const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const cdc = @import("cdc.zig");
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
/// The repository directory name, and the one this project used to use.
///
/// A repo created today is `.sdt`. A repo created before the rename is `.gr`,
/// and is opened in place: discovery prefers the new name and falls back to the
/// old one, so an existing repository keeps working with no migration step and
/// no flag. There is deliberately no converter, because renaming a directory
/// out from under a user's tooling is a worse trade than reading both names
/// forever.
pub const dir_name = ".sdt";
pub const legacy_dir_name = ".gr";

pub const chunk_key_file = "chunkkey";

pub const Store = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    root: std.Io.Dir, // handle to the `.gr` directory
    gear: ?cdc.GearTable = null,

    pub const Error = error{
        NotARepo,
        RepoExists,
        ObjectNotFound,
        RefNotFound,
        InvalidRef,
    };

    /// Create `.sdt/...` under `dir`. Errors `RepoExists` if a repo of either
    /// name is already present.
    pub fn init(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
        if (dir.access(io, dir_name, .{})) |_| return Error.RepoExists else |_| {}
        if (dir.access(io, legacy_dir_name, .{})) |_| return Error.RepoExists else |_| {}
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

    /// Open an existing repo, preferring `.sdt` and accepting `.gr`.
    pub fn open(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
        const root = dir.openDir(io, dir_name, .{}) catch
            dir.openDir(io, legacy_dir_name, .{}) catch return Error.NotARepo;
        var s: Store = .{ .io = io, .alloc = alloc, .root = root };
        s.gear = loadGear(io, root);
        return s;
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
            if (dir.access(io, legacy_dir_name, .{})) |_| return open(io, alloc, dir) else |_| {}
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
        var hex: [Oid.len * 2]u8 = undefined;
        _ = o.toHex(&hex);
        const shard = std.fmt.bufPrint(&buf, "objects/{s}", .{hex[0..2]}) catch unreachable;
        try self.root.createDirPath(self.io, shard);
        const p = objectPath(o, &buf);
        // Write atomically-ish: content addressing makes concurrent identical
        // writes harmless, so a direct write is acceptable here.
        try self.root.writeFile(self.io, .{ .sub_path = p, .data = content });
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
        try self.root.writeFile(self.io, .{ .sub_path = "HEAD", .data = data });
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
        try self.root.writeFile(self.io, .{ .sub_path = p, .data = &hex });
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
