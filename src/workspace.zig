const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const Store = @import("store.zig").Store;
const ignore = @import("ignore.zig");
const idx = @import("index.zig");
const keyring = @import("keyring.zig");
const Oid = oid.Oid;

fn appendFile(
    store: *Store,
    work_dir: std.Io.Dir,
    rel_path: []const u8,
    cache: ?*const idx.Index,
    fresh: ?*idx.Index,
    entries: *std.ArrayList(object.TreeEntry),
) !void {
    const io = store.io;
    const alloc = store.alloc;

    const st = work_dir.statFile(io, rel_path, .{}) catch null;
    var blob: ?Oid = null;
    if (cache) |c| if (st) |s| {
        if (c.lookup(rel_path, s)) |cached| {
            if (store.has(cached)) blob = cached;
        }
    };
    if (blob == null) {
        const data = try work_dir.readFileAlloc(io, rel_path, alloc, .unlimited);
        defer alloc.free(data);
        blob = try store.writeFileContent(data);
    }
    if (fresh) |f| if (st) |s| try f.put(rel_path, s, blob.?);
    const exec = if (st) |s| (s.permissions.toMode() & 0o111) != 0 else false;
    const path = try alloc.dupe(u8, rel_path);
    errdefer alloc.free(path);
    try entries.append(alloc, .{
        .mode = if (exec) .executable else .regular,
        .path = path,
        .blob = blob.?,
    });
}

fn scan(
    store: *Store,
    work_dir: std.Io.Dir,
    cache: ?*const idx.Index,
    fresh: ?*idx.Index,
    plan: *const keyring.Plan,
) ![]object.TreeEntry {
    const io = store.io;
    const alloc = store.alloc;

    var ignores = try ignore.IgnoreList.loadMerged(alloc, work_dir, io);
    defer ignores.deinit();

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e.path);
        entries.deinit(alloc);
    }

    const seen_outputs = try alloc.alloc(bool, plan.outputs.len);
    defer alloc.free(seen_outputs);
    @memset(seen_outputs, false);

    var walker = try work_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!ignores.isIgnored(entry.path, true)) try walker.enter(io, entry);
            },
            .file => {
                if (plan.isSource(entry.path)) continue;
                if (ignores.isIgnored(entry.path, false)) continue;
                for (plan.outputs, 0..) |o, i| {
                    if (std.mem.eql(u8, o, entry.path)) seen_outputs[i] = true;
                }
                try appendFile(store, work_dir, entry.path, cache, fresh, &entries);
            },
            .sym_link => {
                if (plan.isSource(entry.path)) continue;
                if (ignores.isIgnored(entry.path, false)) continue;
                var buf: [4096]u8 = undefined;
                const n = work_dir.readLink(io, entry.path, &buf) catch continue;
                const blob = try store.writeFileContent(buf[0..n]);
                const path = try alloc.dupe(u8, entry.path);
                errdefer alloc.free(path);
                try entries.append(alloc, .{
                    .mode = .symlink,
                    .path = path,
                    .blob = blob,
                });
            },
            else => {},
        }
    }

    for (plan.outputs, seen_outputs) |path, already| {
        if (already) continue;
        work_dir.access(io, path, .{}) catch continue;
        try appendFile(store, work_dir, path, cache, fresh, &entries);
    }

    const slice = try entries.toOwnedSlice(alloc);
    std.mem.sort(object.TreeEntry, slice, {}, object.Tree.lessThan);
    return slice;
}

fn freeEntries(alloc: std.mem.Allocator, entries: []object.TreeEntry) void {
    for (entries) |e| alloc.free(e.path);
    alloc.free(entries);
}

/// The working tree as sorted tree entries, with the stat-cache consulted and
/// refreshed exactly as a save would. Callers that want the tree's shape without
/// creating a change (moment capture) use this instead of `snapshot`.
/// Free with `freeTreeEntries`.
pub fn captureEntries(store: *Store, work_dir: std.Io.Dir) ![]object.TreeEntry {
    const alloc = store.alloc;

    var cache = try idx.Index.load(store, alloc);
    defer cache.deinit();
    var fresh = idx.Index.empty(alloc);
    defer fresh.deinit();

    var plan = try keyring.prepare(store.io, alloc, work_dir);
    defer plan.deinit();

    const entries = try scan(store, work_dir, &cache, &fresh, &plan);
    fresh.save(store) catch {};
    return entries;
}

pub fn freeTreeEntries(alloc: std.mem.Allocator, entries: []object.TreeEntry) void {
    freeEntries(alloc, entries);
}

