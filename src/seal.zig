const std = @import("std");

const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const WrapAead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const X25519 = std.crypto.dh.X25519;
const MlKem = std.crypto.kem.ml_kem.MLKem768;
const Blake3 = std.crypto.hash.Blake3;
const b64 = std.base64.url_safe_no_pad;

pub const key_len = 32;
pub const RepoKey = [key_len]u8;

pub const token_prefix = "gr1:";
pub const public_prefix = "gr1";
pub const secret_prefix = "grsec1";
pub const manifest_name = ".grsealed";
pub const sealed_suffix = ".sealed";

const seal_domain = "gr-seal-v1";
const wrap_domain = "gr-wrap-v1";

pub const Error = error{
    BadToken,
    BadPublicKey,
    BadSecretKey,
    BadWrap,
    BadManifest,
    NotAMember,
};

const Derived = struct {
    key: [32]u8,
    ctx: []u8,
    aad_start: usize,

    fn aad(self: Derived) []const u8 {
        return self.ctx[self.aad_start..];
    }

    fn deinit(self: Derived, alloc: std.mem.Allocator) void {
        alloc.free(self.ctx);
    }
};

fn derive(alloc: std.mem.Allocator, k: RepoKey, path: []const u8, name: []const u8) !Derived {
    const aad_start = seal_domain.len + 1;
    const ctx = try alloc.alloc(u8, aad_start + path.len + 1 + name.len);
    errdefer alloc.free(ctx);
    @memcpy(ctx[0..seal_domain.len], seal_domain);
    ctx[seal_domain.len] = 0;
    @memcpy(ctx[aad_start..][0..path.len], path);
    ctx[aad_start + path.len] = 0;
    @memcpy(ctx[aad_start + path.len + 1 ..], name);

    var out: [32]u8 = undefined;
    Hkdf.expand(&out, ctx, Hkdf.extract(seal_domain, &k));
    return .{ .key = out, .ctx = ctx, .aad_start = aad_start };
}

pub fn sealValue(
    alloc: std.mem.Allocator,
    k: RepoKey,
    path: []const u8,
    name: []const u8,
    plaintext: []const u8,
) ![]u8 {
    const d = try derive(alloc, k, path, name);
    defer d.deinit(alloc);

    var digest: [32]u8 = undefined;
    Blake3.hash(plaintext, &digest, .{ .key = d.key });
    const nonce: [Aead.nonce_length]u8 = digest[0..Aead.nonce_length].*;

    const raw = try alloc.alloc(u8, Aead.nonce_length + plaintext.len + Aead.tag_length);
    defer alloc.free(raw);
    @memcpy(raw[0..Aead.nonce_length], &nonce);
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(
        raw[Aead.nonce_length..][0..plaintext.len],
        &tag,
        plaintext,
        d.aad(),
        nonce,
        d.key,
    );
    @memcpy(raw[Aead.nonce_length + plaintext.len ..], &tag);

    const out = try alloc.alloc(u8, token_prefix.len + b64.Encoder.calcSize(raw.len));
    errdefer alloc.free(out);
    @memcpy(out[0..token_prefix.len], token_prefix);
    _ = b64.Encoder.encode(out[token_prefix.len..], raw);
    return out;
}

pub fn openValue(
    alloc: std.mem.Allocator,
    k: RepoKey,
    path: []const u8,
    name: []const u8,
    token: []const u8,
) ![]u8 {
    if (!std.mem.startsWith(u8, token, token_prefix)) return Error.BadToken;
    const body = token[token_prefix.len..];
    const n = b64.Decoder.calcSizeForSlice(body) catch return Error.BadToken;
    if (n < Aead.nonce_length + Aead.tag_length) return Error.BadToken;

    const raw = try alloc.alloc(u8, n);
    defer alloc.free(raw);
    b64.Decoder.decode(raw, body) catch return Error.BadToken;

    const ct_len = n - Aead.nonce_length - Aead.tag_length;
    const d = try derive(alloc, k, path, name);
    defer d.deinit(alloc);

    const out = try alloc.alloc(u8, ct_len);
    errdefer alloc.free(out);
    const nonce: [Aead.nonce_length]u8 = raw[0..Aead.nonce_length].*;
    const tag: [Aead.tag_length]u8 = raw[Aead.nonce_length + ct_len ..][0..Aead.tag_length].*;
    Aead.decrypt(
        out,
        raw[Aead.nonce_length..][0..ct_len],
        tag,
        d.aad(),
        nonce,
        d.key,
    ) catch return Error.BadToken;
    return out;
}

