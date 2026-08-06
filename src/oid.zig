const std = @import("std");

pub const Blake3 = std.crypto.hash.Blake3;

/// A content address. superdetermine uses BLAKE3-256 for every object and chunk.
/// The type is fixed-width here but callers should treat the length as the
/// single source of truth (`Oid.len`) so a future hash-width bridge stays local.
pub const Oid = struct {
    pub const len = 32;
    bytes: [len]u8,

    pub fn zero() Oid {
        return .{ .bytes = [_]u8{0} ** len };
    }

    pub fn isZero(self: Oid) bool {
        return std.mem.allEqual(u8, &self.bytes, 0);
    }

    pub fn eql(a: Oid, b: Oid) bool {
        return std.mem.eql(u8, &a.bytes, &b.bytes);
    }

    /// Hash arbitrary bytes into an Oid.
    pub fn ofBytes(data: []const u8) Oid {
        var out: Oid = undefined;
        Blake3.hash(data, &out.bytes, .{});
        return out;
    }

    /// Lowercase hex, written into `buf` (must be >= len*2). Returns the slice.
    pub fn toHex(self: Oid, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= len * 2);
        const hex = "0123456789abcdef";
        for (self.bytes, 0..) |byte, i| {
            buf[i * 2] = hex[byte >> 4];
            buf[i * 2 + 1] = hex[byte & 0x0f];
        }
        return buf[0 .. len * 2];
    }

    pub fn fromHex(s: []const u8) !Oid {
        if (s.len != len * 2) return error.InvalidOid;
        var out: Oid = undefined;
        _ = try std.fmt.hexToBytes(&out.bytes, s);
        return out;
    }

    pub fn format(self: Oid, writer: *std.Io.Writer) !void {
        var buf: [len * 2]u8 = undefined;
        try writer.writeAll(self.toHex(&buf));
    }
};

/// Incremental hasher wrapper so callers can stream large inputs.
pub const Hasher = struct {
    inner: Blake3,

    pub fn init() Hasher {
        return .{ .inner = Blake3.init(.{}) };
    }

    pub fn update(self: *Hasher, data: []const u8) void {
        self.inner.update(data);
    }

    pub fn finalOid(self: *Hasher) Oid {
        var out: Oid = undefined;
        self.inner.final(&out.bytes);
        return out;
    }
};

test "oid hex roundtrip" {
    const o = Oid.ofBytes("hello superdetermine");
    var buf: [Oid.len * 2]u8 = undefined;
    const hex = o.toHex(&buf);
    const back = try Oid.fromHex(hex);
    try std.testing.expect(o.eql(back));
    try std.testing.expect(!o.isZero());
}

test "oid zero" {
    try std.testing.expect(Oid.zero().isZero());
}
