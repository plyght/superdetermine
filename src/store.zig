const std = @import("std");
const builtin = @import("builtin");
const oid = @import("oid.zig");
const object = @import("object.zig");
const cdc = @import("cdc.zig");
const config = @import("config.zig");
const Oid = oid.Oid;

/// The on-disk content-addressed store, rooted at `.sdt/`.
///
/// Layout:
///   .sdt/objects/aa/bbbb..   loose objects & chunks, sharded by first hex byte.
///                            The file name is the full hex Oid; contents are the
///                            raw object encoding (chunks are stored verbatim).
///   .sdt/refs/heads/<name>   branch pointers (hex change Oid + '\n').
///   .sdt/HEAD                current branch: "ref: refs/heads/<name>\n".
///
/// Objects and chunks share one namespace keyed by BLAKE3(content). Writes are
/// idempotent: storing content that already exists is a no-op, which is the
/// whole point of content addressing (dedup across versions/branches/workspaces).
/// The repository directory name.
pub const dir_name = ".sdt";

pub const chunk_key_file = "chunkkey";

const tmp_prefix = "tmp-";
var tmp_seq: std.atomic.Value(u64) = .init(0);

fn tempName(io: std.Io, buf: []u8) ![]const u8 {
    var rand: [8]u8 = undefined;
    try io.randomSecure(&rand);
    const n = tmp_seq.fetchAdd(1, .monotonic);
    return std.fmt.bufPrint(buf, tmp_prefix ++ "{d}-{d}-{x:0>16}", .{
        std.c.getpid(),
        n,
        std.mem.readInt(u64, &rand, .little),
    }) catch unreachable;
}

/// How hard a write works to still be there after the power goes out.
///
/// A rename is atomic, so a reader never sees half an object — but atomic is
/// not durable. Until the file's bytes and the directory entry naming them have
/// both reached the disk, a crash can take either one, and the object is gone
/// or, worse, present and empty. `strict` pays for the barriers; `fast` trades
/// them for throughput on a machine where losing the last few seconds of
/// captures is acceptable.
pub const Durability = enum { strict, fast };

/// How far down a flush has to push before it returns.
///
/// Darwin's `fsync` only hands the write to the drive and returns; the drive is
/// free to keep it in its own volatile cache, so a power loss can still take it.
/// `F_FULLFSYNC` is the call that asks the drive to empty that cache, and is the
/// only barrier a power loss respects there — at roughly sixty times the cost,
/// measured, because it drains the whole device queue and not just this file.
///
/// That price is also the reason the two levels are worth separating. Draining
/// the device queue drains everything already in it, so an `ordered` flush per
/// object followed by one `full` flush at the moment a name is published makes
/// every object that name reaches durable too, for one barrier instead of one
/// per object. Elsewhere `fsync` is already the full barrier and the two levels
/// are the same call.
pub const Barrier = enum { ordered, full };

/// Push a file's bytes out of the caches `barrier` covers.
pub fn syncFile(io: std.Io, file: std.Io.File, barrier: Barrier) !void {
    if (barrier == .full and builtin.os.tag == .macos) {
        // Refused on some filesystems (network mounts, some VM shares), where
        // the plain fsync below is the best available.
        if (std.c.fcntl(file.handle, std.c.F.FULLFSYNC, @as(c_int, 0)) != -1) return;
    }
    try file.sync(io);
}

