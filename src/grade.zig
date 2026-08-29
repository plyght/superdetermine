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
const config = @import("config.zig");
const mesh = @import("mesh.zig");
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

/// The historical key: what the log knows about this tree at this tier under
/// this command, whatever environment produced it. `Index` ignores the input
/// dimension by construction, so this is the key the policy and the UI ask with.
fn keyFor(ctx: Context, tree: Oid, tier: verdict.Tier) verdict.Key {
    return .{
        .tree = tree,
        .tier = tier,
        .command = verdict.commandHash(ctx.set.command(tier)),
    };
}

/// The memoization key: the historical key plus the declared inputs the run
/// would see. Only this one may authorise skipping a run.
fn cacheKey(ctx: Context, tree: Oid, tier: verdict.Tier, inputs: Oid) verdict.Key {
    var key = keyFor(ctx, tree, tier);
    key.inputs = inputs;
    return key;
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

/// What the declared inputs hold right now. Empty when none are declared, which
/// digests to zero and leaves the key exactly as it has always been.
pub fn currentInputs(ctx: Context) !checks.InputSet {
    if (ctx.set.inputs.len == 0) return .{ .entries = &.{} };
    const abs = try ctx.work_dir.realPathFileAlloc(ctx.store.io, ".", ctx.alloc);
    defer ctx.alloc.free(abs);
    return checks.collectInputs(ctx.store.io, ctx.alloc, abs, ctx.set.inputs);
}

/// Which declared input made the memoized verdict stop applying, as a path the
/// caller can print. Null when the environment is not what changed.
///
/// This is the whole reason the digest is itemized: "your key changed" is not
/// something anyone can act on, and "bun.lock changed" is.
pub fn missReason(
    ctx: Context,
    tree: Oid,
    tier: verdict.Tier,
    current: checks.InputSet,
) !?[]u8 {
    const alloc = ctx.alloc;
    var ix = try verdict.Index.load(ctx.store, alloc);
    defer ix.deinit();

    const prior = ix.get(keyFor(ctx, tree, tier)) orelse return null;
    const before = checks.loadInputs(ctx.store, prior.inputs) catch return null;
    defer before.deinit(alloc);

    const path = current.firstDifference(before) orelse return null;
    return try alloc.dupe(u8, path);
}

// --- letting one peer do the work ---

/// Whether a peer that loses the claim is willing to wait at all.
///
/// On by default. The cost of being wrong in the on direction is bounded — a
/// deferring peer waits, then grades anyway — while the cost of being wrong in
/// the off direction is paid continuously by every machine in the room, which is
/// the case the mesh exists for. A user who would rather burn the CPU than ever
/// wait sets `mesh.grade-claim off` and gets exactly the old path back.
pub fn claimEnabled(store: *Store, alloc: std.mem.Allocator) bool {
    if (config.get(store, alloc, "mesh.grade-claim")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            return mesh.boolOf(v);
        }
    } else |_| {}
    return true;
}

/// Polling interval while waiting for a peer's verdict to land. Short enough
/// that the wait is not what anyone notices for a fast check, and a verdict log
/// read is a few kilobytes.
const claim_poll_ms: i64 = 100;

/// Slack over the check's own run time, covering the peer's clone, the gossip
/// hop, and the poll interval on this side.
const claim_slack_ms: i64 = 2_000;

/// How long to wait for the claim holder before grading anyway.
///
/// This is deliberately derived from the check rather than picked: a suite that
/// takes ten minutes and a typecheck that takes two hundred milliseconds are not
/// the same wait, and one constant cannot be right for both. `observed_ms` is
/// what this check actually took last time the log saw it run, doubled because a
/// peer that is grading is a peer whose machine is busy, plus slack for the hop.
///
/// Two bounds. Underneath, `observed_ms` of zero — no run of this check has ever
/// been recorded here — returns no wait at all: nothing is known about how long
/// to expect, and the asymmetry is that a duplicated grade costs CPU while a
/// grade that never happens costs the product its whole reason to exist. Above,
/// the check's own timeout, because past that the holder has either produced a
/// verdict or been killed, and there is nothing further to wait for.
pub fn deferralMs(observed_ms: u32, timeout_ms: i64) i64 {
    if (observed_ms == 0) return 0;
    var wait: i64 = @as(i64, observed_ms) * 2 + claim_slack_ms;
    if (timeout_ms > 0 and wait > timeout_ms + claim_slack_ms) {
        wait = timeout_ms + claim_slack_ms;
    }
    return wait;
}