const Assign = struct {
    name: []const u8,
    eq: usize,
    value: []const u8,
    cr: bool,
};

fn parseAssign(line: []const u8) ?Assign {
    const t = std.mem.trim(u8, line, " \t\r");
    if (t.len == 0 or t[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return null;

    var name = std.mem.trim(u8, line[0..eq], " \t");
    if (std.mem.startsWith(u8, name, "export")) {
        const after = name["export".len..];
        if (after.len != 0 and (after[0] == ' ' or after[0] == '\t')) {
            name = std.mem.trim(u8, after, " \t");
        }
    }
    if (name.len == 0) return null;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return null;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }

    var value = line[eq + 1 ..];
    var cr = false;
    if (value.len != 0 and value[value.len - 1] == '\r') {
        cr = true;
        value = value[0 .. value.len - 1];
    }
    return .{ .name = name, .eq = eq, .value = value, .cr = cr };
}

const Mode = enum { seal, unseal };

fn mapLines(
    alloc: std.mem.Allocator,
    k: RepoKey,
    path: []const u8,
    text: []const u8,
    mode: Mode,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var first = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!first) try out.append(alloc, '\n');
        first = false;

        const a = parseAssign(line) orelse {
            try out.appendSlice(alloc, line);
            continue;
        };
        const is_sealed = std.mem.startsWith(u8, a.value, token_prefix);
        const wanted = switch (mode) {
            .seal => !is_sealed,
            .unseal => is_sealed,
        };
        if (!wanted) {
            try out.appendSlice(alloc, line);
            continue;
        }

        const replacement = switch (mode) {
            .seal => try sealValue(alloc, k, path, a.name, a.value),
            .unseal => try openValue(alloc, k, path, a.name, a.value),
        };
        defer alloc.free(replacement);

        try out.appendSlice(alloc, line[0 .. a.eq + 1]);
        try out.appendSlice(alloc, replacement);
        if (a.cr) try out.append(alloc, '\r');
    }

    return out.toOwnedSlice(alloc);
}

pub fn sealText(alloc: std.mem.Allocator, k: RepoKey, path: []const u8, text: []const u8) ![]u8 {
    return mapLines(alloc, k, path, text, .seal);
}

pub fn unsealText(alloc: std.mem.Allocator, k: RepoKey, path: []const u8, text: []const u8) ![]u8 {
    return mapLines(alloc, k, path, text, .unseal);
}

const fp_words = [_][]const u8{
    "amber",  "anchor",  "apple",  "arrow",   "atlas",   "bacon",   "badge",   "balloon",
    "banjo",  "basil",   "beacon", "bison",   "blossom", "bonsai",  "boulder", "bridge",
    "cactus", "canyon",  "cargo",  "cedar",   "chisel",  "cobalt",  "comet",   "copper",
    "coral",  "crayon",  "dagger", "denim",   "domino",  "dragon",  "ember",   "falcon",
    "fossil", "galaxy",  "garlic", "glacier", "granite", "harbor",  "hazel",   "indigo",
    "ivory",  "jasmine", "jigsaw", "juniper", "kettle",  "lantern", "lemon",   "lilac",
    "magnet", "maple",   "marble", "meadow",  "mosaic",  "nectar",  "nomad",   "orbit",
    "otter",  "paprika", "pebble", "quartz",  "raven",   "saffron", "tundra",  "walnut",
};

