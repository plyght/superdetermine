const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const branches = @import("branches.zig");
const history = @import("history.zig");
const merge_mod = @import("merge.zig");
const oplog = @import("oplog.zig");
const sync = @import("sync.zig");
const workspace = @import("workspace.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const Error = error{
    InvalidPath,
    AlreadyRegistered,
    WorktreeNotFound,
    WorktreeMissing,
    WorktreeRemoved,
    WorktreeDirty,
    NothingToMerge,
    RestoreTargetExists,
    CannotRemoveOrigin,
    CorruptRegistry,
};

pub const State = enum { active, removed };

pub const Entry = struct {
    id: []u8,
    state: State,
    branch: []u8,
    baseline: Oid,
    original_path: []u8,
    path: []u8,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.branch);
        alloc.free(self.original_path);
        alloc.free(self.path);
    }
};

pub const Inspection = struct {
    entry: Entry,
    branch: ?[]u8,
    tip: ?Oid,
    changes: []workspace.StatusEntry,

    pub fn deinit(self: Inspection, alloc: std.mem.Allocator) void {
        self.entry.deinit(alloc);
        if (self.branch) |branch| alloc.free(branch);
        for (self.changes) |change| alloc.free(change.path);
        alloc.free(self.changes);
    }

    pub fn dirty(self: Inspection) bool {
        return self.changes.len != 0;
    }
};

pub const MergeResult = struct {
    prev: Oid,
    new: Oid,
    fast_forward: bool,
    imported: usize,
    conflicts: [][]u8,

    pub fn clean(self: MergeResult) bool {
        return self.conflicts.len == 0;
    }

    pub fn deinit(self: MergeResult, alloc: std.mem.Allocator) void {
        for (self.conflicts) |path| alloc.free(path);
        alloc.free(self.conflicts);
    }
};

const registry_dir = "worktrees";

fn validPath(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and std.mem.indexOfAny(u8, path, "\n\r\x00") == null;
}

fn idFor(path: []const u8, out: *[32]u8) []const u8 {
    var digest: [16]u8 = undefined;
    std.crypto.hash.Blake3.hash(path, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(out, &hex);
    return out;
}

fn recordPath(id: []const u8, out: []u8) ![]const u8 {
    return std.fmt.bufPrint(out, registry_dir ++ "/{s}", .{id});
}

fn writeEntry(store: *Store, entry: Entry) !void {
    try store.root.createDirPath(store.io, registry_dir);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(store.alloc);
    try body.print(store.alloc, "{s}\n{s}\n", .{ @tagName(entry.state), entry.branch });
    var hex: [Oid.len * 2]u8 = undefined;
    _ = entry.baseline.toHex(&hex);
    try body.print(store.alloc, "{s}\n{s}\n{s}\n", .{ hex, entry.original_path, entry.path });
    var path_buf: [96]u8 = undefined;
    try store.writeFileAtomic(try recordPath(entry.id, &path_buf), body.items);
}

fn parseEntry(alloc: std.mem.Allocator, id: []const u8, data: []const u8) !Entry {
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    const state_text = lines.next() orelse return Error.CorruptRegistry;
    const branch = lines.next() orelse return Error.CorruptRegistry;
    const baseline = lines.next() orelse return Error.CorruptRegistry;
    const original_path = lines.next() orelse return Error.CorruptRegistry;
    const path = lines.next() orelse return Error.CorruptRegistry;
    if (lines.next() != null) return Error.CorruptRegistry;
    if (!validPath(original_path) or !validPath(path)) return Error.CorruptRegistry;
    const owned_id = try alloc.dupe(u8, id);
    errdefer alloc.free(owned_id);
    const owned_branch = try alloc.dupe(u8, branch);
    errdefer alloc.free(owned_branch);
    const owned_original = try alloc.dupe(u8, original_path);
    errdefer alloc.free(owned_original);
    const owned_path = try alloc.dupe(u8, path);
    errdefer alloc.free(owned_path);
    return .{
        .id = owned_id,
        .state = std.meta.stringToEnum(State, state_text) orelse return Error.CorruptRegistry,
        .branch = owned_branch,
        .baseline = Oid.fromHex(baseline) catch return Error.CorruptRegistry,
        .original_path = owned_original,
        .path = owned_path,
    };
}

pub fn register(store: *Store, path: []const u8) !Entry {
    if (!validPath(path)) return Error.InvalidPath;
    var id_buf: [32]u8 = undefined;
    const id = idFor(path, &id_buf);
    var path_buf: [96]u8 = undefined;
    if (store.root.access(store.io, try recordPath(id, &path_buf), .{})) |_| return Error.AlreadyRegistered else |_| {}
    const branch = try store.headBranch();
    defer store.alloc.free(branch);
    const baseline = try history.tipOf(store, branch);
    const entry: Entry = .{
        .id = try store.alloc.dupe(u8, id),
        .state = .active,
        .branch = try store.alloc.dupe(u8, branch),
        .baseline = baseline,
        .original_path = try store.alloc.dupe(u8, path),
        .path = try store.alloc.dupe(u8, path),
    };
    errdefer entry.deinit(store.alloc);
    try writeEntry(store, entry);
    return entry;
}

pub fn create(store: *Store, origin_abs: []const u8, destination_abs: []const u8) !Entry {
    if (!validPath(origin_abs) or !validPath(destination_abs)) return Error.InvalidPath;
    if (std.mem.eql(u8, origin_abs, destination_abs)) return Error.CannotRemoveOrigin;
    try branches.work(store.io, origin_abs, destination_abs);
    errdefer std.Io.Dir.cwd().deleteTree(store.io, destination_abs) catch {};
    return register(store, destination_abs);
}

pub fn get(store: *Store, alloc: std.mem.Allocator, id: []const u8) !Entry {
    var path_buf: [96]u8 = undefined;
    const data = store.root.readFileAlloc(store.io, try recordPath(id, &path_buf), alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return Error.WorktreeNotFound,
        else => return err,
    };
    defer alloc.free(data);
    return parseEntry(alloc, id, data);
}

pub fn list(store: *Store, alloc: std.mem.Allocator, include_removed: bool) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |entry| entry.deinit(alloc);
        out.deinit(alloc);
    }
    var dir = store.root.openDir(store.io, registry_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return out.toOwnedSlice(alloc),
        else => return err,
    };
    defer dir.close(store.io);
    var iterator = dir.iterate();
    while (try iterator.next(store.io)) |item| {
        if (item.kind != .file) continue;
        const entry = try get(store, alloc, item.name);
        if (!include_removed and entry.state == .removed) {
            entry.deinit(alloc);
            continue;
        }
        try out.append(alloc, entry);
    }
    std.sort.pdq(Entry, out.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.original_path, b.original_path);
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

