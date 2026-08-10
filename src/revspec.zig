const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;
const Moment = moment.Moment;

/// Addressing states by describing them.
///
/// You never place a reference point in advance, so every selector here is a
/// description evaluated against captured history rather than a name someone
/// remembered to write down. The `@` sigil marks the whole grammar, which is
/// what keeps a revspec structurally distinguishable from a branch name or a
/// path with no guessing.
///
///   @              the current state
///   @green @red    the newest green / red moment
///   @save          the last explicit checkpoint
///   @2h @30m       by time
///   @yesterday     24 hours back
///   @a3f91c        by moment id prefix
///   ~n             walk back n, composing with any selector above
///
/// Every selector resolves the same way: build the list of moments the selector
/// admits, oldest first, then index `~n` back from its end. That uniformity is
/// why `@green~2` and `@2h~2` need no special cases.
pub const Error = error{
    NotARevspec,
    UnknownSelector,
    NoSuchMoment,
    AmbiguousMoment,
};

pub const Target = union(enum) {
    /// `@` with no selector: the live worktree, which may be ahead of the last
    /// captured moment.
    live,
    /// A captured state. `.branch` is heap-allocated; free it.
    at: Moment,
};

pub const Resolved = struct {
    target: Target,
    /// Set when the selector was `green` or `red`, so callers can report which
    /// tier answered. "Last state that typechecked" and "last state that passed
    /// the suite" are different claims and the UI must not conflate them.
    verdict: ?verdict.Verdict = null,

    pub fn deinit(self: Resolved, alloc: std.mem.Allocator) void {
        switch (self.target) {
            .live => {},
            .at => |m| alloc.free(m.branch),
        }
    }
};

/// What `green`/`red` need in order to answer. Callers that have no checks
/// configured pass `verdicts = null`, and those selectors then fail cleanly
/// rather than silently resolving to something arbitrary.
pub const Context = struct {
    store: *Store,
    alloc: std.mem.Allocator,
    verdicts: ?*const verdict.Index = null,
    command_fast: Oid = Oid.zero(),
    command_full: Oid = Oid.zero(),
    /// Unix milliseconds, injected so resolution is testable.
    now_ms: i64,
};

pub fn looksLikeRevspec(s: []const u8) bool {
    return s.len >= 1 and s[0] == '@';
}

const Parsed = struct {
    selector: []const u8,
    back: usize,
    sigil: bool,
};

fn parse(spec: []const u8) !Parsed {
    const sigil = looksLikeRevspec(spec);
    const body = if (sigil) spec[1..] else spec;
    if (body.len == 0 and !sigil) return Error.NotARevspec;

    if (std.mem.lastIndexOfScalar(u8, body, '~')) |i| {
        const digits = body[i + 1 ..];
        // A bare trailing `~` means one step back, matching the way every other
        // VCS reads it.
        const n = if (digits.len == 0)
            @as(usize, 1)
        else
            std.fmt.parseInt(usize, digits, 10) catch return if (sigil) Error.UnknownSelector else Error.NotARevspec;
        return .{ .selector = body[0..i], .back = n, .sigil = sigil };
    }
    return .{ .selector = body, .back = 0, .sigil = sigil };
}

