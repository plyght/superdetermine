const std = @import("std");
const oid = @import("oid.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const heads_dir = "op-heads";

pub const Kind = enum(u8) {
    view = 'V',
    operation = 'O',
};

pub const RefState = struct {
    name: []const u8,
    tips: []const Oid,

    pub fn diverged(self: RefState) bool {
        return self.tips.len > 1;
    }
};

pub const View = struct {
    refs: []RefState,
    head_branch: []const u8,

    pub fn deinit(self: View, alloc: std.mem.Allocator) void {
        for (self.refs) |r| {
            alloc.free(r.name);
            alloc.free(r.tips);
        }
        alloc.free(self.refs);
        alloc.free(self.head_branch);
    }

    pub fn find(self: View, name: []const u8) ?RefState {
        for (self.refs) |r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        return null;
    }

    pub fn diverged(self: View) bool {
        for (self.refs) |r| {
            if (r.diverged()) return true;
        }
        return false;
    }

    pub fn encode(self: View, alloc: std.mem.Allocator) ![]u8 {
        var w = Writer.init(alloc);
        errdefer w.deinit();
        try w.byte(@intFromEnum(Kind.view));
        try w.putU16(@intCast(self.head_branch.len));
        try w.bytes(self.head_branch);
        try w.putU32(@intCast(self.refs.len));
        for (self.refs) |r| {
            try w.putU16(@intCast(r.name.len));
            try w.bytes(r.name);
            try w.putU32(@intCast(r.tips.len));
            for (r.tips) |t| try w.oid(t);
        }
        return w.finish();
    }

    pub fn decode(alloc: std.mem.Allocator, data: []const u8) !View {
        var r = Reader.init(data);
        try r.expectTag(.view);
        const hlen = try r.takeU16();
        const head_branch = try alloc.dupe(u8, try r.slice(hlen));
        errdefer alloc.free(head_branch);
        const n = try r.takeU32();
        var refs: std.ArrayList(RefState) = .empty;
        errdefer {
            for (refs.items) |e| {
                alloc.free(e.name);
                alloc.free(e.tips);
            }
            refs.deinit(alloc);
        }
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const nlen = try r.takeU16();
            const name = try alloc.dupe(u8, try r.slice(nlen));
            errdefer alloc.free(name);
            const tn = try r.takeU32();
            const tips = try alloc.alloc(Oid, tn);
            errdefer alloc.free(tips);
            for (tips) |*t| t.* = try r.oid();
            try refs.append(alloc, .{ .name = name, .tips = tips });
        }
        return .{ .refs = try refs.toOwnedSlice(alloc), .head_branch = head_branch };
    }

    pub fn hash(self: View, alloc: std.mem.Allocator) !Oid {
        const enc = try self.encode(alloc);
        defer alloc.free(enc);
        return Oid.ofBytes(enc);
    }
};

pub const Operation = struct {
    parents: []const Oid,
    view: Oid,
    kind: []const u8,
    timestamp: i64,
    metadata: []const u8,

    pub fn encode(self: Operation, alloc: std.mem.Allocator) ![]u8 {
        var w = Writer.init(alloc);
        errdefer w.deinit();
        try w.byte(@intFromEnum(Kind.operation));
        try w.putU32(@intCast(self.parents.len));
        for (self.parents) |p| try w.oid(p);
        try w.oid(self.view);
        try w.putU16(@intCast(self.kind.len));
        try w.bytes(self.kind);
        try w.putU64(@bitCast(self.timestamp));
        try w.putU32(@intCast(self.metadata.len));
        try w.bytes(self.metadata);
        return w.finish();
    }

    pub fn decode(alloc: std.mem.Allocator, data: []const u8) !Operation {
        var r = Reader.init(data);
        try r.expectTag(.operation);
        const np = try r.takeU32();
        const parents = try alloc.alloc(Oid, np);
        errdefer alloc.free(parents);
        for (parents) |*p| p.* = try r.oid();
        const view = try r.oid();
        const klen = try r.takeU16();
        const kind = try alloc.dupe(u8, try r.slice(klen));
        errdefer alloc.free(kind);
        const ts: i64 = @bitCast(try r.takeU64());
        const mlen = try r.takeU32();
        const metadata = try alloc.dupe(u8, try r.slice(mlen));
        return .{
            .parents = parents,
            .view = view,
            .kind = kind,
            .timestamp = ts,
            .metadata = metadata,
        };
    }
};

