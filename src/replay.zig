const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store_mod = @import("store.zig");
const merge = @import("merge.zig");
const superpose = @import("superpose.zig");
const Oid = oid.Oid;
const Store = store_mod.Store;

pub const Error = error{
    MergeChangeNotReplayable,
};

pub const Result = struct {
    tree: Oid,
    conflicts: [][]u8,

    pub fn clean(self: Result) bool {
        return self.conflicts.len == 0;
    }
};

pub fn freeResult(alloc: std.mem.Allocator, r: Result) void {
    for (r.conflicts) |p| alloc.free(p);
    alloc.free(r.conflicts);
}

pub fn emptyTree(store: *Store) !Oid {
    return store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
}

pub fn parentTreeOf(store: *Store, alloc: std.mem.Allocator, change: object.Change) !Oid {
    if (change.parents.len > 1) return Error.MergeChangeNotReplayable;
    if (change.parents.len == 0) return emptyTree(store);
    const parent = try store.readChange(change.parents[0]);
    defer object.freeChange(alloc, parent);
    return parent.tree;
}

pub fn applyChange(store: *Store, alloc: std.mem.Allocator, base_tree: Oid, change_oid: Oid) !Result {
    const change = try store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    const parent_tree = try parentTreeOf(store, alloc, change);
    return applyTreeDelta(store, alloc, parent_tree, change.tree, base_tree);
}

pub fn applyChain(store: *Store, alloc: std.mem.Allocator, base_tree: Oid, changes: []const Oid) !Result {
    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }

    var tree = base_tree;
    for (changes) |c| {
        const r = try applyChange(store, alloc, tree, c);
        defer alloc.free(r.conflicts);
        tree = r.tree;
        for (r.conflicts) |p| {
            errdefer alloc.free(p);
            try conflicts.append(alloc, p);
        }
    }

    return .{ .tree = tree, .conflicts = try conflicts.toOwnedSlice(alloc) };
}

const EntryMap = std.StringHashMap(object.TreeEntry);

fn loadEntryMap(store: *Store, alloc: std.mem.Allocator, tree: Oid, map: *EntryMap) !void {
    const loaded = try store.readTree(tree);
    defer object.freeTree(alloc, loaded);
    for (loaded.entries) |e| {
        const key = try alloc.dupe(u8, e.path);
        errdefer alloc.free(key);
        try map.put(key, .{ .mode = e.mode, .path = key, .blob = e.blob });
    }
}

fn freeEntryMap(alloc: std.mem.Allocator, map: *EntryMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    map.deinit();
}