/// The longest this check has been seen to take, over the recent log.
///
/// The longest rather than the typical one, because being wrong here is
/// asymmetric in the same direction as everything else: a wait that is too long
/// costs nothing while the holder is healthy — the verdict arrives and ends the
/// wait early — and a wait that is too short costs a duplicated run of exactly
/// the suite this is trying not to run twice.
fn observedRunMs(store: *Store, alloc: std.mem.Allocator, tier: verdict.Tier, command: Oid) u32 {
    const all = verdict.readAll(store, alloc) catch return 0;
    defer alloc.free(all);

    var longest: u32 = 0;
    var seen: usize = 0;
    var i = all.len;
    while (i > 0 and seen < 32) {
        i -= 1;
        const v = all[i];
        if (v.tier != tier) continue;
        if (!v.command.eql(command)) continue;
        if (v.duration_ms == 0) continue;
        seen += 1;
        if (v.duration_ms > longest) longest = v.duration_ms;
    }
    return longest;
}

/// Wait for the peer that this job ranks highest, if that peer is not us.
///
/// Returns the verdict that arrived, or null meaning "grade it yourself". Null
/// is the answer for every degraded shape there is: no mesh, no peers, a roster
/// too old to believe, this peer holding the claim, an unknown run time, or the
/// wait having run out with nothing to show for it. That list is the design.
/// Peers can disagree about who is in the room — A sees three, B sees two — and
/// nothing here tries to repair that, because the worst a disagreement can do is
/// make two peers grade, which is precisely what happens today; the one state
/// that must never occur is nobody grading, and a bounded wait that always ends
/// in a real run is what rules it out.
fn awaitClaimant(ctx: Context, key: verdict.Key) !?verdict.Verdict {
    const alloc = ctx.alloc;
    const io = ctx.store.io;
    if (!claimEnabled(ctx.store, alloc)) return null;

    const roster = mesh.readRoster(ctx.store, alloc, nowMillis(io)) orelse return null;
    defer roster.deinit(alloc);
    // Alone in the room is the same thing as no room at all.
    if (roster.peers.len < 2) return null;

    const job = mesh.Job.fromKey(key);
    if (mesh.claims(job, roster.me, roster.peers)) return null;

    const wait = deferralMs(
        observedRunMs(ctx.store, alloc, key.tier, key.command),
        ctx.set.timeoutMs(key.tier),
    );
    if (wait <= 0) return null;

    const deadline = nowMillis(io) + wait;
    while (nowMillis(io) < deadline) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(claim_poll_ms), .awake) catch {};
        const now = nowMillis(io);
        if (try verdict.lookupFresh(ctx.store, alloc, key, now, ctx.set.fresh_ms)) |landed| {
            return landed;
        }
    }
    return null;
}

