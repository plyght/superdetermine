const std = @import("std");
const Store = @import("store.zig").Store;

/// `key = value` config. Two scopes:
///   local  — `.sdt/config` inside a repo
///   global — `${XDG_CONFIG_HOME:-~/.config}/sdt/config`
///
/// Blank lines and lines whose first non-space character is `#` are ignored.
/// Whitespace around key and value is trimmed. Lookups fall back local → global.
const ws = " \t\r";

// --- pure parse / upsert over raw bytes (scope-agnostic) ---

fn parseValue(data: []const u8, key: []const u8, alloc: std.mem.Allocator) !?[]u8 {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, ws);
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], ws);
        if (std.mem.eql(u8, k, key)) {
            const v = std.mem.trim(u8, line[eq + 1 ..], ws);
            return try alloc.dupe(u8, v);
        }
    }
    return null;
}

fn upsert(old: []const u8, key: []const u8, value: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var replaced = false;
    var lines = std.mem.splitScalar(u8, old, '\n');
    var first = true;
    while (lines.next()) |raw| {
        if (raw.len == 0 and lines.peek() == null) break;
        if (!first) try out.append(alloc, '\n');
        first = false;
        const line = std.mem.trim(u8, raw, ws);
        if (line.len != 0 and line[0] != '#') {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                const k = std.mem.trim(u8, line[0..eq], ws);
                if (std.mem.eql(u8, k, key)) {
                    try out.print(alloc, "{s} = {s}", .{ key, value });
                    replaced = true;
                    continue;
                }
            }
        }
        try out.appendSlice(alloc, raw);
    }
    if (!replaced) {
        if (!first) try out.append(alloc, '\n');
        try out.print(alloc, "{s} = {s}", .{ key, value });
    }
    try out.append(alloc, '\n');
    return out.toOwnedSlice(alloc);
}

// --- local scope (repo `.sdt/config`) ---

/// Read a key from local config, falling back to global. Caller frees.
pub fn get(store: *Store, alloc: std.mem.Allocator, key: []const u8) !?[]u8 {
    if (store.root.readFileAlloc(store.io, "config", alloc, .unlimited)) |data| {
        defer alloc.free(data);
        if (try parseValue(data, key, alloc)) |v| return v;
    } else |_| {}
    return globalGet(store.io, alloc, key);
}

/// Read a key from local config only (no global fallback). Caller frees.
pub fn getLocal(store: *Store, alloc: std.mem.Allocator, key: []const u8) !?[]u8 {
    const data = store.root.readFileAlloc(store.io, "config", alloc, .unlimited) catch return null;
    defer alloc.free(data);
    return parseValue(data, key, alloc);
}

/// Upsert a key in `.sdt/config`.
pub fn set(store: *Store, key: []const u8, value: []const u8) !void {
    const alloc = store.alloc;
    const old = store.root.readFileAlloc(store.io, "config", alloc, .unlimited) catch
        try alloc.dupe(u8, "");
    defer alloc.free(old);
    const new = try upsert(old, key, value, alloc);
    defer alloc.free(new);
    try store.root.writeFile(store.io, .{ .sub_path = "config", .data = new });
}

// --- global scope (`${XDG_CONFIG_HOME:-~/.config}/sdt/config`) ---

/// Absolute path to the global config directory, or null if HOME is unset.
/// Caller frees.
pub fn globalDir(alloc: std.mem.Allocator) !?[]u8 {
    return globalDirNamed(alloc, "sdt");
}

/// The pre-rename global config directory.
///
/// It is still read, and that is not cosmetic: a machine that used this tool
/// before the rename keeps its identity, its default branch, and — the one that
/// actually bit — `sync.git`, whose silent disappearance stopped every save
/// from reaching the colocated git repo while still reporting success.
pub fn legacyGlobalDir(alloc: std.mem.Allocator) !?[]u8 {
    return globalDirNamed(alloc, "gr");
}

fn globalDirNamed(alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const v = std.mem.span(xdg);
        if (v.len != 0) return try std.fmt.allocPrint(alloc, "{s}/{s}", .{ v, name });
    }
    if (std.c.getenv("HOME")) |home| {
        const v = std.mem.span(home);
        if (v.len != 0) return try std.fmt.allocPrint(alloc, "{s}/.config/{s}", .{ v, name });
    }
    return null;
}

fn globalPath(alloc: std.mem.Allocator) !?[]u8 {
    const dir = (try globalDir(alloc)) orelse return null;
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/config", .{dir});
}

/// Read a key from the global config. Caller frees.
pub fn globalGet(io: std.Io, alloc: std.mem.Allocator, key: []const u8) !?[]u8 {
    if (try globalPath(alloc)) |path| {
        defer alloc.free(path);
        if (std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited)) |data| {
            defer alloc.free(data);
            if (try parseValue(data, key, alloc)) |v| return v;
        } else |_| {}
    }

    // Fall through to the pre-rename location, per key rather than per file, so
    // a setting written before the rename still applies even once the new file
    // exists and holds other keys.
    const legacy_dir = (try legacyGlobalDir(alloc)) orelse return null;
    defer alloc.free(legacy_dir);
    const legacy = try std.fmt.allocPrint(alloc, "{s}/config", .{legacy_dir});
    defer alloc.free(legacy);
    const data = std.Io.Dir.cwd().readFileAlloc(io, legacy, alloc, .unlimited) catch return null;
    defer alloc.free(data);
    return parseValue(data, key, alloc);
}

