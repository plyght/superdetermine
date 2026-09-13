const std = @import("std");
const apricot = @import("apricot");
const proc = @import("proc.zig");
const net = @import("net.zig");
const oid = @import("oid.zig");
const store = @import("store.zig");
const keyring = @import("keyring.zig");

pub const Published = apricot.git_forge.Published;
pub const Fetched = apricot.git_forge.Fetched;
pub const Collaboration = apricot.collaboration;
pub const ForgeDrivers = apricot.forge_drivers;
pub const Oid = oid.Oid;
pub const Store = store.Store;

pub fn signature(author: []const u8) apricot.git_forge.Signature {
    const value = std.mem.trim(u8, author, " \t");
    if (std.mem.lastIndexOfScalar(u8, value, '<')) |left| {
        if (std.mem.lastIndexOfScalar(u8, value, '>')) |right| {
            if (right == value.len - 1 and right > left + 1) {
                const name = std.mem.trim(u8, value[0..left], " \t");
                return .{
                    .name = if (name.len == 0) "superdetermine" else name,
                    .email = value[left + 1 .. right],
                };
            }
        }
    }
    return .{
        .name = if (value.len == 0) "superdetermine" else value,
        .email = "none@superdetermine",
    };
}

/// What the server said about the last failed request, for the message the user
/// actually reads. Same shape as `git.lastError()`: the CLI is one request at a
/// time, so the detail belongs beside the error rather than threaded through
/// every signature.
var last_failure: apricot.git_transport.Failure = .{};

pub fn lastStatus() u16 {
    return last_failure.status;
}

pub fn lastDetail() []const u8 {
    return last_failure.detail();
}

/// Credentials never travel over cleartext.
///
/// A token in a `Basic` header on `http://` is a token handed to anybody on the
/// path. git refuses this by default too; a plain-HTTP remote is still usable,
/// it just goes unauthenticated and gets an honest 401 rather than a leak.
fn allowsCredentials(remote: []const u8) bool {
    return !std.ascii.startsWithIgnoreCase(remote, "http://");
}

const Authentication = enum { anonymous, configured };

const Session = struct {
    allocator: std.mem.Allocator,
    client: apricot.git_http.Client,
    owned_token: ?[]u8,
    helper: ?proc.Cred,

    fn init(allocator: std.mem.Allocator, io: std.Io, remote: []const u8, authentication: Authentication) Session {
        var owned_token: ?[]u8 = null;
        var helper: ?proc.Cred = null;
        const credentials: ?apricot.http_client.Credentials = if (authentication == .anonymous or !allowsCredentials(remote))
            null
        else if (proc.envToken()) |token| .{
            .username = "apricot",
            .password = std.mem.span(token),
        } else if (proc.githubAuthToken(allocator, remote)) |token| blk: {
            owned_token = token;
            break :blk .{ .username = "x-access-token", .password = token };
        } else if (proc.credentialFill(remote)) |cred| blk: {
            // Whatever git already knows: the keychain, a helper, a .netrc. Not
            // reaching for this is why every forge that is not GitHub answered
            // a perfectly good push with 401.
            helper = cred;
            break :blk .{ .username = cred.user, .password = cred.pass };
        } else null;
        last_failure = .{};
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator, .io = io, .credentials = credentials },
            .owned_token = owned_token,
            .helper = helper,
        };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
        if (self.owned_token) |token| {
            @memset(token, 0);
            self.allocator.free(token);
        }
        if (self.helper) |cred| {
            @memset(cred.pass, 0);
            cred.free();
        }
    }

    fn smart(self: *Session, allocator: std.mem.Allocator, remote: []const u8) apricot.git_transport.SmartHttp {
        return .{
            .allocator = allocator,
            .http = self.client.http(),
            .base_url = remote,
            .failure = &last_failure,
        };
    }
};

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote: []const u8,
    branch: []const u8,
    repository_path: []const u8,
    projection_message: []const u8,
    commit_signature: apricot.git_forge.Signature,
    timestamp: i64,
) !Published {
    var captured = try apricot.sdt_codec.capture(allocator, io, repository_path, remote);
    defer captured.deinit(allocator);
    const projection = try projectionWithoutSealed(allocator, io, repository_path, captured.projection);
    defer allocator.free(projection);
    var session = Session.init(allocator, io, remote, .configured);
    defer session.deinit();
    const published = try apricot.git_forge.publish(
        allocator,
        session.smart(allocator, remote),
        branch,
        captured.encoded.bytes,
        captured.encoded.root,
        projection,
        projection_message,
        commit_signature,
        timestamp,
    );
    holdCarrierAt(io, repository_path, allocator, remote, branch, captured.encoded.bytes) catch {};
    return published;
}