/// The verdict for a state, running the check only if it must.
///
/// Three layers of avoidance, in increasing cost order:
///   1. a memoized verdict for this exact `(tree, tier, command, inputs)` and
///      inside the freshness window, so a tree is never graded twice, ever;
///   2. an unchanged read-set relative to an already-graded neighbour, in which
///      case that verdict is carried over and recorded against this tree;
///   3. a peer in the mesh that this job ranks above us, in which case its
///      verdict is worth a bounded wait rather than a second identical run;
///   4. an actual run.
pub fn gradeState(
    ctx: Context,
    m: Moment,
    tier: verdict.Tier,
) !verdict.Verdict {
    const alloc = ctx.alloc;
    if (!ctx.set.has(tier)) return checks.Error.NoCheckConfigured;

    const inputs = try currentInputs(ctx);
    defer inputs.deinit(alloc);
    const inputs_oid = try checks.storeInputs(ctx.store, inputs);

    var now = nowMillis(ctx.store.io);
    const key = cacheKey(ctx, m.full_tree, tier, inputs_oid);
    if (try verdict.lookupFresh(ctx.store, alloc, key, now, ctx.set.fresh_ms)) |cached| return cached;

    // Layer 1b: the same question one step further out. Layer 1 asked whether
    // the answer already exists; this asks whether somebody is already getting
    // it. It sits after the cache lookup and not before, so a peer that holds
    // the verdict never waits for a single millisecond.
    if (try awaitClaimant(ctx, key)) |shared| return shared;
    // A wait that ended in nothing still consumed wall clock, and everything
    // below dates a run against `now`.
    now = nowMillis(ctx.store.io);

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
    // The neighbour's verdict may predate a change to the declared inputs or
    // have aged out, and carrying it forward would launder exactly the staleness
    // the key exists to catch, so the same two conditions gate it here.
    if (prev) |p| {
        if (!p.verdict.readset.isZero() and !span.paths_changed and
            p.verdict.inputs.eql(inputs_oid) and
            !verdict.isStale(p.verdict, now, ctx.set.fresh_ms))
        {
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
        .inputs = inputs_oid,
        .ran_ms = now,
        .outcome = outcome.outcome,
    };

    // A run that never reached a decision is not a verdict about anything, so
    // it is neither recorded nor worth spending a discrimination probe on. It
    // is still returned, because the caller has to be told what happened.
    if (!v.outcome.cacheable()) return v;

    // Discrimination costs one run and is only worth asking when the check
    // itself changed. Memoized through the same verdict cache as everything
    // else, because the hybrid tree is addressed by content like any other.
    if (v.result == .green and prev != null and warrant.shouldMeasureDiscrimination(span)) {
        v.discrimination = measureDiscrimination(ctx, prev.?.entries, entries, tier, inputs_oid) catch .unknown;
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

    const inputs = try currentInputs(ctx);
    defer inputs.deinit(alloc);
    const inputs_oid = try checks.storeInputs(ctx.store, inputs);

    const now = nowMillis(ctx.store.io);
    const key = cacheKey(ctx, change.tree, tier, inputs_oid);
    if (try verdict.lookupFresh(ctx.store, alloc, key, now, ctx.set.fresh_ms)) |cached| return cached;

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
        .inputs = inputs_oid,
        .ran_ms = now,
        .outcome = outcome.outcome,
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
    inputs_oid: Oid,
) !verdict.Discrimination {
    const alloc = ctx.alloc;

    const hybrid = try warrant.hybridEntries(alloc, previous, target, ctx.rules);
    defer workspace.freeTreeEntries(alloc, hybrid);

    const enc = try object.Tree.encode(.{ .entries = hybrid }, alloc);
    defer alloc.free(enc);
    const hybrid_tree = Oid.ofBytes(enc);

    // The hybrid is a tree like any other, so the verdict cache memoizes it for
    // free across every future state that produces the same combination.
    const key = cacheKey(ctx, hybrid_tree, tier, inputs_oid);
    const now = nowMillis(ctx.store.io);
    if (try verdict.lookupFresh(ctx.store, alloc, key, now, ctx.set.fresh_ms)) |cached| {
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

    // A probe that was killed or timed out answers nothing, so it neither
    // teaches the cache anything nor licenses a claim about the check.
    if (!graded.outcome.cacheable()) return .unknown;

    try verdict.record(ctx.store, .{
        .tree = hybrid_tree,
        .tier = tier,
        .command = key.command,
        .result = graded.outcome.result(),
        .exit_code = graded.outcome.exit_code,
        .duration_ms = graded.outcome.duration_ms,
        .ms = 0,
        .readset = Oid.zero(),
        .inputs = inputs_oid,
        .ran_ms = now,
        .outcome = graded.outcome.outcome,
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
        // A midpoint that timed out or was killed said nothing about itself, and
        // reading it as red would move the boundary to a state never measured.
        // Stop with the interval still honest instead.
        if (!v.outcome.cacheable()) break;
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

// --- what an agent gets back ---

/// What `sdt grade` decided, in the one form a caller can branch on.
///
/// An agent runs this command and needs an answer, not prose: the tree is good,
/// the tree is bad, nothing was measured, the run never finished, or there is
/// nothing configured to measure with. Those are five different situations and
/// exiting zero for all of them makes the command useless to anything that is
/// not a human reading a terminal.
pub const Status = enum {
    /// A check ran, or a memoized verdict says one did, and it passed.
    green,
    /// A check ran and failed. This is a fact about the code.
    red,
    /// The check did not reach a decision: it timed out, was killed, or could
    /// not be launched. This is a fact about the machine, and nothing was cached.
    incomplete,
    /// There is no verdict: nothing had been graded and nothing needed grading.
    ungraded,
    /// No check is configured for this tier, so there is nothing to grade with.
    no_check,

    pub fn label(self: Status) []const u8 {
        return @tagName(self);
    }
};

/// The exit codes. They are part of the interface, so they are named here and
/// not spelled out at the call site.
pub const exit_green: u8 = 0;
pub const exit_red: u8 = 10;
pub const exit_ungraded: u8 = 11;
pub const exit_incomplete: u8 = 12;
pub const exit_no_check: u8 = 14;

pub const Report = struct {
    status: Status,
    tier: verdict.Tier = .full,
    /// The verdict the status is about, when one exists.
    v: ?verdict.Verdict = null,
    /// How many checks actually executed.
    ran: usize = 0,
    captured: bool = false,
    cut: bool = false,
    boundary: ?Break = null,
    /// The declared input that invalidated the memoized verdict, owned.
    miss: ?[]const u8 = null,
    /// Why the tick declined to do anything. Borrowed, never owned.
    skipped: ?[]const u8 = null,

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        if (self.miss) |m| alloc.free(m);
    }

    pub fn exitCode(self: Report) u8 {
        return switch (self.status) {
            .green => exit_green,
            .red => exit_red,
            .incomplete => exit_incomplete,
            .ungraded => exit_ungraded,
            .no_check => exit_no_check,
        };
    }

    /// Exactly one JSON object and nothing else, warrant axes included: the
    /// axes are the reason a green here means more than a green anywhere else,
    /// and an agent that cannot see them cannot use them.
    pub fn writeJson(self: Report, w: *std.Io.Writer) !void {
        try w.print("{{\"status\":\"{s}\",\"exit_code\":{d},\"tier\":\"{s}\"", .{
            self.status.label(), self.exitCode(), self.tier.label(),
        });
        try w.print(",\"ran\":{d},\"captured\":{s},\"cut\":{s}", .{
            self.ran,
            if (self.captured) "true" else "false",
            if (self.cut) "true" else "false",
        });

        if (self.v) |v| {
            var tree_hex: [Oid.len * 2]u8 = undefined;
            _ = v.tree.toHex(&tree_hex);
            try w.writeAll(",\"tree\":");
            try writeJsonString(w, &tree_hex);
            try w.print(",\"result\":\"{s}\",\"outcome\":\"{s}\"", .{
                v.result.label(), v.outcome.label(),
            });
            try w.print(",\"check_exit_code\":{d},\"duration_ms\":{d}", .{
                v.exit_code, v.duration_ms,
            });
            try w.print(
                ",\"warrant\":{{\"independence\":\"{s}\",\"relevance_hit\":{d}," ++
                    "\"relevance_total\":{d},\"discrimination\":\"{s}\",\"hollow\":{s}}}",
                .{
                    v.independence.label(),
                    v.relevance_hit,
                    v.relevance_total,
                    v.discrimination.label(),
                    if (v.isHollow()) "true" else "false",
                },
            );
        } else {
            try w.writeAll(",\"tree\":null,\"result\":null,\"outcome\":null");
            try w.writeAll(",\"check_exit_code\":null,\"duration_ms\":null,\"warrant\":null");
        }

        try w.writeAll(",\"cache_miss\":");
        if (self.miss) |m| try writeJsonString(w, m) else try w.writeAll("null");

        try w.writeAll(",\"skipped\":");
        if (self.skipped) |s| try writeJsonString(w, s) else try w.writeAll("null");

        try w.writeAll(",\"boundary\":");
        if (self.boundary) |b| {
            try w.print("{{\"last_green\":{d},\"first_red\":{d},\"runs\":{d}}}", .{
                b.last_green, b.first_red, b.runs,
            });
        } else try w.writeAll("null");

        try w.writeAll("}\n");
    }
};

/// The status a verdict implies, which is where the outcome taxonomy reaches
/// the caller: a red that was never the check's own answer is not a red.
pub fn statusOf(v: verdict.Verdict) Status {
    if (!v.outcome.cacheable()) return .incomplete;
    return if (v.result == .green) .green else .red;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => {
            if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c);
        },
    };
    try w.writeByte('"');
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

test "a repo that declares no inputs grades exactly as it always did" {
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
    try testing.expect(first.inputs.isZero());
    try testing.expect(first.ran_ms != 0);
    try testing.expectEqual(verdict.Outcome.pass, first.outcome);

    // The key is the one it always was, so the memoized verdict still answers.
    const second = try gradeState(ctx, m, .full);
    try testing.expectEqual(first.duration_ms, second.duration_ms);
    try testing.expect(verdict.lookup(&f.store, alloc, keyFor(ctx, m.full_tree, .full)) catch null != null);
}

test "a declared input changing forces a re-run, and the miss names the file" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    // The lockfile is not tracked, so nothing about the tree moves when it does.
    try f.work.writeFile(io, .{ .sub_path = "bun.lock", .data = "v1" });
    const inputs = [_][]const u8{"bun.lock"};
    const set = checks.Settings{
        .enabled = true,
        .full = "true",
        .inputs = &inputs,
    };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    const first = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, first.result);
    try testing.expect(!first.inputs.isZero());

    // Same tree, same command, same everything the old key could see.
    const again = try gradeState(ctx, m, .full);
    try testing.expectEqual(first.duration_ms, again.duration_ms);

    try f.work.writeFile(io, .{ .sub_path = "bun.lock", .data = "v2" });

    const current = try currentInputs(ctx);
    defer current.deinit(alloc);
    const why = (try missReason(ctx, m.full_tree, .full, current)).?;
    defer alloc.free(why);
    try testing.expectEqualStrings("bun.lock", why);

    const third = try gradeState(ctx, m, .full);
    // A real run against the same tree, under a key that now differs.
    try testing.expect(!third.inputs.eql(first.inputs));
    try testing.expect(third.duration_ms > 0);

    // Nothing moved this time, so there is nothing to name.
    const settled = try currentInputs(ctx);
    defer settled.deinit(alloc);
    try testing.expect((try missReason(ctx, m.full_tree, .full, settled)) == null);
}

test "an input outside the repo re-grades the same tree" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    // A toolchain file above the worktree, addressed absolutely.
    const outside = try std.fmt.allocPrint(alloc, "{s}/toolchain.txt", .{f.scratch});
    defer alloc.free(outside);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside, .data = "0.16.0" });

    const inputs = [_][]const u8{outside};
    const set = checks.Settings{ .enabled = true, .full = "true", .inputs = &inputs };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    const first = try gradeState(ctx, m, .full);
    try testing.expect(!first.inputs.isZero());

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = outside, .data = "0.17.0" });
    const second = try gradeState(ctx, m, .full);
    try testing.expect(!second.inputs.eql(first.inputs));
    try testing.expect(second.duration_ms > 0);
}

