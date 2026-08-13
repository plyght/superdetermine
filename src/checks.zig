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
/// If nothing is configured, sdt does nothing. There is no guessing a build
/// command from the presence of a `package.json`.
extern "c" fn fork() std.c.pid_t;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn chdir(path: [*:0]const u8) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Credentials the parent may be holding that a check has no business reading.
/// A check command comes from repo config, so it is not more trusted than the
/// repo; a token in the environment would otherwise be readable by any of them.
pub const scrubbed_env = [_][*:0]const u8{
    "SDT_GITHUB_TOKEN",
    "GITHUB_TOKEN",
    "GIT_TOKEN",
    "GH_TOKEN",
    "GITHUB_API_TOKEN",
};
extern "c" fn _exit(code: c_int) noreturn;

extern "c" fn setpgid(pid: std.c.pid_t, pgid: std.c.pid_t) c_int;

const PRIO_PROCESS: c_int = 0;

/// A check that has not finished in this long is not going to. Fifteen minutes
/// is long enough for a real suite and short enough that a hung check does not
/// hold the tick until someone notices.
pub const default_timeout_ms: i64 = 15 * std.time.ms_per_min;

/// How long the process group gets to exit on SIGTERM before SIGKILL.
pub const default_kill_grace_ms: i64 = 5 * std.time.ms_per_s;

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
    /// Globs naming files whose content decides what a check says, from
    /// `checks.inputs`. Empty is the historical behaviour exactly.
    inputs: []const []const u8 = &.{},
    /// How long a pass keeps answering, from `checks.fresh`. Zero is forever.
    fresh_ms: i64 = 0,
    /// Per-tier deadline for one run.
    timeout_fast_ms: i64 = default_timeout_ms,
    timeout_full_ms: i64 = default_timeout_ms,
    kill_grace_ms: i64 = default_kill_grace_ms,

    pub fn command(self: Settings, tier: verdict.Tier) []const u8 {
        return switch (tier) {
            .fast => self.fast,
            .full => self.full,
        };
    }

    pub fn has(self: Settings, tier: verdict.Tier) bool {
        return self.command(tier).len != 0;
    }

    pub fn timeoutMs(self: Settings, tier: verdict.Tier) i64 {
        return switch (tier) {
            .fast => self.timeout_fast_ms,
            .full => self.timeout_full_ms,
        };
    }

    pub fn deinit(self: Settings, alloc: std.mem.Allocator) void {
        if (self.fast.len != 0) alloc.free(self.fast);
        if (self.full.len != 0) alloc.free(self.full);
        for (self.inputs) |p| alloc.free(p);
        if (self.inputs.len != 0) alloc.free(self.inputs);
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
    out.inputs = commaList(store, alloc, "checks.inputs");
    out.fresh_ms = getDuration(store, alloc, "checks.fresh") orelse out.fresh_ms;

    const timeout = getDuration(store, alloc, "checks.timeout");
    out.timeout_fast_ms = getDuration(store, alloc, "checks.timeout.fast") orelse
        timeout orelse out.timeout_fast_ms;
    out.timeout_full_ms = getDuration(store, alloc, "checks.timeout.full") orelse
        timeout orelse out.timeout_full_ms;
    out.kill_grace_ms = getDuration(store, alloc, "checks.kill_grace") orelse out.kill_grace_ms;
    return out;
}

fn getDuration(store: *Store, alloc: std.mem.Allocator, key: []const u8) ?i64 {
    if (config.get(store, alloc, key)) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            return config.parseDurationMs(v);
        }
    } else |_| {}
    return null;
}

/// A comma-separated config value as an owned list, empty when unset. The same
/// shape `checks.test_paths` is read in, so one spelling covers both.
fn commaList(store: *Store, alloc: std.mem.Allocator, key: []const u8) []const []const u8 {
    const raw = blk: {
        if (config.get(store, alloc, key)) |maybe| {
            if (maybe) |v| break :blk v;
        } else |_| {}
        return &.{};
    };
    defer alloc.free(raw);

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const dup = alloc.dupe(u8, trimmed) catch continue;
        list.append(alloc, dup) catch {
            alloc.free(dup);
            continue;
        };
    }
    return list.toOwnedSlice(alloc) catch &.{};
}