fn projectionWithoutSealed(
    allocator: std.mem.Allocator,
    io: std.Io,
    repository_path: []const u8,
    entries: []const apricot.git_forge.ProjectionEntry,
) ![]apricot.git_forge.ProjectionEntry {
    const sealed = try keyring.sealedPathsAt(io, allocator, repository_path);
    defer keyring.freePaths(allocator, sealed);
    var kept: std.ArrayList(apricot.git_forge.ProjectionEntry) = .empty;
    errdefer kept.deinit(allocator);
    for (entries) |entry| {
        var omit = false;
        for (sealed) |path| {
            if (std.mem.eql(u8, path, entry.path)) omit = true;
        }
        if (!omit) try kept.append(allocator, entry);
    }
    return kept.toOwnedSlice(allocator);
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, remote: []const u8, branch: []const u8) !Fetched {
    var session = Session.init(allocator, io, remote, .configured);
    defer session.deinit();
    return apricot.git_forge.fetch(allocator, session.smart(allocator, remote), branch);
}

fn fetchDefaultWithSession(allocator: std.mem.Allocator, remote: []const u8, session: *Session) !Fetched {
    const branch = try apricot.git_forge.defaultBranch(allocator, session.smart(allocator, remote));
    defer allocator.free(branch);
    return apricot.git_forge.fetch(allocator, session.smart(allocator, remote), branch);
}

pub fn fetchDefault(allocator: std.mem.Allocator, io: std.Io, remote: []const u8) !Fetched {
    // A clone of a public repository must not consult a credential helper or
    // attach stale credentials. GitHub rejects an otherwise public request
    // when it carries invalid Basic authentication. Probe anonymously first;
    // private repositories get one configured-credential retry after an auth
    // challenge or the concealed 404 that GitHub uses for private repositories.
    var anonymous = Session.init(allocator, io, remote, .anonymous);
    defer anonymous.deinit();
    return fetchDefaultWithSession(allocator, remote, &anonymous) catch |err| {
        // GitHub conceals private repositories as 404, so a configured retry is
        // also required for RepositoryNotFound. A real missing repository costs
        // one credential lookup because those cases are indistinguishable.
        if (err != error.AuthenticationRequired and err != error.RepositoryNotFound) return err;
        var authenticated = Session.init(allocator, io, remote, .configured);
        defer authenticated.deinit();
        return fetchDefaultWithSession(allocator, remote, &authenticated);
    };
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination: []const u8,
    fetched: Fetched,
) !void {
    try apricot.sdt_codec.restore(allocator, io, destination, fetched.carrier_bytes, fetched.carrier_root);
}

const fetched_file = "apricot-fetched";
const carrier_prefix = "apricot-carrier-";

const GitOid = apricot.git_transport.Oid;

const Remembered = struct {
    carrier: GitOid,
    tip: Oid,
};

fn fetchedKey(remote: []const u8, branch: []const u8) [64]u8 {
    var h = std.crypto.hash.Blake3.init(.{});
    h.update(remote);
    h.update(&[_]u8{0});
    h.update(branch);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn carrierFileName(buf: *[carrier_prefix.len + 64]u8, key: *const [64]u8) []const u8 {
    @memcpy(buf[0..carrier_prefix.len], carrier_prefix);
    @memcpy(buf[carrier_prefix.len..], key);
    return buf;
}

fn remembered(destination: *Store, allocator: std.mem.Allocator, key: *const [64]u8) ?Remembered {
    const data = destination.root.readFileAlloc(destination.io, fetched_file, allocator, .unlimited) catch return null;
    defer allocator.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const k = it.next() orelse continue;
        const carrier = it.next() orelse continue;
        const tip = it.next() orelse continue;
        if (!std.mem.eql(u8, k, key)) continue;
        return .{
            .carrier = GitOid.fromHex(carrier) catch return null,
            .tip = Oid.fromHex(tip) catch return null,
        };
    }
    return null;
}

fn remember(destination: *Store, allocator: std.mem.Allocator, key: *const [64]u8, carrier: GitOid, tip: Oid) !void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    if (destination.root.readFileAlloc(destination.io, fetched_file, allocator, .unlimited)) |data| {
        defer allocator.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0 or std.mem.startsWith(u8, t, key)) continue;
            try out.appendSlice(allocator, t);
            try out.append(allocator, '\n');
        }
    } else |_| {}
    var carrier_hex: [40]u8 = undefined;
    var hex: [Oid.len * 2]u8 = undefined;
    try out.print(allocator, "{s} {s} {s}\n", .{ key, carrier.format(&carrier_hex), tip.toHex(&hex) });
    try destination.writeFileAtomic(fetched_file, out.items);
}

