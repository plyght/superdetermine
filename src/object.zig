const std = @import("std");
const oid = @import("oid.zig");
const Oid = oid.Oid;

/// superdetermine's object model. Everything is content-addressed: an object's Oid is
/// the BLAKE3 hash of its canonical encoding (which begins with a type tag, so
/// hashes are domain-separated across object kinds).
///
/// Object graph:
///   chunk  -> raw bytes (stored directly; Oid = hash of the bytes, no tag)
///   blob   -> ordered manifest of chunk Oids = one file's content
///   tree   -> flat list of (mode, path, blob Oid) = a directory snapshot
///   change -> tree Oid + parents + author/time + stable change-id (= a commit)
pub const Kind = enum(u8) {
    blob = 'B',
    tree = 'T',
    change = 'C',
};

pub const ChangeId = [16]u8;

pub const Mode = enum(u32) {
    regular = 0o100644,
    executable = 0o100755,
    symlink = 0o120000,
    _,
};

pub const Blob = struct {
    total_size: u64,
    chunks: []const Oid,

    pub fn encode(self: Blob, alloc: std.mem.Allocator) ![]u8 {
        var w = Writer.init(alloc);
        errdefer w.deinit();
        try w.byte(@intFromEnum(Kind.blob));
        try w.putU64(self.total_size);
        try w.putU32(@intCast(self.chunks.len));
        for (self.chunks) |c| try w.oid(c);
        return w.finish();
    }

    /// Decodes into memory owned by `alloc` (the chunk slice). Free with
    /// `alloc.free(blob.chunks)`.
    pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Blob {
        var r = Reader.init(data);
        try r.expectTag(.blob);
        const total = try r.takeU64();
        const n = try r.takeU32();
        const chunks = try alloc.alloc(Oid, n);
        errdefer alloc.free(chunks);
        for (chunks) |*c| c.* = try r.oid();
        return .{ .total_size = total, .chunks = chunks };
    }
};

pub const TreeEntry = struct {
    mode: Mode,
    /// path is relative to the repo root, forward-slash separated.
    path: []const u8,
    blob: Oid,
};

pub const Tree = struct {
    entries: []const TreeEntry,

    /// Caller must ensure entries are sorted by path (use `lessThan`).
    pub fn encode(self: Tree, alloc: std.mem.Allocator) ![]u8 {
        var w = Writer.init(alloc);
        errdefer w.deinit();
        try w.byte(@intFromEnum(Kind.tree));
        try w.putU32(@intCast(self.entries.len));
        for (self.entries) |e| {
            try w.putU32(@intFromEnum(e.mode));
            try w.oid(e.blob);
            try w.putU16(@intCast(e.path.len));
            try w.bytes(e.path);
        }
        return w.finish();
    }

    /// Decodes into memory owned by `alloc`. Free with `freeTree`.
    pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Tree {
        var r = Reader.init(data);
        try r.expectTag(.tree);
        const n = try r.takeU32();
        const entries = try alloc.alloc(TreeEntry, n);
        errdefer alloc.free(entries);
        for (entries) |*e| {
            e.mode = @enumFromInt(try r.takeU32());
            e.blob = try r.oid();
            const plen = try r.takeU16();
            e.path = try alloc.dupe(u8, try r.slice(plen));
        }
        return .{ .entries = entries };
    }

    pub fn lessThan(_: void, a: TreeEntry, b: TreeEntry) bool {
        return std.mem.lessThan(u8, a.path, b.path);
    }
};

pub fn freeTree(alloc: std.mem.Allocator, tree: Tree) void {
    for (tree.entries) |e| alloc.free(e.path);
    alloc.free(tree.entries);
}