pub fn freeOperation(alloc: std.mem.Allocator, op: Operation) void {
    alloc.free(op.parents);
    alloc.free(op.kind);
    alloc.free(op.metadata);
}

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return std.mem.lessThan(u8, &a.bytes, &b.bytes);
}

fn refLessThan(_: void, a: RefState, b: RefState) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn sortView(v: *View) void {
    std.mem.sort(RefState, v.refs, {}, refLessThan);
    for (v.refs) |r| std.mem.sort(Oid, @constCast(r.tips), {}, oidLessThan);
}

fn containsOid(list: []const Oid, o: Oid) bool {
    for (list) |x| {
        if (x.eql(o)) return true;
    }
    return false;
}

// --- object i/o ---

pub fn writeView(store: *Store, view: View) !Oid {
    const enc = try view.encode(store.alloc);
    defer store.alloc.free(enc);
    return store.writeRaw(enc);
}

pub fn readView(store: *Store, alloc: std.mem.Allocator, o: Oid) !View {
    const enc = try store.readRaw(o);
    defer store.alloc.free(enc);
    return View.decode(alloc, enc);
}

pub fn writeOperation(store: *Store, op: Operation) !Oid {
    const enc = try op.encode(store.alloc);
    defer store.alloc.free(enc);
    return store.writeRaw(enc);
}

pub fn readOperation(store: *Store, alloc: std.mem.Allocator, o: Oid) !Operation {
    const enc = try store.readRaw(o);
    defer store.alloc.free(enc);
    return Operation.decode(alloc, enc);
}

// --- the head-file protocol ---

fn headPath(o: Oid, buf: []u8) []const u8 {
    var hex: [Oid.len * 2]u8 = undefined;
    _ = o.toHex(&hex);
    return std.fmt.bufPrint(buf, heads_dir ++ "/{s}", .{hex}) catch unreachable;
}

pub fn addHead(store: *Store, o: Oid) !void {
    var buf: [96]u8 = undefined;
    try store.root.createDirPath(store.io, heads_dir);
    try store.root.writeFile(store.io, .{ .sub_path = headPath(o, &buf), .data = "" });
}