fn openWorktree(store: *Store, path: []const u8) !struct { dir: std.Io.Dir, store: Store } {
    var dir = std.Io.Dir.openDirAbsolute(store.io, path, .{ .iterate = true }) catch return Error.WorktreeMissing;
    errdefer dir.close(store.io);
    const child = Store.open(store.io, store.alloc, dir) catch return Error.WorktreeMissing;
    return .{ .dir = dir, .store = child };
}

pub fn inspect(store: *Store, alloc: std.mem.Allocator, id: []const u8) !Inspection {
    const entry = try get(store, alloc, id);
    errdefer entry.deinit(alloc);
    if (entry.state == .removed) {
        return .{ .entry = entry, .branch = null, .tip = null, .changes = try alloc.alloc(workspace.StatusEntry, 0) };
    }
    var child = try openWorktree(store, entry.path);
    defer child.dir.close(store.io);
    defer child.store.deinit();
    const branch = try child.store.headBranch();
    errdefer alloc.free(branch);
    const tip = child.store.readRef(branch) catch null;
    const changes = try workspace.status(&child.store, child.dir, alloc);
    return .{ .entry = entry, .branch = branch, .tip = tip, .changes = changes };
}

fn importObjects(destination: *Store, source: *Store, alloc: std.mem.Allocator) !usize {
    const ids = try sync.objectIds(source, alloc);
    defer alloc.free(ids);
    var imported: usize = 0;
    for (ids) |id| {
        if (destination.has(id)) continue;
        const raw = try source.readRaw(id);
        defer alloc.free(raw);
        const written = try destination.writeRaw(raw);
        if (!written.eql(id)) return error.CorruptObject;
        imported += 1;
    }
    return imported;
}

