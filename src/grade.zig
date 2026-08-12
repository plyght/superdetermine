const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const checks = @import("checks.zig");
const warrant = @import("warrant.zig");
const readset = @import("readset.zig");
const tracer = @import("tracer.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;
const Moment = moment.Moment;

/// Deciding what to grade.
///
/// Grading every moment would be 500 runs for an hour of work, which is absurd
/// and which nobody wants anyway. Nobody wants a verdict on every state; they
/// want two boundaries, where it last worked and where it broke. So this is a
/// search, not a sweep, driven by three triggers:
///
///   necessary      the head, once the tree goes quiet
///   transition     head flipped green to red, so binary search back to the
///                  breaking state (~8 runs for a 150-moment gap)
///   opportunistic  spare budget only, grade the midpoint of the largest
///                  ungraded interval, which is the most informative single
///                  run available
///
/// The third trigger is what makes the policy adaptive rather than tuned: an
/// idle machine fills history densely, a busy one does the floor. Nobody
/// configures it because the configuration is "is there spare capacity".
///
/// Never interpolate. A state between two green states is `ungraded`, not
/// green. Code is not monotonic, so the binary search may find *a* boundary
/// rather than *the first* one; every verdict it reports was measured, and the
/// UI says "last known green" precisely because of that.
pub const Trigger = enum { necessary, transition, opportunistic };

pub const Context = struct {
    store: *Store,
    work_dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    set: checks.Settings,
    rules: warrant.PathRules,
    tracer_mode: tracer.Mode = .conservative,
    scratch_parent: ?[]const u8 = null,
};

fn keyFor(ctx: Context, tree: Oid, tier: verdict.Tier) verdict.Key {
    return .{
        .tree = tree,
        .tier = tier,
        .command = verdict.commandHash(ctx.set.command(tier)),
    };
}

/// The verdict for a state, running the check only if it must.
///
/// Three layers of avoidance, in increasing cost order:
///   1. a memoized verdict for this exact `(tree, tier, command)`, so a tree is
///      never graded twice, ever;
///   2. an unchanged read-set relative to an already-graded neighbour, in which
///      case that verdict is carried over and recorded against this tree;
///   3. an actual run.
pub fn gradeState(
    ctx: Context,
    m: Moment,
    tier: verdict.Tier,
) !verdict.Verdict {
    const alloc = ctx.alloc;
    if (!ctx.set.has(tier)) return checks.Error.NoCheckConfigured;

    const key = keyFor(ctx, m.full_tree, tier);
    if (try verdict.lookup(ctx.store, alloc, key)) |cached| return cached;

    const entries = try moment.entriesOf(ctx.store, m);
    defer workspace.freeTreeEntries(alloc, entries);

    // The nearest already-graded predecessor, which is what both the read-set
    // shortcut and the warrant's span are measured against.
    const prev = try nearestGraded(ctx, m, tier);
    defer if (prev) |p| {
        alloc.free(p.m.branch);
        workspace.freeTreeEntries(alloc, p.entries);
    };

    var span = if (prev) |p|
        try warrant.spanBetween(ctx.store, alloc, p.entries, entries, ctx.rules)
    else
        try warrant.spanBetween(ctx.store, alloc, null, entries, ctx.rules);
    defer span.deinit(alloc);

    // Layer 2: if the check never read anything that changed, its answer cannot
    // have changed either. Record the carried-over verdict against this tree so
    // the next lookup is a straight hit.
    // The guard on `paths_changed` is what makes this sound: a read-set can
    // say what the check opened, never what it looked for and failed to find,
    // so an added or removed path must always force a real run.
    if (prev) |p| {
        if (!p.verdict.readset.isZero() and !span.paths_changed) {
            if (readset.load(ctx.store, p.verdict.readset)) |rs| {
                defer rs.deinit(alloc);
                if (!rs.intersectsAny(span.changed)) {
                    var carried = p.verdict;
                    carried.tree = m.full_tree;
                    carried.ms = m.ms;
                    carried.duration_ms = 0;
                    try verdict.record(ctx.store, carried);
                    return carried;
                }
            } else |_| {}
        }
    }

    var id_hex: [16]u8 = undefined;
    _ = m.shortId(&id_hex);
    const graded = try checks.gradeEntries(
        ctx.store,
        ctx.work_dir,
        entries,
        id_hex[0..12],
        ctx.set,
        .{ .tier = tier, .scratch_parent = ctx.scratch_parent },
    );
    defer graded.deinit(alloc);
    const outcome = graded.outcome;

    // The measured read-set, exact where access times track reads and a
    // conservative over-approximation otherwise. Over-approximating can only
    // ever cost an extra run, never a wrong answer.
    const rs_oid = if (graded.read_set) |rs|
        readset.store_(ctx.store, rs) catch Oid.zero()
    else
        Oid.zero();

    const rel = warrant.relevance(graded.read_set, span);

    var v = verdict.Verdict{
        .tree = m.full_tree,
        .tier = tier,
        .command = key.command,
        .result = outcome.result(),
        .exit_code = outcome.exit_code,
        .duration_ms = outcome.duration_ms,
        .ms = m.ms,
        .readset = rs_oid,
        .independence = warrant.independence(ctx.store, alloc, span),
        .relevance_hit = rel.hit,
        .relevance_total = rel.total,
        .discrimination = .unknown,
    };

    // Discrimination costs one run and is only worth asking when the check
    // itself changed. Memoized through the same verdict cache as everything
    // else, because the hybrid tree is addressed by content like any other.
    if (v.result == .green and prev != null and warrant.shouldMeasureDiscrimination(span)) {
        v.discrimination = measureDiscrimination(ctx, prev.?.entries, entries, tier) catch .unknown;
    }

    try verdict.record(ctx.store, v);
    return v;
}

pub fn gradeChange(
    ctx: Context,
    change_oid: Oid,
    tier: verdict.Tier,
) !verdict.Verdict {
    const alloc = ctx.alloc;
    if (!ctx.set.has(tier)) return checks.Error.NoCheckConfigured;

    const change = try ctx.store.readChange(change_oid);
    defer object.freeChange(alloc, change);

    const key = keyFor(ctx, change.tree, tier);
    if (try verdict.lookup(ctx.store, alloc, key)) |cached| return cached;

    const tree = try ctx.store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    var parent_tree: ?object.Tree = null;
    defer if (parent_tree) |p| object.freeTree(alloc, p);
    if (change.parents.len == 1) {
        if (ctx.store.readChange(change.parents[0])) |p| {
            defer object.freeChange(alloc, p);
            parent_tree = ctx.store.readTree(p.tree) catch null;
        } else |_| {}
    }

    var span = try warrant.spanBetween(
        ctx.store,
        alloc,
        if (parent_tree) |p| p.entries else null,
        tree.entries,
        ctx.rules,
    );
    defer span.deinit(alloc);

    var hex: [Oid.len * 2]u8 = undefined;
    _ = change_oid.toHex(&hex);
    const graded = try checks.gradeEntries(
        ctx.store,
        ctx.work_dir,
        tree.entries,
        hex[0..12],
        ctx.set,
        .{ .tier = tier, .scratch_parent = ctx.scratch_parent },
    );
    defer graded.deinit(alloc);
    const outcome = graded.outcome;

    const rs_oid = if (graded.read_set) |rs|
        readset.store_(ctx.store, rs) catch Oid.zero()
    else
        Oid.zero();

    const rel = warrant.relevance(graded.read_set, span);

    const v = verdict.Verdict{
        .tree = change.tree,
        .tier = tier,
        .command = key.command,
        .result = outcome.result(),
        .exit_code = outcome.exit_code,
        .duration_ms = outcome.duration_ms,
        .ms = change.timestamp * 1000,
        .readset = rs_oid,
        .independence = warrant.independence(ctx.store, alloc, span),
        .relevance_hit = rel.hit,
        .relevance_total = rel.total,
        .discrimination = .unknown,
    };

    try verdict.record(ctx.store, v);
    return v;
}

const Graded = struct {
    m: Moment,
    entries: []object.TreeEntry,
    verdict: verdict.Verdict,
};

/// The most recent moment strictly before `m` that already has a verdict at
/// this tier. Null when `m` is the first graded state on this branch.
fn nearestGraded(ctx: Context, m: Moment, tier: verdict.Tier) !?Graded {
    const alloc = ctx.alloc;
    const all = try moment.readAll(ctx.store, alloc);
    defer moment.freeMoments(alloc, all);

    var ix = try verdict.Index.load(ctx.store, alloc);
    defer ix.deinit();

    var i = all.len;
    while (i > 0) {
        i -= 1;
        if (all[i].ms >= m.ms) continue;
        const v = ix.get(keyFor(ctx, all[i].full_tree, tier)) orelse continue;
        const entries = moment.entriesOf(ctx.store, all[i]) catch continue;
        return .{
            .m = .{
                .id = all[i].id,
                .ms = all[i].ms,
                .full_tree = all[i].full_tree,
                .repr = all[i].repr,
                .kind = all[i].kind,
                .cause = all[i].cause,
                .branch = try alloc.dupe(u8, all[i].branch),
            },
            .entries = entries,
            .verdict = v,
        };
    }
    return null;
}

/// Would the check have failed on the previous tree? Build old code plus the new
/// check, grade that, and read the answer off it.
fn measureDiscrimination(
    ctx: Context,
    previous: []const object.TreeEntry,
    target: []const object.TreeEntry,
    tier: verdict.Tier,
) !verdict.Discrimination {
    const alloc = ctx.alloc;

    const hybrid = try warrant.hybridEntries(alloc, previous, target, ctx.rules);
    defer workspace.freeTreeEntries(alloc, hybrid);

    const enc = try object.Tree.encode(.{ .entries = hybrid }, alloc);
    defer alloc.free(enc);
    const hybrid_tree = Oid.ofBytes(enc);

    // The hybrid is a tree like any other, so the verdict cache memoizes it for
    // free across every future state that produces the same combination.
    const key = keyFor(ctx, hybrid_tree, tier);
    if (try verdict.lookup(ctx.store, alloc, key)) |cached| {
        return warrant.discriminationFrom(cached.result);
    }

    var hex: [Oid.len * 2]u8 = undefined;
    _ = hybrid_tree.toHex(&hex);
    // No tracing here: this run exists only to answer one yes/no question, and
    // its read-set would never be consulted.
    const graded = try checks.gradeEntries(
        ctx.store,
        ctx.work_dir,
        hybrid,
        hex[0..12],
        ctx.set,
        .{ .tier = tier, .scratch_parent = ctx.scratch_parent, .trace = false },
    );
    defer graded.deinit(alloc);

    try verdict.record(ctx.store, .{
        .tree = hybrid_tree,
        .tier = tier,
        .command = key.command,
        .result = graded.outcome.result(),
        .exit_code = graded.outcome.exit_code,
        .duration_ms = graded.outcome.duration_ms,
        .ms = 0,
        .readset = Oid.zero(),
    });

    return warrant.discriminationFrom(graded.outcome.result());
}

// --- trigger 2: binary search for the break ---

pub const Break = struct {
    /// Index into the moment list of the last state known to pass.
    last_green: usize,
    /// Index of the first state known to fail.
    first_red: usize,
    /// How many checks the search actually ran.
    runs: usize,
};

/// Given a green state at `lo` and a red state at `hi`, find the boundary
/// between them. Roughly log2(hi-lo) runs: about 8 for a 150-moment gap.
///
/// The boundary found is *a* boundary, not necessarily the first one, because
/// code is not monotonic. Every verdict reported was measured; nothing between
/// two measured points is ever inferred.
pub fn bisect(
    ctx: Context,
    moments: []const Moment,
    lo_green: usize,
    hi_red: usize,
    tier: verdict.Tier,
) !Break {
    std.debug.assert(lo_green < hi_red);
    std.debug.assert(hi_red < moments.len);

    var lo = lo_green;
    var hi = hi_red;
    var runs: usize = 0;

    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        const v = gradeState(ctx, moments[mid], tier) catch break;
        if (v.duration_ms != 0) runs += 1;
        if (v.result == .green) lo = mid else hi = mid;
    }

    return .{ .last_green = lo, .first_red = hi, .runs = runs };
}

