const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store_mod = @import("store.zig");
const replay = @import("replay.zig");
const merge = @import("merge.zig");
const oplog = @import("oplog.zig");
const diff = @import("diff.zig");
const Oid = oid.Oid;
const Store = store_mod.Store;

pub const Error = error{
    UnbornBranch,
    NotAChange,
    NothingToDo,
    OutOfRange,
    NotAPermutation,
    NoSuchHunk,
    BinaryHasNoHunks,
    PathNotModified,
};

/// A hunk-level selection within one file: 1-based hunk numbers, counted the
/// way `sdt diff` prints them.
pub const HunkSpec = struct {
    path: []const u8,
    indices: []const usize,
};

pub const Result = struct {
    prev: Oid,
    new: Oid,
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

pub fn tipOf(store: *Store, branch: []const u8) !Oid {
    if (!store.refExists(branch)) return Error.UnbornBranch;
    return store.readRef(branch) catch Error.UnbornBranch;
}

/// Every change reachable from `tip` through first parents, oldest first.
pub fn chainOf(store: *Store, alloc: std.mem.Allocator, tip: Oid) ![]Oid {
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(alloc);

    var cur = tip;
    while (true) {
        try list.append(alloc, cur);
        const change = store.readChange(cur) catch return Error.NotAChange;
        defer object.freeChange(alloc, change);
        if (change.parents.len == 0) break;
        cur = change.parents[0];
    }
    const owned = try list.toOwnedSlice(alloc);
    std.mem.reverse(Oid, owned);
    return owned;
}

fn spanTo(store: *Store, alloc: std.mem.Allocator, tip: Oid, stop: ?Oid) ![]Oid {
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(alloc);

    var cur = tip;
    while (true) {
        if (stop) |s| {
            if (cur.eql(s)) break;
        }
        try list.append(alloc, cur);
        const change = store.readChange(cur) catch return Error.NotAChange;
        defer object.freeChange(alloc, change);
        if (change.parents.len == 0) break;
        cur = change.parents[0];
    }
    const owned = try list.toOwnedSlice(alloc);
    std.mem.reverse(Oid, owned);
    return owned;
}

/// Refuse before writing anything when a span contains a merge. `replay` would
/// refuse too, but only once objects had already been written.
fn requireLinear(store: *Store, alloc: std.mem.Allocator, span: []const Oid) !void {
    for (span) |c| {
        const change = store.readChange(c) catch return Error.NotAChange;
        defer object.freeChange(alloc, change);
        if (change.parents.len > 1) return replay.Error.MergeChangeNotReplayable;
    }
}

pub fn indexOf(chain: []const Oid, target: Oid) ?usize {
    for (chain, 0..) |c, i| {
        if (c.eql(target)) return i;
    }
    return null;
}

/// Map an address that resolved to a captured moment back onto a change, by id
/// prefix first and by tree identity second. Moments that no change corresponds
/// to are not addresses a branch can point at, and say so.
pub fn changeOfMoment(store: *Store, alloc: std.mem.Allocator, id: []const u8, full_tree: Oid) !Oid {
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);

    var heads = store.root.openDir(store.io, "refs/heads", .{ .iterate = true }) catch return Error.NotAChange;
    defer heads.close(store.io);
    var it = heads.iterate();
    while (try it.next(store.io)) |entry| {
        if (entry.kind != .file) continue;
        const tip = store.readRef(entry.name) catch continue;
        try stack.append(alloc, tip);
    }

    var seen = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer seen.deinit();

    var by_tree: ?Oid = null;
    while (stack.pop()) |cur| {
        if (cur.isZero()) continue;
        if ((try seen.getOrPut(cur.bytes)).found_existing) continue;
        if (id.len != 0 and id.len <= Oid.len and std.mem.eql(u8, cur.bytes[0..id.len], id)) return cur;
        const change = store.readChange(cur) catch continue;
        defer object.freeChange(alloc, change);
        if (by_tree == null and change.tree.eql(full_tree)) by_tree = cur;
        for (change.parents) |p| try stack.append(alloc, p);
    }
    return by_tree orelse Error.NotAChange;
}

const Meta = struct {
    timestamp: i64,
    tz_offset_min: i32,
    author: []const u8,
};

fn metaOf(change: object.Change) Meta {
    return .{
        .timestamp = change.timestamp,
        .tz_offset_min = change.tz_offset_min,
        .author = change.author,
    };
}

