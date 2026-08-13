const std = @import("std");
const Blake3 = @import("oid.zig").Blake3;

/// FastCDC (2020) content-defined chunking.
///
/// Boundaries are found from content via a rolling "gear" hash, so inserting or
/// editing bytes only shifts boundaries locally — unchanged regions keep the
/// same cut points and therefore the same content hash, which is what makes
/// cross-version and cross-file dedup work. Chunking is deterministic: identical
/// bytes always produce identical boundaries on any machine.
pub const Config = struct {
    min_size: u32 = 256 * 1024,
    avg_size: u32 = 1024 * 1024,
    max_size: u32 = 4 * 1024 * 1024,

    pub fn validate(self: Config) void {
        std.debug.assert(self.min_size < self.avg_size);
        std.debug.assert(self.avg_size < self.max_size);
    }
};

pub const Chunk = struct {
    offset: usize,
    len: usize,
};

pub const GearTable = [256]u64;

pub const key_len = 32;

pub const Key = [key_len]u8;

const gear_context = "superdetermine/cdc/gear/v1";

pub fn gearFromKey(key: Key) GearTable {
    var h = Blake3.init(.{ .key = key });
    h.update(gear_context);
    var bytes: [@sizeOf(GearTable)]u8 = undefined;
    h.final(&bytes);
    var table: GearTable = undefined;
    for (&table, 0..) |*e, i| {
        e.* = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    }
    return table;
}

pub fn randomKey(io: std.Io) !Key {
    var key: Key = undefined;
    try io.randomSecure(&key);
    return key;
}

/// A streaming chunker over an in-memory buffer. Call `next` until it returns
/// null. The returned Chunk references `data` — no allocation is performed.
pub const Chunker = struct {
    data: []const u8,
    pos: usize,
    min_size: usize,
    max_size: usize,
    mask_s: u64,
    mask_l: u64,
    normal_size: usize,
    gear: *const GearTable,

    pub fn init(data: []const u8, cfg: Config) Chunker {
        return initWith(data, cfg, &legacy_gear);
    }

    pub fn initWith(data: []const u8, cfg: Config, table: *const GearTable) Chunker {
        cfg.validate();
        const bits = log2Int(cfg.avg_size);
        // Normalized chunking: a stricter mask before the average point and a
        // looser one after, which tightens the chunk-size distribution.
        return .{
            .data = data,
            .pos = 0,
            .min_size = cfg.min_size,
            .max_size = cfg.max_size,
            .mask_s = maskOf(bits + 1),
            .mask_l = maskOf(bits - 1),
            .normal_size = cfg.avg_size,
            .gear = table,
        };
    }

    pub fn next(self: *Chunker) ?Chunk {
        const remaining = self.data.len - self.pos;
        if (remaining == 0) return null;

        const start = self.pos;
        if (remaining <= self.min_size) {
            self.pos = self.data.len;
            return .{ .offset = start, .len = remaining };
        }

        var end = self.min_size;
        var normal = self.normal_size;
        if (remaining < normal) normal = remaining;
        var limit = self.max_size;
        if (remaining < limit) limit = remaining;

        var fp: u64 = 0;
        const buf = self.data[start..][0..limit];
        const g = self.gear;
        var i: usize = self.min_size;

        // Region 1: below the average size, use the stricter mask.
        while (i < normal) : (i += 1) {
            fp = (fp << 1) +% g[buf[i]];
            if ((fp & self.mask_s) == 0) {
                self.pos = start + i + 1;
                return .{ .offset = start, .len = i + 1 };
            }
        }
        // Region 2: past the average size, use the looser mask.
        while (i < limit) : (i += 1) {
            fp = (fp << 1) +% g[buf[i]];
            if ((fp & self.mask_l) == 0) {
                self.pos = start + i + 1;
                return .{ .offset = start, .len = i + 1 };
            }
        }

        _ = &end;
        self.pos = start + limit;
        return .{ .offset = start, .len = limit };
    }
};

fn maskOf(bits: u6) u64 {
    return (@as(u64, 1) << bits) - 1;
}

fn log2Int(n: u32) u6 {
    return @intCast(31 - @clz(n));
}

/// 256-entry gear table, deterministically generated with a fixed-seed SplitMix64
/// so every build (and every machine) agrees on chunk boundaries.
pub const legacy_gear: GearTable = blk: {
    @setEvalBranchQuota(10_000);
    var table: [256]u64 = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;
    for (&table) |*e| {
        state +%= 0x9e3779b97f4a7c15;
        var z = state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        z = z ^ (z >> 31);
        e.* = z;
    }
    break :blk table;
};