fn isHexPrefix(s: []const u8) bool {
    if (s.len < 4 or s.len > Oid.len * 2) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

/// A duration selector like `2h`, `30m`, `45s`, `3d`. Returns milliseconds, or
/// null when the string is not one.
fn parseAgoMs(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const unit = s[s.len - 1];
    const mult: i64 = switch (unit) {
        's' => 1000,
        'm' => 60 * 1000,
        'h' => 60 * 60 * 1000,
        'd' => 24 * 60 * 60 * 1000,
        else => return null,
    };
    const n = std.fmt.parseInt(i64, s[0 .. s.len - 1], 10) catch return null;
    return n * mult;
}

fn matchesIdPrefix(m: Moment, prefix: []const u8) bool {
    var buf: [16]u8 = undefined;
    const hex = m.shortId(&buf);
    if (prefix.len > hex.len) return false;
    for (hex[0..prefix.len], prefix) |a, b| {
        const lb = if (b >= 'A' and b <= 'F') b + 32 else b;
        if (a != lb) return false;
    }
    return true;
}

fn verdictFor(ctx: Context, m: Moment) ?verdict.Verdict {
    const ix = ctx.verdicts orelse return null;
    return ix.best(m.full_tree, ctx.command_fast, ctx.command_full);
}

fn hexHasPrefix(hex: []const u8, prefix: []const u8) bool {
    if (prefix.len > hex.len) return false;
    for (hex[0..prefix.len], prefix) |a, b| {
        const lb = if (b >= 'A' and b <= 'F') b + 32 else b;
        if (a != lb) return false;
    }
    return true;
}

fn matchChanges(ctx: Context, prefix: []const u8, out: *std.ArrayList(Oid)) !void {
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(ctx.alloc);

    var heads = ctx.store.root.openDir(ctx.store.io, "refs/heads", .{ .iterate = true }) catch return;
    defer heads.close(ctx.store.io);
    var it = heads.iterate();
    while (try it.next(ctx.store.io)) |entry| {
        if (entry.kind != .file) continue;
        const tip = ctx.store.readRef(entry.name) catch continue;
        try stack.append(ctx.alloc, tip);
    }

    var seen = std.AutoHashMap([Oid.len]u8, void).init(ctx.alloc);
    defer seen.deinit();

    while (stack.pop()) |cur| {
        if (cur.isZero()) continue;
        if ((try seen.getOrPut(cur.bytes)).found_existing) continue;
        var hex: [Oid.len * 2]u8 = undefined;
        _ = cur.toHex(&hex);
        if (hexHasPrefix(&hex, prefix)) try out.append(ctx.alloc, cur);
        const change = ctx.store.readChange(cur) catch continue;
        defer object.freeChange(ctx.store.alloc, change);
        for (change.parents) |p| try stack.append(ctx.alloc, p);
    }
}

fn resolveChange(ctx: Context, tip: Oid, back: usize) !Resolved {
    var cur = tip;
    var left = back;
    while (left > 0) : (left -= 1) {
        const change = ctx.store.readChange(cur) catch return Error.NoSuchMoment;
        defer object.freeChange(ctx.store.alloc, change);
        if (change.parents.len == 0) return Error.NoSuchMoment;
        cur = change.parents[0];
    }
    const change = ctx.store.readChange(cur) catch return Error.NoSuchMoment;
    defer object.freeChange(ctx.store.alloc, change);

    const branch = ctx.store.headBranch() catch try ctx.store.alloc.dupe(u8, "");
    defer ctx.store.alloc.free(branch);

    var m = Moment{
        .id = undefined,
        .ms = change.timestamp * 1000,
        .full_tree = change.tree,
        .repr = change.tree,
        .kind = .keyframe,
        .cause = .save,
        .branch = try ctx.alloc.dupe(u8, branch),
    };
    @memcpy(&m.id, cur.bytes[0..m.id.len]);
    return .{ .target = .{ .at = m }, .verdict = verdictFor(ctx, m) };
}

fn pick(ctx: Context, all: []const Moment, candidates: []const usize, back: usize) !Resolved {
    if (candidates.len <= back) return Error.NoSuchMoment;
    const chosen = all[candidates[candidates.len - 1 - back]];

    return .{
        .target = .{ .at = .{
            .id = chosen.id,
            .ms = chosen.ms,
            .full_tree = chosen.full_tree,
            .repr = chosen.repr,
            .kind = chosen.kind,
            .cause = chosen.cause,
            .branch = try ctx.alloc.dupe(u8, chosen.branch),
        } },
        .verdict = verdictFor(ctx, chosen),
    };
}

fn resolveHex(ctx: Context, p: Parsed) !Resolved {
    const all = try moment.readAll(ctx.store, ctx.alloc);
    defer moment.freeMoments(ctx.alloc, all);

    // Truncate at the matched moment so `~n` keeps walking back through
    // real history rather than through other id matches.
    var hit: ?usize = null;
    for (all, 0..) |m, i| {
        if (!matchesIdPrefix(m, p.selector)) continue;
        if (hit != null) return Error.AmbiguousMoment;
        hit = i;
    }

    var found: std.ArrayList(Oid) = .empty;
    defer found.deinit(ctx.alloc);
    try matchChanges(ctx, p.selector, &found);
    if (found.items.len > 1) return Error.AmbiguousMoment;
    if (found.items.len == 1) {
        if (hit != null) return Error.AmbiguousMoment;
        return resolveChange(ctx, found.items[0], p.back);
    }

    const at = hit orelse return Error.NoSuchMoment;
    var candidates: std.ArrayList(usize) = .empty;
    defer candidates.deinit(ctx.alloc);
    for (0..at + 1) |i| try candidates.append(ctx.alloc, i);
    return pick(ctx, all, candidates.items, p.back);
}

pub const Match = struct {
    kind: enum { moment, change },
    hex: [Oid.len * 2]u8,
    len: usize,

    pub fn id(self: *const Match) []const u8 {
        return self.hex[0..self.len];
    }
};

pub fn matches(ctx: Context, spec: []const u8, out: *std.ArrayList(Match)) !void {
    const p = parse(spec) catch return;
    if (!isHexPrefix(p.selector)) return;

    const all = try moment.readAll(ctx.store, ctx.alloc);
    defer moment.freeMoments(ctx.alloc, all);
    for (all) |m| {
        if (!matchesIdPrefix(m, p.selector)) continue;
        var entry = Match{ .kind = .moment, .hex = undefined, .len = 16 };
        _ = m.shortId(entry.hex[0..16]);
        try out.append(ctx.alloc, entry);
    }

    var found: std.ArrayList(Oid) = .empty;
    defer found.deinit(ctx.alloc);
    try matchChanges(ctx, p.selector, &found);
    for (found.items) |o| {
        var entry = Match{ .kind = .change, .hex = undefined, .len = Oid.len * 2 };
        _ = o.toHex(&entry.hex);
        try out.append(ctx.alloc, entry);
    }
}

/// Resolve a revspec against captured history. The caller owns the result and
/// must call `Resolved.deinit`.
pub fn resolve(ctx: Context, spec: []const u8) !Resolved {
    const p = try parse(spec);

    if (!p.sigil) {
        if (ctx.store.refExists(p.selector)) {
            const tip = ctx.store.readRef(p.selector) catch return Error.NoSuchMoment;
            return resolveChange(ctx, tip, p.back);
        }
        if (!isHexPrefix(p.selector)) return Error.NotARevspec;
        return resolveHex(ctx, p);
    }

    const all = try moment.readAll(ctx.store, ctx.alloc);
    defer moment.freeMoments(ctx.alloc, all);

    // `@` alone means the live tree; `@~n` means n moments back from it.
    if (p.selector.len == 0 and p.back == 0) return .{ .target = .live };

    var candidates: std.ArrayList(usize) = .empty;
    defer candidates.deinit(ctx.alloc);

    if (p.selector.len == 0) {
        for (all, 0..) |_, i| try candidates.append(ctx.alloc, i);
    } else if (std.mem.eql(u8, p.selector, "green") or std.mem.eql(u8, p.selector, "red")) {
        if (ctx.verdicts == null) return Error.NoSuchMoment;
        const want: verdict.Result = if (p.selector[0] == 'g') .green else .red;
        for (all, 0..) |m, i| {
            const v = verdictFor(ctx, m) orelse continue;
            if (v.result == want) try candidates.append(ctx.alloc, i);
        }
    } else if (std.mem.eql(u8, p.selector, "save")) {
        for (all, 0..) |m, i| {
            if (m.cause == .save) try candidates.append(ctx.alloc, i);
        }
    } else if (std.mem.eql(u8, p.selector, "yesterday")) {
        const cutoff = ctx.now_ms - 24 * 60 * 60 * 1000;
        for (all, 0..) |m, i| {
            if (m.ms <= cutoff) try candidates.append(ctx.alloc, i);
        }
    } else if (parseAgoMs(p.selector)) |ago| {
        const cutoff = ctx.now_ms - ago;
        for (all, 0..) |m, i| {
            if (m.ms <= cutoff) try candidates.append(ctx.alloc, i);
        }
    } else if (isHexPrefix(p.selector)) {
        return resolveHex(ctx, p);
    } else {
        return Error.UnknownSelector;
    }

    return pick(ctx, all, candidates.items, p.back);
}

// --- ranges ---

pub const Range = struct {
    /// Null means "from the beginning of captured history".
    from: ?Resolved,
    to: Resolved,

    pub fn deinit(self: Range, alloc: std.mem.Allocator) void {
        if (self.from) |f| f.deinit(alloc);
        self.to.deinit(alloc);
    }
};

/// Parse `A..B`, `A..` (to the live tree) or a bare `B` (from the beginning).
/// This is what makes `sdt recap @green..` read the way it looks.
pub fn resolveRange(ctx: Context, spec: []const u8) !Range {
    if (std.mem.indexOf(u8, spec, "..")) |i| {
        const lhs = spec[0..i];
        const rhs = spec[i + 2 ..];
        const from = if (lhs.len == 0) null else try resolve(ctx, lhs);
        errdefer if (from) |f| f.deinit(ctx.alloc);
        const to = if (rhs.len == 0) Resolved{ .target = .live } else try resolve(ctx, rhs);
        return .{ .from = from, .to = to };
    }
    return .{ .from = null, .to = try resolve(ctx, spec) };
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    work: std.Io.Dir,

    fn deinit(self: *Fixture) void {
        self.work.close(std.testing.io);
        self.store.deinit();
        self.tmp.cleanup();
    }
};

/// Moments are stamped with real wall-clock-scale times, not small integers:
/// retention measures age against now, so a 1970-era moment is correctly
/// treated as long expired and trimmed away.
const base_ms: i64 = 1_800_000_000_000;

fn fixture(alloc: std.mem.Allocator) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    const store = try Store.init(io, alloc, tmp.dir);
    try tmp.dir.createDirPath(io, "work");
    const work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    return .{ .tmp = tmp, .store = store, .work = work };
}

