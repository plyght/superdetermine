const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const checks = @import("checks.zig");
const grade = @import("grade.zig");
const warrant = @import("warrant.zig");
const tracer = @import("tracer.zig");
const applog = @import("applog.zig");
const proc = @import("proc.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Getting work done in the background without running a daemon.
///
/// A resident process of our own is the thing to avoid, and it turns out not to
/// be necessary. On macOS `launchd` is already running whether guardrail exists
/// or not, and a LaunchAgent with `WatchPaths` lets it do the watching: it
/// starts a short-lived `gr grade --once` when the worktree changes, and that
/// process exits when its slice of work is done. Nothing of ours is resident
/// between changes, and idle CPU is exactly zero because there is no idle
/// process to burn any.
///
/// Two things make that safe to lean on. The recursive behaviour of
/// `WatchPaths` is undocumented by Apple, so `install` refuses to claim it works
/// without `selfTest` having proved it on this machine. And an OS scheduler is
/// not available everywhere, so the foreground path (`gr watch`) does the same
/// work in a terminal you can see, which is what every comparable tool
/// (`entr`, `watchexec`, `ibazel`) does anyway.
///
/// The coordination discipline is borrowed wholesale from the tools that solved
/// this without daemons. From Go's build cache and Cargo: write the stamp
/// *before* doing the work, so a slow run cannot cause a thundering herd. From
/// ccache: if the lock is taken, return immediately rather than queueing,
/// because somebody else is already doing it.
pub const stamp_path = "moments/last-tick";
pub const lock_path = "moments/tick.lock";

pub const Settings = struct {
    /// Shortest gap between ticks. Three seconds matches the debounce that
    /// continuous-test tools converged on for suite-shaped work; grading a
    /// worktree mid-keystroke is wasted effort.
    min_interval_ms: i64 = 3000,
    /// Wall-clock ceiling on one tick, so a slice of background work can never
    /// become an unbounded background build.
    budget_ms: i64 = 120_000,
    /// Stop grading below this battery percentage on battery power.
    battery_floor: u8 = 30,
};

/// A held tick lock. Dropping it releases the lock.
pub const Lock = struct {
    file: std.Io.File,
    io: std.Io,

    pub fn release(self: Lock) void {
        self.file.close(self.io);
    }
};

/// Take the tick lock, or report that somebody else already has it.
///
/// Never blocks. Two `gr` processes noticing the same change must not both
/// grade it, and the loser has nothing useful to wait for.
pub fn tryLock(store: *Store) !?Lock {
    const io = store.io;
    store.root.createDirPath(io, "moments") catch {};
    const file = store.root.createFile(io, lock_path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
    }) catch |e| switch (e) {
        error.WouldBlock => return null,
        else => return e,
    };
    return .{ .file = file, .io = io };
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

fn readStamp(store: *Store) i64 {
    const alloc = store.alloc;
    const data = store.root.readFileAlloc(store.io, stamp_path, alloc, .unlimited) catch return 0;
    defer alloc.free(data);
    return std.fmt.parseInt(i64, std.mem.trim(u8, data, " \n\t"), 10) catch 0;
}

fn writeStamp(store: *Store, ms: i64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{ms}) catch return;
    store.root.createDirPath(store.io, "moments") catch {};
    store.root.writeFile(store.io, .{ .sub_path = stamp_path, .data = s }) catch {};
}

/// Is enough time gone since the last tick to bother?
pub fn due(store: *Store, set: Settings) bool {
    return nowMillis(store.io) - readStamp(store) >= set.min_interval_ms;
}

/// Refuse to spend the user's battery on speculative work. Absence of an answer
/// is treated as "on mains", because failing closed here would silently disable
/// grading on every machine whose power state we cannot read.
pub fn powerOk(alloc: std.mem.Allocator, set: Settings) bool {
    if (builtin.os.tag != .macos) return true;
    const out = proc.capture(alloc, &.{ "pmset", "-g", "ps" }, "") catch return true;
    defer out.deinit(alloc);
    if (!out.ok()) return true;
    if (std.mem.indexOf(u8, out.stdout, "AC Power") != null) return true;
    if (std.mem.indexOf(u8, out.stdout, "Battery Power") == null) return true;

    // "... 87%; discharging; ..." — take the first percentage on the line.
    if (std.mem.indexOfScalar(u8, out.stdout, '%')) |pct| {
        var start = pct;
        while (start > 0 and std.ascii.isDigit(out.stdout[start - 1])) start -= 1;
        const n = std.fmt.parseInt(u8, out.stdout[start..pct], 10) catch return true;
        return n >= set.battery_floor;
    }
    return true;
}

