const std = @import("std");
const history = @import("history.zig");
const merge = @import("merge.zig");
const oplog = @import("oplog.zig");
const Store = @import("store.zig").Store;
const Oid = @import("oid.zig").Oid;

pub const Error = error{
    InvalidName,
    NoSuchBranch,
    NoParent,
    Cycle,
    ParentNotAncestor,
};

pub const Relation = struct {
    child: []u8,
    parent: []u8,
};

pub fn freeRelations(alloc: std.mem.Allocator, relations: []Relation) void {
    for (relations) |r| {
        alloc.free(r.child);
        alloc.free(r.parent);
    }
    alloc.free(relations);
}

fn validName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, "\t\r\n") == null;
}

pub fn readAll(store: *Store, alloc: std.mem.Allocator) ![]Relation {
    const data = store.root.readFileAlloc(store.io, "stacks", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return alloc.alloc(Relation, 0),
        else => return e,
    };
    defer alloc.free(data);

    var out: std.ArrayList(Relation) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.child);
            alloc.free(r.parent);
        }
        out.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const child = line[0..tab];
        const parent = line[tab + 1 ..];
        if (!validName(child) or !validName(parent)) continue;
        try out.append(alloc, .{
            .child = try alloc.dupe(u8, child),
            .parent = try alloc.dupe(u8, parent),
        });
    }
    return out.toOwnedSlice(alloc);
}

fn relationLessThan(_: void, a: Relation, b: Relation) bool {
    return std.mem.lessThan(u8, a.child, b.child);
}

fn writeAll(store: *Store, alloc: std.mem.Allocator, relations: []Relation) !void {
    std.sort.pdq(Relation, relations, {}, relationLessThan);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (relations) |r| try out.print(alloc, "{s}\t{s}\n", .{ r.child, r.parent });
    try store.writeFileAtomic("stacks", out.items);
}

fn relationIndex(relations: []const Relation, child: []const u8) ?usize {
    for (relations, 0..) |r, i| if (std.mem.eql(u8, r.child, child)) return i;
    return null;
}

pub fn parentOf(store: *Store, alloc: std.mem.Allocator, child: []const u8) ![]u8 {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    const i = relationIndex(relations, child) orelse return Error.NoParent;
    return alloc.dupe(u8, relations[i].parent);
}

pub fn setParent(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8) !void {
    if (!validName(child) or !validName(parent) or std.mem.eql(u8, child, parent)) return Error.InvalidName;
    if (!store.refExists(child) or !store.refExists(parent)) return Error.NoSuchBranch;

    var relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);

    var cursor = parent;
    var remaining = relations.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        if (std.mem.eql(u8, cursor, child)) return Error.Cycle;
        const i = relationIndex(relations, cursor) orelse break;
        cursor = relations[i].parent;
    }
    if (remaining == 0) return Error.Cycle;

    if (relationIndex(relations, child)) |i| {
        alloc.free(relations[i].parent);
        relations[i].parent = try alloc.dupe(u8, parent);
    } else {
        const grown = try alloc.realloc(relations, relations.len + 1);
        relations = grown;
        relations[relations.len - 1] = .{
            .child = try alloc.dupe(u8, child),
            .parent = try alloc.dupe(u8, parent),
        };
    }
    try writeAll(store, alloc, relations);
}

pub fn clearParent(store: *Store, alloc: std.mem.Allocator, child: []const u8) !bool {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    _ = relationIndex(relations, child) orelse return false;
    var kept: std.ArrayList(Relation) = .empty;
    defer {
        for (kept.items) |r| {
            alloc.free(r.child);
            alloc.free(r.parent);
        }
        kept.deinit(alloc);
    }
    for (relations) |r| {
        if (std.mem.eql(u8, r.child, child)) continue;
        try kept.append(alloc, .{
            .child = try alloc.dupe(u8, r.child),
            .parent = try alloc.dupe(u8, r.parent),
        });
    }
    try writeAll(store, alloc, kept.items);
    return true;
}

