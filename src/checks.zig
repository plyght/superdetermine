const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const config = @import("config.zig");
const branches = @import("branches.zig");
const workspace = @import("workspace.zig");
const readset = @import("readset.zig");
const tracer = @import("tracer.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Running a project's own check against a state, out of the developer's way.
///
/// The developer's worktree is never touched and their terminal never blocks.
/// A state is graded by copy-on-write cloning the live worktree, reconciling
/// that clone to the target tree, and running the check inside it. Cloning the
/// live tree rather than materialising from the object store is deliberate:
/// everything the project ignores (`node_modules`, `zig-cache`, `target`) comes
/// along for free, so the check runs against a warm build instead of a cold one.
///
/// If nothing is configured, gr does nothing. There is no guessing a build
/// command from the presence of a `package.json`.
extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

const PRIO_PROCESS: c_int = 0;

pub const Error = error{
    NoCheckConfigured,
    CloneFailed,
    SpawnFailed,
};

pub const Settings = struct {
    enabled: bool = false,
    /// Typecheck/lint. Empty means this tier is not configured.
    fast: []const u8 = "",
    /// The suite. Empty means this tier is not configured.
    full: []const u8 = "",
    /// Ceiling on CPU, as a percentage of one core. Enforced, not an average.
    budget_percent: u8 = 25,
    /// Refuse to grade below this battery percentage when on battery power.
    battery_floor: u8 = 30,
    /// Niceness applied to the check process. Positive is lower priority.
    nice: i8 = 10,

    pub fn command(self: Settings, tier: verdict.Tier) []const u8 {
        return switch (tier) {
            .fast => self.fast,
            .full => self.full,
        };
    }

    pub fn has(self: Settings, tier: verdict.Tier) bool {
        return self.command(tier).len != 0;
    }

    pub fn deinit(self: Settings, alloc: std.mem.Allocator) void {
        if (self.fast.len != 0) alloc.free(self.fast);
        if (self.full.len != 0) alloc.free(self.full);
    }
};

fn boolOf(v: []const u8) bool {
    return !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no"));
}

fn getStr(store: *Store, alloc: std.mem.Allocator, key: []const u8) []const u8 {
    if (config.get(store, alloc, key)) |maybe| {
        if (maybe) |v| return v;
    } else |_| {}
    return "";
}

/// Read check settings. `enabled` defaults to true *only* when at least one
/// tier has a command, so a repo that never configured a check stays inert.
pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out = Settings{};
    out.fast = getStr(store, alloc, "checks.fast");
    out.full = getStr(store, alloc, "checks.full");
    out.enabled = out.fast.len != 0 or out.full.len != 0;

    if (config.get(store, alloc, "checks.enabled")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.enabled = out.enabled and boolOf(v);
        }
    } else |_| {}
    if (config.get(store, alloc, "checks.budget")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            const trimmed = std.mem.trimEnd(u8, v, "%");
            out.budget_percent = std.fmt.parseInt(u8, trimmed, 10) catch out.budget_percent;
        }
    } else |_| {}
    if (config.get(store, alloc, "checks.battery_floor")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.battery_floor = std.fmt.parseInt(u8, v, 10) catch out.battery_floor;
        }
    } else |_| {}
    if (config.get(store, alloc, "checks.nice")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.nice = std.fmt.parseInt(i8, v, 10) catch out.nice;
        }
    } else |_| {}
    return out;
}

// --- reconciling a clone to a target tree ---

/// Bring `dest` to exactly `entries`: write every file whose content differs and
/// delete every tracked file that the target does not have. Files the project
/// ignores are left alone, which is what preserves the warm build.
///
/// Only differing files are written, so reconciling a clone of a neighbouring
/// state usually touches a handful of paths.
pub fn reconcile(
    store: *Store,
    dest: std.Io.Dir,
    entries: []const object.TreeEntry,
) !void {
    const io = store.io;
    const alloc = store.alloc;

    var want = std.StringHashMap(Oid).init(alloc);
    defer want.deinit();
    for (entries) |e| try want.put(e.path, e.blob);

    // Delete tracked paths the target does not have. The clone's own tracked
    // set is whatever `captureEntries` sees in it.
    const present = try workspace.captureEntries(store, dest);
    defer workspace.freeTreeEntries(alloc, present);
    for (present) |e| {
        if (want.contains(e.path)) continue;
        dest.deleteFile(io, e.path) catch {};
    }

    var have = std.StringHashMap(Oid).init(alloc);
    defer have.deinit();
    for (present) |e| try have.put(e.path, e.blob);

    for (entries) |e| {
        if (have.get(e.path)) |cur| {
            if (cur.eql(e.blob)) continue;
        }
        if (std.fs.path.dirnamePosix(e.path)) |dir| {
            dest.createDirPath(io, dir) catch {};
        }
        const data = try store.readFileContent(e.blob);
        defer alloc.free(data);
        try dest.writeFile(io, .{ .sub_path = e.path, .data = data });
    }
}