pub fn mergeWorktree(
    store: *Store,
    alloc: std.mem.Allocator,
    id: []const u8,
    destination_branch: []const u8,
    author: []const u8,
    timestamp: i64,
) !MergeResult {
    const inspection = try inspect(store, alloc, id);
    defer inspection.deinit(alloc);
    if (inspection.entry.state == .removed) return Error.WorktreeRemoved;
    if (inspection.dirty()) return Error.WorktreeDirty;
    const child_tip = inspection.tip orelse return Error.NothingToMerge;
    if (child_tip.eql(inspection.entry.baseline)) return Error.NothingToMerge;
    const destination_prev = store.readRef(destination_branch) catch return history.Error.UnbornBranch;

    var child = try openWorktree(store, inspection.entry.path);
    defer child.dir.close(store.io);
    defer child.store.deinit();
    const imported = try importObjects(store, &child.store, alloc);

    if (destination_prev.eql(inspection.entry.baseline)) {
        try store.updateRef(destination_branch, child_tip);
        errdefer store.updateRef(destination_branch, destination_prev) catch {};
        try oplog.record(store, .{
            .kind = .other,
            .branch = destination_branch,
            .prev = destination_prev,
            .new = child_tip,
            .timestamp = timestamp,
        });
        return .{
            .prev = destination_prev,
            .new = child_tip,
            .fast_forward = true,
            .imported = imported,
            .conflicts = try alloc.alloc([]u8, 0),
        };
    }

    const destination_change = try store.readChange(destination_prev);
    defer object.freeChange(alloc, destination_change);
    const child_change = try store.readChange(child_tip);
    defer object.freeChange(alloc, child_change);
    const ancestor = try merge_mod.commonAncestor(store, alloc, destination_prev, child_tip);
    const base_tree: ?Oid = if (ancestor) |base| blk: {
        const change = try store.readChange(base);
        defer object.freeChange(alloc, change);
        break :blk change.tree;
    } else null;
    const merged = try merge_mod.mergeTrees(store, alloc, base_tree, destination_change.tree, child_change.tree);
    errdefer merge_mod.freeMergeResult(alloc, merged);
    const parents = [_]Oid{ destination_prev, child_tip };
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, merged.tree.bytes[0..16]);
    const message = try std.fmt.allocPrint(alloc, "merge worktree {s} into {s}", .{ id, destination_branch });
    defer alloc.free(message);
    const merge_oid = try store.writeChange(.{
        .tree = merged.tree,
        .parents = &parents,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = 0,
        .author = author,
        .message = message,
    });
    try store.updateRef(destination_branch, merge_oid);
    errdefer store.updateRef(destination_branch, destination_prev) catch {};
    try oplog.record(store, .{
        .kind = .other,
        .branch = destination_branch,
        .prev = destination_prev,
        .new = merge_oid,
        .timestamp = timestamp,
    });
    return .{
        .prev = destination_prev,
        .new = merge_oid,
        .fast_forward = false,
        .imported = imported,
        .conflicts = merged.conflicts,
    };
}

fn removedPath(alloc: std.mem.Allocator, original: []const u8, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}.sdt-removed-{s}", .{ original, id });
}

pub fn remove(store: *Store, alloc: std.mem.Allocator, origin_abs: []const u8, id: []const u8) !Entry {
    var entry = try get(store, alloc, id);
    errdefer entry.deinit(alloc);
    if (entry.state == .removed) return Error.WorktreeRemoved;
    if (std.mem.eql(u8, origin_abs, entry.path)) return Error.CannotRemoveOrigin;
    const archived = try removedPath(alloc, entry.original_path, entry.id);
    defer alloc.free(archived);
    if (std.Io.Dir.cwd().access(store.io, archived, .{})) |_| return Error.RestoreTargetExists else |_| {}
    const owned_archived = try alloc.dupe(u8, archived);
    const old_path = entry.path;
    std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), archived, store.io) catch {
        alloc.free(owned_archived);
        return Error.WorktreeMissing;
    };
    errdefer std.Io.Dir.cwd().rename(archived, std.Io.Dir.cwd(), old_path, store.io) catch {};
    entry.path = owned_archived;
    entry.state = .removed;
    try writeEntry(store, entry);
    alloc.free(old_path);
    return entry;
}

pub fn restore(store: *Store, alloc: std.mem.Allocator, id: []const u8) !Entry {
    var entry = try get(store, alloc, id);
    errdefer entry.deinit(alloc);
    if (entry.state == .active) return Error.AlreadyRegistered;
    if (std.Io.Dir.cwd().access(store.io, entry.original_path, .{})) |_| return Error.RestoreTargetExists else |_| {}
    const owned_original = try alloc.dupe(u8, entry.original_path);
    const old_path = entry.path;
    std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), entry.original_path, store.io) catch {
        alloc.free(owned_original);
        return Error.WorktreeMissing;
    };
    errdefer std.Io.Dir.cwd().rename(entry.original_path, std.Io.Dir.cwd(), old_path, store.io) catch {};
    entry.path = owned_original;
    entry.state = .active;
    try writeEntry(store, entry);
    alloc.free(old_path);
    return entry;
}

const testing = std.testing;

