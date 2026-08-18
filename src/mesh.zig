const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const object = @import("object.zig");
const opdag = @import("opdag.zig");
const applog = @import("applog.zig");
const config = @import("config.zig");
const verdict = @import("verdict.zig");
const discovery = @import("discovery.zig");
const wormhole = @import("wormhole.zig");
const live = @import("live.zig");
const sync = @import("sync.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

const net = std.Io.net;
const posix = std.posix;
const Blake3 = std.crypto.hash.Blake3;

/// Multiplayer: N peers on one repo, converging continuously, with no server
/// anywhere in the picture.
///
/// `sync.zig` already reconciles two machines that can reach each other, and
/// its convergence property is the one this file is built on: both ends adopt
/// each other's op-heads and run the same total `mergeViews`, which is
/// deterministic down to the content hash. Two peers therefore agree without
/// asking a third party what the answer is. That generalises to N peers for
/// free — a merge that cannot fail and does not depend on order is a merge that
/// does not care how many ways the state was split — so nothing here needs to
/// elect a leader, order a log globally, or keep a registry of who is in.
///
/// What this file adds is the three things N peers need that two peers did not:
///
/// 1. Finding each other. A broadcast beacon carries a *blinded* room tag, so a
///    peer recognises its own room without the room's secret ever crossing the
///    wire, and a listener on the network learns only that some repo exists.
/// 2. Staying connected. `sync.zig` opens a connection, reconciles, and hangs
///    up. Here the connection stays open, because a handshake per sync is the
///    difference between milliseconds and seconds.
/// 3. Staying cheap. The have/want negotiation is set subtraction over *every*
///    object id, which is right once at join and hopeless at 25ms. After the
///    join reconcile a link switches to gossip: announce roots, push what is
///    new, and let the receiver ask for whatever that did not cover.
///
/// The steady-state cost is the thing to protect, and `Frontier` is what
/// protects it. A naive "what am I missing" walks the whole reachable graph on
/// every event, which is O(repo) and involves a filesystem probe per object.
/// `Frontier` keeps the object set in memory and remembers which subtrees are
/// known whole, so a walk prunes at the first change it has already settled and
/// touches only what actually arrived. Gossip is then O(new), not O(repo).
///
/// This is deliberately not a CRDT and does not become one. `live.zig`'s
/// one-writer rule is about two people sharing *one working state*, and it is
/// untouched. Multiplayer here is the other shape: every peer is a writer in
/// its own tree, and the trees converge. Where two peers genuinely edited the
/// same path, `superpose.zig` holds both whole candidates rather than putting
/// conflict markers into a file that then compiles nowhere.
///
/// Moments are not gossiped. They are per-machine capture noise, they arrive by
/// the hundred, and a teammate wants your changes rather than your keystrokes.
/// Verdicts *are* gossiped, and that is the part nothing else has: a verdict is
/// keyed by content, so a green another machine already paid for applies here
/// without running the check again.
pub const protocol_version: u16 = 1;

pub const Error = error{
    NoSecret,
    BadBeacon,
    BadFrame,
    UnknownKind,
    Truncated,
    NoPortAvailable,
    SocketFailed,
    VersionMismatch,
    WrongRoom,
    SelfConnection,
};

// --- room identity ---

const room_domain = "gr-mesh-v1 room tag";

pub const room_tag_len = 8;
pub const peer_id_len = 8;

pub const RoomTag = [room_tag_len]u8;
pub const PeerId = [peer_id_len]u8;

/// The public label for a room, derived from its secret.
///
/// This is what travels in the beacon, and it is a one-way function of the
/// secret for exactly that reason: peers filter on it, and anyone else on the
/// network learns that a mesh exists and nothing about how to join it. The
/// secret itself is only ever used as the PAKE password, so it is never on the
/// wire in any form an attacker can grind offline.
pub fn roomTag(secret: []const u8) RoomTag {
    var h = Blake3.init(.{});
    h.update(room_domain);
    h.update(secret);
    var full: [32]u8 = undefined;
    h.final(&full);
    var tag: RoomTag = undefined;
    @memcpy(&tag, full[0..room_tag_len]);
    return tag;
}

/// A fresh identity for this process. Random rather than derived from the
/// machine, because two peers in two worktrees on one machine are the ordinary
/// case here, not the exotic one, and they must not collide.
pub fn newPeerId(io: std.Io) PeerId {
    var id: PeerId = undefined;
    io.random(&id);
    return id;
}

pub fn peerHex(id: PeerId, buf: *[peer_id_len * 2]u8) []const u8 {
    const hex = std.fmt.bytesToHex(id, .lower);
    @memcpy(buf, &hex);
    return buf[0..];
}

// --- the beacon ---

pub const beacon_magic = "GRMESH1";
pub const beacon_port: u16 = 7790;
pub const beacon_len = beacon_magic.len + 2 + room_tag_len + peer_id_len + 2;

/// What a peer shouts onto the network: which room, who it is, and where to
/// dial it. Nothing else fits, and nothing else belongs.
pub const Beacon = struct {
    room: RoomTag,
    peer: PeerId,
    tcp_port: u16,
};

pub fn encodeBeacon(b: Beacon) [beacon_len]u8 {
    var buf: [beacon_len]u8 = undefined;
    var i: usize = 0;
    @memcpy(buf[i..][0..beacon_magic.len], beacon_magic);
    i += beacon_magic.len;
    std.mem.writeInt(u16, buf[i..][0..2], protocol_version, .big);
    i += 2;
    @memcpy(buf[i..][0..room_tag_len], &b.room);
    i += room_tag_len;
    @memcpy(buf[i..][0..peer_id_len], &b.peer);
    i += peer_id_len;
    std.mem.writeInt(u16, buf[i..][0..2], b.tcp_port, .big);
    return buf;
}

/// Decode a packet, or null if it is not one of ours. A version this build does
/// not know is rejected here rather than half-parsed: the beacon is the one
/// message that arrives unauthenticated, so it gets the strictest reader.
pub fn decodeBeacon(bytes: []const u8) ?Beacon {
    if (bytes.len != beacon_len) return null;
    if (!std.mem.eql(u8, bytes[0..beacon_magic.len], beacon_magic)) return null;
    var i: usize = beacon_magic.len;
    if (std.mem.readInt(u16, bytes[i..][0..2], .big) != protocol_version) return null;
    i += 2;
    var b: Beacon = undefined;
    @memcpy(&b.room, bytes[i..][0..room_tag_len]);
    i += room_tag_len;
    @memcpy(&b.peer, bytes[i..][0..peer_id_len]);
    i += peer_id_len;
    b.tcp_port = std.mem.readInt(u16, bytes[i..][0..2], .big);
    return b;
}

/// Sends beacons. The send socket is ephemeral, so several peers on one machine
/// announce without fighting over a port; only the receive side needs to share
/// one, and that is `Listener`'s problem.
///
/// The all-ones address leads the target list, and it is not decoration. A
/// receive port shared through `SO_REUSEPORT` *load balances* unicast datagrams
/// across the sockets bound to it rather than copying to each, so a beacon sent
/// to 127.0.0.1 reaches exactly one local peer and the rest never learn the
/// mesh exists. A broadcast datagram is delivered to all of them. Since several
/// peers on one machine is the ordinary case here — an agent per worktree —
/// that difference decides whether same-machine multiplayer works at all.
///
/// `discovery.zig` avoids 255.255.255.255 because sending to it can fail
/// depending on how the socket is bound, and that caution is right: it is a
/// target here, not the only one, and `pulse` drops whichever targets refuse.
pub const Announcer = struct {
    socket: net.Socket,
    targets: [16]net.IpAddress,
    count: usize,

    pub fn init(io: std.Io, dest_port: u16) !Announcer {
        const bind_address: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(0) };
        const sock = try bind_address.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
        var a: Announcer = .{ .socket = sock, .targets = undefined, .count = 0 };

        a.targets[0] = .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = dest_port } };
        a.count = 1;

        var scratch: [16]net.IpAddress = undefined;
        const n = discovery.broadcastTargetsOn(&scratch, dest_port);
        for (scratch[0..n]) |t| {
            if (a.count == a.targets.len) break;
            a.targets[a.count] = t;
            a.count += 1;
        }
        return a;
    }

    pub fn deinit(self: *Announcer, io: std.Io) void {
        self.socket.close(io);
    }

    /// One pulse to every target, dropping any that refuses. An interface can
    /// be up but unroutable, and retrying it forever would be a steady stream
    /// of errors about a peer that was never there.
    pub fn pulse(self: *Announcer, io: std.Io, b: Beacon) bool {
        const packet = encodeBeacon(b);
        var sent = false;
        var i: usize = 0;
        while (i < self.count) {
            if (self.socket.send(io, &self.targets[i], &packet)) |_| {
                sent = true;
                i += 1;
            } else |_| {
                self.targets[i] = self.targets[self.count - 1];
                self.count -= 1;
            }
        }
        return sent;
    }
};

// --- the shared receive port ---

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn bind(fd: c_int, addr: *const posix.sockaddr, len: posix.socklen_t) c_int;
extern "c" fn setsockopt(
    fd: c_int,
    level: c_int,
    optname: c_int,
    optval: ?*const anyopaque,
    optlen: posix.socklen_t,
) c_int;
extern "c" fn recvfrom(
    fd: c_int,
    buf: [*]u8,
    len: usize,
    flags: c_int,
    addr: ?*posix.sockaddr,
    addrlen: ?*posix.socklen_t,
) isize;
extern "c" fn close(fd: c_int) c_int;

