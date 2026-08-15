const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const oplog = @import("oplog.zig");
const moment = @import("moment.zig");
const opdag = @import("opdag.zig");
const branches = @import("branches.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

const Marked = std.AutoHashMap([32]u8, void);

pub const Settings = struct {
    /// How long an operation keeps pinning the content it referenced, in
    /// seconds. Past this, `gc` stops rooting from it and whatever a rewrite
    /// abandoned that long ago becomes collectable.
    ///
    /// This is what bounds the store. The op-log and the operation DAG are
    /// append-only, so rooting `gc` in all of them meant nothing a rewrite
    /// orphaned could ever be reclaimed: a repo that committed its build
    /// output once carried it forever, and `gc` would report kilobytes of
    /// garbage against gigabytes on disk.
    ///
    /// Bounding this never risks committed work. Branch refs are marked
    /// unconditionally below, so everything reachable from any branch survives
    /// regardless of age; only states abandoned by amend/rebase/drop/squash
    /// past the horizon go.
    retain_s: i64 = 30 * 24 * 60 * 60,
};

pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "gc.retain")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.retain_s = moment.parseDuration(v, out.retain_s);
        }
    } else |_| {}
    return out;
}

fn nowSeconds(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000_000));
}

pub const Stats = struct {
    swept: usize,
    bytes_freed: u64,
    kept: usize,
};

fn markChunks(store: *Store, marked: *Marked, o: Oid) !void {
    const raw = store.readRaw(o) catch return;
    defer store.alloc.free(raw);
    const blob = object.Blob.decode(store.alloc, raw) catch return;
    defer store.alloc.free(blob.chunks);
    for (blob.chunks) |c| _ = try marked.getOrPut(c.bytes);
}

fn markObject(store: *Store, marked: *Marked, root: Oid) !void {
    if (root.isZero()) return;

    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(store.alloc);
    try stack.append(store.alloc, root);

    while (stack.items.len > 0) {
        const o = stack.pop().?;
        if (o.isZero()) continue;
        if ((try marked.getOrPut(o.bytes)).found_existing) continue;
        if (!store.has(o)) continue;

        const change = store.readChange(o) catch continue;
        defer object.freeChange(store.alloc, change);

        for (change.parents) |p| try stack.append(store.alloc, p);

        if (!marked.contains(change.tree.bytes)) {
            _ = try marked.getOrPut(change.tree.bytes);
            const tree = try store.readTree(change.tree);
            defer object.freeTree(store.alloc, tree);
            for (tree.entries) |e| {
                if ((try marked.getOrPut(e.blob.bytes)).found_existing) continue;
                const raw = try store.readRaw(e.blob);
                defer store.alloc.free(raw);
                const blob = object.Blob.decode(store.alloc, raw) catch continue;
                defer store.alloc.free(blob.chunks);
                for (blob.chunks) |c| _ = try marked.getOrPut(c.bytes);
            }
        }
    }
}

pub fn collect(store: *Store, alloc: std.mem.Allocator, dry_run: bool) !Stats {
    const io = store.io;

    var marked = Marked.init(alloc);
    defer marked.deinit();

    const names = try branches.list(store, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    for (names) |n| {
        const ref = store.readRef(n) catch continue;
        try markObject(store, &marked, ref);
    }

    const records = try oplog.readAll(store, alloc);
    defer {
        for (records) |r| alloc.free(r.branch);
        alloc.free(records);
    }
    const set = settings(store, alloc);
    const cutoff = nowSeconds(io) - set.retain_s;

    for (records) |r| {
        if (r.timestamp < cutoff) continue;
        try markObject(store, &marked, r.prev);
        try markObject(store, &marked, r.new);
    }

    // Expired moments only ever dropped out of the log during a capture, so a
    // repo that stopped capturing kept being pinned by moments long past their
    // retention. Retire them here too, or `gc` reports nothing to do while the
    // moment log quietly holds the whole store open.
    if (!dry_run) {
        moment.trim(store, alloc, moment.settings(store, alloc)) catch {};
    }

    const captured = moment.reachableObjects(store, alloc) catch &[_]Oid{};
    defer alloc.free(captured);
    for (captured) |o| {
        if ((try marked.getOrPut(o.bytes)).found_existing) continue;
        markChunks(store, &marked, o) catch continue;
    }

    const op_heads = opdag.heads(store, alloc) catch &[_]Oid{};
    defer {
        alloc.free(op_heads);
    }
    var op_stack: std.ArrayList(Oid) = .empty;
    defer op_stack.deinit(alloc);
    for (op_heads) |h| try op_stack.append(alloc, h);
    while (op_stack.items.len > 0) {
        const o = op_stack.pop().?;
        if (o.isZero()) continue;
        if ((try marked.getOrPut(o.bytes)).found_existing) continue;
        const op = opdag.readOperation(store, alloc, o) catch continue;
        defer opdag.freeOperation(alloc, op);
        // Keep walking the whole DAG and keep every operation and view object,
        // so `sdt undo` still has an intact spine to read. Those records are
        // metadata and cost nothing. It is only the *content* an old operation
        // points at that stops being pinned.
        for (op.parents) |p| try op_stack.append(alloc, p);
        _ = try marked.getOrPut(op.view.bytes);
        const view = opdag.readView(store, alloc, op.view) catch continue;
        defer view.deinit(alloc);
        if (op.timestamp < cutoff) continue;
        for (view.refs) |r| {
            for (r.tips) |t| try markObject(store, &marked, t);
        }
    }

    var stats: Stats = .{ .swept = 0, .bytes_freed = 0, .kept = 0 };

    var objects = try store.root.openDir(io, "objects", .{ .iterate = true });
    defer objects.close(io);

    var shard_it = objects.iterate();
    while (try shard_it.next(io)) |shard| {
        if (shard.kind != .directory) continue;
        if (shard.name.len != 2) continue;

        var shard_dir = try objects.openDir(io, shard.name, .{ .iterate = true });
        defer shard_dir.close(io);

        var it = shard_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .file) continue;

            var hex: [Oid.len * 2]u8 = undefined;
            if (shard.name.len + entry.name.len != hex.len) continue;
            @memcpy(hex[0..2], shard.name);
            @memcpy(hex[2..], entry.name);
            const o = Oid.fromHex(&hex) catch continue;

            if (marked.contains(o.bytes)) {
                stats.kept += 1;
                continue;
            }

            const size = (shard_dir.statFile(io, entry.name, .{}) catch continue).size;
            if (!dry_run) {
                shard_dir.deleteFile(io, entry.name) catch continue;
            }
            stats.swept += 1;
            stats.bytes_freed += size;
        }
    }

    return stats;
}

fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    if (i == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[i] }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch unreachable;
}

pub fn run(store: *Store, alloc: std.mem.Allocator, out: *std.Io.Writer, dry_run: bool) !void {
    const stats = try collect(store, alloc, dry_run);
    var buf: [32]u8 = undefined;
    const human = formatBytes(stats.bytes_freed, &buf);
    if (dry_run) {
        try out.print("gc: would remove {d} objects, free {s} (kept {d})\n", .{ stats.swept, human, stats.kept });
    } else {
        try out.print("gc: removed {d} objects, freed {s} (kept {d})\n", .{ stats.swept, human, stats.kept });
    }
}

// --- tests ---

const testing = std.testing;

/// Build a change that no branch points at, as a rewrite would leave behind,
/// and log an operation for it at `ts`. Returns the change and its blob.
fn orphanedByRewrite(store: *Store, ts: i64) !struct { change: Oid, blob: Oid } {
    const blob = try store.writeFileContent("what a rewrite left behind");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "abandoned.txt", .blob = blob },
    };
    const tree = try store.writeTree(.{ .entries = &entries });
    const change = try store.writeChange(.{
        .tree = tree,
        .parents = &.{},
        .change_id = [_]u8{9} ** 16,
        .timestamp = ts,
        .tz_offset_min = 0,
        .author = "t",
        .message = "abandoned",
    });
    try oplog.record(store, .{
        .kind = .other,
        .branch = "main",
        .prev = Oid.zero(),
        .new = change,
        .timestamp = ts,
    });
    return .{ .change = change, .blob = blob };
}

fn commitOnMain(store: *Store) !Oid {
    const blob = try store.writeFileContent("committed work, kept forever");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep.txt", .blob = blob },
    };
    const tree = try store.writeTree(.{ .entries = &entries });
    const change = try store.writeChange(.{
        .tree = tree,
        .parents = &.{},
        .change_id = [_]u8{1} ** 16,
        // Deliberately ancient: age must never decide the fate of history that
        // a branch still points at.
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "keep",
    });
    try store.updateRef("main", change);
    return blob;
}

test "an operation past the horizon stops pinning what it abandoned" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const kept = try commitOnMain(&store);
    const old = try orphanedByRewrite(&store, 1); // 1970, far outside any horizon

    _ = try collect(&store, alloc, false);

    // The abandoned state goes...
    try testing.expect(!store.has(old.change));
    try testing.expect(!store.has(old.blob));
    // ...but committed history survives, however old it is.
    try testing.expect(store.has(kept));
}

test "an operation inside the horizon still pins what it abandoned" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const kept = try commitOnMain(&store);
    const recent = try orphanedByRewrite(&store, nowSeconds(io) - 60);

    _ = try collect(&store, alloc, false);

    // Undo has to be able to reach it, so it stays.
    try testing.expect(store.has(recent.change));
    try testing.expect(store.has(recent.blob));
    try testing.expect(store.has(kept));
}

test "gc.retain shortens the horizon" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try config.set(&store, "gc.retain", "1s");
    try testing.expectEqual(@as(i64, 1), settings(&store, alloc).retain_s);

    const kept = try commitOnMain(&store);
    const old = try orphanedByRewrite(&store, nowSeconds(io) - 600);

    _ = try collect(&store, alloc, false);
    try testing.expect(!store.has(old.blob));
    try testing.expect(store.has(kept));
}

test "gc sweeps orphans and keeps reachable objects" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const blob = try store.writeFileContent("reachable file content");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = blob },
    };
    const tree_oid = try store.writeTree(.{ .entries = &entries });
    const change = object.Change{
        .tree = tree_oid,
        .parents = &.{},
        .change_id = [_]u8{0} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "m",
    };
    const change_oid = try store.writeChange(change);
    try store.updateRef("main", change_oid);

    const orphan = try store.writeRaw("orphan garbage");
    try testing.expect(store.has(orphan));

    const stats = try collect(&store, alloc, false);
    try testing.expect(stats.swept >= 1);

    try testing.expect(!store.has(orphan));
    try testing.expect(store.has(change_oid));
    try testing.expect(store.has(tree_oid));
    try testing.expect(store.has(blob));

    const raw = try store.readRaw(blob);
    defer alloc.free(raw);
    const decoded = try object.Blob.decode(alloc, raw);
    defer alloc.free(decoded.chunks);
    for (decoded.chunks) |c| try testing.expect(store.has(c));
}
