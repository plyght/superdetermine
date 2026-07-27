const std = @import("std");

extern "c" fn fork() std.c.pid_t;
extern "c" fn close(fd: std.c.fd_t) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Largest payload `capture` will push into a child's stdin. Writing happens
/// before stdout is drained, so a payload bigger than the pipe buffer could
/// deadlock; callers with bulk data must hand the child a file path instead.
pub const max_stdin = 32 * 1024;

pub const Output = struct {
    stdout: []u8,
    /// Raw waitpid status; 0 means the child exited successfully.
    status: c_int,

    pub fn ok(self: Output) bool {
        return self.status == 0;
    }

    pub fn deinit(self: Output, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
    }
};

pub const Error = error{ SpawnFailed, StdinTooLarge };

/// Run `argv` with a real pipe/fork/exec (no shell, so external input can never
/// be interpreted as a command), feed `stdin_data` on stdin, and capture stdout.
/// stderr is inherited. Caller frees `Output.stdout`.
pub fn capture(alloc: std.mem.Allocator, argv: []const []const u8, stdin_data: []const u8) !Output {
    if (stdin_data.len > max_stdin) return Error.StdinTooLarge;
    if (argv.len == 0) return Error.SpawnFailed;

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    const cargv = try aa.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| cargv[i] = (try aa.dupeZ(u8, a)).ptr;

    var in_pipe: [2]std.c.fd_t = undefined;
    var out_pipe: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&in_pipe) != 0) return Error.SpawnFailed;
    if (std.c.pipe(&out_pipe) != 0) {
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        return Error.SpawnFailed;
    }

    const pid = fork();
    if (pid < 0) {
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        _ = close(out_pipe[0]);
        _ = close(out_pipe[1]);
        return Error.SpawnFailed;
    }
    if (pid == 0) {
        _ = std.c.dup2(in_pipe[0], 0);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = close(in_pipe[0]);
        _ = close(in_pipe[1]);
        _ = close(out_pipe[0]);
        _ = close(out_pipe[1]);
        _ = execvp(cargv[0].?, cargv.ptr);
        std.c._exit(127);
    }

    _ = close(in_pipe[0]);
    _ = close(out_pipe[1]);

    var written: usize = 0;
    while (written < stdin_data.len) {
        const n = std.c.write(in_pipe[1], stdin_data.ptr + written, stdin_data.len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = close(in_pipe[1]);

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var tmp: [8192]u8 = undefined;
    while (true) {
        const n = std.c.read(out_pipe[0], &tmp, tmp.len);
        if (n <= 0) break;
        try buf.appendSlice(alloc, tmp[0..@intCast(n)]);
    }
    _ = close(out_pipe[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    return .{ .stdout = try buf.toOwnedSlice(alloc), .status = status };
}

// --- git credentials ---

pub const Cred = struct {
    user: [:0]u8,
    pass: [:0]u8,

    pub fn free(self: Cred) void {
        std.heap.c_allocator.free(self.user);
        std.heap.c_allocator.free(self.pass);
    }
};

/// A token from the environment, used as the HTTP basic username with a dummy
/// password (the convention GitHub and friends accept).
pub fn envToken() ?[*:0]const u8 {
    if (std.c.getenv("GIT_TOKEN")) |v| return v;
    if (std.c.getenv("GITHUB_TOKEN")) |v| return v;
    return null;
}

/// Parse `git credential fill` stdout (lines like `username=..`, `password=..`,
/// blank-line terminated) into user/pass spans of `data`. Returns null unless
/// BOTH username and password are present.
pub fn parseCredentialOutput(data: []const u8) ?struct { user: []const u8, pass: []const u8 } {
    var user: ?[]const u8 = null;
    var pass: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const val = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "username")) {
            user = val;
        } else if (std.mem.eql(u8, key, "password")) {
            pass = val;
        }
    }
    if (user == null or pass == null) return null;
    return .{ .user = user.?, .pass = pass.? };
}

/// Query git's configured credential helper (e.g. osxkeychain) by running
/// `git credential fill`, feeding `url=<url>\n\n` on stdin and parsing the
/// answer from stdout. Returns heap-allocated null-terminated user/pass on
/// success.
pub fn credentialFill(url: []const u8) ?Cred {
    const a = std.heap.c_allocator;

    const req = std.fmt.allocPrint(a, "url={s}\n\n", .{url}) catch return null;
    defer a.free(req);

    const out = capture(a, &.{ "git", "credential", "fill" }, req) catch return null;
    defer out.deinit(a);

    const parsed = parseCredentialOutput(out.stdout) orelse return null;
    const user = a.dupeZ(u8, parsed.user) catch return null;
    const pass = a.dupeZ(u8, parsed.pass) catch {
        a.free(user);
        return null;
    };
    return .{ .user = user, .pass = pass };
}

// --- tests ---

const testing = std.testing;

test "parseCredentialOutput parses username and password" {
    const blob = "protocol=https\nhost=github.com\nusername=x-access-token\npassword=ghp_abc123\n\n";
    const got = parseCredentialOutput(blob) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("x-access-token", got.user);
    try testing.expectEqualStrings("ghp_abc123", got.pass);
}

test "parseCredentialOutput returns null when password missing" {
    const blob = "protocol=https\nhost=github.com\nusername=x-access-token\n\n";
    try testing.expect(parseCredentialOutput(blob) == null);
}

test "capture round-trips stdin through a child process" {
    const alloc = testing.allocator;
    const out = capture(alloc, &.{"cat"}, "hello pipes\n") catch return;
    defer out.deinit(alloc);
    try testing.expect(out.ok());
    try testing.expectEqualStrings("hello pipes\n", out.stdout);
}

test "capture reports a non-zero exit status" {
    const alloc = testing.allocator;
    const out = capture(alloc, &.{ "sh", "-c", "exit 3" }, "") catch return;
    defer out.deinit(alloc);
    try testing.expect(!out.ok());
}

test "capture rejects an oversized stdin payload" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_stdin + 1);
    defer alloc.free(big);
    @memset(big, 'x');
    try testing.expectError(Error.StdinTooLarge, capture(alloc, &.{"cat"}, big));
}