const Rewriter = struct {
    store: *Store,
    alloc: std.mem.Allocator,
    tree: Oid,
    parent: ?Oid,
    conflicts: std.ArrayList([]u8),
    count: usize,

    fn init(store: *Store, alloc: std.mem.Allocator, base_tree: Oid, parent: ?Oid) Rewriter {
        return .{
            .store = store,
            .alloc = alloc,
            .tree = base_tree,
            .parent = parent,
            .conflicts = .empty,
            .count = 0,
        };
    }

    fn deinit(self: *Rewriter) void {
        for (self.conflicts.items) |p| self.alloc.free(p);
        self.conflicts.deinit(self.alloc);
    }

    fn take(self: *Rewriter, r: replay.Result) !void {
        defer self.alloc.free(r.conflicts);
        self.tree = r.tree;
        for (r.conflicts) |p| {
            errdefer self.alloc.free(p);
            if (self.holds(p)) {
                self.alloc.free(p);
                continue;
            }
            try self.conflicts.append(self.alloc, p);
        }
    }

    fn holds(self: *Rewriter, path: []const u8) bool {
        for (self.conflicts.items) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    fn write(
        self: *Rewriter,
        meta: Meta,
        tree: Oid,
        change_id: object.ChangeId,
        message: []const u8,
    ) !Oid {
        var buf: [1]Oid = undefined;
        var parents: []const Oid = buf[0..0];
        if (self.parent) |p| {
            buf[0] = p;
            parents = buf[0..1];
        }
        const written = try self.store.writeChange(.{
            .tree = tree,
            .parents = parents,
            .change_id = change_id,
            .timestamp = meta.timestamp,
            .tz_offset_min = meta.tz_offset_min,
            .author = meta.author,
            .message = message,
        });
        self.parent = written;
        self.count += 1;
        return written;
    }

    /// Replay one change onto the running tree, keeping its identity: a rebased
    /// change is the same change on a new base, so its change_id travels with it.
    fn push(self: *Rewriter, source_oid: Oid) !Oid {
        const source = self.store.readChange(source_oid) catch return Error.NotAChange;
        defer object.freeChange(self.alloc, source);
        const r = try replay.applyChange(self.store, self.alloc, self.tree, source_oid);
        try self.take(r);
        return self.write(metaOf(source), self.tree, source.change_id, source.message);
    }

    fn pushAll(self: *Rewriter, sources: []const Oid) !void {
        for (sources) |s| _ = try self.push(s);
    }

    fn finish(self: *Rewriter, branch: []const u8, prev: Oid, timestamp: i64) !Result {
        const new = self.parent orelse return Error.NothingToDo;
        try self.store.updateRef(branch, new);
        try oplog.record(self.store, .{
            .kind = .other,
            .branch = branch,
            .prev = prev,
            .new = new,
            .timestamp = timestamp,
        });
        return .{
            .prev = prev,
            .new = new,
            .rewritten = self.count,
            .conflicts = try self.conflicts.toOwnedSlice(self.alloc),
        };
    }
};

fn derivedChangeId(tree: Oid, timestamp: i64) object.ChangeId {
    var seed: [Oid.len + 8]u8 = undefined;
    @memcpy(seed[0..Oid.len], &tree.bytes);
    std.mem.writeInt(u64, seed[Oid.len..][0..8], @bitCast(timestamp), .big);
    var digest: [Oid.len]u8 = undefined;
    oid.Blake3.hash(&seed, &digest, .{});
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, digest[0..16]);
    return change_id;
}

/// Move a branch tip to any change, forwards or backwards. This is the primitive
/// every rewriter needs and the one the ref layer never exposed.
pub fn point(store: *Store, alloc: std.mem.Allocator, branch: []const u8, target: Oid, timestamp: i64) !Result {
    const change = store.readChange(target) catch return Error.NotAChange;
    object.freeChange(alloc, change);

    const prev = store.readRef(branch) catch Oid.zero();
    if (prev.eql(target)) return Error.NothingToDo;

    try store.updateRef(branch, target);
    try oplog.record(store, .{
        .kind = .other,
        .branch = branch,
        .prev = prev,
        .new = target,
        .timestamp = timestamp,
    });
    return .{ .prev = prev, .new = target, .rewritten = 0, .conflicts = try alloc.alloc([]u8, 0) };
}

pub fn rebase(store: *Store, alloc: std.mem.Allocator, branch: []const u8, onto: Oid, timestamp: i64) !Result {
    const tip = try tipOf(store, branch);
    if (tip.eql(onto)) return Error.NothingToDo;

    const onto_change = store.readChange(onto) catch return Error.NotAChange;
    defer object.freeChange(alloc, onto_change);

    const ancestor = merge.commonAncestor(store, alloc, tip, onto) catch null;
    if (ancestor) |a| {
        if (a.eql(onto)) return Error.NothingToDo;
        if (a.eql(tip)) return point(store, alloc, branch, onto, timestamp);
    }

    const span = try spanTo(store, alloc, tip, ancestor);
    defer alloc.free(span);
    if (span.len == 0) return Error.NothingToDo;
    try requireLinear(store, alloc, span);

    var rw = Rewriter.init(store, alloc, onto_change.tree, onto);
    defer rw.deinit();
    try rw.pushAll(span);
    return rw.finish(branch, tip, timestamp);
}

pub fn squash(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []const u8,
    end: Oid,
    count: usize,
    message: []const u8,
    timestamp: i64,
) !Result {
    if (count < 2) return Error.OutOfRange;
    const tip = try tipOf(store, branch);

    const chain = try chainOf(store, alloc, tip);
    defer alloc.free(chain);

    const end_idx = indexOf(chain, end) orelse return Error.NotAChange;
    if (end_idx + 1 < count) return Error.OutOfRange;
    const start_idx = end_idx + 1 - count;

    const span = chain[start_idx .. end_idx + 1];
    try requireLinear(store, alloc, span);

    const first = store.readChange(span[0]) catch return Error.NotAChange;
    defer object.freeChange(alloc, first);
    const last = store.readChange(end) catch return Error.NotAChange;
    defer object.freeChange(alloc, last);

    const base_tree = try replay.parentTreeOf(store, alloc, first);
    const parent: ?Oid = if (start_idx == 0) null else chain[start_idx - 1];

    var rw = Rewriter.init(store, alloc, base_tree, parent);
    defer rw.deinit();

    const collapsed = try replay.applyTreeDelta(store, alloc, base_tree, last.tree, base_tree);
    try rw.take(collapsed);

    const text = if (message.len != 0) message else first.message;
    const meta = Meta{
        .timestamp = last.timestamp,
        .tz_offset_min = last.tz_offset_min,
        .author = first.author,
    };
    _ = try rw.write(meta, rw.tree, first.change_id, text);

    try rw.pushAll(chain[end_idx + 1 ..]);
    return rw.finish(branch, tip, timestamp);
}

