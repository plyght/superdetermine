const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const branches = @import("branches.zig");
const checks = @import("checks.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Branching at a moment.
///
/// The case this exists for is forking mid-run. An agent is forty minutes into a
/// task, and the approach it considered at minute twelve was better than the one
/// it kept. No commit exists there, nobody thought to mark it, and the agent is
/// still writing to the tree right now. `workAt` materializes that state as its
/// own workspace without touching the live tree and without inventing a branch
/// nobody asked for.
///
/// Forking is cheap by construction: the live worktree is copy-on-write cloned,
/// so every unchanged chunk is shared and every ignored build artifact comes
/// along warm, and only the tracked files that actually differ are written. A
/// fork of a neighbouring state touches a handful of paths.
///
/// A fork is a workspace, and workspaces get graded. Two attempts at the same
/// problem therefore acquire verdicts without anyone running anything: the
/// grader keys on tree content, so both forks land in the same verdict cache and
/// the comparison is already there when you go looking for it.
///
/// A branch is the *second* step, and an explicit one. `newBranchAt` turns a
/// moment into real history once you have decided the fork was worth keeping;
/// until then nothing enters `gr log`.
pub const Error = error{
    BranchExists,
};

// --- materializing a workspace at a moment ---

/// Materialize the state captured by `m` as a workspace at `dst_abs`, which must
/// not already exist (the clone creates it).
///
/// CRITICAL INVARIANT: the target content is read from the object store, never
/// from the live worktree. That is what makes this race-free by construction
/// rather than by timing. An agent may be writing into `work_dir` throughout
/// this call and the result is unaffected, because nothing the agent can write
/// is an input to the content that lands.
///
/// The copy-on-write clone of the live tree is a substrate, not a source of
/// truth. It exists so that unchanged files, and everything the project ignores
/// (`node_modules`, `zig-cache`, `target`), are present without being copied,
/// which keeps the fork's build cache warm. Every *tracked* path is then
/// reconciled from stored content, so any file the agent happened to change
/// between the clone and the reconcile is overwritten with the moment's version.
pub fn workAt(
    store: *Store,
    work_dir: std.Io.Dir,
    dst_abs: []const u8,
    m: moment.Moment,
) !void {
    const io = store.io;
    const alloc = store.alloc;

    // Reconstruct (and verify) the target content before anything is cloned, so
    // a corrupt moment fails without leaving a half-built workspace behind.
    const entries = try moment.entriesOf(store, m);
    defer workspace.freeTreeEntries(alloc, entries);

    const src_abs = try work_dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(src_abs);

    try branches.work(io, src_abs, dst_abs);

    var dst = try std.Io.Dir.openDirAbsolute(io, dst_abs, .{ .iterate = true });
    defer dst.close(io);

    try checks.reconcile(store, dst, entries);
}

// --- promoting a moment to a branch ---

/// Create branch `name` holding the state captured by `m`, and return the Oid of
/// the change it points at. Errors `BranchExists` rather than moving a branch
/// somebody else is standing on.
///
/// The change takes the *current* branch's tip as its parent when that branch
/// exists, and no parents at all when it does not. Parenting on the current tip
/// is the honest description of what happened: the fork was taken from this line
/// of work, and a parentless change would present a forty-minute run as if it
/// had appeared from nothing. An unborn current branch has no tip to point at,
/// and inventing one would be worse than a root change.
pub fn newBranchAt(
    store: *Store,
    name: []const u8,
    m: moment.Moment,
    author: []const u8,
    timestamp: i64,
) !Oid {
    const alloc = store.alloc;
    if (store.refExists(name)) return Error.BranchExists;

    const entries = try moment.entriesOf(store, m);
    defer workspace.freeTreeEntries(alloc, entries);

    const tree_oid = try store.writeTree(.{ .entries = entries });
    // `entriesOf` already proved the reconstruction hashes to `full_tree`, so a
    // mismatch here would mean the tree encoding disagreed with itself.
    std.debug.assert(tree_oid.eql(m.full_tree));

    var parents_buf: [1]Oid = undefined;
    var parents: []const Oid = parents_buf[0..0];
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (store.refExists(branch)) {
        parents_buf[0] = try store.readRef(branch);
        parents = parents_buf[0..1];
    }

    var seed: [Oid.len + 8]u8 = undefined;
    @memcpy(seed[0..Oid.len], &tree_oid.bytes);
    std.mem.writeInt(u64, seed[Oid.len..][0..8], @bitCast(timestamp), .big);
    var digest: [Oid.len]u8 = undefined;
    oid.Blake3.hash(&seed, &digest, .{});
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, digest[0..16]);

    var id_hex: [16]u8 = undefined;
    _ = m.shortId(&id_hex);
    const message = try std.fmt.allocPrint(alloc, "fork at moment {s}", .{&id_hex});
    defer alloc.free(message);

    const change_oid = try store.writeChange(.{
        .tree = tree_oid,
        .parents = parents,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = 0,
        .author = author,
        .message = message,
    });
    try store.updateRef(name, change_oid);
    return change_oid;
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

    fn dst(self: *Fixture, alloc: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fs.path.join(alloc, &.{ self.root_abs, name });
    }

    fn write(self: *Fixture, path: []const u8, body: []const u8) !moment.Moment {
        const io = std.testing.io;
        if (std.fs.path.dirnamePosix(path)) |dir| try self.work.createDirPath(io, dir);
        try self.work.writeFile(io, .{ .sub_path = path, .data = body });
        const r = try moment.capture(&self.store, self.work, .poll, .{
            .enabled = true,
            .keyframe_interval = 4,
        });
        return r.captured;
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

test "forking at an older moment gives that moment's content, not the live tree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const old = try f.write("a.txt", "minute twelve");
    defer alloc.free(old.branch);
    const new = try f.write("a.txt", "minute forty");
    defer alloc.free(new.branch);

    const dst_abs = try f.dst(alloc, "forked");
    defer alloc.free(dst_abs);
    try workAt(&f.store, f.work, dst_abs, old);

    const forked = try f.tmp.dir.readFileAlloc(io, "forked/a.txt", alloc, .unlimited);
    defer alloc.free(forked);
    try testing.expectEqualStrings("minute twelve", forked);

    // The live tree is untouched: the agent is still forty minutes in.
    const live = try f.work.readFileAlloc(io, "a.txt", alloc, .unlimited);
    defer alloc.free(live);
    try testing.expectEqualStrings("minute forty", live);
}

test "a fork removes files the moment did not have" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const early = try f.write("a.txt", "one");
    defer alloc.free(early.branch);
    const later = try f.write("added_later.txt", "two");
    defer alloc.free(later.branch);

    const dst_abs = try f.dst(alloc, "forked");
    defer alloc.free(dst_abs);
    try workAt(&f.store, f.work, dst_abs, early);

    var dst = try std.Io.Dir.openDirAbsolute(io, dst_abs, .{ .iterate = true });
    defer dst.close(io);
    try testing.expectError(error.FileNotFound, dst.access(io, "added_later.txt", .{}));
}

