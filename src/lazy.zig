const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const config = @import("config.zig");
const store_mod = @import("store.zig");
const net = @import("net.zig");
const share = @import("share.zig");
const apricot_bridge = @import("apricot_bridge.zig");
const mesh = @import("mesh.zig");
const sync = @import("sync.zig");
const wormhole = @import("wormhole.zig");
const branches = @import("branches.zig");
const moment = @import("moment.zig");
const applog = @import("applog.zig");
const gc = @import("gc.zig");
const ui = @import("ui.zig");
const Store = store_mod.Store;
const Oid = oid.Oid;

pub const thin_key = "store.thin";
pub const sources_key = "thin.sources";
pub const remote_key = "remote.origin.url";
pub const hydrated_log = "hydrated";
pub const exit_code: u8 = 12;

pub var report: ?*std.Io.Writer = null;

const OidSet = std.AutoHashMap([Oid.len]u8, void);

pub fn boolOf(raw: []const u8) bool {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    return std.ascii.eqlIgnoreCase(v, "true") or std.ascii.eqlIgnoreCase(v, "on") or
        std.ascii.eqlIgnoreCase(v, "yes") or std.mem.eql(u8, v, "1");
}

pub const Miss = struct {
    id: Oid = Oid.zero(),
    path_len: usize = 0,
    path_buf: [512]u8 = undefined,
    tried_len: usize = 0,
    tried_buf: [1024]u8 = undefined,

    pub fn path(self: *const Miss) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    pub fn tried(self: *const Miss) []const u8 {
        return self.tried_buf[0..self.tried_len];
    }

    fn setPath(self: *Miss, p: ?[]const u8) void {
        const v = p orelse "";
        const n = @min(v.len, self.path_buf.len);
        @memcpy(self.path_buf[0..n], v[0..n]);
        self.path_len = n;
    }

    fn setTried(self: *Miss, t: []const u8) void {
        const n = @min(t.len, self.tried_buf.len);
        @memcpy(self.tried_buf[0..n], t[0..n]);
        self.tried_len = n;
    }
};

pub var last_miss: Miss = .{};

pub const Filled = struct {
    objects: usize = 0,
    bytes: u64 = 0,
    sources: usize = 0,
    from_len: usize = 0,
    from_buf: [96]u8 = undefined,

    pub fn from(self: *const Filled) []const u8 {
        return self.from_buf[0..self.from_len];
    }

    fn credit(self: *Filled, label: []const u8, objects: usize, bytes: u64) void {
        if (objects == 0) return;
        self.objects += objects;
        self.bytes += bytes;
        self.sources += 1;
        const n = @min(label.len, self.from_buf.len);
        @memcpy(self.from_buf[0..n], label[0..n]);
        self.from_len = n;
    }
};

pub const Source = union(enum) {
    mesh: mesh.Addr,
    serve: struct { host: []const u8, port: u16 },
    local: []const u8,
    share: []const u8,
    carrier: []const u8,

    pub fn label(self: Source, buf: []u8) []const u8 {
        return switch (self) {
            .mesh => |a| std.fmt.bufPrint(buf, "mesh peer {d}.{d}.{d}.{d}:{d}", .{
                a.ip[0], a.ip[1], a.ip[2], a.ip[3], a.port,
            }) catch buf[0..0],
            .serve => |s| std.fmt.bufPrint(buf, "{s}:{d}", .{ s.host, s.port }) catch buf[0..0],
            .local, .share, .carrier => |p| p,
        };
    }
};

pub const Sources = struct {
    alloc: std.mem.Allocator,
    items: []Source = &.{},
    secret: ?[]u8 = null,
    text: ?[]u8 = null,
    remote: ?[]u8 = null,

    pub fn deinit(self: *Sources) void {
        self.alloc.free(self.items);
        if (self.secret) |s| self.alloc.free(s);
        if (self.text) |t| self.alloc.free(t);
        if (self.remote) |r| self.alloc.free(r);
    }
};

