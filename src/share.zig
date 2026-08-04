const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store = @import("store.zig");
const Oid = oid.Oid;
const Store = store.Store;

const net = std.Io.net;
const Aead = std.crypto.aead.chacha_poly.XChaCha20Poly1305;
const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
const Blake3 = std.crypto.hash.Blake3;
const b64 = std.base64.url_safe_no_pad;

pub const key_len = 32;
pub const ShareKey = [key_len]u8;

pub const id_len = 8;
pub const name_raw_len = 16;
pub const name_len = 22;

const share_domain = "gr-share-v1";
const id_domain = "gr-share-id-v1";
const root_aad = "gr-share-root-v1";
const obj_ctx_prefix = "obj";
const root_ctx = "root";
const name_ctx = "name";

pub const bundle_magic = "GRB1";
pub const root_leaf = "root";
pub const objects_leaf = "o";
pub const path_segment = "/r/";

pub const Error = error{
    BadUrl,
    BadShare,
    BadRecord,
    BadBundle,
    BadRoot,
    BadPath,
    HashMismatch,
    HttpStatus,
    HttpProtocol,
    UnsupportedScheme,
};

pub fn newShareKey(io: std.Io) ShareKey {
    var s: ShareKey = undefined;
    io.random(&s);
    return s;
}

pub fn shareId(s: ShareKey, buf: *[id_len]u8) []const u8 {
    var digest: [32]u8 = undefined;
    Blake3.hash(id_domain, &digest, .{ .key = s });
    const hex = "0123456789abcdef";
    for (digest[0 .. id_len / 2], 0..) |byte, i| {
        buf[i * 2] = hex[byte >> 4];
        buf[i * 2 + 1] = hex[byte & 0x0f];
    }
    return buf[0..id_len];
}

const Prk = [Hkdf.prk_length]u8;

fn prkOf(s: ShareKey) Prk {
    return Hkdf.extract(share_domain, &s);
}

fn objectKey(prk: Prk, o: Oid) [32]u8 {
    var ctx: [obj_ctx_prefix.len + 1 + Oid.len]u8 = undefined;
    @memcpy(ctx[0..obj_ctx_prefix.len], obj_ctx_prefix);
    ctx[obj_ctx_prefix.len] = 0;
    @memcpy(ctx[obj_ctx_prefix.len + 1 ..], &o.bytes);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, &ctx, prk);
    return out;
}

fn rootKey(prk: Prk) [32]u8 {
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, root_ctx, prk);
    return out;
}

fn nameKey(prk: Prk) [32]u8 {
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, name_ctx, prk);
    return out;
}

fn blindedRaw(nk: [32]u8, o: Oid) [name_raw_len]u8 {
    var digest: [32]u8 = undefined;
    Blake3.hash(&o.bytes, &digest, .{ .key = nk });
    return digest[0..name_raw_len].*;
}

pub fn blindedName(s: ShareKey, o: Oid, buf: *[name_len]u8) []const u8 {
    const raw = blindedRaw(nameKey(prkOf(s)), o);
    _ = b64.Encoder.encode(buf, &raw);
    return buf[0..name_len];
}

fn sealRecord(
    alloc: std.mem.Allocator,
    key: [32]u8,
    aad: []const u8,
    plaintext: []const u8,
) ![]u8 {
    var digest: [32]u8 = undefined;
    Blake3.hash(plaintext, &digest, .{ .key = key });
    const nonce: [Aead.nonce_length]u8 = digest[0..Aead.nonce_length].*;

    const out = try alloc.alloc(u8, Aead.nonce_length + plaintext.len + Aead.tag_length);
    errdefer alloc.free(out);
    @memcpy(out[0..Aead.nonce_length], &nonce);
    var tag: [Aead.tag_length]u8 = undefined;
    Aead.encrypt(out[Aead.nonce_length..][0..plaintext.len], &tag, plaintext, aad, nonce, key);
    @memcpy(out[Aead.nonce_length + plaintext.len ..], &tag);
    return out;
}

fn openRecord(
    alloc: std.mem.Allocator,
    key: [32]u8,
    aad: []const u8,
    record: []const u8,
) ![]u8 {
    if (record.len < Aead.nonce_length + Aead.tag_length) return Error.BadRecord;
    const ct_len = record.len - Aead.nonce_length - Aead.tag_length;
    const nonce: [Aead.nonce_length]u8 = record[0..Aead.nonce_length].*;
    const tag: [Aead.tag_length]u8 = record[Aead.nonce_length + ct_len ..][0..Aead.tag_length].*;

    const out = try alloc.alloc(u8, ct_len);
    errdefer alloc.free(out);
    Aead.decrypt(out, record[Aead.nonce_length..][0..ct_len], tag, aad, nonce, key) catch
        return Error.BadRecord;
    return out;
}

fn sealObject(alloc: std.mem.Allocator, prk: Prk, o: Oid, raw: []const u8) ![]u8 {
    return sealRecord(alloc, objectKey(prk, o), &o.bytes, raw);
}

fn openObject(alloc: std.mem.Allocator, prk: Prk, o: Oid, record: []const u8) ![]u8 {
    const plain = try openRecord(alloc, objectKey(prk, o), &o.bytes, record);
    errdefer alloc.free(plain);
    if (!Oid.ofBytes(plain).eql(o)) return Error.HashMismatch;
    return plain;
}