pub fn remove(store: *Store, alloc: std.mem.Allocator, branch: []const u8) !bool {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    const own = relationIndex(relations, branch);
    var touched = own != null;
    for (relations) |*r| {
        if (!std.mem.eql(u8, r.parent, branch)) continue;
        touched = true;
        if (own) |i| {
            if (!std.mem.eql(u8, relations[i].parent, r.child)) {
                const grand = try alloc.dupe(u8, relations[i].parent);
                alloc.free(r.parent);
                r.parent = grand;
                continue;
            }
        }
        alloc.free(r.parent);
        r.parent = try alloc.dupe(u8, "");
    }
    if (!touched) return false;
    var kept: std.ArrayList(Relation) = .empty;
    defer {
        for (kept.items) |r| {
            alloc.free(r.child);
            alloc.free(r.parent);
        }
        kept.deinit(alloc);
    }
    for (relations) |r| {
        if (std.mem.eql(u8, r.child, branch) or r.parent.len == 0) continue;
        try kept.append(alloc, .{
            .child = try alloc.dupe(u8, r.child),
            .parent = try alloc.dupe(u8, r.parent),
        });
    }
    try writeAll(store, alloc, kept.items);
    return true;
}

pub fn childrenOf(store: *Store, alloc: std.mem.Allocator, parent: []const u8) ![][]u8 {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |name| alloc.free(name);
        out.deinit(alloc);
    }
    for (relations) |r| {
        if (std.mem.eql(u8, r.parent, parent)) try out.append(alloc, try alloc.dupe(u8, r.child));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

pub fn freeNames(alloc: std.mem.Allocator, names: [][]u8) void {
    for (names) |name| alloc.free(name);
    alloc.free(names);
}

pub fn lineage(store: *Store, alloc: std.mem.Allocator, branch: []const u8) ![][]u8 {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |name| alloc.free(name);
        out.deinit(alloc);
    }
    var cursor = branch;
    var remaining = relations.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        try out.append(alloc, try alloc.dupe(u8, cursor));
        const i = relationIndex(relations, cursor) orelse break;
        cursor = relations[i].parent;
    }
    const owned = try out.toOwnedSlice(alloc);
    std.mem.reverse([]u8, owned);
    return owned;
}

pub fn rootOf(store: *Store, alloc: std.mem.Allocator, branch: []const u8) ![]u8 {
    const names = try lineage(store, alloc, branch);
    defer freeNames(alloc, names);
    return alloc.dupe(u8, names[0]);
}

pub fn forkPoint(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8, prior: []const Oid) !?Oid {
    const child_tip = history.tipOf(store, child) catch return Error.NoSuchBranch;
    const parent_tip = history.tipOf(store, parent) catch return Error.NoSuchBranch;
    const chain = try history.chainOf(store, alloc, child_tip);
    defer alloc.free(chain);
    if (history.indexOf(chain, parent_tip) != null) return parent_tip;
    for (prior) |candidate| {
        if (history.indexOf(chain, candidate) != null) return candidate;
    }

    const records = try oplog.readAll(store, alloc);
    defer {
        for (records) |r| alloc.free(r.branch);
        alloc.free(records);
    }
    var i = records.len;
    while (i > 0) : (i -= 1) {
        const r = records[i - 1];
        if (r.kind == .undo or r.kind == .redo or r.kind == .rewind) continue;
        if (r.kind == .stack) {
            const moves = oplog.stackMoves(alloc, r) catch continue;
            defer alloc.free(moves);
            for (moves) |m| {
                if (!std.mem.eql(u8, m.branch, parent)) continue;
                if (history.indexOf(chain, m.new) != null) return m.new;
                if (history.indexOf(chain, m.prev) != null) return m.prev;
            }
            continue;
        }
        if (!std.mem.eql(u8, r.branch, parent)) continue;
        if (history.indexOf(chain, r.new) != null) return r.new;
        if (history.indexOf(chain, r.prev) != null) return r.prev;
    }
    return merge.commonAncestor(store, alloc, child_tip, parent_tip);
}

pub fn uniqueChanges(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8) ![]Oid {
    const child_tip = history.tipOf(store, child) catch return Error.NoSuchBranch;
    const fork = try forkPoint(store, alloc, child, parent, &.{}) orelse return Error.ParentNotAncestor;
    const chain = try history.chainOf(store, alloc, child_tip);
    errdefer alloc.free(chain);
    const at = history.indexOf(chain, fork) orelse return Error.ParentNotAncestor;
    const count = chain.len - at - 1;
    const out = try alloc.alloc(Oid, count);
    @memcpy(out, chain[at + 1 ..]);
    alloc.free(chain);
    return out;
}

