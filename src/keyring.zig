const std = @import("std");
const seal = @import("seal.zig");
const config = @import("config.zig");
const object = @import("object.zig");
const store_mod = @import("store.zig");
const Store = store_mod.Store;

pub const Error = error{
    NoHome,
    IdentityExists,
    NoIdentity,
    NoManifest,
    ManifestExists,
};

pub fn keysDir(alloc: std.mem.Allocator) !?[]u8 {
    const dir = (try config.globalDir(alloc)) orelse return null;
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/keys", .{dir});
}

pub fn identityPath(alloc: std.mem.Allocator) !?[]u8 {
    const dir = (try keysDir(alloc)) orelse return null;
    defer alloc.free(dir);
    return try std.fmt.allocPrint(alloc, "{s}/default", .{dir});
}

fn parseIdentity(text: []const u8) !seal.Identity {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var it = std.mem.tokenizeAny(u8, line, " \t");
        const kind = it.next() orelse continue;
        if (!std.mem.eql(u8, kind, "secret")) continue;
        const value = it.next() orelse return seal.Error.BadSecretKey;
        return seal.Identity.decodeSecret(value);
    }
    return seal.Error.BadSecretKey;
}

pub fn loadIdentity(io: std.Io, alloc: std.mem.Allocator) !?seal.Identity {
    const path = (try identityPath(alloc)) orelse return null;
    defer alloc.free(path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch return null;
    defer alloc.free(text);
    return try parseIdentity(text);
}

pub fn createIdentity(io: std.Io, alloc: std.mem.Allocator, overwrite: bool) !seal.Identity {
    const dir = (try keysDir(alloc)) orelse return Error.NoHome;
    defer alloc.free(dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/default", .{dir});
    defer alloc.free(path);

    const cwd = std.Io.Dir.cwd();
    if (!overwrite) {
        if (cwd.access(io, path, .{})) |_| return Error.IdentityExists else |_| {}
    }
    cwd.createDirPath(io, dir) catch {};

    const id = seal.Identity.generate(io);
    const secret = try id.encodeSecret(alloc);
    defer alloc.free(secret);
    const public = try id.publicId().encode(alloc);
    defer alloc.free(public);

    const body = try std.fmt.allocPrint(alloc, "secret {s}\npublic {s}\n", .{ secret, public });
    defer alloc.free(body);

    try cwd.writeFile(io, .{
        .sub_path = path,
        .data = body,
        .flags = .{ .permissions = .fromMode(0o600) },
    });
    return id;
}

pub fn migrateSidecar(
    io: std.Io,
    alloc: std.mem.Allocator,
    store: *Store,
    work_dir: std.Io.Dir,
) !bool {
    if (store.root.access(io, seal.meta_name, .{})) |_| return false else |_| {}
    const text = work_dir.readFileAlloc(io, seal.legacy_manifest_name, alloc, .unlimited) catch
        return false;
    defer alloc.free(text);
    var manifest = try seal.Manifest.parse(alloc, text);
    defer manifest.deinit();
    try saveManifest(alloc, store, &manifest);
    work_dir.deleteFile(io, seal.legacy_manifest_name) catch {};
    return true;
}

pub fn loadManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    store: *Store,
    work_dir: std.Io.Dir,
) !?seal.Manifest {
    _ = try migrateSidecar(io, alloc, store, work_dir);
    const text = store.root.readFileAlloc(io, seal.meta_name, alloc, .unlimited) catch
        return null;
    defer alloc.free(text);
    return try seal.Manifest.parse(alloc, text);
}

pub fn saveManifest(
    alloc: std.mem.Allocator,
    store: *Store,
    manifest: *const seal.Manifest,
) !void {
    const text = try manifest.render(alloc);
    defer alloc.free(text);
    try store.writeFileAtomic(seal.meta_name, text);
}

pub fn sealedPathsAt(io: std.Io, alloc: std.mem.Allocator, repository_path: []const u8) ![][]u8 {
    const meta_path = try std.fs.path.join(alloc, &.{ repository_path, store_mod.dir_name, seal.meta_name });
    defer alloc.free(meta_path);
    const text = std.Io.Dir.cwd().readFileAlloc(io, meta_path, alloc, .unlimited) catch
        return try alloc.alloc([]u8, 0);
    defer alloc.free(text);
    var manifest = seal.Manifest.parse(alloc, text) catch return try alloc.alloc([]u8, 0);
    defer manifest.deinit();

    const out = try alloc.alloc([]u8, manifest.files.items.len);
    errdefer alloc.free(out);
    var filled: usize = 0;
    errdefer for (out[0..filled]) |p| alloc.free(p);
    for (manifest.files.items) |f| {
        out[filled] = try alloc.dupe(u8, f.path);
        filled += 1;
    }
    return out;
}

pub fn freePaths(alloc: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| alloc.free(p);
    alloc.free(paths);
}

pub const SealedForm = struct {
    path: []u8,
    text: []u8,
};

pub const Plan = struct {
    alloc: std.mem.Allocator,
    sources: [][]u8,
    sealed: []SealedForm,
    sealed_any: bool,
    have_key: bool,

    pub const none: Plan = .{
        .alloc = undefined,
        .sources = &.{},
        .sealed = &.{},
        .sealed_any = false,
        .have_key = false,
    };

    pub fn deinit(self: *Plan) void {
        if (self.sources.len == 0 and self.sealed.len == 0) return;
        for (self.sources) |p| self.alloc.free(p);
        self.alloc.free(self.sources);
        for (self.sealed) |s| {
            self.alloc.free(s.path);
            self.alloc.free(s.text);
        }
        self.alloc.free(self.sealed);
    }

    pub fn isSource(self: *const Plan, path: []const u8) bool {
        for (self.sources) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn isSealed(self: *const Plan, path: []const u8) bool {
        for (self.sealed) |s| {
            if (std.mem.eql(u8, s.path, path)) return true;
        }
        return false;
    }
};

pub fn repoKey(
    io: std.Io,
    alloc: std.mem.Allocator,
    manifest: *const seal.Manifest,
) !?seal.RepoKey {
    const id = (try loadIdentity(io, alloc)) orelse return null;
    return manifest.unwrapFor(alloc, id) catch |e| switch (e) {
        seal.Error.NotAMember => null,
        else => e,
    };
}

pub fn headSealedForm(store: *Store, path: []const u8) !?[]u8 {
    const alloc = store.alloc;
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return null;
    const change = store.readChange(store.readRef(branch) catch return null) catch return null;
    defer object.freeChange(alloc, change);
    const tree = store.readTree(change.tree) catch return null;
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (e.mode != .sealed) continue;
        if (!std.mem.eql(u8, e.path, path)) continue;
        return try store.readFileContent(e.blob);
    }
    return null;
}

pub fn prepare(store: *Store, work_dir: std.Io.Dir) !Plan {
    const io = store.io;
    const alloc = store.alloc;
    var manifest = (try loadManifest(io, alloc, store, work_dir)) orelse return .none;
    defer manifest.deinit();
    if (manifest.files.items.len == 0) return .none;

    var sources: std.ArrayList([]u8) = .empty;
    errdefer {
        for (sources.items) |p| alloc.free(p);
        sources.deinit(alloc);
    }
    var sealed: std.ArrayList(SealedForm) = .empty;
    errdefer {
        for (sealed.items) |s| {
            alloc.free(s.path);
            alloc.free(s.text);
        }
        sealed.deinit(alloc);
    }

    for (manifest.files.items) |f| {
        try sources.append(alloc, try alloc.dupe(u8, f.path));
    }

    const key = try repoKey(io, alloc, &manifest);
    var sealed_any = false;
    var dropped_body = false;
    for (manifest.files.items) |f| {
        var text: ?[]u8 = null;
        if (key) |k| {
            if (work_dir.readFileAlloc(io, f.path, alloc, .unlimited)) |plain| {
                defer alloc.free(plain);
                text = try seal.sealText(alloc, k, f.path, plain);
                sealed_any = true;
            } else |_| {}
        }
        if (text == null) text = try headSealedForm(store, f.path);
        if (text == null) {
            if (f.body) |b| text = try alloc.dupe(u8, b);
        } else if (f.body != null) {
            dropped_body = true;
        }
        const form = text orelse continue;
        errdefer alloc.free(form);
        const path = try alloc.dupe(u8, f.path);
        errdefer alloc.free(path);
        try sealed.append(alloc, .{ .path = path, .text = form });
    }

    if (dropped_body) {
        for (manifest.files.items) |*f| {
            if (f.body) |b| {
                alloc.free(b);
                f.body = null;
            }
        }
        try saveManifest(alloc, store, &manifest);
    }

    return .{
        .alloc = alloc,
        .sources = try sources.toOwnedSlice(alloc),
        .sealed = try sealed.toOwnedSlice(alloc),
        .sealed_any = sealed_any,
        .have_key = key != null,
    };
}

pub const Unsealed = struct {
    written: usize,
    skipped: usize,
};

pub fn unsealAll(io: std.Io, alloc: std.mem.Allocator, store: *Store, work_dir: std.Io.Dir) !Unsealed {
    var manifest = (try loadManifest(io, alloc, store, work_dir)) orelse return Error.NoManifest;
    defer manifest.deinit();

    const key = (try repoKey(io, alloc, &manifest)) orelse return seal.Error.NotAMember;

    var result: Unsealed = .{ .written = 0, .skipped = 0 };
    for (manifest.files.items) |f| {
        const from_head = try headSealedForm(store, f.path);
        defer if (from_head) |t| alloc.free(t);
        const sealed = from_head orelse f.body orelse {
            result.skipped += 1;
            continue;
        };
        const plain = try seal.unsealText(alloc, key, f.path, sealed);
        defer alloc.free(plain);
        if (std.fs.path.dirnamePosix(f.path)) |d| try work_dir.createDirPath(io, d);
        try work_dir.writeFile(io, .{
            .sub_path = f.path,
            .data = plain,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        result.written += 1;
    }
    return result;
}

pub fn currentKey(store: *Store, work_dir: std.Io.Dir) !?seal.RepoKey {
    var manifest = (try loadManifest(store.io, store.alloc, store, work_dir)) orelse return null;
    defer manifest.deinit();
    return repoKey(store.io, store.alloc, &manifest);
}

fn ensureIgnoreLine(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
    name: []const u8,
    line: []const u8,
) !void {
    const old = work_dir.readFileAlloc(io, name, alloc, .unlimited) catch
        try alloc.dupe(u8, "");
    defer alloc.free(old);

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |raw| {
        if (std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r"), line)) return;
    }

    const sep: []const u8 = if (old.len == 0 or old[old.len - 1] == '\n') "" else "\n";
    const new = try std.fmt.allocPrint(alloc, "{s}{s}{s}\n", .{ old, sep, line });
    defer alloc.free(new);
    try work_dir.writeFile(io, .{ .sub_path = name, .data = new });
}

pub fn protectPath(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
    path: []const u8,
) !void {
    try ensureIgnoreLine(io, alloc, work_dir, ".sdtignore", path);
    if (work_dir.access(io, ".git", .{})) |_| {
        try ensureIgnoreLine(io, alloc, work_dir, ".gitignore", path);
    } else |_| {}
}

// --- tests ---

const testing = std.testing;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    absz: [:0]u8,
    alloc: std.mem.Allocator,

    fn init(io: std.Io, alloc: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
        defer alloc.free(abs);
        const absz = try alloc.dupeZ(u8, abs);
        _ = setenv("XDG_CONFIG_HOME", absz.ptr, 1);
        return .{ .tmp = tmp, .absz = absz, .alloc = alloc };
    }

    fn deinit(self: *Fixture) void {
        _ = unsetenv("XDG_CONFIG_HOME");
        self.alloc.free(self.absz);
        self.tmp.cleanup();
    }
};

fn commitSealed(store: *Store, path: []const u8, sealed_text: []const u8) !void {
    const alloc = store.alloc;
    const blob = try store.writeFileContent(sealed_text);
    const entries = [_]object.TreeEntry{.{ .mode = .sealed, .path = path, .blob = blob }};
    const tree = try store.writeTree(.{ .entries = &entries });
    const change = object.Change{
        .tree = tree,
        .parents = &.{},
        .change_id = [_]u8{1} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Nico <n@x>",
        .message = "sealed",
    };
    const change_oid = try store.writeChange(change);
    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, change_oid);
}

test "identity is created once and reloads" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    const id = try createIdentity(io, alloc, false);
    try testing.expectError(Error.IdentityExists, createIdentity(io, alloc, false));

    const loaded = (try loadIdentity(io, alloc)).?;
    try testing.expectEqualSlices(u8, &id.x_sec, &loaded.x_sec);
    try testing.expectEqualSlices(u8, &id.kem_pub, &loaded.kem_pub);
}

test "prepare seals sources into the plan and unseal reads them back from HEAD" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    const id = try createIdentity(io, alloc, false);

    try fx.tmp.dir.createDirPath(io, "work");
    var work = try fx.tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    const k = seal.newRepoKey(io);
    try manifest.putMember(io, k, "nico", id.publicId());
    try saveManifest(alloc, &store, &manifest);

    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-live-1\n" });

    var plan = try prepare(&store, work);
    defer plan.deinit();
    try testing.expect(plan.have_key);
    try testing.expect(plan.sealed_any);
    try testing.expect(plan.isSource(".env"));
    try testing.expectEqual(@as(usize, 1), plan.sealed.len);
    try testing.expectEqualStrings(".env", plan.sealed[0].path);
    try testing.expect(std.mem.indexOf(u8, plan.sealed[0].text, "sk-live-1") == null);
    try testing.expect(std.mem.indexOf(u8, plan.sealed[0].text, "API_KEY=gr1:") != null);
    try testing.expectError(error.FileNotFound, work.access(io, seal.legacy_manifest_name, .{}));

    try commitSealed(&store, ".env", plan.sealed[0].text);

    try work.deleteFile(io, ".env");
    const out = try unsealAll(io, alloc, &store, work);
    try testing.expectEqual(@as(usize, 1), out.written);
    const back = try work.readFileAlloc(io, ".env", alloc, .unlimited);
    defer alloc.free(back);
    try testing.expectEqualStrings("API_KEY=sk-live-1\n", back);
}