fn pathSelected(paths: []const []const u8, p: []const u8) bool {
    for (paths) |sel| {
        if (sel.len == 0) continue;
        if (std.mem.eql(u8, sel, p)) return true;
        if (p.len > sel.len and std.mem.startsWith(u8, p, sel) and p[sel.len] == '/') return true;
    }
    return false;
}

fn scopedTree(
    store: *Store,
    alloc: std.mem.Allocator,
    parent_tree: Oid,
    change_tree: Oid,
    paths: []const []const u8,
) !Oid {
    const from = try store.readTree(parent_tree);
    defer object.freeTree(alloc, from);
    const to = try store.readTree(change_tree);
    defer object.freeTree(alloc, to);

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer entries.deinit(alloc);

    for (from.entries) |e| {
        if (pathSelected(paths, e.path)) continue;
        try entries.append(alloc, e);
    }
    for (to.entries) |e| {
        if (!pathSelected(paths, e.path)) continue;
        try entries.append(alloc, e);
    }

    std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    return store.writeTree(.{ .entries = entries.items });
}

fn entryFor(entries: []const object.TreeEntry, path: []const u8) ?object.TreeEntry {
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e;
    }
    return null;
}

/// The parent tree with only the named hunks of the named files applied. Hunks
/// exist only where a file was modified in place, so an added, deleted or
/// binary path is refused rather than half-carried.
fn hunkTree(
    store: *Store,
    alloc: std.mem.Allocator,
    parent_tree: Oid,
    change_tree: Oid,
    specs: []const HunkSpec,
) !Oid {
    const from = try store.readTree(parent_tree);
    defer object.freeTree(alloc, from);
    const to = try store.readTree(change_tree);
    defer object.freeTree(alloc, to);

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer entries.deinit(alloc);
    try entries.appendSlice(alloc, from.entries);

    for (specs) |spec| {
        if (spec.indices.len == 0) return Error.OutOfRange;
        const old_entry = entryFor(from.entries, spec.path) orelse return Error.PathNotModified;
        const new_entry = entryFor(to.entries, spec.path) orelse return Error.PathNotModified;
        if (old_entry.blob.eql(new_entry.blob)) return Error.PathNotModified;

        const old_data = try store.readFileContent(old_entry.blob);
        defer alloc.free(old_data);
        const new_data = try store.readFileContent(new_entry.blob);
        defer alloc.free(new_data);

        const partial = diff.applyHunks(alloc, old_data, new_data, spec.indices) catch |e| switch (e) {
            diff.HunkError.BinaryHasNoHunks => return Error.BinaryHasNoHunks,
            diff.HunkError.NoSuchHunk => return Error.NoSuchHunk,
            else => return e,
        };
        defer alloc.free(partial);

        const blob = try store.writeFileContent(partial);
        for (entries.items) |*e| {
            if (!std.mem.eql(u8, e.path, spec.path)) continue;
            e.mode = new_entry.mode;
            e.blob = blob;
            break;
        }
    }

    std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    return store.writeTree(.{ .entries = entries.items });
}

/// Which piece of a change to lift out: whole files, or hunks within files.
pub const Selection = union(enum) {
    paths: []const []const u8,
    hunks: []const HunkSpec,
};

fn selectedTree(
    store: *Store,
    alloc: std.mem.Allocator,
    parent_tree: Oid,
    change_tree: Oid,
    selection: Selection,
) !Oid {
    return switch (selection) {
        .paths => |p| scopedTree(store, alloc, parent_tree, change_tree, p),
        .hunks => |h| hunkTree(store, alloc, parent_tree, change_tree, h),
    };
}

/// Split one change into two by path. The remainder keeps the original
/// change_id, because it is the piece that still reaches the original tree; the
/// extracted piece is new and gets a derived id.
pub fn split(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []const u8,
    target: Oid,
    paths: []const []const u8,
    message: []const u8,
    timestamp: i64,
) !Result {
    if (paths.len == 0) return Error.OutOfRange;
    return splitBy(store, alloc, branch, target, .{ .paths = paths }, message, timestamp);
}

/// Split one change into two by hunk. Same identity rule as the path form: the
/// remainder keeps the change_id because it still reaches the original tree.
pub fn splitHunks(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []const u8,
    target: Oid,
    specs: []const HunkSpec,
    message: []const u8,
    timestamp: i64,
) !Result {
    if (specs.len == 0) return Error.OutOfRange;
    return splitBy(store, alloc, branch, target, .{ .hunks = specs }, message, timestamp);
}