pub fn removeHead(store: *Store, o: Oid) !void {
    var buf: [96]u8 = undefined;
    store.root.deleteFile(store.io, headPath(o, &buf)) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

pub fn heads(store: *Store, alloc: std.mem.Allocator) ![]Oid {
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(alloc);

    if (store.root.openDir(store.io, heads_dir, .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(store.io);
        var it = d.iterate();
        while (try it.next(store.io)) |entry| {
            if (entry.kind != .file) continue;
            const o = Oid.fromHex(entry.name) catch continue;
            try list.append(alloc, o);
        }
    } else |_| {}

    const out = try list.toOwnedSlice(alloc);
    std.mem.sort(Oid, out, {}, oidLessThan);
    return out;
}

pub fn commitWith(
    store: *Store,
    alloc: std.mem.Allocator,
    parents: []const Oid,
    view_oid: Oid,
    kind: []const u8,
    timestamp: i64,
    metadata: []const u8,
) !Oid {
    const sorted = try alloc.dupe(Oid, parents);
    defer alloc.free(sorted);
    std.mem.sort(Oid, sorted, {}, oidLessThan);

    const id = try writeOperation(store, .{
        .parents = sorted,
        .view = view_oid,
        .kind = kind,
        .timestamp = timestamp,
        .metadata = metadata,
    });

    try addHead(store, id);
    for (sorted) |p| {
        if (p.eql(id)) continue;
        try removeHead(store, p);
    }
    return id;
}

pub fn commit(
    store: *Store,
    alloc: std.mem.Allocator,
    kind: []const u8,
    timestamp: i64,
    metadata: []const u8,
) !Oid {
    var view = try snapshot(store, alloc);
    defer view.deinit(alloc);
    const view_oid = try writeView(store, view);

    const hs = try heads(store, alloc);
    defer alloc.free(hs);

    return commitWith(store, alloc, hs, view_oid, kind, timestamp, metadata);
}

// --- views of the on-disk refs ---

pub fn snapshot(store: *Store, alloc: std.mem.Allocator) !View {
    var refs: std.ArrayList(RefState) = .empty;
    errdefer {
        for (refs.items) |r| {
            alloc.free(r.name);
            alloc.free(r.tips);
        }
        refs.deinit(alloc);
    }

    if (store.root.openDir(store.io, "refs/heads", .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(store.io);
        var it = d.iterate();
        while (try it.next(store.io)) |entry| {
            if (entry.kind != .file) continue;
            const tip = store.readRef(entry.name) catch continue;
            const tips = try alloc.alloc(Oid, 1);
            errdefer alloc.free(tips);
            tips[0] = tip;
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            try refs.append(alloc, .{ .name = name, .tips = tips });
        }
    } else |_| {}

    var head_branch: []u8 = undefined;
    if (store.headBranch()) |h| {
        defer store.alloc.free(h);
        head_branch = try alloc.dupe(u8, h);
    } else |_| {
        head_branch = try alloc.dupe(u8, "");
    }

    var view = View{ .refs = try refs.toOwnedSlice(alloc), .head_branch = head_branch };
    sortView(&view);
    return view;
}

pub fn applyView(store: *Store, view: View) !void {
    for (view.refs) |r| {
        if (r.tips.len == 0) continue;
        try store.updateRef(r.name, r.tips[0]);
    }

    var stale: std.ArrayList([]u8) = .empty;
    defer {
        for (stale.items) |s| store.alloc.free(s);
        stale.deinit(store.alloc);
    }

    if (store.root.openDir(store.io, "refs/heads", .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(store.io);
        var it = d.iterate();
        while (try it.next(store.io)) |entry| {
            if (entry.kind != .file) continue;
            if (view.find(entry.name) != null) continue;
            try stale.append(store.alloc, try store.alloc.dupe(u8, entry.name));
        }
    } else |_| {}

    for (stale.items) |name| {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "refs/heads/{s}", .{name});
        store.root.deleteFile(store.io, p) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }

    if (view.head_branch.len > 0) try store.setHeadBranch(view.head_branch);
}

// --- the total merge ---

pub fn mergeViews(alloc: std.mem.Allocator, base: ?View, sides: []const View) !View {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(alloc);

    if (base) |b| {
        for (b.refs) |r| try appendName(alloc, &names, r.name);
    }
    for (sides) |s| {
        for (s.refs) |r| try appendName(alloc, &names, r.name);
    }
    std.mem.sort([]const u8, names.items, {}, strLessThan);

    var refs: std.ArrayList(RefState) = .empty;
    errdefer {
        for (refs.items) |r| {
            alloc.free(r.name);
            alloc.free(r.tips);
        }
        refs.deinit(alloc);
    }

    for (names.items) |name| {
        const base_tips: []const Oid = if (base) |b|
            (if (b.find(name)) |r| r.tips else &.{})
        else
            &.{};

        var tips: std.ArrayList(Oid) = .empty;
        errdefer tips.deinit(alloc);

        for (sides) |s| {
            const st: []const Oid = if (s.find(name)) |r| r.tips else &.{};
            for (st) |t| {
                if (containsOid(tips.items, t)) continue;
                if (containsOid(base_tips, t)) {
                    var in_all = true;
                    for (sides) |other| {
                        const ot: []const Oid = if (other.find(name)) |r| r.tips else &.{};
                        if (!containsOid(ot, t)) {
                            in_all = false;
                            break;
                        }
                    }
                    if (!in_all) continue;
                }
                try tips.append(alloc, t);
            }
        }

        if (tips.items.len == 0) {
            tips.deinit(alloc);
            continue;
        }
        const owned = try tips.toOwnedSlice(alloc);
        errdefer alloc.free(owned);
        try refs.append(alloc, .{ .name = try alloc.dupe(u8, name), .tips = owned });
    }

    const base_hb: []const u8 = if (base) |b| b.head_branch else "";
    var chosen: ?[]const u8 = null;
    for (sides) |s| {
        if (std.mem.eql(u8, s.head_branch, base_hb)) continue;
        if (chosen) |c| {
            if (std.mem.lessThan(u8, s.head_branch, c)) chosen = s.head_branch;
        } else {
            chosen = s.head_branch;
        }
    }

    var view = View{
        .refs = try refs.toOwnedSlice(alloc),
        .head_branch = try alloc.dupe(u8, chosen orelse base_hb),
    };
    sortView(&view);
    return view;
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn appendName(alloc: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) !void {
    for (list.items) |n| {
        if (std.mem.eql(u8, n, name)) return;
    }
    try list.append(alloc, name);
}

const OidSet = std.AutoHashMap([32]u8, void);

fn collectAncestors(store: *Store, alloc: std.mem.Allocator, root: Oid, set: *OidSet) !void {
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, root);

    while (stack.items.len > 0) {
        const o = stack.pop().?;
        if ((try set.getOrPut(o.bytes)).found_existing) continue;
        const op = readOperation(store, alloc, o) catch continue;
        defer freeOperation(alloc, op);
        for (op.parents) |p| try stack.append(alloc, p);
    }
}

pub fn bestAncestor(store: *Store, alloc: std.mem.Allocator, ids: []const Oid) !?Oid {
    if (ids.len == 0) return null;

    var acc = OidSet.init(alloc);
    defer acc.deinit();
    try collectAncestors(store, alloc, ids[0], &acc);

    for (ids[1..]) |id| {
        var other = OidSet.init(alloc);
        defer other.deinit();
        try collectAncestors(store, alloc, id, &other);

        var next = OidSet.init(alloc);
        errdefer next.deinit();
        var it = acc.keyIterator();
        while (it.next()) |k| {
            if (other.contains(k.*)) try next.put(k.*, {});
        }
        acc.deinit();
        acc = next;
    }

    var candidates: std.ArrayList(Oid) = .empty;
    defer candidates.deinit(alloc);
    var it = acc.keyIterator();
    while (it.next()) |k| try candidates.append(alloc, .{ .bytes = k.* });
    if (candidates.items.len == 0) return null;
    std.mem.sort(Oid, candidates.items, {}, oidLessThan);

    var strict = OidSet.init(alloc);
    defer strict.deinit();
    for (candidates.items) |c| {
        const op = readOperation(store, alloc, c) catch continue;
        defer freeOperation(alloc, op);
        for (op.parents) |p| try collectAncestors(store, alloc, p, &strict);
    }

    for (candidates.items) |c| {
        if (!strict.contains(c.bytes)) return c;
    }
    return candidates.items[0];
}

pub fn mergedView(store: *Store, alloc: std.mem.Allocator, ids: []const Oid) !View {
    var sides: std.ArrayList(View) = .empty;
    defer {
        for (sides.items) |v| v.deinit(alloc);
        sides.deinit(alloc);
    }

    for (ids) |id| {
        const op = readOperation(store, alloc, id) catch continue;
        defer freeOperation(alloc, op);
        const v = readView(store, alloc, op.view) catch continue;
        try sides.append(alloc, v);
    }
    if (sides.items.len == 0) return snapshot(store, alloc);

    var base: ?View = null;
    defer if (base) |b| b.deinit(alloc);
    if (try bestAncestor(store, alloc, ids)) |anc| {
        if (readOperation(store, alloc, anc)) |op| {
            defer freeOperation(alloc, op);
            base = readView(store, alloc, op.view) catch null;
        } else |_| {}
    }

    return mergeViews(alloc, base, sides.items);
}

pub fn currentView(store: *Store, alloc: std.mem.Allocator) !View {
    const hs = try heads(store, alloc);
    defer alloc.free(hs);
    if (hs.len == 0) return snapshot(store, alloc);
    if (hs.len == 1) {
        const op = readOperation(store, alloc, hs[0]) catch return snapshot(store, alloc);
        defer freeOperation(alloc, op);
        return readView(store, alloc, op.view) catch snapshot(store, alloc);
    }
    return mergedView(store, alloc, hs);
}

pub fn resolve(store: *Store, alloc: std.mem.Allocator) !?Oid {
    const hs = try heads(store, alloc);
    defer alloc.free(hs);
    if (hs.len < 2) return null;

    var view = try mergedView(store, alloc, hs);
    defer view.deinit(alloc);
    const view_oid = try writeView(store, view);

    var ts: i64 = 0;
    var seen = false;
    for (hs) |h| {
        const op = readOperation(store, alloc, h) catch continue;
        defer freeOperation(alloc, op);
        if (!seen or op.timestamp > ts) ts = op.timestamp;
        seen = true;
    }

    const id = try commitWith(store, alloc, hs, view_oid, "merge", ts, "");
    try applyView(store, view);
    return id;
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

// --- tests ---

const testing = std.testing;

const TestRef = struct {
    name: []const u8,
    tips: []const Oid,
};

fn buildView(alloc: std.mem.Allocator, head_branch: []const u8, refs: []const TestRef) !View {
    const out = try alloc.alloc(RefState, refs.len);
    errdefer alloc.free(out);
    for (out, refs) |*o, r| {
        o.* = .{ .name = try alloc.dupe(u8, r.name), .tips = try alloc.dupe(Oid, r.tips) };
    }
    var view = View{ .refs = out, .head_branch = try alloc.dupe(u8, head_branch) };
    sortView(&view);
    return view;
}

test "view and operation roundtrip" {
    const alloc = testing.allocator;

    const tips = [_]Oid{ Oid.ofBytes("x"), Oid.ofBytes("y") };
    var view = try buildView(alloc, "main", &.{
        .{ .name = "main", .tips = &.{Oid.ofBytes("a")} },
        .{ .name = "dev", .tips = &tips },
    });
    defer view.deinit(alloc);

    const enc = try view.encode(alloc);
    defer alloc.free(enc);
    var back = try View.decode(alloc, enc);
    defer back.deinit(alloc);

    try testing.expectEqualStrings("main", back.head_branch);
    try testing.expectEqual(@as(usize, 2), back.refs.len);
    try testing.expectEqualStrings("dev", back.refs[0].name);
    try testing.expect(back.refs[0].diverged());
    try testing.expect(back.diverged());

    const parents = [_]Oid{ Oid.ofBytes("p1"), Oid.ofBytes("p2") };
    const op = Operation{
        .parents = &parents,
        .view = Oid.ofBytes("v"),
        .kind = "snapshot",
        .timestamp = 1_700_000_000,
        .metadata = "main",
    };
    const oenc = try op.encode(alloc);
    defer alloc.free(oenc);
    const odec = try Operation.decode(alloc, oenc);
    defer freeOperation(alloc, odec);
    try testing.expectEqual(@as(usize, 2), odec.parents.len);
    try testing.expectEqualStrings("snapshot", odec.kind);
    try testing.expectEqualStrings("main", odec.metadata);
    try testing.expectEqual(@as(i64, 1_700_000_000), odec.timestamp);
    try testing.expect(odec.view.eql(op.view));
}

test "two divergent views merge into one deterministic view" {
    const alloc = testing.allocator;

    const a = Oid.ofBytes("a");
    const b = Oid.ofBytes("b");
    const c = Oid.ofBytes("c");

    var base = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{a} }});
    defer base.deinit(alloc);
    var left = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{b} }});
    defer left.deinit(alloc);
    var right = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{c} }});
    defer right.deinit(alloc);

    var merged = try mergeViews(alloc, base, &.{ left, right });
    defer merged.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), merged.refs.len);
    try testing.expectEqual(@as(usize, 2), merged.refs[0].tips.len);
    try testing.expect(merged.refs[0].diverged());
    try testing.expect(containsOid(merged.refs[0].tips, b));
    try testing.expect(containsOid(merged.refs[0].tips, c));
}