pub fn applyTreeDelta(
    store: *Store,
    alloc: std.mem.Allocator,
    delta_from: Oid,
    delta_to: Oid,
    base_tree: Oid,
) !Result {
    var from_map = EntryMap.init(alloc);
    defer freeEntryMap(alloc, &from_map);
    var to_map = EntryMap.init(alloc);
    defer freeEntryMap(alloc, &to_map);
    var base_map = EntryMap.init(alloc);
    defer freeEntryMap(alloc, &base_map);

    try loadEntryMap(store, alloc, delta_from, &from_map);
    try loadEntryMap(store, alloc, delta_to, &to_map);
    try loadEntryMap(store, alloc, base_tree, &base_map);

    var paths = std.StringHashMap(void).init(alloc);
    defer paths.deinit();
    {
        var it = from_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
        it = to_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
        it = base_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
    }

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e.path);
        entries.deinit(alloc);
    }
    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }

    const sset = superpose.settings(store, alloc);
    var superposed: usize = superpose.count(store, alloc) catch 0;

    var pit = paths.keyIterator();
    while (pit.next()) |kp| {
        const path = kp.*;
        const resolved = try merge.resolveEntry(
            store,
            alloc,
            path,
            from_map.get(path),
            base_map.get(path),
            to_map.get(path),
            &conflicts,
            sset,
            &superposed,
        );
        if (resolved) |e| {
            try entries.append(alloc, .{
                .mode = e.mode,
                .path = try alloc.dupe(u8, path),
                .blob = e.blob,
            });
        }
    }

    std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = entries.items });
    for (entries.items) |e| alloc.free(e.path);
    entries.deinit(alloc);

    return .{ .tree = tree_oid, .conflicts = try conflicts.toOwnedSlice(alloc) };
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,

    fn init() !Fixture {
        const tmp = std.testing.tmpDir(.{});
        const store = try Store.init(std.testing.io, testing.allocator, tmp.dir);
        return .{ .tmp = tmp, .store = store };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn blob(self: *Fixture, data: []const u8) !Oid {
        return self.store.writeFileContent(data);
    }

    fn tree(self: *Fixture, entries: []object.TreeEntry) !Oid {
        std.sort.pdq(object.TreeEntry, entries, {}, object.Tree.lessThan);
        return self.store.writeTree(.{ .entries = entries });
    }

    fn commit(self: *Fixture, t: Oid, parents: []const Oid) !Oid {
        return self.store.writeChange(.{
            .tree = t,
            .parents = parents,
            .change_id = [_]u8{0} ** 16,
            .timestamp = 1_700_000_000,
            .tz_offset_min = 0,
            .author = "T <t@e.com>",
            .message = "c",
        });
    }

    fn read(self: *Fixture, t: Oid, path: []const u8) !?object.TreeEntry {
        const loaded = try self.store.readTree(t);
        defer object.freeTree(testing.allocator, loaded);
        for (loaded.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) {
                return .{ .mode = e.mode, .path = "", .blob = e.blob };
            }
        }
        return null;
    }

    fn text(self: *Fixture, t: Oid, path: []const u8) ![]u8 {
        const e = (try self.read(t, path)) orelse return error.MissingPath;
        return self.store.readFileContent(e.blob);
    }

    fn size(self: *Fixture, t: Oid) !usize {
        const loaded = try self.store.readTree(t);
        defer object.freeTree(testing.allocator, loaded);
        return loaded.entries.len;
    }
};

test "replay a pure add onto an unrelated base" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    const keep = try f.blob("keep\n");
    const added = try f.blob("added\n");

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "old.txt", .blob = keep },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "old.txt", .blob = keep },
        .{ .mode = .regular, .path = "new.txt", .blob = added },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "old.txt", .blob = keep },
        .{ .mode = .regular, .path = "unrelated.txt", .blob = try f.blob("other\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 3), try f.size(r.tree));
    const got = try f.text(r.tree, "new.txt");
    defer alloc.free(got);
    try testing.expectEqualStrings("added\n", got);
    const other = try f.text(r.tree, "unrelated.txt");
    defer alloc.free(other);
    try testing.expectEqualStrings("other\n", other);
}

test "replay a delete" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    const gone = try f.blob("gone\n");
    const stay = try f.blob("stay\n");

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "doomed.txt", .blob = gone },
        .{ .mode = .regular, .path = "stay.txt", .blob = stay },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "stay.txt", .blob = stay },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "doomed.txt", .blob = gone },
        .{ .mode = .regular, .path = "stay.txt", .blob = stay },
        .{ .mode = .regular, .path = "extra.txt", .blob = try f.blob("extra\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 2), try f.size(r.tree));
    try testing.expect((try f.read(r.tree, "doomed.txt")) == null);
    try testing.expect((try f.read(r.tree, "extra.txt")) != null);
}

test "replay a modification onto a base with independent edits" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("a\nb\nc\n") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("a\nb\nC\n") },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("A\nb\nc\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    const got = try f.text(r.tree, "f");
    defer alloc.free(got);
    try testing.expectEqualStrings("A\nb\nC\n", got);
}