pub fn classify(entry: []const u8) Source {
    if (std.mem.indexOf(u8, entry, "#k=") != null) return .{ .share = entry };
    if (std.mem.startsWith(u8, entry, "http://") or std.mem.startsWith(u8, entry, "https://")) {
        return .{ .carrier = entry };
    }
    if (std.mem.lastIndexOfScalar(u8, entry, ':')) |c| {
        const host = entry[0..c];
        if (host.len != 0 and std.mem.indexOfScalar(u8, host, '/') == null) {
            if (std.fmt.parseInt(u16, entry[c + 1 ..], 10)) |port| {
                return .{ .serve = .{ .host = host, .port = port } };
            } else |_| {}
        }
    }
    return .{ .local = entry };
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

pub fn sources(st: *Store, alloc: std.mem.Allocator) !Sources {
    var out: Sources = .{ .alloc = alloc };
    errdefer out.deinit();
    var list: std.ArrayList(Source) = .empty;
    errdefer list.deinit(alloc);

    var mset = mesh.settings(st, alloc);
    if (mset.secret) |secret| {
        out.secret = secret;
        mset.secret = null;
        if (mesh.readRoster(st, alloc, nowMillis(st.io))) |roster| {
            defer roster.deinit(alloc);
            for (roster.peers, roster.addrs) |p, a| {
                if (std.mem.eql(u8, &p, &roster.me)) continue;
                const addr = a orelse continue;
                try list.append(alloc, .{ .mesh = addr });
            }
        }
    }
    mset.deinit(alloc);

    if (config.get(st, alloc, sources_key)) |maybe| {
        if (maybe) |text| {
            out.text = text;
            var it = std.mem.splitScalar(u8, text, ',');
            while (it.next()) |raw| {
                const entry = std.mem.trim(u8, raw, " \t\r\n");
                if (entry.len == 0) continue;
                try list.append(alloc, classify(entry));
            }
        }
    } else |_| {}

    if (config.get(st, alloc, remote_key)) |maybe| {
        if (maybe) |url| {
            if (url.len != 0 and (std.mem.startsWith(u8, url, "http://") or std.mem.startsWith(u8, url, "https://"))) {
                out.remote = url;
                try list.append(alloc, .{ .carrier = url });
            } else {
                alloc.free(url);
            }
        }
    } else |_| {}

    out.items = try list.toOwnedSlice(alloc);
    return out;
}

pub fn openLocal(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?Store {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{}) catch return null;
    if (dir.access(io, store_mod.dir_name, .{})) |_| {
        const inner = dir.openDir(io, store_mod.dir_name, .{}) catch {
            dir.close(io);
            return null;
        };
        dir.close(io);
        return .{ .io = io, .alloc = alloc, .root = inner };
    } else |_| {}
    dir.access(io, "objects", .{}) catch {
        dir.close(io);
        return null;
    };
    return .{ .io = io, .alloc = alloc, .root = dir };
}

fn fromLocal(st: *Store, path: []const u8, ids: []const Oid, filled: *Filled, label: []const u8) ?void {
    var src = openLocal(st.io, st.alloc, path) orelse return null;
    defer src.deinit();
    var objects: usize = 0;
    var bytes: u64 = 0;
    for (ids) |o| {
        if (st.has(o) or !src.has(o)) continue;
        const raw = src.readRawLocal(o) catch continue;
        defer st.alloc.free(raw);
        _ = st.writeRaw(raw) catch continue;
        objects += 1;
        bytes += raw.len;
    }
    filled.credit(label, objects, bytes);
}

fn fromMesh(st: *Store, secret: []const u8, addr: mesh.Addr, ids: []const Oid) !Filled {
    const io = st.io;
    const alloc = st.alloc;
    var address: std.Io.net.IpAddress = .{ .ip4 = .{ .bytes = addr.ip, .port = addr.port } };
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    const conn = wormhole.Conn.adopt(io, alloc, stream) catch |e| {
        stream.close(io);
        return e;
    };
    defer conn.destroy();
    const session = try wormhole.receiverHandshakeWith(io, conn.channel(), secret);
    var wire = sync.Wire.init(io, alloc, conn.channel(), session);

    var hex: [mesh.peer_id_len * 2]u8 = undefined;
    _ = mesh.peerHex(mesh.newPeerId(io), &hex);
    const rep = try sync.respond(st, alloc, &wire, .{ .peer = &hex, .now_ms = nowMillis(io), .thin = true });
    rep.deinit(alloc);

    const want = try mesh.encodeFrame(alloc, .{ .want = ids });
    defer alloc.free(want);
    try wire.sendBytes(want);

    var filled: Filled = .{};
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const raw = try wire.recvBytes(alloc);
        defer alloc.free(raw);
        const frame = try mesh.decodeFrame(alloc, raw);
        defer mesh.freeFrame(alloc, frame);
        switch (frame) {
            .give => |objects| {
                for (objects) |o| {
                    _ = st.writeRaw(o) catch continue;
                    filled.objects += 1;
                    filled.bytes += o.len;
                }
                break;
            },
            .ping => |v| {
                const pong = try mesh.encodeFrame(alloc, .{ .pong = v });
                defer alloc.free(pong);
                try wire.sendBytes(pong);
            },
            .bye => break,
            else => {},
        }
    }
    const bye = try mesh.encodeFrame(alloc, .bye);
    defer alloc.free(bye);
    wire.sendBytes(bye) catch {};
    return filled;
}