fn splitBy(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []const u8,
    target: Oid,
    selection: Selection,
    message: []const u8,
    timestamp: i64,
) !Result {
    const tip = try tipOf(store, branch);

    const chain = try chainOf(store, alloc, tip);
    defer alloc.free(chain);

    const idx = indexOf(chain, target) orelse return Error.NotAChange;
    try requireLinear(store, alloc, chain[idx .. idx + 1]);

    const change = store.readChange(target) catch return Error.NotAChange;
    defer object.freeChange(alloc, change);

    const parent_tree = try replay.parentTreeOf(store, alloc, change);
    const partial = try selectedTree(store, alloc, parent_tree, change.tree, selection);
    if (partial.eql(parent_tree)) return Error.NothingToDo;
    if (partial.eql(change.tree)) return Error.NothingToDo;

    const parent: ?Oid = if (idx == 0) null else chain[idx - 1];

    var rw = Rewriter.init(store, alloc, parent_tree, parent);
    defer rw.deinit();

    const extracted = try replay.applyTreeDelta(store, alloc, parent_tree, partial, parent_tree);
    try rw.take(extracted);

    const text = if (message.len != 0) message else change.message;
    _ = try rw.write(metaOf(change), rw.tree, derivedChangeId(rw.tree, change.timestamp), text);

    const rest = try replay.applyTreeDelta(store, alloc, partial, change.tree, rw.tree);
    try rw.take(rest);
    _ = try rw.write(metaOf(change), rw.tree, change.change_id, change.message);

    try rw.pushAll(chain[idx + 1 ..]);
    return rw.finish(branch, tip, timestamp);
}

/// Reorder the last `order.len` changes. `order` is a permutation of 1..n where
/// 1 is the oldest change in the span.
pub fn reorder(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []const u8,
    order: []const usize,
    timestamp: i64,
) !Result {
    if (order.len < 2) return Error.OutOfRange;
    const tip = try tipOf(store, branch);

    const chain = try chainOf(store, alloc, tip);
    defer alloc.free(chain);
    if (chain.len < order.len) return Error.OutOfRange;

    const seen = try alloc.alloc(bool, order.len);
    defer alloc.free(seen);
    @memset(seen, false);
    for (order) |p| {
        if (p == 0 or p > order.len) return Error.NotAPermutation;
        if (seen[p - 1]) return Error.NotAPermutation;
        seen[p - 1] = true;
    }

    const start_idx = chain.len - order.len;
    const span = chain[start_idx..];
    try requireLinear(store, alloc, span);

    const first = store.readChange(span[0]) catch return Error.NotAChange;
    defer object.freeChange(alloc, first);
    const base_tree = try replay.parentTreeOf(store, alloc, first);
    const parent: ?Oid = if (start_idx == 0) null else chain[start_idx - 1];

    var rw = Rewriter.init(store, alloc, base_tree, parent);
    defer rw.deinit();
    for (order) |p| _ = try rw.push(span[p - 1]);
    return rw.finish(branch, tip, timestamp);
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    seq: u8,

    fn init() !Fixture {
        const tmp = std.testing.tmpDir(.{});
        const store = try Store.init(std.testing.io, testing.allocator, tmp.dir);
        return .{ .tmp = tmp, .store = store, .seq = 1 };
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

    fn commit(self: *Fixture, t: Oid, parents: []const Oid, message: []const u8) !Oid {
        const id = self.seq;
        self.seq += 1;
        return self.store.writeChange(.{
            .tree = t,
            .parents = parents,
            .change_id = [_]u8{id} ** 16,
            .timestamp = 1_700_000_000 + @as(i64, id),
            .tz_offset_min = 0,
            .author = "T <t@e.com>",
            .message = message,
        });
    }

    fn changeIdOf(self: *Fixture, c: Oid) !object.ChangeId {
        const change = try self.store.readChange(c);
        defer object.freeChange(testing.allocator, change);
        return change.change_id;
    }

    fn messageOf(self: *Fixture, c: Oid) ![]u8 {
        const change = try self.store.readChange(c);
        defer object.freeChange(testing.allocator, change);
        return testing.allocator.dupe(u8, change.message);
    }

    fn text(self: *Fixture, t: Oid, path: []const u8) ![]u8 {
        const loaded = try self.store.readTree(t);
        defer object.freeTree(testing.allocator, loaded);
        for (loaded.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return self.store.readFileContent(e.blob);
        }
        return error.MissingPath;
    }

    fn has(self: *Fixture, t: Oid, path: []const u8) !bool {
        const loaded = try self.store.readTree(t);
        defer object.freeTree(testing.allocator, loaded);
        for (loaded.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return true;
        }
        return false;
    }

    fn treeOf(self: *Fixture, c: Oid) !Oid {
        const change = try self.store.readChange(c);
        defer object.freeChange(testing.allocator, change);
        return change.tree;
    }

    fn chain(self: *Fixture, branch: []const u8) ![]Oid {
        const tip = try self.store.readRef(branch);
        return chainOf(&self.store, testing.allocator, tip);
    }
};

test "point moves a branch tip backwards and undo puts it back" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "zero");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n") }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "one");

    try f.store.updateRef("main", c1);

    const r = try point(&f.store, alloc, "main", c0, 5);
    defer r.deinit(alloc);
    try testing.expect(r.new.eql(c0));
    try testing.expect((try f.store.readRef("main")).eql(c0));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c1));
}

test "point refuses an address that is not a change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") }};
    const t0 = try f.tree(&e0);
    const c0 = try f.commit(t0, &.{}, "zero");
    try f.store.updateRef("main", c0);

    try testing.expectError(Error.NotAChange, point(&f.store, alloc, "main", t0, 5));
    try testing.expectError(Error.NothingToDo, point(&f.store, alloc, "main", c0, 5));
}

