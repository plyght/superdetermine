const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const object = @import("object.zig");
const readset = @import("readset.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Layer 2 of the speed budget: learn what a check actually reads.
///
/// The first time a check runs, record every file the process actually opened.
/// That read-set is an exact, empirical dependency list needing no language
/// plugin, no build system and no per-framework adapter, and it works
/// identically for `zig build`, pytest, a Makefile or a shell script.
///
/// It is measured from the filesystem rather than from the process. Every
/// process-side option on macOS is either dead or dishonest: Endpoint Security
/// needs root and an Apple-approved entitlement; `sandbox-exec`'s trace mode
/// still parses but writes only to a root-only directory behind a private
/// entitlement; polling `proc_pidinfo` for open descriptors misses the
/// overwhelming majority of opens because files are open for about a
/// millisecond; and `DYLD_INSERT_LIBRARIES` is erased by SIP the moment the
/// build shells out through `/bin/sh`, poisoning the whole process subtree.
///
/// Access times work instead, and work better, because they observe the
/// filesystem and nothing else. APFS updates a file's access time on read
/// whenever that time is not already newer than its modification time, so
/// backdating every tracked file before the run ("arming") makes the first read
/// of each file visible. We are allowed to do this because the check runs in a
/// copy-on-write clone we created and will throw away; the developer's own tree
/// is never touched.
///
/// Where access times are not reported or not updated, this degrades to a
/// conservative over-approximation and says so in `gr doctor`, rather than
/// quietly pretending it measured something.
extern "c" fn utimensat(
    dirfd: c_int,
    path: [*:0]const u8,
    times: ?*const [2]std.c.timespec,
    flags: c_int,
) c_int;

/// The backdated access time every armed file is given. Zero, not a recent
/// date: the sentinel must be older than the oldest modification time in the
/// tree, or a vendored file with an ancient preserved mtime is silently missed.
const sentinel_ns: i128 = 0;

/// Leave the modification time alone while setting the access time. Changing
/// mtime would both corrupt the tree and defeat every build system's own
/// staleness check.
const utime_omit: isize = switch (builtin.os.tag) {
    .linux => (1 << 30) - 2,
    else => -2,
};

pub const Mode = enum {
    /// Every tracked file is assumed read. Always correct, never precise: it
    /// can only ever cause an unnecessary run, never a wrongly-skipped one.
    conservative,
    /// The exact set, measured from access times.
    atime,

    pub fn label(self: Mode) []const u8 {
        return @tagName(self);
    }

    pub fn isExact(self: Mode) bool {
        return self == .atime;
    }
};

pub const Availability = struct {
    mode: Mode,
    /// A one-line explanation for `gr doctor`. Never empty.
    reason: []const u8,
};

fn timespecOf(ns: i128) std.c.timespec {
    return .{
        .sec = @intCast(@divFloor(ns, std.time.ns_per_s)),
        .nsec = @intCast(@mod(ns, std.time.ns_per_s)),
    };
}

/// Backdate one path's access time, leaving its modification time untouched.
fn armPath(abs_path: [:0]const u8) bool {
    const times = [2]std.c.timespec{
        timespecOf(sentinel_ns),
        .{ .sec = 0, .nsec = @intCast(utime_omit) },
    };
    return utimensat(std.c.AT.FDCWD, abs_path.ptr, &times, std.c.AT.SYMLINK_NOFOLLOW) == 0;
}

/// Backdate every tracked path in `dir_abs`. Only tracked paths are armed:
/// ignored files are not part of the state being graded, so reads of them can
/// never change a verdict, and skipping them keeps arming off `node_modules`.
///
/// Returns how many paths were successfully armed. A path that fails to arm
/// keeps whatever access time it had, which reads as "was read" at harvest and
/// therefore fails safe.
pub fn arm(
    alloc: std.mem.Allocator,
    dir_abs: []const u8,
    entries: []const object.TreeEntry,
) !usize {
    var armed: usize = 0;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    for (entries) |e| {
        buf.clearRetainingCapacity();
        try buf.print(alloc, "{s}/{s}\x00", .{ dir_abs, e.path });
        const z: [:0]const u8 = @ptrCast(buf.items[0 .. buf.items.len - 1]);
        if (armPath(z)) armed += 1;
    }
    return armed;
}

/// Everything whose access time moved past the sentinel: the files the check
/// actually opened.
pub fn harvest(
    alloc: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    entries: []const object.TreeEntry,
) !readset.ReadSet {
    var hits: std.ArrayList([]const u8) = .empty;
    defer hits.deinit(alloc);

    for (entries) |e| {
        const st = dir.statFile(io, e.path, .{}) catch {
            // Unstattable means unknown, and unknown must over-approximate.
            try hits.append(alloc, e.path);
            continue;
        };
        const at = st.atime orelse {
            try hits.append(alloc, e.path);
            continue;
        };
        if (at.nanoseconds > sentinel_ns) try hits.append(alloc, e.path);
    }

    return readset.build(alloc, hits.items);
}

/// Can access times actually answer the question on this filesystem?
///
/// This probe is mandatory, not an optimisation. On a `noatime` mount arming
/// succeeds and access times never move, so harvesting would report an empty
/// read-set and every subsequent run would be wrongly skipped. That is the one
/// failure direction that produces a wrong verdict, so it is checked directly
/// by writing a file, backdating it, reading it, and seeing whether the
/// filesystem noticed.
pub fn detect(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, dir_abs: []const u8) Availability {
    const probe = ".gr-atime-probe";
    defer dir.deleteFile(io, probe) catch {};

    dir.writeFile(io, .{ .sub_path = probe, .data = "probe" }) catch {
        return .{ .mode = .conservative, .reason = "could not write a probe file into the clone" };
    };

    const abs = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir_abs, probe }, 0) catch {
        return .{ .mode = .conservative, .reason = "out of memory probing access times" };
    };
    defer alloc.free(abs);

    if (!armPath(abs)) {
        return .{ .mode = .conservative, .reason = "filesystem refused to set an access time" };
    }

    const data = dir.readFileAlloc(io, probe, alloc, .unlimited) catch {
        return .{ .mode = .conservative, .reason = "could not read the probe file back" };
    };
    alloc.free(data);

    const st = dir.statFile(io, probe, .{}) catch {
        return .{ .mode = .conservative, .reason = "could not stat the probe file" };
    };
    const at = st.atime orelse {
        return .{ .mode = .conservative, .reason = "this filesystem does not report access times" };
    };
    if (at.nanoseconds <= sentinel_ns) {
        return .{
            .mode = .conservative,
            .reason = "access times do not update on read (noatime mount?)",
        };
    }

    return .{ .mode = .atime, .reason = "access times track reads exactly" };
}

