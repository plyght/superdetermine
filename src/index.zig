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
    alloc: std.mem.Allocator,

    pub fn empty(alloc: std.mem.Allocator) Index {
        return .{ .map = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Index) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.map.deinit(self.alloc);
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
            const key = try alloc.dupe(u8, path);
            errdefer alloc.free(key);
            try self.map.put(alloc, key, entry);
        }
        return self;
    }

    pub fn save(self: *Index, store: *Store) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        var it = self.map.iterator();
        while (it.next()) |kv| {
            var hex: [Oid.len * 2]u8 = undefined;
            _ = kv.value_ptr.blob.toHex(&hex);
            const line = try std.fmt.allocPrint(self.alloc, "{d} {d} {d} {s} {s}\n", .{
                @as(i128, kv.value_ptr.mtime_ns),
                kv.value_ptr.size,
                kv.value_ptr.inode,
                hex,
                kv.key_ptr.*,
            });
            defer self.alloc.free(line);
            try out.appendSlice(self.alloc, line);
        }
        try store.writeFileAtomic("index", out.items);
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
        const gop = try self.map.getOrPut(self.alloc, path);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.alloc.dupe(u8, path);
        }
        gop.value_ptr.* = .{
            .mtime_ns = st.mtime.nanoseconds,
            .size = st.size,
            .inode = @intCast(st.inode),
            .blob = blob,
        };
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