test "forking does not create a branch" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const m = try f.write("a.txt", "one");
    defer alloc.free(m.branch);

    const dst_abs = try f.dst(alloc, "forked");
    defer alloc.free(dst_abs);
    try workAt(&f.store, f.work, dst_abs, m);

    const names = try branches.list(&f.store, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    try testing.expectEqual(@as(usize, 0), names.len);
    try testing.expect(!f.store.refExists("main"));
}

test "a forked workspace reconstructs the moment byte for byte" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const first = try f.write("a.txt", "alpha");
    alloc.free(first.branch);
    const second = try f.write("sub/b.txt", "beta");
    alloc.free(second.branch);
    const third = try f.write("a.txt", "gamma");
    defer alloc.free(third.branch);

    const dst_abs = try f.dst(alloc, "forked");
    defer alloc.free(dst_abs);
    try workAt(&f.store, f.work, dst_abs, third);

    const want = try moment.entriesOf(&f.store, third);
    defer workspace.freeTreeEntries(alloc, want);
    const want_enc = try object.Tree.encode(.{ .entries = want }, alloc);
    defer alloc.free(want_enc);

    var dst = try std.Io.Dir.openDirAbsolute(io, dst_abs, .{ .iterate = true });
    defer dst.close(io);
    const got = try workspace.captureEntries(&f.store, dst);
    defer workspace.freeTreeEntries(alloc, got);
    const got_enc = try object.Tree.encode(.{ .entries = got }, alloc);
    defer alloc.free(got_enc);

    try testing.expectEqualSlices(u8, want_enc, got_enc);
}

test "newBranchAt creates a branch and refuses to clobber one" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const m = try f.write("a.txt", "keepable");
    defer alloc.free(m.branch);

    try testing.expect(!f.store.refExists("attempt-b"));
    const change_oid = try newBranchAt(&f.store, "attempt-b", m, "Nico <n@x>", 1_700_000_000);
    try testing.expect(f.store.refExists("attempt-b"));
    try testing.expect((try f.store.readRef("attempt-b")).eql(change_oid));

    const change = try f.store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    try testing.expect(change.tree.eql(m.full_tree));
    // The current branch is unborn here, so the fork is a root change.
    try testing.expectEqual(@as(usize, 0), change.parents.len);

    try testing.expectError(
        Error.BranchExists,
        newBranchAt(&f.store, "attempt-b", m, "Nico <n@x>", 1_700_000_001),
    );
}

test "a fork of a born branch parents on its tip" {
    const alloc = testing.allocator;
    var f = try fixture(alloc);
    defer f.deinit(alloc);

    const tip = try workspace.snapshot(&f.store, f.work, "Nico <n@x>", "init", 1_700_000_000);

    const m = try f.write("a.txt", "forked content");
    defer alloc.free(m.branch);

    const change_oid = try newBranchAt(&f.store, "attempt-b", m, "Nico <n@x>", 1_700_000_100);
    const change = try f.store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    try testing.expectEqual(@as(usize, 1), change.parents.len);
    try testing.expect(change.parents[0].eql(tip));
    // Promoting a moment never moves the branch it was taken from.
    try testing.expect((try f.store.readRef("main")).eql(tip));
}
