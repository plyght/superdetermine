const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const history = @import("history.zig");
const replay = @import("replay.zig");
const oplog = @import("oplog.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const Error = error{
    SameBranch,
    SourceNotFound,
    DestinationNotFound,
    InvalidPosition,
    NothingToDo,
};

pub const Position = union(enum) {
    tip,
    root,
    after: Oid,
};

pub const Result = struct {
    source_prev: ?Oid,
    source_new: ?Oid,
    destination_prev: Oid,
    destination_new: Oid,
    rewritten: usize,
    conflicts: [][]u8,

    pub fn clean(self: Result) bool {
        return self.conflicts.len == 0;
    }

    pub fn deinit(self: Result, alloc: std.mem.Allocator) void {
        for (self.conflicts) |p| alloc.free(p);
        alloc.free(self.conflicts);
    }
};

const Builder = struct {
    store: *Store,
    alloc: std.mem.Allocator,
    tree: Oid,
    parent: ?Oid,
    conflicts: std.ArrayList([]u8) = .empty,
    count: usize = 0,

    fn deinit(self: *Builder) void {
        for (self.conflicts.items) |p| self.alloc.free(p);
        self.conflicts.deinit(self.alloc);
    }

    fn addConflicts(self: *Builder, r: replay.Result) !void {
        defer self.alloc.free(r.conflicts);
        self.tree = r.tree;
        for (r.conflicts) |p| {
            var found = false;
            for (self.conflicts.items) |held| {
                if (std.mem.eql(u8, held, p)) {
                    found = true;
                    break;
                }
            }
            if (found) {
                self.alloc.free(p);
            } else {
                try self.conflicts.append(self.alloc, p);
            }
        }
    }

    fn write(self: *Builder, source: object.Change) !Oid {
        var parent_buf: [1]Oid = undefined;
        const parents: []const Oid = if (self.parent) |p| blk: {
            parent_buf[0] = p;
            break :blk parent_buf[0..1];
        } else parent_buf[0..0];
        const written = try self.store.writeChange(.{
            .tree = self.tree,
            .parents = parents,
            .change_id = source.change_id,
            .timestamp = source.timestamp,
            .tz_offset_min = source.tz_offset_min,
            .author = source.author,
            .message = source.message,
        });
        self.parent = written;
        self.count += 1;
        return written;
    }

    fn replayOne(self: *Builder, source_oid: Oid) !Oid {
        const source = try self.store.readChange(source_oid);
        defer object.freeChange(self.alloc, source);
        if (source.parents.len > 1) return replay.Error.MergeChangeNotReplayable;
        try self.addConflicts(try replay.applyChange(self.store, self.alloc, self.tree, source_oid));
        return self.write(source);
    }
};

const Built = struct {
    tip: ?Oid,
    rewritten: usize,
    conflicts: [][]u8,

    fn deinit(self: Built, alloc: std.mem.Allocator) void {
        for (self.conflicts) |p| alloc.free(p);
        alloc.free(self.conflicts);
    }
};

fn treeOf(store: *Store, alloc: std.mem.Allocator, change_oid: Oid) !Oid {
    const change = try store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    return change.tree;
}

fn emptyTree(store: *Store) !Oid {
    return store.writeTree(.{ .entries = &.{} });
}

fn buildInserted(
    store: *Store,
    alloc: std.mem.Allocator,
    destination_tip: Oid,
    source_oid: Oid,
    position: Position,
) !Built {
    const chain = try history.chainOf(store, alloc, destination_tip);
    defer alloc.free(chain);

    const split: usize = switch (position) {
        .tip => chain.len,
        .root => 0,
        .after => |target| (history.indexOf(chain, target) orelse return Error.InvalidPosition) + 1,
    };
    const parent: ?Oid = if (split == 0) null else chain[split - 1];
    const base_tree = if (parent) |p| try treeOf(store, alloc, p) else try emptyTree(store);

    var builder: Builder = .{ .store = store, .alloc = alloc, .tree = base_tree, .parent = parent };
    defer builder.deinit();
    _ = try builder.replayOne(source_oid);
    for (chain[split..]) |descendant| _ = try builder.replayOne(descendant);
    return .{
        .tip = builder.parent,
        .rewritten = builder.count,
        .conflicts = try builder.conflicts.toOwnedSlice(alloc),
    };
}

