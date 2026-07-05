const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store_mod = @import("store.zig");
const diff = @import("diff.zig");
const provenance = @import("provenance.zig");
const Oid = oid.Oid;
const Store = store_mod.Store;

pub const Line = struct { lineno: usize, origin: Oid, text: []const u8 };

const Attr = struct { text: []u8, change: Oid };

fn contentAt(store: *Store, alloc: std.mem.Allocator, tree_oid: Oid, path: []const u8) ![]u8 {
    const tree = try store.readTree(tree_oid);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return store.readFileContent(e.blob);
    }
    return alloc.alloc(u8, 0);
}

fn buildHistory(store: *Store, alloc: std.mem.Allocator, tip: Oid) ![]Oid {
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(alloc);
    var cur = tip;
    while (true) {
        try list.append(alloc, cur);
        const change = try store.readChange(cur);
        defer object.freeChange(alloc, change);
        if (change.parents.len == 0) break;
        cur = change.parents[0];
    }
    const chain = try list.toOwnedSlice(alloc);
    std.mem.reverse(Oid, chain);
    return chain;
}

/// Attribute each line of `path` (as of HEAD) to the change that last introduced
/// it. Returns lines newest-state, with owned `text` dupes; free with `freeLines`.
pub fn compute(store: *Store, alloc: std.mem.Allocator, path: []const u8) ![]Line {
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return alloc.alloc(Line, 0);

    const tip = try store.readRef(branch);
    const history = try buildHistory(store, alloc, tip);
    defer alloc.free(history);

    var attrs: std.ArrayList(Attr) = .empty;
    defer {
        for (attrs.items) |a| alloc.free(a.text);
        attrs.deinit(alloc);
    }

    var prev_content = try alloc.alloc(u8, 0);
    defer alloc.free(prev_content);

    for (history) |change_oid| {
        const change = try store.readChange(change_oid);
        const tree = change.tree;
        object.freeChange(alloc, change);

        const cur_content = try contentAt(store, alloc, tree, path);
        errdefer alloc.free(cur_content);

        const ops = try diff.diffLines(alloc, prev_content, cur_content);
        defer alloc.free(ops);

        var next: std.ArrayList(Attr) = .empty;
        errdefer {
            for (next.items) |a| alloc.free(a.text);
            next.deinit(alloc);
        }

        var pi: usize = 0;
        for (ops) |op| switch (op.tag) {
            .keep => {
                try next.append(alloc, attrs.items[pi]);
                pi += 1;
            },
            .del => {
                alloc.free(attrs.items[pi].text);
                pi += 1;
            },
            .add => {
                const dup = try alloc.dupe(u8, op.text);
                try next.append(alloc, .{ .text = dup, .change = change_oid });
            },
        };

        attrs.deinit(alloc);
        attrs = next;

        alloc.free(prev_content);
        prev_content = cur_content;
    }

    var lines = try alloc.alloc(Line, attrs.items.len);
    errdefer alloc.free(lines);
    for (attrs.items, 0..) |a, i| {
        lines[i] = .{ .lineno = i + 1, .origin = a.change, .text = a.text };
    }
    // Ownership of texts transfers to the returned slice.
    attrs.clearRetainingCapacity();
    return lines;
}

pub fn freeLines(alloc: std.mem.Allocator, lines: []Line) void {
    for (lines) |l| alloc.free(l.text);
    alloc.free(lines);
}

fn headHasPath(store: *Store, alloc: std.mem.Allocator, path: []const u8) !bool {
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return false;
    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return true;
    }
    return false;
}

pub fn run(store: *Store, alloc: std.mem.Allocator, out: *std.Io.Writer, path: []const u8) !void {
    if (!try headHasPath(store, alloc, path)) {
        try out.print("{s} is not tracked in the current save\n", .{path});
        return;
    }

    const lines = try compute(store, alloc, path);
    defer freeLines(alloc, lines);

    for (lines) |line| {
        var hex: [Oid.len * 2]u8 = undefined;
        _ = line.origin.toHex(&hex);

        const change = try store.readChange(line.origin);
        defer object.freeChange(alloc, change);
        const author = std.mem.trim(u8, change.author, " \t");

        var agent_buf: [128]u8 = undefined;
        var agent: []const u8 = "";
        if (try provenance.get(store, alloc, line.origin)) |p| {
            defer provenance.freeEntry(alloc, p);
            if (p.agent.len != 0) {
                const n = @min(p.agent.len, agent_buf.len);
                @memcpy(agent_buf[0..n], p.agent[0..n]);
                agent = agent_buf[0..n];
            }
        }

        try out.print("{s} {s}\t{d}: {s}", .{ hex[0..10], author, line.lineno, line.text });
        if (agent.len != 0) try out.print(" (agent: {s})", .{agent});
        try out.writeAll("\n");
    }
}

// --- tests ---

const testing = std.testing;

test "blame attributes lines to introducing change" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "one\ntwo\n" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const workspace = @import("workspace.zig");
    const c1 = try workspace.snapshot(&store, work, "Nico <n@x>", "first", 1_700_000_000);

    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "one\ntwo\nthree\n" });
    const c2 = try workspace.snapshot(&store, work, "Nico <n@x>", "second", 1_700_000_100);

    const lines = try compute(&store, alloc, "a.txt");
    defer freeLines(alloc, lines);

    try testing.expectEqual(@as(usize, 3), lines.len);
    try testing.expect(lines[0].origin.eql(c1));
    try testing.expect(lines[1].origin.eql(c1));
    try testing.expect(lines[2].origin.eql(c2));
    try testing.expectEqualStrings("three", lines[2].text);
}