pub const Store = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    root: std.Io.Dir, // handle to the `.sdt` directory
    gear: ?cdc.GearTable = null,
    durability: Durability = .strict,

    pub const Error = error{
        NotARepo,
        RepoExists,
        ObjectNotFound,
        RefNotFound,
        InvalidRef,
    };

    /// Create `.sdt/...` under `dir`. Errors `RepoExists` if a repo is already
    /// present.
    pub fn init(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
        if (dir.access(io, dir_name, .{})) |_| return Error.RepoExists else |_| {}
        try dir.createDirPath(io, dir_name ++ "/objects");
        try dir.createDirPath(io, dir_name ++ "/refs/heads");
        try dir.writeFile(io, .{ .sub_path = dir_name ++ "/HEAD", .data = "ref: refs/heads/main\n" });

        const hex = std.fmt.bytesToHex(try cdc.randomKey(io), .lower);
        var line: [cdc.key_len * 2 + 1]u8 = undefined;
        @memcpy(line[0 .. cdc.key_len * 2], &hex);
        line[cdc.key_len * 2] = '\n';
        try dir.writeFile(io, .{ .sub_path = dir_name ++ "/" ++ chunk_key_file, .data = &line });

        return open(io, alloc, dir);
    }

    /// Open an existing `.sdt` repo.
    pub fn open(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
        const root = dir.openDir(io, dir_name, .{}) catch return Error.NotARepo;
        var s: Store = .{ .io = io, .alloc = alloc, .root = root };
        s.gear = loadGear(io, root);
        s.durability = loadDurability(&s, alloc);
        return s;
    }

    fn loadDurability(self: *Store, alloc: std.mem.Allocator) Durability {
        var out: Durability = .strict;
        if (config.get(self, alloc, "store.durability")) |maybe| {
            if (maybe) |v| {
                defer alloc.free(v);
                out = std.meta.stringToEnum(Durability, v) orelse out;
            }
        } else |_| {}
        return out;
    }

    /// Flush the directory entry itself, so a crash cannot lose a name that a
    /// just-completed rename put there.
    fn syncDir(self: *Store, sub_path: []const u8, barrier: Barrier) !void {
        if (self.durability == .fast) return;
        var dir = try self.root.openDir(self.io, sub_path, .{});
        defer dir.close(self.io);
        try syncFile(self.io, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } }, barrier);
    }

    /// Write the staging copy of an atomic write. Under `strict` the bytes are
    /// on the disk before the rename that publishes them, so the name and the
    /// content can never land out of order.
    fn writeStaged(self: *Store, sub_path: []const u8, content: []const u8, barrier: Barrier) !void {
        if (self.durability == .fast) {
            return self.root.writeFile(self.io, .{ .sub_path = sub_path, .data = content });
        }
        var file = try self.root.createFile(self.io, sub_path, .{});
        defer file.close(self.io);
        try file.writePositionalAll(self.io, content, 0);
        try syncFile(self.io, file, barrier);
    }

    fn loadGear(io: std.Io, root: std.Io.Dir) cdc.GearTable {
        var buf: [cdc.key_len * 2 + 16]u8 = undefined;
        const raw = root.readFile(io, chunk_key_file, &buf) catch return cdc.legacy_gear;
        const hex = std.mem.trim(u8, raw, " \t\r\n");
        if (hex.len != cdc.key_len * 2) return cdc.legacy_gear;
        var key: cdc.Key = undefined;
        _ = std.fmt.hexToBytes(&key, hex) catch return cdc.legacy_gear;
        return cdc.gearFromKey(key);
    }

    fn gearTable(self: *Store) *const cdc.GearTable {
        if (self.gear == null) self.gear = loadGear(self.io, self.root);
        return &self.gear.?;
    }

    /// Walk up from `dir` to find the nearest repo (like git's discovery).
    pub fn discover(io: std.Io, alloc: std.mem.Allocator, start: std.Io.Dir) !Store {
        var dir = start;
        var depth: usize = 0;
        while (depth < 64) : (depth += 1) {
            if (dir.access(io, dir_name, .{})) |_| return open(io, alloc, dir) else |_| {}
            const parent = dir.openDir(io, "..", .{}) catch return Error.NotARepo;
            dir = parent;
        }
        return Error.NotARepo;
    }

    pub fn deinit(self: *Store) void {
        self.root.close(self.io);
    }

    // --- raw object/chunk storage ---

    fn objectPath(o: Oid, buf: []u8) []const u8 {
        var hex: [Oid.len * 2]u8 = undefined;
        _ = o.toHex(&hex);
        // objects/aa/<rest>
        return std.fmt.bufPrint(buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] }) catch unreachable;
    }

    pub fn has(self: *Store, o: Oid) bool {
        var buf: [80]u8 = undefined;
        const p = objectPath(o, &buf);
        self.root.access(self.io, p, .{}) catch return false;
        return true;
    }

    /// Store raw content under its BLAKE3 address. Idempotent. Returns the Oid.
    pub fn writeRaw(self: *Store, content: []const u8) !Oid {
        const o = Oid.ofBytes(content);
        if (self.has(o)) return o;
        var buf: [80]u8 = undefined;
        var shardbuf: [32]u8 = undefined;
        var hex: [Oid.len * 2]u8 = undefined;
        _ = o.toHex(&hex);
        const shard = std.fmt.bufPrint(&shardbuf, "objects/{s}", .{hex[0..2]}) catch unreachable;
        try self.root.createDirPath(self.io, shard);

        var namebuf: [64]u8 = undefined;
        const name = try tempName(self.io, &namebuf);
        var tbuf: [96]u8 = undefined;
        const tp = std.fmt.bufPrint(&tbuf, "objects/{s}/{s}", .{ hex[0..2], name }) catch unreachable;

        errdefer self.root.deleteFile(self.io, tp) catch {};
        // Stage beside the destination, then rename: a reader in another
        // process sees the object whole or not at all, never truncated.
        // An object is written far more often than a name is published, and an
        // object nothing names yet is not worth a device-cache flush of its
        // own: the `full` barrier taken when a ref or a log record finally
        // names it covers every object written before it.
        try self.writeStaged(tp, content, .ordered);
        const p = objectPath(o, &buf);
        try self.root.rename(tp, self.root, p, self.io);
        try self.syncDir(shard, .ordered);
        return o;
    }

    /// Read raw content by Oid. Caller frees. Errors `ObjectNotFound`.
    pub fn readRaw(self: *Store, o: Oid) ![]u8 {
        var buf: [80]u8 = undefined;
        const p = objectPath(o, &buf);
        return self.root.readFileAlloc(self.io, p, self.alloc, .unlimited) catch
            return Error.ObjectNotFound;
    }

    // --- typed helpers ---

    /// Chunk `data` with FastCDC, store each chunk, and store a Blob manifest.
    /// Returns the Blob Oid. Unchanged regions of a re-stored file dedup for free.
    pub fn writeFileContent(self: *Store, data: []const u8) !Oid {
        var chunk_oids: std.ArrayList(Oid) = .empty;
        defer chunk_oids.deinit(self.alloc);
        var chunker = cdc.Chunker.initWith(data, .{}, self.gearTable());
        while (chunker.next()) |ch| {
            const co = try self.writeRaw(data[ch.offset..][0..ch.len]);
            try chunk_oids.append(self.alloc, co);
        }
        const blob = object.Blob{ .total_size = data.len, .chunks = chunk_oids.items };
        const enc = try blob.encode(self.alloc);
        defer self.alloc.free(enc);
        return self.writeRaw(enc);
    }

    /// Reassemble a file's bytes from its Blob Oid. Caller frees.
    pub fn readFileContent(self: *Store, blob_oid: Oid) ![]u8 {
        const enc = try self.readRaw(blob_oid);
        defer self.alloc.free(enc);
        const blob = try object.Blob.decode(self.alloc, enc);
        defer self.alloc.free(blob.chunks);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.alloc);
        for (blob.chunks) |co| {
            const chunk = try self.readRaw(co);
            defer self.alloc.free(chunk);
            try out.appendSlice(self.alloc, chunk);
        }
        return out.toOwnedSlice(self.alloc);
    }

    pub fn writeTree(self: *Store, tree: object.Tree) !Oid {
        const enc = try tree.encode(self.alloc);
        defer self.alloc.free(enc);
        return self.writeRaw(enc);
    }

    pub fn readTree(self: *Store, o: Oid) !object.Tree {
        const enc = try self.readRaw(o);
        defer self.alloc.free(enc);
        return object.Tree.decode(self.alloc, enc);
    }

    pub fn writeChange(self: *Store, change: object.Change) !Oid {
        const enc = try change.encode(self.alloc);
        defer self.alloc.free(enc);
        return self.writeRaw(enc);
    }

    pub fn readChange(self: *Store, o: Oid) !object.Change {
        const enc = try self.readRaw(o);
        defer self.alloc.free(enc);
        return object.Change.decode(self.alloc, enc);
    }

    // --- refs & HEAD ---

    pub fn writeFileAtomic(self: *Store, sub_path: []const u8, data: []const u8) !void {
        var namebuf: [64]u8 = undefined;
        const tp = try tempName(self.io, &namebuf);
        errdefer self.root.deleteFile(self.io, tp) catch {};
        try self.writeStaged(tp, data, .full);
        try self.root.rename(tp, self.root, sub_path, self.io);
        // A ref naming objects that did not survive the crash is the one loss
        // nothing can repair, so publishing a name is where the full barrier is
        // spent: it lands the objects and the name that reaches them together.
        try self.syncDir(std.fs.path.dirname(sub_path) orelse ".", .full);
    }

    /// Read the branch name HEAD points at. Caller frees. Errors InvalidRef if
    /// HEAD is detached (not supported yet) or malformed.
    pub fn headBranch(self: *Store) ![]u8 {
        const data = self.root.readFileAlloc(self.io, "HEAD", self.alloc, .unlimited) catch
            return Error.RefNotFound;
        defer self.alloc.free(data);
        const trimmed = std.mem.trimEnd(u8, data, "\n");
        const prefix = "ref: refs/heads/";
        if (!std.mem.startsWith(u8, trimmed, prefix)) return Error.InvalidRef;
        return self.alloc.dupe(u8, trimmed[prefix.len..]);
    }

    pub fn setHeadBranch(self: *Store, name: []const u8) !void {
        var buf: [256]u8 = undefined;
        const data = try std.fmt.bufPrint(&buf, "ref: refs/heads/{s}\n", .{name});
        try self.writeFileAtomic("HEAD", data);
    }

    /// Resolve a branch to its change Oid. Errors RefNotFound if unborn.
    pub fn readRef(self: *Store, name: []const u8) !Oid {
        var buf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "refs/heads/{s}", .{name});
        const data = self.root.readFileAlloc(self.io, p, self.alloc, .unlimited) catch
            return Error.RefNotFound;
        defer self.alloc.free(data);
        const trimmed = std.mem.trimEnd(u8, data, "\n \t");
        return Oid.fromHex(trimmed) catch Error.InvalidRef;
    }

    pub fn updateRef(self: *Store, name: []const u8, o: Oid) !void {
        var pbuf: [256]u8 = undefined;
        const p = try std.fmt.bufPrint(&pbuf, "refs/heads/{s}", .{name});
        var hex: [Oid.len * 2 + 1]u8 = undefined;
        _ = o.toHex(hex[0 .. Oid.len * 2]);
        hex[Oid.len * 2] = '\n';
        try self.writeFileAtomic(p, &hex);
    }

    /// True if the branch exists (has a commit).
    pub fn refExists(self: *Store, name: []const u8) bool {
        var buf: [256]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "refs/heads/{s}", .{name}) catch return false;
        self.root.access(self.io, p, .{}) catch return false;
        return true;
    }
};