pub const Ref = struct {
    name: []u8,
    target: Oid,
};

pub fn freeRefs(alloc: std.mem.Allocator, refs: []Ref) void {
    for (refs) |r| alloc.free(r.name);
    alloc.free(refs);
}

fn refsFor(st: *Store, alloc: std.mem.Allocator, branches: []const []const u8) ![]Ref {
    var out: std.ArrayList(Ref) = .empty;
    errdefer {
        for (out.items) |r| alloc.free(r.name);
        out.deinit(alloc);
    }
    if (branches.len == 0) {
        const head = try st.headBranch();
        defer st.alloc.free(head);
        const target = try st.readRef(head);
        try out.append(alloc, .{ .name = try alloc.dupe(u8, head), .target = target });
    } else {
        for (branches) |b| {
            const target = try st.readRef(b);
            try out.append(alloc, .{ .name = try alloc.dupe(u8, b), .target = target });
        }
    }
    return out.toOwnedSlice(alloc);
}

fn renderRoot(alloc: std.mem.Allocator, refs: []const Ref) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "version 1\n");
    for (refs) |r| {
        var hex: [Oid.len * 2]u8 = undefined;
        try out.print(alloc, "{s} {s}\n", .{ r.name, r.target.toHex(&hex) });
    }
    return out.toOwnedSlice(alloc);
}

fn parseRoot(alloc: std.mem.Allocator, text: []const u8) ![]Ref {
    var out: std.ArrayList(Ref) = .empty;
    errdefer {
        for (out.items) |r| alloc.free(r.name);
        out.deinit(alloc);
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const name = it.next() orelse continue;
        const value = it.next() orelse return Error.BadRoot;
        if (std.mem.eql(u8, name, "version") and value.len != Oid.len * 2) continue;
        const target = Oid.fromHex(value) catch return Error.BadRoot;
        try out.append(alloc, .{ .name = try alloc.dupe(u8, name), .target = target });
    }
    if (out.items.len == 0) return Error.BadRoot;
    return out.toOwnedSlice(alloc);
}

const Seen = std.AutoHashMap([32]u8, void);

fn oidLessThan(_: void, a: Oid, b: Oid) bool {
    return std.mem.lessThan(u8, &a.bytes, &b.bytes);
}

pub fn collectReachable(st: *Store, alloc: std.mem.Allocator, roots: []const Ref) ![]Oid {
    var seen = Seen.init(alloc);
    defer seen.deinit();

    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(alloc);

    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);
    for (roots) |r| try stack.append(alloc, r.target);

    while (stack.pop()) |o| {
        if (o.isZero()) continue;
        if ((try seen.getOrPut(o.bytes)).found_existing) continue;
        try out.append(alloc, o);

        const change = try st.readChange(o);
        defer object.freeChange(st.alloc, change);
        for (change.parents) |p| try stack.append(alloc, p);

        if ((try seen.getOrPut(change.tree.bytes)).found_existing) continue;
        try out.append(alloc, change.tree);

        const tree = try st.readTree(change.tree);
        defer object.freeTree(st.alloc, tree);
        for (tree.entries) |e| {
            if ((try seen.getOrPut(e.blob.bytes)).found_existing) continue;
            try out.append(alloc, e.blob);

            const raw = try st.readRaw(e.blob);
            defer st.alloc.free(raw);
            const blob = try object.Blob.decode(st.alloc, raw);
            defer st.alloc.free(blob.chunks);
            for (blob.chunks) |c| {
                if ((try seen.getOrPut(c.bytes)).found_existing) continue;
                try out.append(alloc, c);
            }
        }
    }

    const list = try out.toOwnedSlice(alloc);
    std.mem.sort(Oid, list, {}, oidLessThan);
    return list;
}

fn obtain(st: *Store, alloc: std.mem.Allocator, src: anytype, o: Oid) ![]u8 {
    if (st.has(o)) return st.readRaw(o);
    const raw = try src.fetch(alloc, o);
    errdefer alloc.free(raw);
    if (!Oid.ofBytes(raw).eql(o)) return Error.HashMismatch;
    _ = try st.writeRaw(raw);
    return raw;
}

fn importGraph(st: *Store, alloc: std.mem.Allocator, src: anytype, refs: []const Ref) !void {
    var seen = Seen.init(alloc);
    defer seen.deinit();

    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);
    for (refs) |r| try stack.append(alloc, r.target);

    while (stack.pop()) |o| {
        if (o.isZero()) continue;
        if ((try seen.getOrPut(o.bytes)).found_existing) continue;

        const change_raw = try obtain(st, alloc, src, o);
        defer alloc.free(change_raw);
        const change = try object.Change.decode(alloc, change_raw);
        defer object.freeChange(alloc, change);
        for (change.parents) |p| try stack.append(alloc, p);

        if ((try seen.getOrPut(change.tree.bytes)).found_existing) continue;
        const tree_raw = try obtain(st, alloc, src, change.tree);
        defer alloc.free(tree_raw);
        const tree = try object.Tree.decode(alloc, tree_raw);
        defer object.freeTree(alloc, tree);

        for (tree.entries) |e| {
            if ((try seen.getOrPut(e.blob.bytes)).found_existing) continue;
            const blob_raw = try obtain(st, alloc, src, e.blob);
            defer alloc.free(blob_raw);
            const blob = try object.Blob.decode(alloc, blob_raw);
            defer alloc.free(blob.chunks);
            for (blob.chunks) |c| {
                if ((try seen.getOrPut(c.bytes)).found_existing) continue;
                const chunk = try obtain(st, alloc, src, c);
                alloc.free(chunk);
            }
        }
    }

    for (refs) |r| try st.updateRef(r.name, r.target);
}