test "a green past the freshness window is measured again" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    {
        const set = checks.Settings{ .enabled = true, .full = "true" };
        const ctx = f.ctx(alloc, set);
        const first = try gradeState(ctx, m, .full);
        try testing.expectEqual(verdict.Result.green, first.result);
        // Inside a generous window the memoized answer still stands.
        const inside = try gradeState(ctx, m, .full);
        try testing.expectEqual(first.duration_ms, inside.duration_ms);
    }

    // A window of one millisecond has already elapsed by the time this runs.
    const set = checks.Settings{ .enabled = true, .full = "true", .fresh_ms = 1 };
    const ctx = f.ctx(alloc, set);
    std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    const stale = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, stale.result);
    try testing.expect(stale.duration_ms > 0);
}

test "a check killed mid-run is reported, not remembered" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "kill -9 $$" };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    const v = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Outcome.cancelled, v.outcome);
    try testing.expectEqual(Status.incomplete, statusOf(v));

    // Nothing was written, so the next call measures rather than serving a red
    // that only ever meant "the machine interfered".
    try testing.expect((try verdict.lookup(&f.store, alloc, keyFor(ctx, m.full_tree, .full))) == null);
    const again = try gradeState(ctx, m, .full);
    try testing.expect(again.duration_ms > 0);
    try testing.expectEqual(verdict.Outcome.cancelled, again.outcome);
}