fn heldCarrier(root: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator, key: *const [64]u8) ?[]u8 {
    var buf: [carrier_prefix.len + 64]u8 = undefined;
    return root.readFileAlloc(io, carrierFileName(&buf, key), allocator, .unlimited) catch null;
}

fn holdCarrier(root: std.Io.Dir, io: std.Io, key: *const [64]u8, bytes: []const u8) !void {
    var buf: [carrier_prefix.len + 64]u8 = undefined;
    try root.writeFile(io, .{ .sub_path = carrierFileName(&buf, key), .data = bytes });
}

fn holdCarrierAt(io: std.Io, repository_path: []const u8, allocator: std.mem.Allocator, remote: []const u8, branch: []const u8, bytes: []const u8) !void {
    const store_path = try std.fs.path.join(allocator, &.{ repository_path, store.dir_name });
    defer allocator.free(store_path);
    var root = try std.Io.Dir.openDirAbsolute(io, store_path, .{});
    defer root.close(io);
    try holdCarrier(root, io, &fetchedKey(remote, branch), bytes);
}

pub fn fetchInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote: []const u8,
    branch: []const u8,
    destination: *Store,
    destination_ref: []const u8,
) !Oid {
    var session = Session.init(allocator, io, remote, .configured);
    defer session.deinit();
    const smart = session.smart(allocator, remote);

    const key = fetchedKey(remote, branch);
    const known = remembered(destination, allocator, &key);
    const held = heldCarrier(destination.root, io, allocator, &key);
    defer if (held) |h| allocator.free(h);
    const known_commit: ?GitOid = if (known) |k| (if (destination.has(k.tip)) k.carrier else null) else null;

    const outcome = try apricot.git_forge.fetchWith(allocator, smart, branch, .{
        .known_carrier_commit = known_commit,
        .known_carrier_bytes = held,
    });
    defer outcome.deinit(allocator);
    const fetched = switch (outcome) {
        .unchanged => {
            const tip = known.?.tip;
            try destination.updateRef(destination_ref, tip);
            return tip;
        },
        .fetched => |f| f,
    };

    const stamp = std.Io.Clock.real.now(io).nanoseconds;
    const temporary_name = try std.fmt.allocPrint(allocator, ".sdt/apricot-fetch-{d}", .{stamp});
    defer allocator.free(temporary_name);
    const current_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(current_path);
    const temporary_path = try std.fs.path.resolve(allocator, &.{ current_path, temporary_name });
    defer allocator.free(temporary_path);
    defer std.Io.Dir.cwd().deleteTree(io, temporary_path) catch {};
    try restore(allocator, io, temporary_path, fetched);
    const source_store = try std.fs.path.join(allocator, &.{ temporary_path, ".sdt" });
    defer allocator.free(source_store);
    var source_directory = try std.Io.Dir.openDirAbsolute(io, temporary_path, .{});
    defer source_directory.close(io);
    var restored_store = try Store.open(io, allocator, source_directory);
    defer restored_store.deinit();
    const head_branch = try restored_store.headBranch();
    defer allocator.free(head_branch);
    const native_branch = if (restored_store.refExists(branch)) branch else head_branch;
    const tip = try net.fetchSparse(destination, source_store, native_branch, "");
    try destination.updateRef(destination_ref, tip);
    remember(destination, allocator, &key, fetched.carrier_commit, tip) catch {};
    holdCarrier(destination.root, io, &key, fetched.carrier_bytes) catch {};
    return tip;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "a sealed entry rides the carrier and never the projection" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    const seal = @import("seal.zig");
    const workspace = @import("workspace.zig");
    const object = @import("object.zig");

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    const absz = try alloc.dupeZ(u8, abs);
    defer alloc.free(absz);
    _ = setenv("XDG_CONFIG_HOME", absz.ptr, 1);
    defer _ = unsetenv("XDG_CONFIG_HOME");

    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);
    var source = try Store.init(io, alloc, work);
    defer source.deinit();

    const id = try keyring.createIdentity(io, alloc, true);
    var manifest = seal.Manifest.empty(alloc);
    defer manifest.deinit();
    _ = try manifest.addPath(".env");
    try manifest.putMember(io, seal.newRepoKey(io), "nico", id.publicId());
    try keyring.saveManifest(alloc, &source, &manifest);

    try work.writeFile(io, .{ .sub_path = "main.zig", .data = "pub fn main() void {}\n" });
    try work.writeFile(io, .{ .sub_path = ".env", .data = "API_KEY=sk-live-1\n" });
    _ = try workspace.snapshot(&source, work, "Nico <n@x>", "seal", 1_700_000_000);

    const work_path = try tmp.dir.realPathFileAlloc(io, "work", alloc);
    defer alloc.free(work_path);
    var captured = try apricot.sdt_codec.capture(alloc, io, work_path, "fixture");
    defer captured.deinit(alloc);
    for (captured.projection) |entry| {
        try std.testing.expect(!std.mem.eql(u8, entry.path, ".env"));
        try std.testing.expect(std.mem.indexOf(u8, entry.data, "sk-live-1") == null);
    }

    const forged = [_]apricot.git_forge.ProjectionEntry{
        .{ .path = ".env", .kind = .file, .executable = false, .data = "leak" },
        .{ .path = "main.zig", .kind = .file, .executable = false, .data = "code" },
    };
    const filtered = try projectionWithoutSealed(alloc, io, work_path, &forged);
    defer alloc.free(filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expectEqualStrings("main.zig", filtered[0].path);

    try tmp.dir.createDirPath(io, "clone");
    const clone_path = try tmp.dir.realPathFileAlloc(io, "clone", alloc);
    defer alloc.free(clone_path);
    try apricot.sdt_codec.restore(alloc, io, clone_path, captured.encoded.bytes, captured.encoded.root);

    var clone = try tmp.dir.openDir(io, "clone", .{ .iterate = true });
    defer clone.close(io);
    try std.testing.expectError(error.FileNotFound, clone.access(io, ".env", .{}));
    var restored = try Store.open(io, alloc, clone);
    defer restored.deinit();
    const branch = try restored.headBranch();
    defer alloc.free(branch);
    const change = try restored.readChange(try restored.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try restored.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    var saw = false;
    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, ".env")) continue;
        saw = true;
        try std.testing.expectEqual(object.Mode.sealed, e.mode);
    }
    try std.testing.expect(saw);

    const arrived = try keyring.sealedPathsAt(io, alloc, clone_path);
    defer keyring.freePaths(alloc, arrived);
    try std.testing.expectEqual(@as(usize, 1), arrived.len);

    const out = try keyring.unsealAll(io, alloc, &restored, clone);
    try std.testing.expectEqual(@as(usize, 1), out.written);
    const plain = try clone.readFileAlloc(io, ".env", alloc, .unlimited);
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("API_KEY=sk-live-1\n", plain);
}