// --- declared inputs ---

/// One declared input and what it held when the check ran.
///
/// `present` is load-bearing: a file that is missing now and present later must
/// change the digest, so an absence is recorded rather than skipped. Otherwise
/// creating a `.env` would leave the verdict from before it existed in place.
pub const InputEntry = struct {
    path: []const u8,
    digest: Oid,
    present: bool,
};

/// The itemized state of every declared input, in a fixed order.
///
/// Itemized rather than folded into one number, because "the environment
/// changed" is not an answer anyone can act on and "your lockfile changed" is.
pub const InputSet = struct {
    pub const tag: u8 = 'I';

    entries: []const InputEntry,

    pub fn deinit(self: InputSet, alloc: std.mem.Allocator) void {
        for (self.entries) |e| alloc.free(e.path);
        alloc.free(self.entries);
    }

    /// The key dimension. Zero for an empty set, which is what keeps a repo that
    /// declared nothing on byte-identical keys.
    pub fn digest(self: InputSet, alloc: std.mem.Allocator) !Oid {
        if (self.entries.len == 0) return Oid.zero();
        const enc = try encodeInputs(alloc, self);
        defer alloc.free(enc);
        return Oid.ofBytes(enc);
    }

    /// The first declared input that differs, which is the file to name when a
    /// lookup missed. Null when the two sets agree.
    pub fn firstDifference(self: InputSet, other: InputSet) ?[]const u8 {
        for (self.entries) |a| {
            const b = other.find(a.path) orelse return a.path;
            if (b.present != a.present or !b.digest.eql(a.digest)) return a.path;
        }
        for (other.entries) |b| {
            if (self.find(b.path) == null) return b.path;
        }
        return null;
    }

    fn find(self: InputSet, path: []const u8) ?InputEntry {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }
};

/// Hash every declared input, expanding globs against `work_abs`.
///
/// A pattern that starts with `/` is resolved as an absolute path and is meant
/// to be: the toolchain that decides whether a build passes usually lives
/// outside the repo, and refusing to look at it would leave the same hole this
/// closes. A pattern that matches nothing still contributes one `absent` entry,
/// under the pattern itself, so the file appearing later is a change.
pub fn collectInputs(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_abs: []const u8,
    patterns: []const []const u8,
) !InputSet {
    var entries: std.ArrayList(InputEntry) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e.path);
        entries.deinit(alloc);
    }
    if (patterns.len == 0) return .{ .entries = try entries.toOwnedSlice(alloc) };

    for (patterns) |pattern| {
        var matches: std.ArrayList([]const u8) = .empty;
        defer {
            for (matches.items) |m| alloc.free(m);
            matches.deinit(alloc);
        }
        try expand(io, alloc, work_abs, pattern, &matches);

        if (matches.items.len == 0) {
            try entries.append(alloc, .{
                .path = try alloc.dupe(u8, pattern),
                .digest = Oid.zero(),
                .present = false,
            });
            continue;
        }
        std.mem.sort([]const u8, matches.items, {}, lessThan);
        for (matches.items) |m| {
            const found = digestOf(io, alloc, work_abs, m);
            try entries.append(alloc, .{
                .path = try alloc.dupe(u8, m),
                .digest = found orelse Oid.zero(),
                .present = found != null,
            });
        }
    }
    return .{ .entries = try entries.toOwnedSlice(alloc) };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn hasGlob(s: []const u8) bool {
    return std.mem.indexOfAny(u8, s, "*?") != null;
}

/// Every path a pattern names. Only the last component may be a glob; anything
/// earlier is taken literally, which keeps this a lookup rather than a walk of
/// the filesystem.
fn expand(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_abs: []const u8,
    pattern: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
    const dir_part = if (slash) |i| pattern[0..i] else "";
    const base = if (slash) |i| pattern[i + 1 ..] else pattern;

    if (!hasGlob(base) or hasGlob(dir_part)) {
        try out.append(alloc, try alloc.dupe(u8, pattern));
        return;
    }

    const dir_abs = try resolve(alloc, work_abs, if (dir_part.len == 0) "." else dir_part);
    defer alloc.free(dir_abs);

    var dir = std.Io.Dir.openDirAbsolute(io, dir_abs, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (!globMatch(base, entry.name)) continue;
        const joined = if (dir_part.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_part, entry.name });
        errdefer alloc.free(joined);
        try out.append(alloc, joined);
    }
}