// --- tests ---

const testing = std.testing;

fn tmpStore(io: std.Io, alloc: std.mem.Allocator, td: *std.Io.Dir) !Store {
    return Store.init(io, alloc, td.*);
}

test "raw write is content-addressed and idempotent" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = try store.writeRaw("hello");
    const b = try store.writeRaw("hello");
    try testing.expect(a.eql(b));
    try testing.expect(store.has(a));

    const got = try store.readRaw(a);
    defer alloc.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "file content chunk roundtrip + dedup" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const data = try alloc.alloc(u8, 3 * 1024 * 1024);
    defer alloc.free(data);
    var prng = std.Random.DefaultPrng.init(1);
    prng.random().bytes(data);

    const blob = try store.writeFileContent(data);
    const back = try store.readFileContent(blob);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, data, back);

    // Re-store with one byte changed: most chunks already exist (dedup).
    const edited = try alloc.dupe(u8, data);
    defer alloc.free(edited);
    edited[data.len / 2] ^= 0xff;
    const blob2 = try store.writeFileContent(edited);
    try testing.expect(!blob2.eql(blob));
}

fn legacyStore(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
    var s = try Store.init(io, alloc, dir);
    s.deinit();
    try dir.deleteFile(io, dir_name ++ "/" ++ chunk_key_file);
    return Store.open(io, alloc, dir);
}

