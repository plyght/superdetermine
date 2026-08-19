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

const Session = struct {
    client: apricot.git_http.Client,

    fn init(allocator: std.mem.Allocator, io: std.Io) Session {
        const credentials: ?apricot.http_client.Credentials = if (proc.envToken()) |token| .{
            .username = "apricot",
            .password = std.mem.span(token),
        } else null;
        return .{ .client = .{ .allocator = allocator, .io = io, .credentials = credentials } };
    }

    fn deinit(self: *Session) void {
        self.client.deinit();
    }

    fn smart(self: *Session, allocator: std.mem.Allocator, remote: []const u8) apricot.git_transport.SmartHttp {
        return .{ .allocator = allocator, .http = self.client.http(), .base_url = remote };
    }
};

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    remote: []const u8,
    branch: []const u8,
    repository_path: []const u8,
    timestamp: i64,
) !Published {
    var captured = try apricot.sdt_codec.capture(allocator, io, repository_path, remote);
    defer captured.deinit(allocator);
    var session = Session.init(allocator, io);
    defer session.deinit();
    return apricot.git_forge.publish(
        allocator,
        session.smart(allocator, remote),
        branch,
        captured.encoded.bytes,
        captured.encoded.root,
        captured.projection,
        timestamp,
    );
}

pub fn fetch(allocator: std.mem.Allocator, io: std.Io, remote: []const u8, branch: []const u8) !Fetched {
    var session = Session.init(allocator, io);
    defer session.deinit();
    return apricot.git_forge.fetch(allocator, session.smart(allocator, remote), branch);
}

pub fn fetchDefault(allocator: std.mem.Allocator, io: std.Io, remote: []const u8) !Fetched {
    var session = Session.init(allocator, io);
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

test "bridge exposes embedded Apricot transport" {
    try std.testing.expect(@sizeOf(Published) > 0);
    try std.testing.expect(@sizeOf(Fetched) > 0);
    try std.testing.expect(@sizeOf(Collaboration.Resource) > 0);
    try std.testing.expect(@sizeOf(ForgeDrivers.Driver) > 0);
}