test "prepare carries the HEAD sealed form forward when the key is unavailable" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(io, "work");
    var work = try fx.tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    const stranger = seal.Identity.generate(io);
    const k = seal.newRepoKey(io);
    try manifest.putMember(io, k, "someone", stranger.publicId());
    try saveManifest(alloc, &store, &manifest);

    const sealed = try seal.sealText(alloc, k, ".env", "API_KEY=sk-live-1\n");
    defer alloc.free(sealed);
    try commitSealed(&store, ".env", sealed);
    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=edited-locally\n" });

    var plan = try prepare(&store, work);
    defer plan.deinit();
    try testing.expect(!plan.have_key);
    try testing.expect(!plan.sealed_any);
    try testing.expect(plan.isSource(".env"));
    try testing.expectEqual(@as(usize, 1), plan.sealed.len);
    try testing.expectEqualStrings(sealed, plan.sealed[0].text);
    try testing.expectError(seal.Error.NotAMember, unsealAll(io, alloc, &store, work));
}

test "no manifest means an empty plan" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var plan = try prepare(&store, tmp.dir);
    defer plan.deinit();
    try testing.expect(!plan.isSource(".env"));
    try testing.expectEqual(@as(usize, 0), plan.sealed.len);
}

test "a legacy sidecar migrates into repo metadata and is deleted" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    const id = try createIdentity(io, alloc, false);
    try fx.tmp.dir.createDirPath(io, "work");
    var work = try fx.tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);
    var store = try Store.init(io, alloc, work);
    defer store.deinit();

    const k = seal.newRepoKey(io);
    const sealed = try seal.sealText(alloc, k, ".env", "API_KEY=sk-live-1\n");
    defer alloc.free(sealed);
    var legacy = seal.Manifest.empty(alloc);
    defer legacy.deinit();
    _ = try legacy.addPath(".env");
    try legacy.putMember(io, k, "nico", id.publicId());
    _ = try legacy.setBody(".env", sealed);
    const text = try legacy.render(alloc);
    defer alloc.free(text);
    try work.writeFile(io, .{ .sub_path = seal.legacy_manifest_name, .data = text });

    try testing.expect(try migrateSidecar(io, alloc, &store, work));
    try testing.expect(!try migrateSidecar(io, alloc, &store, work));
    try testing.expectError(error.FileNotFound, work.access(io, seal.legacy_manifest_name, .{}));
    try store.root.access(io, seal.meta_name, .{});

    var plan = try prepare(&store, work);
    defer plan.deinit();
    try testing.expectEqual(@as(usize, 1), plan.sealed.len);
    try testing.expectEqualStrings(sealed, plan.sealed[0].text);

    const out = try unsealAll(io, alloc, &store, work);
    try testing.expectEqual(@as(usize, 1), out.written);
    const back = try work.readFileAlloc(io, ".env", alloc, .unlimited);
    defer alloc.free(back);
    try testing.expectEqualStrings("API_KEY=sk-live-1\n", back);

    var again = try prepare(&store, work);
    defer again.deinit();
    try testing.expect(again.sealed_any);
    var stored = (try loadManifest(io, alloc, &store, work)).?;
    defer stored.deinit();
    try testing.expect(stored.bodyOf(".env") == null);
}

test "sealedPathsAt reads the metadata by repository path" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    const nothing = try sealedPathsAt(io, alloc, abs);
    defer freePaths(alloc, nothing);
    try testing.expectEqual(@as(usize, 0), nothing.len);

    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    _ = try manifest.addPath("config/secrets.env");
    try saveManifest(alloc, &store, &manifest);

    const paths = try sealedPathsAt(io, alloc, abs);
    defer freePaths(alloc, paths);
    try testing.expectEqual(@as(usize, 2), paths.len);
    try testing.expectEqualStrings(".env", paths[0]);
    try testing.expectEqualStrings("config/secrets.env", paths[1]);
}

test "protectPath adds ignore rules and re-running is idempotent" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try protectPath(io, alloc, tmp.dir, ".env");
    try protectPath(io, alloc, tmp.dir, ".env");

    const sdt = try tmp.dir.readFileAlloc(io, ".sdtignore", alloc, .unlimited);
    defer alloc.free(sdt);
    try testing.expectEqualStrings(".env\n", sdt);

    const gi = try tmp.dir.readFileAlloc(io, ".gitignore", alloc, .unlimited);
    defer alloc.free(gi);
    try testing.expectEqualStrings(".env\n", gi);
}