/// Capture a moment with a caller-chosen timestamp and cause, so the time
/// selectors can be tested without sleeping.
fn captureAt(f: *Fixture, alloc: std.mem.Allocator, body: []const u8, ms: i64, cause: moment.Cause) !Moment {
    const io = std.testing.io;
    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = body });
    const r = try moment.capture(&f.store, f.work, cause, .{ .enabled = true, .keyframe_interval = 3 });
    var m = r.captured;
    // Rewrite the log's last line with the chosen timestamp.
    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (all, 0..) |rec, i| {
        const t = if (i == all.len - 1) ms else rec.ms;
        var id_hex: [16]u8 = undefined;
        _ = rec.shortId(&id_hex);
        var full_hex: [Oid.len * 2]u8 = undefined;
        var repr_hex: [Oid.len * 2]u8 = undefined;
        _ = rec.full_tree.toHex(&full_hex);
        _ = rec.repr.toHex(&repr_hex);
        try out.print(alloc, "{s} {d} {s} {s} {s} {s}\t{s}\n", .{
            &id_hex, t, &full_hex, &repr_hex, rec.kind.label(), rec.cause.label(), rec.branch,
        });
    }
    try f.store.root.writeFile(std.testing.io, .{ .sub_path = moment.log_path, .data = out.items });
    m.ms = ms;
    return m;
}