pub fn encodeUrl(alloc: std.mem.Allocator, base_url: []const u8, s: ShareKey) ![]u8 {
    const base = std.mem.trimEnd(u8, base_url, "/");
    var idbuf: [id_len]u8 = undefined;
    const id = shareId(s, &idbuf);
    var kbuf: [b64.Encoder.calcSize(key_len)]u8 = undefined;
    _ = b64.Encoder.encode(&kbuf, &s);
    return std.fmt.allocPrint(alloc, "{s}{s}{s}#k={s}", .{ base, path_segment, id, kbuf });
}

pub const ParsedUrl = struct {
    base: []u8,
    id: []u8,
    key: ShareKey,

    pub fn deinit(self: ParsedUrl, alloc: std.mem.Allocator) void {
        alloc.free(self.base);
        alloc.free(self.id);
    }
};

fn isHexLower(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        if (!ok) return false;
    }
    return true;
}

pub fn parseUrl(alloc: std.mem.Allocator, url: []const u8) !ParsedUrl {
    const hash = std.mem.indexOfScalar(u8, url, '#') orelse return Error.BadUrl;
    const link = std.mem.trimEnd(u8, url[0..hash], "/");
    const fragment = url[hash + 1 ..];

    var key: ShareKey = undefined;
    var found = false;
    var parts = std.mem.splitScalar(u8, fragment, '&');
    while (parts.next()) |part| {
        if (!std.mem.startsWith(u8, part, "k=")) continue;
        const body = part[2..];
        const n = b64.Decoder.calcSizeForSlice(body) catch return Error.BadUrl;
        if (n != key_len) return Error.BadUrl;
        b64.Decoder.decode(&key, body) catch return Error.BadUrl;
        found = true;
        break;
    }
    if (!found) return Error.BadUrl;

    const at = std.mem.lastIndexOf(u8, link, path_segment) orelse return Error.BadUrl;
    const id = link[at + path_segment.len ..];
    if (id.len != id_len or !isHexLower(id)) return Error.BadUrl;

    var idbuf: [id_len]u8 = undefined;
    if (!std.mem.eql(u8, shareId(key, &idbuf), id)) return Error.BadShare;

    const base = try alloc.dupe(u8, link[0..at]);
    errdefer alloc.free(base);
    const id_copy = try alloc.dupe(u8, id);
    return .{ .base = base, .id = id_copy, .key = key };
}

fn rootSubPath(id: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "r/{s}/{s}", .{ id, root_leaf }) catch unreachable;
}

fn objectSubPath(id: []const u8, name: []const u8, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "r/{s}/{s}/{s}", .{ id, objects_leaf, name }) catch unreachable;
}

pub fn exportDir(
    st: *Store,
    alloc: std.mem.Allocator,
    io: std.Io,
    s: ShareKey,
    dest: std.Io.Dir,
    branches: []const []const u8,
) !void {
    const refs = try refsFor(st, alloc, branches);
    defer freeRefs(alloc, refs);

    const prk = prkOf(s);
    const nk = nameKey(prk);
    var idbuf: [id_len]u8 = undefined;
    const id = shareId(s, &idbuf);

    var dirbuf: [64]u8 = undefined;
    const objects_dir = std.fmt.bufPrint(&dirbuf, "r/{s}/{s}", .{ id, objects_leaf }) catch unreachable;
    try dest.createDirPath(io, objects_dir);

    const root_text = try renderRoot(alloc, refs);
    defer alloc.free(root_text);
    const root_record = try sealRecord(alloc, rootKey(prk), root_aad, root_text);
    defer alloc.free(root_record);

    var pathbuf: [96]u8 = undefined;
    try dest.writeFile(io, .{
        .sub_path = rootSubPath(id, &pathbuf),
        .data = root_record,
    });

    const oids = try collectReachable(st, alloc, refs);
    defer alloc.free(oids);

    for (oids) |o| {
        const raw = try st.readRaw(o);
        defer alloc.free(raw);
        const record = try sealObject(alloc, prk, o, raw);
        defer alloc.free(record);

        var namebuf: [name_len]u8 = undefined;
        const raw_name = blindedRaw(nk, o);
        _ = b64.Encoder.encode(&namebuf, &raw_name);
        try dest.writeFile(io, .{
            .sub_path = objectSubPath(id, &namebuf, &pathbuf),
            .data = record,
        });
    }
}

fn appendRecord(alloc: std.mem.Allocator, out: *std.ArrayList(u8), payload: []const u8) !void {
    var len: [8]u8 = undefined;
    std.mem.writeInt(u64, &len, @intCast(payload.len), .little);
    try out.appendSlice(alloc, &len);
    try out.appendSlice(alloc, payload);
}