test "one-sided edits and deletes merge without divergence" {
    const alloc = testing.allocator;

    const a = Oid.ofBytes("a");
    const b = Oid.ofBytes("b");

    var base = try buildView(alloc, "main", &.{
        .{ .name = "main", .tips = &.{a} },
        .{ .name = "gone", .tips = &.{a} },
    });
    defer base.deinit(alloc);
    var left = try buildView(alloc, "main", &.{
        .{ .name = "main", .tips = &.{b} },
        .{ .name = "gone", .tips = &.{a} },
    });
    defer left.deinit(alloc);
    var right = try buildView(alloc, "main", &.{
        .{ .name = "main", .tips = &.{a} },
        .{ .name = "fresh", .tips = &.{b} },
    });
    defer right.deinit(alloc);

    var merged = try mergeViews(alloc, base, &.{ left, right });
    defer merged.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), merged.refs.len);
    try testing.expect(merged.find("gone") == null);
    try testing.expect(merged.find("main").?.tips[0].eql(b));
    try testing.expectEqual(@as(usize, 1), merged.find("main").?.tips.len);
    try testing.expect(merged.find("fresh").?.tips[0].eql(b));
}

test "merge is commutative down to the content hash" {
    const alloc = testing.allocator;

    const a = Oid.ofBytes("a");
    const b = Oid.ofBytes("b");
    const c = Oid.ofBytes("c");

    var base = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{a} }});
    defer base.deinit(alloc);
    var left = try buildView(alloc, "main", &.{
        .{ .name = "main", .tips = &.{b} },
        .{ .name = "left", .tips = &.{b} },
    });
    defer left.deinit(alloc);
    var right = try buildView(alloc, "dev", &.{
        .{ .name = "main", .tips = &.{c} },
        .{ .name = "right", .tips = &.{c} },
    });
    defer right.deinit(alloc);

    var one = try mergeViews(alloc, base, &.{ left, right });
    defer one.deinit(alloc);
    var two = try mergeViews(alloc, base, &.{ right, left });
    defer two.deinit(alloc);

    try testing.expect((try one.hash(alloc)).eql(try two.hash(alloc)));
    try testing.expectEqualStrings("dev", one.head_branch);
}

