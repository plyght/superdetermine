const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const net = std.Io.net;

pub const port: u16 = 7789;
pub const magic = "GRLAN1";
pub const packet_len = magic.len + 4;

pub const Error = error{ NoPeerFound, BroadcastFailed };

pub const Peer = struct {
    address: net.IpAddress,
};

fn encode(slot: u16, tcp_port: u16) [packet_len]u8 {
    var buf: [packet_len]u8 = undefined;
    @memcpy(buf[0..magic.len], magic);
    std.mem.writeInt(u16, buf[magic.len..][0..2], slot, .little);
    std.mem.writeInt(u16, buf[magic.len + 2 ..][0..2], tcp_port, .little);
    return buf;
}

fn decode(bytes: []const u8, want_slot: u16) ?u16 {
    if (bytes.len != packet_len) return null;
    if (!std.mem.eql(u8, bytes[0..magic.len], magic)) return null;
    const slot = std.mem.readInt(u16, bytes[magic.len..][0..2], .little);
    if (slot != want_slot) return null;
    return std.mem.readInt(u16, bytes[magic.len + 2 ..][0..2], .little);
}

const ifaddrs = extern struct {
    next: ?*ifaddrs,
    name: [*:0]const u8,
    flags: c_uint,
    addr: ?*posix.sockaddr,
    netmask: ?*posix.sockaddr,
    dstaddr: ?*posix.sockaddr,
    data: ?*anyopaque,
};

extern "c" fn getifaddrs(ifap: *?*ifaddrs) c_int;
extern "c" fn freeifaddrs(ifa: ?*ifaddrs) void;

const iff_up: c_uint = 0x1;
const iff_broadcast: c_uint = 0x2;
const iff_loopback: c_uint = 0x8;

/// Every IPv4 subnet broadcast address this machine can reach, plus loopback so
/// two repos on one machine can find each other. Returns how many were written.
///
/// The all-ones address 255.255.255.255 is deliberately not used: macOS rejects
/// it with `HostUnreachable` unless the socket is bound to a specific interface,
/// so the per-interface address is the portable choice.
///
/// `dest_port` is a parameter rather than the module constant because the mesh
/// beacon shares this interface enumeration but not this protocol's port, and
/// duplicating the `getifaddrs` walk to change one field would be two copies of
/// the part that is actually hard to get right.
pub fn broadcastTargetsOn(out: *[16]net.IpAddress, dest_port: u16) usize {
    var n: usize = 0;
    out[n] = .{ .ip4 = .{ .bytes = .{ 127, 0, 0, 1 }, .port = dest_port } };
    n += 1;

    if (builtin.os.tag == .windows) return n;

    var list: ?*ifaddrs = null;
    if (getifaddrs(&list) != 0) return n;
    defer freeifaddrs(list);

    var it = list;
    while (it) |entry| : (it = entry.next) {
        if (n == out.len) break;
        if (entry.flags & iff_up == 0) continue;
        if (entry.flags & iff_broadcast == 0) continue;
        if (entry.flags & iff_loopback != 0) continue;

        const addr = entry.addr orelse continue;
        const mask = entry.netmask orelse continue;
        if (addr.family != posix.AF.INET or mask.family != posix.AF.INET) continue;

        const sin: *const posix.sockaddr.in = @ptrCast(@alignCast(addr));
        const smask: *const posix.sockaddr.in = @ptrCast(@alignCast(mask));
        const bcast: u32 = sin.addr | ~smask.addr;
        out[n] = .{ .ip4 = .{ .bytes = @bitCast(bcast), .port = dest_port } };
        n += 1;
    }
    return n;
}

fn broadcastTargets(out: *[16]net.IpAddress) usize {
    return broadcastTargetsOn(out, port);
}

/// Broadcast "slot N is listening on tcp_port" once. The caller repeats this
/// while it waits for a peer to connect.
///
/// Only the slot number travels, never the words. The slot is a two-digit
/// public label; the secret stays on both machines and is only ever used
/// through the PAKE, so a listener on the network learns nothing it can use.
pub fn announce(io: std.Io, slot: u16, tcp_port: u16) !void {
    var b = try Broadcaster.init(io);
    defer b.deinit(io);
    if (!b.pulse(io, slot, tcp_port)) return Error.BroadcastFailed;
}