pub fn buildBundle(
    st: *Store,
    alloc: std.mem.Allocator,
    s: ShareKey,
    branches: []const []const u8,
) ![]u8 {
    const refs = try refsFor(st, alloc, branches);
    defer freeRefs(alloc, refs);

    const prk = prkOf(s);
    const nk = nameKey(prk);
    var idbuf: [id_len]u8 = undefined;
    const id = shareId(s, &idbuf);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, bundle_magic);
    try out.appendSlice(alloc, id);

    const root_text = try renderRoot(alloc, refs);
    defer alloc.free(root_text);
    const root_record = try sealRecord(alloc, rootKey(prk), root_aad, root_text);
    defer alloc.free(root_record);
    try appendRecord(alloc, &out, root_record);

    const oids = try collectReachable(st, alloc, refs);
    defer alloc.free(oids);

    for (oids) |o| {
        const raw = try st.readRaw(o);
        defer alloc.free(raw);
        const record = try sealObject(alloc, prk, o, raw);
        defer alloc.free(record);

        const payload = try alloc.alloc(u8, name_raw_len + record.len);
        defer alloc.free(payload);
        const raw_name = blindedRaw(nk, o);
        @memcpy(payload[0..name_raw_len], &raw_name);
        @memcpy(payload[name_raw_len..], record);
        try appendRecord(alloc, &out, payload);
    }

    return out.toOwnedSlice(alloc);
}

pub fn writeBundle(
    st: *Store,
    alloc: std.mem.Allocator,
    io: std.Io,
    s: ShareKey,
    out_path: []const u8,
    branches: []const []const u8,
) !void {
    const bytes = try buildBundle(st, alloc, s, branches);
    defer alloc.free(bytes);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = bytes });
}

const RecordMap = std.AutoHashMap([name_raw_len]u8, []const u8);

const BundleSource = struct {
    prk: Prk,
    nk: [32]u8,
    map: *const RecordMap,

    fn fetch(self: BundleSource, alloc: std.mem.Allocator, o: Oid) ![]u8 {
        const record = self.map.get(blindedRaw(self.nk, o)) orelse return Error.BadBundle;
        return openObject(alloc, self.prk, o, record);
    }
};

pub fn importBundle(
    st: *Store,
    alloc: std.mem.Allocator,
    s: ShareKey,
    bytes: []const u8,
) !void {
    if (bytes.len < bundle_magic.len + id_len) return Error.BadBundle;
    if (!std.mem.eql(u8, bytes[0..bundle_magic.len], bundle_magic)) return Error.BadBundle;

    var idbuf: [id_len]u8 = undefined;
    if (!std.mem.eql(u8, bytes[bundle_magic.len..][0..id_len], shareId(s, &idbuf)))
        return Error.BadShare;

    const prk = prkOf(s);
    var map = RecordMap.init(alloc);
    defer map.deinit();

    var pos: usize = bundle_magic.len + id_len;
    var root_record: ?[]const u8 = null;
    while (pos < bytes.len) {
        if (pos + 8 > bytes.len) return Error.BadBundle;
        const len: usize = @intCast(std.mem.readInt(u64, bytes[pos..][0..8], .little));
        pos += 8;
        if (pos + len > bytes.len) return Error.BadBundle;
        const payload = bytes[pos..][0..len];
        pos += len;

        if (root_record == null) {
            root_record = payload;
            continue;
        }
        if (payload.len < name_raw_len) return Error.BadBundle;
        try map.put(payload[0..name_raw_len].*, payload[name_raw_len..]);
    }

    const root = root_record orelse return Error.BadBundle;
    const root_text = try openRecord(alloc, rootKey(prk), root_aad, root);
    defer alloc.free(root_text);
    const refs = try parseRoot(alloc, root_text);
    defer freeRefs(alloc, refs);

    const src = BundleSource{ .prk = prk, .nk = nameKey(prk), .map = &map };
    try importGraph(st, alloc, src, refs);
}

pub fn readBundle(
    st: *Store,
    alloc: std.mem.Allocator,
    io: std.Io,
    s: ShareKey,
    in_path: []const u8,
) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, in_path, alloc, .unlimited);
    defer alloc.free(bytes);
    try importBundle(st, alloc, s, bytes);
}

fn buildRequest(alloc: std.mem.Allocator, host: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: gr-share/1\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        .{ path, host },
    );
}

const Authority = struct {
    host: []const u8,
    port: u16,
    prefix: []const u8,
    tls: bool,
};

fn splitAuthority(base: []const u8) !Authority {
    var tls = false;
    var rest = base;
    if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    } else if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
        tls = true;
    } else return Error.UnsupportedScheme;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const prefix = rest[slash..];
    if (authority.len == 0) return Error.BadUrl;

    var host = authority;
    var port: u16 = if (tls) 443 else 80;
    if (authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return Error.BadUrl;
        host = authority[1..close];
        const tail = authority[close + 1 ..];
        if (tail.len > 1 and tail[0] == ':') {
            port = std.fmt.parseInt(u16, tail[1..], 10) catch return Error.BadUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return Error.BadUrl;
    }
    if (host.len == 0) return Error.BadUrl;
    return .{ .host = host, .port = port, .prefix = prefix, .tls = tls };
}

fn contentLengthOf(line: []const u8) ?usize {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "content-length")) return null;
    return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " \t\r"), 10) catch null;
}

