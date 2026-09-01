const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const config = @import("config.zig");
const moment = @import("moment.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// The verdict store: what a given tree did when a given check ran against it.
///
/// A verdict is keyed by `(tree Oid, tier, command hash, declared-input digest)`
/// and never by a moment id, which is what makes "a tree is never graded twice,
/// ever" true even across branches, forks, rewinds and retention trims. Two
/// moments that happen to hold identical content share one verdict for free.
///
/// The input digest is the environment dimension. A graded run sees whatever
/// the project ignores, so a lockfile, a `.env` or a toolchain outside the tree
/// can decide the answer without appearing in the tree at all; `checks.inputs`
/// names those files and their itemized digest joins the key. It is zero when
/// nothing is declared, which is exactly the key this store always used.
///
/// `lookup` is the memoization decision and matches the whole key, freshness
/// included. `Index` is the historical record — the newest verdict for a tree at
/// a tier under a command, whatever environment produced it — which is what the
/// UI, `@green` and the grading policy read.
///
/// A verdict is not a boolean. `Result` is the claim; the warrant fields beside
/// it are why the claim is worth anything. Nothing here ever gates: no push is
/// blocked and no build fails on a red. A signal wired to block becomes a
/// target, and an agent optimised against it stops being signal.
pub const log_path = "verdicts";

pub const Tier = enum {
    /// Typecheck, lint: cheap enough to run at any quiet point.
    fast,
    /// The suite: run at idle or on demand.
    full,

    pub fn label(self: Tier) []const u8 {
        return @tagName(self);
    }

    pub fn fromLabel(s: []const u8) ?Tier {
        if (std.mem.eql(u8, s, "fast")) return .fast;
        if (std.mem.eql(u8, s, "full")) return .full;
        return null;
    }
};

pub const Result = enum {
    green,
    red,

    pub fn label(self: Result) []const u8 {
        return @tagName(self);
    }
};

/// What actually happened to the check process, which is a different question
/// from what the check decided.
///
/// A red that means "the suite failed on this tree" is a fact about the code and
/// is worth keeping forever. A red that means "the machine slept, the OOM killer
/// fired, or the run hit its deadline" is a fact about the machine and binds to
/// no tree at all. Caching the second as the first is how a transient kill
/// becomes a permanent verdict nothing ever re-runs.
pub const Outcome = enum {
    /// The check exited zero.
    pass,
    /// The check exited non-zero of its own accord.
    fail,
    /// The check was still running when its deadline passed.
    timeout,
    /// The run could not be performed: no fork, no clone, no exec.
    @"error",
    /// The check died on a signal it did not choose.
    cancelled,

    /// Only a decision the check itself reached may be remembered.
    pub fn cacheable(self: Outcome) bool {
        return self == .pass or self == .fail;
    }

    pub fn result(self: Outcome) Result {
        return if (self == .pass) .green else .red;
    }

    pub fn label(self: Outcome) []const u8 {
        return @tagName(self);
    }
};

/// Did the same actor author both the code and the check across this span?
pub const Independence = enum {
    /// Code and check have different authors: the check is a second opinion.
    independent,
    /// One actor wrote both, so a pass proves only that it agrees with itself.
    co_authored,
    /// No attribution recorded for the span; the axis says nothing.
    unknown,

    pub fn label(self: Independence) []const u8 {
        return @tagName(self);
    }
};

/// Would the check have failed on the *previous* tree? A check that passes on
/// the code and on the code's predecessor did not test the change.
pub const Discrimination = enum {
    /// The check failed on the previous tree, so it responds to this change.
    discriminating,
    /// The check passed on the previous tree too: it did not test the change.
    vacuous,
    /// Not measured (the check files did not change, or the run was skipped).
    unknown,

    pub fn label(self: Discrimination) []const u8 {
        return @tagName(self);
    }
};

fn enumFromLabel(comptime T: type, s: []const u8, fallback: T) T {
    inline for (@typeInfo(T).@"enum".fields) |f| {
        if (std.mem.eql(u8, s, f.name)) return @field(T, f.name);
    }
    return fallback;
}

pub const Verdict = struct {
    /// The full flat tree Oid of the graded state.
    tree: Oid,
    tier: Tier,
    /// BLAKE3 of the exact command string, so editing the check invalidates
    /// every verdict it produced without anyone having to remember to.
    command: Oid,
    result: Result,
    exit_code: i32,
    duration_ms: u32,
    ms: i64,
    /// The read-set recorded for this run, or zero when none was captured.
    readset: Oid,
    independence: Independence = .unknown,
    /// How many of the changed paths the check actually read.
    relevance_hit: u16 = 0,
    relevance_total: u16 = 0,
    discrimination: Discrimination = .unknown,
    /// The declared-input digest this run was made under, zero when none were
    /// declared. Also the object id of the itemized manifest, so a miss can name
    /// the file that caused it.
    inputs: Oid = Oid.zero(),
    /// Wall clock at which the check ran, which is what `checks.fresh` ages.
    /// Zero on a verdict recorded before this field existed.
    ran_ms: i64 = 0,
    outcome: Outcome = .pass,

    pub fn isGreen(self: Verdict) bool {
        return self.result == .green;
    }

    /// True when the verdict is green but the warrant says the green is not
    /// worth much. This is the case the whole warrant exists to name.
    pub fn isHollow(self: Verdict) bool {
        if (self.result != .green) return false;
        return self.independence == .co_authored or self.discrimination == .vacuous;
    }
};

pub const Key = struct {
    tree: Oid,
    tier: Tier,
    command: Oid,
    inputs: Oid = Oid.zero(),
};

// --- encoding ---

fn formatLine(alloc: std.mem.Allocator, v: Verdict) ![]u8 {
    var tree_hex: [Oid.len * 2]u8 = undefined;
    var cmd_hex: [Oid.len * 2]u8 = undefined;
    var rs_hex: [Oid.len * 2]u8 = undefined;
    var in_hex: [Oid.len * 2]u8 = undefined;
    _ = v.tree.toHex(&tree_hex);
    _ = v.command.toHex(&cmd_hex);
    _ = v.readset.toHex(&rs_hex);
    _ = v.inputs.toHex(&in_hex);
    return std.fmt.allocPrint(
        alloc,
        "{s} {s} {s} {s} {d} {d} {d} {s} {s} {d} {d} {s} {s} {d} {s}\n",
        .{
            &tree_hex,
            v.tier.label(),
            &cmd_hex,
            v.result.label(),
            v.exit_code,
            v.duration_ms,
            v.ms,
            &rs_hex,
            v.independence.label(),
            v.relevance_hit,
            v.relevance_total,
            v.discrimination.label(),
            &in_hex,
            v.ran_ms,
            v.outcome.label(),
        },
    );
}

fn parseLine(line: []const u8) !Verdict {
    var it = std.mem.splitScalar(u8, line, ' ');
    const tree_s = it.next() orelse return error.InvalidVerdict;
    const tier_s = it.next() orelse return error.InvalidVerdict;
    const cmd_s = it.next() orelse return error.InvalidVerdict;
    const res_s = it.next() orelse return error.InvalidVerdict;
    const exit_s = it.next() orelse return error.InvalidVerdict;
    const dur_s = it.next() orelse return error.InvalidVerdict;
    const ms_s = it.next() orelse return error.InvalidVerdict;
    const rs_s = it.next() orelse return error.InvalidVerdict;
    const ind_s = it.next() orelse return error.InvalidVerdict;
    const hit_s = it.next() orelse return error.InvalidVerdict;
    const tot_s = it.next() orelse return error.InvalidVerdict;
    const dis_s = it.next() orelse return error.InvalidVerdict;

    // Everything past here postdates the format, so a line written before it
    // still parses: no declared inputs, no run time, and the outcome implied by
    // the result it already recorded.
    const in_s = it.next() orelse "";
    const ran_s = it.next() orelse "";
    const out_s = it.next() orelse "";

    const result = enumFromLabel(Result, res_s, .red);
    return .{
        .tree = Oid.fromHex(tree_s) catch return error.InvalidVerdict,
        .tier = Tier.fromLabel(tier_s) orelse return error.InvalidVerdict,
        .command = Oid.fromHex(cmd_s) catch return error.InvalidVerdict,
        .result = result,
        .exit_code = std.fmt.parseInt(i32, exit_s, 10) catch return error.InvalidVerdict,
        .duration_ms = std.fmt.parseInt(u32, dur_s, 10) catch 0,
        .ms = std.fmt.parseInt(i64, ms_s, 10) catch 0,
        .readset = Oid.fromHex(rs_s) catch Oid.zero(),
        .independence = enumFromLabel(Independence, ind_s, .unknown),
        .relevance_hit = std.fmt.parseInt(u16, hit_s, 10) catch 0,
        .relevance_total = std.fmt.parseInt(u16, tot_s, 10) catch 0,
        .discrimination = enumFromLabel(Discrimination, dis_s, .unknown),
        .inputs = Oid.fromHex(in_s) catch Oid.zero(),
        .ran_ms = std.fmt.parseInt(i64, ran_s, 10) catch 0,
        .outcome = enumFromLabel(Outcome, out_s, if (result == .green) .pass else .fail),
    };
}

/// BLAKE3 of a check command string, domain-separated from every other digest.
pub fn commandHash(command: []const u8) Oid {
    var hasher = oid.Hasher.init();
    // Deliberately still "gr-check-v1": this digest is a persisted verdict
    // cache key, and changing it would throw away every recorded verdict.
    hasher.update("gr-check-v1");
    hasher.update(command);
    return hasher.finalOid();
}

// --- store ---

/// Append a verdict, unless its outcome says the run never reached a decision.
/// The refusal lives here rather than at each call site because a verdict that
/// binds to an infrastructure failure is worthless from every direction.
pub fn record(store: *Store, v: Verdict) !void {
    if (!v.outcome.cacheable()) return;
    const alloc = store.alloc;
    const line = try formatLine(alloc, v);
    defer alloc.free(line);
    try applog.append(store, log_path, line);

    // Retention sweeps from here rather than from a caller, because every call
    // site is somewhere that just finished running a check and has no reason to
    // know this log has a size. A failed sweep is not a failed record: the
    // verdict is already durable, and the log being longer than it needs to be
    // costs nothing but bytes.
    if (sweeps.fetchAdd(1, .monotonic) % sweep_interval != sweep_interval - 1) return;
    if (logLength(store) < sweep_floor) return;
    trim(store, alloc, nowMillis(store.io), settings(store, alloc)) catch {};
}

// --- retention ---

/// How many recorded verdicts pass between retention sweeps, counted per
/// process rather than out of the log, which is the same trade `moment.zig`
/// makes at `trim_interval`: a sweep is a full read and rewrite, and it only has
/// to stay off the critical path of every grade. Recording a verdict already
/// cost a check run, so the interval can be small.
const sweep_interval: usize = 128;

/// And how big the log has to be before a sweep is worth reading it at all.
/// Under a few hundred records there is nothing to reclaim that matters, and
/// leaving small logs alone is also what keeps the trigger from being a second,
/// quieter retention policy that nobody configured.
const sweep_floor: u64 = 64 * 1024;

var sweeps: std.atomic.Value(usize) = .init(0);

fn logLength(store: *Store) u64 {
    const file = store.root.openFile(store.io, log_path, .{}) catch return 0;
    defer file.close(store.io);
    return file.length(store.io) catch 0;
}

pub const Settings = struct {
    /// Retention window in seconds, applied to greens only.
    ///
    /// Ninety days rather than the fortnight moments keep: a moment dropped
    /// costs a state nobody was going to rewind to, while a verdict dropped
    /// costs a suite re-run, and a tree that comes back — a rewind, a revert, a
    /// branch picked up again months later — should still be answered from the
    /// log rather than from the CPU.
    retain_s: i64 = 90 * 24 * 60 * 60,
    /// The hard bound underneath the window, since reds never age out and
    /// something has to stop an infinitely long log. Twenty thousand records is
    /// a few megabytes.
    max: usize = 20_000,
};

pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "verdicts.retain")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.retain_s = moment.parseDuration(v, out.retain_s);
        }
    } else |_| {}
    return out;
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

