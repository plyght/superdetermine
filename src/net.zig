const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const store = @import("store.zig");
const sync = @import("sync.zig");
const Oid = oid.Oid;
const Store = store.Store;

const net = std.Io.net;

pub const Error = error{
    ObjectMissing,
    ProtocolError,
};

// --- local-store transport (filesystem) ---

/// Open a store rooted directly at a `.sdt` directory path. Caller deinits.
fn openGrDir(io: std.Io, alloc: std.mem.Allocator, gr_dir: []const u8) !Store {
    const root = try std.Io.Dir.cwd().openDir(io, gr_dir, .{});
    return .{ .io = io, .alloc = alloc, .root = root };
}

/// Copy one object's raw bytes from `from` to `to` if not already present.
fn copyObject(from: *Store, to: *Store, o: Oid) !void {
    if (to.has(o)) return;
    const raw = try from.readRaw(o);
    defer from.alloc.free(raw);
    _ = try to.writeRaw(raw);
}

/// Core sparse transfer: copy the change, its root tree, and — for every tree
/// entry whose path begins with `prefix` — the blob plus all of its chunks.
/// The result is a partial tree in `to`: only prefix paths are hydrated.
fn transfer(from: *Store, to: *Store, branch: []const u8, prefix: []const u8) !Oid {
    const change_oid = try from.readRef(branch);

    // change object
    try copyObject(from, to, change_oid);
    const change = try from.readChange(change_oid);
    defer object.freeChange(from.alloc, change);

    // root tree object
    try copyObject(from, to, change.tree);
    const tree = try from.readTree(change.tree);
    defer object.freeTree(from.alloc, tree);

    // blobs + chunks under the prefix
    for (tree.entries) |e| {
        if (!std.mem.startsWith(u8, e.path, prefix)) continue;
        try copyObject(from, to, e.blob);
        const raw = try from.readRaw(e.blob);
        defer from.alloc.free(raw);
        const blob = try object.Blob.decode(from.alloc, raw);
        defer from.alloc.free(blob.chunks);
        for (blob.chunks) |c| try copyObject(from, to, c);
    }

    try to.updateRef(branch, change_oid);
    return change_oid;
}

/// Pull the change + trees + the blobs/chunks under `path_prefix` for `branch`
/// from the source repo at `src_gr_dir` into `dst`. Empty prefix = everything.
/// `dst` ends up with a genuinely partial tree. Returns the change Oid.
pub fn fetchSparse(dst: *Store, src_gr_dir: []const u8, branch: []const u8, path_prefix: []const u8) !Oid {
    var src = try openGrDir(dst.io, dst.alloc, src_gr_dir);
    defer src.deinit();
    return transfer(&src, dst, branch, path_prefix);
}

/// Reverse of `fetchSparse`: push local objects under `path_prefix` up to the
/// store at `dst_gr_dir`. Symmetric. Returns the change Oid.
pub fn pushSparse(src: *Store, dst_gr_dir: []const u8, branch: []const u8, path_prefix: []const u8) !Oid {
    var dst = try openGrDir(src.io, src.alloc, dst_gr_dir);
    defer dst.deinit();
    return transfer(src, &dst, branch, path_prefix);
}

/// Lazy-hydration primitive: copy exactly one object by Oid from the source
/// repo at `src_gr_dir` into `dst`. Call this when a partial checkout needs a
/// missing object. (store.zig / main.zig should call this on ObjectNotFound.)
pub fn fetchObject(dst: *Store, src_gr_dir: []const u8, o: Oid) !void {
    var src = try openGrDir(dst.io, dst.alloc, src_gr_dir);
    defer src.deinit();
    try copyObject(&src, dst, o);
}

// --- TCP transport (best-effort) ---
//
// Line/length-prefixed protocol over one stream:
//   client -> "REF <branch>\n"   server -> 64 hex chars + '\n', or "MISSING\n"
//   client -> "WANT <hex>\n"     server -> u32 big-endian length, then that many
//                                          raw bytes; length == missing_marker
//                                          means the object is absent.
// A single connection is reused for a whole sparse fetch.