// --- running ---

pub const RunOutcome = struct {
    exit_code: i32,
    duration_ms: u32,

    pub fn result(self: RunOutcome) verdict.Result {
        return if (self.exit_code == 0) .green else .red;
    }
};

/// How to launch the check. `wrapper` is prepended to the argv, which is how a
/// read-set tracer inserts itself without this module knowing anything about
/// tracing. `env` entries are set in the child only.
pub const Launch = struct {
    wrapper: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    nice: i8 = 10,
};

/// Run `command` with `/bin/sh -c` inside `cwd_path`. A shell is used on
/// purpose: the command comes from the repo's own config, and real check
/// commands contain pipes, `&&`, and variable expansion. Nothing external ever
/// reaches this string.
pub fn run(
    alloc: std.mem.Allocator,
    io: std.Io,
    cwd_path: []const u8,
    command: []const u8,
    launch: Launch,
) !RunOutcome {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var argv: std.ArrayList([]const u8) = .empty;
    for (launch.wrapper) |a| try argv.append(aa, a);
    try argv.append(aa, "/bin/sh");
    try argv.append(aa, "-c");
    try argv.append(aa, command);

    const cargv = try aa.allocSentinel(?[*:0]const u8, argv.items.len, null);
    for (argv.items, 0..) |a, i| cargv[i] = (try aa.dupeZ(u8, a)).ptr;

    const cwd_z = try aa.dupeZ(u8, cwd_path);

    const env_z = try aa.alloc([2][:0]const u8, launch.env.len);
    for (launch.env, 0..) |pair, i| {
        env_z[i] = .{ try aa.dupeZ(u8, pair[0]), try aa.dupeZ(u8, pair[1]) };
    }

    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;

    const pid = fork();
    if (pid < 0) return Error.SpawnFailed;
    if (pid == 0) {
        if (chdir(cwd_z.ptr) != 0) _exit(126);
        // Layer 4 is enforced, not advisory. A grade that competes with the
        // developer's own build is worse than no grade.
        _ = setpriority(PRIO_PROCESS, 0, launch.nice);
        for (env_z) |pair| _ = setenv(pair[0].ptr, pair[1].ptr, 1);
        // stdout and stderr go to /dev/null: a background grade must never
        // write into the developer's terminal.
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.dup2(devnull, 1);
            _ = std.c.dup2(devnull, 2);
        }
        _ = execvp(cargv[0].?, cargv.ptr);
        _exit(127);
    }

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const end_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const elapsed_ms: u32 = @intCast(@divTrunc(end_ns - start_ns, 1_000_000));

    return .{ .exit_code = exitCode(status), .duration_ms = elapsed_ms };
}

/// Decode a waitpid status into a plain exit code, mapping a signal death to a
/// non-zero code so a killed check reads as red rather than green.
pub fn exitCode(status: c_int) i32 {
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @intCast((s >> 8) & 0xff);
    return 128 + @as(i32, @intCast(s & 0x7f));
}

// --- grading one state ---

pub const GradeOptions = struct {
    tier: verdict.Tier,
    launch: Launch = .{},
    /// Where scratch clones are made. Defaults to the parent of the worktree.
    scratch_parent: ?[]const u8 = null,
    /// Measure which files the check reads. Off for runs whose read-set would
    /// never be consulted, such as the discrimination probe.
    trace: bool = true,
};

pub const Graded = struct {
    outcome: RunOutcome,
    /// What the check actually opened, when it could be measured.
    read_set: ?readset.ReadSet = null,
    tracer_mode: tracer.Mode = .conservative,
    /// Why tracing landed where it did, for `gr doctor`.
    tracer_reason: []const u8 = "",

    pub fn deinit(self: Graded, alloc: std.mem.Allocator) void {
        if (self.read_set) |rs| rs.deinit(alloc);
    }
};