fn pinnedContent(alloc: std.mem.Allocator, n: usize) ![]u8 {
    const data = try alloc.alloc(u8, n);
    var h = oid.Blake3.init(.{});
    h.update("superdetermine store keyed chunking");
    h.final(data);
    return data;
}

test "a new repo gets a chunk key; a repo without one keeps legacy boundaries" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_keyed = std.testing.tmpDir(.{});
    defer tmp_keyed.cleanup();
    var tmp_legacy = std.testing.tmpDir(.{});
    defer tmp_legacy.cleanup();

    var keyed = try Store.init(io, alloc, tmp_keyed.dir);
    defer keyed.deinit();
    var legacy = try legacyStore(io, alloc, tmp_legacy.dir);
    defer legacy.deinit();

    try testing.expect(!std.mem.eql(u64, &keyed.gear.?, &cdc.legacy_gear));
    try testing.expectEqualSlices(u64, &cdc.legacy_gear, &legacy.gear.?);

    const data = try pinnedContent(alloc, 4 * 1024 * 1024);
    defer alloc.free(data);

    const keyed_blob = try keyed.writeFileContent(data);
    const legacy_blob = try legacy.writeFileContent(data);
    try testing.expect(!keyed_blob.eql(legacy_blob));

    const back = try keyed.readFileContent(keyed_blob);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, data, back);

    var reopened = try Store.open(io, alloc, tmp_keyed.dir);
    defer reopened.deinit();
    try testing.expectEqualSlices(u64, &keyed.gear.?, &reopened.gear.?);
    const again = try reopened.writeFileContent(data);
    try testing.expect(again.eql(keyed_blob));
}