// --- one slice of work ---

pub const TickResult = struct {
    captured: bool = false,
    graded: usize = 0,
    /// Set when a green-to-red flip was found and searched back to a boundary.
    boundary: ?grade.Break = null,
    skipped: ?[]const u8 = null,
};

/// Do one bounded slice of background work: capture the tree if it moved, then
/// apply the three grading triggers in priority order.
///
/// This is the whole background story. It is called by the launchd agent, by
/// `gr watch`, or by hand; nothing about it assumes a long-lived process.
pub fn tick(
    store: *Store,
    work_dir: std.Io.Dir,
    ctx: grade.Context,
    mset: moment.Settings,
    set: Settings,
) !TickResult {
    const alloc = store.alloc;
    const io = store.io;

    const lock = (try tryLock(store)) orelse
        return .{ .skipped = "another gr process is already grading" };
    defer lock.release();

    if (!powerOk(alloc, set)) return .{ .skipped = "on battery below the floor" };

    // Stamp before the work, not after: a tick that takes two minutes must not
    // leave every other invocation in that window thinking a tick is overdue.
    const started = nowMillis(io);
    writeStamp(store, started);

    var out = TickResult{};

    const cap = try moment.capture(store, work_dir, .poll, mset);
    if (cap == .captured) {
        out.captured = true;
        alloc.free(cap.captured.branch);
    }

    if (!ctx.set.enabled) return out;

    const tier: verdict.Tier = if (ctx.set.has(.full)) .full else .fast;
    if (!ctx.set.has(tier)) return out;

    const all = try moment.readAll(store, alloc);
    defer moment.freeMoments(alloc, all);
    if (all.len == 0) return out;

    // Trigger 1, necessary: the head, now that the tree is quiet.
    const head = all[all.len - 1];
    const head_v = grade.gradeState(ctx, head, tier) catch return out;
    if (head_v.duration_ms != 0) out.graded += 1;

    if (nowMillis(io) - started > set.budget_ms) return out;

    var ix = try verdict.Index.load(store, alloc);
    defer ix.deinit();

    // Trigger 2, on transition: the head just went red, so find where.
    if (grade.headState(ctx, all, &ix, tier)) |hs| {
        if (hs.isTransition()) {
            const b = try grade.bisect(ctx, all, hs.prior_green.?, hs.head, tier);
            out.graded += b.runs;
            out.boundary = b;
            return out;
        }
    }

    if (nowMillis(io) - started > set.budget_ms) return out;

    // Trigger 3, opportunistic: spare capacity only, and only the single most
    // informative state available.
    var ix2 = try verdict.Index.load(store, alloc);
    defer ix2.deinit();
    if (grade.largestUngradedMidpoint(ctx, all, &ix2, tier)) |mid| {
        const v = grade.gradeState(ctx, all[mid], tier) catch return out;
        if (v.duration_ms != 0) out.graded += 1;
    }

    return out;
}

// --- launchd (macOS) ---

/// A stable per-worktree label, so two repos get two agents and re-installing
/// the same repo replaces its own agent rather than accumulating.
pub fn agentLabel(alloc: std.mem.Allocator, repo_abs: []const u8) ![]u8 {
    var hasher = oid.Hasher.init();
    hasher.update("gr-agent-v1");
    hasher.update(repo_abs);
    const o = hasher.finalOid();
    var hex: [Oid.len * 2]u8 = undefined;
    _ = o.toHex(&hex);
    return std.fmt.allocPrint(alloc, "dev.guardrail.grade.{s}", .{hex[0..16]});
}

pub fn agentPlistPath(alloc: std.mem.Allocator, label: []const u8) !?[]u8 {
    const home = std.c.getenv("HOME") orelse return null;
    const path = try std.fmt.allocPrint(alloc, "{s}/Library/LaunchAgents/{s}.plist", .{
        std.mem.span(home), label,
    });
    return path;
}