/// Clone the live worktree, reconcile it to `entries`, run the tier's command in
/// it, and remove the clone. Returns the raw outcome; the caller attaches the
/// warrant and records the verdict.
///
/// `label` only names the scratch directory. It never affects the result, which
/// is why grading a hybrid tree that no moment ever held works here unchanged.
pub fn gradeEntries(
    store: *Store,
    work_dir: std.Io.Dir,
    entries: []const object.TreeEntry,
    label: []const u8,
    set: Settings,
    opts: GradeOptions,
) !Graded {
    const io = store.io;
    const alloc = store.alloc;

    const command = set.command(opts.tier);
    if (command.len == 0) return Error.NoCheckConfigured;

    const src_abs = try work_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(src_abs);

    const parent = opts.scratch_parent orelse std.fs.path.dirname(src_abs) orelse "/tmp";
    const dst_abs = try std.fmt.allocPrint(alloc, "{s}/.gr-grade-{s}-{s}", .{
        parent, label, opts.tier.label(),
    });
    defer alloc.free(dst_abs);

    // A leftover clone from a killed run must not poison this one.
    removeTree(io, dst_abs);
    branches.work(io, src_abs, dst_abs) catch return Error.CloneFailed;
    defer removeTree(io, dst_abs);

    var dst = try std.Io.Dir.openDirAbsolute(io, dst_abs, .{ .iterate = true });
    defer dst.close(io);

    try reconcile(store, dst, entries);

    // Arming has to come after both the clone and the reconcile: a clone
    // preserves access times, and reconciling writes files. Arm any earlier and
    // the run's own setup would look like the check's reads.
    var availability = tracer.Availability{ .mode = .conservative, .reason = "tracing not requested" };
    if (opts.trace) {
        availability = tracer.detect(io, alloc, dst, dst_abs);
        if (availability.mode == .atime) {
            _ = tracer.arm(alloc, dst_abs, entries) catch {
                availability = .{ .mode = .conservative, .reason = "could not backdate access times" };
            };
        }
    }

    var launch = opts.launch;
    launch.nice = set.nice;
    const outcome = try run(alloc, io, dst_abs, command, launch);

    var rs: ?readset.ReadSet = null;
    if (opts.trace) {
        rs = switch (availability.mode) {
            .atime => tracer.harvest(alloc, io, dst, entries) catch
                try tracer.conservativeSet(alloc, entries),
            .conservative => try tracer.conservativeSet(alloc, entries),
        };
    }

    return .{
        .outcome = outcome,
        .read_set = rs,
        .tracer_mode = availability.mode,
        .tracer_reason = availability.reason,
    };
}

pub fn gradeMoment(
    store: *Store,
    work_dir: std.Io.Dir,
    m: moment.Moment,
    set: Settings,
    opts: GradeOptions,
) !Graded {
    const alloc = store.alloc;
    const entries = try moment.entriesOf(store, m);
    defer workspace.freeTreeEntries(alloc, entries);

    var id_hex: [16]u8 = undefined;
    _ = m.shortId(&id_hex);
    return gradeEntries(store, work_dir, entries, id_hex[0..12], set, opts);
}

fn removeTree(io: std.Io, abs: []const u8) void {
    std.Io.Dir.cwd().deleteTree(io, abs) catch {};
}

// --- tests ---

const testing = std.testing;

test "exitCode maps clean exits, failures, and signals" {
    // waitpid status: low 7 bits signal, next 8 bits exit code.
    try testing.expectEqual(@as(i32, 0), exitCode(0));
    try testing.expectEqual(@as(i32, 1), exitCode(1 << 8));
    try testing.expectEqual(@as(i32, 3), exitCode(3 << 8));
    // SIGKILL (9) must not read as green.
    try testing.expect(exitCode(9) != 0);
}

test "run reports success and failure of a real command" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const ok = try run(alloc, io, abs, "exit 0", .{});
    try testing.expectEqual(@as(i32, 0), ok.exit_code);
    try testing.expectEqual(verdict.Result.green, ok.result());

    const bad = try run(alloc, io, abs, "exit 7", .{});
    try testing.expectEqual(@as(i32, 7), bad.exit_code);
    try testing.expectEqual(verdict.Result.red, bad.result());
}