pub fn snapshot(store: *Store, work_dir: std.Io.Dir, author: []const u8, message: []const u8, timestamp: i64) !Oid {
    const alloc = store.alloc;

    var cache = try idx.Index.load(store, alloc);
    defer cache.deinit();
    var fresh = idx.Index.empty(alloc);
    defer fresh.deinit();

    var plan = try keyring.prepare(store.io, alloc, work_dir);
    defer plan.deinit();

    const entries = try scan(store, work_dir, &cache, &fresh, &plan);
    defer freeEntries(alloc, entries);
    fresh.save(store) catch {};

    const tree_oid = try store.writeTree(.{ .entries = entries });

    const branch = try store.headBranch();
    defer alloc.free(branch);

    var parents_buf: [1]Oid = undefined;
    var parents: []const Oid = parents_buf[0..0];
    if (store.refExists(branch)) {
        parents_buf[0] = try store.readRef(branch);
        parents = parents_buf[0..1];
    }

    var seed: [Oid.len + 8]u8 = undefined;
    @memcpy(seed[0..Oid.len], &tree_oid.bytes);
    std.mem.writeInt(u64, seed[Oid.len..][0..8], @bitCast(timestamp), .big);
    var digest: [Oid.len]u8 = undefined;
    oid.Blake3.hash(&seed, &digest, .{});
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, digest[0..16]);

    const change = object.Change{
        .tree = tree_oid,
        .parents = parents,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = 0,
        .author = author,
        .message = message,
    };
    const change_oid = try store.writeChange(change);
    try store.updateRef(branch, change_oid);
    return change_oid;
}

pub const ChangeKind = enum { added, modified, deleted };

pub const StatusEntry = struct {
    path: []const u8,
    kind: ChangeKind,
};

pub fn status(store: *Store, work_dir: std.Io.Dir, alloc: std.mem.Allocator) ![]StatusEntry {
    var cache = try idx.Index.load(store, store.alloc);
    defer cache.deinit();
    var fresh = idx.Index.empty(store.alloc);
    defer fresh.deinit();

    var plan = try keyring.prepare(store.io, store.alloc, work_dir);
    defer plan.deinit();

    const work_entries = try scan(store, work_dir, &cache, &fresh, &plan);
    defer freeEntries(store.alloc, work_entries);
    fresh.save(store) catch {};

    var head_map = std.StringHashMap(Oid).init(alloc);
    defer head_map.deinit();

    var head_tree: ?object.Tree = null;
    defer if (head_tree) |t| object.freeTree(store.alloc, t);

    const branch = try store.headBranch();
    defer store.alloc.free(branch);
    if (store.refExists(branch)) {
        const change = try store.readChange(try store.readRef(branch));
        defer object.freeChange(store.alloc, change);
        const t = try store.readTree(change.tree);
        head_tree = t;
        for (t.entries) |e| try head_map.put(e.path, e.blob);
    }

    var work_map = std.StringHashMap(Oid).init(alloc);
    defer work_map.deinit();
    for (work_entries) |e| try work_map.put(e.path, e.blob);

    var results: std.ArrayList(StatusEntry) = .empty;
    errdefer {
        for (results.items) |r| alloc.free(r.path);
        results.deinit(alloc);
    }

    for (work_entries) |e| {
        if (head_map.get(e.path)) |head_blob| {
            if (!head_blob.eql(e.blob)) {
                try results.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .modified });
            }
        } else {
            try results.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .added });
        }
    }

    if (head_tree) |t| {
        for (t.entries) |e| {
            if (!work_map.contains(e.path)) {
                try results.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .deleted });
            }
        }
    }

    return results.toOwnedSlice(alloc);
}

pub fn materialize(store: *Store, tree_oid: Oid, dest_dir: std.Io.Dir) !void {
    const io = store.io;
    const alloc = store.alloc;

    const tree = try store.readTree(tree_oid);
    defer object.freeTree(alloc, tree);

    for (tree.entries) |e| {
        if (std.fs.path.dirnamePosix(e.path)) |dir| {
            try dest_dir.createDirPath(io, dir);
        }
        const data = try store.readFileContent(e.blob);
        defer alloc.free(data);
        try dest_dir.writeFile(io, .{ .sub_path = e.path, .data = data });
    }
}

/// Restore a single file to its HEAD content, overwriting any local edits.
/// Errors `PathNotInHead` if the path is not tracked in the current HEAD change.
pub fn restoreFile(store: *Store, work_dir: std.Io.Dir, rel_path: []const u8) !void {
    const io = store.io;
    const alloc = store.alloc;

    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return error.PathNotInHead;

    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    for (tree.entries) |e| {
        if (std.mem.eql(u8, e.path, rel_path)) {
            const data = try store.readFileContent(e.blob);
            defer alloc.free(data);
            if (std.fs.path.dirnamePosix(rel_path)) |dir| {
                try work_dir.createDirPath(io, dir);
            }
            try work_dir.writeFile(io, .{ .sub_path = rel_path, .data = data });
            return;
        }
    }
    return error.PathNotInHead;
}

