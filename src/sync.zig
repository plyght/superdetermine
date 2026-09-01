const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const opdag = @import("opdag.zig");
const live = @import("live.zig");
const wormhole = @import("wormhole.zig");
const discovery = @import("discovery.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const Oid = oid.Oid;

const net = std.Io.net;
const Blake3 = std.crypto.hash.Blake3;

/// Peer-to-peer repository sync: two machines that can reach each other end up
/// holding the same history, with no server in the middle.
///
/// The shape is a have/want negotiation over the wormhole channel. Each end
/// says what object ids it holds, the other end subtracts that set from the
/// closure of its own roots and sends the remainder. Because every object is
/// content-addressed and immutable, set subtraction is the whole algorithm:
/// there is no delta to compute, no rebase to agree on, and no state to keep
/// between runs. A transfer that dies halfway leaves the receiver holding a
/// prefix of the objects and nothing else, so the retry's inventory is simply
/// larger and the send set is simply smaller. Resumability is not a feature
/// here, it is a consequence.
///
/// Convergence is the op-log's job, not this file's. Both ends adopt each
/// other's op-heads and then run the same total `mergeViews`, which is
/// deterministic down to the content hash, so both machines land on the same
/// merge operation id and the same view without exchanging another byte. A
/// sync that left the two ends disagreeing would be a bug, and the test for it
/// compares view hashes rather than anything softer.
///
/// This is not a CRDT and does not become one. The live phase that follows the
/// transfer keeps `live.zig`'s one-writer rule exactly as written: authority is
/// held by one end, transferred by an explicit handoff, and a follower that
/// tries to write is refused by the type system rather than by etiquette.
pub const protocol_version: u16 = 1;

const message_key_domain = "gr-sync-v1 message";

pub const Error = error{
    ProtocolError,
    VersionMismatch,
    ScopeMismatch,
    TooManyRounds,
    NoPortAvailable,
};

pub const Options = struct {
    /// A path prefix limiting which blobs travel, or empty for the whole tree.
    scope: []const u8 = "",
    /// This end's identity, as the peer will see it.
    peer: []const u8 = "",
    /// Unix milliseconds, injected so a sync is reproducible under test.
    now_ms: i64 = 0,
    /// A stuck want loop is a bug, not something to retry forever.
    max_rounds: u32 = 64,
    /// How long the joining end waits for a LAN announcement.
    discover_ms: u64 = 10_000,
};

pub const Report = struct {
    sent: usize = 0,
    received: usize = 0,
    rounds: u32 = 0,
    /// The peer's identity, owned here.
    peer: []u8 = &.{},
    /// The scope both ends agreed on, owned here.
    scope: []u8 = &.{},
    /// The op-log view hash both ends must agree on after the sync.
    view: Oid = Oid.zero(),
    /// The merge operation this end wrote, if the heads had diverged.
    merge_op: ?Oid = null,

    pub fn deinit(self: Report, alloc: std.mem.Allocator) void {
        alloc.free(self.peer);
        alloc.free(self.scope);
    }
};

// --- the ratcheted message layer ---

/// A message key that is fresh for every message in a direction.
///
/// `wormhole.Session.sendStream` starts its record counter at zero on every
/// call, which is correct for the one-shot transfer it was written for and
/// catastrophic for a session that sends many messages under one key. Rather
/// than reach into the record layer, each message gets its own key derived from
/// the transfer key and the message index, so the counter restarting is
/// harmless and a message replayed out of order simply fails to decrypt.
fn messageKey(base: [wormhole.key_len]u8, seq: u64) [wormhole.key_len]u8 {
    var h = Blake3.init(.{ .key = base });
    h.update(message_key_domain);
    var seq_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &seq_buf, seq, .big);
    h.update(&seq_buf);
    var out: [wormhole.key_len]u8 = undefined;
    h.final(&out);
    return out;
}

/// A `live.Message` stream over an authenticated wormhole channel.
pub const Wire = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    ch: wormhole.Channel,
    session: wormhole.Session,
    send_seq: u64 = 0,
    recv_seq: u64 = 0,

    pub fn init(
        io: std.Io,
        alloc: std.mem.Allocator,
        ch: wormhole.Channel,
        session: wormhole.Session,
    ) Wire {
        return .{ .io = io, .alloc = alloc, .ch = ch, .session = session };
    }

    fn keyed(self: *Wire, seq: u64) wormhole.Session {
        var s = self.session;
        s.key = messageKey(self.session.key, seq);
        return s;
    }

    pub fn sendBytes(self: *Wire, bytes: []const u8) !void {
        var s = self.keyed(self.send_seq);
        self.send_seq += 1;
        try s.sendStream(self.io, self.alloc, self.ch, bytes);
    }

    pub fn recvBytes(self: *Wire, alloc: std.mem.Allocator) ![]u8 {
        var s = self.keyed(self.recv_seq);
        self.recv_seq += 1;
        return s.recvStream(self.io, alloc, self.ch);
    }

    pub fn send(self: *Wire, msg: live.Message) !void {
        const enc = try live.encode(self.alloc, msg);
        defer self.alloc.free(enc);
        try self.sendBytes(enc);
    }

    pub fn recv(self: *Wire, alloc: std.mem.Allocator) !live.Message {
        const raw = try self.recvBytes(alloc);
        defer alloc.free(raw);
        return live.decode(alloc, raw);
    }

    fn expect(self: *Wire, alloc: std.mem.Allocator, kind: live.MessageKind) !live.Message {
        const msg = try self.recv(alloc);
        errdefer live.freeMessage(alloc, msg);
        if (std.meta.activeTag(msg) != kind) return Error.ProtocolError;
        return msg;
    }
};

// --- what a store holds ---

const OidSet = std.AutoHashMap([Oid.len]u8, void);

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return std.mem.lessThan(u8, &a.bytes, &b.bytes);
}

fn appendUnique(alloc: std.mem.Allocator, list: *std.ArrayList(Oid), o: Oid) !void {
    for (list.items) |x| {
        if (x.eql(o)) return;
    }
    try list.append(alloc, o);
}