/// `*` matches any run of characters and `?` exactly one. No character classes
/// and no `**`: a declared input is a named file, not a search.
pub fn globMatch(pattern: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;

    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == name[n])) {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            star_n = n;
            p += 1;
        } else if (star) |s| {
            p = s + 1;
            star_n += 1;
            n = star_n;
        } else {
            return false;
        }
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn resolve(alloc: std.mem.Allocator, work_abs: []const u8, path: []const u8) ![]u8 {
    if (path.len != 0 and path[0] == '/') return alloc.dupe(u8, path);
    if (path.len > 1 and path[0] == '~' and path[1] == '/') {
        if (std.c.getenv("HOME")) |home| {
            return std.fmt.allocPrint(alloc, "{s}/{s}", .{ std.mem.span(home), path[2..] });
        }
    }
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ work_abs, path });
}

fn digestOf(io: std.Io, alloc: std.mem.Allocator, work_abs: []const u8, path: []const u8) ?Oid {
    const abs = resolve(alloc, work_abs, path) catch return null;
    defer alloc.free(abs);
    const data = std.Io.Dir.cwd().readFileAlloc(io, abs, alloc, .unlimited) catch return null;
    defer alloc.free(data);
    var hasher = oid.Hasher.init();
    hasher.update("sdt-input-v1");
    hasher.update(data);
    return hasher.finalOid();
}

pub fn encodeInputs(alloc: std.mem.Allocator, set: InputSet) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, InputSet.tag);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(set.entries.len), .big);
    try out.appendSlice(alloc, &count_buf);
    for (set.entries) |e| {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(e.path.len), .big);
        try out.appendSlice(alloc, &len_buf);
        try out.appendSlice(alloc, e.path);
        try out.append(alloc, if (e.present) 1 else 0);
        try out.appendSlice(alloc, &e.digest.bytes);
    }
    return out.toOwnedSlice(alloc);
}

pub fn decodeInputs(alloc: std.mem.Allocator, data: []const u8) !InputSet {
    if (data.len < 5 or data[0] != InputSet.tag) return error.InvalidInputSet;
    const n = std.mem.readInt(u32, data[1..5], .big);
    var pos: usize = 5;

    var list: std.ArrayList(InputEntry) = .empty;
    errdefer {
        for (list.items) |e| alloc.free(e.path);
        list.deinit(alloc);
    }

    for (0..n) |_| {
        if (pos + 2 > data.len) return error.InvalidInputSet;
        const len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        if (pos + len + 1 + Oid.len > data.len) return error.InvalidInputSet;
        const path = try alloc.dupe(u8, data[pos .. pos + len]);
        errdefer alloc.free(path);
        pos += len;
        const present = data[pos] != 0;
        pos += 1;
        var digest = Oid.zero();
        @memcpy(&digest.bytes, data[pos .. pos + Oid.len]);
        pos += Oid.len;
        try list.append(alloc, .{ .path = path, .digest = digest, .present = present });
    }
    return .{ .entries = try list.toOwnedSlice(alloc) };
}

/// Persist the itemization under its own digest, so the Oid in the verdict key
/// is also the address of the answer to "which file moved".
pub fn storeInputs(store: *Store, set: InputSet) !Oid {
    if (set.entries.len == 0) return Oid.zero();
    const enc = try encodeInputs(store.alloc, set);
    defer store.alloc.free(enc);
    return store.writeRaw(enc);
}

pub fn loadInputs(store: *Store, o: Oid) !InputSet {
    if (o.isZero()) return .{ .entries = &.{} };
    const raw = try store.readRaw(o);
    defer store.alloc.free(raw);
    return decodeInputs(store.alloc, raw);
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
    outcome: verdict.Outcome = .pass,

    pub fn result(self: RunOutcome) verdict.Result {
        return self.outcome.result();
    }

    pub fn cacheable(self: RunOutcome) bool {
        return self.outcome.cacheable();
    }
};

