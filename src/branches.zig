const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const object = @import("object.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

extern "c" fn clonefile(src: [*:0]const u8, dst: [*:0]const u8, flags: c_uint) c_int;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
extern "c" fn close(fd: c_int) c_int;
const FICLONE: c_ulong = 0x40049409;

pub const Error = error{
    BranchExists,
    CloneFailed,
};

/// List branch names under `.sdt/refs/heads`. Caller frees each name and the slice.
pub fn list(store: *Store, alloc: std.mem.Allocator) ![][]u8 {
    const io = store.io;
    var dir = try store.root.openDir(io, "refs/heads", .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| alloc.free(n);
        names.deinit(alloc);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    return names.toOwnedSlice(alloc);
}

/// Create a new branch at the current HEAD branch's tip. Does not switch.
pub fn create(store: *Store, name: []const u8) !void {
    if (store.refExists(name)) return Error.BranchExists;
    const branch = try store.headBranch();
    defer store.alloc.free(branch);
    const tip = try store.readRef(branch);
    try store.updateRef(name, tip);
}

/// Point HEAD at `name` and materialize its tree into `work_dir`.
/// MVP: assumes a clean working tree — we do not yet stash or merge dirty
/// state; the CLI layer will auto-snapshot before switching.
pub fn switchTo(store: *Store, work_dir: std.Io.Dir, name: []const u8) !void {
    const from_tree = headTree(store);
    try store.setHeadBranch(name);
    if (!store.refExists(name)) return; // unborn branch: nothing to materialize
    const change = try store.readChange(try store.readRef(name));
    defer object.freeChange(store.alloc, change);
    try workspace.checkout(store, work_dir, from_tree, change.tree);
}

/// The tree the current branch's tip holds, or null when HEAD is unborn or
/// unreadable. Nothing is deleted from the worktree in that case.
pub fn headTree(store: *Store) ?Oid {
    const branch = store.headBranch() catch return null;
    defer store.alloc.free(branch);
    if (!store.refExists(branch)) return null;
    const tip = store.readRef(branch) catch return null;
    const change = store.readChange(tip) catch return null;
    defer object.freeChange(store.alloc, change);
    return change.tree;
}

/// Instant copy-on-write worktree via macOS clonefile(2). `dst_dir_path` must
/// NOT already exist. Clones the entire src tree (including `.sdt`) for the MVP;
/// a later refinement can exclude/redirect the repo dir to share one repo.
pub fn work(io: std.Io, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    if (builtin.os.tag == .macos) {
        var src_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
        const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}", .{src_dir_path});
        const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}", .{dst_dir_path});
        if (clonefile(src_z.ptr, dst_z.ptr, 0) != 0) {
            return Error.CloneFailed;
        }
    } else {
        try workTree(io, src_dir_path, dst_dir_path);
    }
}

/// Recursively recreate the src tree at dst. On Linux each regular file is
/// reflinked (FICLONE) for copy-on-write; on failure and on all other OSes it
/// falls back to a plain byte copy.
fn workTree(io: std.Io, src_dir_path: []const u8, dst_dir_path: []const u8) !void {
    const alloc = std.heap.page_allocator;
    var src_dir = try std.Io.Dir.openDirAbsolute(io, src_dir_path, .{ .iterate = true });
    defer src_dir.close(io);

    try std.Io.Dir.cwd().createDirPath(io, dst_dir_path);
    var dst_dir = try std.Io.Dir.openDirAbsolute(io, dst_dir_path, .{});
    defer dst_dir.close(io);

    var walker = try src_dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => try dst_dir.createDirPath(io, entry.path),
            .file => {
                var reflinked = false;
                if (builtin.os.tag == .linux) {
                    reflinked = tryReflink(io, src_dir_path, dst_dir_path, entry) catch false;
                }
                if (!reflinked) {
                    _ = try src_dir.updateFile(io, entry.path, dst_dir, entry.path, .{});
                }
            },
            else => {},
        }
    }
}

/// Attempt a per-file reflink via the Linux FICLONE ioctl. Returns true on a
/// successful copy-on-write clone; any failure returns false so the caller can
/// fall back to a byte copy. Preserves the source's permission bits.
fn tryReflink(io: std.Io, src_dir_path: []const u8, dst_dir_path: []const u8, entry: std.Io.Dir.Walker.Entry) !bool {
    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dst_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_z = try std.fmt.bufPrintZ(&src_buf, "{s}/{s}", .{ src_dir_path, entry.path });
    const dst_z = try std.fmt.bufPrintZ(&dst_buf, "{s}/{s}", .{ dst_dir_path, entry.path });

    const st = entry.dir.statFile(io, entry.basename, .{}) catch return false;
    const mode: c_uint = @intCast(st.permissions.toMode() & 0o777);

    const O_RDONLY: c_int = 0o0;
    const O_WRONLY: c_int = 0o1;
    const O_CREAT: c_int = 0o100;
    const O_TRUNC: c_int = 0o1000;

    const src_fd = open(src_z.ptr, O_RDONLY);
    if (src_fd < 0) return false;
    defer _ = close(src_fd);
    const dst_fd = open(dst_z.ptr, O_WRONLY | O_CREAT | O_TRUNC, mode);
    if (dst_fd < 0) return false;
    defer _ = close(dst_fd);

    if (ioctl(dst_fd, FICLONE, src_fd) != 0) return false;
    return true;
}