test "a remembered carrier and its held bytes round-trip per remote and branch" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var st = try Store.init(io, alloc, tmp.dir);
    defer st.deinit();

    const remote = "https://example.com/plyght/superdetermine.git";
    const carrier_a = try GitOid.fromHex("0123456789abcdef0123456789abcdef01234567");
    const carrier_b = try GitOid.fromHex("89abcdef0123456789abcdef0123456789abcdef");
    const tip_a = Oid.ofBytes("a");
    const tip_b = Oid.ofBytes("b");
    const main_key = fetchedKey(remote, "main");
    const dev_key = fetchedKey(remote, "dev");
    const other_key = fetchedKey("https://example.com/other.git", "main");

    try std.testing.expect(remembered(&st, alloc, &main_key) == null);
    try remember(&st, alloc, &main_key, carrier_a, tip_a);
    try remember(&st, alloc, &dev_key, carrier_b, tip_b);
    try std.testing.expect(remembered(&st, alloc, &main_key).?.carrier.eql(carrier_a));
    try std.testing.expect(remembered(&st, alloc, &main_key).?.tip.eql(tip_a));
    try std.testing.expect(remembered(&st, alloc, &dev_key).?.tip.eql(tip_b));
    try std.testing.expect(remembered(&st, alloc, &other_key) == null);

    try remember(&st, alloc, &main_key, carrier_b, tip_b);
    try std.testing.expect(remembered(&st, alloc, &main_key).?.carrier.eql(carrier_b));
    try std.testing.expect(remembered(&st, alloc, &main_key).?.tip.eql(tip_b));
    try std.testing.expect(remembered(&st, alloc, &dev_key).?.tip.eql(tip_b));

    try std.testing.expect(heldCarrier(st.root, io, alloc, &main_key) == null);
    try holdCarrier(st.root, io, &main_key, "carrier one");
    try holdCarrier(st.root, io, &dev_key, "carrier two");
    const held_main = heldCarrier(st.root, io, alloc, &main_key).?;
    defer alloc.free(held_main);
    try std.testing.expectEqualStrings("carrier one", held_main);
    const held_dev = heldCarrier(st.root, io, alloc, &dev_key).?;
    defer alloc.free(held_dev);
    try std.testing.expectEqualStrings("carrier two", held_dev);
    try std.testing.expect(heldCarrier(st.root, io, alloc, &other_key) == null);

    const abs = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(abs);
    try holdCarrierAt(io, abs, alloc, remote, "main", "carrier three");
    const replaced = heldCarrier(st.root, io, alloc, &main_key).?;
    defer alloc.free(replaced);
    try std.testing.expectEqualStrings("carrier three", replaced);
}