pub const PublicId = struct {
    x: [X25519.public_length]u8,
    kem: [MlKem.PublicKey.encoded_length]u8,

    pub const raw_len = X25519.public_length + MlKem.PublicKey.encoded_length;

    pub fn toRaw(self: PublicId) [raw_len]u8 {
        var raw: [raw_len]u8 = undefined;
        @memcpy(raw[0..X25519.public_length], &self.x);
        @memcpy(raw[X25519.public_length..], &self.kem);
        return raw;
    }

    pub fn fromRaw(raw: [raw_len]u8) PublicId {
        return .{
            .x = raw[0..X25519.public_length].*,
            .kem = raw[X25519.public_length..].*,
        };
    }

    pub fn encode(self: PublicId, alloc: std.mem.Allocator) ![]u8 {
        const raw = self.toRaw();
        const out = try alloc.alloc(u8, public_prefix.len + b64.Encoder.calcSize(raw.len));
        errdefer alloc.free(out);
        @memcpy(out[0..public_prefix.len], public_prefix);
        _ = b64.Encoder.encode(out[public_prefix.len..], &raw);
        return out;
    }

    pub fn decode(s: []const u8) !PublicId {
        if (!std.mem.startsWith(u8, s, public_prefix)) return Error.BadPublicKey;
        const body = s[public_prefix.len..];
        const n = b64.Decoder.calcSizeForSlice(body) catch return Error.BadPublicKey;
        if (n != raw_len) return Error.BadPublicKey;
        var raw: [raw_len]u8 = undefined;
        b64.Decoder.decode(&raw, body) catch return Error.BadPublicKey;
        return fromRaw(raw);
    }

    pub fn fingerprint(self: PublicId, alloc: std.mem.Allocator) ![]u8 {
        const raw = self.toRaw();
        var digest: [32]u8 = undefined;
        Blake3.hash(&raw, &digest, .{});

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        for (digest[0..6], 0..) |byte, i| {
            if (i != 0) try out.append(alloc, '-');
            try out.appendSlice(alloc, fp_words[byte & 0x3f]);
        }
        return out.toOwnedSlice(alloc);
    }
};

pub const Identity = struct {
    x_sec: [X25519.secret_length]u8,
    x_pub: [X25519.public_length]u8,
    kem_sec: [MlKem.SecretKey.encoded_length]u8,
    kem_pub: [MlKem.PublicKey.encoded_length]u8,

    pub const raw_len =
        X25519.secret_length + MlKem.SecretKey.encoded_length + MlKem.PublicKey.encoded_length;

    pub fn generate(io: std.Io) Identity {
        const xk = X25519.KeyPair.generate(io);
        const kk = MlKem.KeyPair.generate(io);
        return .{
            .x_sec = xk.secret_key,
            .x_pub = xk.public_key,
            .kem_sec = kk.secret_key.toBytes(),
            .kem_pub = kk.public_key.toBytes(),
        };
    }

    pub fn publicId(self: Identity) PublicId {
        return .{ .x = self.x_pub, .kem = self.kem_pub };
    }

    pub fn encodeSecret(self: Identity, alloc: std.mem.Allocator) ![]u8 {
        var raw: [raw_len]u8 = undefined;
        @memcpy(raw[0..X25519.secret_length], &self.x_sec);
        @memcpy(raw[X25519.secret_length..][0..MlKem.SecretKey.encoded_length], &self.kem_sec);
        @memcpy(raw[X25519.secret_length + MlKem.SecretKey.encoded_length ..], &self.kem_pub);
        const out = try alloc.alloc(u8, secret_prefix.len + b64.Encoder.calcSize(raw.len));
        errdefer alloc.free(out);
        @memcpy(out[0..secret_prefix.len], secret_prefix);
        _ = b64.Encoder.encode(out[secret_prefix.len..], &raw);
        return out;
    }

    pub fn decodeSecret(s: []const u8) !Identity {
        if (!std.mem.startsWith(u8, s, secret_prefix)) return Error.BadSecretKey;
        const body = s[secret_prefix.len..];
        const n = b64.Decoder.calcSizeForSlice(body) catch return Error.BadSecretKey;
        if (n != raw_len) return Error.BadSecretKey;
        var raw: [raw_len]u8 = undefined;
        b64.Decoder.decode(&raw, body) catch return Error.BadSecretKey;

        const x_sec: [X25519.secret_length]u8 = raw[0..X25519.secret_length].*;
        const kem_sec: [MlKem.SecretKey.encoded_length]u8 =
            raw[X25519.secret_length..][0..MlKem.SecretKey.encoded_length].*;
        const kem_pub: [MlKem.PublicKey.encoded_length]u8 =
            raw[X25519.secret_length + MlKem.SecretKey.encoded_length ..].*;
        _ = MlKem.SecretKey.fromBytes(&kem_sec) catch return Error.BadSecretKey;
        _ = MlKem.PublicKey.fromBytes(&kem_pub) catch return Error.BadSecretKey;
        return .{
            .x_sec = x_sec,
            .x_pub = X25519.recoverPublicKey(x_sec) catch return Error.BadSecretKey,
            .kem_sec = kem_sec,
            .kem_pub = kem_pub,
        };
    }
};