/// How to launch the check. `wrapper` is prepended to the argv, which is how a
/// read-set tracer inserts itself without this module knowing anything about
/// tracing. `env` entries are set in the child only.
pub const Launch = struct {
    wrapper: []const []const u8 = &.{},
    env: []const [2][]const u8 = &.{},
    nice: i8 = 10,
    /// Deadline for the run. Zero waits forever, which is what the tests that
    /// run `exit 0` want and what nothing in production should ask for.
    timeout_ms: i64 = 0,
    kill_grace_ms: i64 = default_kill_grace_ms,
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
        // Its own process group, so a deadline can reach everything the check
        // started and not just the shell that started it.
        _ = setpgid(0, 0);
        if (chdir(cwd_z.ptr) != 0) _exit(126);
        // Layer 4 is enforced, not advisory. A grade that competes with the
        // developer's own build is worse than no grade.
        _ = setpriority(PRIO_PROCESS, 0, launch.nice);
        for (scrubbed_env) |name| _ = unsetenv(name);
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

    // Both sides set the group, because only one of them is guaranteed to have
    // run yet. Whichever loses the race is a harmless no-op, and the deadline
    // below cannot signal a group that does not exist.
    _ = setpgid(pid, pid);

    var status: c_int = 0;
    var timed_out = false;
    if (launch.timeout_ms <= 0) {
        _ = std.c.waitpid(pid, &status, 0);
    } else if (!reap(io, pid, &status, launch.timeout_ms)) {
        timed_out = true;
        // Ask the whole group, then insist. A check that spawned a dev server
        // or a database is only over when its children are.
        _ = std.c.kill(-pid, .TERM);
        if (!reap(io, pid, &status, launch.kill_grace_ms)) {
            _ = std.c.kill(-pid, .KILL);
            _ = std.c.waitpid(pid, &status, 0);
        }
    }

    const end_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    const elapsed_ms: u32 = @intCast(@divTrunc(end_ns - start_ns, 1_000_000));

    return .{
        .exit_code = exitCode(status),
        .duration_ms = elapsed_ms,
        .outcome = classify(status, timed_out),
    };
}

/// Wait up to `budget_ms` for the child. True when it was reaped.
///
/// The clock is `.awake`, so a machine that slept for an hour mid-run does not
/// come back to a check that has "timed out" without ever having been given the
/// time. That is the same failure this whole taxonomy exists to stop caching.
fn reap(io: std.Io, pid: std.c.pid_t, status: *c_int, budget_ms: i64) bool {
    const start_ns = std.Io.Clock.now(.awake, io).nanoseconds;
    var nap_ms: i64 = 2;
    while (true) {
        const got = std.c.waitpid(pid, status, @intCast(std.c.W.NOHANG));
        if (got == pid) return true;
        if (got < 0) return true;
        const now_ns = std.Io.Clock.now(.awake, io).nanoseconds;
        if (@divTrunc(now_ns - start_ns, 1_000_000) >= budget_ms) return false;
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(nap_ms), .awake) catch {};
        if (nap_ms < 100) nap_ms *= 2;
    }
}

/// Decode a waitpid status into a plain exit code, mapping a signal death to a
/// non-zero code so a killed check reads as red rather than green.
pub fn exitCode(status: c_int) i32 {
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @intCast((s >> 8) & 0xff);
    return 128 + @as(i32, @intCast(s & 0x7f));
}

