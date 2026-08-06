const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const checks = @import("checks.zig");
const oplog = @import("oplog.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Putting the working tree back.
///
/// Before touching anything, the current state is captured as a moment and the
/// rewind is written to the op log, so `gr undo` reverses it and the state you
/// left is still addressable afterwards. Nothing is destroyed, which is the
/// property that makes rewinding something people reach for rather than fear.
///
/// Under continuous grading this is a lookup rather than a search: `@green`
/// already resolves to a measured state, so the answer costs one hash lookup
/// and a tree materialisation.
pub const Change = struct {
    path: []const u8,
    kind: enum { restored, removed, added },

    pub fn label(self: Change) []const u8 {
        return @tagName(self.kind);
    }
};

pub const Preview = struct {
    changes: []const Change,

    pub fn deinit(self: Preview, alloc: std.mem.Allocator) void {
        for (self.changes) |c| alloc.free(c.path);
        alloc.free(self.changes);
    }
};

/// What a rewind to `target` would do to the current tree, without doing it.
pub fn preview(
    store: *Store,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
    target: []const object.TreeEntry,
    paths: ?[]const []const u8,
) !Preview {
    const current = try workspace.captureEntries(store, work_dir);
    defer workspace.freeTreeEntries(alloc, current);

    var out: std.ArrayList(Change) = .empty;
    errdefer {
        for (out.items) |c| alloc.free(c.path);
        out.deinit(alloc);
    }

    var have = std.StringHashMap(Oid).init(alloc);
    defer have.deinit();
    for (current) |e| try have.put(e.path, e.blob);

    var want = std.StringHashMap(Oid).init(alloc);
    defer want.deinit();
    for (target) |e| try want.put(e.path, e.blob);

    for (target) |e| {
        if (!selected(paths, e.path)) continue;
        if (have.get(e.path)) |cur| {
            if (cur.eql(e.blob)) continue;
            try out.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .restored });
        } else {
            try out.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .added });
        }
    }
    for (current) |e| {
        if (!selected(paths, e.path)) continue;
        if (want.contains(e.path)) continue;
        try out.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .kind = .removed });
    }

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(Change, slice, {}, lessThan);
    return .{ .changes = slice };
}

fn lessThan(_: void, a: Change, b: Change) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn selected(paths: ?[]const []const u8, path: []const u8) bool {
    const list = paths orelse return true;
    for (list) |p| {
        if (std.mem.eql(u8, p, path)) return true;
        // A directory argument selects everything beneath it.
        if (path.len > p.len and std.mem.startsWith(u8, path, p) and path[p.len] == '/') return true;
    }
    return false;
}

pub const Applied = struct {
    /// The tree the working copy held before the rewind, captured and stored so
    /// it stays reachable and `gr undo` can put it back.
    left: Oid,
    to: Oid,
    changed: usize,
};

/// Rewind the working tree to `target`.
///
/// `paths`, when given, restricts the rewind to those paths, which is the
/// surgical case: put this one file back without disturbing the rest.
pub fn apply(
    store: *Store,
    work_dir: std.Io.Dir,
    target: []const object.TreeEntry,
    mset: moment.Settings,
    paths: ?[]const []const u8,
) !Applied {
    const alloc = store.alloc;

    // Capture what we are about to leave, so it never stops being addressable.
    const cap = try moment.capture(store, work_dir, .rewind, mset);
    if (cap == .captured) alloc.free(cap.captured.branch);

    const current = try workspace.captureEntries(store, work_dir);
    defer workspace.freeTreeEntries(alloc, current);

    // Both trees are written as real objects so the op-log record is
    // self-sufficient: undoing a rewind must not depend on reconstructing a
    // delta chain that retention may later trim.
    const left = try store.writeTree(.{ .entries = current });

    const pv = try preview(store, alloc, work_dir, target, paths);
    defer pv.deinit(alloc);

    if (paths) |_| {
        try applyPartial(store, work_dir, target, paths.?);
    } else {
        try checks.reconcile(store, work_dir, target);
    }

    const to = try store.writeTree(.{ .entries = target });

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try oplog.record(store, .{
        .kind = .rewind,
        .branch = branch,
        .prev = left,
        .new = to,
        .timestamp = @intCast(@divTrunc(std.Io.Clock.now(.real, store.io).nanoseconds, std.time.ns_per_s)),
    });

    return .{ .left = left, .to = to, .changed = pv.changes.len };
}