/// Drop verdicts that can no longer answer anything, in increasing order of what
/// dropping one costs the user.
///
/// First, superseded records. Later records win, so only the newest record for a
/// full key is ever reachable; every earlier one answers a question that has
/// already been answered again. Reclaiming those is free — no lookup that
/// succeeded before can miss afterwards.
///
/// Then aged-out greens, and only greens, on exactly the reasoning `isStale`
/// gives for ageing them at lookup: a pass is a measurement that goes off, a red
/// is a fact about the code. A red is dropped by nothing but the cap.
///
/// Survivors keep their record order, so "later records win" reads the same
/// after a sweep as before it.
pub fn trim(store: *Store, alloc: std.mem.Allocator, now_ms: i64, set: Settings) !void {
    const all = try readAll(store, alloc);
    defer alloc.free(all);
    if (all.len == 0) return;

    var keep = try alloc.alloc(bool, all.len);
    defer alloc.free(keep);
    @memset(keep, false);

    var newest = std.AutoHashMap([Oid.len + 1 + Oid.len + Oid.len]u8, usize).init(alloc);
    defer newest.deinit();
    for (all, 0..) |v, i| try newest.put(fullKeyBytes(.{
        .tree = v.tree,
        .tier = v.tier,
        .command = v.command,
        .inputs = v.inputs,
    }), i);
    var it = newest.valueIterator();
    while (it.next()) |i| keep[i.*] = true;

    const cutoff_ms = now_ms - set.retain_s * 1000;
    for (all, 0..) |v, i| {
        if (!keep[i]) continue;
        if (v.result != .green) continue;
        // A record with no timestamp cannot be shown to be outside the window,
        // and dropping it on a guess costs a re-run.
        if (v.ms == 0) continue;
        if (v.ms < cutoff_ms) keep[i] = false;
    }

    var kept: usize = 0;
    for (keep) |k| {
        if (k) kept += 1;
    }
    if (set.max != 0 and kept > set.max) {
        var over = kept - set.max;
        for (keep) |*k| {
            if (over == 0) break;
            if (!k.*) continue;
            k.* = false;
            over -= 1;
            kept -= 1;
        }
    }

    // Nothing to reclaim, so nothing is rewritten. A sweep that rewrites the log
    // to exactly what it already said is a window in which a crash can lose a
    // record for no gain at all.
    if (kept == all.len) return;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (all, 0..) |v, i| {
        if (!keep[i]) continue;
        const line = try formatLine(alloc, v);
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    try applog.rewrite(store, log_path, out.items);
}

/// Every verdict in record order. Malformed lines are skipped. Caller frees.
pub fn readAll(store: *Store, alloc: std.mem.Allocator) ![]Verdict {
    const data = try applog.readAll(store, alloc, log_path);
    defer alloc.free(data);

    var list: std.ArrayList(Verdict) = .empty;
    errdefer list.deinit(alloc);

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const v = parseLine(line) catch continue;
        try list.append(alloc, v);
    }
    return list.toOwnedSlice(alloc);
}