pub fn settled(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8) bool {
    const parent_tip = history.tipOf(store, parent) catch return false;
    const fork = (forkPoint(store, alloc, child, parent, &.{}) catch return false) orelse return false;
    return fork.eql(parent_tip);
}

pub fn restack(store: *Store, alloc: std.mem.Allocator, child: []const u8, timestamp: i64) !history.Result {
    const parent = try parentOf(store, alloc, child);
    defer alloc.free(parent);
    const parent_tip = history.tipOf(store, parent) catch return Error.NoSuchBranch;
    const fork = try forkPoint(store, alloc, child, parent, &.{}) orelse return Error.ParentNotAncestor;
    if (fork.eql(parent_tip)) return history.Error.NothingToDo;
    return history.rebaseFrom(store, alloc, child, parent_tip, fork, timestamp, .record);
}

pub const Moved = struct {
    child: []u8,
    parent: []u8,
    prev: Oid,
    new: Oid,
    rewritten: usize,
    conflicts: [][]u8,
    reused: [][]u8,

    pub fn clean(self: Moved) bool {
        return self.conflicts.len == 0;
    }
};

fn freeMoved(alloc: std.mem.Allocator, items: []Moved) void {
    for (items) |m| {
        alloc.free(m.child);
        alloc.free(m.parent);
        for (m.conflicts) |p| alloc.free(p);
        alloc.free(m.conflicts);
        for (m.reused) |p| alloc.free(p);
        alloc.free(m.reused);
    }
    alloc.free(items);
}

pub const Report = struct {
    moved: []Moved,
    settled: [][]u8,

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        freeMoved(alloc, self.moved);
        freeNames(alloc, self.settled);
    }

    pub fn find(self: Report, branch: []const u8) ?Moved {
        for (self.moved) |m| if (std.mem.eql(u8, m.child, branch)) return m;
        return null;
    }
};

const Walk = struct {
    store: *Store,
    alloc: std.mem.Allocator,
    timestamp: i64,
    moves: std.ArrayList(oplog.Move),
    moved: std.ArrayList(Moved),
    settled: std.ArrayList([]u8),

    fn init(store: *Store, alloc: std.mem.Allocator, timestamp: i64) Walk {
        return .{
            .store = store,
            .alloc = alloc,
            .timestamp = timestamp,
            .moves = .empty,
            .moved = .empty,
            .settled = .empty,
        };
    }

    fn deinit(self: *Walk) void {
        self.moves.deinit(self.alloc);
        freeMoved(self.alloc, self.moved.items);
        self.moved = .empty;
        for (self.settled.items) |name| self.alloc.free(name);
        self.settled.deinit(self.alloc);
    }

    fn note(self: *Walk, child: []const u8, parent: []const u8, r: history.Result) !void {
        const child_name = try self.alloc.dupe(u8, child);
        errdefer self.alloc.free(child_name);
        const parent_name = try self.alloc.dupe(u8, parent);
        errdefer self.alloc.free(parent_name);
        try self.moved.append(self.alloc, .{
            .child = child_name,
            .parent = parent_name,
            .prev = r.prev,
            .new = r.new,
            .rewritten = r.rewritten,
            .conflicts = r.conflicts,
            .reused = r.reused,
        });
        try self.moves.append(self.alloc, .{ .branch = child_name, .prev = r.prev, .new = r.new });
    }

    fn children(self: *Walk, parent: []const u8, prior: []const Oid) !void {
        const kids = try childrenOf(self.store, self.alloc, parent);
        defer freeNames(self.alloc, kids);
        const parent_tip = history.tipOf(self.store, parent) catch return Error.NoSuchBranch;
        for (kids) |child| {
            const fork = try forkPoint(self.store, self.alloc, child, parent, prior) orelse return Error.ParentNotAncestor;
            if (fork.eql(parent_tip)) {
                try self.settled.append(self.alloc, try self.alloc.dupe(u8, child));
                try self.children(child, &.{});
                continue;
            }
            const r = try history.rebaseFrom(self.store, self.alloc, child, parent_tip, fork, self.timestamp, .quiet);
            errdefer r.deinit(self.alloc);
            try self.note(child, parent, r);
            if (!r.clean()) continue;
            try self.children(child, &.{r.prev});
        }
    }

    fn finish(self: *Walk) !Report {
        try oplog.recordStack(self.store, self.moves.items, self.timestamp);
        const moved = try self.moved.toOwnedSlice(self.alloc);
        errdefer freeMoved(self.alloc, moved);
        return .{ .moved = moved, .settled = try self.settled.toOwnedSlice(self.alloc) };
    }
};

