const std = @import("std");
const applog = @import("applog.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const oid = @import("oid.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Every reader of an append-only log here skips a line it cannot parse, which
/// is the right instinct — one bad byte must not make the whole history
/// unreadable — but a skip nobody counts is a hole nobody learns about. This
/// module counts them and says where they are. It reads; it never writes, and
/// it never repairs: what to do about damage is the user's decision.
pub const Damage = enum {
    /// The append advanced the file's length and its bytes never landed, so the
    /// region reads back as NULs or as nothing at all. A crash mid-append.
    torn,
    /// Bytes are present and are not a record. Something wrote them wrong.
    malformed,

    pub fn label(self: Damage) []const u8 {
        return @tagName(self);
    }
};

/// A run of consecutive unreadable lines of one kind.
pub const Span = struct {
    kind: Damage,
    /// 1-based and inclusive, so the numbers match what an editor shows.
    from_line: usize,
    to_line: usize,
    /// Timestamps of the readable records bracketing the run, in milliseconds,
    /// or zero where the run has no readable neighbour on that side. Together
    /// they are the window of history the damage covers, which is the form the
    /// question is actually asked in: not "line 400" but "the last nine
    /// minutes before lunch".
    from_ms: i64,
    to_ms: i64,

    pub fn lines(self: Span) usize {
        return self.to_line - self.from_line + 1;
    }

    /// Zero when either end is unknown, since an unbounded gap is not a span.
    pub fn gapMs(self: Span) i64 {
        if (self.from_ms == 0 or self.to_ms == 0) return 0;
        return self.to_ms - self.from_ms;
    }
};

pub const LogReport = struct {
    /// Both static; nothing here is owned.
    name: []const u8,
    path: []const u8,
    lines: usize,
    torn: usize,
    malformed: usize,
    spans: []Span,

    pub fn unreadable(self: LogReport) usize {
        return self.torn + self.malformed;
    }
};

pub const Report = struct {
    logs: [shapes.len]LogReport,

    pub fn clean(self: Report) bool {
        for (self.logs) |l| {
            if (l.unreadable() != 0) return false;
        }
        return true;
    }

    pub fn lines(self: Report) usize {
        var n: usize = 0;
        for (self.logs) |l| n += l.lines;
        return n;
    }

    pub fn unreadable(self: Report) usize {
        var n: usize = 0;
        for (self.logs) |l| n += l.unreadable();
        return n;
    }

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        for (self.logs) |l| alloc.free(l.spans);
    }
};

// --- record shapes ---

// Each log's parser is private to the module that owns it, and duplicating one
// here would mean two definitions of "readable" drifting apart. So the check is
// deliberately structural instead: field count, hex width, and integer shape.
// That is what separates a record from rubble, and it is the same thing every
// one of those parsers would reject a line for.

const HexField = struct { field: usize, len: usize };

const Shape = struct {
    name: []const u8,
    path: []const u8,
    /// Everything before this byte is the fixed-arity head; whatever follows is
    /// one free-form field. Null when the whole line splits on spaces, in which
    /// case a trailing free-form field can only make the count larger.
    head_delim: ?u8 = null,
    min_fields: usize,
    hex: []const HexField,
    int: []const usize,
    time_field: usize,
    /// What one unit of the time field is worth in milliseconds; the op-log
    /// records seconds where the other two record milliseconds.
    time_scale: i64,
};

const shapes = [_]Shape{
    .{
        .name = "moments",
        .path = moment.log_path,
        .head_delim = '\t',
        .min_fields = 6,
        .hex = &.{ .{ .field = 0, .len = 16 }, .{ .field = 2, .len = Oid.len * 2 }, .{ .field = 3, .len = Oid.len * 2 } },
        .int = &.{1},
        .time_field = 1,
        .time_scale = 1,
    },
    .{
        .name = "verdicts",
        .path = verdict.log_path,
        .min_fields = 12,
        .hex = &.{ .{ .field = 0, .len = Oid.len * 2 }, .{ .field = 2, .len = Oid.len * 2 } },
        .int = &.{4},
        .time_field = 6,
        .time_scale = 1,
    },
    .{
        .name = "oplog",
        .path = "oplog",
        .min_fields = 5,
        .hex = &.{ .{ .field = 1, .len = Oid.len * 2 }, .{ .field = 2, .len = Oid.len * 2 } },
        .int = &.{3},
        .time_field = 3,
        .time_scale = 1000,
    },
};

