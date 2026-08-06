const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// The verdict store: what a given tree did when a given check ran against it.
///
/// A verdict is keyed by `(tree Oid, tier, command hash)` and never by a moment
/// id, which is what makes "a tree is never graded twice, ever" true even across
/// branches, forks, rewinds and retention trims. Two moments that happen to hold
/// identical content share one verdict for free.
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
};

// --- encoding ---

fn formatLine(alloc: std.mem.Allocator, v: Verdict) ![]u8 {
    var tree_hex: [Oid.len * 2]u8 = undefined;
    var cmd_hex: [Oid.len * 2]u8 = undefined;
    var rs_hex: [Oid.len * 2]u8 = undefined;
    _ = v.tree.toHex(&tree_hex);
    _ = v.command.toHex(&cmd_hex);
    _ = v.readset.toHex(&rs_hex);
    return std.fmt.allocPrint(
        alloc,
        "{s} {s} {s} {s} {d} {d} {d} {s} {s} {d} {d} {s}\n",
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

    return .{
        .tree = Oid.fromHex(tree_s) catch return error.InvalidVerdict,
        .tier = Tier.fromLabel(tier_s) orelse return error.InvalidVerdict,
        .command = Oid.fromHex(cmd_s) catch return error.InvalidVerdict,
        .result = enumFromLabel(Result, res_s, .red),
        .exit_code = std.fmt.parseInt(i32, exit_s, 10) catch return error.InvalidVerdict,
        .duration_ms = std.fmt.parseInt(u32, dur_s, 10) catch 0,
        .ms = std.fmt.parseInt(i64, ms_s, 10) catch 0,
        .readset = Oid.fromHex(rs_s) catch Oid.zero(),
        .independence = enumFromLabel(Independence, ind_s, .unknown),
        .relevance_hit = std.fmt.parseInt(u16, hit_s, 10) catch 0,
        .relevance_total = std.fmt.parseInt(u16, tot_s, 10) catch 0,
        .discrimination = enumFromLabel(Discrimination, dis_s, .unknown),
    };
}

/// BLAKE3 of a check command string, domain-separated from every other digest.
pub fn commandHash(command: []const u8) Oid {
    var hasher = oid.Hasher.init();
    hasher.update("gr-check-v1");
    hasher.update(command);
    return hasher.finalOid();
}

// --- store ---

pub fn record(store: *Store, v: Verdict) !void {
    const alloc = store.alloc;
    const line = try formatLine(alloc, v);
    defer alloc.free(line);
    try applog.append(store, log_path, line);
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
    const all = try readAll(store, alloc);
    defer alloc.free(all);

    var found: ?Verdict = null;
    for (all) |v| {
        if (!v.tree.eql(key.tree)) continue;
        if (v.tier != key.tier) continue;
        if (!v.command.eql(key.command)) continue;
        found = v;
    }
    return found;
}

/// An in-memory index for callers that ask about many trees at once (the
/// grading policy, `gr recap`, the moment listing). One pass over the log
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