// --- tests ---

const testing = std.testing;

test "branch create and list" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const main_oid = Oid.ofBytes("a change");
    try s.updateRef("main", main_oid);

    try create(&s, "feature");
    try testing.expect(s.refExists("feature"));
    try testing.expect((try s.readRef("feature")).eql(main_oid));

    try testing.expectError(Error.BranchExists, create(&s, "feature"));

    const names = try list(&s, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    var has_main = false;
    var has_feature = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "main")) has_main = true;
        if (std.mem.eql(u8, n, "feature")) has_feature = true;
    }
    try testing.expect(has_main);
    try testing.expect(has_feature);
}

test "switching away deletes tracked paths the target branch lacks" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "work");
    var wt = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer wt.close(io);

    var s = try Store.init(io, alloc, wt);
    defer s.deinit();

    try wt.writeFile(io, .{ .sub_path = "keep.txt", .data = "shared" });
    _ = try workspace.snapshot(&s, wt, "Nico <n@x>", "main", 1_700_000_000);

    try create(&s, "bench");
    try switchTo(&s, wt, "bench");
    try wt.createDirPath(io, "bench/adversarial");
    try wt.writeFile(io, .{ .sub_path = "bench/adversarial/one.txt", .data = "a" });
    try wt.writeFile(io, .{ .sub_path = "bench/adversarial/two.txt", .data = "b" });
    _ = try workspace.snapshot(&s, wt, "Nico <n@x>", "add bench", 1_700_000_001);

    try switchTo(&s, wt, "main");

    try testing.expectError(error.FileNotFound, wt.access(io, "bench/adversarial/one.txt", .{}));
    try testing.expectError(error.FileNotFound, wt.access(io, "bench/adversarial", .{}));
    try testing.expectError(error.FileNotFound, wt.access(io, "bench", .{}));
    try wt.access(io, "keep.txt", .{});

    const st = try workspace.status(&s, wt, alloc);
    defer {
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
    }
    try testing.expectEqual(@as(usize, 0), st.len);

    try switchTo(&s, wt, "bench");
    const back = try wt.readFileAlloc(io, "bench/adversarial/two.txt", alloc, .unlimited);
    defer alloc.free(back);
    try testing.expectEqualStrings("b", back);
}

test "switching never removes an untracked file" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "work");
    var wt = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer wt.close(io);

    var s = try Store.init(io, alloc, wt);
    defer s.deinit();

    try wt.writeFile(io, .{ .sub_path = "tracked.txt", .data = "v1" });
    _ = try workspace.snapshot(&s, wt, "Nico <n@x>", "main", 1_700_000_000);

    try create(&s, "side");
    try switchTo(&s, wt, "side");
    try wt.writeFile(io, .{ .sub_path = "side-only.txt", .data = "only on side" });
    _ = try workspace.snapshot(&s, wt, "Nico <n@x>", "side work", 1_700_000_001);

    try wt.createDirPath(io, "scratch");
    try wt.writeFile(io, .{ .sub_path = "scratch/notes.txt", .data = "mine" });
    try wt.writeFile(io, .{ .sub_path = ".sdtignore", .data = "scratch/\n" });
    try wt.writeFile(io, .{ .sub_path = "untracked.txt", .data = "never saved" });

    try switchTo(&s, wt, "main");

    try testing.expectError(error.FileNotFound, wt.access(io, "side-only.txt", .{}));
    const notes = try wt.readFileAlloc(io, "scratch/notes.txt", alloc, .unlimited);
    defer alloc.free(notes);
    try testing.expectEqualStrings("mine", notes);
    const loose = try wt.readFileAlloc(io, "untracked.txt", alloc, .unlimited);
    defer alloc.free(loose);
    try testing.expectEqualStrings("never saved", loose);
}

test "cow worktree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    try tmp.dir.writeFile(io, .{ .sub_path = "src/hello.txt", .data = "cow world" });

    const src_abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(src_abs);
    const parent_abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(parent_abs);

    const dst_abs = try std.fs.path.join(alloc, &.{ parent_abs, "dst" });
    defer alloc.free(dst_abs);

    try work(io, src_abs, dst_abs);

    const got = try tmp.dir.readFileAlloc(io, "dst/hello.txt", alloc, .unlimited);
    defer alloc.free(got);
    try testing.expectEqualStrings("cow world", got);
}
