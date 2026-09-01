const std = @import("std");
const oid = @import("oid.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// The set of repo-relative paths a check actually opened.
///
/// This is the empirical dependency list that layer 2 of the speed budget runs
/// on: if nothing in the read-set changed, the previous verdict holds and
/// nothing executes. It is also what the relevance axis of the warrant is
/// computed from, so the same measurement pays for two features.
///
/// The set is stored as a content-addressed object like everything else, so two
/// runs that touch identical files share one object and the verdict log only
/// ever carries a 32-byte reference.
pub const tag: u8 = 'R';

pub const ReadSet = struct {
    /// Sorted, deduplicated, repo-relative, forward-slash separated.
    paths: []const []const u8,

    pub fn deinit(self: ReadSet, alloc: std.mem.Allocator) void {
        for (self.paths) |p| alloc.free(p);
        alloc.free(self.paths);
    }

    pub fn contains(self: ReadSet, path: []const u8) bool {
        var lo: usize = 0;
        var hi: usize = self.paths.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            switch (std.mem.order(u8, self.paths[mid], path)) {
                .lt => lo = mid + 1,
                .gt => hi = mid,
                .eq => return true,
            }
        }
        return false;
    }

    /// How many of `paths` the check opened, and how many were asked about.
    /// This is the relevance fraction, and it is a set intersection over data
    /// already computed rather than any new measurement.
    pub fn coverage(self: ReadSet, paths: []const []const u8) struct { hit: usize, total: usize } {
        var hit: usize = 0;
        for (paths) |p| {
            if (self.contains(p)) hit += 1;
        }
        return .{ .hit = hit, .total = paths.len };
    }

    pub fn intersectsAny(self: ReadSet, paths: []const []const u8) bool {
        for (paths) |p| {
            if (self.contains(p)) return true;
        }
        return false;
    }
};

/// Build a read-set from raw candidate paths: sort, dedup, drop anything empty.
/// Takes ownership of nothing; every retained path is duplicated.
pub fn build(alloc: std.mem.Allocator, raw: []const []const u8) !ReadSet {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }

    const sorted = try alloc.alloc([]const u8, raw.len);
    defer alloc.free(sorted);
    @memcpy(sorted, raw);
    std.mem.sort([]const u8, sorted, {}, lessThan);

    for (sorted, 0..) |p, i| {
        if (p.len == 0) continue;
        if (i > 0 and std.mem.eql(u8, p, sorted[i - 1])) continue;
        try list.append(alloc, try alloc.dupe(u8, p));
    }
    return .{ .paths = try list.toOwnedSlice(alloc) };
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// --- storage ---

pub fn encode(alloc: std.mem.Allocator, set: ReadSet) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.append(alloc, tag);
    var count_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &count_buf, @intCast(set.paths.len), .big);
    try out.appendSlice(alloc, &count_buf);
    for (set.paths) |p| {
        var len_buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_buf, @intCast(p.len), .big);
        try out.appendSlice(alloc, &len_buf);
        try out.appendSlice(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

pub fn decode(alloc: std.mem.Allocator, data: []const u8) !ReadSet {
    if (data.len < 5 or data[0] != tag) return error.InvalidReadSet;
    const n = std.mem.readInt(u32, data[1..5], .big);
    var pos: usize = 5;

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |p| alloc.free(p);
        list.deinit(alloc);
    }

    for (0..n) |_| {
        if (pos + 2 > data.len) return error.InvalidReadSet;
        const len = std.mem.readInt(u16, data[pos..][0..2], .big);
        pos += 2;
        if (pos + len > data.len) return error.InvalidReadSet;
        try list.append(alloc, try alloc.dupe(u8, data[pos .. pos + len]));
        pos += len;
    }
    return .{ .paths = try list.toOwnedSlice(alloc) };
}

pub fn store_(store: *Store, set: ReadSet) !Oid {
    const enc = try encode(store.alloc, set);
    defer store.alloc.free(enc);
    return store.writeRaw(enc);
}

pub fn load(store: *Store, o: Oid) !ReadSet {
    if (o.isZero()) return error.InvalidReadSet;
    const raw = try store.readRaw(o);
    defer store.alloc.free(raw);
    return decode(store.alloc, raw);
}

// --- tests ---

const testing = std.testing;

test "build sorts, dedups, and drops empties" {
    const alloc = testing.allocator;
    const set = try build(alloc, &.{ "src/b.zig", "src/a.zig", "src/b.zig", "", "README.md" });
    defer set.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), set.paths.len);
    try testing.expectEqualStrings("README.md", set.paths[0]);
    try testing.expectEqualStrings("src/a.zig", set.paths[1]);
    try testing.expectEqualStrings("src/b.zig", set.paths[2]);
}

test "contains is exact" {
    const alloc = testing.allocator;
    const set = try build(alloc, &.{ "a", "b/c", "d" });
    defer set.deinit(alloc);

    try testing.expect(set.contains("a"));
    try testing.expect(set.contains("b/c"));
    try testing.expect(set.contains("d"));
    try testing.expect(!set.contains("b"));
    try testing.expect(!set.contains("e"));
    try testing.expect(!set.contains(""));
}

test "coverage is the relevance fraction" {
    const alloc = testing.allocator;
    const set = try build(alloc, &.{ "src/a.zig", "src/b.zig", "src/c.zig" });
    defer set.deinit(alloc);

    const all = set.coverage(&.{ "src/a.zig", "src/b.zig" });
    try testing.expectEqual(@as(usize, 2), all.hit);
    try testing.expectEqual(@as(usize, 2), all.total);

    const partial = set.coverage(&.{ "src/a.zig", "docs/x.md" });
    try testing.expectEqual(@as(usize, 1), partial.hit);
    try testing.expectEqual(@as(usize, 2), partial.total);

    const none = set.coverage(&.{"nothing"});
    try testing.expectEqual(@as(usize, 0), none.hit);
    try testing.expect(!set.intersectsAny(&.{"nothing"}));
    try testing.expect(set.intersectsAny(&.{ "nothing", "src/c.zig" }));
}

test "encode and decode roundtrip through the object store" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const set = try build(alloc, &.{ "src/main.zig", "build.zig", "src/deep/nested/path.txt" });
    defer set.deinit(alloc);

    const o = try store_(&s, set);
    const back = try load(&s, o);
    defer back.deinit(alloc);

    try testing.expectEqual(set.paths.len, back.paths.len);
    for (set.paths, back.paths) |a, b| try testing.expectEqualStrings(a, b);

    // Identical read-sets share one object.
    const again = try store_(&s, back);
    try testing.expect(again.eql(o));
}

test "decode rejects junk" {
    const alloc = testing.allocator;
    try testing.expectError(error.InvalidReadSet, decode(alloc, "nope"));
    try testing.expectError(error.InvalidReadSet, decode(alloc, ""));
}

test "an empty read-set is representable" {
    const alloc = testing.allocator;
    const set = try build(alloc, &.{});
    defer set.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), set.paths.len);
    try testing.expect(!set.contains("anything"));

    const enc = try encode(alloc, set);
    defer alloc.free(enc);
    const back = try decode(alloc, enc);
    defer back.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), back.paths.len);
}
