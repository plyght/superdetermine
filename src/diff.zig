const std = @import("std");
const ui = @import("ui.zig");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store_mod = @import("store.zig");
const Oid = oid.Oid;
const Store = store_mod.Store;

/// A single line-level edit. `text` points INTO the original `old`/`new`
/// buffers, so callers free only the returned slice, never the line texts.
pub const LineOp = struct {
    tag: enum { keep, del, add },
    text: []const u8,
};

const max_lines = 20000;

/// Split `buf` into lines on '\n'. A trailing newline does not yield a final
/// empty line; a buffer without a trailing newline keeps its last partial line.
fn splitLines(alloc: std.mem.Allocator, buf: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\n') {
            try list.append(alloc, buf[start..i]);
            start = i + 1;
        }
    }
    if (start < buf.len) try list.append(alloc, buf[start..]);
    return list.toOwnedSlice(alloc);
}

/// Line-level diff via an O(N*M) LCS dynamic program. Falls back to a
/// whole-file replace (all dels then all adds) when either side is huge.
pub fn diffLines(alloc: std.mem.Allocator, old: []const u8, new: []const u8) ![]LineOp {
    const a = try splitLines(alloc, old);
    defer alloc.free(a);
    const b = try splitLines(alloc, new);
    defer alloc.free(b);

    var ops: std.ArrayList(LineOp) = .empty;
    errdefer ops.deinit(alloc);

    if (a.len > max_lines or b.len > max_lines) {
        for (a) |l| try ops.append(alloc, .{ .tag = .del, .text = l });
        for (b) |l| try ops.append(alloc, .{ .tag = .add, .text = l });
        return ops.toOwnedSlice(alloc);
    }

    const n = a.len;
    const m = b.len;
    // dp[i][j] = LCS length of a[i..] and b[j..]; row-major (n+1)*(m+1).
    const dp = try alloc.alloc(usize, (n + 1) * (m + 1));
    defer alloc.free(dp);
    const stride = m + 1;
    @memset(dp, 0);
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        var j: usize = m;
        while (j > 0) {
            j -= 1;
            if (std.mem.eql(u8, a[i], b[j])) {
                dp[i * stride + j] = dp[(i + 1) * stride + (j + 1)] + 1;
            } else {
                const down = dp[(i + 1) * stride + j];
                const right = dp[i * stride + (j + 1)];
                dp[i * stride + j] = if (down >= right) down else right;
            }
        }
    }

    i = 0;
    var j: usize = 0;
    while (i < n and j < m) {
        if (std.mem.eql(u8, a[i], b[j])) {
            try ops.append(alloc, .{ .tag = .keep, .text = a[i] });
            i += 1;
            j += 1;
        } else if (dp[(i + 1) * stride + j] >= dp[i * stride + (j + 1)]) {
            try ops.append(alloc, .{ .tag = .del, .text = a[i] });
            i += 1;
        } else {
            try ops.append(alloc, .{ .tag = .add, .text = b[j] });
            j += 1;
        }
    }
    while (i < n) : (i += 1) try ops.append(alloc, .{ .tag = .del, .text = a[i] });
    while (j < m) : (j += 1) try ops.append(alloc, .{ .tag = .add, .text = b[j] });

    return ops.toOwnedSlice(alloc);
}