fn plainGet(io: std.Io, alloc: std.mem.Allocator, a: Authority, path: []const u8) ![]u8 {
    var address = net.IpAddress.parse(a.host, a.port) catch
        try net.IpAddress.resolve(io, a.host, a.port);
    const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
    defer stream.close(io);

    const rbuf = try alloc.alloc(u8, 16 * 1024);
    defer alloc.free(rbuf);
    const wbuf = try alloc.alloc(u8, 4096);
    defer alloc.free(wbuf);

    var sr = stream.reader(io, rbuf);
    var sw = stream.writer(io, wbuf);

    const request = try buildRequest(alloc, a.host, path);
    defer alloc.free(request);
    try sw.interface.writeAll(request);
    try sw.interface.flush();

    const r = &sr.interface;
    const status = try r.takeDelimiterInclusive('\n');
    if (std.mem.indexOf(u8, status, " 200") == null) return Error.HttpStatus;

    var length: ?usize = null;
    while (true) {
        const line = try r.takeDelimiterInclusive('\n');
        const trimmed = std.mem.trimEnd(u8, line, "\r\n");
        if (trimmed.len == 0) break;
        if (contentLengthOf(trimmed)) |n| length = n;
    }
    const n = length orelse return Error.HttpProtocol;
    return r.readAlloc(alloc, n);
}

fn tlsGet(io: std.Io, alloc: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = alloc, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(alloc);
    defer body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    });
    if (result.status != .ok) return Error.HttpStatus;
    return body.toOwnedSlice();
}

fn httpGet(io: std.Io, alloc: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    const a = try splitAuthority(base);
    if (a.tls) {
        const url = try std.fmt.allocPrint(alloc, "{s}{s}", .{ base, path[a.prefix.len..] });
        defer alloc.free(url);
        return tlsGet(io, alloc, url);
    }
    return plainGet(io, alloc, a, path);
}

const HttpSource = struct {
    io: std.Io,
    base: []const u8,
    id: []const u8,
    prefix: []const u8,
    prk: Prk,
    nk: [32]u8,

    fn fetch(self: HttpSource, alloc: std.mem.Allocator, o: Oid) ![]u8 {
        var namebuf: [name_len]u8 = undefined;
        const raw_name = blindedRaw(self.nk, o);
        _ = b64.Encoder.encode(&namebuf, &raw_name);

        const path = try std.fmt.allocPrint(
            alloc,
            "{s}{s}{s}/{s}/{s}",
            .{ self.prefix, path_segment, self.id, objects_leaf, namebuf },
        );
        defer alloc.free(path);

        const record = try httpGet(self.io, alloc, self.base, path);
        defer alloc.free(record);
        return openObject(alloc, self.prk, o, record);
    }
};

pub fn fetchHttp(st: *Store, alloc: std.mem.Allocator, io: std.Io, url: []const u8) !void {
    const parsed = try parseUrl(alloc, url);
    defer parsed.deinit(alloc);

    const a = try splitAuthority(parsed.base);
    const prk = prkOf(parsed.key);

    const root_path = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}/{s}",
        .{ a.prefix, path_segment, parsed.id, root_leaf },
    );
    defer alloc.free(root_path);

    const root_record = try httpGet(io, alloc, parsed.base, root_path);
    defer alloc.free(root_record);

    const root_text = try openRecord(alloc, rootKey(prk), root_aad, root_record);
    defer alloc.free(root_text);
    const refs = try parseRoot(alloc, root_text);
    defer freeRefs(alloc, refs);

    const src = HttpSource{
        .io = io,
        .base = parsed.base,
        .id = parsed.id,
        .prefix = a.prefix,
        .prk = prk,
        .nk = nameKey(prk),
    };
    try importGraph(st, alloc, src, refs);
}

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn requestSubPath(target: []const u8, buf: []u8) ![]const u8 {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q];
    if (!std.mem.startsWith(u8, path, path_segment)) return Error.BadPath;

    var it = std.mem.splitScalar(u8, path[path_segment.len..], '/');
    const id = it.next() orelse return Error.BadPath;
    if (id.len != id_len or !isHexLower(id)) return Error.BadPath;

    const leaf = it.next() orelse return Error.BadPath;
    if (std.mem.eql(u8, leaf, root_leaf)) {
        if (it.next() != null) return Error.BadPath;
        return rootSubPath(id, buf);
    }
    if (!std.mem.eql(u8, leaf, objects_leaf)) return Error.BadPath;
    const name = it.next() orelse return Error.BadPath;
    if (it.next() != null) return Error.BadPath;
    if (!safeName(name)) return Error.BadPath;
    return objectSubPath(id, name, buf);
}