/// Conservative collection: every tracked path in the graded tree. This is the
/// honest fallback, and it is what makes the read-set optimisation safe to ship
/// on a platform where the exact path is unavailable: an over-approximation can
/// only cost an extra run, never a wrong answer.
pub fn conservativeSet(
    alloc: std.mem.Allocator,
    entries: []const object.TreeEntry,
) !readset.ReadSet {
    const paths = try alloc.alloc([]const u8, entries.len);
    defer alloc.free(paths);
    for (entries, 0..) |e, i| paths[i] = e.path;
    return readset.build(alloc, paths);
}

// --- tests ---

const testing = std.testing;

test "the conservative set covers every tracked path" {
    const alloc = testing.allocator;
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "src/a.zig", .blob = Oid.ofBytes("a") },
        .{ .mode = .regular, .path = "src/b.zig", .blob = Oid.ofBytes("b") },
    };
    const set = try conservativeSet(alloc, &entries);
    defer set.deinit(alloc);

    try testing.expect(set.contains("src/a.zig"));
    try testing.expect(set.contains("src/b.zig"));
    try testing.expect(!set.contains("src/c.zig"));
}

test "an empty tree yields an empty conservative set" {
    const alloc = testing.allocator;
    const set = try conservativeSet(alloc, &.{});
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), set.paths.len);
}

test "detect reports a usable mode with a reason either way" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const av = detect(io, alloc, tmp.dir, abs);
    // Whichever way it lands, the reason is always sayable in `gr doctor`.
    try testing.expect(av.reason.len != 0);
    // The probe file must never survive detection.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, ".gr-atime-probe", .{}));
}

test "arming backdates access times without disturbing modification times" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    try tmp.dir.writeFile(io, .{ .sub_path = "a.txt", .data = "hello" });
    const before = try tmp.dir.statFile(io, "a.txt", .{});

    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = Oid.ofBytes("hello") },
    };
    const armed = try arm(alloc, abs, &entries);
    if (armed == 0) return; // filesystem refuses; the conservative path covers it

    const after = try tmp.dir.statFile(io, "a.txt", .{});
    // The modification time is load-bearing for every build system's own
    // staleness check and must survive arming untouched.
    try testing.expectEqual(before.mtime.nanoseconds, after.mtime.nanoseconds);
    if (after.atime) |at| try testing.expect(at.nanoseconds <= sentinel_ns);
}

test "harvest reports exactly the files that were read" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);

    const av = detect(io, alloc, tmp.dir, abs);
    if (av.mode != .atime) return; // nothing to assert on a noatime filesystem

    try tmp.dir.writeFile(io, .{ .sub_path = "read_me.txt", .data = "a" });
    try tmp.dir.writeFile(io, .{ .sub_path = "ignore_me.txt", .data = "b" });
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "ignore_me.txt", .blob = Oid.ofBytes("b") },
        .{ .mode = .regular, .path = "read_me.txt", .blob = Oid.ofBytes("a") },
    };

    _ = try arm(alloc, abs, &entries);

    // Read exactly one of the two.
    const data = try tmp.dir.readFileAlloc(io, "read_me.txt", alloc, .unlimited);
    alloc.free(data);

    const set = try harvest(alloc, io, tmp.dir, &entries);
    defer set.deinit(alloc);

    try testing.expect(set.contains("read_me.txt"));
    try testing.expect(!set.contains("ignore_me.txt"));
}

test "an unarmable path fails safe by reading as touched" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // A path listed in the tree but absent from disk cannot be stat'd, and the
    // safe answer to "was it read" is yes.
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "missing.txt", .blob = Oid.ofBytes("x") },
    };
    const set = try harvest(alloc, io, tmp.dir, &entries);
    defer set.deinit(alloc);
    try testing.expect(set.contains("missing.txt"));
}