pub const wrap_len = X25519.public_length + MlKem.ciphertext_length + key_len + WrapAead.tag_length;

fn wrapKeyMaterial(
    alloc: std.mem.Allocator,
    shared_x: [X25519.shared_length]u8,
    shared_kem: [MlKem.shared_length]u8,
    eph_pub: [X25519.public_length]u8,
    recipient_x: [X25519.public_length]u8,
    kem_ct: [MlKem.ciphertext_length]u8,
) ![32]u8 {
    var ikm: [X25519.shared_length + MlKem.shared_length]u8 = undefined;
    @memcpy(ikm[0..X25519.shared_length], &shared_x);
    @memcpy(ikm[X25519.shared_length..], &shared_kem);

    const ctx = try alloc.alloc(u8, eph_pub.len + recipient_x.len + kem_ct.len);
    defer alloc.free(ctx);
    @memcpy(ctx[0..eph_pub.len], &eph_pub);
    @memcpy(ctx[eph_pub.len..][0..recipient_x.len], &recipient_x);
    @memcpy(ctx[eph_pub.len + recipient_x.len ..], &kem_ct);

    var wk: [32]u8 = undefined;
    Hkdf.expand(&wk, ctx, Hkdf.extract(wrap_domain, &ikm));
    return wk;
}

pub fn wrapKey(alloc: std.mem.Allocator, io: std.Io, k: RepoKey, to: PublicId) ![]u8 {
    const eph = X25519.KeyPair.generate(io);
    const shared_x = X25519.scalarmult(eph.secret_key, to.x) catch return Error.BadPublicKey;
    const pk = MlKem.PublicKey.fromBytes(&to.kem) catch return Error.BadPublicKey;
    const enc = pk.encaps(io);

    const wk = try wrapKeyMaterial(
        alloc,
        shared_x,
        enc.shared_secret,
        eph.public_key,
        to.x,
        enc.ciphertext,
    );

    var raw: [wrap_len]u8 = undefined;
    @memcpy(raw[0..X25519.public_length], &eph.public_key);
    @memcpy(raw[X25519.public_length..][0..MlKem.ciphertext_length], &enc.ciphertext);

    const ct_off = X25519.public_length + MlKem.ciphertext_length;
    var tag: [WrapAead.tag_length]u8 = undefined;
    const nonce = [_]u8{0} ** WrapAead.nonce_length;
    WrapAead.encrypt(raw[ct_off..][0..key_len], &tag, &k, wrap_domain, nonce, wk);
    @memcpy(raw[ct_off + key_len ..], &tag);

    const out = try alloc.alloc(u8, b64.Encoder.calcSize(raw.len));
    errdefer alloc.free(out);
    _ = b64.Encoder.encode(out, &raw);
    return out;
}