/// Every object id in the store, sorted. This is the `igot` half of the
/// negotiation: the store is the index, so nothing has to be kept in sync with
/// it and a store repaired by hand advertises the truth on the next run.
pub fn objectIds(st: *Store, alloc: std.mem.Allocator) ![]Oid {
    var list: std.ArrayList(Oid) = .empty;
    errdefer list.deinit(alloc);

    if (st.root.openDir(st.io, "objects", .{ .iterate = true })) |*od_const| {
        var od = od_const.*;
        defer od.close(st.io);
        var it = od.iterate();
        while (try it.next(st.io)) |shard| {
            if (shard.kind != .directory) continue;
            if (shard.name.len != 2) continue;
            var shard_name: [2]u8 = undefined;
            @memcpy(&shard_name, shard.name);

            var path_buf: [32]u8 = undefined;
            const p = std.fmt.bufPrint(&path_buf, "objects/{s}", .{&shard_name}) catch continue;
            if (st.root.openDir(st.io, p, .{ .iterate = true })) |*sd_const| {
                var sd = sd_const.*;
                defer sd.close(st.io);
                var sit = sd.iterate();
                while (try sit.next(st.io)) |entry| {
                    if (entry.kind != .file) continue;
                    if (entry.name.len != Oid.len * 2 - 2) continue;
                    var hex: [Oid.len * 2]u8 = undefined;
                    @memcpy(hex[0..2], &shard_name);
                    @memcpy(hex[2..], entry.name);
                    const o = Oid.fromHex(&hex) catch continue;
                    try list.append(alloc, o);
                }
            } else |_| {}
        }
    } else |_| {}

    const out = try list.toOwnedSlice(alloc);
    std.mem.sort(Oid, out, {}, oidLessThan);
    return out;
}

pub fn localRefs(st: *Store, alloc: std.mem.Allocator) ![]live.RefAdvert {
    var list: std.ArrayList(live.RefAdvert) = .empty;
    errdefer {
        for (list.items) |r| alloc.free(r.name);
        list.deinit(alloc);
    }

    if (st.root.openDir(st.io, "refs/heads", .{ .iterate = true })) |*d_const| {
        var d = d_const.*;
        defer d.close(st.io);
        var it = d.iterate();
        while (try it.next(st.io)) |entry| {
            if (entry.kind != .file) continue;
            const tip = st.readRef(entry.name) catch continue;
            const name = try alloc.dupe(u8, entry.name);
            errdefer alloc.free(name);
            try list.append(alloc, .{ .name = name, .tip = tip });
        }
    } else |_| {}
    return list.toOwnedSlice(alloc);
}

pub fn freeRefs(alloc: std.mem.Allocator, refs: []live.RefAdvert) void {
    for (refs) |r| alloc.free(r.name);
    alloc.free(refs);
}

fn tipsOf(alloc: std.mem.Allocator, refs: []const live.RefAdvert) ![]Oid {
    const out = try alloc.alloc(Oid, refs.len);
    for (out, refs) |*o, r| o.* = r.tip;
    return out;
}

// --- the reachable closure ---

const NodeKind = enum { change, tree, blob, chunk, operation, view };

const Node = struct {
    id: Oid,
    kind: NodeKind,
};

pub const Closure = struct {
    /// Reachable ids this store actually holds, sorted.
    have: []Oid,
    /// Reachable ids this store does not hold, sorted. These are the frontier:
    /// an absent object cannot be walked through, so its children only become
    /// visible on the round after it arrives.
    missing: []Oid,

    pub fn deinit(self: Closure, alloc: std.mem.Allocator) void {
        alloc.free(self.have);
        alloc.free(self.missing);
    }
};

/// Walk everything reachable from `changes` and `ops`, splitting the result
/// into what this store holds and what it lacks.
///
/// Descent is typed rather than sniffed: a ref tip is a change, an op-head is
/// an operation, and every edge out of those is known statically. `prefix`
/// filters tree entries, which is what keeps a sparse sync sparse on both ends
/// — the receiver must apply the same filter or it would want forever.
pub fn closure(
    st: *Store,
    alloc: std.mem.Allocator,
    changes: []const Oid,
    ops: []const Oid,
    prefix: []const u8,
) !Closure {
    var seen = OidSet.init(alloc);
    defer seen.deinit();

    var have: std.ArrayList(Oid) = .empty;
    errdefer have.deinit(alloc);
    var missing: std.ArrayList(Oid) = .empty;
    errdefer missing.deinit(alloc);

    var stack: std.ArrayList(Node) = .empty;
    defer stack.deinit(alloc);
    for (changes) |c| {
        if (!c.isZero()) try stack.append(alloc, .{ .id = c, .kind = .change });
    }
    for (ops) |o| {
        if (!o.isZero()) try stack.append(alloc, .{ .id = o, .kind = .operation });
    }

    while (stack.pop()) |node| {
        if ((try seen.getOrPut(node.id.bytes)).found_existing) continue;
        if (!st.has(node.id)) {
            try missing.append(alloc, node.id);
            continue;
        }
        try have.append(alloc, node.id);

        switch (node.kind) {
            .chunk => {},
            .change => {
                const ch = st.readChange(node.id) catch continue;
                defer object.freeChange(st.alloc, ch);
                for (ch.parents) |p| {
                    if (!p.isZero()) try stack.append(alloc, .{ .id = p, .kind = .change });
                }
                try stack.append(alloc, .{ .id = ch.tree, .kind = .tree });
            },
            .tree => {
                const t = st.readTree(node.id) catch continue;
                defer object.freeTree(st.alloc, t);
                for (t.entries) |e| {
                    if (!std.mem.startsWith(u8, e.path, prefix)) continue;
                    try stack.append(alloc, .{ .id = e.blob, .kind = .blob });
                }
            },
            .blob => {
                const raw = st.readRaw(node.id) catch continue;
                defer st.alloc.free(raw);
                const b = object.Blob.decode(st.alloc, raw) catch continue;
                defer st.alloc.free(b.chunks);
                for (b.chunks) |c| try stack.append(alloc, .{ .id = c, .kind = .chunk });
            },
            .operation => {
                const op = opdag.readOperation(st, st.alloc, node.id) catch continue;
                defer opdag.freeOperation(st.alloc, op);
                for (op.parents) |p| try stack.append(alloc, .{ .id = p, .kind = .operation });
                try stack.append(alloc, .{ .id = op.view, .kind = .view });
            },
            .view => {
                const v = opdag.readView(st, st.alloc, node.id) catch continue;
                defer v.deinit(st.alloc);
                for (v.refs) |r| {
                    for (r.tips) |t| {
                        if (!t.isZero()) try stack.append(alloc, .{ .id = t, .kind = .change });
                    }
                }
            },
        }
    }

    const have_out = try have.toOwnedSlice(alloc);
    errdefer alloc.free(have_out);
    const missing_out = try missing.toOwnedSlice(alloc);
    std.mem.sort(Oid, have_out, {}, oidLessThan);
    std.mem.sort(Oid, missing_out, {}, oidLessThan);
    return .{ .have = have_out, .missing = missing_out };
}

