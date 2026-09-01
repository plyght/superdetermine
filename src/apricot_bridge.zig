const std = @import("std");
const apricot = @import("apricot");
const proc = @import("proc.zig");
const net = @import("net.zig");
const oid = @import("oid.zig");
const store = @import("store.zig");

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

const Session = struct {
    allocator: std.mem.Allocator,
    client: apricot.git_http.Client,
    owned_token: ?[]u8,
    helper: ?proc.Cred,

    fn init(allocator: std.mem.Allocator, io: std.Io, remote: []const u8) Session {
        var owned_token: ?[]u8 = null;
        var helper: ?proc.Cred = null;
        const credentials: ?apricot.http_client.Credentials = if (!allowsCredentials(remote))
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
    var session = Session.init(allocator, io, remote);
    defer session.deinit();
    return apricot.git_forge.publish(
        allocator,
        session.smart(allocator, remote),
        branch,
        captured.encoded.bytes,
        captured.encoded.root,
        captured.projection,
        projection_message,
        commit_signature,
        timestamp,
    );
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, remote: []const u8, branch: []const u8) !Fetched {
    var session = Session.init(allocator, io, remote);
    defer session.deinit();
    return apricot.git_forge.fetch(allocator, session.smart(allocator, remote), branch);
}

pub fn fetchDefault(allocator: std.mem.Allocator, io: std.Io, remote: []const u8) !Fetched {
    var session = Session.init(allocator, io, remote);
    defer session.deinit();
    const branch = try apricot.git_forge.defaultBranch(allocator, session.smart(allocator, remote));
    defer allocator.free(branch);
    return apricot.git_forge.fetch(allocator, session.smart(allocator, remote), branch);
}

pub fn restore(
    allocator: std.mem.Allocator,
    io: std.Io,
    destination: []const u8,
    fetched: Fetched,
) !void {
    try apricot.sdt_codec.restore(allocator, io, destination, fetched.carrier_bytes, fetched.carrier_root);
}

pub fn fetchInto(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote: []const u8,
    branch: []const u8,
    destination: *Store,
    destination_ref: []const u8,
) !Oid {
    const fetched = try fetch(allocator, io, remote, branch);
    defer fetched.deinit(allocator);
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
    return tip;
}

test "credentials are withheld from a cleartext remote" {
    try std.testing.expect(allowsCredentials("https://github.com/x/y"));
    try std.testing.expect(allowsCredentials("HTTPS://github.com/x/y"));
    try std.testing.expect(!allowsCredentials("http://192.168.1.9/x/y"));
    try std.testing.expect(!allowsCredentials("HTTP://192.168.1.9/x/y"));
}

test "bridge exposes embedded Apricot transport" {
    try std.testing.expect(@sizeOf(Published) > 0);
    try std.testing.expect(@sizeOf(Fetched) > 0);
    try std.testing.expect(@sizeOf(Collaboration.Resource) > 0);
    try std.testing.expect(@sizeOf(ForgeDrivers.Driver) > 0);
}

test "bridge maps configured authors to projection signatures" {
    const complete = signature("Plyght User <plyght@example.com>");
    try std.testing.expectEqualStrings("Plyght User", complete.name);
    try std.testing.expectEqualStrings("plyght@example.com", complete.email);
    const email_only = signature("<plyght@example.com>");
    try std.testing.expectEqualStrings("superdetermine", email_only.name);
    try std.testing.expectEqualStrings("plyght@example.com", email_only.email);
    const name_only = signature("Plyght User");
    try std.testing.expectEqualStrings("Plyght User", name_only.name);
    try std.testing.expectEqualStrings("none@superdetermine", name_only.email);
}