fn serveConn(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, stream: net.Stream) void {
    var rbuf: [8192]u8 = undefined;
    var wbuf: [8192]u8 = undefined;
    var sr = stream.reader(io, &rbuf);
    var sw = stream.writer(io, &wbuf);
    const r = &sr.interface;
    const w = &sw.interface;

    const line = r.takeDelimiterInclusive('\n') catch return;
    const request = std.mem.trimEnd(u8, line, "\r\n");
    while (true) {
        const header = r.takeDelimiterInclusive('\n') catch break;
        if (std.mem.trimEnd(u8, header, "\r\n").len == 0) break;
    }

    var it = std.mem.tokenizeAny(u8, request, " ");
    const method = it.next() orelse return;
    const target = it.next() orelse return;
    if (!std.mem.eql(u8, method, "GET")) {
        respondStatus(w, "405 Method Not Allowed");
        return;
    }

    var pathbuf: [96]u8 = undefined;
    const sub = requestSubPath(target, &pathbuf) catch {
        respondStatus(w, "404 Not Found");
        return;
    };
    const body = dir.readFileAlloc(io, sub, alloc, .unlimited) catch {
        respondStatus(w, "404 Not Found");
        return;
    };
    defer alloc.free(body);

    w.print(
        "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n",
        .{body.len},
    ) catch return;
    w.writeAll(body) catch return;
    w.flush() catch return;
}

fn respondStatus(w: *std.Io.Writer, status: []const u8) void {
    w.print("HTTP/1.1 {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{status}) catch return;
    w.flush() catch return;
}

pub fn serveDir(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, port: u16) !void {
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);
    while (true) {
        const stream = try server.accept(io);
        serveConn(io, alloc, dir, stream);
        stream.close(io);
    }
}

// --- tests ---

const testing = std.testing;

fn seedRepo(st: *Store) !Oid {
    const a_blob = try st.writeFileContent("fn main() void {}\n" ** 64);
    const b_blob = try st.writeFileContent("pub const x = 42;\n" ** 64);
    const env_blob = try st.writeFileContent("API_KEY=gr1:AAAA\n");

    var entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = ".env.sealed", .blob = env_blob },
        .{ .mode = .regular, .path = "src/lib.zig", .blob = b_blob },
        .{ .mode = .regular, .path = "src/main.zig", .blob = a_blob },
    };
    std.mem.sort(object.TreeEntry, &entries, {}, object.Tree.lessThan);
    const tree_oid = try st.writeTree(.{ .entries = &entries });

    const first = try st.writeChange(.{
        .tree = tree_oid,
        .parents = &[_]Oid{},
        .change_id = [_]u8{1} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Tester <t@example.com>",
        .message = "seed",
    });
    const second = try st.writeChange(.{
        .tree = tree_oid,
        .parents = &[_]Oid{first},
        .change_id = [_]u8{2} ** 16,
        .timestamp = 1_700_000_100,
        .tz_offset_min = 0,
        .author = "Tester <t@example.com>",
        .message = "second",
    });
    try st.updateRef("main", second);
    return second;
}

test "share id and blinded names are stable and key dependent" {
    const a: ShareKey = [_]u8{7} ** key_len;
    const b: ShareKey = [_]u8{8} ** key_len;

    var buf_a: [id_len]u8 = undefined;
    var buf_b: [id_len]u8 = undefined;
    const id_a = shareId(a, &buf_a);
    const id_b = shareId(b, &buf_b);
    try testing.expectEqual(@as(usize, id_len), id_a.len);
    try testing.expect(isHexLower(id_a));
    try testing.expect(!std.mem.eql(u8, id_a, id_b));

    const o = Oid.ofBytes("an object");
    var n1: [name_len]u8 = undefined;
    var n2: [name_len]u8 = undefined;
    var n3: [name_len]u8 = undefined;
    const name1 = blindedName(a, o, &n1);
    const name2 = blindedName(a, o, &n2);
    const name3 = blindedName(b, o, &n3);
    try testing.expectEqualStrings(name1, name2);
    try testing.expect(!std.mem.eql(u8, name1, name3));

    var hexbuf: [Oid.len * 2]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, name1, o.toHex(&hexbuf)) == null);
}

test "url roundtrip and the key never reaches the wire" {
    const alloc = testing.allocator;
    const s: ShareKey = [_]u8{3} ** key_len;

    const url = try encodeUrl(alloc, "https://share.example.com/", s);
    defer alloc.free(url);
    try testing.expect(std.mem.indexOf(u8, url, "#k=") != null);

    const parsed = try parseUrl(alloc, url);
    defer parsed.deinit(alloc);
    try testing.expectEqualStrings("https://share.example.com", parsed.base);
    try testing.expectEqualSlices(u8, &s, &parsed.key);

    var idbuf: [id_len]u8 = undefined;
    try testing.expectEqualStrings(shareId(s, &idbuf), parsed.id);

    var kbuf: [b64.Encoder.calcSize(key_len)]u8 = undefined;
    _ = b64.Encoder.encode(&kbuf, &s);

    const a = try splitAuthority(parsed.base);
    const path = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}/{s}",
        .{ a.prefix, path_segment, parsed.id, root_leaf },
    );
    defer alloc.free(path);

    const request = try buildRequest(alloc, a.host, path);
    defer alloc.free(request);
    try testing.expect(std.mem.indexOf(u8, request, &kbuf) == null);
    try testing.expect(std.mem.indexOf(u8, request, "#") == null);
    try testing.expect(std.mem.indexOf(u8, request, "k=") == null);

    var name: [name_len]u8 = undefined;
    const obj_path = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}/{s}/{s}",
        .{ a.prefix, path_segment, parsed.id, objects_leaf, blindedName(s, Oid.ofBytes("x"), &name) },
    );
    defer alloc.free(obj_path);
    const obj_request = try buildRequest(alloc, a.host, obj_path);
    defer alloc.free(obj_request);
    try testing.expect(std.mem.indexOf(u8, obj_request, &kbuf) == null);
}