test "bare @ is the live tree, @~n walks back" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    alloc.free(m2.branch);
    const m3 = try captureAt(&f, alloc, "three", base_ms + 3000, .poll);
    alloc.free(m3.branch);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 4000 };

    const live = try resolve(ctx, "@");
    defer live.deinit(alloc);
    try testing.expect(live.target == .live);

    const back1 = try resolve(ctx, "@~1");
    defer back1.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 2000), back1.target.at.ms);

    const back2 = try resolve(ctx, "@~2");
    defer back2.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), back2.target.at.ms);

    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "@~9"));
}

test "bare ~ means one step back" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    alloc.free(m2.branch);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 3000 };
    const r = try resolve(ctx, "@~");
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), r.target.at.ms);
}

test "@green and @green~1 pick graded states only" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const cmd = verdict.commandHash("check");

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    defer alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    defer alloc.free(m2.branch);
    const m3 = try captureAt(&f, alloc, "three", base_ms + 3000, .poll);
    defer alloc.free(m3.branch);
    const m4 = try captureAt(&f, alloc, "four", base_ms + 4000, .poll);
    defer alloc.free(m4.branch);

    // green, ungraded, green, red
    try verdict.record(&f.store, .{
        .tree = m1.full_tree,
        .tier = .full,
        .command = cmd,
        .result = .green,
        .exit_code = 0,
        .duration_ms = 1,
        .ms = base_ms + 1000,
        .readset = Oid.zero(),
    });
    try verdict.record(&f.store, .{
        .tree = m3.full_tree,
        .tier = .full,
        .command = cmd,
        .result = .green,
        .exit_code = 0,
        .duration_ms = 1,
        .ms = base_ms + 3000,
        .readset = Oid.zero(),
    });
    try verdict.record(&f.store, .{
        .tree = m4.full_tree,
        .tier = .full,
        .command = cmd,
        .result = .red,
        .exit_code = 1,
        .duration_ms = 1,
        .ms = base_ms + 4000,
        .readset = Oid.zero(),
    });

    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();
    const ctx = Context{
        .store = &f.store,
        .alloc = alloc,
        .verdicts = &ix,
        .command_fast = cmd,
        .command_full = cmd,
        .now_ms = 5000,
    };

    const g = try resolve(ctx, "@green");
    defer g.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 3000), g.target.at.ms);
    // The tier that answered is reported, never inferred.
    try testing.expectEqual(verdict.Tier.full, g.verdict.?.tier);

    const g1 = try resolve(ctx, "@green~1");
    defer g1.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), g1.target.at.ms);

    const r = try resolve(ctx, "@red");
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 4000), r.target.at.ms);

    // m2 sits between two greens and is never interpolated to green.
    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "@green~2"));
}