fn fetchFrom(st: *Store, src: Source, secret: ?[]const u8, ids: []const Oid, filled: *Filled) ?void {
    var lbuf: [96]u8 = undefined;
    const label = src.label(&lbuf);
    switch (src) {
        .serve => |s| {
            const got = net.fetchObjectsTcp(st, s.host, s.port, ids) catch return null;
            filled.credit(label, got.objects, got.bytes);
        },
        .local => |p| return fromLocal(st, p, ids, filled, label),
        .share => |source| {
            var opened = share.openSource(st.alloc, st.io, source) catch return null;
            defer opened.deinit(st.alloc);
            const got = share.fetchObjects(st, st.alloc, &opened, ids) catch return null;
            filled.credit(label, got.objects, got.bytes);
        },
        .carrier => |url| {
            const got = apricot_bridge.fetchObjects(st.alloc, st.io, url, st, ids, null) catch return null;
            filled.credit(label, got.objects, got.bytes);
        },
        .mesh => |addr| {
            const got = fromMesh(st, secret orelse return null, addr, ids) catch return null;
            filled.credit(label, got.objects, got.bytes);
        },
    }
}

fn noteHydrated(st: *Store, ids: []const Oid) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(st.alloc);
    for (ids) |o| {
        var hex: [Oid.len * 2]u8 = undefined;
        out.appendSlice(st.alloc, o.toHex(&hex)) catch return;
        out.append(st.alloc, '\n') catch return;
    }
    applog.appendFast(st, hydrated_log, out.items) catch {};
}

pub fn hydratedSet(st: *Store, alloc: std.mem.Allocator) !OidSet {
    var set = OidSet.init(alloc);
    errdefer set.deinit();
    const data = try applog.readAll(st, alloc, hydrated_log);
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len != Oid.len * 2) continue;
        const o = Oid.fromHex(t) catch continue;
        try set.put(o.bytes, {});
    }
    return set;
}

pub fn forgetHydrated(st: *Store) void {
    st.root.deleteFile(st.io, hydrated_log) catch {};
}

pub fn pruneHydrated(st: *Store, alloc: std.mem.Allocator) !void {
    var set = try hydratedSet(st, alloc);
    defer set.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var it = set.keyIterator();
    while (it.next()) |k| {
        const o = Oid{ .bytes = k.* };
        if (!st.has(o)) continue;
        var hex: [Oid.len * 2]u8 = undefined;
        try out.appendSlice(alloc, o.toHex(&hex));
        try out.append(alloc, '\n');
    }
    try applog.rewrite(st, hydrated_log, out.items);
}

fn printLine(f: Filled) void {
    const w = report orelse return;
    if (f.objects == 0) return;
    var buf: [32]u8 = undefined;
    const human = ui.humanBytes(f.bytes, &buf);
    if (f.sources > 1) {
        w.print("{s}hydrated {d} chunk{s} ({s}) from {d} sources{s}\n", .{
            ui.on(.dim), f.objects, if (f.objects == 1) "" else "s", human, f.sources, ui.off(),
        }) catch {};
    } else {
        w.print("{s}hydrated {d} chunk{s} ({s}) from {s}{s}\n", .{
            ui.on(.dim), f.objects, if (f.objects == 1) "" else "s", human, f.from(), ui.off(),
        }) catch {};
    }
    w.flush() catch {};
}

pub fn fetchIds(st: *Store, ids: []const Oid, path: ?[]const u8, tally: ?*Filled) !void {
    const alloc = st.alloc;
    var remaining: std.ArrayList(Oid) = .empty;
    defer remaining.deinit(alloc);
    for (ids) |o| {
        if (!st.has(o)) try remaining.append(alloc, o);
    }
    if (remaining.items.len == 0) return;

    var local: Filled = .{};
    const acc = tally orelse &local;
    var srcs = try sources(st, alloc);
    defer srcs.deinit();

    var arrived: std.ArrayList(Oid) = .empty;
    defer arrived.deinit(alloc);
    var tried_buf: [1024]u8 = undefined;
    var tw = std.Io.Writer.fixed(&tried_buf);

    for (srcs.items) |src| {
        if (remaining.items.len == 0) break;
        var lbuf: [96]u8 = undefined;
        const label = src.label(&lbuf);
        const reached = fetchFrom(st, src, srcs.secret, remaining.items, acc);
        var i: usize = 0;
        while (i < remaining.items.len) {
            if (st.has(remaining.items[i])) {
                try arrived.append(alloc, remaining.swapRemove(i));
            } else {
                i += 1;
            }
        }
        if (reached == null) {
            tw.print("{s} (unreachable), ", .{label}) catch {};
        } else if (remaining.items.len != 0) {
            tw.print("{s} (does not have it), ", .{label}) catch {};
        }
    }

    if (arrived.items.len != 0) noteHydrated(st, arrived.items);

    if (remaining.items.len != 0) {
        last_miss.id = remaining.items[0];
        last_miss.setPath(path);
        const t = tw.buffered();
        if (srcs.items.len == 0) {
            last_miss.setTried("no sources configured");
        } else {
            last_miss.setTried(std.mem.trimEnd(u8, t, ", "));
        }
        return Store.Error.ContentUnavailable;
    }
    if (tally == null) printLine(local);
}