test "objects transfer correctly between repos with different chunk keys" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();

    var src = try Store.init(io, alloc, tmp_a.dir);
    defer src.deinit();
    var dst = try Store.init(io, alloc, tmp_b.dir);
    defer dst.deinit();
    try testing.expect(!std.mem.eql(u64, &src.gear.?, &dst.gear.?));

    const data = try pinnedContent(alloc, 5 * 1024 * 1024);
    defer alloc.free(data);
    const blob_oid = try src.writeFileContent(data);

    const raw = try src.readRaw(blob_oid);
    defer alloc.free(raw);
    _ = try dst.writeRaw(raw);
    const blob = try object.Blob.decode(alloc, raw);
    defer alloc.free(blob.chunks);
    for (blob.chunks) |c| {
        const chunk = try src.readRaw(c);
        defer alloc.free(chunk);
        _ = try dst.writeRaw(chunk);
    }

    const back = try dst.readFileContent(blob_oid);
    defer alloc.free(back);
    try testing.expectEqualSlices(u8, data, back);

    const rechunked = try dst.writeFileContent(data);
    try testing.expect(!rechunked.eql(blob_oid));
}

fn shardEntryCount(io: std.Io, root: std.Io.Dir, shard: []const u8, prefix: ?[]const u8) !usize {
    var dir = try root.openDir(io, shard, .{ .iterate = true });
    defer dir.close(io);
    var n: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (prefix) |pre| {
            if (!std.mem.startsWith(u8, entry.name, pre)) continue;
        }
        n += 1;
    }
    return n;
}

test "a large object lands whole and leaves no temp behind" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const data = try alloc.alloc(u8, 6 * 1024 * 1024 + 12345);
    defer alloc.free(data);
    var prng = std.Random.DefaultPrng.init(99);
    prng.random().bytes(data);

    const o = try store.writeRaw(data);
    try testing.expect(store.has(o));

    const got = try store.readRaw(o);
    defer alloc.free(got);
    try testing.expectEqualSlices(u8, data, got);
    try testing.expect(Oid.ofBytes(got).eql(o));

    var hex: [Oid.len * 2]u8 = undefined;
    _ = o.toHex(&hex);
    var sbuf: [32]u8 = undefined;
    const shard = try std.fmt.bufPrint(&sbuf, "objects/{s}", .{hex[0..2]});
    try testing.expectEqual(@as(usize, 0), try shardEntryCount(io, store.root, shard, tmp_prefix));
    try testing.expectEqual(@as(usize, 1), try shardEntryCount(io, store.root, shard, null));
}