test "run executes in the directory it was given" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "inner");
    try tmp.dir.writeFile(io, .{ .sub_path = "inner/marker", .data = "x" });
    const abs = try tmp.dir.realPathFileAlloc(io, "inner", alloc);
    defer alloc.free(abs);

    const r = try run(alloc, io, abs, "test -f marker", .{});
    try testing.expectEqual(@as(i32, 0), r.exit_code);
}

test "run passes env through to the child" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const r = try run(alloc, io, abs, "test \"$GR_TEST_VAR\" = hello", .{
        .env = &.{.{ "GR_TEST_VAR", "hello" }},
    });
    try testing.expectEqual(@as(i32, 0), r.exit_code);
}

test "reconcile brings a directory to a target tree" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "src");
    var src = try tmp.dir.openDir(io, "src", .{ .iterate = true });
    defer src.close(io);
    try src.writeFile(io, .{ .sub_path = "keep.txt", .data = "same" });
    try src.writeFile(io, .{ .sub_path = "change.txt", .data = "before" });
    try src.writeFile(io, .{ .sub_path = "gone.txt", .data = "doomed" });

    const target = try workspace.captureEntries(&store, src);
    defer workspace.freeTreeEntries(alloc, target);

    // A destination that differs in all three ways.
    try tmp.dir.createDirPath(io, "dst");
    var dst = try tmp.dir.openDir(io, "dst", .{ .iterate = true });
    defer dst.close(io);
    try dst.writeFile(io, .{ .sub_path = "keep.txt", .data = "same" });
    try dst.writeFile(io, .{ .sub_path = "change.txt", .data = "after" });
    try dst.writeFile(io, .{ .sub_path = "extra.txt", .data = "unwanted" });

    try reconcile(&store, dst, target);

    const changed = try dst.readFileAlloc(io, "change.txt", alloc, .unlimited);
    defer alloc.free(changed);
    try testing.expectEqualStrings("before", changed);

    const gone = try dst.readFileAlloc(io, "gone.txt", alloc, .unlimited);
    defer alloc.free(gone);
    try testing.expectEqualStrings("doomed", gone);

    try testing.expectError(error.FileNotFound, dst.access(io, "extra.txt", .{}));
}

test "settings stay inert until a check is configured" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expect(!s.enabled);
        try testing.expect(!s.has(.fast));
        try testing.expect(!s.has(.full));
    }

    try config.set(&store, "checks.full", "zig build test");
    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expect(s.enabled);
        try testing.expect(s.has(.full));
        try testing.expect(!s.has(.fast));
        try testing.expectEqualStrings("zig build test", s.command(.full));
        try testing.expectEqual(@as(u8, 25), s.budget_percent);
    }

    // The kill switch returns the repo to doing nothing at all.
    try config.set(&store, "checks.enabled", "false");
    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expect(!s.enabled);
    }
}

test "grading a moment runs against its content, not the live tree" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);

    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    const set = Settings{
        .enabled = true,
        // Green only when the file still says "good".
        .full = "grep -q good marker.txt",
    };
    const mset = moment.Settings{ .enabled = true, .keyframe_interval = 4 };

    try work.writeFile(io, .{ .sub_path = "marker.txt", .data = "good\n" });
    const good = try moment.capture(&store, work, .poll, mset);
    defer alloc.free(good.captured.branch);

    try work.writeFile(io, .{ .sub_path = "marker.txt", .data = "bad\n" });
    const bad = try moment.capture(&store, work, .poll, mset);
    defer alloc.free(bad.captured.branch);

    const scratch = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(scratch);

    // The live tree says "bad", but the earlier moment must still grade green.
    const g = try gradeMoment(&store, work, good.captured, set, .{
        .tier = .full,
        .scratch_parent = scratch,
    });
    defer g.deinit(alloc);
    try testing.expectEqual(verdict.Result.green, g.outcome.result());

    const b = try gradeMoment(&store, work, bad.captured, set, .{
        .tier = .full,
        .scratch_parent = scratch,
    });
    defer b.deinit(alloc);
    try testing.expectEqual(verdict.Result.red, b.outcome.result());

    // The check reads marker.txt, so an exact tracer must say so; a
    // conservative one lists it too. Either way it is in the read-set.
    if (g.read_set) |rs| try testing.expect(rs.contains("marker.txt"));

    // The developer's own worktree was never touched.
    const live = try work.readFileAlloc(io, "marker.txt", alloc, .unlimited);
    defer alloc.free(live);
    try testing.expectEqualStrings("bad\n", live);
}