pub fn ensureChunks(st: *Store, chunks: []const Oid, path: ?[]const u8) !void {
    if (!st.thin) return;
    var missing: std.ArrayList(Oid) = .empty;
    defer missing.deinit(st.alloc);
    for (chunks) |c| {
        if (!st.has(c)) try missing.append(st.alloc, c);
    }
    if (missing.items.len == 0) return;
    try fetchIds(st, missing.items, path, null);
}

pub fn ensureEntries(st: *Store, entries: []const object.TreeEntry) !void {
    if (!st.thin) return;
    const alloc = st.alloc;
    var tally: Filled = .{};
    var want: std.ArrayList(Oid) = .empty;
    defer want.deinit(alloc);
    var path: ?[]const u8 = null;

    for (entries) |e| {
        if (st.has(e.blob)) continue;
        try want.append(alloc, e.blob);
        if (path == null) path = e.path;
    }
    if (want.items.len != 0) try fetchIds(st, want.items, path, &tally);
    want.clearRetainingCapacity();
    path = null;

    var seen = OidSet.init(alloc);
    defer seen.deinit();
    for (entries) |e| {
        const raw = st.readRawLocal(e.blob) catch continue;
        defer alloc.free(raw);
        const blob = object.Blob.decode(alloc, raw) catch continue;
        defer alloc.free(blob.chunks);
        for (blob.chunks) |c| {
            if ((try seen.getOrPut(c.bytes)).found_existing) continue;
            if (st.has(c)) continue;
            try want.append(alloc, c);
            if (path == null) path = e.path;
        }
    }
    if (want.items.len != 0) try fetchIds(st, want.items, path, &tally);
    printLine(tally);
}

pub fn ensureTree(st: *Store, tree_oid: Oid) !void {
    if (!st.thin) return;
    const tree = try st.readTree(tree_oid);
    defer object.freeTree(st.alloc, tree);
    try ensureEntries(st, tree.entries);
}

pub const Referenced = struct {
    blobs: OidSet,
    chunks: OidSet,
    full_bytes: u64 = 0,

    pub fn deinit(self: *Referenced) void {
        self.blobs.deinit();
        self.chunks.deinit();
    }
};

fn blobsOfTree(st: *Store, alloc: std.mem.Allocator, tree_oid: Oid, blobs: *OidSet) !void {
    const raw = st.readRawLocal(tree_oid) catch return;
    defer alloc.free(raw);
    const tree = object.Tree.decode(alloc, raw) catch return;
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| try blobs.put(e.blob.bytes, {});
}

pub fn referenced(st: *Store, alloc: std.mem.Allocator) !Referenced {
    var out: Referenced = .{ .blobs = OidSet.init(alloc), .chunks = OidSet.init(alloc) };
    errdefer out.deinit();

    var seen = OidSet.init(alloc);
    defer seen.deinit();
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);

    const names = try branches.list(st, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    for (names) |n| {
        const tip = st.readRef(n) catch continue;
        try stack.append(alloc, tip);
    }
    while (stack.pop()) |o| {
        if (o.isZero()) continue;
        if ((try seen.getOrPut(o.bytes)).found_existing) continue;
        const raw = st.readRawLocal(o) catch continue;
        defer alloc.free(raw);
        const change = object.Change.decode(alloc, raw) catch continue;
        defer object.freeChange(alloc, change);
        for (change.parents) |p| try stack.append(alloc, p);
        if ((try seen.getOrPut(change.tree.bytes)).found_existing) continue;
        try blobsOfTree(st, alloc, change.tree, &out.blobs);
    }

    const captured = moment.reachableObjects(st, alloc) catch &[_]Oid{};
    defer alloc.free(captured);
    for (captured) |o| {
        if (out.blobs.contains(o.bytes)) continue;
        const raw = st.readRawLocal(o) catch continue;
        defer alloc.free(raw);
        if (raw.len == 0 or raw[0] != @intFromEnum(object.Kind.blob)) continue;
        const blob = object.Blob.decode(alloc, raw) catch continue;
        alloc.free(blob.chunks);
        try out.blobs.put(o.bytes, {});
    }

    var it = out.blobs.keyIterator();
    while (it.next()) |k| {
        const raw = st.readRawLocal(.{ .bytes = k.* }) catch continue;
        defer alloc.free(raw);
        const blob = object.Blob.decode(alloc, raw) catch continue;
        defer alloc.free(blob.chunks);
        out.full_bytes += blob.total_size;
        for (blob.chunks) |c| try out.chunks.put(c.bytes, {});
    }
    return out;
}

pub fn headChunks(st: *Store, alloc: std.mem.Allocator) !OidSet {
    var set = OidSet.init(alloc);
    errdefer set.deinit();
    const tree_oid = branches.headTree(st) orelse return set;
    const raw = st.readRawLocal(tree_oid) catch return set;
    defer alloc.free(raw);
    const tree = object.Tree.decode(alloc, raw) catch return set;
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        const braw = st.readRawLocal(e.blob) catch continue;
        defer alloc.free(braw);
        const blob = object.Blob.decode(alloc, braw) catch continue;
        defer alloc.free(blob.chunks);
        for (blob.chunks) |c| try set.put(c.bytes, {});
    }
    return set;
}