// --- tests ---

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "snapshot, status, materialize" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/sub/b.txt", .data = "world" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const change_oid = try snapshot(&store, work, "Nico <n@x>", "init", 1_700_000_000);

    {
        const st = try status(&store, work, alloc);
        defer {
            for (st) |e| alloc.free(e.path);
            alloc.free(st);
        }
        try testing.expectEqual(@as(usize, 0), st.len);
    }

    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "changed" });
    {
        const st = try status(&store, work, alloc);
        defer {
            for (st) |e| alloc.free(e.path);
            alloc.free(st);
        }
        try testing.expectEqual(@as(usize, 1), st.len);
        try testing.expectEqualStrings("a.txt", st[0].path);
        try testing.expectEqual(ChangeKind.modified, st[0].kind);
    }

    const change = try store.readChange(change_oid);
    defer object.freeChange(alloc, change);

    try tmp.dir.createDirPath(io, "out");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    try materialize(&store, change.tree, out);

    const a = try out.readFileAlloc(io, "a.txt", alloc, .unlimited);
    defer alloc.free(a);
    try testing.expectEqualStrings("hello", a);

    const b = try out.readFileAlloc(io, "sub/b.txt", alloc, .unlimited);
    defer alloc.free(b);
    try testing.expectEqualStrings("world", b);
}

test "ignored files are excluded from status and snapshot" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work/target");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/.grignore", .data = "*.o\ntarget/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "hello" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/junk.o", .data = "obj" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/target/big.bin", .data = "huge" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const st = try status(&store, work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    for (st) |e| {
        try testing.expect(!std.mem.eql(u8, e.path, "junk.o"));
        try testing.expect(std.mem.indexOf(u8, e.path, "target") == null);
    }

    _ = try snapshot(&store, work, "Nico <n@x>", "init", 1_700_000_000);
    const branch = try store.headBranch();
    defer alloc.free(branch);
    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        try testing.expect(!std.mem.eql(u8, e.path, "junk.o"));
        try testing.expect(std.mem.indexOf(u8, e.path, "target") == null);
    }
}

test "a sealed source never enters the tree and its sealed form always does" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    const seal = @import("seal.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    const absz = try alloc.dupeZ(u8, abs);
    defer alloc.free(absz);
    _ = setenv("XDG_CONFIG_HOME", absz.ptr, 1);
    defer _ = unsetenv("XDG_CONFIG_HOME");

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const id = try keyring.createIdentity(io, alloc, true);
    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    try manifest.putMember(io, seal.newRepoKey(io), "nico", id.publicId());
    try keyring.saveManifest(io, alloc, work, &manifest);

    try work.writeFile(io, .{ .sub_path = ".grignore", .data = ".env\n" });
    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-live-1\n" });

    _ = try snapshot(&store, work, "Nico <n@x>", "init", 1_700_000_000);

    const branch = try store.headBranch();
    defer alloc.free(branch);
    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    var saw_sealed = false;
    for (tree.entries) |e| {
        try testing.expect(!std.mem.eql(u8, e.path, ".env"));
        try testing.expect(!std.mem.eql(u8, e.path, ".env.sealed"));
        if (std.mem.eql(u8, e.path, seal.manifest_name)) {
            saw_sealed = true;
            const data = try store.readFileContent(e.blob);
            defer alloc.free(data);
            try testing.expect(std.mem.indexOf(u8, data, "sk-live-1") == null);
            try testing.expect(std.mem.indexOf(u8, data, "API_KEY=gr1:") != null);
        }
    }
    try testing.expect(saw_sealed);

    const st = try status(&store, work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 0), st.len);
}

test "restoreFile discards local edits to one file" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/sub/b.txt", .data = "original" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    _ = try snapshot(&store, work, "Nico <n@x>", "init", 1_700_000_000);

    try tmp.dir.writeFile(io, .{ .sub_path = "work/sub/b.txt", .data = "corrupted" });
    try restoreFile(&store, work, "sub/b.txt");

    const got = try work.readFileAlloc(io, "sub/b.txt", alloc, .unlimited);
    defer alloc.free(got);
    try testing.expectEqualStrings("original", got);

    try testing.expectError(error.PathNotInHead, restoreFile(&store, work, "nope.txt"));
}