/// The objects this end should hand over: everything reachable from its own
/// roots that the peer did not say it already had.
pub fn objectsToSend(
    st: *Store,
    alloc: std.mem.Allocator,
    peer_objects: []const Oid,
    prefix: []const u8,
) ![]Oid {
    const refs = try localRefs(st, alloc);
    defer freeRefs(alloc, refs);
    const tips = try tipsOf(alloc, refs);
    defer alloc.free(tips);
    const ops = try opdag.heads(st, alloc);
    defer alloc.free(ops);

    const c = try closure(st, alloc, tips, ops, prefix);
    defer c.deinit(alloc);

    var theirs = OidSet.init(alloc);
    defer theirs.deinit();
    for (peer_objects) |o| try theirs.put(o.bytes, {});

    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(alloc);
    for (c.have) |o| {
        if (!theirs.contains(o.bytes)) try out.append(alloc, o);
    }
    return out.toOwnedSlice(alloc);
}

/// The ids this end still lacks to hold the peer's advertised roots whole.
pub fn missingFor(
    st: *Store,
    alloc: std.mem.Allocator,
    peer_tips: []const Oid,
    peer_heads: []const Oid,
    prefix: []const u8,
) ![]Oid {
    const c = try closure(st, alloc, peer_tips, peer_heads, prefix);
    defer alloc.free(c.have);
    return c.missing;
}

// --- convergence ---

fn collectAncestors(st: *Store, alloc: std.mem.Allocator, root: Oid, set: *OidSet) !void {
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, root);

    while (stack.pop()) |o| {
        if ((try set.getOrPut(o.bytes)).found_existing) continue;
        const op = opdag.readOperation(st, alloc, o) catch continue;
        defer opdag.freeOperation(alloc, op);
        for (op.parents) |p| try stack.append(alloc, p);
    }
}

/// Make sure this end's current refs are represented by an operation before it
/// advertises anything. A repo that has never written an op-log entry still has
/// a state worth merging, and an unrepresented state is a state the peer cannot
/// converge with.
pub fn ensureHead(st: *Store, alloc: std.mem.Allocator, now_ms: i64) !void {
    const hs = try opdag.heads(st, alloc);
    defer alloc.free(hs);
    if (hs.len == 0) {
        _ = try opdag.commit(st, alloc, "sync", now_ms, "");
        return;
    }

    var snap = try opdag.snapshot(st, alloc);
    defer snap.deinit(alloc);
    var cur = try opdag.currentView(st, alloc);
    defer cur.deinit(alloc);
    if (!covers(cur, snap)) _ = try opdag.commit(st, alloc, "sync", now_ms, "");
}

