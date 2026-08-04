const std = @import("std");

const net = std.Io.net;
const Group = std.crypto.ecc.Ristretto255;
const scalar = Group.scalar;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Blake3 = std.crypto.hash.Blake3;

pub const protocol_magic = "GRWH1";
pub const version_domain = "gr-wormhole-v1";

const generator_m_domain = version_domain ++ " generator M";
const generator_n_domain = version_domain ++ " generator N";
const password_salt = version_domain ++ " password";
const password_info = version_domain ++ " spake2 w";
const transcript_domain = version_domain ++ " transcript";
const session_info = version_domain ++ " session key";
const confirm_sender_label = version_domain ++ " confirm sender";
const confirm_receiver_label = version_domain ++ " confirm receiver";
const transfer_salt = version_domain ++ " transfer";
const transfer_info = version_domain ++ " transfer key";
const record_salt = version_domain ++ " record";
const record_sender_info = version_domain ++ " sender to receiver";
const record_receiver_info = version_domain ++ " receiver to sender";
const record_aad_domain = version_domain ++ " record";

pub const key_len = 32;
pub const element_len = Group.encoded_length;
pub const confirm_len = 32;

pub const max_code_len = 64;
pub const max_frame_len = 1 << 20;
pub const record_chunk_len = 32 * 1024;
pub const max_slot_attempts: u32 = 5;
pub const max_slot: u16 = 99;

pub const Error = error{
    BadCode,
    BadHandshake,
    ConfirmationFailed,
    ProtocolError,
    FrameTooLarge,
    SlotBurned,
    BadRecord,
};

pub const Role = enum {
    sender,
    receiver,

    fn tag(self: Role) u8 {
        return switch (self) {
            .sender => 'S',
            .receiver => 'R',
        };
    }

    fn other(self: Role) Role {
        return switch (self) {
            .sender => .receiver,
            .receiver => .sender,
        };
    }
};

pub const words = [_][]const u8{
    "acrobat",   "airport",  "almanac",  "amuse",     "anchor",    "antenna",  "apple",     "april",
    "arcade",    "armor",    "artist",   "aspect",    "atlas",     "autumn",   "avocado",   "bagel",
    "bakery",    "balloon",  "bamboo",   "bandit",    "banjo",     "barrel",   "basket",    "batch",
    "beacon",    "beaver",   "bedrock",  "beehive",   "bellhop",   "bicycle",  "bishop",    "bison",
    "blanket",   "blender",  "blizzard", "blossom",   "bobcat",    "bonsai",   "bookend",   "boomerang",
    "bottle",    "boulder",  "bracket",  "brandy",    "bravo",     "brisket",  "bronco",    "bucket",
    "buffalo",   "bugle",    "bunker",   "burrito",   "cabinet",   "cactus",   "camera",    "campus",
    "canary",    "candle",   "canyon",   "capsule",   "caravan",   "cardinal", "cargo",     "carnival",
    "carpet",    "cartoon",  "cascade",  "cashew",    "catalog",   "cedar",    "celery",    "cement",
    "census",    "chalk",    "chapter",  "cheddar",   "chimney",   "chisel",   "chorus",    "chowder",
    "cinnamon",  "circus",   "clamp",    "clarinet",  "classic",   "clever",   "clinic",    "clockwork",
    "cobalt",    "cobra",    "cocoa",    "coconut",   "comet",     "compass",  "concert",   "condor",
    "confetti",  "console",  "copper",   "coral",     "cosmic",    "cottage",  "cougar",    "coyote",
    "crayon",    "cricket",  "crimson",  "crossover", "crumble",   "crystal",  "cubic",     "cupcake",
    "curtain",   "custard",  "cyclone",  "dagger",    "dashboard", "decimal",  "decoy",     "denim",
    "dentist",   "desert",   "diagram",  "diesel",    "digital",   "dinner",   "diploma",   "dolphin",
    "domino",    "donut",    "dragon",   "drummer",   "dugout",    "dynamo",   "eagle",     "eclipse",
    "eggplant",  "elastic",  "elbow",    "elder",     "elegant",   "elephant", "elevator",  "ember",
    "emerald",   "engine",   "epic",     "equator",   "espresso",  "eternal",  "exhibit",   "exodus",
    "fabric",    "falcon",   "fantasy",  "fatigue",   "feather",   "fedora",   "ferry",     "fiber",
    "fiddle",    "figment",  "filter",   "finale",    "firefly",   "flamingo", "flannel",   "flask",
    "flint",     "floral",   "flute",    "folklore",  "fossil",    "foxtrot",  "fragile",   "freedom",
    "fresco",    "frigate",  "fritter",  "frontier",  "frostbite", "fuchsia",  "funnel",    "gadget",
    "galaxy",    "gallery",  "gallon",   "gambit",    "garden",    "garlic",   "gazelle",   "gecko",
    "gemstone",  "ginger",   "giraffe",  "glacier",   "gleam",     "glider",   "glossy",    "gopher",
    "gospel",    "granite",  "gravel",   "gravity",   "griffin",   "grotto",   "guitar",    "gumbo",
    "gusto",     "gymnast",  "habitat",  "hacksaw",   "halibut",   "hammock",  "hamster",   "handbook",
    "harbor",    "harmony",  "harvest",  "hazard",    "hazel",     "headline", "hedgehog",  "helium",
    "hexagon",   "hickory",  "hillside", "hoagie",    "holiday",   "hornet",   "horizon",   "hostel",
    "hotdog",    "hubcap",   "humble",   "hurdle",    "hydrant",   "iceberg",  "igloo",     "impala",
    "import",    "incisor",  "indigo",   "infield",   "inkwell",   "insect",   "instant",   "iris",
    "island",    "ivory",    "jackal",   "jacket",    "jaguar",    "jamboree", "jasmine",   "javelin",
};