pub fn unwrapKey(alloc: std.mem.Allocator, blob: []const u8, id: Identity) !RepoKey {
    const n = b64.Decoder.calcSizeForSlice(blob) catch return Error.BadWrap;
    if (n != wrap_len) return Error.BadWrap;
    var raw: [wrap_len]u8 = undefined;
    b64.Decoder.decode(&raw, blob) catch return Error.BadWrap;

    const eph_pub: [X25519.public_length]u8 = raw[0..X25519.public_length].*;
    const kem_ct: [MlKem.ciphertext_length]u8 =
        raw[X25519.public_length..][0..MlKem.ciphertext_length].*;

    const shared_x = X25519.scalarmult(id.x_sec, eph_pub) catch return Error.BadWrap;
    const sk = MlKem.SecretKey.fromBytes(&id.kem_sec) catch return Error.BadSecretKey;
    const shared_kem = sk.decaps(&kem_ct) catch return Error.BadWrap;

    const wk = try wrapKeyMaterial(alloc, shared_x, shared_kem, eph_pub, id.x_pub, kem_ct);

    const ct_off = X25519.public_length + MlKem.ciphertext_length;
    const tag: [WrapAead.tag_length]u8 = raw[ct_off + key_len ..].*;
    var k: RepoKey = undefined;
    const nonce = [_]u8{0} ** WrapAead.nonce_length;
    WrapAead.decrypt(&k, raw[ct_off..][0..key_len], tag, wrap_domain, nonce, wk) catch
        return Error.BadWrap;
    return k;
}

pub fn newRepoKey(io: std.Io) RepoKey {
    var k: RepoKey = undefined;
    io.random(&k);
    return k;
}

pub const Member = struct {
    name: []u8,
    public: PublicId,
    wrapped: []u8,
};

pub const Sealed = struct {
    path: []u8,
    body: ?[]u8,
};

pub const body_prefix = '|';