/// The verdict for a key, or null. Later records win, so a re-grade after a
/// flaky run supersedes without anyone rewriting history.
pub fn lookup(store: *Store, alloc: std.mem.Allocator, key: Key) !?Verdict {
    return lookupFresh(store, alloc, key, 0, 0);
}

/// `lookup`, plus an age ceiling on greens.
///
/// `fresh_ms` of zero is the whole existing behaviour: a pass answers forever.
/// Above zero a pass older than the window stops answering, and so does one
/// whose run time was never recorded, because "unknown age" cannot be shown to
/// be inside any window. Reds are never aged out: re-running them is the job of
/// an explicit re-grade, not of a clock.
pub fn lookupFresh(
    store: *Store,
    alloc: std.mem.Allocator,
    key: Key,
    now_ms: i64,
    fresh_ms: i64,
) !?Verdict {
    const all = try readAll(store, alloc);
    defer alloc.free(all);

    var found: ?Verdict = null;
    for (all) |v| {
        if (!v.tree.eql(key.tree)) continue;
        if (v.tier != key.tier) continue;
        if (!v.command.eql(key.command)) continue;
        if (!v.inputs.eql(key.inputs)) continue;
        found = v;
    }
    if (found) |v| {
        if (isStale(v, now_ms, fresh_ms)) return null;
    }
    return found;
}