const missing_marker: u32 = 0xFFFF_FFFF;
const line_buf_len = 256;

fn writeAllFlush(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeAll(bytes);
    try w.flush();
}

/// Read one '\n'-terminated line, consuming the delimiter; returns the line
/// without it (a view into the reader buffer, valid until the next read).
fn readLine(r: *std.Io.Reader) ![]const u8 {
    const line = try r.takeDelimiterInclusive('\n');
    return line[0 .. line.len - 1];
}

fn serveConn(st: *Store, stream: net.Stream) void {
    var rbuf: [line_buf_len]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var sr = stream.reader(st.io, &rbuf);
    var sw = stream.writer(st.io, &wbuf);
    const r = &sr.interface;
    const w = &sw.interface;

    while (true) {
        const line = readLine(r) catch return;
        if (std.mem.eql(u8, line, "REFS")) {
            const refs = sync.localRefs(st, st.alloc) catch {
                writeAllFlush(w, "\n") catch return;
                continue;
            };
            defer sync.freeRefs(st.alloc, refs);
            for (refs) |advert| {
                var hex: [Oid.len * 2]u8 = undefined;
                w.print("{s} {s}\n", .{ advert.name, advert.tip.toHex(&hex) }) catch return;
            }
            writeAllFlush(w, "\n") catch return;
        } else if (std.mem.eql(u8, line, "HEAD")) {
            const branch = st.headBranch() catch {
                writeAllFlush(w, "MISSING\n") catch return;
                continue;
            };
            defer st.alloc.free(branch);
            w.writeAll(branch) catch return;
            writeAllFlush(w, "\n") catch return;
        } else if (std.mem.startsWith(u8, line, "HAVE ")) {
            const o = Oid.fromHex(line[5..]) catch {
                writeAllFlush(w, "NO\n") catch return;
                continue;
            };
            writeAllFlush(w, if (st.has(o)) "YES\n" else "NO\n") catch return;
        } else if (std.mem.startsWith(u8, line, "REF ")) {
            const branch = line[4..];
            const o = st.readRef(branch) catch {
                writeAllFlush(w, "MISSING\n") catch return;
                continue;
            };
            var hex: [Oid.len * 2 + 1]u8 = undefined;
            _ = o.toHex(hex[0 .. Oid.len * 2]);
            hex[Oid.len * 2] = '\n';
            writeAllFlush(w, &hex) catch return;
        } else if (std.mem.startsWith(u8, line, "WANT ")) {
            const o = Oid.fromHex(line[5..]) catch {
                sendMissing(w) catch return;
                continue;
            };
            const raw = st.readRawLocal(o) catch {
                sendMissing(w) catch return;
                continue;
            };
            defer st.alloc.free(raw);
            var lenbuf: [4]u8 = undefined;
            std.mem.writeInt(u32, &lenbuf, @intCast(raw.len), .big);
            w.writeAll(&lenbuf) catch return;
            w.writeAll(raw) catch return;
            w.flush() catch return;
        } else {
            return;
        }
    }
}

fn sendMissing(w: *std.Io.Writer) !void {
    var lenbuf: [4]u8 = undefined;
    std.mem.writeInt(u32, &lenbuf, missing_marker, .big);
    try writeAllFlush(w, &lenbuf);
}

/// Tiny TCP object server. Serves objects/refs from `store` forever.
pub fn serve(st: *Store, port: u16) !void {
    var address: net.IpAddress = .{ .ip4 = net.Ip4Address.loopback(port) };
    var server = try address.listen(st.io, .{ .reuse_address = true });
    defer server.deinit(st.io);
    while (true) {
        const stream = try server.accept(st.io);
        serveConn(st, stream);
        stream.close(st.io);
    }
}