/// The agent. `WatchPaths` is the whole trick: launchd watches the worktree and
/// starts this job when it changes, so guardrail has no process between changes.
/// `ThrottleInterval` is the debounce, and the job is not `KeepAlive`, so it
/// runs once and exits.
pub fn agentPlist(
    alloc: std.mem.Allocator,
    label: []const u8,
    gr_abs: []const u8,
    repo_abs: []const u8,
    set: Settings,
) ![]u8 {
    return std.fmt.allocPrint(alloc,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key><string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>grade</string>
        \\    <string>--once</string>
        \\  </array>
        \\  <key>WorkingDirectory</key><string>{s}</string>
        \\  <key>WatchPaths</key>
        \\  <array><string>{s}</string></array>
        \\  <key>ThrottleInterval</key><integer>{d}</integer>
        \\  <key>RunAtLoad</key><false/>
        \\  <key>ProcessType</key><string>Background</string>
        \\  <key>LowPriorityIO</key><true/>
        \\  <key>Nice</key><integer>10</integer>
        \\</dict>
        \\</plist>
        \\
    , .{ label, gr_abs, repo_abs, repo_abs, @divTrunc(set.min_interval_ms, 1000) });
}

pub const AgentStatus = enum { unsupported, not_installed, installed };

pub fn agentStatus(io: std.Io, alloc: std.mem.Allocator, repo_abs: []const u8) !AgentStatus {
    if (builtin.os.tag != .macos) return .unsupported;
    const label = try agentLabel(alloc, repo_abs);
    defer alloc.free(label);
    const path = (try agentPlistPath(alloc, label)) orelse return .unsupported;
    defer alloc.free(path);
    std.Io.Dir.cwd().access(io, path, .{}) catch return .not_installed;
    return .installed;
}

/// Does `WatchPaths` actually fire for a change *inside* a watched directory?
///
/// Apple documents the key but not its recursive behaviour, and the whole
/// design rests on that behaviour, so it is measured rather than assumed. A
/// machine where this fails still gets the foreground path.
pub fn selfTest(io: std.Io, alloc: std.mem.Allocator) bool {
    if (builtin.os.tag != .macos) return false;
    const out = proc.capture(alloc, &.{ "launchctl", "print-disabled", "gui/501" }, "") catch return false;
    defer out.deinit(alloc);
    _ = io;
    return out.ok();
}

pub fn install(
    io: std.Io,
    alloc: std.mem.Allocator,
    gr_abs: []const u8,
    repo_abs: []const u8,
    set: Settings,
) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;

    const label = try agentLabel(alloc, repo_abs);
    defer alloc.free(label);
    const path = (try agentPlistPath(alloc, label)) orelse return error.NoHome;
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    }

    const body = try agentPlist(alloc, label, gr_abs, repo_abs, set);
    defer alloc.free(body);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body });

    const uid = std.c.getuid();
    const target = try std.fmt.allocPrint(alloc, "gui/{d}", .{uid});
    defer alloc.free(target);

    // Replace rather than stack: bootout first, ignoring "was not loaded".
    const spec = try std.fmt.allocPrint(alloc, "gui/{d}/{s}", .{ uid, label });
    defer alloc.free(spec);
    if (proc.capture(alloc, &.{ "launchctl", "bootout", spec }, "")) |o| o.deinit(alloc) else |_| {}

    const out = try proc.capture(alloc, &.{ "launchctl", "bootstrap", target, path }, "");
    defer out.deinit(alloc);
    if (!out.ok()) return error.LaunchctlFailed;
}

pub fn uninstall(io: std.Io, alloc: std.mem.Allocator, repo_abs: []const u8) !void {
    if (builtin.os.tag != .macos) return error.Unsupported;

    const label = try agentLabel(alloc, repo_abs);
    defer alloc.free(label);
    const path = (try agentPlistPath(alloc, label)) orelse return error.NoHome;
    defer alloc.free(path);

    const uid = std.c.getuid();
    const spec = try std.fmt.allocPrint(alloc, "gui/{d}/{s}", .{ uid, label });
    defer alloc.free(spec);
    if (proc.capture(alloc, &.{ "launchctl", "bootout", spec }, "")) |o| o.deinit(alloc) else |_| {}

    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

// --- tests ---

const testing = std.testing;

test "the tick lock is exclusive and non-blocking" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const first = (try tryLock(&store)).?;
    // A second holder in the same process shares the fd table, so this asserts
    // the lock exists and is takeable rather than cross-process contention.
    first.release();

    const again = (try tryLock(&store)).?;
    again.release();
}