test "rebase replays a branch onto a new base and keeps change ids" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    const shared = try f.blob("shared\n");

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "base", .blob = shared }};
    const root = try f.commit(try f.tree(&e0), &.{}, "root");

    var ea = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = shared },
        .{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") },
    };
    const a1 = try f.commit(try f.tree(&ea), &.{root}, "add a");
    var ea2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = shared },
        .{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") },
        .{ .mode = .executable, .path = "a2", .blob = try f.blob("a2\n") },
    };
    const a2 = try f.commit(try f.tree(&ea2), &.{a1}, "add a2");

    var eb = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = shared },
        .{ .mode = .regular, .path = "b", .blob = try f.blob("b\n") },
    };
    const b1 = try f.commit(try f.tree(&eb), &.{root}, "add b");

    try f.store.updateRef("feature", a2);
    try f.store.updateRef("main", b1);

    const id_a1 = try f.changeIdOf(a1);
    const id_a2 = try f.changeIdOf(a2);

    const r = try rebase(&f.store, alloc, "feature", b1, 9);
    defer r.deinit(alloc);
    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 2), r.rewritten);

    const chain = try f.chain("feature");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 4), chain.len);
    try testing.expect(chain[0].eql(root));
    try testing.expect(chain[1].eql(b1));

    const got_a1 = try f.changeIdOf(chain[2]);
    try testing.expectEqualSlices(u8, &id_a1, &got_a1);

    const new_tip_tree = try f.treeOf(r.new);
    try testing.expect(try f.has(new_tip_tree, "a"));
    try testing.expect(try f.has(new_tip_tree, "a2"));
    try testing.expect(try f.has(new_tip_tree, "b"));

    const tip_id = try f.changeIdOf(r.new);
    try testing.expectEqualSlices(u8, &id_a2, &tip_id);

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("feature")).eql(a2));
}

test "rebase refuses to rewrite across a merge change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("f\n") }};
    const t = try f.tree(&e0);
    const root = try f.commit(t, &.{}, "root");
    const side = try f.commit(t, &.{root}, "side");
    const mine = try f.commit(t, &.{root}, "mine");
    const merged = try f.commit(t, &.{ mine, side }, "merged");

    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "g", .blob = try f.blob("g\n") }};
    const onto = try f.commit(try f.tree(&e1), &.{}, "unrelated");

    try f.store.updateRef("main", merged);
    try f.store.updateRef("other", onto);

    try testing.expectError(
        replay.Error.MergeChangeNotReplayable,
        rebase(&f.store, alloc, "main", onto, 3),
    );
    try testing.expect((try f.store.readRef("main")).eql(merged));
}

test "rebase surfaces conflicts instead of picking a side" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("a\nb\nc\n") }};
    const root = try f.commit(try f.tree(&e0), &.{}, "root");

    var em = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("X\nb\nc\n") }};
    const mine = try f.commit(try f.tree(&em), &.{root}, "mine");

    var et = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("Y\nb\nc\n") }};
    const theirs = try f.commit(try f.tree(&et), &.{root}, "theirs");

    try f.store.updateRef("feature", mine);
    try f.store.updateRef("main", theirs);

    const r = try rebase(&f.store, alloc, "feature", theirs, 4);
    defer r.deinit(alloc);
    try testing.expect(!r.clean());
    try testing.expectEqual(@as(usize, 1), r.conflicts.len);
    try testing.expectEqualStrings("f", r.conflicts[0]);

    const got = try f.text(try f.treeOf(r.new), "f");
    defer alloc.free(got);
    try testing.expect(std.mem.indexOf(u8, got, "X") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Y") != null);
}

test "squash collapses two adjacent changes into one" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "log", .blob = try f.blob("one\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "one");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "log", .blob = try f.blob("one\ntwo\n") }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "two");
    var e2 = [_]object.TreeEntry{.{ .mode = .regular, .path = "log", .blob = try f.blob("one\ntwo\nthree\n") }};
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "three");

    try f.store.updateRef("main", c2);
    const id_c1 = try f.changeIdOf(c1);

    const r = try squash(&f.store, alloc, "main", c2, 2, "one and two and three", 7);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 2), chain.len);
    try testing.expect(chain[0].eql(c0));

    const msg = try f.messageOf(chain[1]);
    defer alloc.free(msg);
    try testing.expectEqualStrings("one and two and three", msg);

    const kept = try f.changeIdOf(chain[1]);
    try testing.expectEqualSlices(u8, &id_c1, &kept);

    const got = try f.text(try f.treeOf(chain[1]), "log");
    defer alloc.free(got);
    try testing.expectEqualStrings("one\ntwo\nthree\n", got);

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));
}

test "squash of a non-top span rewrites the descendants" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "zero");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n") }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "one");
    var e2 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n2\n") }};
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "two");
    var e3 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "f", .blob = try f.blob("0\n1\n2\n") },
        .{ .mode = .regular, .path = "g", .blob = try f.blob("g\n") },
    };
    const c3 = try f.commit(try f.tree(&e3), &.{c2}, "three");

    try f.store.updateRef("main", c3);

    const r = try squash(&f.store, alloc, "main", c2, 2, "", 8);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);

    const tip_tree = try f.treeOf(r.new);
    const got = try f.text(tip_tree, "f");
    defer alloc.free(got);
    try testing.expectEqualStrings("0\n1\n2\n", got);
    try testing.expect(try f.has(tip_tree, "g"));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c3));
}