const Conn = struct {
    stream: net.Stream,
    io: std.Io,
    sr: net.Stream.Reader,
    sw: net.Stream.Writer,
    rbuf: [4096]u8 = undefined,
    wbuf: [line_buf_len]u8 = undefined,

    alloc: std.mem.Allocator,

    /// Connects to `host:port`. Heap-allocated so the stream reader/writer can
    /// reference the Conn's own buffers at a stable address. Caller `destroy`s.
    fn openHost(io: std.Io, alloc: std.mem.Allocator, host: []const u8, port: u16) !*Conn {
        var address = net.IpAddress.parse(host, port) catch
            try net.IpAddress.resolve(io, host, port);
        const stream = try address.connect(io, .{ .mode = .stream, .protocol = .tcp });
        const c = try alloc.create(Conn);
        c.* = .{ .stream = stream, .io = io, .alloc = alloc, .sr = undefined, .sw = undefined };
        c.sr = stream.reader(io, &c.rbuf);
        c.sw = stream.writer(io, &c.wbuf);
        return c;
    }

    fn destroy(c: *Conn) void {
        c.stream.close(c.io);
        c.alloc.destroy(c);
    }

    fn reader(c: *Conn) *std.Io.Reader {
        return &c.sr.interface;
    }
    fn writer(c: *Conn) *std.Io.Writer {
        return &c.sw.interface;
    }

    /// Request one object; returns raw bytes owned by `alloc`, or ObjectMissing.
    fn want(c: *Conn, alloc: std.mem.Allocator, o: Oid) ![]u8 {
        var hex: [Oid.len * 2]u8 = undefined;
        try c.writer().print("WANT {s}\n", .{o.toHex(&hex)});
        try c.writer().flush();
        const len = try c.reader().takeInt(u32, .big);
        if (len == missing_marker) return Error.ObjectMissing;
        return c.reader().readAlloc(alloc, len);
    }

    fn ref(c: *Conn, branch: []const u8) !Oid {
        try c.writer().print("REF {s}\n", .{branch});
        try c.writer().flush();
        const line = try readLine(c.reader());
        if (std.mem.eql(u8, line, "MISSING")) return Error.ObjectMissing;
        return Oid.fromHex(line) catch Error.ProtocolError;
    }

    fn head(c: *Conn, alloc: std.mem.Allocator) ![]u8 {
        try c.writer().writeAll("HEAD\n");
        try c.writer().flush();
        const line = try readLine(c.reader());
        if (std.mem.eql(u8, line, "MISSING") or line.len == 0) return Error.ObjectMissing;
        return alloc.dupe(u8, line);
    }

    fn refs(c: *Conn, alloc: std.mem.Allocator) ![]RefTip {
        try c.writer().writeAll("REFS\n");
        try c.writer().flush();
        var out: std.ArrayList(RefTip) = .empty;
        errdefer freeRefTips(alloc, out.items);
        errdefer out.deinit(alloc);
        while (true) {
            const line = try readLine(c.reader());
            if (line.len == 0) break;
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return Error.ProtocolError;
            const tip = Oid.fromHex(line[sp + 1 ..]) catch return Error.ProtocolError;
            const name = try alloc.dupe(u8, line[0..sp]);
            errdefer alloc.free(name);
            try out.append(alloc, .{ .name = name, .tip = tip });
        }
        return out.toOwnedSlice(alloc);
    }

    fn have(c: *Conn, o: Oid) !bool {
        var hex: [Oid.len * 2]u8 = undefined;
        try c.writer().print("HAVE {s}\n", .{o.toHex(&hex)});
        try c.writer().flush();
        const line = try readLine(c.reader());
        return std.mem.eql(u8, line, "YES");
    }
};

pub const Filled = struct {
    objects: usize = 0,
    bytes: u64 = 0,
};

pub const RefTip = struct {
    name: []u8,
    tip: Oid,
};