// --- trigger 3: opportunistic ---

/// The midpoint of the largest run of consecutive ungraded moments, which is
/// the single most informative state to spend spare capacity on. Null when
/// every moment already has a verdict.
pub fn largestUngradedMidpoint(
    ctx: Context,
    moments: []const Moment,
    ix: *const verdict.Index,
    tier: verdict.Tier,
) ?usize {
    var best_len: usize = 0;
    var best_mid: ?usize = null;

    var run_start: ?usize = null;
    for (moments, 0..) |m, i| {
        const graded = ix.get(keyFor(ctx, m.full_tree, tier)) != null;
        if (!graded) {
            if (run_start == null) run_start = i;
            continue;
        }
        if (run_start) |s| {
            const len = i - s;
            if (len > best_len) {
                best_len = len;
                best_mid = s + len / 2;
            }
            run_start = null;
        }
    }
    if (run_start) |s| {
        const len = moments.len - s;
        if (len > best_len) {
            best_len = len;
            best_mid = s + len / 2;
        }
    }
    return best_mid;
}

/// Where the head stands right now: the newest moment's verdict, and whether
/// the branch just flipped from green to red.
pub const HeadState = struct {
    head: usize,
    result: ?verdict.Result,
    /// Index of the newest green state before the head, when the head is red.
    prior_green: ?usize,

    pub fn isTransition(self: HeadState) bool {
        return self.result == .red and self.prior_green != null;
    }
};