test "malformed urls and mismatched ids are rejected" {
    const alloc = testing.allocator;
    const s: ShareKey = [_]u8{4} ** key_len;

    try testing.expectError(Error.BadUrl, parseUrl(alloc, "https://x/r/abcdabcd"));
    try testing.expectError(Error.BadUrl, parseUrl(alloc, "https://x/r/abcdabcd#nope"));
    try testing.expectError(Error.BadUrl, parseUrl(alloc, "https://x/nope#k=AAA"));

    const url = try encodeUrl(alloc, "https://x", s);
    defer alloc.free(url);
    const tampered = try alloc.dupe(u8, url);
    defer alloc.free(tampered);
    const at = std.mem.lastIndexOf(u8, tampered, path_segment).?;
    tampered[at + path_segment.len] = if (tampered[at + path_segment.len] == 'a') 'b' else 'a';
    try testing.expectError(Error.BadShare, parseUrl(alloc, tampered));
}

test "directory export is deterministic and hides real names" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var out_a = std.testing.tmpDir(.{});
    defer out_a.cleanup();
    var out_b = std.testing.tmpDir(.{});
    defer out_b.cleanup();

    var st = try Store.init(io, alloc, repo.dir);
    defer st.deinit();
    const tip = try seedRepo(&st);

    const s: ShareKey = [_]u8{5} ** key_len;
    try exportDir(&st, alloc, io, s, out_a.dir, &.{"main"});
    try exportDir(&st, alloc, io, s, out_b.dir, &.{"main"});

    var idbuf: [id_len]u8 = undefined;
    const id = shareId(s, &idbuf);

    var pathbuf: [96]u8 = undefined;
    const root_a = try out_a.dir.readFileAlloc(io, rootSubPath(id, &pathbuf), alloc, .unlimited);
    defer alloc.free(root_a);
    const root_b = try out_b.dir.readFileAlloc(io, rootSubPath(id, &pathbuf), alloc, .unlimited);
    defer alloc.free(root_b);
    try testing.expectEqualSlices(u8, root_a, root_b);
    try testing.expect(std.mem.indexOf(u8, root_a, "main") == null);

    var name: [name_len]u8 = undefined;
    const sub = objectSubPath(id, blindedName(s, tip, &name), &pathbuf);
    const rec_a = try out_a.dir.readFileAlloc(io, sub, alloc, .unlimited);
    defer alloc.free(rec_a);
    const rec_b = try out_b.dir.readFileAlloc(io, sub, alloc, .unlimited);
    defer alloc.free(rec_b);
    try testing.expectEqualSlices(u8, rec_a, rec_b);

    const raw = try st.readRaw(tip);
    defer alloc.free(raw);
    try testing.expect(std.mem.indexOf(u8, rec_a, "second") == null);

    const opened = try openObject(alloc, prkOf(s), tip, rec_a);
    defer alloc.free(opened);
    try testing.expectEqualSlices(u8, raw, opened);
}

test "bundle roundtrips into a fresh store" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var clone = std.testing.tmpDir(.{});
    defer clone.cleanup();

    var src = try Store.init(io, alloc, repo.dir);
    defer src.deinit();
    const tip = try seedRepo(&src);

    const s: ShareKey = [_]u8{6} ** key_len;
    const bytes = try buildBundle(&src, alloc, s, &.{"main"});
    defer alloc.free(bytes);
    try testing.expect(std.mem.startsWith(u8, bytes, bundle_magic));

    const again = try buildBundle(&src, alloc, s, &.{"main"});
    defer alloc.free(again);
    try testing.expectEqualSlices(u8, bytes, again);

    var dst = try Store.init(io, alloc, clone.dir);
    defer dst.deinit();
    try importBundle(&dst, alloc, s, bytes);

    try testing.expect((try dst.readRef("main")).eql(tip));

    const change = try dst.readChange(tip);
    defer object.freeChange(alloc, change);
    try testing.expectEqualStrings("second", change.message);

    const tree = try dst.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        const content = try dst.readFileContent(e.blob);
        defer alloc.free(content);
        if (std.mem.eql(u8, e.path, ".env.sealed")) {
            try testing.expect(std.mem.indexOf(u8, content, "gr1:") != null);
        }
    }

    try importBundle(&dst, alloc, s, bytes);
}

test "a wrong key cannot open a bundle" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var clone = std.testing.tmpDir(.{});
    defer clone.cleanup();

    var src = try Store.init(io, alloc, repo.dir);
    defer src.deinit();
    _ = try seedRepo(&src);

    const s: ShareKey = [_]u8{9} ** key_len;
    const other: ShareKey = [_]u8{10} ** key_len;
    const bytes = try buildBundle(&src, alloc, s, &.{"main"});
    defer alloc.free(bytes);

    var dst = try Store.init(io, alloc, clone.dir);
    defer dst.deinit();
    try testing.expectError(Error.BadShare, importBundle(&dst, alloc, other, bytes));

    const forged = try alloc.dupe(u8, bytes);
    defer alloc.free(forged);
    var idbuf: [id_len]u8 = undefined;
    @memcpy(forged[bundle_magic.len..][0..id_len], shareId(other, &idbuf));
    try testing.expectError(Error.BadRecord, importBundle(&dst, alloc, other, forged));
}