pub const Manifest = struct {
    alloc: std.mem.Allocator,
    files: std.ArrayList(Sealed),
    members: std.ArrayList(Member),

    pub fn empty(alloc: std.mem.Allocator) Manifest {
        return .{ .alloc = alloc, .files = .empty, .members = .empty };
    }

    pub fn deinit(self: *Manifest) void {
        for (self.files.items) |f| {
            self.alloc.free(f.path);
            if (f.body) |b| self.alloc.free(b);
        }
        self.files.deinit(self.alloc);
        for (self.members.items) |m| {
            self.alloc.free(m.name);
            self.alloc.free(m.wrapped);
        }
        self.members.deinit(self.alloc);
    }

    pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Manifest {
        var m = Manifest.empty(alloc);
        errdefer m.deinit();

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var collecting = false;

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            if (raw.len != 0 and raw[0] == body_prefix) {
                if (!collecting) return Error.BadManifest;
                if (body.items.len != 0) try body.append(alloc, '\n');
                var content = raw[1..];
                if (content.len != 0 and content[0] == ' ') content = content[1..];
                try body.appendSlice(alloc, content);
                continue;
            }
            if (collecting) {
                try m.attachBody(body.items);
                body.clearRetainingCapacity();
                collecting = false;
            }

            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;

            var it = std.mem.tokenizeAny(u8, line, " \t");
            const kind = it.next() orelse continue;
            if (std.mem.eql(u8, kind, "version")) continue;
            if (std.mem.eql(u8, kind, "seal")) {
                const path = it.next() orelse return Error.BadManifest;
                try m.files.append(alloc, .{ .path = try alloc.dupe(u8, path), .body = null });
                collecting = true;
            } else if (std.mem.eql(u8, kind, "wrap")) {
                const name = it.next() orelse return Error.BadManifest;
                const pub_s = it.next() orelse return Error.BadManifest;
                const wrapped = it.next() orelse return Error.BadManifest;
                const public = try PublicId.decode(pub_s);
                const name_copy = try alloc.dupe(u8, name);
                errdefer alloc.free(name_copy);
                const wrapped_copy = try alloc.dupe(u8, wrapped);
                errdefer alloc.free(wrapped_copy);
                try m.members.append(alloc, .{
                    .name = name_copy,
                    .public = public,
                    .wrapped = wrapped_copy,
                });
            } else {
                return Error.BadManifest;
            }
        }
        if (collecting) try m.attachBody(body.items);
        return m;
    }

    fn attachBody(self: *Manifest, text: []const u8) !void {
        if (text.len == 0) return;
        const last = &self.files.items[self.files.items.len - 1];
        if (last.body) |b| self.alloc.free(b);
        last.body = try self.alloc.dupe(u8, text);
    }

    pub fn render(self: *const Manifest, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.appendSlice(alloc, "version 1\n");
        for (self.files.items) |f| {
            try out.print(alloc, "seal {s}\n", .{f.path});
            const text = f.body orelse continue;
            var body_lines = std.mem.splitScalar(u8, text, '\n');
            while (body_lines.next()) |line| {
                if (line.len == 0) {
                    try out.append(alloc, body_prefix);
                } else {
                    try out.print(alloc, "{c} {s}", .{ body_prefix, line });
                }
                try out.append(alloc, '\n');
            }
        }
        for (self.members.items) |m| {
            const enc = try m.public.encode(alloc);
            defer alloc.free(enc);
            try out.print(alloc, "wrap {s} {s} {s}\n", .{ m.name, enc, m.wrapped });
        }
        return out.toOwnedSlice(alloc);
    }

    pub fn hasPath(self: *const Manifest, path: []const u8) bool {
        return self.find(path) != null;
    }

    pub fn find(self: *const Manifest, path: []const u8) ?usize {
        for (self.files.items, 0..) |f, i| {
            if (std.mem.eql(u8, f.path, path)) return i;
        }
        return null;
    }

    pub fn bodyOf(self: *const Manifest, path: []const u8) ?[]const u8 {
        const i = self.find(path) orelse return null;
        return self.files.items[i].body;
    }

    /// Replace the sealed text for `path`. Returns true when the bytes changed,
    /// so callers can skip rewriting the manifest on a no-op save.
    pub fn setBody(self: *Manifest, path: []const u8, text: []const u8) !bool {
        const i = self.find(path) orelse return false;
        const slot = &self.files.items[i];
        if (slot.body) |old| {
            if (std.mem.eql(u8, old, text)) return false;
            self.alloc.free(old);
        }
        slot.body = try self.alloc.dupe(u8, text);
        return true;
    }

    pub fn addPath(self: *Manifest, path: []const u8) !bool {
        if (self.hasPath(path)) return false;
        try self.files.append(self.alloc, .{ .path = try self.alloc.dupe(u8, path), .body = null });
        return true;
    }

    pub fn findMember(self: *const Manifest, name: []const u8) ?usize {
        for (self.members.items, 0..) |m, i| {
            if (std.mem.eql(u8, m.name, name)) return i;
        }
        return null;
    }

    pub fn removeMember(self: *Manifest, name: []const u8) bool {
        const i = self.findMember(name) orelse return false;
        const m = self.members.orderedRemove(i);
        self.alloc.free(m.name);
        self.alloc.free(m.wrapped);
        return true;
    }

    pub fn putMember(
        self: *Manifest,
        io: std.Io,
        k: RepoKey,
        name: []const u8,
        public: PublicId,
    ) !void {
        const wrapped = try wrapKey(self.alloc, io, k, public);
        errdefer self.alloc.free(wrapped);
        if (self.findMember(name)) |i| {
            self.alloc.free(self.members.items[i].wrapped);
            self.members.items[i].wrapped = wrapped;
            self.members.items[i].public = public;
            return;
        }
        const name_copy = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(name_copy);
        try self.members.append(self.alloc, .{
            .name = name_copy,
            .public = public,
            .wrapped = wrapped,
        });
    }

    pub fn unwrapFor(self: *const Manifest, alloc: std.mem.Allocator, id: Identity) !RepoKey {
        const mine = id.publicId();
        for (self.members.items) |m| {
            if (!std.mem.eql(u8, &m.public.x, &mine.x)) continue;
            return unwrapKey(alloc, m.wrapped, id);
        }
        return Error.NotAMember;
    }

    pub fn rewrapAll(self: *Manifest, io: std.Io, k: RepoKey) !void {
        for (self.members.items) |*m| {
            const wrapped = try wrapKey(self.alloc, io, k, m.public);
            self.alloc.free(m.wrapped);
            m.wrapped = wrapped;
        }
    }
};

