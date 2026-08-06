const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// What happened while you were away.
///
/// A run of an hour is a few hundred moments and a few dozen verdicts. Nobody
/// reads that. What they want is the shape: it was green here, it broke there,
/// it came back, and these are the files that survived the whole thing. So a
/// recap is spans, not events.
///
/// Everything here is deterministic and offline. No model is consulted, nothing
/// is summarised, nothing is guessed. `renderJson` exists precisely so that a
/// user who wants prose can pipe the structure into their own agent, rather than
/// this module pretending to be one.
///
/// The one rule that shapes the whole design: every reported verdict was
/// measured. Code is not monotonic, so an ungraded moment sitting between two
/// green ones is not green, and it is never absorbed into a neighbouring span.
pub const Span = struct {
    result: verdict.Result,
    /// Indices into the moment slice the span was computed from, inclusive.
    from_index: usize,
    to_index: usize,
    from_ms: i64,
    to_ms: i64,
    /// How many moments in the span carried a measured verdict. Because an
    /// ungraded moment ends a span, this always equals the index extent.
    moments: usize,

    pub fn durationMs(self: Span) i64 {
        return self.to_ms - self.from_ms;
    }
};

// --- spans ---

/// Group consecutive measured verdicts of the same result into spans, oldest
/// first.
///
/// Ungraded moments get a third treatment: they belong to no span at all, and
/// they terminate the span in progress. Skipping them silently would let a span
/// claim an extent nobody measured, and merging across them would be plain
/// interpolation. The visible cost is that a graded-ungraded-graded stretch
/// reports two spans of the same colour instead of one, which is exactly the
/// honest answer, and `spans.len` is therefore a measure of coverage rather than
/// of how often the result flipped.
pub fn spans(
    store: *Store,
    alloc: std.mem.Allocator,
    moments: []const moment.Moment,
    ix: *const verdict.Index,
    cmd_fast: Oid,
    cmd_full: Oid,
) ![]Span {
    // Verdicts are keyed by tree content, so the index answers everything and
    // the store is never touched here.
    _ = store;

    var out: std.ArrayList(Span) = .empty;
    errdefer out.deinit(alloc);

    var cur: ?Span = null;
    for (moments, 0..) |m, i| {
        const v = ix.best(m.full_tree, cmd_fast, cmd_full) orelse {
            if (cur) |s| {
                try out.append(alloc, s);
                cur = null;
            }
            continue;
        };
        if (cur) |*s| {
            if (s.result == v.result) {
                s.to_index = i;
                s.to_ms = m.ms;
                s.moments += 1;
                continue;
            }
            try out.append(alloc, s.*);
        }
        cur = .{
            .result = v.result,
            .from_index = i,
            .to_index = i,
            .from_ms = m.ms,
            .to_ms = m.ms,
            .moments = 1,
        };
    }
    if (cur) |s| try out.append(alloc, s);

    return out.toOwnedSlice(alloc);
}

/// How long the tree was measurably broken: the summed extent of the red spans.
///
/// The gap between a red span's last moment and the next measured green is not
/// counted. Nothing in that gap was run, so claiming it as broken time would be
/// the same interpolation the span walk refuses to do.
pub fn brokenMs(list: []const Span) i64 {
    var total: i64 = 0;
    for (list) |s| {
        if (s.result != .red) continue;
        total += s.durationMs();
    }
    return total;
}

// --- thrash ---

/// A path the run kept rewriting without settling.
pub const Thrash = struct {
    path: []const u8,
    /// Content changes across the range, counting creation and deletion.
    writes: usize,
};

const Track = struct {
    /// Content at the start of the range. A zero Oid means the path was absent,
    /// which is safe as a sentinel because no blob ever hashes to zero.
    first: Oid,
    /// The value the path took immediately after its first change.
    intermediate: Oid,
    intermediate_set: bool,
    /// Content as of the most recent moment seen so far.
    prev: Oid,
    writes: usize,
};