/// Whether a green has aged past the window. False whenever no window is set.
pub fn isStale(v: Verdict, now_ms: i64, fresh_ms: i64) bool {
    if (fresh_ms <= 0) return false;
    if (v.result != .green) return false;
    if (v.ran_ms == 0) return true;
    return now_ms - v.ran_ms > fresh_ms;
}

/// An in-memory index for callers that ask about many trees at once (the
/// grading policy, `sdt recap`, the moment listing). One pass over the log
/// instead of one pass per question.
pub const Index = struct {
    map: std.AutoHashMap([Oid.len + 1 + Oid.len]u8, Verdict),

    pub fn load(store: *Store, alloc: std.mem.Allocator) !Index {
        var self = Index{ .map = std.AutoHashMap([Oid.len + 1 + Oid.len]u8, Verdict).init(alloc) };
        errdefer self.map.deinit();

        const all = try readAll(store, alloc);
        defer alloc.free(all);
        for (all) |v| try self.map.put(keyBytes(.{
            .tree = v.tree,
            .tier = v.tier,
            .command = v.command,
        }), v);
        return self;
    }

    pub fn deinit(self: *Index) void {
        self.map.deinit();
    }

    pub fn get(self: *const Index, key: Key) ?Verdict {
        return self.map.get(keyBytes(key));
    }

    /// The verdict for a tree at either tier, preferring `full` because it is
    /// the stronger claim. Callers that must distinguish the two ask directly.
    pub fn best(self: *const Index, tree: Oid, command_fast: Oid, command_full: Oid) ?Verdict {
        if (self.get(.{ .tree = tree, .tier = .full, .command = command_full })) |v| return v;
        return self.get(.{ .tree = tree, .tier = .fast, .command = command_fast });
    }
};