fn setFlag(fd: c_int, optname: u32, on: bool) void {
    const v: c_int = if (on) 1 else 0;
    _ = setsockopt(
        fd,
        @intCast(posix.SOL.SOCKET),
        @intCast(optname),
        &v,
        @sizeOf(c_int),
    );
}

/// Receives beacons on a port several processes share.
///
/// `std.Io.net.bind` has no reuse option, and a mesh where the second repo on a
/// machine cannot listen would exclude the case this feature exists for: an
/// agent fleet in `sdt work` copies, all in one room, on one laptop. So the
/// socket is opened through libc with `SO_REUSEPORT` set before the bind, which
/// is the only order in which that option means anything. Everything after the
/// bind is an ordinary blocking `recvfrom` with a receive timeout, which keeps
/// this off `std.Io`'s readiness machinery entirely rather than half on it.
pub const Listener = struct {
    fd: c_int,

    pub const Heard = struct {
        beacon: Beacon,
        /// The announcing machine, as the kernel saw it. Trusted for routing
        /// only: the PAKE decides whether the peer is real.
        ip: [4]u8,
    };

    pub fn open(port: u16) !Listener {
        const fd = socket(@intCast(posix.AF.INET), @intCast(posix.SOCK.DGRAM), 0);
        if (fd < 0) return Error.SocketFailed;
        errdefer _ = close(fd);

        setFlag(fd, posix.SO.REUSEADDR, true);
        setFlag(fd, posix.SO.REUSEPORT, true);
        setFlag(fd, posix.SO.BROADCAST, true);

        var addr: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
        if (@hasField(posix.sockaddr.in, "len")) addr.len = @sizeOf(posix.sockaddr.in);
        addr.family = @intCast(posix.AF.INET);
        addr.port = std.mem.nativeToBig(u16, port);
        addr.addr = 0;

        if (bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) {
            return Error.SocketFailed;
        }
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Listener) void {
        _ = close(self.fd);
        self.fd = -1;
    }

    fn setTimeout(self: *Listener, timeout_ms: u32) void {
        var tv: posix.timeval = std.mem.zeroes(posix.timeval);
        tv.sec = @intCast(timeout_ms / 1000);
        tv.usec = @intCast((timeout_ms % 1000) * 1000);
        _ = setsockopt(
            self.fd,
            @intCast(posix.SOL.SOCKET),
            @intCast(posix.SO.RCVTIMEO),
            &tv,
            @sizeOf(posix.timeval),
        );
    }

    /// The next beacon, or null once `timeout_ms` passes with nothing to read.
    /// A packet that is not one of ours is skipped rather than returned, so a
    /// caller never has to know that the port is shared with anything else.
    pub fn next(self: *Listener, timeout_ms: u32) ?Heard {
        self.setTimeout(timeout_ms);
        var buf: [128]u8 = undefined;
        var from: posix.sockaddr.in = std.mem.zeroes(posix.sockaddr.in);
        var from_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);

        const n = recvfrom(self.fd, &buf, buf.len, 0, @ptrCast(&from), &from_len);
        if (n <= 0) return null;
        const beacon = decodeBeacon(buf[0..@intCast(n)]) orelse return null;
        return .{
            .beacon = beacon,
            .ip = @bitCast(from.addr),
        };
    }
};

// --- what this peer already knows ---

const OidSet = std.AutoHashMapUnmanaged([Oid.len]u8, void);

const NodeKind = enum { change, tree, blob, chunk, operation, view };

const Node = struct {
    id: Oid,
    kind: NodeKind,

    fn bulk(self: Node) bool {
        return self.kind == .blob or self.kind == .chunk;
    }
};

/// One traversal's answer: what is missing, what metadata was walked through,
/// and what bulk content hangs off it.
pub const Walk = struct {
    /// Reachable ids this peer does not hold. This is the want list, and it is
    /// the frontier rather than the full absent closure: an object that is not
    /// here cannot be walked through, so its children appear only after it
    /// arrives.
    missing: []Oid,
    /// Changes, trees, operations and views this peer holds and had not settled
    /// before. Small, and the part worth pushing without being asked.
    meta: []Oid,
    /// Blobs and chunks this peer holds and had not settled before. Pushed only
    /// as far as a byte budget allows; whatever does not fit is asked for.
    bulk: []Oid,

    pub fn deinit(self: Walk, alloc: std.mem.Allocator) void {
        alloc.free(self.missing);
        alloc.free(self.meta);
        alloc.free(self.bulk);
    }
};

/// The in-memory picture of what this store holds, and of which subtrees are
/// known whole.
///
/// Both halves exist to keep the steady state cheap. `present` replaces a
/// filesystem probe per object with a hash lookup, and `settled` replaces the
/// walk itself: once a change's closure has been seen complete, every later
/// walk prunes at it, so the cost of a gossip event is the size of what
/// arrived rather than the size of the repository.
///
/// `settled` is only ever extended by a walk that found nothing missing, which
/// is what makes the claim it encodes true. A partial walk settles nothing and
/// simply runs again once the wanted objects land.
///
/// `present` is a cache of a directory that another process can edit — capture
/// writes into it constantly, and `sdt gc` can remove from it. Extra entries in
/// `present` after a gc would make this peer skip asking for something it needs,
/// so the mesh re-seeds on an interval rather than trusting the cache forever.
/// Missing entries are harmless in the other direction: the worst case is
/// asking a peer for bytes that turn out to be here already, and a write of
/// content that already exists is a no-op.
pub const Frontier = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    present: OidSet = .empty,
    settled: OidSet = .empty,

    pub fn init(io: std.Io, alloc: std.mem.Allocator) Frontier {
        return .{ .io = io, .alloc = alloc };
    }

    pub fn deinit(self: *Frontier) void {
        self.present.deinit(self.alloc);
        self.settled.deinit(self.alloc);
    }

    fn lock(self: *Frontier) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *Frontier) void {
        self.mutex.unlock(self.io);
    }

    /// Rebuild `present` from the object directory. One walk of the store, and
    /// the only part of this file whose cost is O(repo).
    pub fn seed(self: *Frontier, st: *Store) !void {
        const ids = try sync.objectIds(st, self.alloc);
        defer self.alloc.free(ids);

        self.lock();
        defer self.unlock();
        self.present.clearRetainingCapacity();
        for (ids) |o| try self.present.put(self.alloc, o.bytes, {});
    }

    /// Record an object this process just wrote.
    pub fn note(self: *Frontier, o: Oid) !void {
        self.lock();
        defer self.unlock();
        try self.present.put(self.alloc, o.bytes, {});
    }

    pub fn holds(self: *Frontier, o: Oid) bool {
        self.lock();
        defer self.unlock();
        return self.present.contains(o.bytes);
    }

    pub fn objectCount(self: *Frontier) usize {
        self.lock();
        defer self.unlock();
        return self.present.count();
    }

    /// Walk everything reachable from `changes` and `ops`, pruning at anything
    /// already settled.
    ///
    /// Descent is typed rather than sniffed, exactly as in `sync.closure`: a ref
    /// tip is a change, an op-head is an operation, and every edge out of those
    /// is known statically. Guessing an object's kind from its bytes would make
    /// a hash collision across types a parsing question instead of a
    /// cryptographic one.
    pub fn walk(
        self: *Frontier,
        st: *Store,
        changes: []const Oid,
        ops: []const Oid,
    ) !Walk {
        const alloc = self.alloc;

        self.lock();
        defer self.unlock();

        var seen: OidSet = .empty;
        defer seen.deinit(alloc);

        var missing: std.ArrayList(Oid) = .empty;
        errdefer missing.deinit(alloc);
        var meta: std.ArrayList(Oid) = .empty;
        errdefer meta.deinit(alloc);
        var bulk: std.ArrayList(Oid) = .empty;
        errdefer bulk.deinit(alloc);

        var stack: std.ArrayList(Node) = .empty;
        defer stack.deinit(alloc);
        for (changes) |c| {
            if (!c.isZero()) try stack.append(alloc, .{ .id = c, .kind = .change });
        }
        for (ops) |o| {
            if (!o.isZero()) try stack.append(alloc, .{ .id = o, .kind = .operation });
        }

        while (stack.pop()) |node| {
            if (self.settled.contains(node.id.bytes)) continue;
            if ((try seen.getOrPut(alloc, node.id.bytes)).found_existing) continue;
            if (!self.present.contains(node.id.bytes)) {
                try missing.append(alloc, node.id);
                continue;
            }
            if (node.bulk()) {
                try bulk.append(alloc, node.id);
            } else {
                try meta.append(alloc, node.id);
            }

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

        // Settling on a walk that found a gap would claim a subtree is whole
        // when a later arrival is still owed, and nothing would ever go back to
        // check. So a partial walk settles nothing and pays to walk again.
        if (missing.items.len == 0) {
            for (meta.items) |o| try self.settled.put(alloc, o.bytes, {});
        }

        return .{
            .missing = try missing.toOwnedSlice(alloc),
            .meta = try meta.toOwnedSlice(alloc),
            .bulk = try bulk.toOwnedSlice(alloc),
        };
    }
};

// --- the gossip protocol ---

/// The wire kinds. Printable on purpose, as in `live.zig`: a mis-framed stream
/// is diagnosable by eye, and the tag is never zero so an all-zero read is
/// always an error rather than a valid empty message.
pub const FrameKind = enum(u8) {
    update = 'U',
    want = 'W',
    give = 'G',
    verdicts = 'D',
    ping = 'P',
    pong = 'Q',
    bye = 'B',

    pub fn fromByte(b: u8) ?FrameKind {
        inline for (@typeInfo(FrameKind).@"enum".fields) |f| {
            if (b == f.value) return @field(FrameKind, f.name);
        }
        return null;
    }

    pub fn label(self: FrameKind) []const u8 {
        return @tagName(self);
    }
};