/// Paths that were written, changed again, and ended somewhere else entirely.
///
/// The filter is deliberately narrow. A path written once is progress. A path
/// written twice and put back is a revert. Thrash is the third shape: the final
/// content matches neither where the range began nor the value the path was
/// first moved to, which is what churn without convergence looks like.
///
/// Free with `freeThrash`.
pub fn thrash(
    store: *Store,
    alloc: std.mem.Allocator,
    moments: []const moment.Moment,
) ![]Thrash {
    var tracks = std.StringHashMap(Track).init(alloc);
    defer {
        var it = tracks.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        tracks.deinit();
    }

    for (moments, 0..) |m, i| {
        const entries = try moment.entriesOf(store, m);
        defer workspace.freeTreeEntries(alloc, entries);

        var present = std.StringHashMap(void).init(alloc);
        defer present.deinit();
        for (entries) |e| try present.put(e.path, {});

        for (entries) |e| {
            const gop = try tracks.getOrPut(e.path);
            if (!gop.found_existing) {
                gop.key_ptr.* = alloc.dupe(u8, e.path) catch |err| {
                    _ = tracks.remove(e.path);
                    return err;
                };
                // A path first seen after the range began was created, which is
                // itself a write, and that creation is its first intermediate.
                gop.value_ptr.* = .{
                    .first = if (i == 0) e.blob else Oid.zero(),
                    .intermediate = e.blob,
                    .intermediate_set = i != 0,
                    .prev = e.blob,
                    .writes = if (i == 0) 0 else 1,
                };
                continue;
            }
            if (gop.value_ptr.prev.eql(e.blob)) continue;
            gop.value_ptr.writes += 1;
            if (!gop.value_ptr.intermediate_set) {
                gop.value_ptr.intermediate = e.blob;
                gop.value_ptr.intermediate_set = true;
            }
            gop.value_ptr.prev = e.blob;
        }

        // A tracked path that vanished changed too, and deletion is a write.
        var it = tracks.iterator();
        while (it.next()) |kv| {
            if (present.contains(kv.key_ptr.*)) continue;
            if (kv.value_ptr.prev.isZero()) continue;
            kv.value_ptr.writes += 1;
            if (!kv.value_ptr.intermediate_set) {
                kv.value_ptr.intermediate = Oid.zero();
                kv.value_ptr.intermediate_set = true;
            }
            kv.value_ptr.prev = Oid.zero();
        }
    }

    var out: std.ArrayList(Thrash) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t.path);
        out.deinit(alloc);
    }

    var it = tracks.iterator();
    while (it.next()) |kv| {
        const t = kv.value_ptr.*;
        if (t.writes < 2) continue;
        if (t.prev.eql(t.first)) continue;
        if (!t.intermediate_set or t.prev.eql(t.intermediate)) continue;
        try out.append(alloc, .{
            .path = try alloc.dupe(u8, kv.key_ptr.*),
            .writes = t.writes,
        });
    }

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(Thrash, slice, {}, thrashLessThan);
    return slice;
}

pub fn freeThrash(alloc: std.mem.Allocator, list: []const Thrash) void {
    for (list) |t| alloc.free(t.path);
    alloc.free(list);
}

fn thrashLessThan(_: void, a: Thrash, b: Thrash) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

// --- the report ---

pub const Report = struct {
    spans: []const Span,
    thrash: []const Thrash,
    /// Summed extent of the red spans.
    broken_ms: i64,
    /// How many paths differ between the first and last moment of the range.
    landed: usize,
    landed_paths: []const []const u8,
    /// The paths the first red span changed relative to its predecessor moment.
    /// Empty when nothing went red, or when the range opens red and there is no
    /// predecessor to blame.
    broke_paths: []const []const u8,
    from_ms: i64,
    to_ms: i64,
    /// Moments in the range, graded or not.
    moments: usize,
    /// Moments that carried a measured verdict.
    graded: usize,

    pub fn durationMs(self: Report) i64 {
        return self.to_ms - self.from_ms;
    }

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        alloc.free(self.spans);
        freeThrash(alloc, self.thrash);
        freePaths(alloc, self.landed_paths);
        freePaths(alloc, self.broke_paths);
    }
};

fn freePaths(alloc: std.mem.Allocator, list: []const []const u8) void {
    for (list) |p| alloc.free(p);
    alloc.free(list);
}