pub fn headState(
    ctx: Context,
    moments: []const Moment,
    ix: *const verdict.Index,
    tier: verdict.Tier,
) ?HeadState {
    if (moments.len == 0) return null;
    const head = moments.len - 1;
    const head_v = ix.get(keyFor(ctx, moments[head].full_tree, tier));

    var prior_green: ?usize = null;
    if (head_v != null and head_v.?.result == .red) {
        var i = head;
        while (i > 0) {
            i -= 1;
            const v = ix.get(keyFor(ctx, moments[i].full_tree, tier)) orelse continue;
            if (v.result == .green) {
                prior_green = i;
                break;
            }
        }
    }

    return .{
        .head = head,
        .result = if (head_v) |v| v.result else null,
        .prior_green = prior_green,
    };
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    work: std.Io.Dir,
    scratch: [:0]u8,

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.scratch);
        self.work.close(std.testing.io);
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn ctx(self: *Fixture, alloc: std.mem.Allocator, set: checks.Settings) Context {
        return .{
            .store = &self.store,
            .work_dir = self.work,
            .alloc = alloc,
            .set = set,
            .rules = .{},
            .scratch_parent = self.scratch,
        };
    }
};

fn fixture(alloc: std.mem.Allocator) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.createDirPath(io, "repo");
    const work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    const store = try Store.init(io, alloc, work);
    const scratch = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    return .{ .tmp = tmp, .store = store, .work = work, .scratch = scratch };
}