test "merge is idempotent" {
    const alloc = testing.allocator;

    const a = Oid.ofBytes("a");
    const b = Oid.ofBytes("b");
    const c = Oid.ofBytes("c");

    var base = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{a} }});
    defer base.deinit(alloc);
    var left = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{b} }});
    defer left.deinit(alloc);
    var right = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{c} }});
    defer right.deinit(alloc);

    var merged = try mergeViews(alloc, base, &.{ left, right });
    defer merged.deinit(alloc);

    var again = try mergeViews(alloc, merged, &.{merged});
    defer again.deinit(alloc);
    try testing.expect((try merged.hash(alloc)).eql(try again.hash(alloc)));

    var solo = try mergeViews(alloc, base, &.{merged});
    defer solo.deinit(alloc);
    try testing.expect((try merged.hash(alloc)).eql(try solo.hash(alloc)));
}

test "three-way divergence merges into three tips" {
    const alloc = testing.allocator;

    const a = Oid.ofBytes("a");
    const b = Oid.ofBytes("b");
    const c = Oid.ofBytes("c");
    const d = Oid.ofBytes("d");

    var base = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{a} }});
    defer base.deinit(alloc);
    var s1 = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{b} }});
    defer s1.deinit(alloc);
    var s2 = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{c} }});
    defer s2.deinit(alloc);
    var s3 = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{d} }});
    defer s3.deinit(alloc);

    var m1 = try mergeViews(alloc, base, &.{ s1, s2, s3 });
    defer m1.deinit(alloc);
    var m2 = try mergeViews(alloc, base, &.{ s3, s1, s2 });
    defer m2.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), m1.refs[0].tips.len);
    try testing.expect((try m1.hash(alloc)).eql(try m2.hash(alloc)));
}