fn save(dir: std.Io.Dir, store: *Store, text: []const u8, timestamp: i64) !Oid {
    try dir.writeFile(std.testing.io, .{ .sub_path = "file", .data = text });
    return workspace.snapshot(store, dir, "T <t@e>", text, timestamp);
}

test "register list inspect remove and restore preserve the complete worktree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "origin");
    var origin = try tmp.dir.openDir(io, "origin", .{ .iterate = true });
    defer origin.close(io);
    var store = try Store.init(io, alloc, origin);
    defer store.deinit();
    _ = try save(origin, &store, "base", 1);
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const origin_abs = try std.fs.path.join(alloc, &.{ root, "origin" });
    defer alloc.free(origin_abs);
    const child_abs = try std.fs.path.join(alloc, &.{ root, "child" });
    defer alloc.free(child_abs);

    const made = try create(&store, origin_abs, child_abs);
    const id = try alloc.dupe(u8, made.id);
    made.deinit(alloc);
    defer alloc.free(id);
    const entries = try list(&store, alloc, false);
    defer {
        for (entries) |entry| entry.deinit(alloc);
        alloc.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);

    const before = try inspect(&store, alloc, id);
    defer before.deinit(alloc);
    try testing.expect(!before.dirty());

    const removed = try remove(&store, alloc, origin_abs, id);
    const archive = try alloc.dupe(u8, removed.path);
    removed.deinit(alloc);
    defer alloc.free(archive);
    try std.Io.Dir.cwd().access(io, archive, .{});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, child_abs, .{}));

    const restored = try restore(&store, alloc, id);
    restored.deinit(alloc);
    const restored_file = try std.fs.path.join(alloc, &.{ child_abs, "file" });
    defer alloc.free(restored_file);
    const body = try std.Io.Dir.cwd().readFileAlloc(io, restored_file, alloc, .unlimited);
    defer alloc.free(body);
    try testing.expectEqualStrings("base", body);
}

test "merge worktree imports objects and is reversible independently of removal" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "origin");
    var origin = try tmp.dir.openDir(io, "origin", .{ .iterate = true });
    defer origin.close(io);
    var store = try Store.init(io, alloc, origin);
    defer store.deinit();
    const base = try save(origin, &store, "base", 1);
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const origin_abs = try std.fs.path.join(alloc, &.{ root, "origin" });
    defer alloc.free(origin_abs);
    const child_abs = try std.fs.path.join(alloc, &.{ root, "child" });
    defer alloc.free(child_abs);
    const made = try create(&store, origin_abs, child_abs);
    const id = try alloc.dupe(u8, made.id);
    made.deinit(alloc);
    defer alloc.free(id);

    var child_dir = try std.Io.Dir.openDirAbsolute(io, child_abs, .{ .iterate = true });
    defer child_dir.close(io);
    var child_store = try Store.open(io, alloc, child_dir);
    const child_tip = try save(child_dir, &child_store, "changed", 2);
    child_store.deinit();

    const merged = try mergeWorktree(&store, alloc, id, "main", "T <t@e>", 3);
    defer merged.deinit(alloc);
    try testing.expect(merged.fast_forward);
    try testing.expect(merged.new.eql(child_tip));
    try testing.expect(merged.imported > 0);
    try testing.expect((try store.readRef("main")).eql(child_tip));
    try oplog.undo(&store, null);
    try testing.expect((try store.readRef("main")).eql(base));
    try std.Io.Dir.cwd().access(io, child_abs, .{});
}

test "merge worktree refuses dirty files without moving the destination" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "origin");
    var origin = try tmp.dir.openDir(io, "origin", .{ .iterate = true });
    defer origin.close(io);
    var store = try Store.init(io, alloc, origin);
    defer store.deinit();
    const base = try save(origin, &store, "base", 1);
    const root = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(root);
    const origin_abs = try std.fs.path.join(alloc, &.{ root, "origin" });
    defer alloc.free(origin_abs);
    const child_abs = try std.fs.path.join(alloc, &.{ root, "child" });
    defer alloc.free(child_abs);
    const made = try create(&store, origin_abs, child_abs);
    const id = try alloc.dupe(u8, made.id);
    made.deinit(alloc);
    defer alloc.free(id);
    var child = try std.Io.Dir.openDirAbsolute(io, child_abs, .{});
    defer child.close(io);
    try child.writeFile(io, .{ .sub_path = "file", .data = "dirty" });

    try testing.expectError(Error.WorktreeDirty, mergeWorktree(&store, alloc, id, "main", "T <t@e>", 2));
    try testing.expect((try store.readRef("main")).eql(base));
}
