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

/// Drop every line setting `key`, leaving comments and everything else alone.
fn remove(old: []const u8, key: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 and lines.peek() == null) break;
        const line = std.mem.trim(u8, raw, ws);
        if (line.len != 0 and line[0] != '#') {
            if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], ws), key)) continue;
            }
        }
        try out.appendSlice(alloc, raw);
        try out.append(alloc, '\n');
    }
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

/// Remove a key from `.sdt/config`. Absent is success: the point is that the
/// key is not set afterwards.
pub fn unset(store: *Store, key: []const u8) !void {
    const alloc = store.alloc;
    const old = store.root.readFileAlloc(store.io, "config", alloc, .unlimited) catch return;
    defer alloc.free(old);
    const new = try remove(old, key, alloc);
    defer alloc.free(new);
    try store.root.writeFile(store.io, .{ .sub_path = "config", .data = new });
}

// --- global scope (`${XDG_CONFIG_HOME:-~/.config}/sdt/config`) ---

/// Absolute path to the global config directory, or null if HOME is unset.
/// Caller frees.
pub fn globalDir(alloc: std.mem.Allocator) !?[]u8 {
    return globalDirNamed(alloc, "sdt");
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
    return null;
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

/// Remove a key from the global config.
pub fn globalUnset(io: std.Io, alloc: std.mem.Allocator, key: []const u8) !void {
    const path = (try globalPath(alloc)) orelse return error.NoHome;
    defer alloc.free(path);
    const old = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return;
    defer alloc.free(old);
    const new = try remove(old, key, alloc);
    defer alloc.free(new);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = new });
}

// --- resolved settings ---

/// Resolve the change author. Precedence:
///   1. env `SDT_AUTHOR`,
///   2. `user.name`/`user.email` (local, then global) as "Name <email>",
///   3. fallback "you <you@localhost>".
/// Caller frees.
pub fn author(store: *Store, alloc: std.mem.Allocator) ![]u8 {
    if (std.c.getenv("SDT_AUTHOR")) |env| {
        const v = std.mem.span(env);
        if (v.len != 0) return alloc.dupe(u8, v);
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

/// Parse a duration written the way a person writes one: `750ms`, `90s`, `30m`,
/// `2h`, `1d`, or a bare number meaning seconds. Null when it is not a duration,
/// so a caller can keep its default rather than silently reading a typo as zero.
pub fn parseDurationMs(raw: []const u8) ?i64 {
    const s = std.mem.trim(u8, raw, ws);
    if (s.len == 0) return null;

    var digits: usize = 0;
    while (digits < s.len and s[digits] >= '0' and s[digits] <= '9') digits += 1;
    if (digits == 0) return null;

    const n = std.fmt.parseInt(i64, s[0..digits], 10) catch return null;
    const unit = std.mem.trim(u8, s[digits..], ws);

    const scale: i64 = if (unit.len == 0)
        std.time.ms_per_s
    else if (std.mem.eql(u8, unit, "ms"))
        1
    else if (std.mem.eql(u8, unit, "s"))
        std.time.ms_per_s
    else if (std.mem.eql(u8, unit, "m"))
        std.time.ms_per_min
    else if (std.mem.eql(u8, unit, "h"))
        std.time.ms_per_hour
    else if (std.mem.eql(u8, unit, "d"))
        std.time.ms_per_day
    else
        return null;

    return std.math.mul(i64, n, scale) catch null;
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

test "unset removes a key and leaves the rest of the file alone" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try set(&store, "user.name", "Nico");
    try set(&store, "user.email", "n@x.com");
    try unset(&store, "user.name");

    try testing.expect((try getLocal(&store, alloc, "user.name")) == null);
    const kept = try getLocal(&store, alloc, "user.email");
    defer if (kept) |v| alloc.free(v);
    try testing.expectEqualStrings("n@x.com", kept.?);

    // Unsetting what was never set is not an error.
    try unset(&store, "user.name");
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

test "durations parse in the units people write them in" {
    try testing.expectEqual(@as(i64, 750), parseDurationMs("750ms").?);
    try testing.expectEqual(@as(i64, 90_000), parseDurationMs("90s").?);
    try testing.expectEqual(@as(i64, 1_800_000), parseDurationMs("30m").?);
    try testing.expectEqual(@as(i64, 7_200_000), parseDurationMs("2h").?);
    try testing.expectEqual(@as(i64, 86_400_000), parseDurationMs("1d").?);
    // A bare number is seconds.
    try testing.expectEqual(@as(i64, 45_000), parseDurationMs("45").?);
    try testing.expectEqual(@as(i64, 1_800_000), parseDurationMs("  30m  ").?);
    try testing.expectEqual(@as(i64, 0), parseDurationMs("0").?);

    // Not a duration at all, which must not read as zero.
    try testing.expect(parseDurationMs("") == null);
    try testing.expect(parseDurationMs("soon") == null);
    try testing.expect(parseDurationMs("m") == null);
    try testing.expect(parseDurationMs("30 minutes") == null);
}