/// True when the op-log view already accounts for every tip the working refs
/// hold. A diverged view keeps several tips per ref while `refs/heads` can only
/// hold one, so comparing the two by hash would call a settled repo dirty on
/// every run and commit a redundant operation before every sync.
fn covers(view: opdag.View, snap: opdag.View) bool {
    for (snap.refs) |r| {
        const cur = view.find(r.name) orelse return false;
        for (r.tips) |t| {
            var found = false;
            for (cur.tips) |c| {
                if (c.eql(t)) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    if (snap.head_branch.len > 0 and !std.mem.eql(u8, snap.head_branch, view.head_branch)) {
        return false;
    }
    return true;
}

/// Fold the peer's op-heads into this store's head set, dropping any head that
/// turns out to be an ancestor of another. Heads the peer named but whose
/// operations never arrived are ignored rather than recorded: a head file
/// pointing at an object this store does not hold would be a dangling promise.
pub fn adoptHeads(st: *Store, alloc: std.mem.Allocator, peer_heads: []const Oid) !void {
    var all: std.ArrayList(Oid) = .empty;
    defer all.deinit(alloc);

    const mine = try opdag.heads(st, alloc);
    defer alloc.free(mine);
    for (mine) |h| try appendUnique(alloc, &all, h);
    for (peer_heads) |h| {
        if (st.has(h)) try appendUnique(alloc, &all, h);
    }

    var anc = OidSet.init(alloc);
    defer anc.deinit();
    for (all.items) |h| {
        const op = opdag.readOperation(st, alloc, h) catch continue;
        defer opdag.freeOperation(alloc, op);
        for (op.parents) |p| try collectAncestors(st, alloc, p, &anc);
    }

    for (all.items) |h| {
        if (anc.contains(h.bytes)) {
            try opdag.removeHead(st, h);
        } else {
            try opdag.addHead(st, h);
        }
    }
}

pub const Converged = struct {
    view: Oid,
    merge_op: ?Oid,
};

/// Collapse whatever heads this store now has into one view and write it out.
///
/// `resolve` does the merge when the heads diverged, and is deterministic
/// across machines; when they did not diverge there is nothing to merge but the
/// single surviving view still has to reach `refs/heads`, which is the case a
/// fast-forward sync lands in.
pub fn converge(st: *Store, alloc: std.mem.Allocator) !Converged {
    const merged = try opdag.resolve(st, alloc);
    if (merged == null) {
        var v = try opdag.currentView(st, alloc);
        defer v.deinit(alloc);
        try opdag.applyView(st, v);
    }
    var v = try opdag.currentView(st, alloc);
    defer v.deinit(alloc);
    return .{ .view = try v.hash(alloc), .merge_op = merged };
}

// --- the negotiation ---

const Party = struct {
    st: *Store,
    alloc: std.mem.Allocator,
    wire: *Wire,
    scope: []const u8,
    /// Ids the peer was asked for and could not produce. A peer holding a
    /// sparse store advertises roots whose blobs it never had, and asking for
    /// them again every round would turn a legal partial repo into a hung
    /// session instead of a finished one.
    refused: OidSet,
    sent: usize = 0,
    received: usize = 0,

    fn init(st: *Store, alloc: std.mem.Allocator, wire: *Wire, scope: []const u8) Party {
        return .{
            .st = st,
            .alloc = alloc,
            .wire = wire,
            .scope = scope,
            .refused = OidSet.init(alloc),
        };
    }

    fn deinit(self: *Party) void {
        self.refused.deinit();
    }

    fn wants(self: *Party, tips: []const Oid, heads: []const Oid) ![]Oid {
        const raw = try missingFor(self.st, self.alloc, tips, heads, self.scope);
        defer self.alloc.free(raw);

        var out: std.ArrayList(Oid) = .empty;
        errdefer out.deinit(self.alloc);
        for (raw) |o| {
            if (!self.refused.contains(o.bytes)) try out.append(self.alloc, o);
        }
        return out.toOwnedSlice(self.alloc);
    }

    fn markUnfilled(self: *Party, asked: []const Oid) !void {
        for (asked) |o| {
            if (!self.st.has(o)) try self.refused.put(o.bytes, {});
        }
    }

    fn sendInventory(self: *Party) !void {
        const refs = try localRefs(self.st, self.alloc);
        defer freeRefs(self.alloc, refs);
        const heads = try opdag.heads(self.st, self.alloc);
        defer self.alloc.free(heads);
        const objects = try objectIds(self.st, self.alloc);
        defer self.alloc.free(objects);

        try self.wire.send(.{ .inventory = .{
            .refs = refs,
            .op_heads = heads,
            .objects = objects,
        } });
    }

    fn sendPack(self: *Party, ids: []const Oid) !void {
        try self.wire.send(.{ .pack = .{ .count = @intCast(ids.len) } });
        for (ids) |o| {
            const raw = self.st.readRaw(o) catch continue;
            defer self.st.alloc.free(raw);
            try self.wire.send(.{ .object = .{ .raw = raw } });
            self.sent += 1;
        }
        try self.wire.send(.end);
    }

    fn recvPack(self: *Party) !usize {
        const head = try self.wire.expect(self.alloc, .pack);
        live.freeMessage(self.alloc, head);

        var n: usize = 0;
        while (true) {
            const msg = try self.wire.recv(self.alloc);
            defer live.freeMessage(self.alloc, msg);
            switch (msg) {
                .object => |f| {
                    _ = try self.st.writeRaw(f.raw);
                    n += 1;
                },
                .end => break,
                else => return Error.ProtocolError,
            }
        }
        self.received += n;
        return n;
    }
};

const PeerState = struct {
    name: []u8,
    tips: []Oid,
    heads: []Oid,
    objects: []Oid,
};

fn takeInventory(alloc: std.mem.Allocator, wire: *Wire) !struct {
    tips: []Oid,
    heads: []Oid,
    objects: []Oid,
} {
    const msg = try wire.expect(alloc, .inventory);
    defer live.freeMessage(alloc, msg);
    const inv = msg.inventory;

    const tips = try alloc.alloc(Oid, inv.refs.len);
    errdefer alloc.free(tips);
    for (tips, inv.refs) |*t, r| t.* = r.tip;
    const heads = try alloc.dupe(Oid, inv.op_heads);
    errdefer alloc.free(heads);
    const objects = try alloc.dupe(Oid, inv.objects);
    return .{ .tips = tips, .heads = heads, .objects = objects };
}

fn haveOf(st: *Store, alloc: std.mem.Allocator, ids: []const Oid) ![]Oid {
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(alloc);
    for (ids) |o| {
        if (st.has(o)) try out.append(alloc, o);
    }
    return out.toOwnedSlice(alloc);
}

/// The end that dials out. It opens the session, holds the write authority for
/// the live phase that may follow, and drives every round trip.
pub fn initiate(st: *Store, alloc: std.mem.Allocator, wire: *Wire, opts: Options) !Report {
    try ensureHead(st, alloc, opts.now_ms);

    try wire.send(.{ .hello = .{
        .version = protocol_version,
        .peer = opts.peer,
        .scope = opts.scope,
        .writer = true,
    } });

    const hello = try wire.expect(alloc, .hello);
    defer live.freeMessage(alloc, hello);
    if (hello.hello.version != protocol_version) return Error.VersionMismatch;
    if (!std.mem.eql(u8, hello.hello.scope, opts.scope)) return Error.ScopeMismatch;

    var report = Report{};
    report.peer = try alloc.dupe(u8, hello.hello.peer);
    errdefer alloc.free(report.peer);
    report.scope = try alloc.dupe(u8, opts.scope);
    errdefer alloc.free(report.scope);

    var party = Party.init(st, alloc, wire, report.scope);
    defer party.deinit();

    try party.sendInventory();
    const inv = try takeInventory(alloc, wire);
    const peer = PeerState{
        .name = report.peer,
        .tips = inv.tips,
        .heads = inv.heads,
        .objects = inv.objects,
    };
    defer {
        alloc.free(peer.tips);
        alloc.free(peer.heads);
        alloc.free(peer.objects);
    }

    _ = try party.recvPack();

    {
        const bulk = try objectsToSend(st, alloc, peer.objects, party.scope);
        defer alloc.free(bulk);
        try party.sendPack(bulk);
    }

    while (true) : (report.rounds += 1) {
        if (report.rounds >= opts.max_rounds) return Error.TooManyRounds;

        const mine = try party.wants(peer.tips, peer.heads);
        defer alloc.free(mine);
        try wire.send(.{ .want = .{ .ids = mine } });

        _ = try party.recvPack();
        try party.markUnfilled(mine);

        const theirs = try wire.expect(alloc, .want);
        defer live.freeMessage(alloc, theirs);
        const fill = try haveOf(st, alloc, theirs.want.ids);
        defer alloc.free(fill);
        try party.sendPack(fill);

        if (mine.len == 0 and theirs.want.ids.len == 0) {
            report.rounds += 1;
            break;
        }
    }

    try adoptHeads(st, alloc, peer.heads);
    const done = try converge(st, alloc);
    report.view = done.view;
    report.merge_op = done.merge_op;
    report.sent = party.sent;
    report.received = party.received;

    try wire.send(.end);
    return report;
}

/// The end that answers. Mirror of `initiate`, message for message.
pub fn respond(st: *Store, alloc: std.mem.Allocator, wire: *Wire, opts: Options) !Report {
    try ensureHead(st, alloc, opts.now_ms);

    const hello = try wire.expect(alloc, .hello);
    defer live.freeMessage(alloc, hello);
    if (hello.hello.version != protocol_version) return Error.VersionMismatch;

    var report = Report{};
    report.peer = try alloc.dupe(u8, hello.hello.peer);
    errdefer alloc.free(report.peer);
    report.scope = try alloc.dupe(u8, hello.hello.scope);
    errdefer alloc.free(report.scope);

    try wire.send(.{ .hello = .{
        .version = protocol_version,
        .peer = opts.peer,
        .scope = report.scope,
        .writer = false,
    } });

    var party = Party.init(st, alloc, wire, report.scope);
    defer party.deinit();

    const inv = try takeInventory(alloc, wire);
    const peer = PeerState{
        .name = report.peer,
        .tips = inv.tips,
        .heads = inv.heads,
        .objects = inv.objects,
    };
    defer {
        alloc.free(peer.tips);
        alloc.free(peer.heads);
        alloc.free(peer.objects);
    }

    try party.sendInventory();

    {
        const bulk = try objectsToSend(st, alloc, peer.objects, party.scope);
        defer alloc.free(bulk);
        try party.sendPack(bulk);
    }

    _ = try party.recvPack();

    while (true) : (report.rounds += 1) {
        if (report.rounds >= opts.max_rounds) return Error.TooManyRounds;

        const theirs = try wire.expect(alloc, .want);
        defer live.freeMessage(alloc, theirs);
        const fill = try haveOf(st, alloc, theirs.want.ids);
        defer alloc.free(fill);
        try party.sendPack(fill);

        const mine = try party.wants(peer.tips, peer.heads);
        defer alloc.free(mine);
        try wire.send(.{ .want = .{ .ids = mine } });

        _ = try party.recvPack();
        try party.markUnfilled(mine);

        if (mine.len == 0 and theirs.want.ids.len == 0) {
            report.rounds += 1;
            break;
        }
    }

    try adoptHeads(st, alloc, peer.heads);
    const done = try converge(st, alloc);
    report.view = done.view;
    report.merge_op = done.merge_op;
    report.sent = party.sent;
    report.received = party.received;

    const end = try wire.expect(alloc, .end);
    live.freeMessage(alloc, end);
    return report;
}

// --- the live phase ---

/// The session that runs after the transfer, driving `live.zig`'s frames over
/// the same wire. Nothing here relaxes the one-writer rule: a send that would
/// need authority this end does not hold is refused before it reaches the wire,
/// and a moment or verdict arriving while this end still holds authority is a
/// protocol violation rather than a race to resolve.
pub const LiveSession = struct {
    st: *Store,
    alloc: std.mem.Allocator,
    wire: *Wire,
    state: live.Session,
    /// The peer's identity, borrowed from the caller's `Report`.
    peer_name: []const u8,

    pub fn init(
        st: *Store,
        alloc: std.mem.Allocator,
        wire: *Wire,
        role: live.Role,
        peer_name: []const u8,
        started_ms: i64,
    ) LiveSession {
        return .{
            .st = st,
            .alloc = alloc,
            .wire = wire,
            .state = .{
                .role = role,
                .peer = peer_name,
                .started_ms = started_ms,
                .writer_is_me = role == .author,
            },
            .peer_name = peer_name,
        };
    }

    pub fn canWrite(self: *const LiveSession) bool {
        return live.canWrite(self.state);
    }

    pub fn send(self: *LiveSession, msg: live.Message) !void {
        switch (msg) {
            .moment, .verdict => try live.rejectWrite(self.state),
            .note, .bye => {},
            else => return Error.ProtocolError,
        }
        try self.wire.send(msg);
    }

    pub fn handoff(self: *LiveSession) !void {
        try live.applyHandoff(&self.state, self.peer_name);
        try self.wire.send(.{ .handoff = .{ .to = self.peer_name } });
    }

    /// One inbound frame, or null once the peer says goodbye. The caller owns
    /// the returned message and frees it with `live.freeMessage`.
    pub fn recv(self: *LiveSession, alloc: std.mem.Allocator, now_ms: i64) !?live.Message {
        const msg = try self.wire.recv(alloc);
        errdefer live.freeMessage(alloc, msg);
        switch (msg) {
            .bye => {
                live.freeMessage(alloc, msg);
                return null;
            },
            .moment => |f| {
                if (live.canWrite(self.state)) return live.Error.NotTheWriter;
                try acceptMoment(self.st, alloc, f);
            },
            .verdict => {
                if (live.canWrite(self.state)) return live.Error.NotTheWriter;
            },
            .note => |f| try live.recordNote(self.st, f, now_ms),
            .handoff => try live.acceptHandoff(&self.state, self.peer_name),
            else => return Error.ProtocolError,
        }
        return msg;
    }
};

/// Rebuild the tree a moment frame describes and refuse it unless it hashes to
/// the id the sender claimed. A frame that does not reconstruct is a frame that
/// would put a wrong tree into a content-addressed store under a right name.
fn acceptMoment(st: *Store, alloc: std.mem.Allocator, f: live.MomentFrame) !void {
    const entries = try alloc.dupe(object.TreeEntry, f.entries);
    defer alloc.free(entries);
    std.mem.sort(object.TreeEntry, entries, {}, object.Tree.lessThan);

    const tree = object.Tree{ .entries = entries };
    const enc = try tree.encode(alloc);
    defer alloc.free(enc);
    if (!Oid.ofBytes(enc).eql(f.full_tree)) return live.Error.BadFrame;
    _ = try st.writeRaw(enc);
}

// --- transports ---

pub const RelayAddress = struct {
    host: []const u8,
    port: u16,
};

pub const Endpoint = union(enum) {
    /// Zero infrastructure: UDP broadcast to find the peer, then a direct TCP
    /// connection between the two machines.
    lan,
    /// An optional, self-hostable rendezvous that pairs two streams. It sees a
    /// slot number and ciphertext, and never a byte of plaintext.
    relay: RelayAddress,
};

pub const lan_port_base: u16 = 41000;

fn bindLan(io: std.Io, slot: u16) !struct { server: net.Server, port: u16 } {
    var port: u16 = lan_port_base +% slot;
    var tries: u16 = 0;
    while (tries < 64) : (tries += 1) {
        var address: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(port) };
        if (address.listen(io, .{ .reuse_address = true })) |s| {
            return .{ .server = s, .port = port };
        } else |_| {}
        port +%= 1;
    }
    return Error.NoPortAvailable;
}

const AnnounceJob = struct {
    io: std.Io,
    slot: u16,
    port: u16,
    stop: *std.atomic.Value(bool),

    fn run(self: AnnounceJob) void {
        var b = discovery.Broadcaster.init(self.io) catch return;
        defer b.deinit(self.io);
        while (!self.stop.load(.acquire)) {
            _ = b.pulse(self.io, self.slot, self.port);
            self.io.sleep(.{ .nanoseconds = 200 * std.time.ns_per_ms }, .awake) catch return;
        }
    }
};

fn acceptLan(io: std.Io, alloc: std.mem.Allocator, slot: u16) !*wormhole.Conn {
    var bound = try bindLan(io, slot);
    defer bound.server.deinit(io);

    var stop = std.atomic.Value(bool).init(false);
    const job = AnnounceJob{ .io = io, .slot = slot, .port = bound.port, .stop = &stop };
    const th = std.Thread.spawn(.{}, AnnounceJob.run, .{job}) catch null;
    defer if (th) |t| {
        stop.store(true, .release);
        t.join();
    };

    const stream = try bound.server.accept(io);
    return wormhole.Conn.adopt(io, alloc, stream);
}

fn dialLan(io: std.Io, alloc: std.mem.Allocator, slot: u16, timeout_ms: u64) !*wormhole.Conn {
    const found = try discovery.discover(io, slot, timeout_ms);
    var address = found.address;
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    return wormhole.Conn.adopt(io, alloc, stream);
}

fn openEndpoint(
    io: std.Io,
    alloc: std.mem.Allocator,
    ep: Endpoint,
    code: wormhole.Code,
    dialing: bool,
    timeout_ms: u64,
) !*wormhole.Conn {
    switch (ep) {
        .lan => return if (dialing)
            dialLan(io, alloc, code.slot, timeout_ms)
        else
            acceptLan(io, alloc, code.slot),
        .relay => |r| {
            const conn = try wormhole.Conn.open(io, alloc, r.host, r.port);
            errdefer conn.destroy();
            try wormhole.joinSlot(conn.channel(), code.slot);
            return conn;
        },
    }
}

/// Open a session as the end that generated the code, negotiate, and converge.
///
/// On LAN this is the end that announces and waits; through a relay both ends
/// dial the same slot and the relay pairs them. Either way the PAKE runs over
/// whatever byte pipe came back, so the relay is a convenience and never a
/// party to the session.
pub fn hostSession(
    st: *Store,
    alloc: std.mem.Allocator,
    code_text: []const u8,
    ep: Endpoint,
    opts: Options,
) !Report {
    const io = st.io;
    const code = try wormhole.Code.parse(code_text);
    const conn = try openEndpoint(io, alloc, ep, code, false, opts.discover_ms);
    defer conn.destroy();

    const session = try wormhole.senderHandshake(io, alloc, conn.channel(), code.text());
    var wire = Wire.init(io, alloc, conn.channel(), session);
    return initiate(st, alloc, &wire, opts);
}

/// Open a session as the end that was handed the code.
pub fn joinSession(
    st: *Store,
    alloc: std.mem.Allocator,
    code_text: []const u8,
    ep: Endpoint,
    opts: Options,
) !Report {
    const io = st.io;
    const code = try wormhole.Code.parse(code_text);
    const conn = try openEndpoint(io, alloc, ep, code, true, opts.discover_ms);
    defer conn.destroy();

    const session = try wormhole.receiverHandshake(io, alloc, conn.channel(), code.text());
    var wire = Wire.init(io, alloc, conn.channel(), session);
    return respond(st, alloc, &wire, opts);
}

// --- tests ---

const testing = std.testing;

const FileSpec = struct {
    path: []const u8,
    content: []const u8,
};

fn commitFiles(
    st: *Store,
    branch: []const u8,
    files: []const FileSpec,
    parents: []const Oid,
    seed: u8,
    ts: i64,
) !Oid {
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
        .timestamp = ts,
        .tz_offset_min = 0,
        .author = "Tester <t@example.com>",
        .message = "seed",
    });
    try st.updateRef(branch, change);
    return change;
}