fn isHex(s: []const u8, want: usize) bool {
    if (s.len != want) return false;
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

const Line = union(enum) {
    /// Readable, carrying the record's time in milliseconds (zero when the
    /// field is there but says nothing).
    readable: i64,
    damaged: Damage,
};

fn classify(shape: Shape, line: []const u8) Line {
    // A hole is empty or NUL-filled. It is checked first because a hole that
    // swallowed the newline before it merges with the following record, and the
    // resulting line is not malformed — it is torn, and saying so tells the
    // user they lost a crash rather than found a bug.
    if (line.len == 0) return .{ .damaged = .torn };
    if (std.mem.indexOfScalar(u8, line, 0) != null) return .{ .damaged = .torn };

    var head = line;
    if (shape.head_delim) |d| {
        const at = std.mem.indexOfScalar(u8, line, d) orelse return .{ .damaged = .malformed };
        head = line[0..at];
        if (line.len == at + 1) return .{ .damaged = .malformed };
    }

    var fields: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, head, ' ');
    while (it.next()) |f| {
        if (n == fields.len) break;
        fields[n] = f;
        n += 1;
    }
    if (n < shape.min_fields) return .{ .damaged = .malformed };

    for (shape.hex) |h| {
        if (!isHex(fields[h.field], h.len)) return .{ .damaged = .malformed };
    }
    for (shape.int) |i| {
        _ = std.fmt.parseInt(i64, fields[i], 10) catch return .{ .damaged = .malformed };
    }

    const t = std.fmt.parseInt(i64, fields[shape.time_field], 10) catch 0;
    return .{ .readable = t * shape.time_scale };
}

fn inspectOne(store: *Store, alloc: std.mem.Allocator, shape: Shape) !LogReport {
    const data = try applog.readAll(store, alloc, shape.path);
    defer alloc.free(data);

    var out = LogReport{
        .name = shape.name,
        .path = shape.path,
        .lines = 0,
        .torn = 0,
        .malformed = 0,
        .spans = &.{},
    };

    var spans: std.ArrayList(Span) = .empty;
    errdefer spans.deinit(alloc);

    const trimmed = std.mem.trimEnd(u8, data, "\n");
    if (trimmed.len != 0) {
        var last_ms: i64 = 0;
        // Index into `spans` of the run still waiting for a readable record to
        // close its time window; the readers ahead of it are what date it.
        var open: ?usize = null;

        var it = std.mem.splitScalar(u8, trimmed, '\n');
        while (it.next()) |line| {
            out.lines += 1;
            switch (classify(shape, line)) {
                .readable => |ms| {
                    if (open) |i| {
                        spans.items[i].to_ms = ms;
                        open = null;
                    }
                    last_ms = ms;
                },
                .damaged => |kind| {
                    switch (kind) {
                        .torn => out.torn += 1,
                        .malformed => out.malformed += 1,
                    }
                    const extend = if (open) |i| spans.items[i].kind == kind else false;
                    if (extend) {
                        spans.items[open.?].to_line = out.lines;
                    } else {
                        try spans.append(alloc, .{
                            .kind = kind,
                            .from_line = out.lines,
                            .to_line = out.lines,
                            .from_ms = last_ms,
                            .to_ms = 0,
                        });
                        open = spans.items.len - 1;
                    }
                },
            }
        }
    }

    out.spans = try spans.toOwnedSlice(alloc);
    return out;
}

/// Inspect every append-only log the repo keeps. Caller frees with
/// `Report.deinit`.
pub fn inspect(store: *Store, alloc: std.mem.Allocator) !Report {
    var out: Report = .{ .logs = undefined };
    var done: usize = 0;
    errdefer for (out.logs[0..done]) |l| alloc.free(l.spans);
    for (&shapes, 0..) |shape, i| {
        out.logs[i] = try inspectOne(store, alloc, shape);
        done = i + 1;
    }
    return out;
}

// --- tests ---

const testing = std.testing;

fn hex(comptime c: u8) [Oid.len * 2]u8 {
    return [_]u8{c} ** (Oid.len * 2);
}

fn momentLine(alloc: std.mem.Allocator, ms: i64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s} {d} {s} {s} k idle\tmain\n", .{
        "0123456789abcdef",
        ms,
        &hex('a'),
        &hex('b'),
    });
}

fn writeMoments(store: *Store, alloc: std.mem.Allocator, times: []const i64) !void {
    try store.root.createDirPath(store.io, "moments");
    for (times) |ms| {
        const line = try momentLine(alloc, ms);
        defer alloc.free(line);
        try applog.append(store, moment.log_path, line);
    }
}

test "a clean set of logs reports no damage" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{ 1_700_000_000_000, 1_700_000_060_000 });

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expect(r.clean());
    try testing.expectEqual(@as(usize, 0), r.unreadable());
    try testing.expectEqual(@as(usize, 2), r.logs[0].lines);
    // Logs that were never written read as empty rather than as damaged.
    try testing.expectEqual(@as(usize, 0), r.logs[1].lines);
    try testing.expectEqual(@as(usize, 0), r.logs[2].lines);
}