/// The memoization key in full, declared inputs included. `keyBytes` is
/// deliberately the coarser index key; retention has to reason about what a
/// `lookup` can reach, and a lookup matches inputs too.
fn fullKeyBytes(key: Key) [Oid.len + 1 + Oid.len + Oid.len]u8 {
    var out: [Oid.len + 1 + Oid.len + Oid.len]u8 = undefined;
    @memcpy(out[0 .. Oid.len + 1 + Oid.len], &keyBytes(key));
    @memcpy(out[Oid.len + 1 + Oid.len ..], &key.inputs.bytes);
    return out;
}

fn keyBytes(key: Key) [Oid.len + 1 + Oid.len]u8 {
    var out: [Oid.len + 1 + Oid.len]u8 = undefined;
    @memcpy(out[0..Oid.len], &key.tree.bytes);
    out[Oid.len] = @intFromEnum(key.tier);
    @memcpy(out[Oid.len + 1 ..], &key.command.bytes);
    return out;
}

// --- tests ---

const testing = std.testing;

fn sample(tree: Oid, tier: Tier, cmd: Oid, result: Result) Verdict {
    return .{
        .tree = tree,
        .tier = tier,
        .command = cmd,
        .result = result,
        .exit_code = if (result == .green) 0 else 1,
        .duration_ms = 1234,
        .ms = 1_700_000_000_000,
        .readset = Oid.zero(),
        .outcome = if (result == .green) .pass else .fail,
    };
}

test "record and look up a verdict" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-a");
    const cmd = commandHash("zig build test");
    try record(&store, sample(tree, .full, cmd, .green));

    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(Result.green, got.result);
    try testing.expectEqual(@as(u32, 1234), got.duration_ms);

    // A different tier is a different question with no answer yet.
    try testing.expect((try lookup(&store, alloc, .{ .tree = tree, .tier = .fast, .command = cmd })) == null);
}

test "editing the check command invalidates its verdicts" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-a");
    try record(&store, sample(tree, .full, commandHash("make test"), .green));

    const other = commandHash("make test -j8");
    try testing.expect((try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = other })) == null);
}

test "a later record supersedes an earlier one" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-a");
    const cmd = commandHash("pytest");
    try record(&store, sample(tree, .full, cmd, .red));
    try record(&store, sample(tree, .full, cmd, .green));

    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(Result.green, got.result);
}

test "the warrant survives a roundtrip" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-w");
    const cmd = commandHash("bun test");
    var v = sample(tree, .full, cmd, .green);
    v.independence = .co_authored;
    v.relevance_hit = 5;
    v.relevance_total = 5;
    v.discrimination = .vacuous;
    try record(&store, v);

    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(Independence.co_authored, got.independence);
    try testing.expectEqual(Discrimination.vacuous, got.discrimination);
    try testing.expectEqual(@as(u16, 5), got.relevance_hit);
    try testing.expect(got.isGreen());
    // Green, and hollow. Naming this is the entire point of the warrant.
    try testing.expect(got.isHollow());
}

test "an independent discriminating green is not hollow" {
    const cmd = commandHash("c");
    var v = sample(Oid.ofBytes("t"), .full, cmd, .green);
    v.independence = .independent;
    v.discrimination = .discriminating;
    try testing.expect(!v.isHollow());
}