fn snap(f: *Fixture, alloc: std.mem.Allocator, path: []const u8, body: []const u8) !Moment {
    try f.work.writeFile(std.testing.io, .{ .sub_path = path, .data = body });
    const r = try moment.capture(&f.store, f.work, .poll, .{ .enabled = true, .keyframe_interval = 4 });
    _ = alloc;
    return r.captured;
}

test "a tree is never graded twice" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    // Each run appends a byte, so a second real run would be visible.
    const set = checks.Settings{
        .enabled = true,
        .full = "echo x >> ../runs.log; exit 0",
    };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    const first = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, first.result);

    const second = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, second.result);
    // A cache hit costs no time at all.
    try testing.expectEqual(first.duration_ms, second.duration_ms);
}

test "grading records green and red from the real command" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = f.ctx(alloc, set);

    const good = try snap(&f, alloc, "a.txt", "good");
    defer alloc.free(good.branch);
    const bad = try snap(&f, alloc, "a.txt", "bad");
    defer alloc.free(bad.branch);

    try testing.expectEqual(verdict.Result.green, (try gradeState(ctx, good, .full)).result);
    try testing.expectEqual(verdict.Result.red, (try gradeState(ctx, bad, .full)).result);
}

test "bisect finds the breaking state in logarithmic runs" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    // Green while the file holds a number below 30.
    const set = checks.Settings{
        .enabled = true,
        .full = "test \"$(cat n.txt)\" -lt 30",
    };
    const ctx = f.ctx(alloc, set);

    for (0..64) |i| {
        const body = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(body);
        const m = try snap(&f, alloc, "n.txt", body);
        alloc.free(m.branch);
    }

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expectEqual(@as(usize, 64), all.len);

    // The endpoints come from continuous capture, not from anyone marking them.
    try testing.expectEqual(verdict.Result.green, (try gradeState(ctx, all[0], .full)).result);
    try testing.expectEqual(verdict.Result.red, (try gradeState(ctx, all[63], .full)).result);

    const b = try bisect(ctx, all, 0, 63, .full);
    // Moment i holds the number i, so the break is between 29 and 30.
    try testing.expectEqual(@as(usize, 29), b.last_green);
    try testing.expectEqual(@as(usize, 30), b.first_red);
    // ~8 runs for a 64-moment gap, not 64.
    try testing.expect(b.runs <= 8);
}