pub const Census = struct {
    thin: bool,
    blobs: usize,
    referenced: usize,
    held: usize,
    held_bytes: u64,
    full_bytes: u64,
};

pub fn census(st: *Store, alloc: std.mem.Allocator) !Census {
    var refd = try referenced(st, alloc);
    defer refd.deinit();
    var out: Census = .{
        .thin = st.thin,
        .blobs = refd.blobs.count(),
        .referenced = refd.chunks.count(),
        .held = 0,
        .held_bytes = 0,
        .full_bytes = refd.full_bytes,
    };
    var it = refd.chunks.keyIterator();
    while (it.next()) |k| {
        const size = st.sizeOnDisk(.{ .bytes = k.* }) orelse continue;
        out.held += 1;
        out.held_bytes += size;
    }
    return out;
}

pub const Dropped = struct {
    objects: usize = 0,
    bytes: u64 = 0,
};

pub fn thinOut(st: *Store, alloc: std.mem.Allocator) !Dropped {
    var refd = try referenced(st, alloc);
    defer refd.deinit();
    var keep = try headChunks(st, alloc);
    defer keep.deinit();
    var out: Dropped = .{};
    var it = refd.chunks.keyIterator();
    while (it.next()) |k| {
        if (keep.contains(k.*)) continue;
        const o = Oid{ .bytes = k.* };
        const size = st.sizeOnDisk(o) orelse continue;
        st.deleteRaw(o) catch continue;
        out.objects += 1;
        out.bytes += size;
    }
    return out;
}

pub fn confirmHeld(st: *Store, alloc: std.mem.Allocator, ids: []const Oid) ![]bool {
    const out = try alloc.alloc(bool, ids.len);
    errdefer alloc.free(out);
    @memset(out, false);
    if (ids.len == 0) return out;
    var srcs = try sources(st, alloc);
    defer srcs.deinit();
    for (srcs.items) |src| {
        switch (src) {
            .serve => |s| {
                const have = net.haveTcp(st.io, alloc, s.host, s.port, ids) catch continue;
                defer alloc.free(have);
                for (out, have) |*o, h| o.* = o.* or h;
            },
            .local => |p| {
                var from = openLocal(st.io, alloc, p) orelse continue;
                defer from.deinit();
                for (out, ids) |*o, id| o.* = o.* or from.has(id);
            },
            .share => |source| {
                var opened = share.openSource(alloc, st.io, source) catch continue;
                defer opened.deinit(alloc);
                for (out, ids) |*o, id| o.* = o.* or opened.holds(id);
            },
            .carrier => |url| {
                const have = try alloc.alloc(bool, ids.len);
                defer alloc.free(have);
                @memset(have, false);
                _ = apricot_bridge.fetchObjects(alloc, st.io, url, null, ids, have) catch continue;
                for (out, have) |*o, h| o.* = o.* or h;
            },
            .mesh => {},
        }
    }
    return out;
}

pub fn droppable(st: *Store, alloc: std.mem.Allocator, marked: *const std.AutoHashMap([32]u8, void)) !OidSet {
    var out = OidSet.init(alloc);
    errdefer out.deinit();
    if (branches.headTree(st) == null) return out;
    var refd = try referenced(st, alloc);
    defer refd.deinit();
    var keep = try headChunks(st, alloc);
    defer keep.deinit();
    var known = try hydratedSet(st, alloc);
    defer known.deinit();

    var unverified: std.ArrayList(Oid) = .empty;
    defer unverified.deinit(alloc);
    var it = refd.chunks.keyIterator();
    while (it.next()) |k| {
        if (keep.contains(k.*)) continue;
        if (!marked.contains(k.*)) continue;
        const o = Oid{ .bytes = k.* };
        if (!st.has(o)) continue;
        if (known.contains(k.*)) {
            try out.put(k.*, {});
        } else {
            try unverified.append(alloc, o);
        }
    }
    if (unverified.items.len != 0) {
        const held = try confirmHeld(st, alloc, unverified.items);
        defer alloc.free(held);
        for (unverified.items, held) |o, h| {
            if (h) try out.put(o.bytes, {});
        }
    }
    return out;
}

pub fn fetchAll(st: *Store, alloc: std.mem.Allocator) !Filled {
    var tally: Filled = .{};
    var refd = try referenced(st, alloc);
    defer refd.deinit();
    var missing: std.ArrayList(Oid) = .empty;
    defer missing.deinit(alloc);
    var it = refd.chunks.keyIterator();
    while (it.next()) |k| {
        const o = Oid{ .bytes = k.* };
        if (!st.has(o)) try missing.append(alloc, o);
    }
    if (missing.items.len != 0) try fetchIds(st, missing.items, null, &tally);
    return tally;
}

