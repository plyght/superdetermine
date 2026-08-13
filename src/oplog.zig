const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const applog = @import("applog.zig");
const opdag = @import("opdag.zig");
const checks = @import("checks.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const OpKind = enum {
    snapshot,
    undo,
    redo,
    import,
    /// A worktree rewind. Unlike every other kind, `prev` and `new` are tree
    /// Oids rather than change Oids, because a rewind moves the working tree
    /// and not a branch pointer. Undoing one materializes `prev` back.
    rewind,
    other,

    pub fn label(self: OpKind) []const u8 {
        return switch (self) {
            .snapshot => "snapshot",
            .undo => "undo",
            .redo => "redo",
            .import => "import",
            .rewind => "rewind",
            .other => "other",
        };
    }

    pub fn fromLabel(s: []const u8) OpKind {
        if (std.mem.eql(u8, s, "snapshot")) return .snapshot;
        if (std.mem.eql(u8, s, "undo")) return .undo;
        if (std.mem.eql(u8, s, "redo")) return .redo;
        if (std.mem.eql(u8, s, "import")) return .import;
        if (std.mem.eql(u8, s, "rewind")) return .rewind;
        return .other;
    }
};

/// One append-only op-log entry. `branch` is borrowed on write; on read via
/// `lastOp` it is heap-allocated and the caller frees it.
pub const OpRecord = struct {
    kind: OpKind,
    branch: []const u8,
    prev: Oid,
    new: Oid,
    timestamp: i64,
};

// Record wire format, one line per op:
//   <kind> <prevhex> <newhex> <timestamp> <branch>\n
// branch comes last so it may contain any byte except '\n'.

/// Append a record to `.sdt/oplog`, in time independent of the log's length.
pub fn record(store: *Store, op: OpRecord) !void {
    const alloc = store.alloc;

    var prev_hex: [Oid.len * 2]u8 = undefined;
    var new_hex: [Oid.len * 2]u8 = undefined;
    _ = op.prev.toHex(&prev_hex);
    _ = op.new.toHex(&new_hex);

    const line = try std.fmt.allocPrint(alloc, "{s} {s} {s} {d} {s}\n", .{
        op.kind.label(),
        prev_hex,
        new_hex,
        op.timestamp,
        op.branch,
    });
    defer alloc.free(line);

    try applog.append(store, "oplog", line);

    _ = opdag.commit(store, alloc, op.kind.label(), op.timestamp, op.branch) catch Oid.zero();
}

fn parseLine(alloc: std.mem.Allocator, line: []const u8) !OpRecord {
    var it = std.mem.splitScalar(u8, line, ' ');
    const kind_s = it.next() orelse return error.InvalidOpRecord;
    const prev_s = it.next() orelse return error.InvalidOpRecord;
    const new_s = it.next() orelse return error.InvalidOpRecord;
    const ts_s = it.next() orelse return error.InvalidOpRecord;
    const branch_s = it.rest();
    if (branch_s.len == 0) return error.InvalidOpRecord;

    return .{
        .kind = OpKind.fromLabel(kind_s),
        .branch = try alloc.dupe(u8, branch_s),
        .prev = try Oid.fromHex(prev_s),
        .new = try Oid.fromHex(new_s),
        .timestamp = try std.fmt.parseInt(i64, ts_s, 10),
    };
}

/// Parse the last record. Returns null if the log is empty or absent.
/// Caller frees `.branch`.
pub fn lastOp(store: *Store, alloc: std.mem.Allocator) !?OpRecord {
    const data = store.root.readFileAlloc(store.io, "oplog", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer alloc.free(data);

    const trimmed = std.mem.trimEnd(u8, data, "\n");
    if (trimmed.len == 0) return null;

    const start = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| i + 1 else 0;
    return try parseLine(alloc, trimmed[start..]);
}

/// Parse every record in `.sdt/oplog`, in order. Caller frees each `.branch`
/// and the returned slice.
pub fn readAll(store: *Store, alloc: std.mem.Allocator) ![]OpRecord {
    const data = store.root.readFileAlloc(store.io, "oplog", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return try alloc.alloc(OpRecord, 0),
        else => return e,
    };
    defer alloc.free(data);

    var list: std.ArrayList(OpRecord) = .empty;
    errdefer {
        for (list.items) |r| alloc.free(r.branch);
        list.deinit(alloc);
    }

    const trimmed = std.mem.trimEnd(u8, data, "\n");
    if (trimmed.len == 0) return list.toOwnedSlice(alloc);

    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        try list.append(alloc, try parseLine(alloc, line));
    }
    return list.toOwnedSlice(alloc);
}