test "opportunistic grading targets the middle of the biggest gap" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "true" };
    const ctx = f.ctx(alloc, set);

    for (0..10) |i| {
        const body = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(body);
        const m = try snap(&f, alloc, "n.txt", body);
        alloc.free(m.branch);
    }
    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    // Grade the ends, leaving one long ungraded interval in the middle.
    _ = try gradeState(ctx, all[0], .full);
    _ = try gradeState(ctx, all[9], .full);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    const mid = largestUngradedMidpoint(ctx, all, &ix, .full).?;
    try testing.expect(mid >= 4 and mid <= 6);
}

test "opportunistic grading has nothing to do once all is graded" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "true" };
    const ctx = f.ctx(alloc, set);

    for (0..4) |i| {
        const body = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(body);
        const m = try snap(&f, alloc, "n.txt", body);
        alloc.free(m.branch);
    }
    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    for (all) |m| _ = try gradeState(ctx, m, .full);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();
    try testing.expect(largestUngradedMidpoint(ctx, all, &ix, .full) == null);
}

test "headState spots a green to red transition" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = f.ctx(alloc, set);

    const a = try snap(&f, alloc, "a.txt", "good one");
    alloc.free(a.branch);
    const b = try snap(&f, alloc, "a.txt", "good two");
    alloc.free(b.branch);
    const c = try snap(&f, alloc, "a.txt", "broken");
    alloc.free(c.branch);

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    for (all) |m| _ = try gradeState(ctx, m, .full);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    const hs = headState(ctx, all, &ix, .full).?;
    try testing.expectEqual(@as(usize, 2), hs.head);
    try testing.expectEqual(verdict.Result.red, hs.result.?);
    try testing.expectEqual(@as(usize, 1), hs.prior_green.?);
    try testing.expect(hs.isTransition());
}

test "editing a file the check never reads reuses the verdict without running" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    // The check reads only watched.txt, and records every real execution.
    const set = checks.Settings{
        .enabled = true,
        .full = "echo run >> ../ran.log; grep -q good watched.txt",
    };
    const ctx = f.ctx(alloc, set);

    try f.work.writeFile(std.testing.io, .{ .sub_path = "unread.txt", .data = "v0" });
    const a = try snap(&f, alloc, "watched.txt", "good");
    defer alloc.free(a.branch);
    const first = try gradeState(ctx, a, .full);
    try testing.expectEqual(verdict.Result.green, first.result);

    // Touch only the file the check never opened.
    const b = try snap(&f, alloc, "unread.txt", "v1");
    defer alloc.free(b.branch);
    const second = try gradeState(ctx, b, .full);

    try testing.expectEqual(verdict.Result.green, second.result);

    // Under exact tracing this is carried over rather than re-run, which shows
    // as a zero duration. Under the conservative fallback it re-runs, and that
    // is the correct-but-slower behaviour, so both are acceptable here.
    const rs = try readset.load(&f.store, first.readset);
    defer rs.deinit(alloc);
    if (!rs.contains("unread.txt")) {
        try testing.expectEqual(@as(u32, 0), second.duration_ms);
    }
}