fn pathLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Paths whose content differs between two moments, sorted. Caller frees with
/// `freePaths`.
fn changedBetween(
    store: *Store,
    alloc: std.mem.Allocator,
    a: moment.Moment,
    b: moment.Moment,
) ![]const []const u8 {
    const old = try moment.entriesOf(store, a);
    defer workspace.freeTreeEntries(alloc, old);
    const new = try moment.entriesOf(store, b);
    defer workspace.freeTreeEntries(alloc, new);

    var old_map = std.StringHashMap(Oid).init(alloc);
    defer old_map.deinit();
    for (old) |e| try old_map.put(e.path, e.blob);

    var new_set = std.StringHashMap(void).init(alloc);
    defer new_set.deinit();
    for (new) |e| try new_set.put(e.path, {});

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }

    for (new) |e| {
        if (old_map.get(e.path)) |o| {
            if (o.eql(e.blob)) continue;
        }
        try out.append(alloc, try alloc.dupe(u8, e.path));
    }
    var it = old_map.keyIterator();
    while (it.next()) |k| {
        if (new_set.contains(k.*)) continue;
        try out.append(alloc, try alloc.dupe(u8, k.*));
    }

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort([]const u8, slice, {}, pathLessThan);
    return slice;
}

/// Assemble the whole report: the span shape, what landed, how long the tree was
/// broken, what broke it, and what never settled. Caller frees with
/// `Report.deinit`.
pub fn build(
    store: *Store,
    alloc: std.mem.Allocator,
    moments: []const moment.Moment,
    ix: *const verdict.Index,
    cmd_fast: Oid,
    cmd_full: Oid,
) !Report {
    const span_list = try spans(store, alloc, moments, ix, cmd_fast, cmd_full);
    errdefer alloc.free(span_list);

    const thrash_list = try thrash(store, alloc, moments);
    errdefer freeThrash(alloc, thrash_list);

    // What landed is the first-to-last difference, not the sum of the edits: a
    // file touched forty times and put back did not land.
    const landed_paths: []const []const u8 = if (moments.len < 2)
        try alloc.alloc([]const u8, 0)
    else
        try changedBetween(store, alloc, moments[0], moments[moments.len - 1]);
    errdefer freePaths(alloc, landed_paths);

    var broke_paths: []const []const u8 = try alloc.alloc([]const u8, 0);
    errdefer freePaths(alloc, broke_paths);
    for (span_list) |s| {
        if (s.result != .red) continue;
        if (s.from_index == 0) break;
        alloc.free(broke_paths);
        broke_paths = try changedBetween(store, alloc, moments[s.from_index - 1], moments[s.from_index]);
        break;
    }

    var graded: usize = 0;
    for (span_list) |s| graded += s.moments;

    return .{
        .spans = span_list,
        .thrash = thrash_list,
        .broken_ms = brokenMs(span_list),
        .landed = landed_paths.len,
        .landed_paths = landed_paths,
        .broke_paths = broke_paths,
        .from_ms = if (moments.len == 0) 0 else moments[0].ms,
        .to_ms = if (moments.len == 0) 0 else moments[moments.len - 1].ms,
        .moments = moments.len,
        .graded = graded,
    };
}

// --- rendering ---

fn writeDuration(w: *std.Io.Writer, ms: i64) !void {
    const abs: u64 = @intCast(if (ms < 0) -ms else ms);
    if (abs < 1000) return w.print("{d}ms", .{abs});
    const secs = abs / 1000;
    if (secs < 60) return w.print("{d}s", .{secs});
    const mins = secs / 60;
    if (mins < 60) return w.print("{d}m{d:0>2}s", .{ mins, secs % 60 });
    return w.print("{d}h{d:0>2}m", .{ mins / 60, mins % 60 });
}