fn nowSeconds(store: *Store) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, store.io).nanoseconds, std.time.ns_per_s));
}

/// Apply the effect of an op in the direction of `target`. Ref-shaped ops move
/// a branch; a rewind puts the working tree back, which is what makes rewinding
/// something people reach for rather than fear.
fn applyOp(store: *Store, op: OpRecord, target: Oid, work_dir: ?std.Io.Dir) !void {
    if (op.kind != .rewind) return applyRef(store, op.branch, target);

    const wd = work_dir orelse return error.WorktreeRequired;
    const tree = try store.readTree(target);
    defer object.freeTree(store.alloc, tree);
    try checks.reconcile(store, wd, tree.entries);
}

fn applyRef(store: *Store, branch: []const u8, target: Oid) !void {
    if (target.isZero()) {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "refs/heads/{s}", .{branch});
        store.root.deleteFile(store.io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    } else {
        try store.updateRef(branch, target);
    }
}

/// Multi-level undo. Models the log as a stack of "real" ops (snapshot/import/
/// other) with an undo pointer; a trailing run of undo/redo meta records shifts
/// the pointer (undo steps back one real op, redo forward one). Applies the
/// inverse of the currently-topmost applied op — sets its branch back to `prev`
/// (deleting the ref when `prev` is zero/unborn) — then appends an undo record.
/// Errors `NothingToUndo` when the pointer is already at the bottom.
///
/// Limitation: real ops that were undone and then superseded by a new real op
/// remain in the flat real-op list, so undoing past such a boundary walks the
/// historical ops rather than reconstructing a branching timeline.
pub fn undo(store: *Store, work_dir: ?std.Io.Dir) !void {
    const alloc = store.alloc;

    const records = try readAll(store, alloc);
    defer {
        for (records) |r| alloc.free(r.branch);
        alloc.free(records);
    }

    const pointer = currentPointer(records);
    const reals = realCount(records);
    if (pointer == 0 or reals == 0) return error.NothingToUndo;

    const target = nthReal(records, pointer - 1).?;

    try applyOp(store, target, target.prev, work_dir);

    try record(store, .{
        .kind = .undo,
        .branch = target.branch,
        .prev = target.new,
        .new = target.prev,
        .timestamp = nowSeconds(store),
    });
}

/// Re-apply the most recently undone real op. Only valid when the last effective
/// op was an undo (i.e. the log ends in a trailing undo with nothing new after);
/// sets the branch forward to that op's `new` and appends a redo record. Errors
/// `NothingToRedo` otherwise.
pub fn redo(store: *Store, work_dir: ?std.Io.Dir) !void {
    const alloc = store.alloc;

    const records = try readAll(store, alloc);
    defer {
        for (records) |r| alloc.free(r.branch);
        alloc.free(records);
    }

    if (records.len == 0 or records[records.len - 1].kind != .undo) return error.NothingToRedo;

    const pointer = currentPointer(records);
    const reals = realCount(records);
    if (pointer >= reals) return error.NothingToRedo;

    const target = nthReal(records, pointer).?;

    try applyOp(store, target, target.new, work_dir);

    try record(store, .{
        .kind = .redo,
        .branch = target.branch,
        .prev = target.prev,
        .new = target.new,
        .timestamp = nowSeconds(store),
    });
}

fn isMeta(k: OpKind) bool {
    return k == .undo or k == .redo;
}

/// Number of "real" (non-meta) ops in the log.
fn realCount(records: []const OpRecord) usize {
    var n: usize = 0;
    for (records) |r| {
        if (!isMeta(r.kind)) n += 1;
    }
    return n;
}

/// The i-th real op (0-based), skipping meta records.
fn nthReal(records: []const OpRecord, i: usize) ?OpRecord {
    var n: usize = 0;
    for (records) |r| {
        if (isMeta(r.kind)) continue;
        if (n == i) return r;
        n += 1;
    }
    return null;
}

