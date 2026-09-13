const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const checks = @import("checks.zig");
const branches = @import("branches.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;
const Moment = moment.Moment;

pub const Clone = struct {
    abs: []u8,

    pub fn discard(self: Clone, io: std.Io, alloc: std.mem.Allocator) void {
        std.Io.Dir.cwd().deleteTree(io, self.abs) catch {};
        alloc.free(self.abs);
    }
};

pub fn prepare(
    store: *Store,
    work_dir: std.Io.Dir,
    entries: []const object.TreeEntry,
    label: []const u8,
    scratch_parent: ?[]const u8,
) !Clone {
    const io = store.io;
    const alloc = store.alloc;

    const src_abs = try work_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(src_abs);

    const parent = scratch_parent orelse std.fs.path.dirname(src_abs) orelse "/tmp";
    const dst_abs = try std.fmt.allocPrint(alloc, "{s}/.sdt-probe-{s}", .{ parent, label });
    errdefer alloc.free(dst_abs);

    std.Io.Dir.cwd().deleteTree(io, dst_abs) catch {};
    branches.work(io, src_abs, dst_abs) catch return checks.Error.CloneFailed;
    errdefer std.Io.Dir.cwd().deleteTree(io, dst_abs) catch {};

    var dst = try std.Io.Dir.openDirAbsolute(io, dst_abs, .{ .iterate = true });
    defer dst.close(io);
    try checks.reconcile(store, dst, entries);

    return .{ .abs = dst_abs };
}

pub fn prepareMoment(
    store: *Store,
    work_dir: std.Io.Dir,
    m: Moment,
    scratch_parent: ?[]const u8,
) !Clone {
    const entries = try moment.entriesOf(store, m);
    defer workspace.freeTreeEntries(store.alloc, entries);
    var id_hex: [16]u8 = undefined;
    _ = m.shortId(&id_hex);
    return prepare(store, work_dir, entries, id_hex[0..12], scratch_parent);
}

pub fn execute(
    alloc: std.mem.Allocator,
    io: std.Io,
    clone: Clone,
    command: []const u8,
    launch: checks.Launch,
) !checks.RunOutcome {
    return checks.run(alloc, io, clone.abs, command, launch);
}

pub const Run = struct {
    index: usize,
    exit_code: i32,
    duration_ms: u32,
    outcome: verdict.Outcome,
    cached: bool,

    pub fn passes(self: Run) bool {
        return self.exit_code == 0;
    }
};

pub const Cache = struct {
    index: *const verdict.Index,
    tier: verdict.Tier,
    command: Oid,
};

pub const Flip = struct {
    before: usize,
    after: usize,
};

pub const Runner = struct {
    store: *Store,
    work_dir: std.Io.Dir,
    moments: []const Moment,
    command: []const u8,
    launch: checks.Launch = .{},
    scratch_parent: ?[]const u8 = null,
    cache: ?Cache = null,
    jobs: usize = 1,
    runs: std.ArrayList(Run) = .empty,

    pub fn deinit(self: *Runner) void {
        self.runs.deinit(self.store.alloc);
    }

    pub fn known(self: *const Runner, index: usize) ?Run {
        for (self.runs.items) |r| {
            if (r.index == index) return r;
        }
        return null;
    }

    fn fromCache(self: *const Runner, index: usize) ?Run {
        const cache = self.cache orelse return null;
        const v = cache.index.get(.{
            .tree = self.moments[index].full_tree,
            .tier = cache.tier,
            .command = cache.command,
        }) orelse return null;
        return .{
            .index = index,
            .exit_code = v.exit_code,
            .duration_ms = v.duration_ms,
            .outcome = v.outcome,
            .cached = true,
        };
    }

    pub fn probe(self: *Runner, indices: []const usize) !void {
        const alloc = self.store.alloc;
        const io = self.store.io;

        var pending: std.ArrayList(usize) = .empty;
        defer pending.deinit(alloc);
        for (indices) |i| {
            if (self.known(i) != null) continue;
            var dup = false;
            for (pending.items) |p| {
                if (p == i) dup = true;
            }
            if (dup) continue;
            if (self.fromCache(i)) |r| {
                try self.runs.append(alloc, r);
                continue;
            }
            try pending.append(alloc, i);
        }
        if (pending.items.len == 0) return;

        var clones: std.ArrayList(Clone) = .empty;
        defer {
            for (clones.items) |c| c.discard(io, alloc);
            clones.deinit(alloc);
        }
        for (pending.items) |i| {
            try clones.append(alloc, try prepareMoment(self.store, self.work_dir, self.moments[i], self.scratch_parent));
        }

        const outcomes = try alloc.alloc(checks.RunOutcome, pending.items.len);
        defer alloc.free(outcomes);
        const failures = try alloc.alloc(?anyerror, pending.items.len);
        defer alloc.free(failures);
        @memset(failures, null);

        const width = @max(self.jobs, 1);
        var start: usize = 0;
        while (start < pending.items.len) {
            const end = @min(start + width, pending.items.len);
            if (end - start == 1) {
                worker(alloc, io, clones.items[start], self.command, self.launch, &outcomes[start], &failures[start]);
            } else {
                var threads: [64]?std.Thread = undefined;
                for (start..end) |j| {
                    threads[j - start] = std.Thread.spawn(.{}, worker, .{
                        alloc,       io,           clones.items[j], self.command,
                        self.launch, &outcomes[j], &failures[j],
                    }) catch null;
                    if (threads[j - start] == null) {
                        worker(alloc, io, clones.items[j], self.command, self.launch, &outcomes[j], &failures[j]);
                    }
                }
                for (start..end) |j| {
                    if (threads[j - start]) |t| t.join();
                }
            }
            start = end;
        }

        for (pending.items, 0..) |i, j| {
            if (failures[j]) |e| return e;
            try self.runs.append(alloc, .{
                .index = i,
                .exit_code = outcomes[j].exit_code,
                .duration_ms = outcomes[j].duration_ms,
                .outcome = outcomes[j].outcome,
                .cached = false,
            });
        }
    }

    pub fn bisect(self: *Runner, lo: usize, hi: usize) !?Flip {
        std.debug.assert(lo < hi);
        std.debug.assert(hi < self.moments.len);

        try self.probe(&.{ lo, hi });
        const lo_pass = self.known(lo).?.passes();
        if (lo_pass == self.known(hi).?.passes()) return null;

        var a = lo;
        var b = hi;
        var buf: [64]usize = undefined;
        while (b - a > 1) {
            const mids = midpoints(a, b, @min(@max(self.jobs, 1), buf.len), &buf);
            try self.probe(mids);
            for (mids) |m| {
                if (self.known(m).?.passes() != lo_pass) {
                    b = m;
                    break;
                }
                a = m;
            }
        }
        return .{ .before = a, .after = b };
    }

    pub fn sorted(self: *Runner) []Run {
        std.mem.sort(Run, self.runs.items, {}, runLessThan);
        return self.runs.items;
    }
};

fn runLessThan(_: void, a: Run, b: Run) bool {
    return a.index < b.index;
}

fn worker(
    alloc: std.mem.Allocator,
    io: std.Io,
    clone: Clone,
    command: []const u8,
    launch: checks.Launch,
    out: *checks.RunOutcome,
    failure: *?anyerror,
) void {
    out.* = execute(alloc, io, clone, command, launch) catch |e| {
        failure.* = e;
        return;
    };
}

pub fn midpoints(lo: usize, hi: usize, k: usize, out: []usize) []usize {
    if (hi <= lo + 1 or k == 0) return out[0..0];
    const gap = hi - lo;
    const n = @min(@min(k, gap - 1), out.len);
    var count: usize = 0;
    for (1..n + 1) |i| {
        const idx = lo + gap * i / (n + 1);
        if (idx <= lo or idx >= hi) continue;
        if (count != 0 and out[count - 1] == idx) continue;
        out[count] = idx;
        count += 1;
    }
    return out[0..count];
}

pub fn parallelism(power_ok: bool, budget_percent: u8) usize {
    if (!power_ok) return 1;
    const cores = std.Thread.getCpuCount() catch 1;
    const share = cores * @as(usize, budget_percent) / 100;
    return @max(1, @min(share, 64));
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    store: Store,
    work: std.Io.Dir,
    root_abs: [:0]u8,

    fn deinit(self: *Fixture, alloc: std.mem.Allocator) void {
        alloc.free(self.root_abs);
        self.work.close(std.testing.io);
        self.store.deinit();
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, path: []const u8, body: []const u8) !void {
        const io = std.testing.io;
        try self.work.writeFile(io, .{ .sub_path = path, .data = body });
        const r = try moment.capture(&self.store, self.work, .poll, .{
            .enabled = true,
            .keyframe_interval = 4,
        });
        std.testing.allocator.free(r.captured.branch);
    }
};

fn fixture(alloc: std.mem.Allocator) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.createDirPath(io, "repo");
    const work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    const store = try Store.init(io, alloc, work);
    const root_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    return .{ .tmp = tmp, .store = store, .work = work, .root_abs = root_abs };
}