/// Emit a git-ish unified diff. Real `@@` hunks: runs of unchanged context
/// beyond 3 lines are collapsed, and each surviving change group gets an
/// `@@ -oldstart,oldcount +newstart,newcount @@` header.
pub fn writeUnified(w: *std.Io.Writer, path: []const u8, ops: []const LineOp) !void {
    try w.print("{s}--- a/{s}{s}\n", .{ ui.on(.bold), path, ui.off() });
    try w.print("{s}+++ b/{s}{s}\n", .{ ui.on(.bold), path, ui.off() });

    const context = 3;
    // Mark which ops belong to a hunk (a change, or context within `context`
    // lines of a change).
    const in_hunk = try std.heap.page_allocator.alloc(bool, ops.len);
    defer std.heap.page_allocator.free(in_hunk);
    @memset(in_hunk, false);
    for (ops, 0..) |op, idx| {
        if (op.tag == .keep) continue;
        const lo = if (idx >= context) idx - context else 0;
        const hi = @min(ops.len, idx + context + 1);
        var k = lo;
        while (k < hi) : (k += 1) in_hunk[k] = true;
    }

    var idx: usize = 0;
    // 1-based line numbers in old/new files.
    var old_line: usize = 1;
    var new_line: usize = 1;
    while (idx < ops.len) {
        if (!in_hunk[idx]) {
            switch (ops[idx].tag) {
                .keep => {
                    old_line += 1;
                    new_line += 1;
                },
                .del => old_line += 1,
                .add => new_line += 1,
            }
            idx += 1;
            continue;
        }
        // Gather one contiguous hunk.
        const start = idx;
        var old_count: usize = 0;
        var new_count: usize = 0;
        var end = idx;
        while (end < ops.len and in_hunk[end]) : (end += 1) {
            switch (ops[end].tag) {
                .keep => {
                    old_count += 1;
                    new_count += 1;
                },
                .del => old_count += 1,
                .add => new_count += 1,
            }
        }
        const old_start = if (old_count == 0) old_line - 1 else old_line;
        const new_start = if (new_count == 0) new_line - 1 else new_line;
        try w.print("{s}@@ -{d},{d} +{d},{d} @@{s}\n", .{ ui.on(.cyan), old_start, old_count, new_start, new_count, ui.off() });
        var h = start;
        while (h < end) : (h += 1) {
            const op = ops[h];
            switch (op.tag) {
                .keep => {
                    try w.print(" {s}\n", .{op.text});
                    old_line += 1;
                    new_line += 1;
                },
                .del => {
                    try w.print("{s}-{s}{s}\n", .{ ui.on(.red), op.text, ui.off() });
                    old_line += 1;
                },
                .add => {
                    try w.print("{s}+{s}{s}\n", .{ ui.on(.green), op.text, ui.off() });
                    new_line += 1;
                },
            }
        }
        idx = end;
    }
}

pub const FileChange = struct {
    path: []const u8,
    kind: enum { added, modified, deleted },
};

/// Compare two stored trees by path + blob Oid. `null` means the empty tree.
/// Caller frees each `path` and the returned slice via `freeChanges`.
pub fn diffTrees(store: *Store, alloc: std.mem.Allocator, old_tree: ?Oid, new_tree: ?Oid) ![]FileChange {
    var old = object.Tree{ .entries = &.{} };
    var have_old = false;
    if (old_tree) |o| {
        old = try store.readTree(o);
        have_old = true;
    }
    defer if (have_old) object.freeTree(alloc, old);

    var new = object.Tree{ .entries = &.{} };
    var have_new = false;
    if (new_tree) |o| {
        new = try store.readTree(o);
        have_new = true;
    }
    defer if (have_new) object.freeTree(alloc, new);

    var changes: std.ArrayList(FileChange) = .empty;
    errdefer {
        for (changes.items) |c| alloc.free(c.path);
        changes.deinit(alloc);
    }

    // Entries are stored sorted by path; merge-walk both sides.
    var i: usize = 0;
    var j: usize = 0;
    while (i < old.entries.len and j < new.entries.len) {
        const oe = old.entries[i];
        const ne = new.entries[j];
        const c = std.mem.order(u8, oe.path, ne.path);
        switch (c) {
            .lt => {
                try changes.append(alloc, .{ .path = try alloc.dupe(u8, oe.path), .kind = .deleted });
                i += 1;
            },
            .gt => {
                try changes.append(alloc, .{ .path = try alloc.dupe(u8, ne.path), .kind = .added });
                j += 1;
            },
            .eq => {
                if (!oe.blob.eql(ne.blob)) {
                    try changes.append(alloc, .{ .path = try alloc.dupe(u8, oe.path), .kind = .modified });
                }
                i += 1;
                j += 1;
            },
        }
    }
    while (i < old.entries.len) : (i += 1) {
        try changes.append(alloc, .{ .path = try alloc.dupe(u8, old.entries[i].path), .kind = .deleted });
    }
    while (j < new.entries.len) : (j += 1) {
        try changes.append(alloc, .{ .path = try alloc.dupe(u8, new.entries[j].path), .kind = .added });
    }

    return changes.toOwnedSlice(alloc);
}

pub fn freeChanges(alloc: std.mem.Allocator, changes: []FileChange) void {
    for (changes) |c| alloc.free(c.path);
    alloc.free(changes);
}

fn looksBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, 0) != null;
}