pub fn freeRefTips(alloc: std.mem.Allocator, refs: []const RefTip) void {
    for (refs) |r| alloc.free(r.name);
}

fn wantInto(c: *Conn, dst: *Store, o: Oid, filled: *Filled) !void {
    if (dst.has(o)) return;
    const raw = c.want(dst.alloc, o) catch |e| switch (e) {
        Error.ObjectMissing => return,
        else => return e,
    };
    defer dst.alloc.free(raw);
    if (!Oid.ofBytes(raw).eql(o)) return Error.ProtocolError;
    _ = try dst.writeRaw(raw);
    filled.objects += 1;
    filled.bytes += raw.len;
}

pub fn fetchObjectsTcp(dst: *Store, host: []const u8, port: u16, ids: []const Oid) !Filled {
    const c = try Conn.openHost(dst.io, dst.alloc, host, port);
    defer c.destroy();
    var filled: Filled = .{};
    for (ids) |o| try wantInto(c, dst, o, &filled);
    return filled;
}

pub fn haveTcp(io: std.Io, alloc: std.mem.Allocator, host: []const u8, port: u16, ids: []const Oid) ![]bool {
    const out = try alloc.alloc(bool, ids.len);
    errdefer alloc.free(out);
    @memset(out, false);
    const c = try Conn.openHost(io, alloc, host, port);
    defer c.destroy();
    for (ids, out) |o, *h| h.* = c.have(o) catch return out;
    return out;
}

pub fn headTcp(io: std.Io, alloc: std.mem.Allocator, host: []const u8, port: u16) !?[]u8 {
    const c = try Conn.openHost(io, alloc, host, port);
    defer c.destroy();
    return c.head(alloc) catch null;
}

pub fn fetchThinTcp(dst: *Store, host: []const u8, port: u16, branch: []const u8) !Oid {
    const c = try Conn.openHost(dst.io, dst.alloc, host, port);
    defer c.destroy();
    const alloc = dst.alloc;
    var filled: Filled = .{};

    const tip = try c.ref(branch);
    var seen = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer seen.deinit();
    var stack: std.ArrayList(Oid) = .empty;
    defer stack.deinit(alloc);
    try stack.append(alloc, tip);

    const others = c.refs(alloc) catch try alloc.alloc(RefTip, 0);
    defer {
        freeRefTips(alloc, others);
        alloc.free(others);
    }
    for (others) |r| {
        if (std.mem.eql(u8, r.name, branch)) continue;
        try stack.append(alloc, r.tip);
    }

    var head_tree: ?Oid = null;
    while (stack.pop()) |o| {
        if (o.isZero()) continue;
        if ((try seen.getOrPut(o.bytes)).found_existing) continue;
        try wantInto(c, dst, o, &filled);
        const change = dst.readChange(o) catch continue;
        defer object.freeChange(alloc, change);
        for (change.parents) |p| try stack.append(alloc, p);
        if (head_tree == null and o.eql(tip)) head_tree = change.tree;
        if ((try seen.getOrPut(change.tree.bytes)).found_existing) continue;
        try wantInto(c, dst, change.tree, &filled);
        const tree = dst.readTree(change.tree) catch continue;
        defer object.freeTree(alloc, tree);
        for (tree.entries) |e| {
            if ((try seen.getOrPut(e.blob.bytes)).found_existing) continue;
            try wantInto(c, dst, e.blob, &filled);
        }
    }

    if (head_tree) |t| {
        const tree = try dst.readTree(t);
        defer object.freeTree(alloc, tree);
        for (tree.entries) |e| {
            const raw = dst.readRawLocal(e.blob) catch continue;
            defer alloc.free(raw);
            const blob = object.Blob.decode(alloc, raw) catch continue;
            defer alloc.free(blob.chunks);
            for (blob.chunks) |ch| try wantInto(c, dst, ch, &filled);
        }
    }

    for (others) |r| {
        if (dst.has(r.tip)) try dst.updateRef(r.name, r.tip);
    }
    try dst.updateRef(branch, tip);
    return tip;
}