test "split separates a non-top change by path and rewrites its descendant" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "keep", .blob = try f.blob("keep\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");

    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep", .blob = try f.blob("keep\n") },
        .{ .mode = .regular, .path = "src/a.zig", .blob = try f.blob("a\n") },
        .{ .mode = .regular, .path = "docs/b.md", .blob = try f.blob("b\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "add code and docs");

    var e2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep", .blob = try f.blob("keep\n") },
        .{ .mode = .regular, .path = "src/a.zig", .blob = try f.blob("a\n") },
        .{ .mode = .regular, .path = "docs/b.md", .blob = try f.blob("b\n") },
        .{ .mode = .regular, .path = "later", .blob = try f.blob("later\n") },
    };
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "later work");

    try f.store.updateRef("main", c2);
    const id_c1 = try f.changeIdOf(c1);

    const paths = [_][]const u8{"docs"};
    const r = try split(&f.store, alloc, "main", c1, &paths, "docs only", 11);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 4), chain.len);
    try testing.expect(chain[0].eql(c0));

    const first_tree = try f.treeOf(chain[1]);
    try testing.expect(try f.has(first_tree, "docs/b.md"));
    try testing.expect(!(try f.has(first_tree, "src/a.zig")));

    const second_tree = try f.treeOf(chain[2]);
    try testing.expect(try f.has(second_tree, "docs/b.md"));
    try testing.expect(try f.has(second_tree, "src/a.zig"));
    try testing.expect(second_tree.eql(try f.treeOf(c1)));

    const first_msg = try f.messageOf(chain[1]);
    defer alloc.free(first_msg);
    try testing.expectEqualStrings("docs only", first_msg);

    const kept = try f.changeIdOf(chain[2]);
    try testing.expectEqualSlices(u8, &id_c1, &kept);

    const tip_tree = try f.treeOf(chain[3]);
    try testing.expect(try f.has(tip_tree, "later"));
    try testing.expect(tip_tree.eql(try f.treeOf(c2)));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));
}

test "split refuses when the paths cover none or all of the change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "keep", .blob = try f.blob("keep\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep", .blob = try f.blob("keep\n") },
        .{ .mode = .regular, .path = "only", .blob = try f.blob("only\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "add only");
    try f.store.updateRef("main", c1);

    const nothing = [_][]const u8{"absent"};
    try testing.expectError(Error.NothingToDo, split(&f.store, alloc, "main", c1, &nothing, "", 1));

    const everything = [_][]const u8{"only"};
    try testing.expectError(Error.NothingToDo, split(&f.store, alloc, "main", c1, &everything, "", 1));
}

const wide_old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
const wide_new = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10a\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20a\n";
const only_mid = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10a\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";

test "split by hunk lifts one hunk of three out of a single file" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_old) }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_new) }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "three edits");

    try f.store.updateRef("main", c1);
    const id_c1 = try f.changeIdOf(c1);

    const indices = [_]usize{2};
    const specs = [_]HunkSpec{.{ .path = "app.zig", .indices = &indices }};
    const r = try splitHunks(&f.store, alloc, "main", c1, &specs, "just the middle", 21);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);
    try testing.expect(chain[0].eql(c0));

    const first = try f.text(try f.treeOf(chain[1]), "app.zig");
    defer alloc.free(first);
    try testing.expectEqualStrings(only_mid, first);

    const msg = try f.messageOf(chain[1]);
    defer alloc.free(msg);
    try testing.expectEqualStrings("just the middle", msg);

    try testing.expect((try f.treeOf(chain[2])).eql(try f.treeOf(c1)));
    const kept = try f.changeIdOf(chain[2]);
    try testing.expectEqualSlices(u8, &id_c1, &kept);

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c1));
}

test "split by hunk spans two files in one selection" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.zig", .blob = try f.blob(wide_old) },
        .{ .mode = .regular, .path = "b.zig", .blob = try f.blob("x\ny\nz\n") },
    };
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.zig", .blob = try f.blob(wide_new) },
        .{ .mode = .regular, .path = "b.zig", .blob = try f.blob("x\nY\nz\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "both files");

    try f.store.updateRef("main", c1);

    const a_idx = [_]usize{ 1, 3 };
    const b_idx = [_]usize{1};
    const specs = [_]HunkSpec{
        .{ .path = "a.zig", .indices = &a_idx },
        .{ .path = "b.zig", .indices = &b_idx },
    };
    const r = try splitHunks(&f.store, alloc, "main", c1, &specs, "edges", 22);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);

    const first_tree = try f.treeOf(chain[1]);
    const a_text = try f.text(first_tree, "a.zig");
    defer alloc.free(a_text);
    try testing.expect(std.mem.indexOf(u8, a_text, "1a\n") != null);
    try testing.expect(std.mem.indexOf(u8, a_text, "20a\n") != null);
    try testing.expect(std.mem.indexOf(u8, a_text, "10a\n") == null);

    const b_text = try f.text(first_tree, "b.zig");
    defer alloc.free(b_text);
    try testing.expectEqualStrings("x\nY\nz\n", b_text);

    try testing.expect((try f.treeOf(chain[2])).eql(try f.treeOf(c1)));
}