fn buildRemoved(store: *Store, alloc: std.mem.Allocator, source_tip: Oid, source_oid: Oid) !Built {
    const chain = try history.chainOf(store, alloc, source_tip);
    defer alloc.free(chain);
    const index = history.indexOf(chain, source_oid) orelse return Error.SourceNotFound;
    const parent: ?Oid = if (index == 0) null else chain[index - 1];
    const base_tree = if (parent) |p| try treeOf(store, alloc, p) else try emptyTree(store);

    var builder: Builder = .{ .store = store, .alloc = alloc, .tree = base_tree, .parent = parent };
    defer builder.deinit();
    for (chain[index + 1 ..]) |descendant| _ = try builder.replayOne(descendant);
    return .{
        .tip = builder.parent,
        .rewritten = builder.count,
        .conflicts = try builder.conflicts.toOwnedSlice(alloc),
    };
}

fn deleteRef(store: *Store, branch: []const u8) !void {
    var buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "refs/heads/{s}", .{branch});
    store.root.deleteFile(store.io, path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn publish(store: *Store, branch: []const u8, target: ?Oid) !void {
    if (target) |value| return store.updateRef(branch, value);
    return deleteRef(store, branch);
}

fn appendConflicts(alloc: std.mem.Allocator, out: *std.ArrayList([]u8), paths: []const []const u8) !void {
    for (paths) |path| {
        var found = false;
        for (out.items) |held| {
            if (std.mem.eql(u8, held, path)) {
                found = true;
                break;
            }
        }
        if (!found) try out.append(alloc, try alloc.dupe(u8, path));
    }
}

pub fn take(
    store: *Store,
    alloc: std.mem.Allocator,
    source_oid: Oid,
    destination_branch: []const u8,
    position: Position,
    timestamp: i64,
) !Result {
    const source = store.readChange(source_oid) catch return Error.SourceNotFound;
    object.freeChange(alloc, source);
    const destination_prev = store.readRef(destination_branch) catch return Error.DestinationNotFound;
    const built = try buildInserted(store, alloc, destination_prev, source_oid, position);
    defer built.deinit(alloc);
    const destination_new = built.tip orelse return Error.NothingToDo;
    if (destination_new.eql(destination_prev)) return Error.NothingToDo;

    try store.updateRef(destination_branch, destination_new);
    errdefer store.updateRef(destination_branch, destination_prev) catch {};
    try oplog.record(store, .{
        .kind = .other,
        .branch = destination_branch,
        .prev = destination_prev,
        .new = destination_new,
        .timestamp = timestamp,
    });

    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }
    try appendConflicts(alloc, &conflicts, built.conflicts);
    return .{
        .source_prev = null,
        .source_new = null,
        .destination_prev = destination_prev,
        .destination_new = destination_new,
        .rewritten = built.rewritten,
        .conflicts = try conflicts.toOwnedSlice(alloc),
    };
}