test "a verdict log written before declared inputs still parses" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("legacy-tree");
    const cmd = commandHash("zig build test");
    var tree_hex: [Oid.len * 2]u8 = undefined;
    var cmd_hex: [Oid.len * 2]u8 = undefined;
    var rs_hex: [Oid.len * 2]u8 = undefined;
    _ = tree.toHex(&tree_hex);
    _ = cmd.toHex(&cmd_hex);
    _ = Oid.zero().toHex(&rs_hex);

    // Exactly the twelve fields the format had before this change.
    const line = try std.fmt.allocPrint(
        alloc,
        "{s} full {s} green 0 4321 1700000000000 {s} independent 3 4 discriminating\n",
        .{ &tree_hex, &cmd_hex, &rs_hex },
    );
    defer alloc.free(line);
    try applog.append(&store, log_path, line);

    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(Result.green, got.result);
    try testing.expectEqual(@as(u32, 4321), got.duration_ms);
    try testing.expectEqual(Independence.independent, got.independence);
    try testing.expectEqual(Discrimination.discriminating, got.discrimination);
    // The new fields take the only values that are honest about an old line.
    try testing.expect(got.inputs.isZero());
    try testing.expectEqual(@as(i64, 0), got.ran_ms);
    try testing.expectEqual(Outcome.pass, got.outcome);

    // A legacy red implies a failure, not an infrastructure problem.
    const red_line = try std.fmt.allocPrint(
        alloc,
        "{s} fast {s} red 1 10 1700000000000 {s} unknown 0 0 unknown\n",
        .{ &tree_hex, &cmd_hex, &rs_hex },
    );
    defer alloc.free(red_line);
    try applog.append(&store, log_path, red_line);
    const red = (try lookup(&store, alloc, .{ .tree = tree, .tier = .fast, .command = cmd })).?;
    try testing.expectEqual(Outcome.fail, red.outcome);
}

test "a repo that declares no inputs keeps byte-identical keys" {
    const tree = Oid.ofBytes("t");
    const cmd = commandHash("make");
    const key = Key{ .tree = tree, .tier = .full, .command = cmd };

    // The default is the zero digest, so nothing about an existing repo's key
    // moves and every recorded verdict stays addressable.
    try testing.expect(key.inputs.isZero());

    var expected: [Oid.len + 1 + Oid.len]u8 = undefined;
    @memcpy(expected[0..Oid.len], &tree.bytes);
    expected[Oid.len] = @intFromEnum(Tier.full);
    @memcpy(expected[Oid.len + 1 ..], &cmd.bytes);
    try testing.expectEqualSlices(u8, &expected, &keyBytes(key));

    // And the index key does not move when inputs are declared: the log is the
    // historical record, not the memoization decision.
    var with = key;
    with.inputs = Oid.ofBytes("some lockfile digest");
    try testing.expectEqualSlices(u8, &keyBytes(key), &keyBytes(with));
}

test "a declared input changing is a different key" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-a");
    const cmd = commandHash("bun test");
    const before = Oid.ofBytes("lockfile v1");

    var v = sample(tree, .full, cmd, .green);
    v.inputs = before;
    try record(&store, v);

    try testing.expect((try lookup(&store, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = cmd,
        .inputs = before,
    })) != null);

    // The lockfile moved, so the memoized answer no longer applies.
    try testing.expect((try lookup(&store, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = cmd,
        .inputs = Oid.ofBytes("lockfile v2"),
    })) == null);

    // The log still remembers it happened, which is what the UI reads.
    var ix = try Index.load(&store, alloc);
    defer ix.deinit();
    try testing.expect(ix.get(.{ .tree = tree, .tier = .full, .command = cmd }) != null);
}

test "a pass stops answering once it is older than the freshness window" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-f");
    const cmd = commandHash("pytest");
    const key = Key{ .tree = tree, .tier = .full, .command = cmd };
    const now: i64 = 1_700_000_000_000;

    var green = sample(tree, .full, cmd, .green);
    green.ran_ms = now - 10 * std.time.ms_per_min;
    try record(&store, green);

    // No window configured is the existing behaviour: it answers forever.
    try testing.expect((try lookupFresh(&store, alloc, key, now, 0)) != null);
    // Inside the window it still answers.
    try testing.expect((try lookupFresh(&store, alloc, key, now, 30 * std.time.ms_per_min)) != null);
    // Past it, it does not.
    try testing.expect((try lookupFresh(&store, alloc, key, now, 5 * std.time.ms_per_min)) == null);

    // A red is a fact about the code, not a measurement that goes off.
    const red_tree = Oid.ofBytes("tree-r");
    var red = sample(red_tree, .full, cmd, .red);
    red.ran_ms = now - 10 * std.time.ms_per_min;
    try record(&store, red);
    try testing.expect((try lookupFresh(&store, alloc, .{
        .tree = red_tree,
        .tier = .full,
        .command = cmd,
    }, now, std.time.ms_per_min)) != null);

    // A green whose age is unknown cannot be shown to be inside any window.
    const old_tree = Oid.ofBytes("tree-o");
    try record(&store, sample(old_tree, .full, cmd, .green));
    try testing.expect((try lookupFresh(&store, alloc, .{
        .tree = old_tree,
        .tier = .full,
        .command = cmd,
    }, now, std.time.ms_per_min)) == null);
}

