const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Durability = store_mod.Durability;

/// O(1) appends to a line-oriented log inside `.sdt/`.
///
/// The read-modify-write shape these logs used before was invisible at op-log
/// volume and quadratic at moment volume: appending the n-th record rewrote all
/// n-1 preceding ones. Here the file is opened without truncation under an
/// exclusive advisory lock, its current length is queried, and the record is
/// written at that offset. Cost is independent of how long the log already is.
///
/// The lock is held only for the length-then-write pair, which is what makes
/// two `sdt` processes appending concurrently interleave whole records rather
/// than shredding each other's bytes.
///
/// Extending the file and filling the extension are two separate things to a
/// filesystem, and a crash between them leaves a record-shaped hole of zeroes
/// that every reader here skips as malformed — a moment or a verdict that
/// silently stops existing. Under `store.durability = strict` the bytes are
/// flushed before the lock is dropped, so a record that appended is a record
/// that is there.
pub fn append(store: *Store, sub_path: []const u8, bytes: []const u8) !void {
    return appendWith(store, sub_path, bytes, store.durability);
}

/// Append without the barrier whatever the repo asked for. For records a later
/// one supersedes — a heartbeat, a re-derivable capture — where the cost of a
/// flush per write outweighs losing the last of them.
pub fn appendFast(store: *Store, sub_path: []const u8, bytes: []const u8) !void {
    return appendWith(store, sub_path, bytes, .fast);
}

fn appendWith(store: *Store, sub_path: []const u8, bytes: []const u8, mode: Durability) !void {
    if (bytes.len == 0) return;
    const io = store.io;

    var file = try store.root.createFile(io, sub_path, .{
        .truncate = false,
        .lock = .exclusive,
    });
    defer file.close(io);

    const end = try file.length(io);
    try file.writePositionalAll(io, bytes, end);
    // Still under the lock: the next appender reads a length it can trust.
    if (mode == .strict) try store_mod.syncFile(io, file, .full);
}

/// Read a whole log. Absent file reads as empty rather than erroring, since a
/// log that has never been appended to is indistinguishable from an empty one.
/// Caller frees.
pub fn readAll(store: *Store, alloc: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    return store.root.readFileAlloc(store.io, sub_path, alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => try alloc.dupe(u8, ""),
        else => return e,
    };
}

/// Replace a log wholesale. Used by compaction and retention trimming, never on
/// the append path.
pub fn rewrite(store: *Store, sub_path: []const u8, data: []const u8) !void {
    try store.root.writeFile(store.io, .{ .sub_path = sub_path, .data = data });
}

// --- tests ---

const testing = std.testing;

test "append is additive and survives reopen" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try append(&store, "log", "one\n");
    try append(&store, "log", "two\n");
    try append(&store, "log", "three\n");

    const data = try readAll(&store, alloc, "log");
    defer alloc.free(data);
    try testing.expectEqualStrings("one\ntwo\nthree\n", data);
}

test "readAll of an absent log is empty, not an error" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const data = try readAll(&store, alloc, "never-written");
    defer alloc.free(data);
    try testing.expectEqualStrings("", data);
}

test "many appends stay byte-exact" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);

    for (0..500) |i| {
        const line = try std.fmt.allocPrint(alloc, "record {d}\n", .{i});
        defer alloc.free(line);
        try append(&store, "log", line);
        try expected.appendSlice(alloc, line);
    }

    const data = try readAll(&store, alloc, "log");
    defer alloc.free(data);
    try testing.expectEqualStrings(expected.items, data);
}

test "rewrite replaces and append continues from the new end" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try append(&store, "log", "aaaa\nbbbb\n");
    try rewrite(&store, "log", "bbbb\n");
    try append(&store, "log", "cccc\n");

    const data = try readAll(&store, alloc, "log");
    defer alloc.free(data);
    try testing.expectEqualStrings("bbbb\ncccc\n", data);
}

test "a strict append leaves no hole behind it" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try testing.expectEqual(Durability.strict, store.durability);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(alloc);

    for (0..64) |i| {
        const line = try std.fmt.allocPrint(alloc, "verdict {d} green\n", .{i});
        defer alloc.free(line);
        try append(&store, "log", line);
        try expected.appendSlice(alloc, line);

        // Every record that returned is on disk whole: the file is exactly as
        // long as what was written, with no zero-filled gap standing in for a
        // write that never landed.
        const so_far = try readAll(&store, alloc, "log");
        defer alloc.free(so_far);
        try testing.expectEqualStrings(expected.items, so_far);
        try testing.expect(std.mem.indexOfScalar(u8, so_far, 0) == null);
    }
}

test "both durability modes append the same bytes" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try append(&store, "log", "one\n");
    try appendFast(&store, "log", "two\n");
    store.durability = .fast;
    try append(&store, "log", "three\n");
    store.durability = .strict;
    try append(&store, "log", "four\n");

    const data = try readAll(&store, alloc, "log");
    defer alloc.free(data);
    try testing.expectEqualStrings("one\ntwo\nthree\nfour\n", data);
}
