const std = @import("std");
const seal = @import("seal.zig");
const config = @import("config.zig");

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

pub fn loadManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
) !?seal.Manifest {
    const text = work_dir.readFileAlloc(io, seal.manifest_name, alloc, .unlimited) catch
        return null;
    defer alloc.free(text);
    return try seal.Manifest.parse(alloc, text);
}

pub fn saveManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    work_dir: std.Io.Dir,
    manifest: *const seal.Manifest,
) !void {
    const text = try manifest.render(alloc);
    defer alloc.free(text);
    try work_dir.writeFile(io, .{ .sub_path = seal.manifest_name, .data = text });
}

pub const Plan = struct {
    alloc: std.mem.Allocator,
    sources: [][]u8,
    outputs: [][]u8,
    sealed_any: bool,
    have_key: bool,

    pub const none: Plan = .{
        .alloc = undefined,
        .sources = &.{},
        .outputs = &.{},
        .sealed_any = false,
        .have_key = false,
    };

    pub fn deinit(self: *Plan) void {
        if (self.sources.len == 0 and self.outputs.len == 0) return;
        for (self.sources) |p| self.alloc.free(p);
        self.alloc.free(self.sources);
        for (self.outputs) |p| self.alloc.free(p);
        self.alloc.free(self.outputs);
    }

    pub fn isSource(self: *const Plan, path: []const u8) bool {
        for (self.sources) |p| {
            if (std.mem.eql(u8, p, path)) return true;
        }
        return false;
    }

    pub fn isOutput(self: *const Plan, path: []const u8) bool {
        for (self.outputs) |p| {
            if (std.mem.eql(u8, p, path)) return true;
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

pub fn prepare(io: std.Io, alloc: std.mem.Allocator, work_dir: std.Io.Dir) !Plan {
    var manifest = (try loadManifest(io, alloc, work_dir)) orelse return .none;
    defer manifest.deinit();
    if (manifest.paths.items.len == 0) return .none;

    var sources: std.ArrayList([]u8) = .empty;
    errdefer {
        for (sources.items) |p| alloc.free(p);
        sources.deinit(alloc);
    }
    var outputs: std.ArrayList([]u8) = .empty;
    errdefer {
        for (outputs.items) |p| alloc.free(p);
        outputs.deinit(alloc);
    }

    for (manifest.paths.items) |p| {
        try sources.append(alloc, try alloc.dupe(u8, p));
        try outputs.append(alloc, try seal.sealedPathAlloc(alloc, p));
    }

    const key = try repoKey(io, alloc, &manifest);
    var sealed_any = false;
    if (key) |k| {
        for (manifest.paths.items, outputs.items) |src, dst| {
            const plain = work_dir.readFileAlloc(io, src, alloc, .unlimited) catch continue;
            defer alloc.free(plain);
            const sealed = try seal.sealText(alloc, k, src, plain);
            defer alloc.free(sealed);

            const existing = work_dir.readFileAlloc(io, dst, alloc, .unlimited) catch null;
            defer if (existing) |e| alloc.free(e);
            if (existing) |e| {
                if (std.mem.eql(u8, e, sealed)) continue;
            }
            if (std.fs.path.dirnamePosix(dst)) |d| try work_dir.createDirPath(io, d);
            try work_dir.writeFile(io, .{ .sub_path = dst, .data = sealed });
            sealed_any = true;
        }
    }

    return .{
        .alloc = alloc,
        .sources = try sources.toOwnedSlice(alloc),
        .outputs = try outputs.toOwnedSlice(alloc),
        .sealed_any = sealed_any,
        .have_key = key != null,
    };
}

pub const Unsealed = struct {
    written: usize,
    skipped: usize,
};

pub fn unsealAll(io: std.Io, alloc: std.mem.Allocator, work_dir: std.Io.Dir) !Unsealed {
    var manifest = (try loadManifest(io, alloc, work_dir)) orelse return Error.NoManifest;
    defer manifest.deinit();

    const key = (try repoKey(io, alloc, &manifest)) orelse return seal.Error.NotAMember;

    var result: Unsealed = .{ .written = 0, .skipped = 0 };
    for (manifest.paths.items) |src| {
        const dst = try seal.sealedPathAlloc(alloc, src);
        defer alloc.free(dst);
        const sealed = work_dir.readFileAlloc(io, dst, alloc, .unlimited) catch {
            result.skipped += 1;
            continue;
        };
        defer alloc.free(sealed);
        const plain = try seal.unsealText(alloc, key, src, sealed);
        defer alloc.free(plain);
        if (std.fs.path.dirnamePosix(src)) |d| try work_dir.createDirPath(io, d);
        try work_dir.writeFile(io, .{
            .sub_path = src,
            .data = plain,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
        result.written += 1;
    }
    return result;
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
    const sealed = try seal.sealedPathAlloc(alloc, path);
    defer alloc.free(sealed);
    const negation = try std.fmt.allocPrint(alloc, "!{s}", .{sealed});
    defer alloc.free(negation);

    try ensureIgnoreLine(io, alloc, work_dir, ".grignore", path);
    if (work_dir.access(io, ".git", .{})) |_| {
        try ensureIgnoreLine(io, alloc, work_dir, ".gitignore", path);
        try ensureIgnoreLine(io, alloc, work_dir, ".gitignore", negation);
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

test "prepare seals sources and leaves plaintext out of the plan" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    const id = try createIdentity(io, alloc, false);

    try fx.tmp.dir.createDirPath(io, "work");
    var work = try fx.tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    const k = seal.newRepoKey(io);
    try manifest.putMember(io, k, "nico", id.publicId());
    try saveManifest(io, alloc, work, &manifest);

    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-live-1\n" });

    var plan = try prepare(io, alloc, work);
    defer plan.deinit();
    try testing.expect(plan.have_key);
    try testing.expect(plan.isSource(".env"));
    try testing.expect(plan.isOutput(".env.sealed"));

    const sealed = try work.readFileAlloc(io, ".env.sealed", alloc, .unlimited);
    defer alloc.free(sealed);
    try testing.expect(std.mem.indexOf(u8, sealed, "sk-live-1") == null);
    try testing.expect(std.mem.indexOf(u8, sealed, "API_KEY=gr1:") != null);

    try work.deleteFile(io, ".env");
    const out = try unsealAll(io, alloc, work);
    try testing.expectEqual(@as(usize, 1), out.written);
    const back = try work.readFileAlloc(io, ".env", alloc, .unlimited);
    defer alloc.free(back);
    try testing.expectEqualStrings("API_KEY=sk-live-1\n", back);
}

test "prepare still excludes plaintext when the key is unavailable" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var fx = try Fixture.init(io, alloc);
    defer fx.deinit();

    try fx.tmp.dir.createDirPath(io, "work");
    var work = try fx.tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    const stranger = seal.Identity.generate(io);
    try manifest.putMember(io, seal.newRepoKey(io), "someone", stranger.publicId());
    try saveManifest(io, alloc, work, &manifest);
    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-live-1\n" });

    var plan = try prepare(io, alloc, work);
    defer plan.deinit();
    try testing.expect(!plan.have_key);
    try testing.expect(plan.isSource(".env"));
    try testing.expectError(seal.Error.NotAMember, unsealAll(io, alloc, work));
}

test "no manifest means an empty plan" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var plan = try prepare(io, alloc, tmp.dir);
    defer plan.deinit();
    try testing.expect(!plan.isSource(".env"));
    try testing.expectEqual(@as(usize, 0), plan.outputs.len);
}

test "protectPath adds ignore rules and re-running is idempotent" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try protectPath(io, alloc, tmp.dir, ".env");
    try protectPath(io, alloc, tmp.dir, ".env");

    const gr = try tmp.dir.readFileAlloc(io, ".grignore", alloc, .unlimited);
    defer alloc.free(gr);
    try testing.expectEqualStrings(".env\n", gr);

    const gi = try tmp.dir.readFileAlloc(io, ".gitignore", alloc, .unlimited);
    defer alloc.free(gi);
    try testing.expectEqualStrings(".env\n!.env.sealed\n", gi);
}
