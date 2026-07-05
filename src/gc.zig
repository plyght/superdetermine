const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const oplog = @import("oplog.zig");
const branches = @import("branches.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

const Marked = std.AutoHashMap([32]u8, void);

pub const Stats = struct {
    swept: usize,
    bytes_freed: u64,
    kept: usize,
};

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
    for (records) |r| {
        try markObject(store, &marked, r.prev);
        try markObject(store, &marked, r.new);
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