test "merging with no base never fails" {
    const alloc = testing.allocator;

    var left = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{Oid.ofBytes("b")} }});
    defer left.deinit(alloc);
    var right = try buildView(alloc, "dev", &.{.{ .name = "dev", .tips = &.{Oid.ofBytes("c")} }});
    defer right.deinit(alloc);

    var merged = try mergeViews(alloc, null, &.{ left, right });
    defer merged.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), merged.refs.len);
    try testing.expectEqualStrings("dev", merged.head_branch);

    var empty = try mergeViews(alloc, null, &.{});
    defer empty.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), empty.refs.len);
}

test "zero-byte head files: concurrent writes leave two heads and the next read merges them" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = Oid.ofBytes("a");
    try store.updateRef("main", a);
    const base_op = try commit(&store, alloc, "snapshot", 1, "main");

    {
        const hs = try heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 1), hs.len);
        try testing.expect(hs[0].eql(base_op));
    }

    const b = Oid.ofBytes("b");
    const c = Oid.ofBytes("c");

    var left = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{b} }});
    defer left.deinit(alloc);
    var right = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{c} }});
    defer right.deinit(alloc);

    const left_view = try writeView(&store, left);
    const right_view = try writeView(&store, right);
    const left_op = try commitWith(&store, alloc, &.{base_op}, left_view, "snapshot", 2, "main");
    const right_op = try commitWith(&store, alloc, &.{base_op}, right_view, "snapshot", 3, "main");
    try testing.expect(!left_op.eql(right_op));

    {
        const hs = try heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 2), hs.len);
    }

    var head_files: [Oid.len * 2 + 16]u8 = undefined;
    const p = headPath(left_op, &head_files);
    const stat = try store.root.statFile(io, p, .{});
    try testing.expectEqual(@as(u64, 0), stat.size);

    var merged = try currentView(&store, alloc);
    defer merged.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), merged.find("main").?.tips.len);

    const merge_op = (try resolve(&store, alloc)).?;
    {
        const hs = try heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 1), hs.len);
        try testing.expect(hs[0].eql(merge_op));
    }

    try testing.expect((try resolve(&store, alloc)) == null);

    var after = try currentView(&store, alloc);
    defer after.deinit(alloc);
    try testing.expect((try after.hash(alloc)).eql(try merged.hash(alloc)));

    const tip = try store.readRef("main");
    try testing.expect(containsOid(merged.find("main").?.tips, tip));
}