/// What the run was, as opposed to what it said.
///
/// A clean exit is the check's own answer, whatever the code. A signal is not:
/// the OOM killer, a `kill -9`, and a machine shutting down all land here, and
/// none of them is evidence about the tree.
pub fn classify(status: c_int, timed_out: bool) verdict.Outcome {
    if (timed_out) return .timeout;
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return if ((s >> 8) & 0xff == 0) .pass else .fail;
    return .cancelled;
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
    /// Why tracing landed where it did, for `sdt doctor`.
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
    const dst_abs = try std.fmt.allocPrint(alloc, "{s}/.sdt-grade-{s}-{s}", .{
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
    launch.timeout_ms = set.timeoutMs(opts.tier);
    launch.kill_grace_ms = set.kill_grace_ms;
    const outcome = try run(alloc, io, dst_abs, command, launch);

    var rs: ?readset.ReadSet = null;
    if (opts.trace and outcome.cacheable()) {
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

test "a check cannot read the parent's credentials" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    _ = setenv("GITHUB_TOKEN", "ghp_secret", 1);
    _ = setenv("SDT_GITHUB_TOKEN", "sdt_secret", 1);
    defer {
        _ = unsetenv("GITHUB_TOKEN");
        _ = unsetenv("SDT_GITHUB_TOKEN");
    }

    const seen = try run(alloc, io, abs, "test -z \"$GITHUB_TOKEN\" && test -z \"$SDT_GITHUB_TOKEN\"", .{});
    try testing.expectEqual(verdict.Result.green, seen.result());

    const passed = try run(alloc, io, abs, "test -n \"$PATH\"", .{});
    try testing.expectEqual(verdict.Result.green, passed.result());
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

    const r = try run(alloc, io, abs, "test \"$SDT_TEST_VAR\" = hello", .{
        .env = &.{.{ "SDT_TEST_VAR", "hello" }},
    });
    try testing.expectEqual(@as(i32, 0), r.exit_code);
}

test "a check that outruns its deadline is a timeout, and is not cacheable" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const r = try run(alloc, io, abs, "sleep 30", .{
        .timeout_ms = 150,
        .kill_grace_ms = 50,
    });
    try testing.expectEqual(verdict.Outcome.timeout, r.outcome);
    try testing.expect(!r.cacheable());
    try testing.expectEqual(verdict.Result.red, r.result());
    // It really was stopped, rather than waited out.
    try testing.expect(r.duration_ms < 5000);

    // A check that finishes inside its deadline is untouched by any of this.
    const ok = try run(alloc, io, abs, "exit 0", .{ .timeout_ms = 30_000 });
    try testing.expectEqual(verdict.Outcome.pass, ok.outcome);
    try testing.expect(ok.cacheable());
}

test "a killed check is not cached as a red" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    // Exactly what an OOM kill looks like from here.
    const r = try run(alloc, io, abs, "kill -9 $$", .{});
    try testing.expectEqual(verdict.Outcome.cancelled, r.outcome);
    try testing.expect(!r.cacheable());
    try testing.expect(r.exit_code != 0);

    // A check that chose its own non-zero exit is a real failure and is kept.
    const failed = try run(alloc, io, abs, "exit 3", .{});
    try testing.expectEqual(verdict.Outcome.fail, failed.outcome);
    try testing.expect(failed.cacheable());
}

test "the deadline reaches the whole process group, leaving no orphan" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    // A check that leaves a daemon behind: the classic dev server nobody
    // remembers to stop. Killing only the shell would leave it running.
    const r = try run(
        alloc,
        io,
        abs,
        "sleep 60 & echo $! > child.pid; sleep 60",
        .{ .timeout_ms = 300, .kill_grace_ms = 50 },
    );
    try testing.expectEqual(verdict.Outcome.timeout, r.outcome);

    const raw = try tmp.dir.readFileAlloc(io, "child.pid", alloc, .unlimited);
    defer alloc.free(raw);
    const child = try std.fmt.parseInt(std.c.pid_t, std.mem.trim(u8, raw, " \n\r\t"), 10);

    var gone = false;
    var waited: usize = 0;
    while (waited < 40) : (waited += 1) {
        if (std.c.kill(child, @enumFromInt(0)) != 0) {
            gone = true;
            break;
        }
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(50), .awake) catch {};
    }
    try testing.expect(gone);
}

test "classify separates the check's own answer from the machine's" {
    try testing.expectEqual(verdict.Outcome.pass, classify(0, false));
    try testing.expectEqual(verdict.Outcome.fail, classify(1 << 8, false));
    try testing.expectEqual(verdict.Outcome.fail, classify(3 << 8, false));
    // SIGKILL is not the check saying anything.
    try testing.expectEqual(verdict.Outcome.cancelled, classify(9, false));
    // A deadline outranks whatever signal ended it.
    try testing.expectEqual(verdict.Outcome.timeout, classify(9, true));

    try testing.expect(verdict.Outcome.pass.cacheable());
    try testing.expect(verdict.Outcome.fail.cacheable());
    try testing.expect(!verdict.Outcome.timeout.cacheable());
    try testing.expect(!verdict.Outcome.cancelled.cacheable());
    try testing.expect(!verdict.Outcome.@"error".cacheable());
}