fn storeWant(c: *Conn, dst: *Store, o: Oid) !void {
    if (dst.has(o)) return;
    const raw = try c.want(dst.alloc, o);
    defer dst.alloc.free(raw);
    _ = try dst.writeRaw(raw);
}

/// TCP counterpart of `fetchObject`: pull a single object over the socket.
pub fn fetchObjectTcp(dst: *Store, host: []const u8, port: u16, o: Oid) !void {
    const c = try Conn.openHost(dst.io, dst.alloc, host, port);
    defer c.destroy();
    try storeWant(c, dst, o);
}

/// TCP counterpart of `fetchSparse`: sparse pull over the socket. Returns the
/// change Oid; leaves `dst` with a partial (prefix-only) tree.
pub fn fetchSparseTcp(dst: *Store, host: []const u8, port: u16, branch: []const u8, path_prefix: []const u8) !Oid {
    const c = try Conn.openHost(dst.io, dst.alloc, host, port);
    defer c.destroy();

    const change_oid = try c.ref(branch);
    try storeWant(c, dst, change_oid);

    const change_raw = try dst.readRaw(change_oid);
    defer dst.alloc.free(change_raw);
    const change = try object.Change.decode(dst.alloc, change_raw);
    defer object.freeChange(dst.alloc, change);

    try storeWant(c, dst, change.tree);
    const tree_raw = try dst.readRaw(change.tree);
    defer dst.alloc.free(tree_raw);
    const tree = try object.Tree.decode(dst.alloc, tree_raw);
    defer object.freeTree(dst.alloc, tree);

    for (tree.entries) |e| {
        if (!std.mem.startsWith(u8, e.path, path_prefix)) continue;
        try storeWant(c, dst, e.blob);
        const blob_raw = try dst.readRaw(e.blob);
        defer dst.alloc.free(blob_raw);
        const blob = try object.Blob.decode(dst.alloc, blob_raw);
        defer dst.alloc.free(blob.chunks);
        for (blob.chunks) |ch| try storeWant(c, dst, ch);
    }

    try dst.updateRef(branch, change_oid);
    return change_oid;
}

// --- tests ---

const testing = std.testing;

const Fixture = struct {
    docs_blob: Oid,
    src_chunk: Oid,
    docs_chunk: Oid,
    change_oid: Oid,
};

/// Build a source repo with files under docs/ and src/, a tree, a change, and
/// a "main" ref. Returns Oids useful for sparse assertions.
fn buildSource(st: *Store) !Fixture {
    const alloc = st.alloc;

    const src_a = "fn main() void {}\n" ** 64;
    const src_b = "pub const x = 42;\n" ** 64;
    const docs_a = "# superdetermine docs\n" ** 64;

    const src_a_blob = try st.writeFileContent(src_a);
    const src_b_blob = try st.writeFileContent(src_b);
    const docs_blob = try st.writeFileContent(docs_a);

    var entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "docs/intro.md", .blob = docs_blob },
        .{ .mode = .regular, .path = "src/lib.zig", .blob = src_b_blob },
        .{ .mode = .regular, .path = "src/main.zig", .blob = src_a_blob },
    };
    std.mem.sort(object.TreeEntry, &entries, {}, object.Tree.lessThan);
    const tree_oid = try st.writeTree(.{ .entries = &entries });

    const change = object.Change{
        .tree = tree_oid,
        .parents = &[_]Oid{},
        .change_id = [_]u8{1} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Tester <t@example.com>",
        .message = "seed",
    };
    const change_oid = try st.writeChange(change);
    try st.updateRef("main", change_oid);

    // grab a representative chunk oid from a src blob and a docs blob
    const src_raw = try st.readRaw(src_a_blob);
    defer alloc.free(src_raw);
    const src_blob = try object.Blob.decode(alloc, src_raw);
    defer alloc.free(src_blob.chunks);

    const docs_raw = try st.readRaw(docs_blob);
    defer alloc.free(docs_raw);
    const docs_blob_dec = try object.Blob.decode(alloc, docs_raw);
    defer alloc.free(docs_blob_dec.chunks);

    return .{
        .docs_blob = docs_blob,
        .src_chunk = src_blob.chunks[0],
        .docs_chunk = docs_blob_dec.chunks[0],
        .change_oid = change_oid,
    };
}