test "the merge operation is deterministic across machines" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var ids: [2]Oid = undefined;
    var view_hashes: [2]Oid = undefined;

    for (0..2) |run| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try Store.init(io, alloc, tmp.dir);
        defer store.deinit();

        try store.updateRef("main", Oid.ofBytes("a"));
        const base_op = try commit(&store, alloc, "snapshot", 1, "main");

        var left = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{Oid.ofBytes("b")} }});
        defer left.deinit(alloc);
        var right = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{Oid.ofBytes("c")} }});
        defer right.deinit(alloc);

        const lv = try writeView(&store, left);
        const rv = try writeView(&store, right);

        if (run == 0) {
            _ = try commitWith(&store, alloc, &.{base_op}, lv, "snapshot", 2, "main");
            _ = try commitWith(&store, alloc, &.{base_op}, rv, "snapshot", 3, "main");
        } else {
            _ = try commitWith(&store, alloc, &.{base_op}, rv, "snapshot", 3, "main");
            _ = try commitWith(&store, alloc, &.{base_op}, lv, "snapshot", 2, "main");
        }

        ids[run] = (try resolve(&store, alloc)).?;
        var v = try currentView(&store, alloc);
        defer v.deinit(alloc);
        view_hashes[run] = try v.hash(alloc);
    }

    try testing.expect(ids[0].eql(ids[1]));
    try testing.expect(view_hashes[0].eql(view_hashes[1]));
}

test "a linear chain of operations keeps exactly one head" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var i: i64 = 0;
    while (i < 5) : (i += 1) {
        var buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&buf, "change {d}", .{i});
        try store.updateRef("main", Oid.ofBytes(name));
        _ = try commit(&store, alloc, "snapshot", i, "main");

        const hs = try heads(&store, alloc);
        defer alloc.free(hs);
        try testing.expectEqual(@as(usize, 1), hs.len);
    }

    var view = try currentView(&store, alloc);
    defer view.deinit(alloc);
    try testing.expect(!view.diverged());
    try testing.expect(view.find("main").?.tips[0].eql(Oid.ofBytes("change 4")));
    try testing.expect((try resolve(&store, alloc)) == null);
}

test "operations converge to the same view under shuffled application orders" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const n = 6;
    var expected: ?Oid = null;
    var seed: u64 = 0;

    while (seed < 12) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();

        var order: [n]usize = undefined;
        for (&order, 0..) |*o, i| o.* = i;
        rand.shuffle(usize, &order);
        const cut = rand.intRangeAtMost(usize, 1, n);

        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var store = try Store.init(io, alloc, tmp.dir);
        defer store.deinit();

        try store.updateRef("main", Oid.ofBytes("root"));
        const base_op = try commit(&store, alloc, "snapshot", 1, "main");

        for (order, 0..) |idx, step| {
            var buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&buf, "sibling {d}", .{idx});
            var v = try buildView(alloc, "main", &.{.{ .name = "main", .tips = &.{Oid.ofBytes(name)} }});
            defer v.deinit(alloc);
            const vid = try writeView(&store, v);
            _ = try commitWith(&store, alloc, &.{base_op}, vid, "snapshot", @intCast(2 + idx), "main");
            if (step + 1 == cut) _ = try resolve(&store, alloc);
        }

        _ = try resolve(&store, alloc);

        var final = try currentView(&store, alloc);
        defer final.deinit(alloc);
        const h = try final.hash(alloc);

        if (expected) |e| {
            if (!e.eql(h)) std.debug.print("convergence failed at seed {d} (cut {d})\n", .{ seed, cut });
            try testing.expect(e.eql(h));
        } else {
            expected = h;
        }
        try testing.expectEqual(@as(usize, n), final.find("main").?.tips.len);
    }
}