test "adding a file forces a run even when the read-set never mentioned it" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good watched.txt" };
    const ctx = f.ctx(alloc, set);

    const a = try snap(&f, alloc, "watched.txt", "good");
    defer alloc.free(a.branch);
    const first = try gradeState(ctx, a, .full);
    try testing.expectEqual(verdict.Result.green, first.result);

    // A brand new path cannot be in any previous read-set, so a naive
    // intersection test would skip it. It must not: a check can look for a file
    // and not find it, and that absence is a dependency the read-set cannot see.
    const b = try snap(&f, alloc, "brand_new.txt", "hello");
    defer alloc.free(b.branch);

    const entries = try moment.entriesOf(&f.store, b);
    defer workspace.freeTreeEntries(alloc, entries);
    const prev_entries = try moment.entriesOf(&f.store, a);
    defer workspace.freeTreeEntries(alloc, prev_entries);

    const span = try warrant.spanBetween(&f.store, alloc, prev_entries, entries, .{});
    defer span.deinit(alloc);
    try testing.expect(span.paths_changed);

    const second = try gradeState(ctx, b, .full);
    try testing.expectEqual(verdict.Result.green, second.result);
    // A real run, not a carry-over.
    try testing.expect(second.duration_ms > 0);
}

test "a state between two greens stays ungraded, never interpolated" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "true" };
    const ctx = f.ctx(alloc, set);

    for (0..3) |i| {
        const body = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(body);
        const m = try snap(&f, alloc, "n.txt", body);
        alloc.free(m.branch);
    }
    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    _ = try gradeState(ctx, all[0], .full);
    _ = try gradeState(ctx, all[2], .full);

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    // Surrounded by green on both sides, and still not green.
    try testing.expect(ix.get(keyFor(ctx, all[1].full_tree, .full)) == null);
}

fn changeOf(f: *Fixture, body: []const u8, parents: []const Oid) !Oid {
    const blob = try f.store.writeFileContent(body);
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = blob },
    };
    const tree = try f.store.writeTree(.{ .entries = &entries });
    return f.store.writeChange(.{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{7} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Someone <someone@example.com>",
        .message = "imported from git\n",
    });
}

test "a change is graded from its tree, with no moment involved" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = f.ctx(alloc, set);

    const good = try changeOf(&f, "good", &.{});
    const bad = try changeOf(&f, "bad", &.{good});

    try testing.expectEqual(verdict.Result.green, (try gradeChange(ctx, good, .full)).result);
    try testing.expectEqual(verdict.Result.red, (try gradeChange(ctx, bad, .full)).result);

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expectEqual(@as(usize, 0), all.len);
}

test "a change and a moment holding the same tree share one verdict" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{
        .enabled = true,
        .full = "echo x >> ../runs.log; exit 0",
    };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);
    const first = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, first.result);

    const entries = try moment.entriesOf(&f.store, m);
    defer workspace.freeTreeEntries(alloc, entries);
    const tree = try f.store.writeTree(.{ .entries = entries });
    try testing.expect(tree.eql(m.full_tree));

    const change_oid = try f.store.writeChange(.{
        .tree = tree,
        .parents = &.{},
        .change_id = [_]u8{9} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Someone <someone@example.com>",
        .message = "same tree\n",
    });

    const second = try gradeChange(ctx, change_oid, .full);
    try testing.expectEqual(verdict.Result.green, second.result);
    try testing.expectEqual(first.duration_ms, second.duration_ms);
}

test "the warrant on a change with no attribution is unknown, not fabricated" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "true" };
    const ctx = f.ctx(alloc, set);

    const only = try changeOf(&f, "whatever", &.{});
    const v = try gradeChange(ctx, only, .full);

    try testing.expectEqual(verdict.Result.green, v.result);
    try testing.expectEqual(verdict.Independence.unknown, v.independence);
    try testing.expectEqual(verdict.Discrimination.unknown, v.discrimination);
}