pub const RefTip = struct {
    name: []const u8,
    tip: Oid,
};

/// "Here is where I am, and here is some of what that needs."
///
/// The roots are the load-bearing half and the objects are an optimisation. A
/// receiver works out what it wants from the roots alone, so an update whose
/// object list guessed wrong — or carried nothing at all — still converges,
/// one round trip later. That invariant is why the sender is allowed to be
/// cheap about what it speculates on.
pub const Update = struct {
    refs: []const RefTip,
    ops: []const Oid,
    objects: []const []const u8,
};

pub const Frame = union(FrameKind) {
    update: Update,
    want: []const Oid,
    give: []const []const u8,
    /// Raw verdict log lines, newline terminated. Lines rather than a parsed
    /// struct because the log is the format of record and a peer running a
    /// newer build may write fields this one does not know; forwarding the line
    /// verbatim keeps those intact instead of silently dropping them.
    verdicts: []const u8,
    ping: u64,
    pong: u64,
    bye: void,
};

pub fn encodeFrame(alloc: std.mem.Allocator, frame: Frame) ![]u8 {
    var body = Writer.init(alloc);
    defer body.deinit();

    switch (frame) {
        .update => |u| {
            try body.putU32(@intCast(u.refs.len));
            for (u.refs) |r| {
                try body.putU16(@intCast(r.name.len));
                try body.bytes(r.name);
                try body.putOid(r.tip);
            }
            try body.putU32(@intCast(u.ops.len));
            for (u.ops) |o| try body.putOid(o);
            try body.putU32(@intCast(u.objects.len));
            for (u.objects) |raw| {
                try body.putU32(@intCast(raw.len));
                try body.bytes(raw);
            }
        },
        .want => |ids| {
            try body.putU32(@intCast(ids.len));
            for (ids) |o| try body.putOid(o);
        },
        .give => |objects| {
            try body.putU32(@intCast(objects.len));
            for (objects) |raw| {
                try body.putU32(@intCast(raw.len));
                try body.bytes(raw);
            }
        },
        .verdicts => |lines| {
            try body.putU32(@intCast(lines.len));
            try body.bytes(lines);
        },
        .ping, .pong => |v| try body.putU64(v),
        .bye => {},
    }

    var out = Writer.init(alloc);
    errdefer out.deinit();
    try out.byte(@intFromEnum(std.meta.activeTag(frame)));
    try out.putU32(@intCast(body.list.items.len));
    try out.bytes(body.list.items);
    return out.finish();
}

/// Decode one frame. Anything that ends early is `Truncated` and an unknown tag
/// is `UnknownKind`; neither reads past the input. Owned slices are freed with
/// `freeFrame`.
pub fn decodeFrame(alloc: std.mem.Allocator, bytes: []const u8) !Frame {
    var r = Reader.init(bytes);
    const tag = (try r.slice(1))[0];
    const kind = FrameKind.fromByte(tag) orelse return Error.UnknownKind;
    const len = try r.takeU32();
    var body = Reader.init(try r.slice(len));

    switch (kind) {
        .update => {
            const nrefs = try body.takeU32();
            if (nrefs > body.remaining() / (2 + Oid.len)) return Error.Truncated;
            const refs = try alloc.alloc(RefTip, nrefs);
            var filled: usize = 0;
            errdefer {
                for (refs[0..filled]) |r2| alloc.free(r2.name);
                alloc.free(refs);
            }
            while (filled < nrefs) : (filled += 1) {
                const nlen = try body.takeU16();
                const name = try alloc.dupe(u8, try body.slice(nlen));
                errdefer alloc.free(name);
                refs[filled] = .{ .name = name, .tip = try body.takeOid() };
            }

            const ops = try takeOids(alloc, &body);
            errdefer alloc.free(ops);
            const objects = try takeBlobs(alloc, &body);
            return .{ .update = .{ .refs = refs, .ops = ops, .objects = objects } };
        },
        .want => return .{ .want = try takeOids(alloc, &body) },
        .give => return .{ .give = try takeBlobs(alloc, &body) },
        .verdicts => {
            const n = try body.takeU32();
            return .{ .verdicts = try alloc.dupe(u8, try body.slice(n)) };
        },
        .ping => return .{ .ping = try body.takeU64() },
        .pong => return .{ .pong = try body.takeU64() },
        .bye => return .bye,
    }
}

fn takeOids(alloc: std.mem.Allocator, body: *Reader) ![]Oid {
    const n = try body.takeU32();
    if (n > body.remaining() / Oid.len) return Error.Truncated;
    const out = try alloc.alloc(Oid, n);
    errdefer alloc.free(out);
    for (out) |*o| o.* = try body.takeOid();
    return out;
}

fn takeBlobs(alloc: std.mem.Allocator, body: *Reader) ![][]const u8 {
    const n = try body.takeU32();
    // Each entry costs at least its own length prefix, so a count the remaining
    // bytes cannot hold is truncation rather than a reason to try a huge
    // allocation on a hostile peer's say-so.
    if (n > body.remaining() / 4) return Error.Truncated;
    const out = try alloc.alloc([]const u8, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |b| alloc.free(b);
        alloc.free(out);
    }
    while (filled < n) : (filled += 1) {
        const blen = try body.takeU32();
        out[filled] = try alloc.dupe(u8, try body.slice(blen));
    }
    return out;
}

pub fn freeFrame(alloc: std.mem.Allocator, frame: Frame) void {
    switch (frame) {
        .update => |u| {
            for (u.refs) |r| alloc.free(r.name);
            alloc.free(u.refs);
            alloc.free(u.ops);
            for (u.objects) |b| alloc.free(b);
            alloc.free(u.objects);
        },
        .want => |ids| alloc.free(ids),
        .give => |objects| {
            for (objects) |b| alloc.free(b);
            alloc.free(objects);
        },
        .verdicts => |lines| alloc.free(lines),
        .ping, .pong, .bye => {},
    }
}

// --- the shared verdict cache ---

fn lineDigest(line: []const u8) [32]u8 {
    var h = Blake3.init(.{});
    h.update("gr-mesh-v1 verdict line");
    h.update(line);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

/// A verdict line is only worth appending if it could have been written here.
/// The check is deliberately shallow — a tree id, then a space — because the
/// log's own reader already skips what it cannot parse, and a stricter gate
/// would reject fields a newer peer knows about and this build does not.
fn plausibleVerdict(line: []const u8) bool {
    if (line.len < Oid.len * 2 + 2) return false;
    if (line.len > 1024) return false;
    if (line[Oid.len * 2] != ' ') return false;
    _ = Oid.fromHex(line[0 .. Oid.len * 2]) catch return false;
    return true;
}

/// Verdicts other machines already paid for.
///
/// A verdict is keyed by `(tree, tier, command, inputs)` and by nothing about
/// the machine that produced it, so a green earned on a teammate's laptop
/// answers here for the identical tree without the check running twice. That is
/// the one thing multiplayer gives that a lone repo cannot have at any price.
///
/// Merging is append-and-dedupe over raw lines rather than a parsed union: the
/// log is append-only and its reader already resolves duplicates by taking the
/// last record, so an arriving line either is new or is a line already held,
/// and there is no third case to arbitrate.
///
/// A verdict adopted from a peer is a claim about a check this machine did not
/// watch run. That is a real trust step, and it is bounded by the room secret:
/// the only peers that can reach this log are the ones that already hold the
/// password to the mesh, which is the same set that could push a change here.
pub const VerdictPool = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    seen: std.AutoHashMapUnmanaged([32]u8, void) = .empty,
    /// How far into the local log this peer has already told the mesh about.
    shared: usize = 0,
    adopted: usize = 0,

    pub fn init(io: std.Io, alloc: std.mem.Allocator) VerdictPool {
        return .{ .io = io, .alloc = alloc };
    }

    pub fn deinit(self: *VerdictPool) void {
        self.seen.deinit(self.alloc);
    }

    fn lock(self: *VerdictPool) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *VerdictPool) void {
        self.mutex.unlock(self.io);
    }

    pub fn seed(self: *VerdictPool, st: *Store) !void {
        const data = try applog.readAll(st, self.alloc, verdict.log_path);
        defer self.alloc.free(data);

        self.lock();
        defer self.unlock();
        self.seen.clearRetainingCapacity();
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try self.seen.put(self.alloc, lineDigest(line), {});
        }
    }

    /// Append every line here that is not held already. Returns how many landed.
    pub fn merge(self: *VerdictPool, st: *Store, lines: []const u8) !usize {
        var fresh: std.ArrayList(u8) = .empty;
        defer fresh.deinit(self.alloc);

        {
            self.lock();
            defer self.unlock();
            var it = std.mem.splitScalar(u8, lines, '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                if (!plausibleVerdict(line)) continue;
                const gop = try self.seen.getOrPut(self.alloc, lineDigest(line));
                if (gop.found_existing) continue;
                try fresh.appendSlice(self.alloc, line);
                try fresh.append(self.alloc, '\n');
            }
        }
        if (fresh.items.len == 0) return 0;

        try applog.append(st, verdict.log_path, fresh.items);

        var n: usize = 0;
        var it = std.mem.splitScalar(u8, fresh.items, '\n');
        while (it.next()) |line| {
            if (line.len != 0) n += 1;
        }
        self.lock();
        defer self.unlock();
        self.adopted += n;
        return n;
    }

    /// The part of the local log this peer has not announced yet, or the whole
    /// log if it shrank — a trimmed log is a log whose tail offset means
    /// nothing, and re-announcing costs a dedupe the receiver does anyway.
    pub fn unshared(self: *VerdictPool, st: *Store, alloc: std.mem.Allocator) !?[]u8 {
        const data = try applog.readAll(st, alloc, verdict.log_path);
        defer alloc.free(data);

        self.lock();
        const from: usize = if (self.shared <= data.len) self.shared else 0;
        self.unlock();

        if (from >= data.len) return null;
        const tail = try alloc.dupe(u8, data[from..]);
        errdefer alloc.free(tail);

        self.lock();
        defer self.unlock();
        self.shared = data.len;
        return tail;
    }

    /// Every line held, for a link that has just opened and knows none of them.
    pub fn everything(self: *VerdictPool, st: *Store, alloc: std.mem.Allocator) ![]u8 {
        const data = try applog.readAll(st, alloc, verdict.log_path);
        self.lock();
        defer self.unlock();
        if (data.len > self.shared) self.shared = data.len;
        return data;
    }

    pub fn adoptedCount(self: *VerdictPool) usize {
        self.lock();
        defer self.unlock();
        return self.adopted;
    }
};