fn skippedName(name: []const u8) bool {
    if (std.mem.eql(u8, name, "objects") or std.mem.eql(u8, name, "index") or
        std.mem.eql(u8, name, "mesh") or std.mem.eql(u8, name, hydrated_log) or
        std.mem.eql(u8, name, "worktrees") or std.mem.eql(u8, name, "gitmirror") or
        std.mem.eql(u8, name, ".DS_Store")) return true;
    if (std.mem.startsWith(u8, name, "tmp-") or std.mem.startsWith(u8, name, "marker-")) return true;
    if (std.mem.startsWith(u8, name, "apricot-")) return true;
    return false;
}

pub fn copyRepo(from: *Store, to: *Store, thin: bool) !Filled {
    const io = from.io;
    const alloc = from.alloc;
    var filled: Filled = .{};

    var src = try from.root.openDir(io, ".", .{ .iterate = true });
    defer src.close(io);
    var walker = try src.walk(alloc);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        const top = if (std.mem.indexOfScalar(u8, entry.path, '/')) |c| entry.path[0..c] else entry.path;
        if (skippedName(top)) continue;
        switch (entry.kind) {
            .directory => try to.root.createDirPath(io, entry.path),
            .file => {
                if (std.fs.path.dirnamePosix(entry.path)) |d| try to.root.createDirPath(io, d);
                _ = try src.updateFile(io, entry.path, to.root, entry.path, .{});
            },
            else => {},
        }
    }

    var keep = try headChunks(from, alloc);
    defer keep.deinit();

    if (thin) {
        var marked = try gc.mark(from, alloc, true);
        defer marked.deinit();
        var chunks = OidSet.init(alloc);
        defer chunks.deinit();
        var it = marked.keyIterator();
        while (it.next()) |k| {
            const raw = from.readRawLocal(.{ .bytes = k.* }) catch continue;
            defer alloc.free(raw);
            if (raw.len == 0 or raw[0] != @intFromEnum(object.Kind.blob)) continue;
            const blob = object.Blob.decode(alloc, raw) catch continue;
            defer alloc.free(blob.chunks);
            for (blob.chunks) |c| try chunks.put(c.bytes, {});
        }
        var mit = marked.keyIterator();
        while (mit.next()) |k| {
            if (chunks.contains(k.*) and !keep.contains(k.*)) continue;
            try copyOne(from, to, .{ .bytes = k.* }, &filled);
        }
    } else {
        const ids = try sync.objectIds(from, alloc);
        defer alloc.free(ids);
        for (ids) |o| try copyOne(from, to, o, &filled);
    }
    to.gear = null;
    return filled;
}

fn copyOne(from: *Store, to: *Store, o: Oid, filled: *Filled) !void {
    if (to.has(o)) return;
    const raw = from.readRawLocal(o) catch return;
    defer from.alloc.free(raw);
    _ = try to.writeRaw(raw);
    filled.objects += 1;
    filled.bytes += raw.len;
}

const testing = std.testing;

const FileSpec = struct {
    path: []const u8,
    content: []const u8,
};

fn commitFiles(st: *Store, branch: []const u8, files: []const FileSpec, parents: []const Oid, seed: u8) !Oid {
    const alloc = st.alloc;
    const entries = try alloc.alloc(object.TreeEntry, files.len);
    defer alloc.free(entries);
    for (entries, files) |*e, f| {
        e.* = .{ .mode = .regular, .path = f.path, .blob = try st.writeFileContent(f.content) };
    }
    std.mem.sort(object.TreeEntry, entries, {}, object.Tree.lessThan);
    const tree = try st.writeTree(.{ .entries = entries });
    const change = try st.writeChange(.{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{seed} ** 16,
        .timestamp = 1_700_000_000 + @as(i64, seed),
        .tz_offset_min = 0,
        .author = "Tester <t@example.com>",
        .message = "seed",
    });
    try st.updateRef(branch, change);
    return change;
}

const old_files = [_]FileSpec{
    .{ .path = "docs/intro.md", .content = "# the old docs\n" ** 300 },
    .{ .path = "src/main.zig", .content = "fn main() void {}\n" ** 300 },
};

const new_files = [_]FileSpec{
    .{ .path = "docs/intro.md", .content = "# the new docs\n" ** 300 },
    .{ .path = "src/main.zig", .content = "fn main() void {}\n" ** 300 },
    .{ .path = "src/extra.zig", .content = "pub const extra = 1;\n" ** 300 },
};

fn seedSource(st: *Store) !struct { old: Oid, new: Oid } {
    const old = try commitFiles(st, "main", &old_files, &.{}, 1);
    try st.updateRef("old", old);
    const new = try commitFiles(st, "main", &new_files, &.{old}, 2);
    return .{ .old = old, .new = new };
}