const base_files = [_]FileSpec{
    .{ .path = "docs/intro.md", .content = "# superdetermine\n" ** 200 },
    .{ .path = "src/main.zig", .content = "fn main() void {}\n" ** 200 },
};

const left_files = [_]FileSpec{
    .{ .path = "docs/intro.md", .content = "# superdetermine\n" ** 200 },
    .{ .path = "src/main.zig", .content = "fn main() void {}\n" ** 200 },
    .{ .path = "src/left.zig", .content = "pub const left = 1;\n" ** 200 },
};

const right_files = [_]FileSpec{
    .{ .path = "docs/intro.md", .content = "# superdetermine\n" ** 200 },
    .{ .path = "src/main.zig", .content = "fn main() void {}\n" ** 200 },
    .{ .path = "docs/right.md", .content = "the other side\n" ** 200 },
};

test "the send set is exactly the closure minus what the peer already has" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();
    _ = try commitFiles(&st, "main", &base_files, &.{}, 1, 1000);
    try ensureHead(&st, alloc, 1000);

    const everything = try objectsToSend(&st, alloc, &.{}, "");
    defer alloc.free(everything);
    try testing.expect(everything.len > 4);

    // A peer that already holds a prefix of the closure is sent only the rest,
    // which is exactly what an interrupted transfer leaves behind.
    const half = everything.len / 2;
    const partial = try objectsToSend(&st, alloc, everything[0..half], "");
    defer alloc.free(partial);
    try testing.expectEqual(everything.len - half, partial.len);

    const none = try objectsToSend(&st, alloc, everything, "");
    defer alloc.free(none);
    try testing.expectEqual(@as(usize, 0), none.len);
}