// --- one link to one peer ---

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

fn sleepMs(io: std.Io, ms: u64) void {
    io.sleep(.{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
}

/// A connection that stays up.
///
/// `sync.zig` opens a channel, reconciles, and hangs up, which is the right
/// shape for handing a repo to someone once. It is the wrong shape here: a
/// PAKE, a TCP handshake and a full inventory exchange per edit is seconds of
/// work to move a few kilobytes. A link pays all of that once and then carries
/// frames for as long as both peers are up.
///
/// Sends are serialised by a mutex rather than queued behind a writer thread.
/// The wire's send and receive halves already have separate keys and separate
/// counters, so a reader and a writer never touch the same state; all the mutex
/// has to guarantee is that two senders do not interleave, and a queue would
/// buy nothing else.
pub const Link = struct {
    mesh: *Mesh,
    conn: *wormhole.Conn,
    wire: sync.Wire,
    peer: PeerId,
    send_mutex: std.Io.Mutex = .init,
    alive: std.atomic.Value(bool) = .init(true),
    thread: ?std.Thread = null,
    /// The roots this peer last announced, and the reason a `give` that did not
    /// finish the job can be followed by another `want` without the peer having
    /// to repeat itself. Touched only by this link's read loop.
    peer_tips: []Oid = &.{},
    peer_ops: []Oid = &.{},
    rtt_us: std.atomic.Value(u64) = .init(0),
    sent: std.atomic.Value(u64) = .init(0),
    received: std.atomic.Value(u64) = .init(0),

    pub fn send(self: *Link, frame: Frame) !void {
        const alloc = self.mesh.alloc;
        const bytes = try encodeFrame(alloc, frame);
        defer alloc.free(bytes);

        self.send_mutex.lockUncancelable(self.mesh.io);
        defer self.send_mutex.unlock(self.mesh.io);
        try self.wire.sendBytes(bytes);
    }

    fn recvFrame(self: *Link, alloc: std.mem.Allocator) !Frame {
        const raw = try self.wire.recvBytes(alloc);
        defer alloc.free(raw);
        return decodeFrame(alloc, raw);
    }

    fn rememberRoots(self: *Link, u: Update) !void {
        const alloc = self.mesh.alloc;
        const tips = try alloc.alloc(Oid, u.refs.len);
        errdefer alloc.free(tips);
        for (tips, u.refs) |*t, r| t.* = r.tip;
        const ops = try alloc.dupe(Oid, u.ops);

        alloc.free(self.peer_tips);
        alloc.free(self.peer_ops);
        self.peer_tips = tips;
        self.peer_ops = ops;
    }

    /// Everything the peer asked for that this peer actually holds. A sparse
    /// store legitimately advertises roots whose blobs it never had, so a want
    /// this end cannot fill is answered short rather than treated as an error.
    fn fill(self: *Link, ids: []const Oid) !void {
        const alloc = self.mesh.alloc;
        var raws: std.ArrayList([]const u8) = .empty;
        defer {
            for (raws.items) |r| alloc.free(r);
            raws.deinit(alloc);
        }
        for (ids) |o| {
            const raw = self.mesh.st.readRaw(o) catch continue;
            try raws.append(alloc, raw);
        }
        _ = self.sent.fetchAdd(raws.items.len, .monotonic);
        try self.send(.{ .give = raws.items });
    }

    /// Absorb objects, then either ask for the rest or settle up.
    ///
    /// The want loop is bounded because each round strictly shrinks what is
    /// reachable-but-absent: an object that arrives is never asked for again,
    /// and one the peer cannot produce is dropped by `refused`-style short
    /// answering rather than requested forever. The counter is a backstop for
    /// a peer that is lying, not for the normal case.
    fn absorb(self: *Link, objects: []const []const u8, round: u32) !void {
        var written: usize = 0;
        for (objects) |raw| {
            const o = self.mesh.st.writeRaw(raw) catch continue;
            self.mesh.frontier.note(o) catch {};
            written += 1;
        }
        _ = self.received.fetchAdd(written, .monotonic);

        if (self.peer_tips.len == 0 and self.peer_ops.len == 0) return;

        var w = try self.mesh.frontier.walk(
            self.mesh.st,
            self.peer_tips,
            self.peer_ops,
        );
        defer w.deinit(self.mesh.alloc);

        if (w.missing.len > 0 and round < self.mesh.opts.max_rounds) {
            try self.send(.{ .want = w.missing });
            return;
        }
        try self.mesh.absorbHeads(self.peer_ops);
    }

    fn readLoop(self: *Link) void {
        const alloc = self.mesh.alloc;
        var round: u32 = 0;
        while (self.alive.load(.acquire) and !self.mesh.stop.load(.acquire)) {
            const frame = self.recvFrame(alloc) catch break;
            defer freeFrame(alloc, frame);

            switch (frame) {
                .update => |u| {
                    round = 0;
                    self.rememberRoots(u) catch break;
                    self.absorb(u.objects, round) catch break;
                },
                .want => |ids| self.fill(ids) catch break,
                .give => |objects| {
                    round += 1;
                    self.absorb(objects, round) catch break;
                },
                .verdicts => |lines| {
                    _ = self.mesh.verdicts.merge(self.mesh.st, lines) catch {};
                },
                .ping => |v| self.send(.{ .pong = v }) catch break,
                .pong => |v| {
                    const sent_us: u64 = v;
                    const now_us: u64 = @intCast(@divTrunc(
                        std.Io.Clock.now(.real, self.mesh.io).nanoseconds,
                        1000,
                    ));
                    if (now_us > sent_us) self.rtt_us.store(now_us - sent_us, .monotonic);
                },
                .bye => break,
            }
        }
        self.alive.store(false, .release);
    }

    fn shutdown(self: *Link) void {
        if (!self.alive.swap(false, .acq_rel)) return;
        self.send(.bye) catch {};
    }

    fn destroy(self: *Link) void {
        const alloc = self.mesh.alloc;
        alloc.free(self.peer_tips);
        alloc.free(self.peer_ops);
        self.conn.destroy();
        alloc.destroy(self);
    }
};

// --- the mesh ---

pub const Seed = struct {
    host: []const u8,
    port: u16,
};

pub const Options = struct {
    /// The room password. Never sent; both ends derive the channel key from it
    /// through the PAKE, and only its blinded tag is ever broadcast.
    secret: []const u8,
    /// Where beacons are sent and heard. Shared by every peer in every room on
    /// the network, which is why the room tag is in the packet.
    beacon_port: u16 = beacon_port,
    /// 0 asks the kernel for whatever is free, which is right: the beacon
    /// carries the answer, so nothing has to agree on a number in advance.
    listen_port: u16 = 0,
    /// How often local state is checked for something worth announcing. This is
    /// the floor on how long an edit sits before it reaches the wire; the wire
    /// itself is sub-millisecond on a LAN.
    interval_ms: u32 = 25,
    announce_ms: u32 = 250,
    /// Idle re-announce. A peer that missed an update recovers on the next one
    /// of these instead of waiting for the next edit, which is what makes a
    /// dropped frame a latency problem rather than a correctness problem.
    heartbeat_ms: u32 = 2_000,
    /// How often the object cache is rebuilt from disk, bounding how long a
    /// concurrent `sdt gc` can leave it claiming something that is gone.
    reseed_ms: u32 = 30_000,
    /// How many bytes of bulk content one update may carry unasked. Metadata is
    /// never capped: it is small, and it is what lets the receiver work out
    /// what to ask for.
    push_budget: usize = 256 * 1024,
    /// A stuck want loop is a bug, not something to retry forever.
    max_rounds: u32 = 64,
    /// Peers to dial directly, for the case where broadcast does not reach:
    /// a VPN, a tunnel, a machine across the internet. Still no server — this
    /// is one peer's address, not a registry.
    seeds: []const Seed = &.{},
    /// Whether verdicts travel with changes.
    share_verdicts: bool = true,
    /// A path prefix limiting what the join reconcile transfers.
    scope: []const u8 = "",
};

pub const Status = struct {
    peers: usize,
    objects: usize,
    verdicts_adopted: usize,
    objects_sent: u64,
    objects_received: u64,
    /// Round trip to the nearest peer, or zero before the first exchange.
    best_rtt_us: u64,
    tcp_port: u16,
};

/// N peers, one repo, nothing in the middle.
///
/// Everything here is threads over blocking sockets rather than one event loop,
/// because the work is genuinely independent and the shared state is small: an
/// accept loop, a beacon in each direction, a poll that notices local edits, and
/// one reader per link. What they share is the store, and the rule for that is
/// simple — content-addressed writes are idempotent and need no lock, while
/// anything that moves a ref or a head is serialised by `store_mutex`.
pub const Mesh = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    st: *Store,
    opts: Options,

    room: RoomTag,
    me: PeerId,

    store_mutex: std.Io.Mutex = .init,
    frontier: Frontier,
    verdicts: VerdictPool,

    server: net.Server,
    tcp_port: u16,

    links_mutex: std.Io.Mutex = .init,
    links: std.ArrayList(*Link) = .empty,
    pushed_mutex: std.Io.Mutex = .init,
    /// Peers already linked, so a beacon that keeps arriving does not keep
    /// opening connections to the same machine.
    known: std.AutoHashMapUnmanaged(PeerId, i64) = .empty,
    /// Objects already handed to the mesh, so a store that is legitimately
    /// short of something does not re-announce the same metadata forever.
    pushed: OidSet = .empty,

    stop: std.atomic.Value(bool) = .init(false),
    threads: std.ArrayList(std.Thread) = .empty,
    last_fingerprint: Oid = Oid.zero(),

    pub fn open(io: std.Io, alloc: std.mem.Allocator, st: *Store, opts: Options) !*Mesh {
        if (opts.secret.len == 0) return Error.NoSecret;

        var address: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(opts.listen_port) };
        var server = try address.listen(io, .{ .reuse_address = true });
        errdefer server.deinit(io);

        const m = try alloc.create(Mesh);
        errdefer alloc.destroy(m);
        m.* = .{
            .io = io,
            .alloc = alloc,
            .st = st,
            .opts = opts,
            .room = roomTag(opts.secret),
            .me = newPeerId(io),
            .frontier = Frontier.init(io, alloc),
            .verdicts = VerdictPool.init(io, alloc),
            .server = server,
            .tcp_port = server.socket.address.getPort(),
        };

        try m.frontier.seed(st);
        try m.verdicts.seed(st);
        return m;
    }

    pub fn close(self: *Mesh) void {
        self.stop.store(true, .release);
        // Closing a socket another thread is blocked in `accept` on would leave
        // that thread reading a `Server` this one has already invalidated. One
        // throwaway connection to our own port returns it from the syscall, so
        // the teardown order stays boring: stop, wake, join, only then free.
        self.wakeAccept();

        for (self.threads.items) |t| t.join();
        self.threads.deinit(self.alloc);
        self.server.deinit(self.io);

        self.lockLinks();
        for (self.links.items) |l| {
            l.shutdown();
            if (l.thread) |t| t.join();
            l.destroy();
        }
        self.links.deinit(self.alloc);
        self.unlockLinks();

        self.known.deinit(self.alloc);
        self.pushed.deinit(self.alloc);
        self.frontier.deinit();
        self.verdicts.deinit();
        self.alloc.destroy(self);
    }

    fn lockLinks(self: *Mesh) void {
        self.links_mutex.lockUncancelable(self.io);
    }

    fn unlockLinks(self: *Mesh) void {
        self.links_mutex.unlock(self.io);
    }

    fn lockStore(self: *Mesh) void {
        self.store_mutex.lockUncancelable(self.io);
    }

    fn unlockStore(self: *Mesh) void {
        self.store_mutex.unlock(self.io);
    }

    pub fn beacon(self: *Mesh) Beacon {
        return .{ .room = self.room, .peer = self.me, .tcp_port = self.tcp_port };
    }

    pub fn status(self: *Mesh) Status {
        var out: Status = .{
            .peers = 0,
            .objects = self.frontier.objectCount(),
            .verdicts_adopted = self.verdicts.adoptedCount(),
            .objects_sent = 0,
            .objects_received = 0,
            .best_rtt_us = 0,
            .tcp_port = self.tcp_port,
        };
        self.lockLinks();
        defer self.unlockLinks();
        for (self.links.items) |l| {
            if (!l.alive.load(.acquire)) continue;
            out.peers += 1;
            out.objects_sent += l.sent.load(.monotonic);
            out.objects_received += l.received.load(.monotonic);
            const rtt = l.rtt_us.load(.monotonic);
            if (rtt != 0 and (out.best_rtt_us == 0 or rtt < out.best_rtt_us)) {
                out.best_rtt_us = rtt;
            }
        }
        return out;
    }

    /// Take the peer's op-heads and collapse whatever that leaves into one view.
    ///
    /// This is the whole of convergence, and it is `sync.zig`'s unchanged: the
    /// merge is total and deterministic down to the content hash, so every peer
    /// that has seen the same operations lands on the same view without anyone
    /// being asked to arbitrate. Serialised here only because two links can
    /// finish absorbing at the same instant and `refs/heads` holds one tip.
    pub fn absorbHeads(self: *Mesh, peer_ops: []const Oid) !void {
        self.lockStore();
        defer self.unlockStore();
        try sync.adoptHeads(self.st, self.alloc, peer_ops);
        _ = try sync.converge(self.st, self.alloc);
    }

    fn localRoots(self: *Mesh, alloc: std.mem.Allocator) !struct {
        refs: []live.RefAdvert,
        tips: []Oid,
        ops: []Oid,
    } {
        const refs = try sync.localRefs(self.st, alloc);
        errdefer sync.freeRefs(alloc, refs);
        const tips = try alloc.alloc(Oid, refs.len);
        errdefer alloc.free(tips);
        for (tips, refs) |*t, r| t.* = r.tip;
        const ops = try opdag.heads(self.st, alloc);
        return .{ .refs = refs, .tips = tips, .ops = ops };
    }

    /// A cheap identity for "where this repo is", so the poll thread can tell
    /// an edit from a quiet tick without hashing the tree.
    fn fingerprint(self: *Mesh, alloc: std.mem.Allocator) !Oid {
        const roots = try self.localRoots(alloc);
        defer {
            sync.freeRefs(alloc, roots.refs);
            alloc.free(roots.tips);
            alloc.free(roots.ops);
        }
        var h = oid.Hasher.init();
        h.update("gr-mesh-v1 fingerprint");
        for (roots.refs) |r| {
            h.update(r.name);
            h.update(&r.tip.bytes);
        }
        for (roots.ops) |o| h.update(&o.bytes);
        return h.finalOid();
    }

    fn broadcast(self: *Mesh, frame: Frame) void {
        self.lockLinks();
        const snapshot = self.alloc.dupe(*Link, self.links.items) catch {
            self.unlockLinks();
            return;
        };
        self.unlockLinks();
        defer self.alloc.free(snapshot);

        for (snapshot) |l| {
            if (!l.alive.load(.acquire)) continue;
            l.send(frame) catch l.alive.store(false, .release);
        }
    }

    /// Announce where this peer is, and hand over what that most likely needs.
    ///
    /// Returns true when the walk was clean. A walk that found this store short
    /// of something is a store whose metadata will not settle, so the caller
    /// backs off rather than paying for a full traversal every tick.
    fn pushUpdate(self: *Mesh, with_objects: bool) !bool {
        const alloc = self.alloc;
        const roots = try self.localRoots(alloc);
        defer {
            sync.freeRefs(alloc, roots.refs);
            alloc.free(roots.tips);
            alloc.free(roots.ops);
        }

        var tips: std.ArrayList(RefTip) = .empty;
        defer tips.deinit(alloc);
        for (roots.refs) |r| try tips.append(alloc, .{ .name = r.name, .tip = r.tip });

        var raws: std.ArrayList([]const u8) = .empty;
        defer {
            for (raws.items) |b| alloc.free(b);
            raws.deinit(alloc);
        }

        var clean = true;
        if (with_objects) {
            var w = try self.frontier.walk(self.st, roots.tips, roots.ops);
            defer w.deinit(alloc);
            clean = w.missing.len == 0;

            var budget = self.opts.push_budget;
            try self.pack(&raws, w.meta, null);
            try self.pack(&raws, w.bulk, &budget);
        }

        self.broadcast(.{ .update = .{
            .refs = tips.items,
            .ops = roots.ops,
            .objects = raws.items,
        } });
        return clean;
    }

    /// Read objects this peer has not handed over before, up to a byte budget.
    /// A null budget means metadata, which is never capped.
    fn pack(
        self: *Mesh,
        into: *std.ArrayList([]const u8),
        ids: []const Oid,
        budget: ?*usize,
    ) !void {
        for (ids) |o| {
            if (budget) |b| {
                if (b.* == 0) return;
            }
            self.pushed_mutex.lockUncancelable(self.io);
            const gop = try self.pushed.getOrPut(self.alloc, o.bytes);
            const already = gop.found_existing;
            self.pushed_mutex.unlock(self.io);
            if (already) continue;

            const raw = self.st.readRaw(o) catch continue;
            errdefer self.alloc.free(raw);
            if (budget) |b| b.* -|= raw.len;
            try into.append(self.alloc, raw);
        }
    }

    /// Hand the mesh whichever verdict lines it has not been told about yet.
    fn shareVerdicts(self: *Mesh) !void {
        if (!self.opts.share_verdicts) return;
        const lines = (try self.verdicts.unshared(self.st, self.alloc)) orelse return;
        defer self.alloc.free(lines);
        if (lines.len == 0) return;
        self.broadcast(.{ .verdicts = lines });
    }

    fn parsePeerId(hex: []const u8) ?PeerId {
        if (hex.len != peer_id_len * 2) return null;
        var id: PeerId = undefined;
        _ = std.fmt.hexToBytes(&id, hex) catch return null;
        return id;
    }

    fn alreadyLinked(self: *Mesh, peer: PeerId) bool {
        self.lockLinks();
        defer self.unlockLinks();
        for (self.links.items) |l| {
            if (l.alive.load(.acquire) and std.mem.eql(u8, &l.peer, &peer)) return true;
        }
        return false;
    }

    /// Bring a fresh connection all the way up: authenticate it, reconcile the
    /// two histories once in full, and only then let it gossip.
    ///
    /// The full reconcile is deliberate and happens exactly once per link. It
    /// is the step that makes every later message a delta: after it, both ends
    /// hold each other's closure, so an update needs to carry only what has
    /// happened since. Skipping it and relying on gossip alone would mean a peer
    /// joining an old repo learns its history one edit at a time, or never.
    fn establish(self: *Mesh, conn: *wormhole.Conn, dialing: bool) !void {
        const io = self.io;
        const alloc = self.alloc;

        const session = if (dialing)
            try wormhole.receiverHandshakeWith(io, conn.channel(), self.opts.secret)
        else
            try wormhole.senderHandshakeWith(io, conn.channel(), self.opts.secret);

        const link = try alloc.create(Link);
        var adopted = false;
        defer if (!adopted) alloc.destroy(link);

        link.* = .{
            .mesh = self,
            .conn = conn,
            .wire = sync.Wire.init(io, alloc, conn.channel(), session),
            .peer = std.mem.zeroes(PeerId),
        };

        var me_hex: [peer_id_len * 2]u8 = undefined;
        _ = peerHex(self.me, &me_hex);
        const sync_opts = sync.Options{
            .scope = self.opts.scope,
            .peer = &me_hex,
            .now_ms = nowMillis(io),
        };

        self.lockStore();
        const outcome = if (dialing)
            sync.respond(self.st, alloc, &link.wire, sync_opts)
        else
            sync.initiate(self.st, alloc, &link.wire, sync_opts);
        self.unlockStore();

        const report = try outcome;
        defer report.deinit(alloc);

        const peer = parsePeerId(report.peer) orelse return Error.BadFrame;
        if (std.mem.eql(u8, &peer, &self.me)) return Error.SelfConnection;
        if (self.alreadyLinked(peer)) return Error.SelfConnection;
        link.peer = peer;

        // The reconcile wrote objects straight into the store, and settling the
        // walk over what is now held is what stops the first gossip update from
        // re-announcing the entire history it just finished transferring.
        try self.frontier.seed(self.st);
        try self.settleLocal();

        {
            self.lockLinks();
            defer self.unlockLinks();
            try self.links.append(alloc, link);
            try self.known.put(alloc, peer, nowMillis(io));
        }
        adopted = true;

        if (self.opts.share_verdicts) {
            const lines = self.verdicts.everything(self.st, alloc) catch &.{};
            defer alloc.free(lines);
            if (lines.len > 0) link.send(.{ .verdicts = lines }) catch {};
        }

        link.thread = std.Thread.spawn(.{}, Link.readLoop, .{link}) catch null;
        if (link.thread == null) link.alive.store(false, .release);
    }

    /// Mark everything currently held as settled, so gossip starts from a
    /// baseline rather than from nothing.
    fn settleLocal(self: *Mesh) !void {
        const alloc = self.alloc;
        const roots = try self.localRoots(alloc);
        defer {
            sync.freeRefs(alloc, roots.refs);
            alloc.free(roots.tips);
            alloc.free(roots.ops);
        }
        var w = try self.frontier.walk(self.st, roots.tips, roots.ops);
        defer w.deinit(alloc);

        self.pushed_mutex.lockUncancelable(self.io);
        defer self.pushed_mutex.unlock(self.io);
        for (w.meta) |o| try self.pushed.put(alloc, o.bytes, {});
        for (w.bulk) |o| try self.pushed.put(alloc, o.bytes, {});
    }

    fn dial(self: *Mesh, address: net.IpAddress) void {
        var target = address;
        const stream = target.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch return;
        const conn = wormhole.Conn.adopt(self.io, self.alloc, stream) catch {
            stream.close(self.io);
            return;
        };
        self.establish(conn, true) catch {
            conn.destroy();
            return;
        };
    }

    /// Whether this end is the one that dials.
    ///
    /// Both peers see each other's beacon at roughly the same moment, and both
    /// dialing would open two connections where one is wanted. The lower peer
    /// id dials. It needs no negotiation, both ends compute the same answer
    /// from bytes they already have, and the ids are random so it does not
    /// systematically load one machine.
    fn shouldDial(self: *const Mesh, other: PeerId) bool {
        return std.mem.lessThan(u8, &self.me, &other);
    }

    fn recentlySeen(self: *Mesh, peer: PeerId, now_ms: i64, cooldown_ms: i64) bool {
        self.lockLinks();
        defer self.unlockLinks();
        if (self.known.get(peer)) |at| {
            if (now_ms - at < cooldown_ms) return true;
        }
        self.known.put(self.alloc, peer, now_ms) catch {};
        return false;
    }

    fn reap(self: *Mesh) void {
        self.lockLinks();
        defer self.unlockLinks();
        var i: usize = 0;
        while (i < self.links.items.len) {
            const l = self.links.items[i];
            if (l.alive.load(.acquire)) {
                i += 1;
                continue;
            }
            _ = self.links.swapRemove(i);
            _ = self.known.remove(l.peer);
            if (l.thread) |t| t.join();
            l.destroy();
        }
    }

    fn wakeAccept(self: *Mesh) void {
        var address: net.IpAddress = .{
            .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = self.tcp_port },
        };
        const stream = address.connect(self.io, .{ .mode = .stream, .protocol = .tcp }) catch return;
        stream.close(self.io);
    }

    /// Sleep in slices so a stop is noticed promptly rather than after whatever
    /// interval this loop happens to use.
    fn rest(self: *Mesh, ms: u64) void {
        var left = ms;
        while (left > 0 and !self.stop.load(.acquire)) {
            const slice = @min(left, 200);
            sleepMs(self.io, slice);
            left -= slice;
        }
    }

    fn verdictLogLen(self: *Mesh) u64 {
        const file = self.st.root.openFile(self.io, verdict.log_path, .{}) catch return 0;
        defer file.close(self.io);
        return file.length(self.io) catch 0;
    }

    fn acceptLoop(self: *Mesh) void {
        while (!self.stop.load(.acquire)) {
            const stream = self.server.accept(self.io) catch break;
            if (self.stop.load(.acquire)) {
                stream.close(self.io);
                break;
            }
            const conn = wormhole.Conn.adopt(self.io, self.alloc, stream) catch {
                stream.close(self.io);
                continue;
            };
            // Handled inline rather than on a spawned thread: a join is rare,
            // and a connection whose lifetime outlives the loop that made it is
            // the shape that turns a shutdown into a use-after-free.
            self.establish(conn, false) catch {
                conn.destroy();
                continue;
            };
        }
    }

    fn announceLoop(self: *Mesh) void {
        var announcer = Announcer.init(self.io, self.opts.beacon_port) catch return;
        defer announcer.deinit(self.io);
        while (!self.stop.load(.acquire)) {
            _ = announcer.pulse(self.io, self.beacon());
            self.rest(self.opts.announce_ms);
        }
    }

    fn discoverLoop(self: *Mesh) void {
        var listener = Listener.open(self.opts.beacon_port) catch return;
        defer listener.deinit();

        while (!self.stop.load(.acquire)) {
            const heard = listener.next(250) orelse continue;
            if (!std.mem.eql(u8, &heard.beacon.room, &self.room)) continue;
            if (std.mem.eql(u8, &heard.beacon.peer, &self.me)) continue;
            if (!self.shouldDial(heard.beacon.peer)) continue;
            if (self.alreadyLinked(heard.beacon.peer)) continue;
            if (self.recentlySeen(heard.beacon.peer, nowMillis(self.io), 2_000)) continue;

            self.dial(.{ .ip4 = .{ .bytes = heard.ip, .port = heard.beacon.tcp_port } });
        }
    }

    /// Dial the addresses the user named. Broadcast does not cross a router, so
    /// this is how a mesh spans two networks without anything in the middle
    /// starting to look like a service.
    fn seedLoop(self: *Mesh) void {
        if (self.opts.seeds.len == 0) return;
        while (!self.stop.load(.acquire)) {
            for (self.opts.seeds) |seed| {
                if (self.stop.load(.acquire)) return;
                const conn = wormhole.Conn.open(self.io, self.alloc, seed.host, seed.port) catch continue;
                self.establish(conn, true) catch {
                    conn.destroy();
                    continue;
                };
            }
            sleepMs(self.io, 5_000);
        }
    }

    fn pollLoop(self: *Mesh) void {
        const io = self.io;
        var last_heartbeat = nowMillis(io);
        var last_reseed = last_heartbeat;
        var last_verdict_len: u64 = self.verdictLogLen();
        var backoff: u32 = 1;

        self.last_fingerprint = self.fingerprint(self.alloc) catch Oid.zero();

        while (!self.stop.load(.acquire)) {
            self.rest(self.opts.interval_ms * backoff);
            if (self.stop.load(.acquire)) break;
            self.reap();

            const now = nowMillis(io);
            const fp = self.fingerprint(self.alloc) catch continue;
            const vlen = self.verdictLogLen();
            const moved = !fp.eql(self.last_fingerprint);

            if (moved) {
                self.last_fingerprint = fp;
                const clean = self.pushUpdate(true) catch true;
                // A store that is short of something never settles, so a full
                // walk every tick would be the steady state rather than the
                // exception. Back off and let the want rounds catch up.
                backoff = if (clean) 1 else 20;
            }
            if (vlen != last_verdict_len) {
                last_verdict_len = vlen;
                self.shareVerdicts() catch {};
            }

            if (now - last_heartbeat >= self.opts.heartbeat_ms) {
                last_heartbeat = now;
                _ = self.pushUpdate(false) catch {};
                const us: u64 = @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1000));
                self.broadcast(.{ .ping = us });
            }
            if (now - last_reseed >= self.opts.reseed_ms) {
                last_reseed = now;
                self.frontier.seed(self.st) catch {};
            }
        }
    }

    /// Bring the mesh up. Returns as soon as the threads are running; the
    /// caller decides what to do while it converges, and calls `close` to stop.
    pub fn start(self: *Mesh) !void {
        try self.settleLocal();
        try self.threads.append(self.alloc, try std.Thread.spawn(.{}, acceptLoop, .{self}));
        try self.threads.append(self.alloc, try std.Thread.spawn(.{}, announceLoop, .{self}));
        try self.threads.append(self.alloc, try std.Thread.spawn(.{}, discoverLoop, .{self}));
        try self.threads.append(self.alloc, try std.Thread.spawn(.{}, pollLoop, .{self}));
        if (self.opts.seeds.len > 0) {
            try self.threads.append(self.alloc, try std.Thread.spawn(.{}, seedLoop, .{self}));
        }
    }
};

