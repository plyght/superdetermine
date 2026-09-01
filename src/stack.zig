const std = @import("std");
const history = @import("history.zig");
const merge = @import("merge.zig");
const Store = @import("store.zig").Store;
const Oid = @import("oid.zig").Oid;

pub const Error = error{
    InvalidName,
    NoSuchBranch,
    NoParent,
    Cycle,
    ParentNotAncestor,
};

pub const Relation = struct {
    child: []u8,
    parent: []u8,
};

pub fn freeRelations(alloc: std.mem.Allocator, relations: []Relation) void {
    for (relations) |r| {
        alloc.free(r.child);
        alloc.free(r.parent);
    }
    alloc.free(relations);
}

fn validName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfAny(u8, name, "\t\r\n") == null;
}

pub fn readAll(store: *Store, alloc: std.mem.Allocator) ![]Relation {
    const data = store.root.readFileAlloc(store.io, "stacks", alloc, .unlimited) catch |e| switch (e) {
        error.FileNotFound => return alloc.alloc(Relation, 0),
        else => return e,
    };
    defer alloc.free(data);

    var out: std.ArrayList(Relation) = .empty;
    errdefer {
        for (out.items) |r| {
            alloc.free(r.child);
            alloc.free(r.parent);
        }
        out.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const child = line[0..tab];
        const parent = line[tab + 1 ..];
        if (!validName(child) or !validName(parent)) continue;
        try out.append(alloc, .{
            .child = try alloc.dupe(u8, child),
            .parent = try alloc.dupe(u8, parent),
        });
    }
    return out.toOwnedSlice(alloc);
}

fn relationLessThan(_: void, a: Relation, b: Relation) bool {
    return std.mem.lessThan(u8, a.child, b.child);
}

fn writeAll(store: *Store, alloc: std.mem.Allocator, relations: []Relation) !void {
    std.sort.pdq(Relation, relations, {}, relationLessThan);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (relations) |r| try out.print(alloc, "{s}\t{s}\n", .{ r.child, r.parent });
    try store.writeFileAtomic("stacks", out.items);
}

fn relationIndex(relations: []const Relation, child: []const u8) ?usize {
    for (relations, 0..) |r, i| if (std.mem.eql(u8, r.child, child)) return i;
    return null;
}

pub fn parentOf(store: *Store, alloc: std.mem.Allocator, child: []const u8) ![]u8 {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    const i = relationIndex(relations, child) orelse return Error.NoParent;
    return alloc.dupe(u8, relations[i].parent);
}

pub fn setParent(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8) !void {
    if (!validName(child) or !validName(parent) or std.mem.eql(u8, child, parent)) return Error.InvalidName;
    if (!store.refExists(child) or !store.refExists(parent)) return Error.NoSuchBranch;

    var relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);

    var cursor = parent;
    var remaining = relations.len + 1;
    while (remaining > 0) : (remaining -= 1) {
        if (std.mem.eql(u8, cursor, child)) return Error.Cycle;
        const i = relationIndex(relations, cursor) orelse break;
        cursor = relations[i].parent;
    }
    if (remaining == 0) return Error.Cycle;

    if (relationIndex(relations, child)) |i| {
        alloc.free(relations[i].parent);
        relations[i].parent = try alloc.dupe(u8, parent);
    } else {
        const grown = try alloc.realloc(relations, relations.len + 1);
        relations = grown;
        relations[relations.len - 1] = .{
            .child = try alloc.dupe(u8, child),
            .parent = try alloc.dupe(u8, parent),
        };
    }
    try writeAll(store, alloc, relations);
}

pub fn clearParent(store: *Store, alloc: std.mem.Allocator, child: []const u8) !bool {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    _ = relationIndex(relations, child) orelse return false;
    var kept: std.ArrayList(Relation) = .empty;
    defer {
        for (kept.items) |r| {
            alloc.free(r.child);
            alloc.free(r.parent);
        }
        kept.deinit(alloc);
    }
    for (relations) |r| {
        if (std.mem.eql(u8, r.child, child)) continue;
        try kept.append(alloc, .{
            .child = try alloc.dupe(u8, r.child),
            .parent = try alloc.dupe(u8, r.parent),
        });
    }
    try writeAll(store, alloc, kept.items);
    return true;
}