test "@green without configured checks fails cleanly" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    alloc.free(m1.branch);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 2000 };
    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "@green"));
}

test "time selectors and @save" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const hour = 60 * 60 * 1000;
    const m1 = try captureAt(&f, alloc, "one", base_ms + 10 * hour, .save);
    alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 11 * hour, .poll);
    alloc.free(m2.branch);
    const m3 = try captureAt(&f, alloc, "three", base_ms + 12 * hour, .poll);
    alloc.free(m3.branch);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 13 * hour };

    const two_h = try resolve(ctx, "@2h");
    defer two_h.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 11 * hour), two_h.target.at.ms);

    const thirty_m = try resolve(ctx, "@30m");
    defer thirty_m.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 12 * hour), thirty_m.target.at.ms);

    const save = try resolve(ctx, "@save");
    defer save.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 10 * hour), save.target.at.ms);
}

test "by id prefix, and ~n from there" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    defer alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    defer alloc.free(m2.branch);
    const m3 = try captureAt(&f, alloc, "three", base_ms + 3000, .poll);
    defer alloc.free(m3.branch);

    var buf: [16]u8 = undefined;
    const hex = m2.shortId(&buf);
    const spec = try std.fmt.allocPrint(alloc, "@{s}", .{hex[0..6]});
    defer alloc.free(spec);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 4000 };
    const r = try resolve(ctx, spec);
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 2000), r.target.at.ms);

    const spec_back = try std.fmt.allocPrint(alloc, "@{s}~1", .{hex[0..6]});
    defer alloc.free(spec_back);
    const rb = try resolve(ctx, spec_back);
    defer rb.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), rb.target.at.ms);
}