fn wordIndex(w: []const u8) ?usize {
    for (words, 0..) |candidate, i| {
        if (std.ascii.eqlIgnoreCase(candidate, w)) return i;
    }
    return null;
}

pub const Code = struct {
    slot: u16,
    buf: [max_code_len]u8,
    len: usize,

    pub fn text(self: *const Code) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn parse(raw: []const u8) Error!Code {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > max_code_len) return Error.BadCode;

        var it = std.mem.splitScalar(u8, trimmed, '-');
        const slot_text = it.next() orelse return Error.BadCode;
        const first = it.next() orelse return Error.BadCode;
        const second = it.next() orelse return Error.BadCode;
        if (it.next() != null) return Error.BadCode;

        const slot = std.fmt.parseInt(u16, slot_text, 10) catch return Error.BadCode;
        if (slot == 0 or slot > max_slot) return Error.BadCode;
        const a = wordIndex(first) orelse return Error.BadCode;
        const b = wordIndex(second) orelse return Error.BadCode;

        var code: Code = .{ .slot = slot, .buf = undefined, .len = 0 };
        var w: std.Io.Writer = .fixed(&code.buf);
        w.print("{d}-{s}-{s}", .{ slot, words[a], words[b] }) catch return Error.BadCode;
        code.len = w.end;
        return code;
    }
};

pub fn generateCode(io: std.Io, alloc: std.mem.Allocator) ![]u8 {
    var raw: [4]u8 = undefined;
    io.random(&raw);
    const slot: u16 = 1 + @as(u16, raw[0]) % max_slot;
    return std.fmt.allocPrint(alloc, "{d}-{s}-{s}", .{ slot, words[raw[1]], words[raw[2]] });
}

fn hashToElement(domain: []const u8) Group {
    var uniform: [64]u8 = undefined;
    Blake3.hash(domain, &uniform, .{});
    return Group.fromUniform(uniform);
}

fn generatorM() Group {
    return hashToElement(generator_m_domain);
}

fn generatorN() Group {
    return hashToElement(generator_n_domain);
}

fn passwordScalar(code: *const Code) [32]u8 {
    var wide: [64]u8 = undefined;
    Hkdf.expand(&wide, password_info, Hkdf.extract(password_salt, code.text()));
    return scalar.reduce64(wide);
}

fn hashField(h: *Blake3, bytes: []const u8) void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(bytes.len), .little);
    h.update(&len_buf);
    h.update(bytes);
}

fn transcriptHash(
    code: *const Code,
    w: [32]u8,
    sender_msg: [element_len]u8,
    receiver_msg: [element_len]u8,
    shared: [element_len]u8,
) [32]u8 {
    var h = Blake3.init(.{});
    hashField(&h, transcript_domain);
    hashField(&h, code.text());
    hashField(&h, &sender_msg);
    hashField(&h, &receiver_msg);
    hashField(&h, &w);
    hashField(&h, &shared);
    var out: [32]u8 = undefined;
    h.final(&out);
    return out;
}

fn sessionKey(transcript: [32]u8, shared: [element_len]u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    Hkdf.expand(&out, session_info, Hkdf.extract(&transcript, &shared));
    return out;
}

fn confirmation(session: [key_len]u8, transcript: [32]u8, role: Role) [confirm_len]u8 {
    const label = switch (role) {
        .sender => confirm_sender_label,
        .receiver => confirm_receiver_label,
    };
    var h = Blake3.init(.{ .key = session });
    h.update(label);
    h.update(&transcript);
    var out: [confirm_len]u8 = undefined;
    h.final(&out);
    return out;
}

fn transferKey(session: [key_len]u8) [key_len]u8 {
    var out: [key_len]u8 = undefined;
    Hkdf.expand(&out, transfer_info, Hkdf.extract(transfer_salt, &session));
    return out;
}

fn recordKey(transfer: [key_len]u8, direction: Role) [key_len]u8 {
    const info = switch (direction) {
        .sender => record_sender_info,
        .receiver => record_receiver_info,
    };
    var out: [key_len]u8 = undefined;
    Hkdf.expand(&out, info, Hkdf.extract(record_salt, &transfer));
    return out;
}

pub const Channel = struct {
    r: *std.Io.Reader,
    w: *std.Io.Writer,
};

