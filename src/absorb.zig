const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const Store = @import("store.zig").Store;
const workspace = @import("workspace.zig");
const oplog = @import("oplog.zig");
const Oid = oid.Oid;

pub const Stats = struct {
    absorbed: usize,
    targets: usize,
    skipped: usize,
};

const ChainEntry = struct {
    oid: Oid,
    change: object.Change,
    tree: object.Tree,
};

const Absorb = struct {
    path: []u8,
    target: usize,
    old: Oid,
    blob: Oid,
};

fn blobInTree(tree: object.Tree, path: []const u8) ?Oid {
    for (tree.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.blob;
    }
    return null;
}

fn eqlOpt(a: ?Oid, b: ?Oid) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

pub fn absorb(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir) !Stats {
    const io = store.io;

    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return .{ .absorbed = 0, .targets = 0, .skipped = 0 };

    const changes = try workspace.status(store, work_dir, alloc);
    defer {
        for (changes) |c| alloc.free(c.path);
        alloc.free(changes);
    }

    const old_tip = try store.readRef(branch);

    var chain: std.ArrayList(ChainEntry) = .empty;
    defer {
        for (chain.items) |*c| {
            object.freeChange(alloc, c.change);
            object.freeTree(alloc, c.tree);
        }
        chain.deinit(alloc);
    }

    {
        var cur = old_tip;
        while (true) {
            const change = try store.readChange(cur);
            const tree = try store.readTree(change.tree);
            try chain.append(alloc, .{ .oid = cur, .change = change, .tree = tree });
            if (change.parents.len == 0) break;
            cur = change.parents[0];
        }
    }
    std.mem.reverse(ChainEntry, chain.items);

    const n = chain.items.len;

    var absorbs: std.ArrayList(Absorb) = .empty;
    defer {
        for (absorbs.items) |a| alloc.free(a.path);
        absorbs.deinit(alloc);
    }

    var skipped: usize = 0;

    for (changes) |c| {
        if (c.kind != .modified) {
            skipped += 1;
            continue;
        }
        var target: ?usize = null;
        var i = n;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            const cb = blobInTree(chain.items[idx].tree, c.path);
            const pb = if (idx > 0) blobInTree(chain.items[idx - 1].tree, c.path) else null;
            if (!eqlOpt(cb, pb)) {
                target = idx;
                break;
            }
        }
        if (target == null) {
            skipped += 1;
            continue;
        }

        const data = try work_dir.readFileAlloc(io, c.path, alloc, .unlimited);
        defer alloc.free(data);
        const new_blob = try store.writeFileContent(data);

        const old_blob = blobInTree(chain.items[target.?].tree, c.path).?;
        try absorbs.append(alloc, .{ .path = try alloc.dupe(u8, c.path), .target = target.?, .old = old_blob, .blob = new_blob });
    }

    if (absorbs.items.len == 0) {
        return .{ .absorbed = 0, .targets = 0, .skipped = skipped };
    }

    var earliest: usize = n;
    var distinct: std.AutoHashMap(usize, void) = .init(alloc);
    defer distinct.deinit();
    for (absorbs.items) |a| {
        if (a.target < earliest) earliest = a.target;
        try distinct.put(a.target, {});
    }

    var new_oids = try alloc.alloc(Oid, n);
    defer alloc.free(new_oids);
    for (chain.items, 0..) |c, i| new_oids[i] = c.oid;

    var idx = earliest;
    while (idx < n) : (idx += 1) {
        const entry = &chain.items[idx];

        const new_entries = try alloc.dupe(object.TreeEntry, entry.tree.entries);
        defer alloc.free(new_entries);
        for (absorbs.items) |a| {
            if (idx < a.target) continue;
            for (new_entries) |*e| {
                if (std.mem.eql(u8, e.path, a.path) and e.blob.eql(a.old)) e.blob = a.blob;
            }
        }
        const new_tree = try store.writeTree(.{ .entries = new_entries });

        const new_parents = try alloc.dupe(Oid, entry.change.parents);
        defer alloc.free(new_parents);
        if (new_parents.len > 0) new_parents[0] = new_oids[idx - 1];

        const new_change = object.Change{
            .tree = new_tree,
            .parents = new_parents,
            .change_id = entry.change.change_id,
            .timestamp = entry.change.timestamp,
            .tz_offset_min = entry.change.tz_offset_min,
            .author = entry.change.author,
            .message = entry.change.message,
        };
        new_oids[idx] = try store.writeChange(new_change);
    }

    const new_tip = new_oids[n - 1];
    try store.updateRef(branch, new_tip);
    try oplog.record(store, .{
        .kind = .other,
        .branch = branch,
        .prev = old_tip,
        .new = new_tip,
        .timestamp = chain.items[n - 1].change.timestamp,
    });

    const new_tip_change = try store.readChange(new_tip);
    defer object.freeChange(alloc, new_tip_change);
    try workspace.materialize(store, new_tip_change.tree, work_dir);

    return .{ .absorbed = absorbs.items.len, .targets = distinct.count(), .skipped = skipped };
}