test "replay a mode change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    const script = try f.blob("#!/bin/sh\necho hi\n");

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "run.sh", .blob = script },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .executable, .path = "run.sh", .blob = script },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "run.sh", .blob = script },
        .{ .mode = .regular, .path = "readme", .blob = try f.blob("hi\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    const e = (try f.read(r.tree, "run.sh")).?;
    try testing.expectEqual(object.Mode.executable, e.mode);
    try testing.expect(e.blob.eql(script));
}

test "replay a symlink retarget" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("old/target") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("new/target") },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("old/target") },
        .{ .mode = .regular, .path = "file", .blob = try f.blob("data\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    const e = (try f.read(r.tree, "link")).?;
    try testing.expectEqual(object.Mode.symlink, e.mode);
    const target = try f.text(r.tree, "link");
    defer alloc.free(target);
    try testing.expectEqualStrings("new/target", target);
}

test "replay a divergent symlink conflicts without text markers" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("old") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("theirs") },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("ours") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("link", r.conflicts[0]);
    const target = try f.text(r.tree, "link");
    defer alloc.free(target);
    try testing.expectEqualStrings("theirs", target);
}

test "replay a root change onto a populated base" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var root_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "seed.txt", .blob = try f.blob("seed\n") },
    };
    const root_tree = try f.tree(&root_entries);
    const root = try f.commit(root_tree, &.{});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "existing.txt", .blob = try f.blob("existing\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, root);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 2), try f.size(r.tree));
    try testing.expect((try f.read(r.tree, "seed.txt")) != null);
    try testing.expect((try f.read(r.tree, "existing.txt")) != null);
}

test "an empty delta is a no-op" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("same\n") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});
    const child = try f.commit(parent_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("different\n") },
        .{ .mode = .executable, .path = "g", .blob = try f.blob("g\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expect(r.tree.eql(base));
}

test "a conflicting apply is reported, not fatal" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("a\nb\nc\n") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("X\nb\nc\n") },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("Y\nb\nc\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChange(&f.store, alloc, base, child);
    defer freeResult(alloc, r);

    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("f", r.conflicts[0]);

    const got = try f.text(r.tree, "f");
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "X") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Y") != null);
    try testing.expect(merge.hasConflictMarkers(got));
}

test "replaying a chain of three preserves an untouched base file" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var t0_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "log", .blob = try f.blob("one\n") },
    };
    const t0 = try f.tree(&t0_entries);
    const c0 = try f.commit(t0, &.{});

    var t1_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "log", .blob = try f.blob("one\ntwo\n") },
    };
    const t1 = try f.tree(&t1_entries);
    const c1 = try f.commit(t1, &.{c0});

    var t2_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "log", .blob = try f.blob("one\ntwo\nthree\n") },
        .{ .mode = .executable, .path = "bin/run", .blob = try f.blob("#!/bin/sh\n") },
    };
    const t2 = try f.tree(&t2_entries);
    const c2 = try f.commit(t2, &.{c1});

    var t3_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "log", .blob = try f.blob("one\ntwo\nthree\nfour\n") },
        .{ .mode = .executable, .path = "bin/run", .blob = try f.blob("#!/bin/sh\n") },
    };
    const t3 = try f.tree(&t3_entries);
    const c3 = try f.commit(t3, &.{c2});

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "log", .blob = try f.blob("one\n") },
        .{ .mode = .regular, .path = "untouched", .blob = try f.blob("intact\n") },
    };
    const base = try f.tree(&base_entries);

    const r = try applyChain(&f.store, alloc, base, &.{ c1, c2, c3 });
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 3), try f.size(r.tree));

    const log = try f.text(r.tree, "log");
    defer alloc.free(log);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\n", log);

    const untouched = try f.text(r.tree, "untouched");
    defer alloc.free(untouched);
    try testing.expectEqualStrings("intact\n", untouched);

    const run = (try f.read(r.tree, "bin/run")).?;
    try testing.expectEqual(object.Mode.executable, run.mode);
}