pub fn writeFrame(ch: Channel, bytes: []const u8) !void {
    if (bytes.len > max_frame_len) return Error.FrameTooLarge;
    try ch.w.writeInt(u32, @intCast(bytes.len), .little);
    try ch.w.writeAll(bytes);
    try ch.w.flush();
}

pub fn readFrameInto(ch: Channel, buf: []u8) ![]u8 {
    const len = try ch.r.takeInt(u32, .little);
    if (len > max_frame_len) return Error.FrameTooLarge;
    if (len > buf.len) return Error.ProtocolError;
    try ch.r.readSliceAll(buf[0..len]);
    return buf[0..len];
}

pub fn readFrameAlloc(ch: Channel, alloc: std.mem.Allocator) ![]u8 {
    const len = try ch.r.takeInt(u32, .little);
    if (len > max_frame_len) return Error.FrameTooLarge;
    return ch.r.readAlloc(alloc, len);
}

pub const Session = struct {
    key: [key_len]u8,
    role: Role,
    confirmed: bool,

    fn sendKey(self: *const Session) [key_len]u8 {
        return recordKey(self.key, self.role);
    }

    fn recvKey(self: *const Session) [key_len]u8 {
        return recordKey(self.key, self.role.other());
    }

    pub fn sendStream(
        self: *Session,
        io: std.Io,
        alloc: std.mem.Allocator,
        ch: Channel,
        payload: []const u8,
    ) !void {
        _ = io;
        const k = self.sendKey();
        const frame = try alloc.alloc(u8, 1 + record_chunk_len + Aead.tag_length);
        defer alloc.free(frame);

        var index: u64 = 0;
        var offset: usize = 0;
        while (true) {
            const take = @min(record_chunk_len, payload.len - offset);
            const chunk = payload[offset..][0..take];
            offset += take;
            const final = offset == payload.len;

            var aad_buf: AadBuf = undefined;
            const aad = buildAad(&aad_buf, self.role, index, final);
            const nonce = recordNonce(index);

            frame[0] = @intFromBool(final);
            var tag: [Aead.tag_length]u8 = undefined;
            Aead.encrypt(frame[1..][0..take], &tag, chunk, aad, nonce, k);
            @memcpy(frame[1 + take ..][0..Aead.tag_length], &tag);
            try writeFrame(ch, frame[0 .. 1 + take + Aead.tag_length]);

            index += 1;
            if (final) break;
        }
    }

    pub fn recvStream(self: *Session, io: std.Io, alloc: std.mem.Allocator, ch: Channel) ![]u8 {
        _ = io;
        const k = self.recvKey();
        const direction = self.role.other();

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);

        var index: u64 = 0;
        while (true) {
            const frame = try readFrameAlloc(ch, alloc);
            defer alloc.free(frame);
            if (frame.len < 1 + Aead.tag_length) return Error.BadRecord;
            if (frame[0] > 1) return Error.BadRecord;
            const final = frame[0] == 1;

            const ct = frame[1 .. frame.len - Aead.tag_length];
            const tag: [Aead.tag_length]u8 =
                frame[frame.len - Aead.tag_length ..][0..Aead.tag_length].*;
            const nonce = recordNonce(index);

            const plain = try alloc.alloc(u8, ct.len);
            defer alloc.free(plain);

            var aad_buf: AadBuf = undefined;
            const aad = buildAad(&aad_buf, direction, index, final);
            Aead.decrypt(plain, ct, tag, aad, nonce, k) catch return Error.BadRecord;

            try out.appendSlice(alloc, plain);
            index += 1;
            if (final) break;
        }

        return out.toOwnedSlice(alloc);
    }
};

fn recordNonce(index: u64) [Aead.nonce_length]u8 {
    var nonce = [_]u8{0} ** Aead.nonce_length;
    std.mem.writeInt(u64, nonce[0..8], index, .little);
    return nonce;
}

const AadBuf = [record_aad_domain.len + 10]u8;

fn buildAad(buf: *AadBuf, direction: Role, index: u64, final: bool) []const u8 {
    @memcpy(buf[0..record_aad_domain.len], record_aad_domain);
    buf[record_aad_domain.len] = direction.tag();
    std.mem.writeInt(u64, buf[record_aad_domain.len + 1 ..][0..8], index, .little);
    buf[record_aad_domain.len + 9] = @intFromBool(final);
    return buf[0..];
}

const Half = struct {
    secret: [32]u8,
    w: [32]u8,
    message: [element_len]u8,
    code: Code,
    role: Role,
};

fn begin(io: std.Io, raw_code: []const u8, role: Role) Error!Half {
    const code = try Code.parse(raw_code);
    const w = passwordScalar(&code);
    const blind = switch (role) {
        .sender => generatorM(),
        .receiver => generatorN(),
    };
    const mask = blind.mul(w) catch return Error.BadCode;
    const secret = scalar.random(io);
    const public = Group.basePoint.mul(secret) catch return Error.BadHandshake;
    return .{
        .secret = secret,
        .w = w,
        .message = public.add(mask).toBytes(),
        .code = code,
        .role = role,
    };
}