pub fn childrenOf(store: *Store, alloc: std.mem.Allocator, parent: []const u8) ![][]u8 {
    const relations = try readAll(store, alloc);
    defer freeRelations(alloc, relations);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |name| alloc.free(name);
        out.deinit(alloc);
    }
    for (relations) |r| {
        if (std.mem.eql(u8, r.parent, parent)) try out.append(alloc, try alloc.dupe(u8, r.child));
    }
    std.mem.sort([]u8, out.items, {}, struct {
        fn lessThan(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return out.toOwnedSlice(alloc);
}

pub fn uniqueChanges(store: *Store, alloc: std.mem.Allocator, child: []const u8, parent: []const u8) ![]Oid {
    const child_tip = history.tipOf(store, child) catch return Error.NoSuchBranch;
    const parent_tip = history.tipOf(store, parent) catch return Error.NoSuchBranch;
    const common = try merge.commonAncestor(store, alloc, child_tip, parent_tip) orelse return Error.ParentNotAncestor;
    const chain = try history.chainOf(store, alloc, child_tip);
    errdefer alloc.free(chain);
    const at = history.indexOf(chain, common) orelse return Error.ParentNotAncestor;
    const count = chain.len - at - 1;
    const out = try alloc.alloc(Oid, count);
    @memcpy(out, chain[at + 1 ..]);
    alloc.free(chain);
    return out;
}

pub fn restack(store: *Store, alloc: std.mem.Allocator, child: []const u8, timestamp: i64) !history.Result {
    const parent = try parentOf(store, alloc, child);
    defer alloc.free(parent);
    const parent_tip = history.tipOf(store, parent) catch return Error.NoSuchBranch;
    return history.rebase(store, alloc, child, parent_tip, timestamp);
}

const testing = std.testing;
const object = @import("object.zig");

fn commit(store: *Store, tree: Oid, parents: []const Oid, id: u8) !Oid {
    return store.writeChange(.{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{id} ** 16,
        .timestamp = 1_700_000_000 + @as(i64, id),
        .tz_offset_min = 0,
        .author = "T <t@example.com>",
        .message = "change",
    });
}

test "stack relations are canonical and reject cycles" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = try store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
    const base = try commit(&store, tree, &.{}, 1);
    try store.updateRef("main", base);
    try store.updateRef("api", base);
    try store.updateRef("ui", base);

    try setParent(&store, alloc, "api", "main");
    try setParent(&store, alloc, "ui", "api");
    try testing.expectError(Error.Cycle, setParent(&store, alloc, "main", "ui"));

    const parent = try parentOf(&store, alloc, "ui");
    defer alloc.free(parent);
    try testing.expectEqualStrings("api", parent);

    const children = try childrenOf(&store, alloc, "api");
    defer {
        for (children) |name| alloc.free(name);
        alloc.free(children);
    }
    try testing.expectEqual(@as(usize, 1), children.len);
    try testing.expectEqualStrings("ui", children[0]);
}

test "stack unique changes begin after the shared parent" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const tree = try store.writeTree(.{ .entries = &[_]object.TreeEntry{} });
    const base = try commit(&store, tree, &.{}, 1);
    const api = try commit(&store, tree, &.{base}, 2);
    const ui = try commit(&store, tree, &.{api}, 3);
    try store.updateRef("main", base);
    try store.updateRef("feature", ui);

    const unique = try uniqueChanges(&store, alloc, "feature", "main");
    defer alloc.free(unique);
    try testing.expectEqual(@as(usize, 2), unique.len);
    try testing.expect(unique[0].eql(api));
    try testing.expect(unique[1].eql(ui));
}