/// Count of real ops currently applied: total reals minus the net backward shift
/// from the trailing run of undo/redo meta records.
fn currentPointer(records: []const OpRecord) usize {
    var net_back: usize = 0;
    var i = records.len;
    while (i > 0) : (i -= 1) {
        const k = records[i - 1].kind;
        if (k == .undo) {
            net_back += 1;
        } else if (k == .redo) {
            if (net_back > 0) net_back -= 1;
        } else break;
    }
    const reals = realCount(records);
    return if (net_back >= reals) 0 else reals - net_back;
}

// --- tests ---

const testing = std.testing;

test {
    _ = @import("opdag.zig");
}

test "record, lastOp, and single-level undo" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = Oid.ofBytes("change A");
    const b = Oid.ofBytes("change B");

    try store.updateRef("main", a);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = Oid.zero(), .new = a, .timestamp = 1 });

    try store.updateRef("main", b);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = a, .new = b, .timestamp = 2 });

    {
        const lo = (try lastOp(&store, alloc)).?;
        defer alloc.free(lo.branch);
        try testing.expectEqualStrings("main", lo.branch);
        try testing.expect(lo.new.eql(b));
        try testing.expect(lo.prev.eql(a));
        try testing.expectEqual(OpKind.snapshot, lo.kind);
    }

    try undo(&store, null);
    try testing.expect((try store.readRef("main")).eql(a));

    // Undo op was logged.
    {
        const lo = (try lastOp(&store, alloc)).?;
        defer alloc.free(lo.branch);
        try testing.expectEqual(OpKind.undo, lo.kind);
    }
}

test "multi-level undo then redo" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = Oid.ofBytes("snap A");
    const b = Oid.ofBytes("snap B");
    const c = Oid.ofBytes("snap C");

    try store.updateRef("main", a);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = Oid.zero(), .new = a, .timestamp = 1 });
    try store.updateRef("main", b);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = a, .new = b, .timestamp = 2 });
    try store.updateRef("main", c);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = b, .new = c, .timestamp = 3 });

    try testing.expect((try store.readRef("main")).eql(c));

    try undo(&store, null);
    try testing.expect((try store.readRef("main")).eql(b));

    try undo(&store, null);
    try testing.expect((try store.readRef("main")).eql(a));

    try redo(&store, null);
    try testing.expect((try store.readRef("main")).eql(b));
}

test "undo of unborn branch deletes the ref" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = Oid.ofBytes("first commit");
    try store.updateRef("feature", a);
    try record(&store, .{ .kind = .snapshot, .branch = "feature", .prev = Oid.zero(), .new = a, .timestamp = 1 });

    try testing.expect(store.refExists("feature"));
    try undo(&store, null);
    try testing.expect(!store.refExists("feature"));
}

test "the linear log keeps one operation head, and undo tracks it" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = Oid.ofBytes("dag A");
    const b = Oid.ofBytes("dag B");

    try store.updateRef("main", a);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = Oid.zero(), .new = a, .timestamp = 1 });
    try store.updateRef("main", b);
    try record(&store, .{ .kind = .snapshot, .branch = "main", .prev = a, .new = b, .timestamp = 2 });

    {
        const hs = try opdag.heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 1), hs.len);

        var view = try opdag.currentView(&store, alloc);
        defer view.deinit(alloc);
        try testing.expect(!view.diverged());
        try testing.expect(view.find("main").?.tips[0].eql(b));
        try testing.expect((try opdag.resolve(&store, alloc)) == null);
    }

    try undo(&store, null);
    try testing.expect((try store.readRef("main")).eql(a));

    {
        const hs = try opdag.heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 1), hs.len);

        var view = try opdag.currentView(&store, alloc);
        defer view.deinit(alloc);
        try testing.expect(view.find("main").?.tips[0].eql(a));
    }

    try redo(&store, null);
    try testing.expect((try store.readRef("main")).eql(b));

    const lo = (try lastOp(&store, alloc)).?;
    defer alloc.free(lo.branch);
    try testing.expectEqual(OpKind.redo, lo.kind);
}

test "lastOp is null on empty log" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expect((try lastOp(&store, alloc)) == null);
}