fn applyPartial(
    store: *Store,
    work_dir: std.Io.Dir,
    target: []const object.TreeEntry,
    paths: []const []const u8,
) !void {
    const io = store.io;
    const alloc = store.alloc;

    var want = std.StringHashMap(Oid).init(alloc);
    defer want.deinit();
    for (target) |e| {
        if (!selected(paths, e.path)) continue;
        try want.put(e.path, e.blob);
        if (std.fs.path.dirnamePosix(e.path)) |dir| work_dir.createDirPath(io, dir) catch {};
        const data = try store.readFileContent(e.blob);
        defer alloc.free(data);
        try work_dir.writeFile(io, .{ .sub_path = e.path, .data = data });
    }

    const current = try workspace.captureEntries(store, work_dir);
    defer workspace.freeTreeEntries(alloc, current);
    for (current) |e| {
        if (!selected(paths, e.path)) continue;
        if (want.contains(e.path)) continue;
        work_dir.deleteFile(io, e.path) catch {};
    }
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

fn fixture(alloc: std.mem.Allocator) !Fixture {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    try tmp.dir.createDirPath(io, "repo");
    const work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    const store = try Store.init(io, alloc, work);
    return .{ .tmp = tmp, .store = store, .work = work };
}

const test_mset = moment.Settings{ .enabled = true, .keyframe_interval = 4 };

test "rewind restores the tree and leaves the state it left addressable" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "original" });
    const first = try moment.capture(&f.store, f.work, .poll, test_mset);
    alloc.free(first.captured.branch);

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "ruined by an agent" });
    try f.work.writeFile(io, .{ .sub_path = "junk.txt", .data = "also added" });

    const target = try moment.entriesOf(&f.store, first.captured);
    defer workspace.freeTreeEntries(alloc, target);

    const applied = try apply(&f.store, f.work, target, test_mset, null);
    try testing.expect(applied.changed >= 2);

    const back = try f.work.readFileAlloc(io, "a.txt", alloc, .unlimited);
    defer alloc.free(back);
    try testing.expectEqualStrings("original", back);
    try testing.expectError(error.FileNotFound, f.work.access(io, "junk.txt", .{}));

    // The ruined state was captured on the way out, so it is still reachable.
    const all = try moment.readAll(&f.store, alloc);
    defer moment.freeMoments(alloc, all);
    try testing.expect(all.len >= 2);

    const left = try f.store.readTree(applied.left);
    defer object.freeTree(alloc, left);
    var saw_junk = false;
    for (left.entries) |e| {
        if (std.mem.eql(u8, e.path, "junk.txt")) saw_junk = true;
    }
    try testing.expect(saw_junk);
}

test "gr undo reverses a rewind" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "original" });
    const first = try moment.capture(&f.store, f.work, .poll, test_mset);
    alloc.free(first.captured.branch);

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "later work" });

    const target = try moment.entriesOf(&f.store, first.captured);
    defer workspace.freeTreeEntries(alloc, target);
    _ = try apply(&f.store, f.work, target, test_mset, null);

    {
        const now = try f.work.readFileAlloc(io, "a.txt", alloc, .unlimited);
        defer alloc.free(now);
        try testing.expectEqualStrings("original", now);
    }

    try oplog.undo(&f.store, f.work);

    // Undo put the later work back: rewinding destroyed nothing.
    const restored = try f.work.readFileAlloc(io, "a.txt", alloc, .unlimited);
    defer alloc.free(restored);
    try testing.expectEqualStrings("later work", restored);
}

test "a dry run reports what would change and changes nothing" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const first = try moment.capture(&f.store, f.work, .poll, test_mset);
    alloc.free(first.captured.branch);

    try f.work.writeFile(io, .{ .sub_path = "a.txt", .data = "two" });

    const target = try moment.entriesOf(&f.store, first.captured);
    defer workspace.freeTreeEntries(alloc, target);

    const pv = try preview(&f.store, alloc, f.work, target, null);
    defer pv.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), pv.changes.len);
    try testing.expectEqualStrings("a.txt", pv.changes[0].path);

    const unchanged = try f.work.readFileAlloc(io, "a.txt", alloc, .unlimited);
    defer alloc.free(unchanged);
    try testing.expectEqualStrings("two", unchanged);
}

test "a path-scoped rewind touches only the paths named" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var f = try fixture(alloc);
    defer f.deinit();

    try f.work.writeFile(io, .{ .sub_path = "keep.txt", .data = "v1" });
    try f.work.writeFile(io, .{ .sub_path = "fix.txt", .data = "v1" });
    const first = try moment.capture(&f.store, f.work, .poll, test_mset);
    alloc.free(first.captured.branch);

    try f.work.writeFile(io, .{ .sub_path = "keep.txt", .data = "v2" });
    try f.work.writeFile(io, .{ .sub_path = "fix.txt", .data = "v2" });

    const target = try moment.entriesOf(&f.store, first.captured);
    defer workspace.freeTreeEntries(alloc, target);
    _ = try apply(&f.store, f.work, target, test_mset, &.{"fix.txt"});

    const fixed = try f.work.readFileAlloc(io, "fix.txt", alloc, .unlimited);
    defer alloc.free(fixed);
    try testing.expectEqualStrings("v1", fixed);

    // The path that was not named keeps the newer work.
    const kept = try f.work.readFileAlloc(io, "keep.txt", alloc, .unlimited);
    defer alloc.free(kept);
    try testing.expectEqualStrings("v2", kept);
}

test "a directory argument selects everything beneath it" {
    try testing.expect(selected(&.{"src"}, "src/a.zig"));
    try testing.expect(selected(&.{"src"}, "src/deep/b.zig"));
    try testing.expect(!selected(&.{"src"}, "srcfile.zig"));
    try testing.expect(!selected(&.{"src"}, "docs/a.md"));
    try testing.expect(selected(null, "anything"));
}