test "globs match a name and nothing else" {
    try testing.expect(globMatch("*.lock", "bun.lock"));
    try testing.expect(globMatch("*.lock", ".lock"));
    try testing.expect(!globMatch("*.lock", "bun.lockb"));
    try testing.expect(globMatch("bun.?ock", "bun.lock"));
    try testing.expect(!globMatch("bun.?ock", "bun.loock"));
    try testing.expect(globMatch("*", "anything"));
    try testing.expect(globMatch("go.*", "go.sum"));
    try testing.expect(globMatch("a*b*c", "azzbzzc"));
    try testing.expect(!globMatch("a*b*c", "azzbzz"));
    try testing.expect(globMatch("exact", "exact"));
    try testing.expect(!globMatch("exact", "exacts"));
}

test "declared inputs are itemized, and a change names the file" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "bun.lock", .data = "v1" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".env", .data = "MODE=test" });

    const patterns = [_][]const u8{ "bun.lock", ".env", "missing.txt" };

    const before = try collectInputs(io, alloc, abs, &patterns);
    defer before.deinit(alloc);
    try testing.expectEqual(@as(usize, 3), before.entries.len);
    try testing.expect(before.entries[0].present);
    try testing.expect(before.entries[1].present);
    // A file that is not there is recorded as absent, not dropped, so its
    // arrival later is a change like any other.
    try testing.expect(!before.entries[2].present);
    try testing.expectEqualStrings("missing.txt", before.entries[2].path);

    const d0 = try before.digest(alloc);
    try testing.expect(!d0.isZero());

    try tmp.dir.writeFile(io, .{ .sub_path = "bun.lock", .data = "v2" });
    const after = try collectInputs(io, alloc, abs, &patterns);
    defer after.deinit(alloc);

    try testing.expect(!(try after.digest(alloc)).eql(d0));
    // The digest says something moved; the itemization says which file.
    try testing.expectEqualStrings("bun.lock", after.firstDifference(before).?);

    // Creating the missing file is also a change, and it is named too.
    try tmp.dir.writeFile(io, .{ .sub_path = "missing.txt", .data = "here now" });
    const appeared = try collectInputs(io, alloc, abs, &patterns);
    defer appeared.deinit(alloc);
    try testing.expectEqualStrings("missing.txt", appeared.firstDifference(after).?);

    // Nothing moved, nothing to name.
    const again = try collectInputs(io, alloc, abs, &patterns);
    defer again.deinit(alloc);
    try testing.expect(again.firstDifference(appeared) == null);
    try testing.expect((try again.digest(alloc)).eql(try appeared.digest(alloc)));
}

test "declaring nothing digests to zero, which is the key this store always had" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const none = try collectInputs(io, alloc, abs, &.{});
    defer none.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), none.entries.len);
    try testing.expect((try none.digest(alloc)).isZero());
}

test "an input outside the repo is followed on purpose" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);

    // The toolchain lives beside the repo, not in it, which is the whole point.
    try tmp.dir.createDirPath(io, "toolchain");
    try tmp.dir.writeFile(io, .{ .sub_path = "toolchain/version", .data = "0.16.0" });
    try tmp.dir.createDirPath(io, "repo");
    const work = try tmp.dir.realPathFileAlloc(io, "repo", alloc);
    defer alloc.free(work);

    const outside = try std.fmt.allocPrint(alloc, "{s}/toolchain/version", .{root});
    defer alloc.free(outside);
    const patterns = [_][]const u8{outside};

    const before = try collectInputs(io, alloc, work, &patterns);
    defer before.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), before.entries.len);
    try testing.expect(before.entries[0].present);

    try tmp.dir.writeFile(io, .{ .sub_path = "toolchain/version", .data = "0.17.0" });
    const after = try collectInputs(io, alloc, work, &patterns);
    defer after.deinit(alloc);
    try testing.expect(!(try after.digest(alloc)).eql(try before.digest(alloc)));
    try testing.expectEqualStrings(outside, after.firstDifference(before).?);
}

