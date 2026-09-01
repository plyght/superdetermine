const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const Store = @import("store.zig").Store;
const workspace = @import("workspace.zig");
const oplog = @import("oplog.zig");
const history = @import("history.zig");
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

/// Which part of the working tree an amend carries: everything, whole files, or
/// hunks within files.
pub const Scope = union(enum) {
    all,
    paths: []const []const u8,
    hunks: []const history.HunkSpec,
};

/// Fold the working tree, or the named part of it, into one named change.
///
/// This is `absorb` with the target chosen by hand rather than inferred, which
/// is what makes it possible to send two hunks of one file to two different
/// changes: run it twice, once per hunk. The working tree is left exactly as it
/// was, so whatever was not selected stays an uncommitted edit.
pub fn amend(
    store: *Store,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
    target: Oid,
    scope: Scope,
    timestamp: i64,
) !history.Result {
    const branch = try store.headBranch();
    defer alloc.free(branch);

    const entries = try workspace.captureEntries(store, work_dir);
    defer workspace.freeTreeEntries(alloc, entries);
    const work_tree = try store.writeTree(.{ .entries = entries });

    const selection: history.Selection = switch (scope) {
        .all => .whole,
        .paths => |p| .{ .paths = p },
        .hunks => |h| .{ .hunks = h },
    };
    return history.amendInto(store, alloc, branch, target, work_tree, selection, timestamp);
}

fn selected(only: []const []const u8, path: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |sel| {
        if (sel.len == 0) continue;
        if (std.mem.eql(u8, sel, path)) return true;
        if (path.len > sel.len and std.mem.startsWith(u8, path, sel) and path[sel.len] == '/') return true;
    }
    return false;
}

pub fn absorb(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir, only: []const []const u8) !Stats {
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
        if (!selected(only, c.path)) continue;
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

    return .{ .absorbed = absorbs.items.len, .targets = distinct.count(), .skipped = skipped };
}

pub fn run(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir, only: []const []const u8, out: *std.Io.Writer) !void {
    const stats = try absorb(store, alloc, work_dir, only);
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

    const stats = try absorb(&store, alloc, work, &.{});
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

const wide_old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
const wide_new = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10a\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20a\n";
const only_first = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
const first_and_last = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20a\n";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    work: std.Io.Dir,

    fn init() !Fixture {
        const io = std.testing.io;
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.createDirPath(io, "work");
        const work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
        const store = try Store.init(io, testing.allocator, work);
        return .{ .tmp = tmp, .store = store, .work = work };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.work.close(std.testing.io);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        try self.work.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn save(self: *Fixture, message: []const u8, timestamp: i64) !Oid {
        return workspace.snapshot(&self.store, self.work, "Nico <n@x>", message, timestamp);
    }

    fn tip(self: *Fixture) !Oid {
        const branch = try self.store.headBranch();
        defer testing.allocator.free(branch);
        return self.store.readRef(branch);
    }

    fn chain(self: *Fixture) ![]Oid {
        return history.chainOf(&self.store, testing.allocator, try self.tip());
    }

    fn text(self: *Fixture, change: Oid, path: []const u8) ![]u8 {
        const c = try self.store.readChange(change);
        defer object.freeChange(testing.allocator, c);
        const t = try self.store.readTree(c.tree);
        defer object.freeTree(testing.allocator, t);
        const blob = blobInTree(t, path) orelse return error.MissingPath;
        return self.store.readFileContent(blob);
    }

    fn onDisk(self: *Fixture, path: []const u8) ![]u8 {
        return self.work.readFileAlloc(std.testing.io, path, testing.allocator, .unlimited);
    }
};

test "amend routes two hunks of one file into two different earlier changes" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    try f.write("app.zig", wide_old);
    _ = try f.save("root", 1_700_000_000);
    try f.write("one.txt", "one\n");
    const first = try f.save("first", 1_700_000_100);
    try f.write("two.txt", "two\n");
    _ = try f.save("second", 1_700_000_200);

    try f.write("app.zig", wide_new);

    const top = [_]usize{1};
    const to_first = [_]history.HunkSpec{.{ .path = "app.zig", .indices = &top }};
    {
        const r = try amend(&f.store, alloc, f.work, first, .{ .hunks = &to_first }, 1_700_000_300);
        defer r.deinit(alloc);
        try testing.expect(r.clean());
    }

    const bottom = [_]usize{2};
    const to_second = [_]history.HunkSpec{.{ .path = "app.zig", .indices = &bottom }};
    {
        const r = try amend(&f.store, alloc, f.work, try f.tip(), .{ .hunks = &to_second }, 1_700_000_400);
        defer r.deinit(alloc);
        try testing.expect(r.clean());
    }

    const chain = try f.chain();
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);

    const root_text = try f.text(chain[0], "app.zig");
    defer alloc.free(root_text);
    try testing.expectEqualStrings(wide_old, root_text);

    const first_text = try f.text(chain[1], "app.zig");
    defer alloc.free(first_text);
    try testing.expectEqualStrings(only_first, first_text);

    const second_text = try f.text(chain[2], "app.zig");
    defer alloc.free(second_text);
    try testing.expectEqualStrings(first_and_last, second_text);

    // The middle hunk was never selected, so it is still an uncommitted edit.
    const on_disk = try f.onDisk("app.zig");
    defer alloc.free(on_disk);
    try testing.expectEqualStrings(wide_new, on_disk);

    const st = try workspace.status(&f.store, f.work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 1), st.len);
    try testing.expectEqualStrings("app.zig", st[0].path);
    try testing.expectEqual(workspace.ChangeKind.modified, st[0].kind);
}