test "identity: replaying a change onto its own parent tree reproduces its tree" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var parent_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = try f.blob("a\nb\nc\n") },
        .{ .mode = .regular, .path = "doomed", .blob = try f.blob("bye\n") },
        .{ .mode = .regular, .path = "sh", .blob = try f.blob("#!/bin/sh\n") },
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("a.txt") },
    };
    const parent_tree = try f.tree(&parent_entries);
    const parent = try f.commit(parent_tree, &.{});

    var child_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = try f.blob("a\nB\nc\n") },
        .{ .mode = .executable, .path = "sh", .blob = try f.blob("#!/bin/sh\n") },
        .{ .mode = .symlink, .path = "link", .blob = try f.blob("nested/a.txt") },
        .{ .mode = .regular, .path = "nested/new", .blob = try f.blob("fresh\n") },
    };
    const child_tree = try f.tree(&child_entries);
    const child = try f.commit(child_tree, &.{parent});

    const r = try applyChange(&f.store, alloc, parent_tree, child);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expect(r.tree.eql(child_tree));
}

test "identity holds for a root change replayed onto the empty tree" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var root_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") },
        .{ .mode = .executable, .path = "b", .blob = try f.blob("b\n") },
    };
    const root_tree = try f.tree(&root_entries);
    const root = try f.commit(root_tree, &.{});

    const empty = try emptyTree(&f.store);
    const r = try applyChange(&f.store, alloc, empty, root);
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expect(r.tree.eql(root_tree));
}

test "identity holds across a chain replayed onto the chain base" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var t0_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") },
    };
    const t0 = try f.tree(&t0_entries);
    const c0 = try f.commit(t0, &.{});

    var t1_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n") },
    };
    const t1 = try f.tree(&t1_entries);
    const c1 = try f.commit(t1, &.{c0});

    var t2_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n2\n") },
    };
    const t2 = try f.tree(&t2_entries);
    const c2 = try f.commit(t2, &.{c1});

    const r = try applyChain(&f.store, alloc, t0, &.{ c1, c2 });
    defer freeResult(alloc, r);

    try testing.expect(r.clean());
    try testing.expect(r.tree.eql(t2));
}

test "a merge change is refused rather than silently taking parent zero" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var t_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("f\n") },
    };
    const t = try f.tree(&t_entries);
    const a = try f.commit(t, &.{});
    const b = try f.commit(t, &.{a});
    const m = try f.commit(t, &.{ a, b });

    try testing.expectError(Error.MergeChangeNotReplayable, applyChange(&f.store, alloc, t, m));
    try testing.expectError(Error.MergeChangeNotReplayable, applyChain(&f.store, alloc, t, &.{ b, m }));
}

test "reorder: replaying two independent changes in either order agrees" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var t0_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = try f.blob("base\n") },
    };
    const t0 = try f.tree(&t0_entries);
    const c0 = try f.commit(t0, &.{});

    var t1_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = try f.blob("base\n") },
        .{ .mode = .regular, .path = "x", .blob = try f.blob("x\n") },
    };
    const t1 = try f.tree(&t1_entries);
    const c1 = try f.commit(t1, &.{c0});

    var t2_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = try f.blob("base\n") },
        .{ .mode = .regular, .path = "x", .blob = try f.blob("x\n") },
        .{ .mode = .regular, .path = "y", .blob = try f.blob("y\n") },
    };
    const t2 = try f.tree(&t2_entries);
    const c2 = try f.commit(t2, &.{c1});

    const forward = try applyChain(&f.store, alloc, t0, &.{ c1, c2 });
    defer freeResult(alloc, forward);
    const swapped = try applyChain(&f.store, alloc, t0, &.{ c2, c1 });
    defer freeResult(alloc, swapped);

    try testing.expect(forward.clean());
    try testing.expect(swapped.clean());
    try testing.expect(forward.tree.eql(swapped.tree));
}