/// The human form: the span shape first, because that is the question, then the
/// three follow-ups (what landed, how long it was broken, what broke it).
pub fn render(w: *std.Io.Writer, r: Report) !void {
    try w.print("recap: {d} moments, {d} graded, over ", .{ r.moments, r.graded });
    try writeDuration(w, r.durationMs());
    try w.writeByte('\n');

    if (r.spans.len == 0) {
        try w.writeAll("  nothing measured in this range\n");
    } else {
        for (r.spans) |s| {
            try w.print("  {s:<5} {d:>4} moments  ", .{ s.result.label(), s.moments });
            try writeDuration(w, s.durationMs());
            try w.print("  [{d}..{d}]\n", .{ s.from_index, s.to_index });
        }
    }

    try w.print("landed: {d} paths\n", .{r.landed});
    for (r.landed_paths) |p| try w.print("  {s}\n", .{p});

    try w.writeAll("broken for ");
    try writeDuration(w, r.broken_ms);
    try w.writeByte('\n');

    if (r.broke_paths.len != 0) {
        try w.writeAll("broke:\n");
        for (r.broke_paths) |p| try w.print("  {s}\n", .{p});
    }
    if (r.thrash.len != 0) {
        try w.writeAll("thrash:\n");
        for (r.thrash) |t| try w.print("  {s} ({d} writes)\n", .{ t.path, t.writes });
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn writeJsonPaths(w: *std.Io.Writer, list: []const []const u8) !void {
    try w.writeByte('[');
    for (list, 0..) |p, i| {
        if (i != 0) try w.writeByte(',');
        try writeJsonString(w, p);
    }
    try w.writeByte(']');
}

/// The machine form for `--json`. Written by hand rather than through a
/// serializer so the field names are the contract and stay visible here.
pub fn renderJson(w: *std.Io.Writer, r: Report) !void {
    try w.print(
        "{{\"moments\":{d},\"graded\":{d},\"from_ms\":{d},\"to_ms\":{d},\"broken_ms\":{d},\"landed\":{d},",
        .{ r.moments, r.graded, r.from_ms, r.to_ms, r.broken_ms, r.landed },
    );

    try w.writeAll("\"spans\":[");
    for (r.spans, 0..) |s, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"result\":");
        try writeJsonString(w, s.result.label());
        try w.print(
            ",\"from_index\":{d},\"to_index\":{d},\"from_ms\":{d},\"to_ms\":{d},\"moments\":{d}}}",
            .{ s.from_index, s.to_index, s.from_ms, s.to_ms, s.moments },
        );
    }
    try w.writeAll("],");

    try w.writeAll("\"landed_paths\":");
    try writeJsonPaths(w, r.landed_paths);
    try w.writeAll(",\"broke_paths\":");
    try writeJsonPaths(w, r.broke_paths);

    try w.writeAll(",\"thrash\":[");
    for (r.thrash, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"path\":");
        try writeJsonString(w, t.path);
        try w.print(",\"writes\":{d}}}", .{t.writes});
    }
    try w.writeAll("]}");
}

// --- tests ---

const testing = std.testing;

const base_ms: i64 = 1_800_000_000_000;

/// Moments built by hand, so span boundaries can be asserted against exact
/// timestamps without sleeping. `spans` only reads `full_tree` and `ms`.
fn fakeMoment(n: usize, ms: i64) moment.Moment {
    var buf: [16]u8 = undefined;
    const body = std.fmt.bufPrint(&buf, "tree-{d}", .{n}) catch unreachable;
    const tree = Oid.ofBytes(body);
    return .{
        .id = moment.computeId("main", tree, ms),
        .ms = ms,
        .full_tree = tree,
        .repr = tree,
        .kind = .keyframe,
        .cause = .poll,
        .branch = "main",
    };
}

fn recordResult(store: *Store, m: moment.Moment, cmd: Oid, result: verdict.Result) !void {
    try verdict.record(store, .{
        .tree = m.full_tree,
        .tier = .full,
        .command = cmd,
        .result = result,
        .exit_code = if (result == .green) 0 else 1,
        .duration_ms = 1,
        .ms = m.ms,
        .readset = Oid.zero(),
    });
}

test "green then red is two spans with measured boundaries" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = verdict.commandHash("zig build test");

    var list: [6]moment.Moment = undefined;
    for (&list, 0..) |*m, i| {
        m.* = fakeMoment(i, base_ms + @as(i64, @intCast(i)) * 1000);
        try recordResult(&store, m.*, cmd, if (i < 3) .green else .red);
    }

    var ix = try verdict.Index.load(&store, alloc);
    defer ix.deinit();

    const got = try spans(&store, alloc, &list, &ix, cmd, cmd);
    defer alloc.free(got);

    try testing.expectEqual(@as(usize, 2), got.len);

    try testing.expectEqual(verdict.Result.green, got[0].result);
    try testing.expectEqual(@as(usize, 0), got[0].from_index);
    try testing.expectEqual(@as(usize, 2), got[0].to_index);
    try testing.expectEqual(@as(usize, 3), got[0].moments);
    try testing.expectEqual(base_ms, got[0].from_ms);
    try testing.expectEqual(base_ms + 2000, got[0].to_ms);

    try testing.expectEqual(verdict.Result.red, got[1].result);
    try testing.expectEqual(@as(usize, 3), got[1].from_index);
    try testing.expectEqual(@as(usize, 5), got[1].to_index);
    try testing.expectEqual(@as(usize, 3), got[1].moments);
    try testing.expectEqual(base_ms + 3000, got[1].from_ms);
    try testing.expectEqual(base_ms + 5000, got[1].to_ms);
}