test "a check that hangs past its deadline is not remembered either" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{
        .enabled = true,
        .full = "sleep 30",
        .timeout_full_ms = 200,
        .kill_grace_ms = 50,
    };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);

    const v = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Outcome.timeout, v.outcome);
    try testing.expectEqual(Status.incomplete, statusOf(v));
    try testing.expect((try verdict.lookup(&f.store, alloc, keyFor(ctx, m.full_tree, .full))) == null);
}

test "the report gives an agent an exit code and one JSON object" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = f.ctx(alloc, set);

    const good = try snap(&f, alloc, "a.txt", "good");
    defer alloc.free(good.branch);
    const v = try gradeState(ctx, good, .full);

    const green = Report{ .status = statusOf(v), .tier = .full, .v = v, .ran = 1, .captured = true };
    try testing.expectEqual(exit_green, green.exitCode());

    var buf: [4096]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);
    try green.writeJson(&out);
    const json = out.buffered();

    // Exactly one object, and a trailing newline.
    try testing.expect(json[0] == '{');
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, json, "\n"));
    try testing.expect(std.mem.endsWith(u8, json, "}\n"));

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("green", root.get("status").?.string);
    try testing.expectEqual(@as(i64, 0), root.get("exit_code").?.integer);
    try testing.expectEqualStrings("full", root.get("tier").?.string);
    try testing.expectEqualStrings("pass", root.get("outcome").?.string);
    try testing.expectEqual(@as(i64, 1), root.get("ran").?.integer);

    // The warrant axes are the differentiator, so an agent can see all of them.
    const warrant_axes = root.get("warrant").?.object;
    try testing.expect(warrant_axes.get("independence") != null);
    try testing.expect(warrant_axes.get("relevance_hit") != null);
    try testing.expect(warrant_axes.get("relevance_total") != null);
    try testing.expect(warrant_axes.get("discrimination") != null);
    try testing.expect(warrant_axes.get("hollow") != null);

    const bad = try snap(&f, alloc, "a.txt", "broken");
    defer alloc.free(bad.branch);
    const rv = try gradeState(ctx, bad, .full);
    const red = Report{ .status = statusOf(rv), .tier = .full, .v = rv, .ran = 1 };
    try testing.expectEqual(exit_red, red.exitCode());

    try testing.expectEqual(exit_ungraded, (Report{ .status = .ungraded, .tier = .full }).exitCode());
    try testing.expectEqual(exit_no_check, (Report{ .status = .no_check, .tier = .full }).exitCode());
    try testing.expectEqual(exit_incomplete, (Report{ .status = .incomplete, .tier = .full }).exitCode());
}