fn deriveSession(half: Half, peer_msg: [element_len]u8) Error!Derived {
    const peer_blind = switch (half.role) {
        .sender => generatorN(),
        .receiver => generatorM(),
    };
    const peer = Group.fromBytes(peer_msg) catch return Error.BadHandshake;
    const peer_mask = peer_blind.mul(half.w) catch return Error.BadCode;
    const stripped = peer.sub(peer_mask);
    const shared = stripped.mul(half.secret) catch return Error.BadHandshake;
    const shared_bytes = shared.toBytes();

    const sender_msg = switch (half.role) {
        .sender => half.message,
        .receiver => peer_msg,
    };
    const receiver_msg = switch (half.role) {
        .sender => peer_msg,
        .receiver => half.message,
    };

    const transcript = transcriptHash(&half.code, half.w, sender_msg, receiver_msg, shared_bytes);
    return .{ .transcript = transcript, .session = sessionKey(transcript, shared_bytes) };
}

const Derived = struct {
    transcript: [32]u8,
    session: [key_len]u8,
};

fn exchangeAndConfirm(ch: Channel, half: Half) !Session {
    try writeFrame(ch, &half.message);
    var msg_buf: [element_len]u8 = undefined;
    const peer_msg = try readFrameInto(ch, &msg_buf);
    if (peer_msg.len != element_len) return Error.ProtocolError;

    const derived = try deriveSession(half, msg_buf);
    const mine = confirmation(derived.session, derived.transcript, half.role);
    const theirs = confirmation(derived.session, derived.transcript, half.role.other());

    var conf_buf: [confirm_len]u8 = undefined;
    switch (half.role) {
        .sender => {
            try writeFrame(ch, &mine);
            const got = try readFrameInto(ch, &conf_buf);
            if (got.len != confirm_len) return Error.ProtocolError;
            if (!std.crypto.timing_safe.eql([confirm_len]u8, conf_buf, theirs)) {
                return Error.ConfirmationFailed;
            }
        },
        .receiver => {
            const got = try readFrameInto(ch, &conf_buf);
            if (got.len != confirm_len) return Error.ProtocolError;
            if (!std.crypto.timing_safe.eql([confirm_len]u8, conf_buf, theirs)) {
                return Error.ConfirmationFailed;
            }
            try writeFrame(ch, &mine);
        },
    }

    return .{ .key = transferKey(derived.session), .role = half.role, .confirmed = true };
}

pub fn senderHandshake(io: std.Io, alloc: std.mem.Allocator, ch: Channel, code: []const u8) !Session {
    _ = alloc;
    return exchangeAndConfirm(ch, try begin(io, code, .sender));
}

pub fn receiverHandshake(io: std.Io, alloc: std.mem.Allocator, ch: Channel, code: []const u8) !Session {
    _ = alloc;
    return exchangeAndConfirm(ch, try begin(io, code, .receiver));
}

pub const SlotTable = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    mutex: std.Io.Mutex = .init,
    map: std.AutoHashMapUnmanaged(u16, State) = .empty,

    pub const State = struct {
        attempts: u32 = 0,
        burned: bool = false,
        waiting: ?net.Stream = null,
    };

    pub fn init(io: std.Io, alloc: std.mem.Allocator) SlotTable {
        return .{ .io = io, .alloc = alloc };
    }

    pub fn deinit(self: *SlotTable) void {
        self.map.deinit(self.alloc);
    }

    fn lock(self: *SlotTable) void {
        self.mutex.lockUncancelable(self.io);
    }

    fn unlock(self: *SlotTable) void {
        self.mutex.unlock(self.io);
    }

    pub fn claim(self: *SlotTable, slot: u16) !void {
        self.lock();
        defer self.unlock();
        const gop = try self.map.getOrPut(self.alloc, slot);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (gop.value_ptr.burned) return Error.SlotBurned;
        gop.value_ptr.attempts += 1;
        if (gop.value_ptr.attempts > max_slot_attempts) {
            gop.value_ptr.burned = true;
            return Error.SlotBurned;
        }
    }

    pub fn burn(self: *SlotTable, slot: u16) !void {
        self.lock();
        defer self.unlock();
        const gop = try self.map.getOrPut(self.alloc, slot);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.burned = true;
    }

    pub fn attempts(self: *SlotTable, slot: u16) u32 {
        self.lock();
        defer self.unlock();
        const entry = self.map.get(slot) orelse return 0;
        return entry.attempts;
    }

    pub fn isBurned(self: *SlotTable, slot: u16) bool {
        self.lock();
        defer self.unlock();
        const entry = self.map.get(slot) orelse return false;
        return entry.burned;
    }

    fn park(self: *SlotTable, slot: u16, stream: net.Stream) !?net.Stream {
        self.lock();
        defer self.unlock();
        const gop = try self.map.getOrPut(self.alloc, slot);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        if (gop.value_ptr.burned) return Error.SlotBurned;
        if (gop.value_ptr.waiting) |partner| {
            gop.value_ptr.waiting = null;
            gop.value_ptr.attempts += 1;
            if (gop.value_ptr.attempts > max_slot_attempts) {
                gop.value_ptr.burned = true;
                return Error.SlotBurned;
            }
            return partner;
        }
        gop.value_ptr.waiting = stream;
        return null;
    }
};