test "an ungraded moment is never absorbed into a neighbouring span" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = verdict.commandHash("check");

    var list: [3]moment.Moment = undefined;
    for (&list, 0..) |*m, i| m.* = fakeMoment(i, base_ms + @as(i64, @intCast(i)) * 1000);
    // Green, ungraded, green. The middle one is not green.
    try recordResult(&store, list[0], cmd, .green);
    try recordResult(&store, list[2], cmd, .green);

    var ix = try verdict.Index.load(&store, alloc);
    defer ix.deinit();

    const got = try spans(&store, alloc, &list, &ix, cmd, cmd);
    defer alloc.free(got);

    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqual(@as(usize, 1), got[0].moments);
    try testing.expectEqual(@as(usize, 1), got[1].moments);
    try testing.expectEqual(@as(usize, 2), got[1].from_index);
}

test "broken_ms sums only the red spans" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = verdict.commandHash("check");

    // green x2 (0..1000), red x3 (2000..4000), green x2 (5000..6000)
    const results = [_]verdict.Result{ .green, .green, .red, .red, .red, .green, .green };
    var list: [results.len]moment.Moment = undefined;
    for (&list, 0..) |*m, i| {
        m.* = fakeMoment(i, base_ms + @as(i64, @intCast(i)) * 1000);
        try recordResult(&store, m.*, cmd, results[i]);
    }

    var ix = try verdict.Index.load(&store, alloc);
    defer ix.deinit();

    const got = try spans(&store, alloc, &list, &ix, cmd, cmd);
    defer alloc.free(got);

    try testing.expectEqual(@as(usize, 3), got.len);
    // Only the red span's own measured extent counts: 4000 - 2000.
    try testing.expectEqual(@as(i64, 2000), brokenMs(got));
}

// --- store-backed fixture for thrash and the assembled report ---

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    work: std.Io.Dir,

    fn deinit(self: *Fixture) void {
        self.work.close(std.testing.io);
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, body: []const u8) !void {
        try self.work.writeFile(std.testing.io, .{ .sub_path = path, .data = body });
        const r = try moment.capture(&self.store, self.work, .poll, .{
            .enabled = true,
            .keyframe_interval = 4,
        });
        if (r == .captured) self.store.alloc.free(r.captured.branch);
    }
};

fn fixture(alloc: std.mem.Allocator) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    const store = try Store.init(io, alloc, tmp.dir);
    try tmp.dir.createDirPath(io, "work");
    const work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    return .{ .tmp = tmp, .store = store, .work = work };
}

test "a file rewritten to a third value is thrash, one written once is not" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.write("settled.txt", "v0");
    try f.write("churn.txt", "c0");
    try f.write("churn.txt", "c1");
    try f.write("churn.txt", "c2");
    try f.write("churn.txt", "c3");
    // Written exactly once across the range, and left alone after.
    try f.write("settled.txt", "v1");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    const got = try thrash(&f.store, alloc, all);
    defer freeThrash(alloc, got);

    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("churn.txt", got[0].path);
    try testing.expect(got[0].writes >= 3);
}