test "a report with nothing graded is still one valid JSON object" {
    const alloc = testing.allocator;
    var buf: [2048]u8 = undefined;
    var out = std.Io.Writer.fixed(&buf);

    const miss = try alloc.dupe(u8, "bun.lock");
    const r = Report{
        .status = .ungraded,
        .tier = .fast,
        .miss = miss,
        .skipped = "on battery below the floor, so nothing was graded",
    };
    defer r.deinit(alloc);
    try r.writeJson(&out);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.buffered(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("ungraded", root.get("status").?.string);
    try testing.expectEqual(@as(i64, 11), root.get("exit_code").?.integer);
    try testing.expectEqual(std.json.Value.null, root.get("result").?);
    try testing.expectEqual(std.json.Value.null, root.get("warrant").?);
    try testing.expectEqualStrings("bun.lock", root.get("cache_miss").?.string);
    try testing.expect(root.get("skipped").?.string.len != 0);
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

test "the wait scales with how long the check takes" {
    // Nothing known about the check means no wait: a duplicated run is cheaper
    // than a grade that might never happen.
    try testing.expectEqual(@as(i64, 0), deferralMs(0, 15 * std.time.ms_per_min));

    // A fast check is waited on briefly, a slow one for longer.
    const quick = deferralMs(200, 15 * std.time.ms_per_min);
    const slow = deferralMs(60_000, 15 * std.time.ms_per_min);
    try testing.expect(quick < slow);
    try testing.expect(quick >= 2_000);

    // Never past the point where the holder must have finished or been killed.
    try testing.expect(deferralMs(60_000, 1_000) <= 1_000 + 2_000);
}

/// A peer id this repo's peer would rank below, for the job `key` names.
fn losingSelf(key: verdict.Key, them: mesh.PeerId) mesh.PeerId {
    const job = mesh.Job.fromKey(key);
    var me: mesh.PeerId = [_]u8{0} ** mesh.peer_id_len;
    var i: u8 = 1;
    while (i < 255) : (i += 1) {
        me = [_]u8{i} ** mesh.peer_id_len;
        if (!mesh.claims(job, me, &.{ me, them })) return me;
    }
    return me;
}

test "a peer that loses the claim grades anyway when the verdict never arrives" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{
        .enabled = true,
        .full = "exit 0",
        // Caps the wait, so the test spends seconds rather than minutes proving
        // that the deferral ends in a real run.
        .timeout_full_ms = 500,
    };
    const ctx = f.ctx(alloc, set);

    // A first run so the log knows what this check costs; without that there is
    // nothing to derive a wait from and the peer never defers at all.
    const first = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(first.branch);
    _ = try gradeState(ctx, first, .full);

    const m = try snap(&f, alloc, "a.txt", "two");
    defer alloc.free(m.branch);

    const key = keyFor(ctx, m.full_tree, .full);
    const them: mesh.PeerId = [_]u8{0xab} ** mesh.peer_id_len;
    const me = losingSelf(key, them);
    const started = nowMillis(f.store.io);
    try mesh.writeRoster(&f.store, alloc, me, &.{them}, started);

    // The claim holder produces nothing, so the wait runs out and this peer
    // does the work rather than leaving the tree ungraded forever.
    const v = try gradeState(ctx, m, .full);
    try testing.expectEqual(verdict.Result.green, v.result);
    try testing.expect(nowMillis(f.store.io) - started >= 1_000);
}

test "a peer that already holds the verdict never waits" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "exit 0" };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);
    _ = try gradeState(ctx, m, .full);

    // Losing the claim is irrelevant once the answer is in hand.
    const key = keyFor(ctx, m.full_tree, .full);
    const them: mesh.PeerId = [_]u8{0xab} ** mesh.peer_id_len;
    const me = losingSelf(key, them);
    const started = nowMillis(f.store.io);
    try mesh.writeRoster(&f.store, alloc, me, &.{them}, started);

    _ = try gradeState(ctx, m, .full);
    try testing.expect(nowMillis(f.store.io) - started < 1_000);
}

test "with no mesh there is nothing to defer to" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const set = checks.Settings{ .enabled = true, .full = "exit 0" };
    const ctx = f.ctx(alloc, set);

    const m = try snap(&f, alloc, "a.txt", "one");
    defer alloc.free(m.branch);
    _ = try gradeState(ctx, m, .full);

    const key = keyFor(ctx, m.full_tree, .full);
    // No roster at all: the old path, exactly.
    try testing.expect((try awaitClaimant(ctx, key)) == null);

    // A room of one is the same thing.
    const me: mesh.PeerId = [_]u8{3} ** mesh.peer_id_len;
    try mesh.writeRoster(&f.store, alloc, me, &.{}, nowMillis(f.store.io));
    try testing.expect((try awaitClaimant(ctx, key)) == null);

    // And so is the toggle being off, even with a peer that outranks us.
    const them: mesh.PeerId = [_]u8{0xab} ** mesh.peer_id_len;
    const loser = losingSelf(key, them);
    try mesh.writeRoster(&f.store, alloc, loser, &.{them}, nowMillis(f.store.io));
    try config.set(&f.store, "mesh.grade-claim", "off");
    try testing.expect((try awaitClaimant(ctx, key)) == null);
}