pub fn restackAll(store: *Store, alloc: std.mem.Allocator, from: []const u8, timestamp: i64) !Report {
    var walk = Walk.init(store, alloc, timestamp);
    defer walk.deinit();
    try walk.children(from, &.{});
    return walk.finish();
}

pub fn squashLevel(store: *Store, alloc: std.mem.Allocator, branch: []const u8, message: []const u8, timestamp: i64) !Report {
    const parent = try parentOf(store, alloc, branch);
    defer alloc.free(parent);
    const tip = history.tipOf(store, branch) catch return Error.NoSuchBranch;
    const unique = try uniqueChanges(store, alloc, branch, parent);
    defer alloc.free(unique);
    if (unique.len < 2) return history.Error.NothingToDo;

    var walk = Walk.init(store, alloc, timestamp);
    defer walk.deinit();
    const r = try history.squashWith(store, alloc, branch, tip, unique.len, message, timestamp, .quiet);
    errdefer r.deinit(alloc);
    try walk.note(branch, parent, r);
    try walk.children(branch, &.{tip});
    return walk.finish();
}

const testing = std.testing;
const object = @import("object.zig");

fn commit(store: *Store, tree: Oid, parents: []const Oid, id: u8) !Oid {
    return store.writeChange(.{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{id} ** 16,
        .timestamp = 1_700_000_000 + @as(i64, id),
        .tz_offset_min = 0,
        .author = "T <t@example.com>",
        .message = "change",
    });
}

test "stack relations are canonical and reject cycles" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = try store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
    const base = try commit(&store, tree, &.{}, 1);
    try store.updateRef("main", base);
    try store.updateRef("api", base);
    try store.updateRef("ui", base);

    try setParent(&store, alloc, "api", "main");
    try setParent(&store, alloc, "ui", "api");
    try testing.expectError(Error.Cycle, setParent(&store, alloc, "main", "ui"));

    const parent = try parentOf(&store, alloc, "ui");
    defer alloc.free(parent);
    try testing.expectEqualStrings("api", parent);

    const children = try childrenOf(&store, alloc, "api");
    defer {
        for (children) |name| alloc.free(name);
        alloc.free(children);
    }
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings("ui", children[0]);
}

test "stack unique changes begin after the shared parent" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = try store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
    const base = try commit(&store, tree, &.{}, 1);
    const api = try commit(&store, tree, &.{base}, 2);
    const ui = try commit(&store, tree, &.{api}, 3);
    try store.updateRef("main", base);
    try store.updateRef("feature", ui);

    const unique = try uniqueChanges(&store, alloc, "feature", "main");
    defer alloc.free(unique);
    try testing.expectEqual(@as(usize, 2), unique.len);
    try testing.expect(unique[0].eql(api));
    try testing.expect(unique[1].eql(ui));
}

fn treeWith(store: *Store, alloc: std.mem.Allocator, paths: []const []const u8) !Oid {
    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer entries.deinit(alloc);
    for (paths) |path| {
        try entries.append(alloc, .{ .mode = .regular, .path = path, .blob = try store.writeFileContent(path) });
    }
    std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    return store.writeTree(.{ .entries = entries.items });
}

fn treePaths(store: *Store, alloc: std.mem.Allocator, change: Oid) ![][]u8 {
    const c = try store.readChange(change);
    defer object.freeChange(alloc, c);
    const tree = try store.readTree(c.tree);
    defer object.freeTree(alloc, tree);
    var out: std.ArrayList([]u8) = .empty;
    errdefer freeNames(alloc, out.items);
    for (tree.entries) |e| try out.append(alloc, try alloc.dupe(u8, e.path));
    return out.toOwnedSlice(alloc);
}