test "non-revspecs and junk selectors are rejected" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();
    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 1 };

    try testing.expect(!looksLikeRevspec("main"));
    try testing.expectError(Error.NotARevspec, resolve(ctx, "main"));
    try testing.expectError(Error.UnknownSelector, resolve(ctx, "@wat"));
}

test "ranges parse both ends and default sensibly" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .save);
    alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    alloc.free(m2.branch);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 3000 };

    // `@save..` runs from the last checkpoint to the live tree.
    const open = try resolveRange(ctx, "@save..");
    defer open.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), open.from.?.target.at.ms);
    try testing.expect(open.to.target == .live);

    // `@~0` is `@` with zero steps back, which is the live tree, not a moment.
    const zero_back = try resolveRange(ctx, "@save..@~0");
    defer zero_back.deinit(alloc);
    try testing.expect(zero_back.to.target == .live);

    // A genuinely closed range ends on a captured state.
    const closed = try resolveRange(ctx, "@save..@~1");
    defer closed.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 1000), closed.to.target.at.ms);

    // A bare spec is a range from the beginning of history.
    const bare = try resolveRange(ctx, "@save");
    defer bare.deinit(alloc);
    try testing.expect(bare.from == null);
}

fn commitAt(f: *Fixture, alloc: std.mem.Allocator, branch: []const u8, message: []const u8, parents: []const Oid) !Oid {
    const blob = try f.store.writeFileContent(message);
    const entries = [_]object.TreeEntry{.{ .mode = .regular, .path = "a.txt", .blob = blob }};
    const tree = try f.store.writeTree(.{ .entries = &entries });
    const change = object.Change{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{0} ** 16,
        .timestamp = @divTrunc(base_ms, 1000),
        .tz_offset_min = 0,
        .author = "t <t@t>",
        .message = message,
    };
    const id = try f.store.writeChange(change);
    try f.store.updateRef(branch, id);
    _ = alloc;
    return id;
}

fn freeEntries(alloc: std.mem.Allocator, entries: []object.TreeEntry) void {
    for (entries) |e| alloc.free(e.path);
    alloc.free(entries);
}

test "a change id from the log resolves, bare and with the sigil" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const root = try commitAt(&f, alloc, "main", "one", &.{});
    const tip = try commitAt(&f, alloc, "main", "two", &.{root});

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms };

    var hex: [Oid.len * 2]u8 = undefined;
    _ = tip.toHex(&hex);

    const full = try resolve(ctx, &hex);
    defer full.deinit(alloc);
    try testing.expectEqualSlices(u8, tip.bytes[0..8], &full.target.at.id);

    const entries = try moment.entriesOf(&f.store, full.target.at);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    const body = try f.store.readFileContent(entries[0].blob);
    defer alloc.free(body);
    try testing.expectEqualStrings("two", body);

    const short = try resolve(ctx, hex[0..12]);
    defer short.deinit(alloc);
    try testing.expectEqualSlices(u8, tip.bytes[0..8], &short.target.at.id);

    const spec = try std.fmt.allocPrint(alloc, "@{s}", .{hex[0..12]});
    defer alloc.free(spec);
    const sigil = try resolve(ctx, spec);
    defer sigil.deinit(alloc);
    try testing.expectEqualSlices(u8, tip.bytes[0..8], &sigil.target.at.id);

    const parent_spec = try std.fmt.allocPrint(alloc, "{s}~1", .{hex[0..12]});
    defer alloc.free(parent_spec);
    const parent = try resolve(ctx, parent_spec);
    defer parent.deinit(alloc);
    try testing.expectEqualSlices(u8, root.bytes[0..8], &parent.target.at.id);

    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "0123456789ab"));
}