test "identity: a hunk split's two halves reproduce the original tree exactly" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "src/validate.zig", .blob = try f.blob(wide_old) },
        .{ .mode = .regular, .path = "src/log.zig", .blob = try f.blob("a\nb\nc\nd\ne\nf\ng\nh\ni\n") },
        .{ .mode = .regular, .path = "untouched", .blob = try f.blob("intact\n") },
    };
    const t0 = try f.tree(&e0);
    const c0 = try f.commit(t0, &.{}, "root");

    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "src/validate.zig", .blob = try f.blob(wide_new) },
        .{ .mode = .regular, .path = "src/log.zig", .blob = try f.blob("a\nb\nc\nd\nE\nf\ng\nh\ni\n") },
        .{ .mode = .regular, .path = "untouched", .blob = try f.blob("intact\n") },
    };
    const t1 = try f.tree(&e1);
    const c1 = try f.commit(t1, &.{c0}, "validation and logging");

    try f.store.updateRef("main", c1);

    const idx = [_]usize{ 1, 2 };
    const specs = [_]HunkSpec{.{ .path = "src/validate.zig", .indices = &idx }};
    const r = try splitHunks(&f.store, alloc, "main", c1, &specs, "validation only", 23);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 3), chain.len);

    const extracted = try f.treeOf(chain[1]);
    const remainder = try f.treeOf(chain[2]);
    try testing.expect(!extracted.eql(t0));
    try testing.expect(!extracted.eql(t1));
    try testing.expect(remainder.eql(t1));

    const logging = try f.text(extracted, "src/log.zig");
    defer alloc.free(logging);
    try testing.expectEqualStrings("a\nb\nc\nd\ne\nf\ng\nh\ni\n", logging);

    const replayed = try replay.applyTreeDelta(&f.store, alloc, extracted, t1, extracted);
    defer replay.freeResult(alloc, replayed);
    try testing.expect(replayed.clean());
    try testing.expect(replayed.tree.eql(t1));
}

test "split by hunk of a non-top change keeps the descendants" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_old) }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_new) }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "three edits");
    var e2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_new) },
        .{ .mode = .regular, .path = "later", .blob = try f.blob("later\n") },
    };
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "later work");

    try f.store.updateRef("main", c2);

    const indices = [_]usize{2};
    const specs = [_]HunkSpec{.{ .path = "app.zig", .indices = &indices }};
    const r = try splitHunks(&f.store, alloc, "main", c1, &specs, "middle first", 24);
    defer r.deinit(alloc);
    try testing.expect(r.clean());

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 4), chain.len);
    try testing.expect(chain[0].eql(c0));

    const first = try f.text(try f.treeOf(chain[1]), "app.zig");
    defer alloc.free(first);
    try testing.expectEqualStrings(only_mid, first);
    try testing.expect(!(try f.has(try f.treeOf(chain[1]), "later")));

    try testing.expect((try f.treeOf(chain[2])).eql(try f.treeOf(c1)));

    const tip_tree = try f.treeOf(chain[3]);
    try testing.expect(tip_tree.eql(try f.treeOf(c2)));
    try testing.expect(try f.has(tip_tree, "later"));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));
}

test "split by hunk refuses an empty, a total, and an impossible selection" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_old) },
        .{ .mode = .regular, .path = "bin", .blob = try f.blob("head\x00old\n") },
    };
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_new) },
        .{ .mode = .regular, .path = "bin", .blob = try f.blob("head\x00new\n") },
        .{ .mode = .regular, .path = "fresh", .blob = try f.blob("fresh\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "everything");
    try f.store.updateRef("main", c1);

    const none = [_]HunkSpec{};
    try testing.expectError(Error.OutOfRange, splitHunks(&f.store, alloc, "main", c1, &none, "", 1));

    const no_indices = [_]usize{};
    const empty_spec = [_]HunkSpec{.{ .path = "app.zig", .indices = &no_indices }};
    try testing.expectError(Error.OutOfRange, splitHunks(&f.store, alloc, "main", c1, &empty_spec, "", 1));

    const bad_idx = [_]usize{4};
    const bad = [_]HunkSpec{.{ .path = "app.zig", .indices = &bad_idx }};
    try testing.expectError(Error.NoSuchHunk, splitHunks(&f.store, alloc, "main", c1, &bad, "", 1));

    const bin_idx = [_]usize{1};
    const binary = [_]HunkSpec{.{ .path = "bin", .indices = &bin_idx }};
    try testing.expectError(Error.BinaryHasNoHunks, splitHunks(&f.store, alloc, "main", c1, &binary, "", 1));

    const added = [_]HunkSpec{.{ .path = "fresh", .indices = &bin_idx }};
    try testing.expectError(Error.PathNotModified, splitHunks(&f.store, alloc, "main", c1, &added, "", 1));

    const absent = [_]HunkSpec{.{ .path = "nope", .indices = &bin_idx }};
    try testing.expectError(Error.PathNotModified, splitHunks(&f.store, alloc, "main", c1, &absent, "", 1));

    try testing.expect((try f.store.readRef("main")).eql(c1));
}

test "split by hunk refuses when the selection covers the whole change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_old) }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "app.zig", .blob = try f.blob(wide_new) }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "three edits");
    try f.store.updateRef("main", c1);

    const all = [_]usize{ 1, 2, 3 };
    const specs = [_]HunkSpec{.{ .path = "app.zig", .indices = &all }};
    try testing.expectError(Error.NothingToDo, splitHunks(&f.store, alloc, "main", c1, &specs, "", 1));
    try testing.expect((try f.store.readRef("main")).eql(c1));
}