const Rendezvous = struct {
    io: std.Io,
    slots: SlotTable,
};

fn readJoin(ch: Channel) !u16 {
    var buf: [protocol_magic.len + 2]u8 = undefined;
    const frame = try readFrameInto(ch, &buf);
    if (frame.len != protocol_magic.len + 2) return Error.ProtocolError;
    if (!std.mem.eql(u8, frame[0..protocol_magic.len], protocol_magic)) return Error.ProtocolError;
    return std.mem.readInt(u16, frame[protocol_magic.len..][0..2], .little);
}

pub fn joinSlot(ch: Channel, slot: u16) !void {
    var buf: [protocol_magic.len + 2]u8 = undefined;
    @memcpy(buf[0..protocol_magic.len], protocol_magic);
    std.mem.writeInt(u16, buf[protocol_magic.len..][0..2], slot, .little);
    try writeFrame(ch, &buf);

    var status: [1]u8 = undefined;
    const reply = try readFrameInto(ch, &status);
    if (reply.len != 1) return Error.ProtocolError;
    if (status[0] != 0) return Error.SlotBurned;
}

pub fn join(ch: Channel, code: []const u8) !void {
    const parsed = try Code.parse(code);
    try joinSlot(ch, parsed.slot);
}

fn replyStatus(io: std.Io, stream: net.Stream, ok: bool) void {
    var wbuf: [16]u8 = undefined;
    var sw = stream.writer(io, &wbuf);
    var rbuf: [1]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    const ch: Channel = .{ .r = &sr.interface, .w = &sw.interface };
    writeFrame(ch, &[_]u8{@intFromBool(!ok)}) catch {};
}

const Pump = struct {
    io: std.Io,
    from: net.Stream,
    to: net.Stream,

    fn run(self: Pump) void {
        var rbuf: [8192]u8 = undefined;
        var wbuf: [8192]u8 = undefined;
        var sr = self.from.reader(self.io, &rbuf);
        var sw = self.to.writer(self.io, &wbuf);
        const r = &sr.interface;
        const w = &sw.interface;

        while (true) {
            const len = r.takeInt(u32, .little) catch break;
            if (len > max_frame_len) break;
            w.writeInt(u32, len, .little) catch break;
            r.streamExact(w, len) catch break;
            w.flush() catch break;
        }
        self.to.shutdown(self.io, .send) catch {};
    }
};

fn relay(io: std.Io, a: net.Stream, b: net.Stream) void {
    const forward: Pump = .{ .io = io, .from = a, .to = b };
    const backward: Pump = .{ .io = io, .from = b, .to = a };
    const th = std.Thread.spawn(.{}, Pump.run, .{forward}) catch {
        forward.run();
        backward.run();
        return;
    };
    backward.run();
    th.join();
}

fn serveConn(rv: *Rendezvous, stream: net.Stream) void {
    const io = rv.io;
    var rbuf: [64]u8 = undefined;
    var wbuf: [64]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    const ch: Channel = .{ .r = &sr.interface, .w = &sw.interface };

    const slot = readJoin(ch) catch {
        stream.close(io);
        return;
    };

    const partner = rv.slots.park(slot, stream) catch {
        writeFrame(ch, &[_]u8{1}) catch {};
        stream.close(io);
        return;
    };

    writeFrame(ch, &[_]u8{0}) catch {
        stream.close(io);
        return;
    };

    const other = partner orelse return;
    relay(io, other, stream);
    other.close(io);
    stream.close(io);
}

const ConnJob = struct {
    rv: *Rendezvous,
    stream: net.Stream,

    fn run(self: ConnJob) void {
        serveConn(self.rv, self.stream);
    }
};

pub fn rendezvous(io: std.Io, alloc: std.mem.Allocator, port: u16) !void {
    var rv: Rendezvous = .{ .io = io, .slots = SlotTable.init(io, alloc) };
    defer rv.slots.deinit();

    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    while (true) {
        const stream = try server.accept(io);
        const job: ConnJob = .{ .rv = &rv, .stream = stream };
        const th = std.Thread.spawn(.{}, ConnJob.run, .{job}) catch {
            stream.close(io);
            continue;
        };
        th.detach();
    }
}

pub const Conn = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    stream: net.Stream,
    sr: net.Stream.Reader,
    sw: net.Stream.Writer,
    rbuf: [64 * 1024]u8 = undefined,
    wbuf: [64 * 1024]u8 = undefined,

    pub fn open(io: std.Io, alloc: std.mem.Allocator, host: []const u8, port: u16) !*Conn {
        var address = net.IpAddress.parse(host, port) catch
            try net.IpAddress.resolve(io, host, port);
        const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
        return adopt(io, alloc, stream);
    }

    pub fn adopt(io: std.Io, alloc: std.mem.Allocator, stream: net.Stream) !*Conn {
        const c = try alloc.create(Conn);
        c.* = .{ .io = io, .alloc = alloc, .stream = stream, .sr = undefined, .sw = undefined };
        c.sr = stream.reader(io, &c.rbuf);
        c.sw = stream.writer(io, &c.wbuf);
        return c;
    }

    pub fn destroy(c: *Conn) void {
        c.stream.close(c.io);
        c.alloc.destroy(c);
    }

    pub fn channel(c: *Conn) Channel {
        return .{ .r = &c.sr.interface, .w = &c.sw.interface };
    }
};