test "lineage runs base to tip and remove reconnects the levels" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = try store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
    const base = try commit(&store, tree, &.{}, 1);
    try store.updateRef("main", base);
    try store.updateRef("api", base);
    try store.updateRef("ui", base);
    try setParent(&store, alloc, "api", "main");
    try setParent(&store, alloc, "ui", "api");

    const names = try lineage(&store, alloc, "ui");
    defer freeNames(alloc, names);
    try testing.expectEqual(@as(usize, 3), names.len);
    try testing.expectEqualStrings("main", names[0]);
    try testing.expectEqualStrings("api", names[1]);
    try testing.expectEqualStrings("ui", names[2]);

    const root = try rootOf(&store, alloc, "ui");
    defer alloc.free(root);
    try testing.expectEqualStrings("main", root);

    try testing.expect(try remove(&store, alloc, "api"));
    const parent = try parentOf(&store, alloc, "ui");
    defer alloc.free(parent);
    try testing.expectEqualStrings("main", parent);
    try testing.expect(try remove(&store, alloc, "ui"));
    try testing.expect(!try remove(&store, alloc, "ui"));
    try testing.expectError(Error.NoParent, parentOf(&store, alloc, "ui"));
}

test "restackAll replays every level onto its moved parent as one reversible op" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const base = try commit(&store, try treeWith(&store, alloc, &.{"base"}), &.{}, 1);
    const a1 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1" }), &.{base}, 2);
    const a2 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1", "a2" }), &.{a1}, 3);
    const ui1 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1", "a2", "u1" }), &.{a2}, 4);
    const m2 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "m2" }), &.{base}, 5);
    try store.updateRef("main", m2);
    try store.updateRef("api", a2);
    try store.updateRef("ui", ui1);
    try setParent(&store, alloc, "api", "main");
    try setParent(&store, alloc, "ui", "api");
    try testing.expect(!settled(&store, alloc, "api", "main"));

    const report = try restackAll(&store, alloc, "main", 1_700_000_100);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), report.moved.len);
    try testing.expectEqualStrings("api", report.moved[0].child);
    try testing.expectEqualStrings("ui", report.moved[1].child);
    try testing.expect(report.moved[0].clean() and report.moved[1].clean());
    try testing.expect(settled(&store, alloc, "api", "main"));
    try testing.expect(settled(&store, alloc, "ui", "api"));

    const ui_paths = try treePaths(&store, alloc, try store.readRef("ui"));
    defer freeNames(alloc, ui_paths);
    try testing.expectEqual(@as(usize, 5), ui_paths.len);

    const last = (try oplog.lastOp(&store, alloc)).?;
    defer alloc.free(last.branch);
    try testing.expectEqual(oplog.OpKind.stack, last.kind);

    try oplog.undo(&store, null);
    try testing.expect((try store.readRef("api")).eql(a2));
    try testing.expect((try store.readRef("ui")).eql(ui1));
    try oplog.redo(&store, null);
    try testing.expect((try store.readRef("api")).eql(report.moved[0].new));
    try testing.expect((try store.readRef("ui")).eql(report.moved[1].new));
}

test "squashLevel collapses one level and replays only the children's own changes" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const base = try commit(&store, try treeWith(&store, alloc, &.{"base"}), &.{}, 1);
    const a1 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1" }), &.{base}, 2);
    const a2 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1", "a2" }), &.{a1}, 3);
    const ui1 = try commit(&store, try treeWith(&store, alloc, &.{ "base", "a1", "a2", "u1" }), &.{a2}, 4);
    try store.updateRef("main", base);
    try store.updateRef("api", a2);
    try store.updateRef("ui", ui1);
    try setParent(&store, alloc, "api", "main");
    try setParent(&store, alloc, "ui", "api");

    const report = try squashLevel(&store, alloc, "api", "one api change", 1_700_000_100);
    defer report.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), report.moved.len);

    const api_unique = try uniqueChanges(&store, alloc, "api", "main");
    defer alloc.free(api_unique);
    try testing.expectEqual(@as(usize, 1), api_unique.len);
    const ui_unique = try uniqueChanges(&store, alloc, "ui", "api");
    defer alloc.free(ui_unique);
    try testing.expectEqual(@as(usize, 1), ui_unique.len);

    const ui_paths = try treePaths(&store, alloc, try store.readRef("ui"));
    defer freeNames(alloc, ui_paths);
    try testing.expectEqual(@as(usize, 4), ui_paths.len);

    try testing.expectError(history.Error.NothingToDo, squashLevel(&store, alloc, "api", "", 1_700_000_200));
}