test "a run that never reached a decision is never recorded" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-k");
    const cmd = commandHash("zig build test");

    for ([_]Outcome{ .timeout, .@"error", .cancelled }) |o| {
        var v = sample(tree, .full, cmd, .red);
        v.outcome = o;
        try testing.expect(!o.cacheable());
        try record(&store, v);
    }

    // Nothing was written, so the next lookup runs the check instead of
    // serving a red that says only that the machine misbehaved.
    try testing.expect((try lookup(&store, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = cmd,
    })) == null);

    var fail = sample(tree, .full, cmd, .red);
    fail.outcome = .fail;
    try record(&store, fail);
    try testing.expect((try lookup(&store, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = cmd,
    })) != null);
}

test "the outcome survives a roundtrip" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-x");
    const cmd = commandHash("x");
    var v = sample(tree, .full, cmd, .red);
    v.outcome = .fail;
    v.inputs = Oid.ofBytes("inputs");
    v.ran_ms = 1_700_000_123_456;
    try record(&store, v);

    const got = (try lookup(&store, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = cmd,
        .inputs = v.inputs,
    })).?;
    try testing.expectEqual(Outcome.fail, got.outcome);
    try testing.expectEqual(@as(i64, 1_700_000_123_456), got.ran_ms);
    try testing.expect(got.inputs.eql(v.inputs));
}

test "index answers many trees in one pass" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = commandHash("check");
    for (0..50) |i| {
        const body = try std.fmt.allocPrint(alloc, "tree-{d}", .{i});
        defer alloc.free(body);
        try record(&store, sample(Oid.ofBytes(body), .fast, cmd, if (i % 2 == 0) .green else .red));
    }

    var ix = try Index.load(&store, alloc);
    defer ix.deinit();

    try testing.expectEqual(Result.green, ix.get(.{
        .tree = Oid.ofBytes("tree-0"),
        .tier = .fast,
        .command = cmd,
    }).?.result);
    try testing.expectEqual(Result.red, ix.get(.{
        .tree = Oid.ofBytes("tree-1"),
        .tier = .fast,
        .command = cmd,
    }).?.result);
    try testing.expect(ix.get(.{
        .tree = Oid.ofBytes("tree-999"),
        .tier = .fast,
        .command = cmd,
    }) == null);
}

test "retention drops superseded records and keeps the answer" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-s");
    const cmd = commandHash("zig build test");
    const now: i64 = 1_700_000_000_000;

    // The same question answered five times: only the last answer is reachable.
    for (0..5) |i| {
        var v = sample(tree, .full, cmd, if (i == 4) .green else .red);
        v.ms = now - @as(i64, @intCast(4 - i)) * std.time.ms_per_min;
        v.exit_code = @intCast(i);
        try record(&store, v);
    }

    try trim(&store, alloc, now, .{});

    const all = try readAll(&store, alloc);
    defer alloc.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);

    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(Result.green, got.result);
    try testing.expectEqual(@as(i32, 4), got.exit_code);
}

test "a superseded record for a different declared input is not the same record" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-i");
    const cmd = commandHash("bun test");
    const now: i64 = 1_700_000_000_000;

    var v1 = sample(tree, .full, cmd, .green);
    v1.inputs = Oid.ofBytes("lockfile v1");
    v1.ms = now;
    try record(&store, v1);
    var v2 = sample(tree, .full, cmd, .green);
    v2.inputs = Oid.ofBytes("lockfile v2");
    v2.ms = now;
    try record(&store, v2);

    try trim(&store, alloc, now, .{});

    // Two keys, two answers. Collapsing them would re-run a check that has
    // already been run under exactly the environment being asked about.
    for ([_]Oid{ v1.inputs, v2.inputs }) |in| {
        try testing.expect((try lookup(&store, alloc, .{
            .tree = tree,
            .tier = .full,
            .command = cmd,
            .inputs = in,
        })) != null);
    }
}