test "the closure splits into what a store holds and what it lacks" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var full = try Store.init(io, alloc, tmp_a.dir);
    defer full.deinit();
    const tip = try commitFiles(&full, "main", &base_files, &.{}, 1, 1000);

    var empty = try Store.init(io, alloc, tmp_b.dir);
    defer empty.deinit();

    const here = try closure(&full, alloc, &.{tip}, &.{}, "");
    defer here.deinit(alloc);
    try testing.expect(here.have.len > 4);
    try testing.expectEqual(@as(usize, 0), here.missing.len);

    const there = try closure(&empty, alloc, &.{tip}, &.{}, "");
    defer there.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), there.have.len);
    try testing.expectEqual(@as(usize, 1), there.missing.len);
    try testing.expect(there.missing[0].eql(tip));
}

test "a prefix scope keeps the other subtree out of the closure" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();
    const tip = try commitFiles(&st, "main", &base_files, &.{}, 1, 1000);

    const all = try closure(&st, alloc, &.{tip}, &.{}, "");
    defer all.deinit(alloc);
    const scoped = try closure(&st, alloc, &.{tip}, &.{}, "src/");
    defer scoped.deinit(alloc);

    try testing.expect(scoped.have.len < all.have.len);
    try testing.expectEqual(@as(usize, 0), scoped.missing.len);
}

const Side = struct {
    st: *Store,
    opts: Options,
    report: Report = .{},
    err: ?anyerror = null,
    handoff_probe: bool = false,
    follower_refused: bool = false,
    notes_seen: usize = 0,
};

fn hostThread(io: std.Io, alloc: std.mem.Allocator, port: u16, code: []const u8, side: *Side) void {
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var server = address.listen(io, .{ .reuse_address = true }) catch |e| {
        side.err = e;
        return;
    };
    defer server.deinit(io);

    const stream = server.accept(io) catch |e| {
        side.err = e;
        return;
    };
    const conn = wormhole.Conn.adopt(io, alloc, stream) catch |e| {
        side.err = e;
        return;
    };
    defer conn.destroy();

    const session = wormhole.senderHandshake(io, alloc, conn.channel(), code) catch |e| {
        side.err = e;
        return;
    };
    var wire = Wire.init(io, alloc, conn.channel(), session);
    side.report = initiate(side.st, alloc, &wire, side.opts) catch |e| {
        side.err = e;
        return;
    };

    if (!side.handoff_probe) return;
    runAuthor(side, alloc, &wire);
}