fn leftovers(io: std.Io, dir: std.Io.Dir) !usize {
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (std.mem.startsWith(u8, e.name, ".sdt-probe-")) n += 1;
    }
    return n;
}

test "midpoints are evenly spaced, strictly inside, and never repeat" {
    var buf: [8]usize = undefined;
    try testing.expectEqualSlices(usize, &.{ 2, 5, 7 }, midpoints(0, 10, 3, &buf));
    try testing.expectEqualSlices(usize, &.{5}, midpoints(0, 10, 1, &buf));
    try testing.expectEqualSlices(usize, &.{1}, midpoints(0, 2, 4, &buf));
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3 }, midpoints(0, 4, 8, &buf));
    try testing.expectEqual(@as(usize, 0), midpoints(0, 1, 4, &buf).len);
    try testing.expectEqual(@as(usize, 0), midpoints(3, 3, 4, &buf).len);
}

test "a probe runs against the moment's content and leaves the live tree alone" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    try f.write("n.txt", "1");
    try f.write("n.txt", "2");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expectEqual(@as(usize, 2), all.len);

    const clone = try prepareMoment(&f.store, f.work, all[0], f.root_abs);
    const outcome = try execute(alloc, io, clone, "test \"$(cat n.txt)\" = 1", .{});
    try testing.expectEqual(@as(i32, 0), outcome.exit_code);
    clone.discard(io, alloc);

    const live = try f.work.readFileAlloc(io, "n.txt", alloc, .unlimited);
    defer alloc.free(live);
    try testing.expectEqualStrings("2", live);
    try testing.expectEqual(@as(usize, 0), try leftovers(io, f.tmp.dir));
}