fn grDirPath(alloc: std.mem.Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, store.dir_name, alloc);
}

test "fetchSparse pulls only the prefix subtree" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const fx = try buildSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();

    const src_gr = try grDirPath(alloc, &tmp_a);
    defer alloc.free(src_gr);

    const got = try fetchSparse(&dst, src_gr, "main", "src/");
    try testing.expect(got.eql(fx.change_oid));

    // change + root tree copied
    try testing.expect(dst.has(fx.change_oid));
    const dst_change = try dst.readChange(fx.change_oid);
    defer object.freeChange(alloc, dst_change);
    try testing.expect(dst.has(dst_change.tree));

    // ref updated in dst
    const dst_ref = try dst.readRef("main");
    try testing.expect(dst_ref.eql(fx.change_oid));

    // src/ files are fully hydrated: readFileContent works
    const tree = try dst.readTree(dst_change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (!std.mem.startsWith(u8, e.path, "src/")) continue;
        const content = try dst.readFileContent(e.blob);
        alloc.free(content);
    }

    // a src chunk is present; a docs chunk is genuinely MISSING → sparse
    try testing.expect(dst.has(fx.src_chunk));
    try testing.expect(!dst.has(fx.docs_chunk));
    try testing.expect(!dst.has(fx.docs_blob));
}

test "fetchObject copies a single object" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const fx = try buildSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();

    const src_gr = try grDirPath(alloc, &tmp_a);
    defer alloc.free(src_gr);

    try testing.expect(!dst.has(fx.docs_blob));
    try fetchObject(&dst, src_gr, fx.docs_blob);
    try testing.expect(dst.has(fx.docs_blob));

    // idempotent
    try fetchObject(&dst, src_gr, fx.docs_blob);
    try testing.expect(dst.has(fx.docs_blob));
}

test "pushSparse is the symmetric reverse" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const fx = try buildSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();

    const dst_gr = try grDirPath(alloc, &tmp_b);
    defer alloc.free(dst_gr);

    const got = try pushSparse(&src, dst_gr, "main", "docs/");
    try testing.expect(got.eql(fx.change_oid));
    try testing.expect(dst.has(fx.change_oid));
    try testing.expect(dst.has(fx.docs_chunk));
    try testing.expect(!dst.has(fx.src_chunk));
}

test "reference tcp transport symbols" {
    // Type-check the TCP transport without opening sockets.
    _ = &serve;
    _ = &fetchObjectTcp;
    _ = &fetchSparseTcp;
}

fn tcpServerThread(st: *Store, port: u16) void {
    serve(st, port) catch {};
}

test "TCP sparse roundtrip (live socket)" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    const fx = try buildSource(&src);

    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();

    const port: u16 = 47821;
    const th = try std.Thread.spawn(.{}, tcpServerThread, .{ &src, port });
    th.detach();

    var attempt: usize = 0;
    const got = while (attempt < 100) : (attempt += 1) {
        if (fetchSparseTcp(&dst, "127.0.0.1", port, "main", "src/")) |g| break g else |e| {
            if (attempt == 99) return e;
            io.sleep(std.Io.Duration.fromMilliseconds(5), .awake) catch {};
        }
    } else return error.CouldNotConnect;

    try testing.expect(got.eql(fx.change_oid));
    try testing.expect(dst.has(fx.change_oid));
    try testing.expect(dst.has(fx.src_chunk));
    try testing.expect(!dst.has(fx.docs_chunk));
}