test "an ambiguous id prefix names its candidates" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const first = try commitAt(&f, alloc, "main", "one", &.{});
    var first_hex: [Oid.len * 2]u8 = undefined;
    _ = first.toHex(&first_hex);
    const prefix = first_hex[0..4];

    const tree = try f.store.writeTree(.{ .entries = &.{} });
    var i: usize = 0;
    const twin = while (i < 8_000_000) : (i += 1) {
        var msg_buf: [32]u8 = undefined;
        const message = try std.fmt.bufPrint(&msg_buf, "twin {d}", .{i});
        const enc = try object.Change.encode(.{
            .tree = tree,
            .parents = &.{},
            .change_id = [_]u8{0} ** 16,
            .timestamp = @divTrunc(base_ms, 1000),
            .tz_offset_min = 0,
            .author = "t <t@t>",
            .message = message,
        }, alloc);
        defer alloc.free(enc);
        var cand_hex: [Oid.len * 2]u8 = undefined;
        _ = Oid.ofBytes(enc).toHex(&cand_hex);
        if (!hexHasPrefix(&cand_hex, prefix)) continue;
        break try f.store.writeRaw(enc);
    } else return error.NoTwinFound;
    try testing.expect(!twin.eql(first));
    try f.store.updateRef("side", twin);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms };
    try testing.expectError(Error.AmbiguousMoment, resolve(ctx, prefix));

    const spec = try std.fmt.allocPrint(alloc, "@{s}", .{prefix});
    defer alloc.free(spec);
    try testing.expectError(Error.AmbiguousMoment, resolve(ctx, spec));

    var found: std.ArrayList(Match) = .empty;
    defer found.deinit(alloc);
    try matches(ctx, spec, &found);
    try testing.expectEqual(@as(usize, 2), found.items.len);
    for (found.items) |m| {
        try testing.expect(m.kind == .change);
        try testing.expectEqualStrings(prefix, m.id()[0..4]);
    }
}

test "a branch name resolves to its tip and walks back from there" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const root = try commitAt(&f, alloc, "main", "one", &.{});
    const tip = try commitAt(&f, alloc, "main", "two", &.{root});

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms };

    const head = try resolve(ctx, "main");
    defer head.deinit(alloc);
    try testing.expectEqualSlices(u8, tip.bytes[0..8], &head.target.at.id);

    const back = try resolve(ctx, "main~1");
    defer back.deinit(alloc);
    try testing.expectEqualSlices(u8, root.bytes[0..8], &back.target.at.id);

    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "main~2"));
}

test "a moment id resolves without the sigil too" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    const m1 = try captureAt(&f, alloc, "one", base_ms + 1000, .poll);
    defer alloc.free(m1.branch);
    const m2 = try captureAt(&f, alloc, "two", base_ms + 2000, .poll);
    defer alloc.free(m2.branch);

    var buf: [16]u8 = undefined;
    const hex = m2.shortId(&buf);

    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms + 3000 };
    const r = try resolve(ctx, hex[0..12]);
    defer r.deinit(alloc);
    try testing.expectEqual(@as(i64, base_ms + 2000), r.target.at.ms);
}

test "an unresolvable ref comes back as an error, never a panic" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit();

    _ = try commitAt(&f, alloc, "main", "one", &.{});
    const ctx = Context{ .store = &f.store, .alloc = alloc, .now_ms = base_ms };

    try testing.expectError(Error.NotARevspec, resolve(ctx, "nope"));
    try testing.expectError(Error.NotARevspec, resolve(ctx, ""));
    try testing.expectError(Error.UnknownSelector, resolve(ctx, "@wat"));
    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "deadbeef"));
    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "@deadbeef"));
    try testing.expectError(Error.NoSuchMoment, resolve(ctx, "@green"));
}