test "tampering with a record is detected" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var clone = std.testing.tmpDir(.{});
    defer clone.cleanup();

    var src = try Store.init(io, alloc, repo.dir);
    defer src.deinit();
    _ = try seedRepo(&src);

    const s: ShareKey = [_]u8{11} ** key_len;
    const bytes = try buildBundle(&src, alloc, s, &.{"main"});
    defer alloc.free(bytes);

    const flipped = try alloc.dupe(u8, bytes);
    defer alloc.free(flipped);
    flipped[flipped.len - 1] ^= 0xff;

    var dst = try Store.init(io, alloc, clone.dir);
    defer dst.deinit();
    try testing.expectError(Error.BadRecord, importBundle(&dst, alloc, s, flipped));

    const root_flipped = try alloc.dupe(u8, bytes);
    defer alloc.free(root_flipped);
    root_flipped[bundle_magic.len + id_len + 8] ^= 0x01;
    try testing.expectError(Error.BadRecord, importBundle(&dst, alloc, s, root_flipped));
}

test "a host that swaps object bodies is rejected" {
    const alloc = testing.allocator;
    const s: ShareKey = [_]u8{12} ** key_len;
    const prk = prkOf(s);

    const real = Oid.ofBytes("the real object");
    const record = try sealRecord(alloc, objectKey(prk, real), &real.bytes, "not the real object");
    defer alloc.free(record);
    try testing.expectError(Error.HashMismatch, openObject(alloc, prk, real, record));
}

test "root text roundtrip" {
    const alloc = testing.allocator;
    const refs = [_]Ref{
        .{ .name = @constCast("main"), .target = Oid.ofBytes("a") },
        .{ .name = @constCast("dev"), .target = Oid.ofBytes("b") },
    };
    const text = try renderRoot(alloc, &refs);
    defer alloc.free(text);

    const back = try parseRoot(alloc, text);
    defer freeRefs(alloc, back);
    try testing.expectEqual(@as(usize, 2), back.len);
    try testing.expectEqualStrings("main", back[0].name);
    try testing.expect(back[1].target.eql(Oid.ofBytes("b")));
    try testing.expectError(Error.BadRoot, parseRoot(alloc, "version 1\n"));
}

test "authority parsing" {
    const a = try splitAuthority("http://127.0.0.1:8080");
    try testing.expectEqualStrings("127.0.0.1", a.host);
    try testing.expectEqual(@as(u16, 8080), a.port);
    try testing.expectEqualStrings("", a.prefix);
    try testing.expect(!a.tls);

    const b = try splitAuthority("https://share.example.com/mnt");
    try testing.expectEqualStrings("share.example.com", b.host);
    try testing.expectEqual(@as(u16, 443), b.port);
    try testing.expectEqualStrings("/mnt", b.prefix);
    try testing.expect(b.tls);

    try testing.expectError(Error.UnsupportedScheme, splitAuthority("ftp://x"));
}

test "server path mapping refuses traversal" {
    var buf: [96]u8 = undefined;
    const sub = try requestSubPath("/r/0123abcd/root", &buf);
    try testing.expectEqualStrings("r/0123abcd/root", sub);

    var buf2: [96]u8 = undefined;
    const obj = try requestSubPath("/r/0123abcd/o/AAAA_BBBB?x=1", &buf2);
    try testing.expectEqualStrings("r/0123abcd/o/AAAA_BBBB", obj);

    try testing.expectError(Error.BadPath, requestSubPath("/r/0123abcd/o/..", &buf));
    try testing.expectError(Error.BadPath, requestSubPath("/r/0123abcd/o/a/b", &buf));
    try testing.expectError(Error.BadPath, requestSubPath("/etc/passwd", &buf));
    try testing.expectError(Error.BadPath, requestSubPath("/r/zzzz/root", &buf));
}

fn serveThread(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir, port: u16) void {
    serveDir(io, alloc, dir, port) catch {};
}

test "http share roundtrip over a live socket" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var hosted = std.testing.tmpDir(.{});
    defer hosted.cleanup();
    var clone = std.testing.tmpDir(.{});
    defer clone.cleanup();

    var src = try Store.init(io, alloc, repo.dir);
    defer src.deinit();
    const tip = try seedRepo(&src);

    const s: ShareKey = [_]u8{13} ** key_len;
    try exportDir(&src, alloc, io, s, hosted.dir, &.{"main"});

    const port: u16 = 47833;
    const th = try std.Thread.spawn(.{}, serveThread, .{ io, alloc, hosted.dir, port });
    th.detach();

    const base = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{port});
    defer alloc.free(base);
    const url = try encodeUrl(alloc, base, s);
    defer alloc.free(url);

    var dst = try Store.init(io, alloc, clone.dir);
    defer dst.deinit();

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        if (fetchHttp(&dst, alloc, io, url)) |_| break else |e| {
            if (attempt == 99) return e;
            io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    } else return error.CouldNotConnect;

    try testing.expect((try dst.readRef("main")).eql(tip));
    const change = try dst.readChange(tip);
    defer object.freeChange(alloc, change);
    try testing.expectEqualStrings("second", change.message);
    const tree = try dst.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        const content = try dst.readFileContent(e.blob);
        alloc.free(content);
    }
}