/// Holds the socket and the target list across repeated announcements, and
/// drops any target that fails. An interface can be up but unroutable (a idle
/// VPN, a disconnected adapter), and retrying it every pulse would produce a
/// steady stream of errors for a peer that was never going to be there.
pub const Broadcaster = struct {
    socket: net.Socket,
    targets: [16]net.IpAddress,
    count: usize,

    pub fn init(io: std.Io) !Broadcaster {
        const bind_address: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(0) };
        const socket = try bind_address.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
        var b: Broadcaster = .{ .socket = socket, .targets = undefined, .count = 0 };
        b.count = broadcastTargets(&b.targets);
        return b;
    }

    pub fn deinit(self: *Broadcaster, io: std.Io) void {
        self.socket.close(io);
    }

    pub fn pulse(self: *Broadcaster, io: std.Io, slot: u16, tcp_port: u16) bool {
        const packet = encode(slot, tcp_port);
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

/// Listen for an announcement of `slot` and return the announcing peer's
/// address. Gives up after `timeout_ms`.
pub fn discover(io: std.Io, slot: u16, timeout_ms: u64) !Peer {
    const bind_address: net.IpAddress = .{ .ip4 = net.Ip4Address.unspecified(port) };
    const socket = try bind_address.bind(io, .{ .mode = .dgram });
    defer socket.close(io);

    const deadline = timeout_ms;
    var waited: u64 = 0;
    const slice_ms: u64 = 500;

    var buf: [64]u8 = undefined;
    while (waited < deadline) : (waited += slice_ms) {
        const message = socket.receiveTimeout(io, &buf, .{ .duration = .{
            .raw = .{ .nanoseconds = @intCast(slice_ms * std.time.ns_per_ms) },
            .clock = .awake,
        } }) catch continue;
        const tcp_port = decode(message.data, slot) orelse continue;
        var address = message.from;
        address.setPort(tcp_port);
        return .{ .address = address };
    }
    return Error.NoPeerFound;
}

// --- tests ---

const testing = std.testing;

test "packets round-trip and reject the wrong slot or garbage" {
    const packet = encode(43, 51234);
    try testing.expectEqual(@as(usize, packet_len), packet.len);
    try testing.expectEqual(@as(?u16, 51234), decode(&packet, 43));
    try testing.expectEqual(@as(?u16, null), decode(&packet, 44));
    try testing.expectEqual(@as(?u16, null), decode("nope", 43));
    try testing.expectEqual(@as(?u16, null), decode(&[_]u8{0} ** packet_len, 43));
}

test "a packet carries the slot and port only, never the code" {
    const packet = encode(7, 9000);
    try testing.expect(std.mem.indexOf(u8, &packet, "hydrant") == null);
    try testing.expectEqual(@as(usize, 10), packet.len);
}

test "discover gives up when nobody is announcing" {
    const io = std.testing.io;
    try testing.expectError(Error.NoPeerFound, discover(io, 61, 600));
}

test "at least one broadcast target is always available" {
    var targets: [16]net.IpAddress = undefined;
    const n = broadcastTargets(&targets);
    try testing.expect(n >= 1);
    try testing.expectEqual(@as(u16, port), targets[0].getPort());
}

fn announceThread(io: std.Io, slot: u16, tcp_port: u16, stop: *std.atomic.Value(bool)) void {
    var b = Broadcaster.init(io) catch return;
    defer b.deinit(io);
    while (!stop.load(.acquire)) {
        _ = b.pulse(io, slot, tcp_port);
        io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake) catch return;
    }
}

test "a sender is found on this machine and its port comes back" {
    const io = std.testing.io;
    var stop = std.atomic.Value(bool).init(false);
    const th = try std.Thread.spawn(.{}, announceThread, .{ io, 88, 51999, &stop });
    defer {
        stop.store(true, .release);
        th.join();
    }
    const peer = try discover(io, 88, 5000);
    try testing.expectEqual(@as(u16, 51999), peer.address.getPort());
}