test "reorder rewrites three changes into the requested order" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    const base_blob = try f.blob("base\n");
    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "base", .blob = base_blob }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "root");

    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = base_blob },
        .{ .mode = .regular, .path = "x", .blob = try f.blob("x\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "x");

    var e2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = base_blob },
        .{ .mode = .regular, .path = "x", .blob = try f.blob("x\n") },
        .{ .mode = .regular, .path = "y", .blob = try f.blob("y\n") },
    };
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "y");

    var e3 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "base", .blob = base_blob },
        .{ .mode = .regular, .path = "x", .blob = try f.blob("x\n") },
        .{ .mode = .regular, .path = "y", .blob = try f.blob("y\n") },
        .{ .mode = .regular, .path = "z", .blob = try f.blob("z\n") },
    };
    const c3 = try f.commit(try f.tree(&e3), &.{c2}, "z");

    try f.store.updateRef("main", c3);
    const id_x = try f.changeIdOf(c1);
    const id_y = try f.changeIdOf(c2);
    const id_z = try f.changeIdOf(c3);

    const order = [_]usize{ 3, 1, 2 };
    const r = try reorder(&f.store, alloc, "main", &order, 12);
    defer r.deinit(alloc);
    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 3), r.rewritten);

    const chain = try f.chain("main");
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 4), chain.len);
    try testing.expect(chain[0].eql(c0));

    const got_z = try f.changeIdOf(chain[1]);
    const got_x = try f.changeIdOf(chain[2]);
    const got_y = try f.changeIdOf(chain[3]);
    try testing.expectEqualSlices(u8, &id_z, &got_z);
    try testing.expectEqualSlices(u8, &id_x, &got_x);
    try testing.expectEqualSlices(u8, &id_y, &got_y);

    const first_tree = try f.treeOf(chain[1]);
    try testing.expect(try f.has(first_tree, "z"));
    try testing.expect(!(try f.has(first_tree, "x")));

    try testing.expect((try f.treeOf(chain[3])).eql(try f.treeOf(c3)));

    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c3));
}

test "reorder rejects anything that is not a permutation" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "zero");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("1\n") }};
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "one");
    try f.store.updateRef("main", c1);

    const dup = [_]usize{ 1, 1 };
    try testing.expectError(Error.NotAPermutation, reorder(&f.store, alloc, "main", &dup, 1));

    const big = [_]usize{ 1, 3 };
    try testing.expectError(Error.NotAPermutation, reorder(&f.store, alloc, "main", &big, 1));

    const too_many = [_]usize{ 1, 2, 3 };
    try testing.expectError(Error.OutOfRange, reorder(&f.store, alloc, "main", &too_many, 1));
}

test "changeOfMoment maps an id prefix and a tree back onto a change" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("0\n") }};
    const t0 = try f.tree(&e0);
    const c0 = try f.commit(t0, &.{}, "zero");
    var e1 = [_]object.TreeEntry{.{ .mode = .regular, .path = "f", .blob = try f.blob("1\n") }};
    const t1 = try f.tree(&e1);
    const c1 = try f.commit(t1, &.{c0}, "one");
    try f.store.updateRef("main", c1);

    try testing.expect((try changeOfMoment(&f.store, alloc, c0.bytes[0..8], Oid.zero())).eql(c0));
    try testing.expect((try changeOfMoment(&f.store, alloc, &[_]u8{}, t1)).eql(c1));
    try testing.expectError(
        Error.NotAChange,
        changeOfMoment(&f.store, alloc, &[_]u8{}, Oid.ofBytes("nothing")),
    );
}

test "undo of a rewrite restores the exact prior ref for every driver" {
    var f = try Fixture.init();
    defer f.deinit();
    const alloc = testing.allocator;

    var e0 = [_]object.TreeEntry{.{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") }};
    const c0 = try f.commit(try f.tree(&e0), &.{}, "a");
    var e1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") },
        .{ .mode = .regular, .path = "b", .blob = try f.blob("b\n") },
    };
    const c1 = try f.commit(try f.tree(&e1), &.{c0}, "b");
    var e2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a", .blob = try f.blob("a\n") },
        .{ .mode = .regular, .path = "b", .blob = try f.blob("b\n") },
        .{ .mode = .regular, .path = "c", .blob = try f.blob("c\n") },
        .{ .mode = .regular, .path = "d", .blob = try f.blob("d\n") },
    };
    const c2 = try f.commit(try f.tree(&e2), &.{c1}, "c and d");
    try f.store.updateRef("main", c2);

    {
        const r = try squash(&f.store, alloc, "main", c2, 2, "squashed", 1);
        defer r.deinit(alloc);
    }
    try testing.expect(!(try f.store.readRef("main")).eql(c2));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));

    {
        const order = [_]usize{ 2, 1 };
        const r = try reorder(&f.store, alloc, "main", &order, 2);
        defer r.deinit(alloc);
    }
    try testing.expect(!(try f.store.readRef("main")).eql(c2));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));

    {
        const paths = [_][]const u8{"c"};
        const r = try split(&f.store, alloc, "main", c2, &paths, "just c", 3);
        defer r.deinit(alloc);
    }
    try testing.expect(!(try f.store.readRef("main")).eql(c2));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));

    {
        const r = try point(&f.store, alloc, "main", c0, 4);
        defer r.deinit(alloc);
    }
    try testing.expect((try f.store.readRef("main")).eql(c0));
    try oplog.undo(&f.store, null);
    try testing.expect((try f.store.readRef("main")).eql(c2));
}