// --- settings ---

/// The mesh is opt-in and off by default. Nothing here listens, announces or
/// dials until a room secret exists in config, and the secret is the whole of
/// membership: holding it is what makes a peer a peer.
pub const Settings = struct {
    secret: ?[]u8 = null,
    enabled: bool = false,
    interval_ms: u32 = 25,
    share_verdicts: bool = true,

    pub fn deinit(self: Settings, alloc: std.mem.Allocator) void {
        if (self.secret) |s| alloc.free(s);
    }
};

fn boolOf(v: []const u8) bool {
    return !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no"));
}

pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "mesh.secret")) |maybe| {
        if (maybe) |v| {
            if (v.len == 0) alloc.free(v) else out.secret = v;
        }
    } else |_| {}
    out.enabled = out.secret != null;

    if (config.get(store, alloc, "mesh.enabled")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            if (!boolOf(v)) out.enabled = false;
        }
    } else |_| {}

    if (config.get(store, alloc, "mesh.interval-ms")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.interval_ms = std.fmt.parseInt(u32, v, 10) catch out.interval_ms;
        }
    } else |_| {}

    if (config.get(store, alloc, "mesh.verdicts")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.share_verdicts = boolOf(v);
        }
    } else |_| {}
    return out;
}

/// A fresh room secret: five words from the wormhole list, which is enough
/// entropy to be unguessable and few enough to read down a phone line.
pub fn newSecret(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var raw: [5]u8 = undefined;
    try io.randomSecure(&raw);
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}-{s}-{s}", .{
        wormhole.words[raw[0]],
        wormhole.words[raw[1]],
        wormhole.words[raw[2]],
        wormhole.words[raw[3]],
        wormhole.words[raw[4]],
    });
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
    fn putOid(self: *Writer, o: Oid) !void {
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
    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }
    fn slice(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn takeU16(self: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try self.slice(2))[0..2], .big);
    }
    fn takeU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.slice(4))[0..4], .big);
    }
    fn takeU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.slice(8))[0..8], .big);
    }
    fn takeOid(self: *Reader) Error!Oid {
        var o: Oid = undefined;
        @memcpy(&o.bytes, try self.slice(Oid.len));
        return o;
    }
};