pub fn sealedPathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ path, sealed_suffix });
}

pub fn sourcePath(sealed: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, sealed, sealed_suffix)) return null;
    return sealed[0 .. sealed.len - sealed_suffix.len];
}

// --- tests ---

const testing = std.testing;

test "seal then open a value roundtrips" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{7} ** key_len;

    const token = try sealValue(alloc, k, ".env", "DATABASE_URL", "postgres://localhost/x");
    defer alloc.free(token);
    try testing.expect(std.mem.startsWith(u8, token, token_prefix));

    const back = try openValue(alloc, k, ".env", "DATABASE_URL", token);
    defer alloc.free(back);
    try testing.expectEqualStrings("postgres://localhost/x", back);
}

test "sealing is deterministic for an unchanged value" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{9} ** key_len;

    const a = try sealValue(alloc, k, ".env", "TOKEN", "abc123");
    defer alloc.free(a);
    const b = try sealValue(alloc, k, ".env", "TOKEN", "abc123");
    defer alloc.free(b);
    try testing.expectEqualStrings(a, b);

    const c = try sealValue(alloc, k, ".env", "TOKEN", "abc124");
    defer alloc.free(c);
    try testing.expect(!std.mem.eql(u8, a, c));
}

test "the same value under two names produces unrelated ciphertext" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{3} ** key_len;

    const a = try sealValue(alloc, k, ".env", "STAGING_DB", "same");
    defer alloc.free(a);
    const b = try sealValue(alloc, k, ".env", "PROD_DB", "same");
    defer alloc.free(b);
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "moving a token to another name fails authentication" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{5} ** key_len;

    const token = try sealValue(alloc, k, ".env", "STAGING_DB", "staging-secret");
    defer alloc.free(token);
    try testing.expectError(Error.BadToken, openValue(alloc, k, ".env", "PROD_DB", token));
    try testing.expectError(Error.BadToken, openValue(alloc, k, ".env.local", "STAGING_DB", token));

    const other: RepoKey = [_]u8{6} ** key_len;
    try testing.expectError(Error.BadToken, openValue(alloc, other, ".env", "STAGING_DB", token));
}

test "text roundtrip preserves comments, blanks and layout" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{1} ** key_len;
    const src =
        \\# a comment
        \\
        \\DATABASE_URL=postgres://localhost/x
        \\export API_KEY="sk-live-123"
        \\  SPACED  =  value with spaces
        \\EMPTY=
        \\not an assignment
        \\
    ;

    const sealed = try sealText(alloc, k, ".env", src);
    defer alloc.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "postgres://localhost/x") == null);
    try testing.expect(std.mem.indexOf(u8, sealed, "sk-live-123") == null);
    try testing.expect(std.mem.indexOf(u8, sealed, "# a comment") != null);
    try testing.expect(std.mem.indexOf(u8, sealed, "not an assignment") != null);

    const opened = try unsealText(alloc, k, ".env", sealed);
    defer alloc.free(opened);
    try testing.expectEqualStrings(src, opened);
}

test "sealing an already sealed file is a no-op" {
    const alloc = testing.allocator;
    const k: RepoKey = [_]u8{2} ** key_len;

    const once = try sealText(alloc, k, ".env", "A=1\nB=2\n");
    defer alloc.free(once);
    const twice = try sealText(alloc, k, ".env", once);
    defer alloc.free(twice);
    try testing.expectEqualStrings(once, twice);
}

test "wrap and unwrap the repo key" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const nico = Identity.generate(io);
    const dana = Identity.generate(io);
    const k = newRepoKey(io);

    const blob = try wrapKey(alloc, io, k, dana.publicId());
    defer alloc.free(blob);

    const got = try unwrapKey(alloc, blob, dana);
    try testing.expectEqualSlices(u8, &k, &got);
    try testing.expectError(Error.BadWrap, unwrapKey(alloc, blob, nico));
}