test "a temp name is never mistaken for an object and never collides" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit(alloc);
    }

    var i: usize = 0;
    while (i < 512) : (i += 1) {
        var buf: [64]u8 = undefined;
        const name = try tempName(io, &buf);
        try testing.expect(std.mem.startsWith(u8, name, tmp_prefix));
        try testing.expect(name.len != Oid.len * 2 - 2);
        try testing.expect(std.mem.indexOfNone(u8, name, "0123456789abcdef") != null);
        const owned = try alloc.dupe(u8, name);
        errdefer alloc.free(owned);
        const gop = try seen.getOrPut(alloc, owned);
        try testing.expect(!gop.found_existing);
    }
}

test "writing an existing object skips the temp+rename fast path" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const o = try store.writeRaw("the same content");
    const before = tmp_seq.load(.monotonic);
    const again = try store.writeRaw("the same content");
    try testing.expect(again.eql(o));
    try testing.expectEqual(before, tmp_seq.load(.monotonic));
}

test "a rename onto an unwritable destination leaves no litter" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expectError(error.FileNotFound, store.writeFileAtomic("refs/heads/no/such/dir", "x\n"));
    try testing.expectEqual(@as(usize, 0), try shardEntryCount(io, store.root, ".", tmp_prefix));
}

test "refs and HEAD" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try testing.expectEqualStrings("main", branch);

    try testing.expect(!store.refExists("main"));
    const o = Oid.ofBytes("a change");
    try store.updateRef("main", o);
    try testing.expect(store.refExists("main"));
    const got = try store.readRef("main");
    try testing.expect(got.eql(o));
}

test "an object round-trips under both durability modes" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    for ([_]Durability{ .strict, .fast }) |mode| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();

        var store = try Store.init(io, alloc, tmp.dir);
        defer store.deinit();
        store.durability = mode;

        const small = try store.writeRaw("a short object");
        const data = try alloc.alloc(u8, 1024 * 1024 + 7);
        defer alloc.free(data);
        var prng = std.Random.DefaultPrng.init(7);
        prng.random().bytes(data);
        const big = try store.writeRaw(data);

        const got_small = try store.readRaw(small);
        defer alloc.free(got_small);
        try testing.expectEqualStrings("a short object", got_small);

        const got_big = try store.readRaw(big);
        defer alloc.free(got_big);
        try testing.expectEqualSlices(u8, data, got_big);
        try testing.expect(Oid.ofBytes(got_big).eql(big));

        var hex: [Oid.len * 2]u8 = undefined;
        _ = big.toHex(&hex);
        var sbuf: [32]u8 = undefined;
        const shard = try std.fmt.bufPrint(&sbuf, "objects/{s}", .{hex[0..2]});
        try testing.expectEqual(@as(usize, 0), try shardEntryCount(io, store.root, shard, tmp_prefix));

        const o = Oid.ofBytes("a change");
        try store.updateRef("main", o);
        try testing.expect((try store.readRef("main")).eql(o));
    }
}

test "durability is read from config and defaults to strict" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    try testing.expectEqual(Durability.strict, store.durability);

    try config.set(&store, "store.durability", "fast");
    store.deinit();

    var fast = try Store.open(io, alloc, tmp.dir);
    try testing.expectEqual(Durability.fast, fast.durability);
    try config.set(&fast, "store.durability", "strict");
    fast.deinit();

    var strict = try Store.open(io, alloc, tmp.dir);
    try testing.expectEqual(Durability.strict, strict.durability);
    // A value this version does not know is not a reason to stop being durable.
    try config.set(&strict, "store.durability", "whenever");
    strict.deinit();

    var unknown = try Store.open(io, alloc, tmp.dir);
    defer unknown.deinit();
    try testing.expectEqual(Durability.strict, unknown.durability);
}