fn joinThread(io: std.Io, alloc: std.mem.Allocator, port: u16, code: []const u8, side: *Side) void {
    var attempt: usize = 0;
    const conn = while (attempt < 400) : (attempt += 1) {
        if (wormhole.Conn.open(io, alloc, "127.0.0.1", port)) |c| break c else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    } else {
        side.err = error.CouldNotConnect;
        return;
    };
    defer conn.destroy();

    const session = wormhole.receiverHandshake(io, alloc, conn.channel(), code) catch |e| {
        side.err = e;
        return;
    };
    var wire = Wire.init(io, alloc, conn.channel(), session);
    side.report = respond(side.st, alloc, &wire, side.opts) catch |e| {
        side.err = e;
        return;
    };

    if (!side.handoff_probe) return;
    runFollower(side, alloc, &wire);
}

fn runAuthor(side: *Side, alloc: std.mem.Allocator, wire: *Wire) void {
    var s = LiveSession.init(side.st, alloc, wire, .author, side.report.peer, 0);

    // A note from the read-only end costs no authority, so it arrives first.
    const note = s.recv(alloc, 5000) catch |e| {
        side.err = e;
        return;
    };
    if (note) |m| {
        defer live.freeMessage(alloc, m);
        if (std.meta.activeTag(m) == .note) side.notes_seen += 1;
    }

    s.handoff() catch |e| {
        side.err = e;
        return;
    };
    // Authority is gone the instant the handoff is applied.
    if (s.canWrite()) side.err = error.TwoWriters;
    s.send(.{ .verdict = sampleVerdict() }) catch |e| {
        if (e != error.ReadOnlyFollower) side.err = e;
        side.follower_refused = true;
    };

    // The new writer's verdict, then the authority coming back.
    const written = s.recv(alloc, 5000) catch |e| {
        side.err = e;
        return;
    };
    if (written) |m| {
        defer live.freeMessage(alloc, m);
        if (std.meta.activeTag(m) != .verdict) side.err = error.ExpectedVerdict;
    }

    const back = s.recv(alloc, 5000) catch |e| {
        side.err = e;
        return;
    };
    if (back) |m| {
        defer live.freeMessage(alloc, m);
        if (std.meta.activeTag(m) != .handoff) side.err = error.ExpectedHandoff;
    }
    if (!s.canWrite()) side.err = error.AuthorityLost;

    const bye = s.recv(alloc, 5000) catch |e| {
        side.err = e;
        return;
    };
    if (bye) |m| {
        live.freeMessage(alloc, m);
        side.err = error.ExpectedBye;
    }
}

fn runFollower(side: *Side, alloc: std.mem.Allocator, wire: *Wire) void {
    var s = LiveSession.init(side.st, alloc, wire, .follower, side.report.peer, 0);

    if (s.canWrite()) side.err = error.TwoWriters;
    s.send(.{ .verdict = sampleVerdict() }) catch |e| {
        if (e != error.ReadOnlyFollower) side.err = e;
        side.follower_refused = true;
    };

    s.send(.{ .note = .{ .path = "src/main.zig", .line = 3, .text = "look here" } }) catch |e| {
        side.err = e;
        return;
    };

    const got = s.recv(alloc, 5000) catch |e| {
        side.err = e;
        return;
    };
    if (got) |m| {
        defer live.freeMessage(alloc, m);
        if (std.meta.activeTag(m) != .handoff) side.err = error.ExpectedHandoff;
    }
    if (!s.canWrite()) side.err = error.AuthorityLost;

    s.send(.{ .verdict = sampleVerdict() }) catch |e| {
        side.err = e;
        return;
    };
    s.handoff() catch |e| {
        side.err = e;
        return;
    };
    s.send(.bye) catch |e| {
        side.err = e;
        return;
    };
}

fn sampleVerdict() live.VerdictFrame {
    return .{
        .tree = Oid.ofBytes("tree"),
        .tier = .full,
        .result = .green,
        .independence = .independent,
        .relevance_hit = 1,
        .relevance_total = 1,
        .discrimination = .discriminating,
    };
}

fn runSync(
    alloc: std.mem.Allocator,
    port: u16,
    code: []const u8,
    host: *Side,
    join: *Side,
) !void {
    const io = std.testing.io;
    const h = try std.Thread.spawn(.{}, hostThread, .{ io, alloc, port, code, host });
    const j = try std.Thread.spawn(.{}, joinThread, .{ io, alloc, port, code, join });
    h.join();
    j.join();
    if (host.err) |e| return e;
    if (join.err) |e| return e;
}

fn viewHash(st: *Store, alloc: std.mem.Allocator) !Oid {
    var v = try opdag.currentView(st, alloc);
    defer v.deinit(alloc);
    return v.hash(alloc);
}

test "two divergent stores converge on one op-log view" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();

    const base = try commitFiles(&a, "main", &base_files, &.{}, 1, 1000);
    _ = try commitFiles(&a, "main", &left_files, &.{base}, 2, 2000);
    _ = try commitFiles(&b, "main", &base_files, &.{}, 1, 1000);
    _ = try commitFiles(&b, "main", &right_files, &.{base}, 3, 3000);

    var host = Side{ .st = &a, .opts = .{ .peer = "a@laptop", .now_ms = 10 } };
    var join = Side{ .st = &b, .opts = .{ .peer = "b@studio", .now_ms = 20 } };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);

    try runSync(alloc, 47951, "31-anchor-apple", &host, &join);

    try testing.expectEqualStrings("b@studio", host.report.peer);
    try testing.expectEqualStrings("a@laptop", join.report.peer);
    try testing.expect(host.report.sent > 0);
    try testing.expect(host.report.received > 0);

    // The whole point: the same view hash on both machines.
    try testing.expect(host.report.view.eql(join.report.view));
    try testing.expect((try viewHash(&a, alloc)).eql(try viewHash(&b, alloc)));

    // And both merge operations are the same object, derived independently.
    try testing.expect(host.report.merge_op != null);
    try testing.expect(join.report.merge_op != null);
    try testing.expect(host.report.merge_op.?.eql(join.report.merge_op.?));

    // Every object either side needed is now present on both.
    const a_ids = try objectIds(&a, alloc);
    defer alloc.free(a_ids);
    for (a_ids) |o| try testing.expect(b.has(o));

    var view = try opdag.currentView(&a, alloc);
    defer view.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), view.find("main").?.tips.len);
}