// --- tests ---

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

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

test "a room tag identifies the room without carrying it" {
    const secret = "43-hydrant-hostel-orbit-marble";
    const tag = roomTag(secret);
    try testing.expectEqualSlices(u8, &tag, &roomTag(secret));
    try testing.expect(!std.mem.eql(u8, &tag, &roomTag("43-hydrant-hostel-orbit-marbles")));

    // The tag is what goes on the wire, so the secret must not be recoverable
    // by reading it, and must not be sitting inside it in the clear.
    try testing.expect(std.mem.indexOf(u8, &tag, "hydrant") == null);
    try testing.expect(std.mem.indexOf(u8, secret, &tag) == null);
}

test "a beacon round trips and rejects anything that is not one" {
    const b = Beacon{
        .room = roomTag("a room"),
        .peer = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .tcp_port = 51234,
    };
    const packet = encodeBeacon(b);
    const back = decodeBeacon(&packet) orelse return error.TestExpectedDecode;
    try testing.expectEqualSlices(u8, &b.room, &back.room);
    try testing.expectEqualSlices(u8, &b.peer, &back.peer);
    try testing.expectEqual(b.tcp_port, back.tcp_port);

    try testing.expectEqual(@as(?Beacon, null), decodeBeacon("nope"));
    try testing.expectEqual(@as(?Beacon, null), decodeBeacon(packet[0 .. packet.len - 1]));
    try testing.expectEqual(@as(?Beacon, null), decodeBeacon(&[_]u8{0} ** beacon_len));

    var wrong_version = packet;
    wrong_version[beacon_magic.len] = 0xff;
    try testing.expectEqual(@as(?Beacon, null), decodeBeacon(&wrong_version));
}