test "a glob expands to every file it names, in a stable order" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    try tmp.dir.createDirPath(io, "deps");
    try tmp.dir.writeFile(io, .{ .sub_path = "deps/b.lock", .data = "b" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deps/a.lock", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deps/notes.md", .data = "ignored" });

    const set = try collectInputs(io, alloc, abs, &.{"deps/*.lock"});
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), set.entries.len);
    try testing.expectEqualStrings("deps/a.lock", set.entries[0].path);
    try testing.expectEqualStrings("deps/b.lock", set.entries[1].path);

    // A glob matching nothing still contributes an absent entry, so the first
    // file to match it is a change.
    const empty = try collectInputs(io, alloc, abs, &.{"deps/*.toml"});
    defer empty.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), empty.entries.len);
    try testing.expect(!empty.entries[0].present);
    try testing.expectEqualStrings("deps/*.toml", empty.entries[0].path);
}

test "the input manifest roundtrips through the object store" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "Cargo.lock", .data = "deps" });
    const set = try collectInputs(io, alloc, abs, &.{ "Cargo.lock", "absent.txt" });
    defer set.deinit(alloc);

    const o = try storeInputs(&store, set);
    // The key is the address of the answer to "which file moved".
    try testing.expect(o.eql(try set.digest(alloc)));

    const back = try loadInputs(&store, o);
    defer back.deinit(alloc);
    try testing.expectEqual(set.entries.len, back.entries.len);
    for (set.entries, back.entries) |a, b| {
        try testing.expectEqualStrings(a.path, b.path);
        try testing.expectEqual(a.present, b.present);
        try testing.expect(a.digest.eql(b.digest));
    }

    // A zero digest loads as the empty set rather than failing, which is what
    // every verdict recorded before this existed carries.
    const none = try loadInputs(&store, Oid.zero());
    defer none.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), none.entries.len);

    try testing.expectError(error.InvalidInputSet, decodeInputs(alloc, "junk"));
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

test "a repo that configures nothing new gets the defaults it always had" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try config.set(&store, "checks.full", "zig build test");

    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), s.inputs.len);
        try testing.expectEqual(@as(i64, 0), s.fresh_ms);
        try testing.expectEqual(default_timeout_ms, s.timeoutMs(.full));
        try testing.expectEqual(default_timeout_ms, s.timeoutMs(.fast));
        try testing.expectEqual(default_kill_grace_ms, s.kill_grace_ms);
    }

    try config.set(&store, "checks.inputs", "bun.lock, .env , */go.sum");
    try config.set(&store, "checks.fresh", "30m");
    try config.set(&store, "checks.timeout", "20m");
    try config.set(&store, "checks.timeout.fast", "90s");
    try config.set(&store, "checks.kill_grace", "2s");
    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expectEqual(@as(usize, 3), s.inputs.len);
        try testing.expectEqualStrings("bun.lock", s.inputs[0]);
        try testing.expectEqualStrings(".env", s.inputs[1]);
        try testing.expectEqualStrings("*/go.sum", s.inputs[2]);
        try testing.expectEqual(@as(i64, 30 * std.time.ms_per_min), s.fresh_ms);
        // The bare key is the floor and the per-tier key overrides it.
        try testing.expectEqual(@as(i64, 20 * std.time.ms_per_min), s.timeoutMs(.full));
        try testing.expectEqual(@as(i64, 90 * std.time.ms_per_s), s.timeoutMs(.fast));
        try testing.expectEqual(@as(i64, 2 * std.time.ms_per_s), s.kill_grace_ms);
    }

    // A value that is not a duration keeps the default rather than reading zero,
    // which would silently mean "no deadline" or "always stale".
    try config.set(&store, "checks.timeout", "soon");
    try config.set(&store, "checks.timeout.fast", "soon");
    {
        const s = settings(&store, alloc);
        defer s.deinit(alloc);
        try testing.expectEqual(default_timeout_ms, s.timeoutMs(.fast));
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