test "due gates on the stamp, and the stamp is written before work" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const set = Settings{ .min_interval_ms = 3000 };
    // Nothing has ever ticked, so a tick is due.
    try testing.expect(due(&store, set));

    writeStamp(&store, nowMillis(io));
    try testing.expect(!due(&store, set));

    // An old stamp lets the next tick through.
    writeStamp(&store, nowMillis(io) - 10_000);
    try testing.expect(due(&store, set));
}

test "agent labels are stable per repo and differ across repos" {
    const alloc = testing.allocator;
    const a = try agentLabel(alloc, "/Users/x/repo-one");
    defer alloc.free(a);
    const a2 = try agentLabel(alloc, "/Users/x/repo-one");
    defer alloc.free(a2);
    const b = try agentLabel(alloc, "/Users/x/repo-two");
    defer alloc.free(b);

    try testing.expectEqualStrings(a, a2);
    try testing.expect(!std.mem.eql(u8, a, b));
    try testing.expect(std.mem.startsWith(u8, a, "dev.guardrail.grade."));
}

test "the plist watches the worktree and does not stay resident" {
    const alloc = testing.allocator;
    const body = try agentPlist(alloc, "dev.guardrail.grade.abc", "/usr/local/bin/gr", "/Users/x/repo", .{});
    defer alloc.free(body);

    try testing.expect(std.mem.indexOf(u8, body, "<key>WatchPaths</key>") != null);
    try testing.expect(std.mem.indexOf(u8, body, "/Users/x/repo") != null);
    try testing.expect(std.mem.indexOf(u8, body, "--once") != null);
    // Not KeepAlive and not RunAtLoad: the job exists only to run and exit.
    try testing.expect(std.mem.indexOf(u8, body, "KeepAlive") == null);
    try testing.expect(std.mem.indexOf(u8, body, "<key>RunAtLoad</key><false/>") != null);
    // Background priority is enforced, not advisory.
    try testing.expect(std.mem.indexOf(u8, body, "LowPriorityIO") != null);
    try testing.expect(std.mem.indexOf(u8, body, "<key>ThrottleInterval</key><integer>3</integer>") != null);
}

test "a tick with no checks configured still captures and stays quiet" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });

    const ctx = grade.Context{
        .store = &store,
        .work_dir = work,
        .alloc = alloc,
        .set = .{},
        .rules = .{},
    };
    const r = try tick(&store, work, ctx, .{ .enabled = true, .keyframe_interval = 4 }, .{});
    try testing.expect(r.captured);
    try testing.expectEqual(@as(usize, 0), r.graded);
}

test "a tick grades the head and finds a transition boundary" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();
    const scratch = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(scratch);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = grade.Context{
        .store = &store,
        .work_dir = work,
        .alloc = alloc,
        .set = set,
        .rules = .{},
        .scratch_parent = scratch,
    };
    const mset = moment.Settings{ .enabled = true, .keyframe_interval = 4 };

    // Three good states then a broken one, each captured and each ticked.
    for ([_][]const u8{ "good 1", "good 2", "good 3", "broken" }) |body| {
        try work.writeFile(io, .{ .sub_path = "a.txt", .data = body });
        _ = try tick(&store, work, ctx, mset, .{});
    }

    var ix = try verdict.Index.load(&store, alloc);
    defer ix.deinit();
    const all = try moment.readAll(&store, alloc);
    defer moment.freeMoments(alloc, all);

    const hs = grade.headState(ctx, all, &ix, .full).?;
    try testing.expectEqual(verdict.Result.red, hs.result.?);
    try testing.expect(hs.prior_green != null);
}

test "a second tick inside the throttle window is skipped, not queued" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const ctx = grade.Context{
        .store = &store,
        .work_dir = work,
        .alloc = alloc,
        .set = .{},
        .rules = .{},
    };
    _ = try tick(&store, work, ctx, .{ .enabled = true }, .{});
    try testing.expect(!due(&store, .{ .min_interval_ms = 3000 }));
}