// --- tests ---

const testing = std.testing;

fn allocWriter(alloc: std.mem.Allocator) std.Io.Writer.Allocating {
    return std.Io.Writer.Allocating.init(alloc);
}

test "wordlist is well formed" {
    try testing.expectEqual(@as(usize, 256), words.len);
    for (words, 0..) |a, i| {
        try testing.expect(a.len >= 4 and a.len <= 9);
        for (words[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a, b));
        }
        for (a) |c| try testing.expect(std.ascii.isLower(c));
    }
}

test "generated codes parse and round trip" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var i: usize = 0;
    while (i < 64) : (i += 1) {
        const text = try generateCode(io, alloc);
        defer alloc.free(text);
        const code = try Code.parse(text);
        try testing.expectEqualStrings(text, code.text());
        try testing.expect(code.slot >= 1 and code.slot <= max_slot);
    }
}

test "code parsing rejects malformed input" {
    try testing.expectError(Error.BadCode, Code.parse("7-crossover"));
    try testing.expectError(Error.BadCode, Code.parse("7-crossover-clockwork-extra"));
    try testing.expectError(Error.BadCode, Code.parse("0-crossover-clockwork"));
    try testing.expectError(Error.BadCode, Code.parse("7-notaword-clockwork"));
    try testing.expectError(Error.BadCode, Code.parse("abc-crossover-clockwork"));
    const upper = try Code.parse("  7-CROSSOVER-Clockwork\n");
    try testing.expectEqualStrings("7-crossover-clockwork", upper.text());
}

test "generators are distinct, non identity and deterministic" {
    const m = generatorM();
    const n = generatorN();
    try testing.expect(!m.equivalent(n));
    try m.rejectIdentity();
    try n.rejectIdentity();
    try testing.expectEqualSlices(u8, &m.toBytes(), &generatorM().toBytes());
}

const Transcript = struct {
    sender: Session,
    receiver: Session,
};

fn runHandshake(io: std.Io, sender_code: []const u8, receiver_code: []const u8) !Transcript {
    const s = try begin(io, sender_code, .sender);
    const r = try begin(io, receiver_code, .receiver);

    const sd = try deriveSession(s, r.message);
    const rd = try deriveSession(r, s.message);

    const s_conf = confirmation(sd.session, sd.transcript, .sender);
    const r_conf_expected = confirmation(sd.session, sd.transcript, .receiver);
    const r_conf = confirmation(rd.session, rd.transcript, .receiver);
    const s_conf_expected = confirmation(rd.session, rd.transcript, .sender);

    if (!std.crypto.timing_safe.eql([confirm_len]u8, s_conf, s_conf_expected)) {
        return Error.ConfirmationFailed;
    }
    if (!std.crypto.timing_safe.eql([confirm_len]u8, r_conf, r_conf_expected)) {
        return Error.ConfirmationFailed;
    }

    return .{
        .sender = .{ .key = transferKey(sd.session), .role = .sender, .confirmed = true },
        .receiver = .{ .key = transferKey(rd.session), .role = .receiver, .confirmed = true },
    };
}

test "matching codes agree on the transfer key" {
    const io = std.testing.io;
    const t = try runHandshake(io, "7-crossover-clockwork", "7-crossover-clockwork");
    try testing.expectEqualSlices(u8, &t.sender.key, &t.receiver.key);
}

test "mismatched codes derive different keys and fail confirmation" {
    const io = std.testing.io;
    const s = try begin(io, "7-crossover-clockwork", .sender);
    const r = try begin(io, "7-crossover-cupcake", .receiver);

    const sd = try deriveSession(s, r.message);
    const rd = try deriveSession(r, s.message);
    try testing.expect(!std.mem.eql(u8, &sd.session, &rd.session));
    try testing.expect(!std.mem.eql(u8, &transferKey(sd.session), &transferKey(rd.session)));

    try testing.expectError(
        Error.ConfirmationFailed,
        runHandshake(io, "7-crossover-clockwork", "7-crossover-cupcake"),
    );
    try testing.expectError(
        Error.ConfirmationFailed,
        runHandshake(io, "7-crossover-clockwork", "8-crossover-clockwork"),
    );
}