test "a NUL-filled hole is a torn append" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{1_700_000_000_000});
    try applog.append(&store, moment.log_path, &([_]u8{0} ** 40 ++ [_]u8{'\n'}));
    try writeMoments(&store, alloc, &.{1_700_000_060_000});

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expect(!r.clean());
    try testing.expectEqual(@as(usize, 1), r.logs[0].torn);
    try testing.expectEqual(@as(usize, 0), r.logs[0].malformed);
    try testing.expectEqual(@as(usize, 1), r.logs[0].spans.len);
    try testing.expectEqual(Damage.torn, r.logs[0].spans[0].kind);
    try testing.expectEqual(@as(usize, 2), r.logs[0].spans[0].from_line);
}

test "an empty line is torn, not malformed" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{1_700_000_000_000});
    try applog.append(&store, moment.log_path, "\n");
    try writeMoments(&store, alloc, &.{1_700_000_060_000});

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), r.logs[0].torn);
    try testing.expectEqual(@as(usize, 0), r.logs[0].malformed);
}

test "a structurally wrong line is malformed" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{1_700_000_000_000});
    try applog.append(&store, moment.log_path, "0123456789abcdef 17 zz k idle\tmain\n");

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expectEqual(@as(usize, 0), r.logs[0].torn);
    try testing.expectEqual(@as(usize, 1), r.logs[0].malformed);
    try testing.expectEqual(Damage.malformed, r.logs[0].spans[0].kind);
    // Nothing readable follows, so the window has no far edge and no gap.
    try testing.expectEqual(@as(i64, 0), r.logs[0].spans[0].to_ms);
}

test "a damaged run reports the span of history it covers" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const start: i64 = 1_700_000_000_000;
    try writeMoments(&store, alloc, &.{start});
    try applog.append(&store, moment.log_path, &([_]u8{0} ** 60 ++ [_]u8{'\n'}));
    try applog.append(&store, moment.log_path, &([_]u8{0} ** 60 ++ [_]u8{'\n'}));
    try writeMoments(&store, alloc, &.{ start + 540_000, start + 600_000 });

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    const log = r.logs[0];
    try testing.expectEqual(@as(usize, 5), log.lines);
    try testing.expectEqual(@as(usize, 2), log.torn);
    // Both torn lines are one run, not two reports of the same wound.
    try testing.expectEqual(@as(usize, 1), log.spans.len);
    try testing.expectEqual(@as(usize, 2), log.spans[0].lines());
    try testing.expectEqual(start, log.spans[0].from_ms);
    try testing.expectEqual(start + 540_000, log.spans[0].to_ms);
    try testing.expectEqual(@as(i64, 540_000), log.spans[0].gapMs());
}

test "torn and malformed runs stay separate spans" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{1_700_000_000_000});
    try applog.append(&store, moment.log_path, "\n");
    try applog.append(&store, moment.log_path, "not a record at all\n");

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), r.logs[0].spans.len);
    try testing.expectEqual(Damage.torn, r.logs[0].spans[0].kind);
    try testing.expectEqual(Damage.malformed, r.logs[0].spans[1].kind);
}

test "damage in the verdict and op logs is found too" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const good_v = try std.fmt.allocPrint(
        alloc,
        "{s} full {s} green 0 12 1700000000000 {s} unknown 0 0 unknown\n",
        .{ &hex('a'), &hex('b'), &hex('0') },
    );
    defer alloc.free(good_v);
    try applog.append(&store, verdict.log_path, good_v);
    try applog.append(&store, verdict.log_path, "green 0 12\n");

    const good_op = try std.fmt.allocPrint(alloc, "snapshot {s} {s} 1700000000 main\n", .{ &hex('0'), &hex('c') });
    defer alloc.free(good_op);
    try applog.append(&store, "oplog", good_op);
    try applog.append(&store, "oplog", "snapshot deadbeef 1700000000 main\n");

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), r.logs[1].lines);
    try testing.expectEqual(@as(usize, 1), r.logs[1].malformed);
    try testing.expectEqual(@as(usize, 2), r.logs[2].lines);
    try testing.expectEqual(@as(usize, 1), r.logs[2].malformed);
}

test "counts agree with what the owning readers keep" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try writeMoments(&store, alloc, &.{ 1_700_000_000_000, 1_700_000_060_000 });
    try applog.append(&store, moment.log_path, "garbage\n");
    try applog.append(&store, moment.log_path, &([_]u8{0} ** 20 ++ [_]u8{'\n'}));

    const r = try inspect(&store, alloc);
    defer r.deinit(alloc);

    const kept = try moment.readAll(&store, alloc);
    defer moment.freeMoments(alloc, kept);

    try testing.expectEqual(kept.len, r.logs[0].lines - r.logs[0].unreadable());
}