/// Look up a path's blob Oid in a stored tree, or null if absent/empty tree.
fn blobFor(store: *Store, alloc: std.mem.Allocator, tree: ?Oid, path: []const u8) !?Oid {
    const t = tree orelse return null;
    const loaded = try store.readTree(t);
    defer object.freeTree(alloc, loaded);
    for (loaded.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.blob;
    }
    return null;
}

/// For each changed file between two trees, print a unified line diff.
pub fn writeTreeDiff(store: *Store, alloc: std.mem.Allocator, w: *std.Io.Writer, old_tree: ?Oid, new_tree: ?Oid) !void {
    const changes = try diffTrees(store, alloc, old_tree, new_tree);
    defer freeChanges(alloc, changes);

    for (changes) |c| {
        const old_blob = try blobFor(store, alloc, old_tree, c.path);
        const new_blob = try blobFor(store, alloc, new_tree, c.path);

        const old_data: []u8 = if (old_blob) |o| try store.readFileContent(o) else try alloc.alloc(u8, 0);
        defer alloc.free(old_data);
        const new_data: []u8 = if (new_blob) |o| try store.readFileContent(o) else try alloc.alloc(u8, 0);
        defer alloc.free(new_data);

        if (looksBinary(old_data) or looksBinary(new_data)) {
            try w.print("Binary file {s} differs\n", .{c.path});
            continue;
        }

        const ops = try diffLines(alloc, old_data, new_data);
        defer alloc.free(ops);
        try writeUnified(w, c.path, ops);
    }
}

// --- tests ---

const testing = std.testing;

test "diffLines insert delete modify" {
    const alloc = testing.allocator;
    const old = "alpha\nbeta\ngamma\n";
    const new = "alpha\nBETA\ngamma\ndelta\n";
    const ops = try diffLines(alloc, old, new);
    defer alloc.free(ops);

    // Expect: keep alpha, (del beta / add BETA), keep gamma, add delta.
    try testing.expectEqual(@as(usize, 5), ops.len);
    try testing.expect(ops[0].tag == .keep);
    try testing.expectEqualStrings("alpha", ops[0].text);

    var dels: usize = 0;
    var adds: usize = 0;
    var keeps: usize = 0;
    for (ops) |op| switch (op.tag) {
        .del => dels += 1,
        .add => adds += 1,
        .keep => keeps += 1,
    };
    try testing.expectEqual(@as(usize, 1), dels);
    try testing.expectEqual(@as(usize, 2), adds);
    try testing.expectEqual(@as(usize, 2), keeps);
}

test "diffLines identical is all keep" {
    const alloc = testing.allocator;
    const ops = try diffLines(alloc, "a\nb\nc\n", "a\nb\nc\n");
    defer alloc.free(ops);
    try testing.expectEqual(@as(usize, 3), ops.len);
    for (ops) |op| try testing.expect(op.tag == .keep);
}

test "diffTrees reports modified file" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const a1 = try s.writeFileContent("one\ntwo\n");
    const shared = try s.writeFileContent("keep me\n");

    const entries1 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "file.txt", .blob = a1 },
        .{ .mode = .regular, .path = "same.txt", .blob = shared },
    };
    const t1 = try s.writeTree(.{ .entries = &entries1 });

    const a2 = try s.writeFileContent("one\nTWO\nthree\n");
    const entries2 = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "file.txt", .blob = a2 },
        .{ .mode = .regular, .path = "same.txt", .blob = shared },
    };
    const t2 = try s.writeTree(.{ .entries = &entries2 });

    const changes = try diffTrees(&s, alloc, t1, t2);
    defer freeChanges(alloc, changes);

    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("file.txt", changes[0].path);
    try testing.expect(changes[0].kind == .modified);
}

test "diffTrees added and deleted vs empty" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const blob = try s.writeFileContent("hello\n");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "new.txt", .blob = blob },
    };
    const t = try s.writeTree(.{ .entries = &entries });

    const added = try diffTrees(&s, alloc, null, t);
    defer freeChanges(alloc, added);
    try testing.expectEqual(@as(usize, 1), added.len);
    try testing.expect(added[0].kind == .added);

    const deleted = try diffTrees(&s, alloc, t, null);
    defer freeChanges(alloc, deleted);
    try testing.expectEqual(@as(usize, 1), deleted.len);
    try testing.expect(deleted[0].kind == .deleted);
}