test "amend by path sends one file back and leaves the other edit pending" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    try f.write("a.txt", "a\n");
    const root = try f.save("root", 1_700_000_000);
    try f.write("b.txt", "b\n");
    _ = try f.save("second", 1_700_000_100);

    try f.write("a.txt", "a fixed\n");
    try f.write("b.txt", "b later\n");

    const only = [_][]const u8{"a.txt"};
    const r = try amend(&f.store, alloc, f.work, root, .{ .paths = &only }, 1_700_000_200);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain();
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 2), chain.len);

    const in_root = try f.text(chain[0], "a.txt");
    defer alloc.free(in_root);
    try testing.expectEqualStrings("a fixed\n", in_root);

    const at_tip = try f.text(chain[1], "b.txt");
    defer alloc.free(at_tip);
    try testing.expectEqualStrings("b\n", at_tip);

    const st = try workspace.status(&f.store, f.work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 1), st.len);
    try testing.expectEqualStrings("b.txt", st[0].path);
}

test "amend with no selection folds everything into the named change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    try f.write("a.txt", "a\n");
    const root = try f.save("root", 1_700_000_000);
    try f.write("b.txt", "b\n");
    const second = try f.save("second", 1_700_000_100);

    try f.write("a.txt", "a fixed\n");
    try f.write("c.txt", "c\n");

    const r = try amend(&f.store, alloc, f.work, root, .all, 1_700_000_200);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain();
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 2), chain.len);

    const in_root = try f.text(chain[0], "a.txt");
    defer alloc.free(in_root);
    try testing.expectEqualStrings("a fixed\n", in_root);

    const new_file = try f.text(chain[0], "c.txt");
    defer alloc.free(new_file);
    try testing.expectEqualStrings("c\n", new_file);

    const st = try workspace.status(&f.store, f.work, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 0), st.len);

    try oplog.undo(&f.store, null);
    try testing.expect((try f.tip()).eql(second));
}

test "absorb takes a path filter and leaves the other edits alone" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    try f.write("a.txt", "a\n");
    _ = try f.save("add a", 1_700_000_000);
    try f.write("b.txt", "b\n");
    _ = try f.save("add b", 1_700_000_100);

    try f.write("a.txt", "a changed\n");
    try f.write("b.txt", "b changed\n");

    const only = [_][]const u8{"a.txt"};
    const stats = try absorb(&f.store, alloc, f.work, &only);
    try testing.expectEqual(@as(usize, 1), stats.absorbed);
    try testing.expectEqual(@as(usize, 1), stats.targets);

    const chain = try f.chain();
    defer alloc.free(chain);
    const in_root = try f.text(chain[0], "a.txt");
    defer alloc.free(in_root);
    try testing.expectEqualStrings("a changed\n", in_root);

    const still_pending = try f.onDisk("b.txt");
    defer alloc.free(still_pending);
    try testing.expectEqualStrings("b changed\n", still_pending);
}