pub const Change = struct {
    tree: Oid,
    parents: []const Oid,
    change_id: ChangeId,
    /// Unix seconds + timezone offset in minutes.
    timestamp: i64,
    tz_offset_min: i32,
    author: []const u8,
    message: []const u8,

    pub fn encode(self: Change, alloc: std.mem.Allocator) ![]u8 {
        var w = Writer.init(alloc);
        errdefer w.deinit();
        try w.byte(@intFromEnum(Kind.change));
        try w.oid(self.tree);
        try w.putU32(@intCast(self.parents.len));
        for (self.parents) |p| try w.oid(p);
        try w.bytes(&self.change_id);
        try w.putU64(@bitCast(self.timestamp));
        try w.putU32(@bitCast(self.tz_offset_min));
        try w.putU16(@intCast(self.author.len));
        try w.bytes(self.author);
        try w.putU32(@intCast(self.message.len));
        try w.bytes(self.message);
        return w.finish();
    }

    /// Decodes into memory owned by `alloc`. Free with `freeChange`.
    pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Change {
        var r = Reader.init(data);
        try r.expectTag(.change);
        const tree = try r.oid();
        const np = try r.takeU32();
        const parents = try alloc.alloc(Oid, np);
        errdefer alloc.free(parents);
        for (parents) |*p| p.* = try r.oid();
        var change_id: ChangeId = undefined;
        @memcpy(&change_id, try r.slice(16));
        const ts: i64 = @bitCast(try r.takeU64());
        const tz: i32 = @bitCast(try r.takeU32());
        const alen = try r.takeU16();
        const author = try alloc.dupe(u8, try r.slice(alen));
        errdefer alloc.free(author);
        const mlen = try r.takeU32();
        const message = try alloc.dupe(u8, try r.slice(mlen));
        return .{
            .tree = tree,
            .parents = parents,
            .change_id = change_id,
            .timestamp = ts,
            .tz_offset_min = tz,
            .author = author,
            .message = message,
        };
    }
};

pub fn freeChange(alloc: std.mem.Allocator, change: Change) void {
    alloc.free(change.parents);
    alloc.free(change.author);
    alloc.free(change.message);
}

// --- tiny binary encode/decode helpers (big-endian, self-describing lengths) ---

const Writer = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Writer {
        return .{ .list = .empty, .alloc = alloc };
    }
    fn deinit(self: *Writer) void {
        self.list.deinit(self.alloc);
    }
    fn byte(self: *Writer, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    fn bytes(self: *Writer, b: []const u8) !void {
        try self.list.appendSlice(self.alloc, b);
    }
    fn putU16(self: *Writer, v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn putU32(self: *Writer, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn putU64(self: *Writer, v: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn oid(self: *Writer, o: Oid) !void {
        try self.bytes(&o.bytes);
    }
    fn finish(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }
    fn slice(self: *Reader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn expectTag(self: *Reader, kind: Kind) !void {
        const b = try self.slice(1);
        if (b[0] != @intFromEnum(kind)) return error.WrongKind;
    }
    fn takeU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.slice(2))[0..2], .big);
    }
    fn takeU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.slice(4))[0..4], .big);
    }
    fn takeU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.slice(8))[0..8], .big);
    }
    fn oid(self: *Reader) !Oid {
        var o: Oid = undefined;
        @memcpy(&o.bytes, try self.slice(Oid.len));
        return o;
    }
};

test "blob roundtrip" {
    const alloc = std.testing.allocator;
    const chunks = [_]Oid{ Oid.ofBytes("a"), Oid.ofBytes("b") };
    const blob = Blob{ .total_size = 123, .chunks = &chunks };
    const enc = try blob.encode(alloc);
    defer alloc.free(enc);
    const dec = try Blob.decode(alloc, enc);
    defer alloc.free(dec.chunks);
    try std.testing.expectEqual(@as(u64, 123), dec.total_size);
    try std.testing.expectEqual(@as(usize, 2), dec.chunks.len);
    try std.testing.expect(dec.chunks[0].eql(chunks[0]));
}

test "tree roundtrip" {
    const alloc = std.testing.allocator;
    const entries = [_]TreeEntry{
        .{ .mode = .regular, .path = "a.txt", .blob = Oid.ofBytes("a") },
        .{ .mode = .executable, .path = "bin/run", .blob = Oid.ofBytes("r") },
    };
    const tree = Tree{ .entries = &entries };
    const enc = try tree.encode(alloc);
    defer alloc.free(enc);
    const dec = try Tree.decode(alloc, enc);
    defer freeTree(alloc, dec);
    try std.testing.expectEqual(@as(usize, 2), dec.entries.len);
    try std.testing.expectEqualStrings("bin/run", dec.entries[1].path);
}

test "change roundtrip" {
    const alloc = std.testing.allocator;
    const parents = [_]Oid{Oid.ofBytes("p")};
    const change = Change{
        .tree = Oid.ofBytes("t"),
        .parents = &parents,
        .change_id = [_]u8{7} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = -480,
        .author = "Nico <n@example.com>",
        .message = "first",
    };
    const enc = try change.encode(alloc);
    defer alloc.free(enc);
    const dec = try Change.decode(alloc, enc);
    defer freeChange(alloc, dec);
    try std.testing.expectEqual(change.timestamp, dec.timestamp);
    try std.testing.expectEqualStrings("first", dec.message);
    try std.testing.expect(dec.tree.eql(change.tree));
}