test "a second sync between converged stores transfers nothing" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();

    _ = try commitFiles(&a, "main", &left_files, &.{}, 2, 2000);
    _ = try commitFiles(&b, "main", &right_files, &.{}, 3, 3000);

    {
        var host = Side{ .st = &a, .opts = .{ .peer = "a", .now_ms = 10 } };
        var join = Side{ .st = &b, .opts = .{ .peer = "b", .now_ms = 20 } };
        defer host.report.deinit(alloc);
        defer join.report.deinit(alloc);
        try runSync(alloc, 47952, "32-anchor-apple", &host, &join);
        try testing.expect(host.report.received > 0);
    }

    var host = Side{ .st = &a, .opts = .{ .peer = "a", .now_ms = 30 } };
    var join = Side{ .st = &b, .opts = .{ .peer = "b", .now_ms = 40 } };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);
    try runSync(alloc, 47953, "33-anchor-apple", &host, &join);

    try testing.expectEqual(@as(usize, 0), host.report.sent);
    try testing.expectEqual(@as(usize, 0), host.report.received);
    try testing.expectEqual(@as(usize, 0), join.report.sent);
    try testing.expectEqual(@as(usize, 0), join.report.received);
    try testing.expect(host.report.view.eql(join.report.view));
}

test "a resumed transfer sends only the objects that never arrived" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();

    _ = try commitFiles(&a, "main", &left_files, &.{}, 2, 2000);
    try ensureHead(&a, alloc, 10);

    const full = try objectsToSend(&a, alloc, &.{}, "");
    defer alloc.free(full);
    try testing.expect(full.len > 6);

    // Stand in for a connection that died mid-pack: the receiver kept the
    // objects that did arrive and nothing else.
    const arrived = full.len / 2;
    for (full[0..arrived]) |o| {
        const raw = try a.readRaw(o);
        defer alloc.free(raw);
        _ = try b.writeRaw(raw);
    }

    var host = Side{ .st = &a, .opts = .{ .peer = "a", .now_ms = 10 } };
    var join = Side{ .st = &b, .opts = .{ .peer = "b", .now_ms = 20 } };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);
    try runSync(alloc, 47954, "34-anchor-apple", &host, &join);

    // Exactly the remainder crossed the wire, and nothing was sent twice.
    try testing.expectEqual(full.len - arrived, host.report.sent);
    try testing.expectEqual(full.len - arrived, join.report.received);
    try testing.expect(host.report.view.eql(join.report.view));

    for (full) |o| try testing.expect(b.has(o));
}

test "a scoped sync moves one subtree and leaves the other behind" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();

    const tip = try commitFiles(&a, "main", &base_files, &.{}, 1, 1000);

    var host = Side{ .st = &a, .opts = .{ .peer = "a", .scope = "src/", .now_ms = 10 } };
    var join = Side{ .st = &b, .opts = .{ .peer = "b", .scope = "src/", .now_ms = 20 } };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);
    try runSync(alloc, 47955, "35-anchor-apple", &host, &join);

    try testing.expectEqualStrings("src/", join.report.scope);
    try testing.expect(b.has(tip));

    const change = try a.readChange(tip);
    defer object.freeChange(alloc, change);
    const tree = try a.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (std.mem.startsWith(u8, e.path, "src/")) {
            const content = try b.readFileContent(e.blob);
            alloc.free(content);
        } else {
            try testing.expect(!b.has(e.blob));
        }
    }
    try testing.expect(host.report.view.eql(join.report.view));
}

test "syncing with a sparse peer finishes instead of wanting forever" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    var tmp_c = std.testing.tmpDir(.{});
    defer tmp_c.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();
    var c = try Store.init(io, alloc, tmp_c.dir);
    defer c.deinit();

    const tip = try commitFiles(&a, "main", &base_files, &.{}, 1, 1000);
    const change = try a.readChange(tip);
    defer object.freeChange(alloc, change);
    const tree = try a.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    var docs_blob = Oid.zero();
    for (tree.entries) |e| {
        if (std.mem.startsWith(u8, e.path, "docs/")) docs_blob = e.blob;
    }
    try testing.expect(!docs_blob.isZero());

    {
        var host = Side{ .st = &a, .opts = .{ .peer = "a", .scope = "src/", .now_ms = 10 } };
        var join = Side{ .st = &b, .opts = .{ .peer = "b", .scope = "src/", .now_ms = 20 } };
        defer host.report.deinit(alloc);
        defer join.report.deinit(alloc);
        try runSync(alloc, 47957, "37-anchor-apple", &host, &join);
    }
    try testing.expect(!b.has(docs_blob));

    // b now advertises a tip whose docs blob it never had. A full-scope sync
    // against it must settle on what exists rather than loop on what does not.
    var host = Side{ .st = &b, .opts = .{ .peer = "b", .now_ms = 30 } };
    var join = Side{ .st = &c, .opts = .{ .peer = "c", .now_ms = 40 } };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);
    try runSync(alloc, 47958, "38-anchor-apple", &host, &join);

    try testing.expect(host.report.view.eql(join.report.view));
    try testing.expect(c.has(tip));
    try testing.expect(!c.has(docs_blob));
    try testing.expect(host.report.rounds < 8);
}

test "the one-writer rule holds across a whole live session" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var a = try Store.init(io, alloc, tmp_a.dir);
    defer a.deinit();
    var b = try Store.init(io, alloc, tmp_b.dir);
    defer b.deinit();

    _ = try commitFiles(&a, "main", &base_files, &.{}, 1, 1000);

    var host = Side{ .st = &a, .opts = .{ .peer = "a", .now_ms = 10 }, .handoff_probe = true };
    var join = Side{ .st = &b, .opts = .{ .peer = "b", .now_ms = 20 }, .handoff_probe = true };
    defer host.report.deinit(alloc);
    defer join.report.deinit(alloc);
    try runSync(alloc, 47956, "36-anchor-apple", &host, &join);

    // Both ends tried to write while read-only and both were refused.
    try testing.expect(host.follower_refused);
    try testing.expect(join.follower_refused);
    // The follower's note is the one thing it may send, and it persisted.
    try testing.expectEqual(@as(usize, 1), host.notes_seen);

    const kept = try live.notes(&a, alloc);
    defer live.freeNotes(alloc, kept);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectEqualStrings("look here", kept[0].text);
    try testing.expectEqual(@as(u32, 3), kept[0].line);
}

test "every message on a wire is encrypted under its own key" {
    const base = [_]u8{0x11} ** wormhole.key_len;

    var seen: [8][wormhole.key_len]u8 = undefined;
    for (&seen, 0..) |*k, i| k.* = messageKey(base, i);
    for (seen, 0..) |k, i| {
        try testing.expect(!std.mem.eql(u8, &k, &base));
        for (seen[i + 1 ..]) |other| try testing.expect(!std.mem.eql(u8, &k, &other));
    }
    try testing.expectEqualSlices(u8, &seen[3], &messageKey(base, 3));

    var other_base = base;
    other_base[0] ^= 0xff;
    try testing.expect(!std.mem.eql(u8, &seen[0], &messageKey(other_base, 0)));
}