fn chunksOfTree(st: *Store, alloc: std.mem.Allocator, change_oid: Oid) ![]Oid {
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(alloc);
    const change = try st.readChange(change_oid);
    defer object.freeChange(alloc, change);
    const tree = try st.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        const raw = try st.readRawLocal(e.blob);
        defer alloc.free(raw);
        const blob = try object.Blob.decode(alloc, raw);
        defer alloc.free(blob.chunks);
        try out.appendSlice(alloc, blob.chunks);
    }
    return out.toOwnedSlice(alloc);
}

fn holdsAll(st: *Store, ids: []const Oid) bool {
    for (ids) |o| if (!st.has(o)) return false;
    return true;
}

fn holdsNone(st: *Store, ids: []const Oid, except: []const Oid) bool {
    for (ids) |o| {
        var shared = false;
        for (except) |x| if (x.eql(o)) {
            shared = true;
        };
        if (!shared and st.has(o)) return false;
    }
    return true;
}

fn serveThread(st: *Store, port: u16) void {
    net.serve(st, port) catch {};
}

fn awaitServe(io: std.Io, alloc: std.mem.Allocator, port: u16) !void {
    var attempt: usize = 0;
    while (attempt < 200) : (attempt += 1) {
        if (net.headTcp(io, alloc, "127.0.0.1", port)) |h| {
            if (h) |b| alloc.free(b);
            return;
        } else |_| {}
        io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
    }
    return error.CouldNotConnect;
}

test "a thin clone from a served repo holds history and only the head tree's chunks" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const seeded = try seedSource(&src);

    const port: u16 = 47861;
    const th = try std.Thread.spawn(.{}, serveThread, .{ &src, port });
    th.detach();
    try awaitServe(io, alloc, port);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    const head = (try net.headTcp(io, alloc, "127.0.0.1", port)).?;
    defer alloc.free(head);
    try testing.expectEqualStrings("main", head);
    const tip = try net.fetchThinTcp(&dst, "127.0.0.1", port, head);
    try testing.expect(tip.eql(seeded.new));

    try testing.expect(dst.has(seeded.old));
    try testing.expect(dst.has(seeded.new));
    const new_chunks = try chunksOfTree(&src, alloc, seeded.new);
    defer alloc.free(new_chunks);
    const old_chunks = try chunksOfTree(&src, alloc, seeded.old);
    defer alloc.free(old_chunks);
    try testing.expect(holdsAll(&dst, new_chunks));
    try testing.expect(holdsNone(&dst, old_chunks, new_chunks));

    const c = try census(&dst, alloc);
    try testing.expect(c.held < c.referenced);
    try testing.expectEqual(new_chunks.len, c.held);
}

test "reading an older tree hydrates its chunks from the source and records them" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const seeded = try seedSource(&src);

    const port: u16 = 47862;
    const th = try std.Thread.spawn(.{}, serveThread, .{ &src, port });
    th.detach();
    try awaitServe(io, alloc, port);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    _ = try net.fetchThinTcp(&dst, "127.0.0.1", port, "main");
    try config.set(&dst, thin_key, "true");
    try config.set(&dst, sources_key, "127.0.0.1:47862");
    dst.thin = true;

    const old_chunks = try chunksOfTree(&src, alloc, seeded.old);
    defer alloc.free(old_chunks);
    try testing.expect(!holdsAll(&dst, old_chunks));

    const change = try dst.readChange(seeded.old);
    defer object.freeChange(alloc, change);
    try ensureTree(&dst, change.tree);
    try testing.expect(holdsAll(&dst, old_chunks));

    const tree = try dst.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        const content = try dst.readFileContent(e.blob);
        defer alloc.free(content);
        if (std.mem.eql(u8, e.path, "docs/intro.md")) {
            try testing.expect(std.mem.startsWith(u8, content, "# the old docs"));
        }
    }

    var known = try hydratedSet(&dst, alloc);
    defer known.deinit();
    var recorded: usize = 0;
    for (old_chunks) |c| {
        if (known.contains(c.bytes)) recorded += 1;
    }
    try testing.expect(recorded > 0);
}

test "a miss with no reachable source fails with one named error, not a hang" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const seeded = try seedSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    _ = try copyRepo(&src, &dst, true);
    try config.set(&dst, thin_key, "true");
    try config.set(&dst, sources_key, "127.0.0.1:1");
    dst.thin = true;

    const change = try dst.readChange(seeded.old);
    defer object.freeChange(alloc, change);
    try testing.expectError(Store.Error.ContentUnavailable, ensureTree(&dst, change.tree));
    try testing.expectEqualStrings("docs/intro.md", last_miss.path());
    try testing.expect(std.mem.indexOf(u8, last_miss.tried(), "127.0.0.1:1 (unreachable)") != null);

    const tree = try dst.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    try testing.expectError(Store.Error.ContentUnavailable, dst.readFileContent(tree.entries[0].blob));

    try config.set(&dst, sources_key, "");
    try testing.expectError(Store.Error.ContentUnavailable, ensureTree(&dst, change.tree));
    try testing.expectEqualStrings("no sources configured", last_miss.tried());
}