fn pinnedBytes(alloc: std.mem.Allocator, n: usize) ![]u8 {
    const data = try alloc.alloc(u8, n);
    var h = Blake3.init(.{});
    h.update("superdetermine cdc boundary pin");
    h.final(data);
    return data;
}

fn lensOf(alloc: std.mem.Allocator, data: []const u8, table: *const GearTable) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(alloc);
    var c = Chunker.initWith(data, .{}, table);
    while (c.next()) |ch| try out.append(alloc, ch.len);
    return out.toOwnedSlice(alloc);
}

test "legacy boundaries are pinned" {
    const alloc = std.testing.allocator;
    const data = try pinnedBytes(alloc, 4 * 1024 * 1024);
    defer alloc.free(data);

    const lens = try lensOf(alloc, data, &legacy_gear);
    defer alloc.free(lens);

    const expected = [_]usize{ 1240328, 1907079, 1046897 };
    try std.testing.expectEqualSlices(usize, &expected, lens);
}

test "a key moves the boundaries, and the same key always reproduces them" {
    const alloc = std.testing.allocator;
    const data = try pinnedBytes(alloc, 4 * 1024 * 1024);
    defer alloc.free(data);

    const key_a: Key = @splat(0xa5);
    var key_b: Key = @splat(0xa5);
    key_b[31] = 0xa6;

    const table_a = gearFromKey(key_a);
    const table_a2 = gearFromKey(key_a);
    const table_b = gearFromKey(key_b);
    try std.testing.expectEqualSlices(u64, &table_a, &table_a2);
    try std.testing.expect(!std.mem.eql(u64, &table_a, &table_b));
    try std.testing.expect(!std.mem.eql(u64, &table_a, &legacy_gear));

    const legacy = try lensOf(alloc, data, &legacy_gear);
    defer alloc.free(legacy);
    const keyed_a = try lensOf(alloc, data, &table_a);
    defer alloc.free(keyed_a);
    const keyed_a2 = try lensOf(alloc, data, &table_a2);
    defer alloc.free(keyed_a2);
    const keyed_b = try lensOf(alloc, data, &table_b);
    defer alloc.free(keyed_b);

    try std.testing.expectEqualSlices(usize, keyed_a, keyed_a2);
    try std.testing.expect(!std.mem.eql(usize, legacy, keyed_a));
    try std.testing.expect(!std.mem.eql(usize, keyed_a, keyed_b));

    var sum: usize = 0;
    for (keyed_a) |l| sum += l;
    try std.testing.expectEqual(data.len, sum);
}

test "chunker covers input exactly and is deterministic" {
    const alloc = std.testing.allocator;
    const data = try alloc.alloc(u8, 5 * 1024 * 1024);
    defer alloc.free(data);
    var prng = std.Random.DefaultPrng.init(42);
    prng.random().bytes(data);

    const cfg = Config{};
    var expected: usize = 0;
    var count: usize = 0;
    var c1 = Chunker.init(data, cfg);
    while (c1.next()) |ch| {
        try std.testing.expectEqual(expected, ch.offset);
        expected += ch.len;
        count += 1;
    }
    try std.testing.expectEqual(data.len, expected);
    try std.testing.expect(count > 1);

    // Determinism: same bytes -> same boundaries.
    var c2 = Chunker.init(data, cfg);
    var c3 = Chunker.init(data, cfg);
    while (c2.next()) |a| {
        const b = c3.next().?;
        try std.testing.expectEqual(a.offset, b.offset);
        try std.testing.expectEqual(a.len, b.len);
    }
    try std.testing.expect(c3.next() == null);
}

test "edit shifts only local boundaries (dedup property)" {
    const alloc = std.testing.allocator;
    const n = 4 * 1024 * 1024;
    var base = try alloc.alloc(u8, n);
    defer alloc.free(base);
    var prng = std.Random.DefaultPrng.init(7);
    prng.random().bytes(base);

    var edited = try alloc.dupe(u8, base);
    defer alloc.free(edited);
    edited[n / 2] ^= 0xff; // flip one byte in the middle

    const cfg = Config{};
    var shared: usize = 0;
    var ca = Chunker.init(base, cfg);
    var cb = Chunker.init(edited, cfg);
    // Chunks before the edit must be byte-identical.
    while (ca.next()) |a| {
        const b = cb.next() orelse break;
        if (a.offset != b.offset or a.len != b.len) break;
        if (a.offset + a.len > n / 2) break;
        if (std.mem.eql(u8, base[a.offset..][0..a.len], edited[b.offset..][0..b.len])) {
            shared += 1;
        }
    }
    try std.testing.expect(shared > 0);
}