pub fn run(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir, out: *std.Io.Writer) !void {
    const stats = try absorb(store, alloc, work_dir);
    if (stats.absorbed == 0) {
        try out.writeAll("nothing to absorb\n");
        return;
    }
    if (stats.skipped == 0) {
        try out.print("absorbed {d} file(s) into {d} change(s)\n", .{ stats.absorbed, stats.targets });
    } else {
        try out.print("absorbed {d} file(s) into {d} change(s) ({d} skipped)\n", .{ stats.absorbed, stats.targets, stats.skipped });
    }
}

// --- tests ---

const testing = std.testing;

test "absorb folds working edit into the change that last touched the file" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "1\n" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const change_a = try workspace.snapshot(&store, work, "Nico <n@x>", "add a", 1_700_000_000);

    try tmp.dir.writeFile(io, .{ .sub_path = "work/b.txt", .data = "b\n" });
    _ = try workspace.snapshot(&store, work, "Nico <n@x>", "add b", 1_700_000_100);

    const branch = try store.headBranch();
    defer alloc.free(branch);
    const old_tip = try store.readRef(branch);

    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "1changed\n" });

    const stats = try absorb(&store, alloc, work);
    try testing.expectEqual(@as(usize, 1), stats.absorbed);
    try testing.expectEqual(@as(usize, 1), stats.targets);
    try testing.expectEqual(@as(usize, 0), stats.skipped);

    const new_tip = try store.readRef(branch);
    try testing.expect(!new_tip.eql(old_tip));

    const tip_change = try store.readChange(new_tip);
    defer object.freeChange(alloc, tip_change);
    const tip_tree = try store.readTree(tip_change.tree);
    defer object.freeTree(alloc, tip_tree);
    const tip_a = blobInTree(tip_tree, "a.txt").?;
    const expected = try store.writeFileContent("1changed\n");
    try testing.expect(tip_a.eql(expected));

    var cur = new_tip;
    var found_a_change: ?Oid = null;
    while (true) {
        const ch = try store.readChange(cur);
        defer object.freeChange(alloc, ch);
        const t = try store.readTree(ch.tree);
        defer object.freeTree(alloc, t);
        if (blobInTree(t, "a.txt")) |_| found_a_change = cur;
        if (ch.parents.len == 0) break;
        cur = ch.parents[0];
    }
    try testing.expect(found_a_change != null);

    {
        const root_change = try store.readChange(found_a_change.?);
        defer object.freeChange(alloc, root_change);
        const rt = try store.readTree(root_change.tree);
        defer object.freeTree(alloc, rt);
        try testing.expect(blobInTree(rt, "a.txt").?.eql(expected));
    }

    _ = change_a;

    const st = try workspace.status(&store, work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 0), st.len);
}