test "public and secret key encodings roundtrip" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const id = Identity.generate(io);
    const pub_s = try id.publicId().encode(alloc);
    defer alloc.free(pub_s);
    const decoded = try PublicId.decode(pub_s);
    try testing.expectEqualSlices(u8, &id.x_pub, &decoded.x);
    try testing.expectEqualSlices(u8, &id.kem_pub, &decoded.kem);

    const sec_s = try id.encodeSecret(alloc);
    defer alloc.free(sec_s);
    const back = try Identity.decodeSecret(sec_s);
    try testing.expectEqualSlices(u8, &id.x_sec, &back.x_sec);
    try testing.expectEqualSlices(u8, &id.kem_sec, &back.kem_sec);
    try testing.expectEqualSlices(u8, &id.kem_pub, &back.kem_pub);

    try testing.expectError(Error.BadPublicKey, PublicId.decode("nope"));

    const fp = try id.publicId().fingerprint(alloc);
    defer alloc.free(fp);
    try testing.expect(fp.len != 0);
}

test "manifest roundtrip, membership and rotation" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const nico = Identity.generate(io);
    const dana = Identity.generate(io);
    const mallory = Identity.generate(io);
    const k = newRepoKey(io);

    var m = Manifest.empty(alloc);
    defer m.deinit();
    try testing.expect(try m.addPath(".env"));
    try testing.expect(!try m.addPath(".env"));
    try m.putMember(io, k, "nico", nico.publicId());
    try m.putMember(io, k, "dana", dana.publicId());

    const text = try m.render(alloc);
    defer alloc.free(text);

    var parsed = try Manifest.parse(alloc, text);
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 1), parsed.files.items.len);
    try testing.expectEqualStrings(".env", parsed.files.items[0].path);
    try testing.expectEqual(@as(usize, 2), parsed.members.items.len);

    try testing.expectEqualSlices(u8, &k, &try parsed.unwrapFor(alloc, nico));
    try testing.expectEqualSlices(u8, &k, &try parsed.unwrapFor(alloc, dana));
    try testing.expectError(Error.NotAMember, parsed.unwrapFor(alloc, mallory));

    try testing.expect(parsed.removeMember("dana"));
    try testing.expect(!parsed.removeMember("dana"));

    const k2 = newRepoKey(io);
    try parsed.rewrapAll(io, k2);
    try testing.expectEqualSlices(u8, &k2, &try parsed.unwrapFor(alloc, nico));

    try testing.expectError(Error.BadManifest, Manifest.parse(alloc, "bogus line here"));
}

test "a sealed body survives the manifest byte for byte" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    const nico = Identity.generate(io);
    const k = newRepoKey(io);
    const src =
        \\# a comment
        \\
        \\DATABASE_URL=postgres://localhost/x
        \\  SPACED  =  value with spaces
        \\EMPTY=
        \\
    ;
    const sealed = try sealText(alloc, k, ".env", src);
    defer alloc.free(sealed);

    var m = Manifest.empty(alloc);
    defer m.deinit();
    _ = try m.addPath(".env");
    try m.putMember(io, k, "nico", nico.publicId());
    try testing.expect(try m.setBody(".env", sealed));
    try testing.expect(!try m.setBody(".env", sealed));

    const text = try m.render(alloc);
    defer alloc.free(text);
    try testing.expect(std.mem.indexOf(u8, text, "postgres://localhost/x") == null);

    var parsed = try Manifest.parse(alloc, text);
    defer parsed.deinit();
    try testing.expectEqualStrings(sealed, parsed.bodyOf(".env").?);

    const opened = try unsealText(alloc, k, ".env", parsed.bodyOf(".env").?);
    defer alloc.free(opened);
    try testing.expectEqualStrings(src, opened);

    try testing.expect(parsed.bodyOf(".env.other") == null);
    try testing.expectError(Error.BadManifest, Manifest.parse(alloc, "| orphan body line"));
}

test "sealed path naming" {
    const alloc = testing.allocator;
    const p = try sealedPathAlloc(alloc, ".env");
    defer alloc.free(p);
    try testing.expectEqualStrings(".env.sealed", p);
    try testing.expectEqualStrings(".env", sourcePath(".env.sealed").?);
    try testing.expect(sourcePath(".env") == null);
}