/// Upsert a key in the global config, creating the directory if needed.
pub fn globalSet(io: std.Io, alloc: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    const dir = (try globalDir(alloc)) orelse return error.NoHome;
    defer alloc.free(dir);
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(alloc, "{s}/config", .{dir});
    defer alloc.free(path);
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch
        try alloc.dupe(u8, "");
    defer alloc.free(old);
    const new = try upsert(old, key, value, alloc);
    defer alloc.free(new);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new });
}

// --- resolved settings ---

/// Resolve the change author. Precedence:
///   1. env `SDT_AUTHOR` (or the older `GR_AUTHOR`),
///   2. `user.name`/`user.email` (local, then global) as "Name <email>",
///   3. fallback "you <you@localhost>".
/// Caller frees.
pub fn author(store: *Store, alloc: std.mem.Allocator) ![]u8 {
    // The old `GR_` spelling still works, so an existing shell profile does not
    // have to be edited the day this is installed.
    for ([_][:0]const u8{ "SDT_AUTHOR", "GR_AUTHOR" }) |name| {
        if (std.c.getenv(name)) |env| {
            const v = std.mem.span(env);
            if (v.len != 0) return alloc.dupe(u8, v);
        }
    }
    const name = try get(store, alloc, "user.name");
    defer if (name) |n| alloc.free(n);
    const email = try get(store, alloc, "user.email");
    defer if (email) |e| alloc.free(e);

    if (name) |n| {
        if (email) |e| return std.fmt.allocPrint(alloc, "{s} <{s}>", .{ n, e });
        return alloc.dupe(u8, n);
    }
    if (email) |e| return std.fmt.allocPrint(alloc, "<{s}>", .{e});
    return alloc.dupe(u8, "you <you@localhost>");
}

/// The default branch name for `sdt init`, from global `init.defaultBranch`,
/// else "main". Caller frees.
pub fn defaultBranch(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    if (try globalGet(io, alloc, "init.defaultBranch")) |v| {
        if (v.len != 0) return v;
        alloc.free(v);
    }
    return alloc.dupe(u8, "main");
}

// --- tests ---

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "set + author combines name and email" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try set(&store, "user.name", "Nico");
    try set(&store, "user.email", "n@x.com");
    const a = try author(&store, alloc);
    defer alloc.free(a);
    try testing.expectEqualStrings("Nico <n@x.com>", a);
}

test "set upserts without duplicating" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try set(&store, "user.name", "First");
    try set(&store, "user.name", "Second");
    const n = try getLocal(&store, alloc, "user.name");
    defer if (n) |v| alloc.free(v);
    try testing.expectEqualStrings("Second", n.?);
}

test "get of missing key is null" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try testing.expect((try getLocal(&store, alloc, "nope")) == null);
}

test "global config roundtrip and local-over-global precedence" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Point XDG_CONFIG_HOME at a temp dir so we don't touch the real ~/.config.
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    const absz = try alloc.dupeZ(u8, abs);
    defer alloc.free(absz);
    _ = setenv("XDG_CONFIG_HOME", absz.ptr, 1);
    defer _ = unsetenv("XDG_CONFIG_HOME");

    try globalSet(io, alloc, "user.name", "GlobalName");
    const g = try globalGet(io, alloc, "user.name");
    defer if (g) |v| alloc.free(v);
    try testing.expectEqualStrings("GlobalName", g.?);

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    // No local user.name → get falls back to global.
    const fb = try get(&store, alloc, "user.name");
    defer if (fb) |v| alloc.free(v);
    try testing.expectEqualStrings("GlobalName", fb.?);
    // Local overrides global.
    try set(&store, "user.name", "LocalName");
    const lo = try get(&store, alloc, "user.name");
    defer if (lo) |v| alloc.free(v);
    try testing.expectEqualStrings("LocalName", lo.?);
}

test "a setting written before the rename is still honoured" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    const absz = try alloc.dupeZ(u8, abs);
    defer alloc.free(absz);
    _ = setenv("XDG_CONFIG_HOME", absz.ptr, 1);
    defer _ = unsetenv("XDG_CONFIG_HOME");

    // Only the pre-rename directory exists, as on a machine that used the tool
    // before the rename and has not written a setting since.
    try tmp.dir.createDirPath(io, "gr");
    try tmp.dir.writeFile(io, .{ .sub_path = "gr/config", .data = "sync.git = true\nuser.name = Old\n" });

    const sync = try globalGet(io, alloc, "sync.git");
    defer if (sync) |v| alloc.free(v);
    try testing.expectEqualStrings("true", sync.?);

    // A new-location file must not hide keys that only the old one has.
    try tmp.dir.createDirPath(io, "sdt");
    try tmp.dir.writeFile(io, .{ .sub_path = "sdt/config", .data = "user.name = New\n" });

    const name = try globalGet(io, alloc, "user.name");
    defer if (name) |v| alloc.free(v);
    try testing.expectEqualStrings("New", name.?);

    const still = try globalGet(io, alloc, "sync.git");
    defer if (still) |v| alloc.free(v);
    try testing.expectEqualStrings("true", still.?);
}