test "a tampered handshake message breaks the session" {
    const io = std.testing.io;
    const s = try begin(io, "12-harbor-hammock", .sender);
    const r = try begin(io, "12-harbor-hammock", .receiver);

    var tampered = r.message;
    tampered[0] ^= 0x01;

    const rd = try deriveSession(r, s.message);
    const sd = deriveSession(s, tampered) catch {
        return;
    };
    try testing.expect(!std.mem.eql(u8, &sd.session, &rd.session));

    const expected = confirmation(sd.session, sd.transcript, .receiver);
    const actual = confirmation(rd.session, rd.transcript, .receiver);
    try testing.expect(!std.crypto.timing_safe.eql([confirm_len]u8, expected, actual));
}

test "handshake over an in-memory channel pair" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const s = try begin(io, "3-gopher-gecko", .sender);
    const r = try begin(io, "3-gopher-gecko", .receiver);

    var s_out = allocWriter(alloc);
    defer s_out.deinit();
    var r_out = allocWriter(alloc);
    defer r_out.deinit();

    try writeFrame(.{ .r = undefined, .w = &s_out.writer }, &s.message);
    try writeFrame(.{ .r = undefined, .w = &r_out.writer }, &r.message);

    var s_reader: std.Io.Reader = .fixed(r_out.written());
    var r_reader: std.Io.Reader = .fixed(s_out.written());

    var buf_a: [element_len]u8 = undefined;
    var buf_b: [element_len]u8 = undefined;
    const from_r = try readFrameInto(.{ .r = &s_reader, .w = undefined }, &buf_a);
    const from_s = try readFrameInto(.{ .r = &r_reader, .w = undefined }, &buf_b);
    try testing.expectEqualSlices(u8, &r.message, from_r);
    try testing.expectEqualSlices(u8, &s.message, from_s);

    const sd = try deriveSession(s, buf_a);
    const rd = try deriveSession(r, buf_b);
    try testing.expectEqualSlices(u8, &sd.session, &rd.session);
}

test "record streams round trip in both directions" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var t = try runHandshake(io, "42-galaxy-gadget", "42-galaxy-gadget");

    const payload = try alloc.alloc(u8, record_chunk_len * 2 + 777);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i *% 31);

    var wire = allocWriter(alloc);
    defer wire.deinit();
    try t.sender.sendStream(io, alloc, .{ .r = undefined, .w = &wire.writer }, payload);

    var reader: std.Io.Reader = .fixed(wire.written());
    const got = try t.receiver.recvStream(io, alloc, .{ .r = &reader, .w = undefined });
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, payload, got);

    var back = allocWriter(alloc);
    defer back.deinit();
    try t.receiver.sendStream(io, alloc, .{ .r = undefined, .w = &back.writer }, "ack");
    var back_reader: std.Io.Reader = .fixed(back.written());
    const ack = try t.sender.recvStream(io, alloc, .{ .r = &back_reader, .w = undefined });
    defer alloc.free(ack);
    try testing.expectEqualStrings("ack", ack);
}

test "an empty payload round trips" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var t = try runHandshake(io, "5-bagel-bugle", "5-bagel-bugle");

    var wire = allocWriter(alloc);
    defer wire.deinit();
    try t.sender.sendStream(io, alloc, .{ .r = undefined, .w = &wire.writer }, "");
    var reader: std.Io.Reader = .fixed(wire.written());
    const got = try t.receiver.recvStream(io, alloc, .{ .r = &reader, .w = undefined });
    defer alloc.free(got);
    try testing.expectEqual(@as(usize, 0), got.len);
}

fn frameOffsets(alloc: std.mem.Allocator, wire: []const u8) ![]usize {
    var offsets: std.ArrayList(usize) = .empty;
    errdefer offsets.deinit(alloc);
    var i: usize = 0;
    while (i + 4 <= wire.len) {
        try offsets.append(alloc, i);
        const len = std.mem.readInt(u32, wire[i..][0..4], .little);
        i += 4 + len;
    }
    return offsets.toOwnedSlice(alloc);
}

test "reordered, dropped and replayed records fail to authenticate" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var t = try runHandshake(io, "9-cactus-camera", "9-cactus-camera");

    const payload = try alloc.alloc(u8, record_chunk_len * 3);
    defer alloc.free(payload);
    for (payload, 0..) |*b, i| b.* = @truncate(i);

    var wire = allocWriter(alloc);
    defer wire.deinit();
    try t.sender.sendStream(io, alloc, .{ .r = undefined, .w = &wire.writer }, payload);
    const original = wire.written();

    const offsets = try frameOffsets(alloc, original);
    defer alloc.free(offsets);
    try testing.expectEqual(@as(usize, 3), offsets.len);

    const swapped = try alloc.alloc(u8, original.len);
    defer alloc.free(swapped);
    const frame_len = offsets[1] - offsets[0];
    @memcpy(swapped[0..frame_len], original[offsets[1]..][0..frame_len]);
    @memcpy(swapped[frame_len..][0..frame_len], original[offsets[0]..][0..frame_len]);
    @memcpy(swapped[2 * frame_len ..], original[offsets[2]..]);

    var swapped_reader: std.Io.Reader = .fixed(swapped);
    try testing.expectError(
        Error.BadRecord,
        t.receiver.recvStream(io, alloc, .{ .r = &swapped_reader, .w = undefined }),
    );

    var dropped_reader: std.Io.Reader = .fixed(original[0..offsets[2]]);
    try testing.expectError(
        error.EndOfStream,
        t.receiver.recvStream(io, alloc, .{ .r = &dropped_reader, .w = undefined }),
    );

    const replayed = try alloc.alloc(u8, frame_len * 2);
    defer alloc.free(replayed);
    @memcpy(replayed[0..frame_len], original[0..frame_len]);
    @memcpy(replayed[frame_len..], original[0..frame_len]);
    var replay_reader: std.Io.Reader = .fixed(replayed);
    try testing.expectError(
        Error.BadRecord,
        t.receiver.recvStream(io, alloc, .{ .r = &replay_reader, .w = undefined }),
    );
}