test "bisect finds where the exit status flips, serially and in parallel" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    for ([_][]const u8{ "1", "2", "3", "4", "5", "6" }) |n| try f.write("n.txt", n);

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expectEqual(@as(usize, 6), all.len);

    for ([_]usize{ 1, 3 }) |jobs| {
        var runner = Runner{
            .store = &f.store,
            .work_dir = f.work,
            .moments = all,
            .command = "test \"$(cat n.txt)\" -lt 4",
            .scratch_parent = f.root_abs,
            .jobs = jobs,
        };
        defer runner.deinit();

        const flip = (try runner.bisect(0, 5)) orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(usize, 2), flip.before);
        try testing.expectEqual(@as(usize, 3), flip.after);
        try testing.expect(runner.known(2).?.passes());
        try testing.expect(!runner.known(3).?.passes());
        for (runner.sorted()) |r| try testing.expect(!r.cached);
    }
    try testing.expectEqual(@as(usize, 0), try leftovers(io, f.tmp.dir));

    var same = Runner{
        .store = &f.store,
        .work_dir = f.work,
        .moments = all,
        .command = "true",
        .scratch_parent = f.root_abs,
    };
    defer same.deinit();
    try testing.expect((try same.bisect(0, 5)) == null);
}

test "a recorded verdict for the configured check answers without a run" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    try f.write("n.txt", "1");
    try f.write("n.txt", "2");

    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);

    const command = "true";
    try verdict.record(&f.store, .{
        .tree = all[1].full_tree,
        .tier = .full,
        .command = verdict.commandHash(command),
        .result = .red,
        .exit_code = 7,
        .duration_ms = 5,
        .ms = all[1].ms,
        .readset = Oid.zero(),
        .outcome = .fail,
    });
    var ix = try verdict.Index.load(&f.store, alloc);
    defer ix.deinit();

    var runner = Runner{
        .store = &f.store,
        .work_dir = f.work,
        .moments = all,
        .command = command,
        .scratch_parent = f.root_abs,
        .cache = .{ .index = &ix, .tier = .full, .command = verdict.commandHash(command) },
    };
    defer runner.deinit();

    const flip = (try runner.bisect(0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), flip.before);
    try testing.expectEqual(@as(usize, 1), flip.after);
    try testing.expect(!runner.known(0).?.cached);
    try testing.expect(runner.known(1).?.cached);
    try testing.expectEqual(@as(i32, 7), runner.known(1).?.exit_code);
}