test "the lower peer id dials and the higher one waits" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    var low = Mesh{
        .io = io,
        .alloc = alloc,
        .st = &st,
        .opts = .{ .secret = "x" },
        .room = roomTag("x"),
        .me = [_]u8{0} ** peer_id_len,
        .frontier = Frontier.init(io, alloc),
        .verdicts = VerdictPool.init(io, alloc),
        .server = undefined,
        .tcp_port = 0,
    };
    const high: PeerId = [_]u8{0xff} ** peer_id_len;

    // Exactly one side dials, whichever way round the pair is looked at.
    try testing.expect(low.shouldDial(high));
    low.me = high;
    try testing.expect(!low.shouldDial([_]u8{0} ** peer_id_len));
    try testing.expect(!low.shouldDial(high));
}

test "every frame kind round trips" {
    const alloc = testing.allocator;

    const refs = [_]RefTip{
        .{ .name = "main", .tip = Oid.ofBytes("tip a") },
        .{ .name = "feature/x", .tip = Oid.ofBytes("tip b") },
    };
    const ops = [_]Oid{ Oid.ofBytes("op a"), Oid.ofBytes("op b") };
    const objects = [_][]const u8{ "raw one", "", "raw three" };

    const cases = [_]Frame{
        .{ .update = .{ .refs = &refs, .ops = &ops, .objects = &objects } },
        .{ .want = &ops },
        .{ .give = &objects },
        .{ .verdicts = "abc\ndef\n" },
        .{ .ping = 1234567890 },
        .{ .pong = 987654321 },
        .bye,
    };

    for (cases) |frame| {
        const enc = try encodeFrame(alloc, frame);
        defer alloc.free(enc);
        const back = try decodeFrame(alloc, enc);
        defer freeFrame(alloc, back);
        try testing.expectEqual(std.meta.activeTag(frame), std.meta.activeTag(back));

        switch (back) {
            .update => |u| {
                try testing.expectEqual(refs.len, u.refs.len);
                try testing.expectEqualStrings("main", u.refs[0].name);
                try testing.expect(u.refs[1].tip.eql(refs[1].tip));
                try testing.expectEqual(ops.len, u.ops.len);
                try testing.expectEqual(objects.len, u.objects.len);
                try testing.expectEqualStrings("raw three", u.objects[2]);
            },
            .want => |ids| try testing.expect(ids[1].eql(ops[1])),
            .give => |objs| try testing.expectEqualStrings("raw one", objs[0]),
            .verdicts => |lines| try testing.expectEqualStrings("abc\ndef\n", lines),
            .ping => |v| try testing.expectEqual(@as(u64, 1234567890), v),
            .pong => |v| try testing.expectEqual(@as(u64, 987654321), v),
            .bye => {},
        }
    }
}