test "a file put back where it started is a revert, not thrash" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.write("a.txt", "original");
    try f.write("a.txt", "experiment");
    try f.write("a.txt", "original");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    const got = try thrash(&f.store, alloc, all);
    defer freeThrash(alloc, got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

test "a report names what landed, how long it was broken, and what broke it" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.write("keep.txt", "one");
    try f.write("keep.txt", "two");
    try f.write("breaker.txt", "boom");
    try f.write("breaker.txt", "still boom");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expectEqual(@as(usize, 4), all.len);

    const cmd = verdict.commandHash("check");
    for (all, 0..) |m, i| try recordResult(&f.store, m, cmd, if (i < 2) .green else .red);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    const r = try build(&f.store, alloc, all, &ix, cmd, cmd);
    defer r.deinit(alloc);

    try testing.expectEqual(@as(usize, 4), r.moments);
    try testing.expectEqual(@as(usize, 4), r.graded);
    try testing.expectEqual(@as(usize, 2), r.spans.len);
    try testing.expectEqual(r.spans[1].durationMs(), r.broken_ms);

    // keep.txt changed one -> two and breaker.txt appeared.
    try testing.expectEqual(@as(usize, 2), r.landed);
    try testing.expectEqualStrings("breaker.txt", r.landed_paths[0]);
    try testing.expectEqualStrings("keep.txt", r.landed_paths[1]);

    // The first red span opens at index 2, so the blame is what index 2 changed.
    try testing.expectEqual(@as(usize, 1), r.broke_paths.len);
    try testing.expectEqualStrings("breaker.txt", r.broke_paths[0]);
}

fn renderToString(alloc: std.mem.Allocator, r: Report, json: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = w.toArrayList();
    if (json) try renderJson(&w.writer, r) else try render(&w.writer, r);
    return alloc.dupe(u8, w.written());
}

/// Count quotes that actually delimit a JSON string, skipping any byte that a
/// backslash escaped. A balanced count is the cheap proof that escaping held.
fn unescapedQuotes(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '"') n += 1;
    }
    return n;
}

test "json output carries the contract keys and balanced quoting" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.write("a.txt", "one");
    try f.write("a.txt", "two");
    try f.write("b.txt", "three");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    const cmd = verdict.commandHash("check");
    for (all, 0..) |m, i| try recordResult(&f.store, m, cmd, if (i == 2) .red else .green);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    const r = try build(&f.store, alloc, all, &ix, cmd, cmd);
    defer r.deinit(alloc);

    const json = try renderToString(alloc, r, true);
    defer alloc.free(json);

    for ([_][]const u8{
        "\"moments\":",     "\"graded\":", "\"from_ms\":", "\"to_ms\":",
        "\"broken_ms\":",   "\"landed\":", "\"spans\":",   "\"landed_paths\":",
        "\"broke_paths\":", "\"thrash\":", "\"result\":",  "\"from_index\":",
    }) |key| {
        try testing.expect(std.mem.indexOf(u8, json, key) != null);
    }
    try testing.expectEqual(@as(u8, '{'), json[0]);
    try testing.expectEqual(@as(u8, '}'), json[json.len - 1]);
    try testing.expectEqual(@as(usize, 0), unescapedQuotes(json) % 2);

    const human = try renderToString(alloc, r, false);
    defer alloc.free(human);
    try testing.expect(std.mem.indexOf(u8, human, "broken for ") != null);
    try testing.expect(std.mem.indexOf(u8, human, "landed: ") != null);
}

test "json escapes quotes, backslashes and control bytes in paths" {
    const alloc = testing.allocator;

    const landed = [_][]const u8{"he said \"hi\"\n\\x"};
    const r = Report{
        .spans = &.{},
        .thrash = &.{},
        .broken_ms = 0,
        .landed = landed.len,
        .landed_paths = &landed,
        .broke_paths = &.{},
        .from_ms = 0,
        .to_ms = 0,
        .moments = 0,
        .graded = 0,
    };

    const json = try renderToString(alloc, r, true);
    defer alloc.free(json);

    try testing.expect(std.mem.indexOf(u8, json, "\\\"hi\\\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\\\\x") != null);
    // Two for the key, two for the value, and nothing leaked out of the string.
    try testing.expectEqual(@as(usize, 0), unescapedQuotes(json) % 2);
}

test "duration formatting covers the whole range" {
    const alloc = testing.allocator;
    const cases = [_]struct { ms: i64, want: []const u8 }{
        .{ .ms = 0, .want = "0ms" },
        .{ .ms = 999, .want = "999ms" },
        .{ .ms = 1000, .want = "1s" },
        .{ .ms = 59_000, .want = "59s" },
        .{ .ms = 121_000, .want = "2m01s" },
        .{ .ms = 3_720_000, .want = "1h02m" },
    };
    for (cases) |c| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(alloc);
        var w = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
        defer out = w.toArrayList();
        try writeDuration(&w.writer, c.ms);
        try testing.expectEqualStrings(c.want, w.written());
    }
}