test "a flipped ciphertext bit fails to authenticate" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var t = try runHandshake(io, "11-fossil-flask", "11-fossil-flask");

    var wire = allocWriter(alloc);
    defer wire.deinit();
    try t.sender.sendStream(io, alloc, .{ .r = undefined, .w = &wire.writer }, "top secret payload");
    const bytes = wire.written();
    bytes[6] ^= 0x40;

    var reader: std.Io.Reader = .fixed(bytes);
    try testing.expectError(
        Error.BadRecord,
        t.receiver.recvStream(io, alloc, .{ .r = &reader, .w = undefined }),
    );
}

test "a stream encrypted under a different code does not decrypt" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var good = try runHandshake(io, "8-copper-cobra", "8-copper-cobra");
    var evil = try runHandshake(io, "8-copper-condor", "8-copper-condor");

    var wire = allocWriter(alloc);
    defer wire.deinit();
    try good.sender.sendStream(io, alloc, .{ .r = undefined, .w = &wire.writer }, "payload");
    var reader: std.Io.Reader = .fixed(wire.written());
    try testing.expectError(
        Error.BadRecord,
        evil.receiver.recvStream(io, alloc, .{ .r = &reader, .w = undefined }),
    );
}

test "the slot table burns a slot after the attempt budget" {
    const alloc = testing.allocator;
    var table = SlotTable.init(std.testing.io, alloc);
    defer table.deinit();

    var i: u32 = 0;
    while (i < max_slot_attempts) : (i += 1) {
        try table.claim(7);
        try testing.expect(!table.isBurned(7));
    }
    try testing.expectError(Error.SlotBurned, table.claim(7));
    try testing.expect(table.isBurned(7));
    try testing.expectError(Error.SlotBurned, table.claim(7));
    try testing.expectEqual(max_slot_attempts, table.attempts(7));

    try table.claim(8);
    try testing.expect(!table.isBurned(8));
    try table.burn(8);
    try testing.expectError(Error.SlotBurned, table.claim(8));
}

const LiveResult = struct {
    ok: bool = false,
    payload: []u8 = &.{},
};

fn rendezvousThread(io: std.Io, alloc: std.mem.Allocator, port: u16) void {
    rendezvous(io, alloc, port) catch {};
}

fn senderThread(
    io: std.Io,
    alloc: std.mem.Allocator,
    port: u16,
    code: []const u8,
    payload: []const u8,
    result: *LiveResult,
) void {
    var attempt: usize = 0;
    const conn = while (attempt < 200) : (attempt += 1) {
        if (Conn.open(io, alloc, "127.0.0.1", port)) |c| break c else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    } else return;
    defer conn.destroy();

    join(conn.channel(), code) catch return;
    var session = senderHandshake(io, alloc, conn.channel(), code) catch return;
    session.sendStream(io, alloc, conn.channel(), payload) catch return;
    result.ok = true;
}

fn receiverThread(
    io: std.Io,
    alloc: std.mem.Allocator,
    port: u16,
    code: []const u8,
    result: *LiveResult,
) void {
    var attempt: usize = 0;
    const conn = while (attempt < 200) : (attempt += 1) {
        if (Conn.open(io, alloc, "127.0.0.1", port)) |c| break c else |_| {
            io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    } else return;
    defer conn.destroy();

    join(conn.channel(), code) catch return;
    var session = receiverHandshake(io, alloc, conn.channel(), code) catch return;
    const got = session.recvStream(io, alloc, conn.channel()) catch return;
    result.payload = got;
    result.ok = true;
}

test "end to end transfer through a live rendezvous" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const port: u16 = 47931;
    const code = "13-hexagon-hickory";
    const payload = "a small pack of guardrail objects" ** 512;

    const server = try std.Thread.spawn(.{}, rendezvousThread, .{ io, alloc, port });
    server.detach();

    var sent: LiveResult = .{};
    var received: LiveResult = .{};

    const rx = try std.Thread.spawn(.{}, receiverThread, .{ io, alloc, port, code, &received });
    const tx = try std.Thread.spawn(.{}, senderThread, .{ io, alloc, port, code, payload, &sent });
    tx.join();
    rx.join();

    defer if (received.payload.len != 0) alloc.free(received.payload);
    try testing.expect(sent.ok);
    try testing.expect(received.ok);
    try testing.expectEqualStrings(payload, received.payload);
}