test "a truncated or unknown frame is refused rather than half read" {
    const alloc = testing.allocator;
    const ops = [_]Oid{Oid.ofBytes("op")};
    const enc = try encodeFrame(alloc, .{ .want = &ops });
    defer alloc.free(enc);

    var i: usize = 0;
    while (i < enc.len) : (i += 1) {
        try testing.expectError(Error.Truncated, decodeFrame(alloc, enc[0..i]));
    }

    var bad = try alloc.dupe(u8, enc);
    defer alloc.free(bad);
    bad[0] = 'z';
    try testing.expectError(Error.UnknownKind, decodeFrame(alloc, bad));

    // A count no payload could hold must not become an allocation that size.
    const lying = [_]u8{ 'W', 0, 0, 0, 4, 0xff, 0xff, 0xff, 0xff };
    try testing.expectError(Error.Truncated, decodeFrame(alloc, &lying));
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

fn viewHash(st: *Store, alloc: std.mem.Allocator) !Oid {
    var v = try opdag.currentView(st, alloc);
    defer v.deinit(alloc);
    return v.hash(alloc);
}

fn waitFor(io: std.Io, budget_ms: u64, ctx: anytype) bool {
    var waited: u64 = 0;
    while (waited < budget_ms) : (waited += 50) {
        if (ctx.ready()) return true;
        sleepMs(io, 50);
    }
    return ctx.ready();
}

test "two peers find each other with no server and end up holding the same view" {
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

    // Two histories with no common ancestor: the hardest thing the merge has to
    // survive, and the case where "converged" cannot be confused with "one side
    // happened to already have the other's objects".
    const left = try commitFiles(&a, "main", &left_files, &.{}, 1, 1000);
    const right = try commitFiles(&b, "main", &right_files, &.{}, 2, 2000);
    try sync.ensureHead(&a, alloc, 1000);
    try sync.ensureHead(&b, alloc, 2000);

    const opts = Options{
        .secret = "test-room-hydrant-hostel-orbit",
        .beacon_port = 47790,
        .announce_ms = 50,
        .interval_ms = 20,
        .heartbeat_ms = 250,
        .reseed_ms = 60_000,
    };

    const ma = try Mesh.open(io, alloc, &a, opts);
    defer ma.close();
    const mb = try Mesh.open(io, alloc, &b, opts);
    defer mb.close();

    try ma.start();
    try mb.start();

    const Exchanged = struct {
        a: *Store,
        b: *Store,
        left: Oid,
        right: Oid,
        fn ready(self: @This()) bool {
            return self.a.has(self.right) and self.b.has(self.left);
        }
    };
    try testing.expect(waitFor(io, 30_000, Exchanged{
        .a = &a,
        .b = &b,
        .left = left,
        .right = right,
    }));

    const Agreed = struct {
        a: *Store,
        b: *Store,
        alloc: std.mem.Allocator,
        fn ready(self: @This()) bool {
            const ha = viewHash(self.a, self.alloc) catch return false;
            const hb = viewHash(self.b, self.alloc) catch return false;
            return ha.eql(hb);
        }
    };
    try testing.expect(waitFor(io, 15_000, Agreed{ .a = &a, .b = &b, .alloc = alloc }));

    // Both sides kept both tips rather than one silently winning. Convergence
    // that quietly drops a peer's work would pass a hash comparison and be
    // worthless.
    var view = try opdag.currentView(&a, alloc);
    defer view.deinit(alloc);
    const main_ref = view.find("main") orelse return error.TestExpectedRef;
    try testing.expectEqual(@as(usize, 2), main_ref.tips.len);

    // A link becomes visible to `status` only once its post-reconcile settle
    // finishes, which is after the transfer it just performed. Asserting the
    // count without waiting would be asserting that an asynchronous mesh is
    // synchronous.
    const Linked = struct {
        ma: *Mesh,
        mb: *Mesh,
        fn ready(self: @This()) bool {
            return self.ma.status().peers >= 1 and self.mb.status().peers >= 1;
        }
    };
    try testing.expect(waitFor(io, 15_000, Linked{ .ma = ma, .mb = mb }));
}

test "a verdict earned on one peer answers on the other" {
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

    const tree = try commitFiles(&a, "main", &left_files, &.{}, 1, 1000);
    _ = try commitFiles(&b, "main", &left_files, &.{}, 1, 1000);
    try sync.ensureHead(&a, alloc, 1000);
    try sync.ensureHead(&b, alloc, 1000);

    const key = verdict.Key{
        .tree = tree,
        .tier = .full,
        .command = verdict.commandHash("zig build test"),
    };
    try verdict.record(&a, .{
        .tree = key.tree,
        .tier = key.tier,
        .command = key.command,
        .result = .green,
        .exit_code = 0,
        .duration_ms = 4200,
        .ms = 1000,
        .readset = Oid.zero(),
        .independence = .independent,
        .relevance_hit = 5,
        .relevance_total = 5,
        .discrimination = .discriminating,
    });

    try testing.expect((try verdict.lookup(&b, alloc, key)) == null);

    const opts = Options{
        .secret = "test-room-verdicts-travel",
        .beacon_port = 47792,
        .announce_ms = 50,
        .interval_ms = 20,
        .heartbeat_ms = 250,
    };
    const ma = try Mesh.open(io, alloc, &a, opts);
    defer ma.close();
    const mb = try Mesh.open(io, alloc, &b, opts);
    defer mb.close();
    try ma.start();
    try mb.start();

    const Adopted = struct {
        st: *Store,
        alloc: std.mem.Allocator,
        key: verdict.Key,
        fn ready(self: @This()) bool {
            const got = verdict.lookup(self.st, self.alloc, self.key) catch return false;
            return got != null;
        }
    };
    try testing.expect(waitFor(io, 30_000, Adopted{ .st = &b, .alloc = alloc, .key = key }));

    const adopted = (try verdict.lookup(&b, alloc, key)).?;
    try testing.expect(adopted.isGreen());
    try testing.expectEqual(verdict.Independence.independent, adopted.independence);
    try testing.expectEqual(@as(u32, 4200), adopted.duration_ms);
}

test "a walk settles what it saw whole, and the next walk prunes at it" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    const first = try commitFiles(&st, "main", &base_files, &.{}, 1, 1000);
    try sync.ensureHead(&st, alloc, 1000);

    var f = Frontier.init(io, alloc);
    defer f.deinit();
    try f.seed(&st);

    const ops = try opdag.heads(&st, alloc);
    defer alloc.free(ops);

    var first_walk = try f.walk(&st, &.{first}, ops);
    defer first_walk.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), first_walk.missing.len);
    try testing.expect(first_walk.meta.len > 0);
    try testing.expect(first_walk.bulk.len > 0);

    // Nothing moved, so the second walk over the same roots has nothing to
    // report. This is the property the whole gossip loop rests on: a quiet
    // repo costs nothing to re-examine.
    var again = try f.walk(&st, &.{first}, ops);
    defer again.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), again.missing.len);
    try testing.expectEqual(@as(usize, 0), again.meta.len);
    try testing.expectEqual(@as(usize, 0), again.bulk.len);

    // One more change, and the walk reports that change and nothing else it
    // had already accounted for.
    const second = try commitFiles(&st, "main", &left_files, &.{first}, 2, 2000);
    try f.seed(&st);
    var third = try f.walk(&st, &.{second}, ops);
    defer third.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), third.missing.len);
    try testing.expect(third.meta.len > 0);
    try testing.expect(third.meta.len < first_walk.meta.len);
}

test "a walk over roots this store lacks names them and settles nothing" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    var f = Frontier.init(io, alloc);
    defer f.deinit();
    try f.seed(&st);

    const absent = Oid.ofBytes("a change this store never saw");
    var w = try f.walk(&st, &.{absent}, &.{});
    defer w.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), w.missing.len);
    try testing.expect(w.missing[0].eql(absent));

    // A walk that ended short must not have claimed anything is whole, or the
    // want would never be reissued once the object arrived.
    var again = try f.walk(&st, &.{absent}, &.{});
    defer again.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), again.missing.len);
}

test "verdict lines merge once, and junk is not written into the log" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    var pool = VerdictPool.init(io, alloc);
    defer pool.deinit();
    try pool.seed(&st);

    const tree = Oid.ofBytes("a graded tree");
    try verdict.record(&st, .{
        .tree = tree,
        .tier = .full,
        .command = verdict.commandHash("zig build test"),
        .result = .green,
        .exit_code = 0,
        .duration_ms = 10,
        .ms = 1,
        .readset = Oid.zero(),
    });
    try pool.seed(&st);

    const held = try applog.readAll(&st, alloc, verdict.log_path);
    defer alloc.free(held);

    // A line already held is not appended a second time, which is what stops
    // two peers echoing the same verdict back and forth forever.
    try testing.expectEqual(@as(usize, 0), try pool.merge(&st, held));

    try testing.expectEqual(@as(usize, 0), try pool.merge(&st, "not a verdict\n"));
    try testing.expectEqual(@as(usize, 0), try pool.merge(&st, "\n\n"));
    try testing.expectEqual(@as(usize, 0), try pool.merge(&st, "zzzz not hex zzzz\n"));

    const after_junk = try applog.readAll(&st, alloc, verdict.log_path);
    defer alloc.free(after_junk);
    try testing.expectEqualStrings(held, after_junk);

    // A genuine line from elsewhere lands exactly once.
    var other = VerdictPool.init(io, alloc);
    defer other.deinit();
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var st2 = try Store.init(io, alloc, tmp2.dir);
    defer st2.deinit();
    try other.seed(&st2);

    try testing.expectEqual(@as(usize, 1), try other.merge(&st2, held));
    try testing.expectEqual(@as(usize, 0), try other.merge(&st2, held));

    const adopted = try verdict.lookup(&st2, alloc, .{
        .tree = tree,
        .tier = .full,
        .command = verdict.commandHash("zig build test"),
    });
    try testing.expect(adopted != null);
    try testing.expect(adopted.?.isGreen());
}

test "an unshared tail is handed over once, and a trimmed log is re-offered whole" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    var pool = VerdictPool.init(io, alloc);
    defer pool.deinit();
    try pool.seed(&st);

    try applog.append(&st, verdict.log_path, "one\n");
    const first = (try pool.unshared(&st, alloc)) orelse return error.TestExpectedTail;
    defer alloc.free(first);
    try testing.expectEqualStrings("one\n", first);
    try testing.expectEqual(@as(?[]u8, null), try pool.unshared(&st, alloc));

    try applog.append(&st, verdict.log_path, "two\n");
    const second = (try pool.unshared(&st, alloc)) orelse return error.TestExpectedTail;
    defer alloc.free(second);
    try testing.expectEqualStrings("two\n", second);

    // A log that shrank makes the recorded offset meaningless, so the whole
    // thing is offered again rather than a slice of it read at the wrong place.
    try applog.rewrite(&st, verdict.log_path, "x\n");
    const third = (try pool.unshared(&st, alloc)) orelse return error.TestExpectedTail;
    defer alloc.free(third);
    try testing.expectEqualStrings("x\n", third);
}
