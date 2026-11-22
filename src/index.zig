const std = @import("std");
const oid = @import("oid.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const Entry = struct {
    mtime_ns: i96,
    size: u64,
    inode: u64,
    blob: Oid,
};

pub const Index = struct {
    map: std.StringHashMapUnmanaged(Entry),
    keys: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    pub fn empty(alloc: std.mem.Allocator) Index {
        return .{ .map = .empty, .keys = .init(alloc), .alloc = alloc };
    }

    pub fn deinit(self: *Index) void {
        self.map.deinit(self.alloc);
        self.keys.deinit();
    }

    pub fn load(store: *Store, alloc: std.mem.Allocator) !Index {
        var self = Index.empty(alloc);
        errdefer self.deinit();
        const data = store.root.readFileAlloc(store.io, "index", alloc, .unlimited) catch |e| switch (e) {
            error.FileNotFound => return self,
            else => return e,
        };
        defer alloc.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            var it = std.mem.splitScalar(u8, line, ' ');
            const mtime_s = it.next() orelse continue;
            const size_s = it.next() orelse continue;
            const inode_s = it.next() orelse continue;
            const blob_s = it.next() orelse continue;
            const path = it.rest();
            if (path.len == 0) continue;
            const entry: Entry = .{
                .mtime_ns = std.fmt.parseInt(i96, mtime_s, 10) catch continue,
                .size = std.fmt.parseInt(u64, size_s, 10) catch continue,
                .inode = std.fmt.parseInt(u64, inode_s, 10) catch continue,
                .blob = Oid.fromHex(blob_s) catch continue,
            };
            try self.set(path, entry);
        }
        return self;
    }

    pub fn save(self: *Index, store: *Store) !void {
        var out = std.Io.Writer.Allocating.init(self.alloc);
        defer out.deinit();
        var it = self.map.iterator();
        while (it.next()) |kv| {
            var hex: [Oid.len * 2]u8 = undefined;
            _ = kv.value_ptr.blob.toHex(&hex);
            out.writer.print("{d} {d} {d} {s} {s}\n", .{
                @as(i128, kv.value_ptr.mtime_ns),
                kv.value_ptr.size,
                kv.value_ptr.inode,
                hex,
                kv.key_ptr.*,
            }) catch return error.OutOfMemory;
        }
        try store.writeFileAtomic("index", out.written());
    }

    /// Returns the cached blob Oid iff a prior entry for `path` matches the
    /// current stat (mtime, size, inode all identical). Otherwise null.
    pub fn lookup(self: *const Index, path: []const u8, st: std.Io.File.Stat) ?Oid {
        const e = self.map.get(path) orelse return null;
        if (e.mtime_ns != st.mtime.nanoseconds) return null;
        if (e.size != st.size) return null;
        if (e.inode != @as(u64, @intCast(st.inode))) return null;
        return e.blob;
    }

    /// Record the current stat + blob for `path`, duplicating the key.
    pub fn put(self: *Index, path: []const u8, st: std.Io.File.Stat, blob: Oid) !void {
        try self.set(path, .{
            .mtime_ns = st.mtime.nanoseconds,
            .size = st.size,
            .inode = @intCast(st.inode),
            .blob = blob,
        });
    }

    fn set(self: *Index, path: []const u8, entry: Entry) !void {
        const gop = try self.map.getOrPut(self.alloc, path);
        if (!gop.found_existing) {
            errdefer _ = self.map.remove(path);
            gop.key_ptr.* = try self.keys.allocator().dupe(u8, path);
        }
        gop.value_ptr.* = entry;
    }
};

const testing = std.testing;

test "index roundtrip and stat match" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello" });
    const st = try tmp.dir.statFile(io, "f.txt", .{});
    const blob = Oid.ofBytes("hello");

    var ix = Index.empty(alloc);
    defer ix.deinit();
    try ix.put("f.txt", st, blob);

    try testing.expect(ix.lookup("f.txt", st).?.eql(blob));
    try testing.expect(ix.lookup("missing", st) == null);

    try ix.save(&store);

    var loaded = try Index.load(&store, alloc);
    defer loaded.deinit();
    const st2 = try tmp.dir.statFile(io, "f.txt", .{});
    try testing.expect(loaded.lookup("f.txt", st2).?.eql(blob));
}

test "lookup misses when size changes" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello" });
    const st = try tmp.dir.statFile(io, "f.txt", .{});

    var ix = Index.empty(alloc);
    defer ix.deinit();
    try ix.put("f.txt", st, Oid.ofBytes("hello"));

    try tmp.dir.writeFile(io, .{ .sub_path = "f.txt", .data = "hello world longer" });
    const st2 = try tmp.dir.statFile(io, "f.txt", .{});
    try testing.expect(ix.lookup("f.txt", st2) == null);
}

test "large stat index roundtrips without per-entry allocations" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const count = 2048;
    const blob = Oid.ofBytes("content");
    const entry: Entry = .{ .mtime_ns = -1, .size = 7, .inode = 42, .blob = blob };
    var measured = testing.FailingAllocator.init(alloc, .{});
    var ix = Index.empty(measured.allocator());
    defer ix.deinit();

    var buf: [64]u8 = undefined;
    for (0..count) |i| {
        const path = try std.fmt.bufPrint(&buf, "src/file {d}.zig", .{i});
        try ix.set(path, entry);
    }
    const after_put = measured.allocations;
    try ix.save(&store);
    const after_save = measured.allocations;

    var loaded = try Index.load(&store, measured.allocator());
    defer loaded.deinit();
    try testing.expectEqual(count, loaded.map.count());
    for (0..count) |i| {
        const path = try std.fmt.bufPrint(&buf, "src/file {d}.zig", .{i});
        try testing.expectEqual(entry, loaded.map.get(path).?);
    }
    try testing.expect(after_put < count / 8);
    try testing.expect(after_save - after_put < count / 8);
    try testing.expect(measured.allocations - after_save < count / 8);
}