test "retention ages out a stale green and never ages out a red" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = commandHash("pytest");
    const now: i64 = 1_700_000_000_000;
    const day = std.time.ms_per_day;

    const old_green = Oid.ofBytes("old-green");
    var a = sample(old_green, .full, cmd, .green);
    a.ms = now - 100 * day;
    try record(&store, a);

    const new_green = Oid.ofBytes("new-green");
    var b = sample(new_green, .full, cmd, .green);
    b.ms = now - 3 * day;
    try record(&store, b);

    const old_red = Oid.ofBytes("old-red");
    var c = sample(old_red, .full, cmd, .red);
    c.ms = now - 100 * day;
    try record(&store, c);

    // A green with no timestamp cannot be shown to be outside the window.
    const undated = Oid.ofBytes("undated");
    var d = sample(undated, .full, cmd, .green);
    d.ms = 0;
    try record(&store, d);

    try trim(&store, alloc, now, .{ .retain_s = 90 * 24 * 60 * 60 });

    try testing.expect((try lookup(&store, alloc, .{ .tree = old_green, .tier = .full, .command = cmd })) == null);
    try testing.expect((try lookup(&store, alloc, .{ .tree = new_green, .tier = .full, .command = cmd })) != null);
    // A red is a fact about the code, not a measurement that goes off.
    try testing.expect((try lookup(&store, alloc, .{ .tree = old_red, .tier = .full, .command = cmd })) != null);
    try testing.expect((try lookup(&store, alloc, .{ .tree = undated, .tier = .full, .command = cmd })) != null);
}

test "the count cap keeps the newest verdicts and preserves their order" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = commandHash("make");
    const now: i64 = 1_700_000_000_000;

    // Reds, so nothing but the cap can decide what goes.
    for (0..50) |i| {
        const body = try std.fmt.allocPrint(alloc, "tree-{d}", .{i});
        defer alloc.free(body);
        var v = sample(Oid.ofBytes(body), .fast, cmd, .red);
        v.ms = now;
        try record(&store, v);
    }

    try trim(&store, alloc, now, .{ .max = 10 });

    const all = try readAll(&store, alloc);
    defer alloc.free(all);
    try testing.expectEqual(@as(usize, 10), all.len);
    for (all, 40..) |v, i| {
        const body = try std.fmt.allocPrint(alloc, "tree-{d}", .{i});
        defer alloc.free(body);
        try testing.expect(v.tree.eql(Oid.ofBytes(body)));
    }
}

test "a sweep that can reclaim nothing leaves the log alone" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cmd = commandHash("make");
    const now: i64 = 1_700_000_000_000;
    for (0..5) |i| {
        const body = try std.fmt.allocPrint(alloc, "tree-{d}", .{i});
        defer alloc.free(body);
        var v = sample(Oid.ofBytes(body), .fast, cmd, .green);
        v.ms = now;
        try record(&store, v);
    }

    const before = try applog.readAll(&store, alloc, log_path);
    defer alloc.free(before);
    try trim(&store, alloc, now, .{});
    const after = try applog.readAll(&store, alloc, log_path);
    defer alloc.free(after);
    try testing.expectEqualStrings(before, after);
}

test "verdicts.retain configures the window" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expectEqual(@as(i64, 90 * 24 * 60 * 60), settings(&store, alloc).retain_s);
    try config.set(&store, "verdicts.retain", "7d");
    try testing.expectEqual(@as(i64, 7 * 24 * 60 * 60), settings(&store, alloc).retain_s);
}

test "recording sweeps the log without anyone asking it to" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = Oid.ofBytes("tree-auto");
    const cmd = commandHash("zig build test");
    const now = nowMillis(io);

    // One key, answered over and over: every record but the last is superseded,
    // so a sweep that fires at all collapses the log to a single line.
    var i: usize = 0;
    while (i < 4 * sweep_interval and logLength(&store) < 2 * sweep_floor) : (i += 1) {
        var v = sample(tree, .full, cmd, .green);
        v.ms = now;
        v.exit_code = @intCast(i);
        try record(&store, v);
    }

    const all = try readAll(&store, alloc);
    defer alloc.free(all);
    try testing.expect(all.len < i);

    // And the answer the log exists to give is the one it still gives.
    const got = (try lookup(&store, alloc, .{ .tree = tree, .tier = .full, .command = cmd })).?;
    try testing.expectEqual(@as(i32, @intCast(i - 1)), got.exit_code);
}