pub fn move(
    store: *Store,
    alloc: std.mem.Allocator,
    source_branch: []const u8,
    source_oid: Oid,
    destination_branch: []const u8,
    position: Position,
    timestamp: i64,
) !Result {
    if (std.mem.eql(u8, source_branch, destination_branch)) return Error.SameBranch;
    const source_prev = store.readRef(source_branch) catch return Error.SourceNotFound;
    const destination_prev = store.readRef(destination_branch) catch return Error.DestinationNotFound;

    const destination = try buildInserted(store, alloc, destination_prev, source_oid, position);
    defer destination.deinit(alloc);
    const removed = try buildRemoved(store, alloc, source_prev, source_oid);
    defer removed.deinit(alloc);
    const destination_new = destination.tip orelse return Error.NothingToDo;

    try publish(store, source_branch, removed.tip);
    errdefer publish(store, source_branch, source_prev) catch {};
    try publish(store, destination_branch, destination_new);
    errdefer publish(store, destination_branch, destination_prev) catch {};

    try oplog.record(store, .{
        .kind = .other,
        .branch = source_branch,
        .prev = source_prev,
        .new = removed.tip orelse Oid.zero(),
        .timestamp = timestamp,
    });
    try oplog.record(store, .{
        .kind = .other,
        .branch = destination_branch,
        .prev = destination_prev,
        .new = destination_new,
        .timestamp = timestamp,
    });

    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }
    try appendConflicts(alloc, &conflicts, destination.conflicts);
    try appendConflicts(alloc, &conflicts, removed.conflicts);
    return .{
        .source_prev = source_prev,
        .source_new = removed.tip,
        .destination_prev = destination_prev,
        .destination_new = destination_new,
        .rewritten = destination.rewritten + removed.rewritten,
        .conflicts = try conflicts.toOwnedSlice(alloc),
    };
}

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    seq: u8 = 1,

    fn init() !Fixture {
        const tmp = std.testing.tmpDir(.{});
        return .{ .tmp = tmp, .store = try Store.init(std.testing.io, testing.allocator, tmp.dir) };
    }

    fn deinit(self: *Fixture) void {
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn commit(self: *Fixture, parent: ?Oid, paths: []const []const u8, message: []const u8) !Oid {
        var entries: std.ArrayList(object.TreeEntry) = .empty;
        defer entries.deinit(testing.allocator);
        for (paths) |path| {
            try entries.append(testing.allocator, .{
                .mode = .regular,
                .path = path,
                .blob = try self.store.writeFileContent(path),
            });
        }
        std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
        const tree = try self.store.writeTree(.{ .entries = entries.items });
        var parent_buf: [1]Oid = undefined;
        const parents: []const Oid = if (parent) |p| blk: {
            parent_buf[0] = p;
            break :blk parent_buf[0..1];
        } else parent_buf[0..0];
        const value = self.seq;
        self.seq += 1;
        return self.store.writeChange(.{
            .tree = tree,
            .parents = parents,
            .change_id = [_]u8{value} ** 16,
            .timestamp = value,
            .tz_offset_min = 0,
            .author = "T <t@e>",
            .message = message,
        });
    }

    fn hasPath(self: *Fixture, change_oid: Oid, path: []const u8) !bool {
        const change = try self.store.readChange(change_oid);
        defer object.freeChange(testing.allocator, change);
        const tree = try self.store.readTree(change.tree);
        defer object.freeTree(testing.allocator, tree);
        for (tree.entries) |entry| if (std.mem.eql(u8, entry.path, path)) return true;
        return false;
    }
};

test "take inserts a change and restacks destination descendants" {
    var f = try Fixture.init();
    defer f.deinit();
    const root = try f.commit(null, &.{"root"}, "root");
    const source = try f.commit(root, &.{ "root", "source" }, "source");
    const middle = try f.commit(root, &.{ "root", "middle" }, "middle");
    const tip = try f.commit(middle, &.{ "root", "middle", "tip" }, "tip");
    try f.store.updateRef("source", source);
    try f.store.updateRef("main", tip);

    const result = try take(&f.store, testing.allocator, source, "main", .{ .after = middle }, 10);
    defer result.deinit(testing.allocator);
    try testing.expect(result.clean());
    try testing.expectEqual(@as(usize, 2), result.rewritten);
    try testing.expect(try f.hasPath(result.destination_new, "source"));
    try testing.expect(try f.hasPath(result.destination_new, "tip"));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(tip));
}

test "move removes from source, restacks descendants, and preserves the change on destination" {
    var f = try Fixture.init();
    defer f.deinit();
    const root = try f.commit(null, &.{"root"}, "root");
    const source = try f.commit(root, &.{ "root", "moved" }, "moved");
    const source_tip = try f.commit(source, &.{ "root", "moved", "later" }, "later");
    const destination = try f.commit(root, &.{ "root", "destination" }, "destination");
    try f.store.updateRef("feature", source_tip);
    try f.store.updateRef("main", destination);

    const result = try move(&f.store, testing.allocator, "feature", source, "main", .tip, 20);
    defer result.deinit(testing.allocator);
    try testing.expect(result.clean());
    try testing.expect(try f.hasPath(result.destination_new, "moved"));
    try testing.expect(try f.hasPath(result.destination_new, "destination"));
    try testing.expect(result.source_new != null);
    try testing.expect(!(try f.hasPath(result.source_new.?, "moved")));
    try testing.expect(try f.hasPath(result.source_new.?, "later"));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(destination));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("feature")).eql(source_tip));
}

test "move refuses the same branch without changing it" {
    var f = try Fixture.init();
    defer f.deinit();
    const root = try f.commit(null, &.{"root"}, "root");
    try f.store.updateRef("main", root);
    try testing.expectError(Error.SameBranch, move(&f.store, testing.allocator, "main", root, "main", .tip, 1));
    try testing.expect((try f.store.readRef("main")).eql(root));
}