test "copyRepo thin keeps every manifest and drops only chunks outside the head tree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const seeded = try seedSource(&src);
    try config.set(&src, "user.name", "Ada");

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    _ = try copyRepo(&src, &dst, true);

    try testing.expect((try dst.readRef("main")).eql(seeded.new));
    try testing.expect((try dst.readRef("old")).eql(seeded.old));
    const name = try config.getLocal(&dst, alloc, "user.name");
    defer if (name) |n| alloc.free(n);
    try testing.expectEqualStrings("Ada", name.?);

    var refd = try referenced(&src, alloc);
    defer refd.deinit();
    var it = refd.blobs.keyIterator();
    while (it.next()) |k| try testing.expect(dst.has(.{ .bytes = k.* }));

    const old_chunks = try chunksOfTree(&src, alloc, seeded.old);
    defer alloc.free(old_chunks);
    const new_chunks = try chunksOfTree(&src, alloc, seeded.new);
    defer alloc.free(new_chunks);
    try testing.expect(holdsAll(&dst, new_chunks));
    try testing.expect(holdsNone(&dst, old_chunks, new_chunks));

    try config.set(&dst, thin_key, "true");
    try config.set(&dst, sources_key, "");
    dst.thin = true;
    const src_root = try tmp_a.dir.realPathFileAlloc(io, store_mod.dir_name, alloc);
    defer alloc.free(src_root);
    try config.set(&dst, sources_key, src_root);
    const got = try fetchAll(&dst, alloc);
    try testing.expect(got.objects > 0);
    try testing.expect(holdsAll(&dst, old_chunks));
    const c = try census(&dst, alloc);
    try testing.expectEqual(c.referenced, c.held);
}

test "gc in a thin store drops only chunks a source holds and keeps every manifest" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const seeded = try seedSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    _ = try copyRepo(&src, &dst, true);
    const src_root = try tmp_a.dir.realPathFileAlloc(io, store_mod.dir_name, alloc);
    defer alloc.free(src_root);
    try config.set(&dst, thin_key, "true");
    try config.set(&dst, sources_key, src_root);
    dst.thin = true;

    const old_chunks = try chunksOfTree(&src, alloc, seeded.old);
    defer alloc.free(old_chunks);
    const new_chunks = try chunksOfTree(&src, alloc, seeded.new);
    defer alloc.free(new_chunks);

    const change = try dst.readChange(seeded.old);
    defer object.freeChange(alloc, change);
    try ensureTree(&dst, change.tree);
    try testing.expect(holdsAll(&dst, old_chunks));

    const local_only = try dst.writeFileContent("only ever written here\n" ** 200);
    const entries = [_]object.TreeEntry{.{ .mode = .regular, .path = "mine.txt", .blob = local_only }};
    const tree = try dst.writeTree(.{ .entries = &entries });
    const mine = try dst.writeChange(.{
        .tree = tree,
        .parents = &.{seeded.new},
        .change_id = [_]u8{7} ** 16,
        .timestamp = 1_700_000_100,
        .tz_offset_min = 0,
        .author = "t",
        .message = "mine",
    });
    try dst.updateRef("mine", mine);
    const mine_chunks = try chunksOfTree(&dst, alloc, mine);
    defer alloc.free(mine_chunks);

    const stats = try gc.collect(&dst, alloc, false);
    try testing.expect(stats.thinned > 0);
    try testing.expect(holdsAll(&dst, new_chunks));
    try testing.expect(holdsAll(&dst, mine_chunks));
    try testing.expect(holdsNone(&dst, old_chunks, new_chunks));
    try testing.expect(dst.has(seeded.old));
    var refd = try referenced(&dst, alloc);
    defer refd.deinit();
    var it = refd.blobs.keyIterator();
    while (it.next()) |k| try testing.expect(dst.has(.{ .bytes = k.* }));

    var known = try hydratedSet(&dst, alloc);
    defer known.deinit();
    for (old_chunks) |c| try testing.expect(!known.contains(c.bytes));

    const c = try census(&dst, alloc);
    try testing.expect(c.held < c.referenced);
    try ensureTree(&dst, change.tree);
    try testing.expect(holdsAll(&dst, old_chunks));
}

test "source entries are told apart by shape" {
    try testing.expect(classify("127.0.0.1:7777") == .serve);
    try testing.expectEqual(@as(u16, 7777), classify("127.0.0.1:7777").serve.port);
    try testing.expect(classify("/tmp/repo") == .local);
    try testing.expect(classify("/tmp/repo:notaport") == .local);
    try testing.expect(classify("https://github.com/plyght/superdetermine.git") == .carrier);
    try testing.expect(classify("https://x.example/r/abcdabcd#k=AAAA") == .share);
    try testing.expect(classify("/tmp/repo.grb#k=AAAA") == .share);
}
