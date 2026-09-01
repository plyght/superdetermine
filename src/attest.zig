const std = @import("std");
const proc = @import("proc.zig");
const lfs = @import("lfs.zig");
const verdict = @import("verdict.zig");
const Oid = @import("oid.zig").Oid;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

pub const Error = error{
    NoToken,
    NoRemote,
    BadSha,
    CurlFailed,
    Rejected,
};

/// A network failure is not a red tree. Callers exit with these so a broken
/// token and a check that genuinely failed are never the same event.
pub const exit_network: u8 = 13;
pub const exit_no_token: u8 = 15;

/// GitHub keeps the first 140 characters of a status description and drops the
/// rest, so the description is built to fit rather than sent to be cut.
pub const max_description = 140;

const sep = " · ";

pub const State = enum {
    success,
    failure,

    pub fn label(self: State) []const u8 {
        return @tagName(self);
    }
};

pub fn stateFor(v: verdict.Verdict) State {
    return if (v.isGreen()) .success else .failure;
}

// --- the description ---

fn independenceWord(i: verdict.Independence) ?[]const u8 {
    return switch (i) {
        .independent => "independent",
        .co_authored => "co-authored",
        .unknown => null,
    };
}

fn discriminationWord(d: verdict.Discrimination) ?[]const u8 {
    return switch (d) {
        .discriminating => "discriminating",
        .vacuous => "vacuous",
        .unknown => null,
    };
}

const Fit = struct {
    buf: []u8,
    limit: usize,
    len: usize = 0,
    dropped: bool = false,

    fn add(self: *Fit, text: []const u8) void {
        const lead: usize = if (self.len == 0) 0 else sep.len;
        const need = self.len + lead + text.len;
        if (need > self.limit or need > self.buf.len) {
            self.dropped = true;
            return;
        }
        if (lead != 0) {
            @memcpy(self.buf[self.len..][0..sep.len], sep);
            self.len += sep.len;
        }
        @memcpy(self.buf[self.len..][0..text.len], text);
        self.len += text.len;
    }
};

/// Render a verdict and its warrant as one status description, never longer
/// than `limit` bytes. A token that does not fit is left out whole and an
/// ellipsis says so, because half an axis reads as a different claim.
pub fn describeInto(buf: []u8, v: verdict.Verdict, limit: usize) []const u8 {
    var f = Fit{ .buf = buf, .limit = limit };
    f.add(v.result.label());

    const ind = independenceWord(v.independence);
    const dis = discriminationWord(v.discrimination);
    const has_relevance = v.relevance_total != 0;

    if (ind == null and dis == null and !has_relevance) {
        f.add("warrant unknown");
        return f.buf[0..f.len];
    }

    if (ind) |t| f.add(t);
    if (has_relevance) {
        var rel: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&rel, "relevance {d}/{d}", .{
            v.relevance_hit, v.relevance_total,
        }) catch "relevance";
        f.add(text);
    }
    if (dis) |t| f.add(t);

    if (f.dropped) {
        const marker = "…";
        const lead: usize = if (f.len == 0) 0 else sep.len;
        if (f.len + lead + marker.len <= @min(f.limit, f.buf.len)) {
            f.dropped = false;
            f.add(marker);
        }
    }
    return f.buf[0..f.len];
}

pub fn describe(buf: []u8, v: verdict.Verdict) []const u8 {
    return describeInto(buf, v, max_description);
}

/// The status context, which is the name branch protection matches on. The tier
/// belongs here and not in the description: one is an identity, the other is a
/// claim about a tree.
pub fn contextFor(buf: []u8, tier: verdict.Tier) []const u8 {
    return std.fmt.bufPrint(buf, "sdt/{s}", .{tier.label()}) catch "sdt";
}

// --- where to post it ---

pub const Target = struct {
    api_base: []u8,
    slug: []u8,

    pub fn deinit(self: Target, alloc: std.mem.Allocator) void {
        alloc.free(self.api_base);
        alloc.free(self.slug);
    }
};

/// Derive the API base and `owner/repo` slug from a git remote URL, by way of
/// the LFS endpoint parser, which already knows every https, ssh, scp and
/// git:// form a remote comes in. Returns null for anything with no host.
pub fn targetFromRemote(alloc: std.mem.Allocator, remote_url: []const u8) !?Target {
    const endpoint = (try lfs.endpointFromRemote(alloc, remote_url)) orelse return null;
    defer alloc.free(endpoint);

    var rest: []const u8 = endpoint;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    } else return null;

    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    var slug = rest[slash + 1 ..];
    if (host.len == 0) return null;

    if (!std.mem.endsWith(u8, slug, "/info/lfs")) return null;
    slug = slug[0 .. slug.len - "/info/lfs".len];
    if (std.mem.endsWith(u8, slug, ".git")) slug = slug[0 .. slug.len - ".git".len];
    if (slug.len == 0) return null;

    const github = std.mem.eql(u8, host, "github.com") or std.mem.eql(u8, host, "www.github.com");
    const api_base = if (github)
        try alloc.dupe(u8, "https://api.github.com")
    else
        try std.fmt.allocPrint(alloc, "https://{s}/api/v3", .{host});
    errdefer alloc.free(api_base);

    return .{ .api_base = api_base, .slug = try alloc.dupe(u8, slug) };
}

pub fn isFullSha(sha: []const u8) bool {
    if (sha.len != 40 and sha.len != 64) return false;
    for (sha) |ch| switch (ch) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

pub fn statusUrl(alloc: std.mem.Allocator, t: Target, sha: []const u8) ![]u8 {
    if (!isFullSha(sha)) return Error.BadSha;
    return std.fmt.allocPrint(alloc, "{s}/repos/{s}/statuses/{s}", .{ t.api_base, t.slug, sha });
}

// --- the request ---

/// The token comes from the environment and nowhere else: never a flag, never
/// git's credential helper, never a file this writes.
pub fn envToken() ?[*:0]const u8 {
    if (std.c.getenv("SDT_GITHUB_TOKEN")) |v| return v;
    if (std.c.getenv("GITHUB_TOKEN")) |v| return v;
    return null;
}

fn jsonQuote(alloc: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (ch < 0x20) try out.print(alloc, "\\u{x:0>4}", .{ch}) else try out.append(alloc, ch),
    };
    try out.append(alloc, '"');
}

fn curlQuote(alloc: std.mem.Allocator, out: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try out.appendSlice(alloc, key);
    try out.appendSlice(alloc, " = \"");
    for (value) |ch| switch (ch) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, ch),
    };
    try out.appendSlice(alloc, "\"\n");
}

pub fn buildBody(
    alloc: std.mem.Allocator,
    state: State,
    context: []const u8,
    description: []const u8,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    try body.print(alloc, "{{\"state\":\"{s}\",\"context\":", .{state.label()});
    try jsonQuote(alloc, &body, context);
    try body.appendSlice(alloc, ",\"description\":");
    try jsonQuote(alloc, &body, description);
    try body.append(alloc, '}');
    return body.toOwnedSlice(alloc);
}

/// Build the curl config fed on stdin. The token lives here and only here: not
/// in argv, where every process on the machine could read it, and not in an
/// environment curl inherits.
pub fn buildConfig(
    alloc: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
) ![]u8 {
    var cfg: std.ArrayList(u8) = .empty;
    errdefer cfg.deinit(alloc);
    try curlQuote(alloc, &cfg, "url", url);
    try curlQuote(alloc, &cfg, "request", "POST");
    try curlQuote(alloc, &cfg, "header", "Accept: application/vnd.github+json");
    try curlQuote(alloc, &cfg, "header", "X-GitHub-Api-Version: 2022-11-28");
    try curlQuote(alloc, &cfg, "header", "User-Agent: sdt");
    const auth = try std.fmt.allocPrint(alloc, "Authorization: Bearer {s}", .{token});
    defer alloc.free(auth);
    try curlQuote(alloc, &cfg, "header", auth);
    try curlQuote(alloc, &cfg, "data-binary", body);
    try curlQuote(alloc, &cfg, "write-out", "\\n%{http_code}");
    // No `location`: a redirect would carry the Authorization header to
    // whatever host the redirect names.
    try cfg.appendSlice(alloc, "silent\nshow-error\n");
    return cfg.toOwnedSlice(alloc);
}

pub fn httpCodeOf(response: []const u8) ?u16 {
    const trimmed = std.mem.trimEnd(u8, response, "\r\n \t");
    const nl = std.mem.lastIndexOfScalar(u8, trimmed, '\n') orelse return std.fmt.parseInt(u16, trimmed, 10) catch null;
    return std.fmt.parseInt(u16, trimmed[nl + 1 ..], 10) catch null;
}

/// The only function here that touches the network. It runs when the user typed
/// `sdt attest` and at no other time.
pub fn post(
    alloc: std.mem.Allocator,
    url: []const u8,
    token: []const u8,
    body: []const u8,
) !u16 {
    const cfg = try buildConfig(alloc, url, token, body);
    defer alloc.free(cfg);

    const out = proc.capture(alloc, &.{ "curl", "--config", "-" }, cfg) catch return Error.CurlFailed;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.CurlFailed;
    return httpCodeOf(out.stdout) orelse Error.CurlFailed;
}

// --- tests ---

const testing = std.testing;

fn vd(
    result: verdict.Result,
    ind: verdict.Independence,
    dis: verdict.Discrimination,
    hit: u16,
    total: u16,
) verdict.Verdict {
    return .{
        .tree = Oid.zero(),
        .tier = .full,
        .command = Oid.zero(),
        .result = result,
        .exit_code = 0,
        .duration_ms = 0,
        .ms = 0,
        .readset = Oid.zero(),
        .independence = ind,
        .relevance_hit = hit,
        .relevance_total = total,
        .discrimination = dis,
    };
}

test "the description carries every warrant axis it has" {
    var buf: [max_description]u8 = undefined;
    try testing.expectEqualStrings(
        "green · independent · relevance 5/5 · discriminating",
        describe(&buf, vd(.green, .independent, .discriminating, 5, 5)),
    );
    try testing.expectEqualStrings(
        "green · co-authored · relevance 3/5 · vacuous",
        describe(&buf, vd(.green, .co_authored, .vacuous, 3, 5)),
    );
    try testing.expectEqualStrings(
        "red · independent · relevance 2/4 · discriminating",
        describe(&buf, vd(.red, .independent, .discriminating, 2, 4)),
    );
}

test "an axis that says nothing is left out rather than guessed at" {
    var buf: [max_description]u8 = undefined;
    try testing.expectEqualStrings(
        "green · warrant unknown",
        describe(&buf, vd(.green, .unknown, .unknown, 0, 0)),
    );
    try testing.expectEqualStrings(
        "red · warrant unknown",
        describe(&buf, vd(.red, .unknown, .unknown, 0, 0)),
    );
    try testing.expectEqualStrings(
        "green · independent",
        describe(&buf, vd(.green, .independent, .unknown, 0, 0)),
    );
    try testing.expectEqualStrings(
        "green · vacuous",
        describe(&buf, vd(.green, .unknown, .vacuous, 0, 0)),
    );
    try testing.expectEqualStrings(
        "green · relevance 0/7",
        describe(&buf, vd(.green, .unknown, .unknown, 0, 7)),
    );
    try testing.expectEqualStrings(
        "green · co-authored · discriminating",
        describe(&buf, vd(.green, .co_authored, .discriminating, 0, 0)),
    );
}

test "every warrant combination fits inside the 140 character budget" {
    var buf: [max_description]u8 = undefined;
    const results = [_]verdict.Result{ .green, .red };
    const inds = [_]verdict.Independence{ .independent, .co_authored, .unknown };
    const diss = [_]verdict.Discrimination{ .discriminating, .vacuous, .unknown };
    for (results) |r| for (inds) |i| for (diss) |d| {
        for ([_][2]u16{ .{ 0, 0 }, .{ 5, 5 }, .{ 65535, 65535 } }) |rel| {
            const got = describe(&buf, vd(r, i, d, rel[0], rel[1]));
            try testing.expect(got.len <= max_description);
            try testing.expect(std.mem.indexOf(u8, got, "…") == null);
            try testing.expect(std.mem.startsWith(u8, got, r.label()));
        }
    };
}

test "a description too long for its budget drops whole tokens, never half of one" {
    var buf: [max_description]u8 = undefined;
    const full = vd(.green, .independent, .discriminating, 5, 5);

    try testing.expectEqualStrings("green · independent · …", describeInto(&buf, full, 30));
    try testing.expectEqualStrings("green · …", describeInto(&buf, full, 16));
    try testing.expectEqualStrings("green", describeInto(&buf, full, 5));
    try testing.expectEqualStrings("", describeInto(&buf, full, 2));

    // The ellipsis is the only thing ever cut short of a word boundary.
    const tight = describeInto(&buf, full, 40);
    try testing.expect(std.mem.indexOf(u8, tight, "relevanc ") == null);
    try testing.expect(std.mem.indexOf(u8, tight, "discrimin") == null);
}

test "the context names the tier, which is what branch protection matches" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("sdt/full", contextFor(&buf, .full));
    try testing.expectEqualStrings("sdt/fast", contextFor(&buf, .fast));
}

test "the state follows the result and nothing else" {
    try testing.expectEqual(State.success, stateFor(vd(.green, .co_authored, .vacuous, 0, 1)));
    try testing.expectEqual(State.failure, stateFor(vd(.red, .independent, .discriminating, 5, 5)));
}

test "owner and repo come out of https, ssh and scp remotes alike" {
    const alloc = testing.allocator;
    const cases = [_][]const u8{
        "https://github.com/plyght/superdetermine.git",
        "https://github.com/plyght/superdetermine",
        "git@github.com:plyght/superdetermine.git",
        "ssh://git@github.com/plyght/superdetermine.git",
        "ssh://git@github.com:22/plyght/superdetermine.git",
        "https://x-access-token:tok@github.com/plyght/superdetermine.git",
    };
    for (cases) |c| {
        const t = (try targetFromRemote(alloc, c)) orelse return error.TestUnexpectedResult;
        defer t.deinit(alloc);
        try testing.expectEqualStrings("https://api.github.com", t.api_base);
        try testing.expectEqualStrings("plyght/superdetermine", t.slug);
    }

    const ghe = (try targetFromRemote(alloc, "git@git.example.com:team/tools.git")) orelse
        return error.TestUnexpectedResult;
    defer ghe.deinit(alloc);
    try testing.expectEqualStrings("https://git.example.com/api/v3", ghe.api_base);
    try testing.expectEqualStrings("team/tools", ghe.slug);

    try testing.expect((try targetFromRemote(alloc, "/tmp/bare")) == null);
    try testing.expect((try targetFromRemote(alloc, "file:///tmp/bare")) == null);
    try testing.expect((try targetFromRemote(alloc, "")) == null);
}

test "the status URL names the repository and the full sha" {
    const alloc = testing.allocator;
    const t = (try targetFromRemote(alloc, "git@github.com:plyght/superdetermine.git")) orelse
        return error.TestUnexpectedResult;
    defer t.deinit(alloc);

    const sha = "0123456789abcdef0123456789abcdef01234567";
    const url = try statusUrl(alloc, t, sha);
    defer alloc.free(url);
    try testing.expectEqualStrings(
        "https://api.github.com/repos/plyght/superdetermine/statuses/" ++ sha,
        url,
    );

    try testing.expectError(Error.BadSha, statusUrl(alloc, t, "0123456"));
    try testing.expectError(Error.BadSha, statusUrl(alloc, t, "../../../etc/passwd"));
    try testing.expectError(Error.BadSha, statusUrl(alloc, t, ""));
}

test "the request body is the state, the context and the warrant" {
    const alloc = testing.allocator;
    var buf: [max_description]u8 = undefined;
    const desc = describe(&buf, vd(.green, .co_authored, .vacuous, 3, 5));
    const body = try buildBody(alloc, .success, "sdt/full", desc);
    defer alloc.free(body);
    try testing.expectEqualStrings(
        "{\"state\":\"success\",\"context\":\"sdt/full\",\"description\":\"green · co-authored · relevance 3/5 · vacuous\"}",
        body,
    );

    const quoted = try buildBody(alloc, .failure, "sdt/\"fast\"", "a\nb");
    defer alloc.free(quoted);
    try testing.expectEqualStrings(
        "{\"state\":\"failure\",\"context\":\"sdt/\\\"fast\\\"\",\"description\":\"a\\nb\"}",
        quoted,
    );
}

test "the token is carried on stdin and never reaches argv or the URL" {
    const alloc = testing.allocator;
    const url = "https://api.github.com/repos/o/r/statuses/" ++ "a" ** 40;
    const body = "{\"state\":\"success\"}";
    const cfg = try buildConfig(alloc, url, "ghp_secret", body);
    defer alloc.free(cfg);

    try testing.expect(std.mem.indexOf(u8, cfg, "Authorization: Bearer ghp_secret") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "request = \"POST\"") != null);
    try testing.expect(std.mem.indexOf(u8, cfg, "location") == null);
    try testing.expect(std.mem.indexOf(u8, url, "ghp_secret") == null);
    try testing.expect(std.mem.indexOf(u8, body, "ghp_secret") == null);
}

test "the token comes from SDT_GITHUB_TOKEN first and GITHUB_TOKEN after" {
    _ = unsetenv("SDT_GITHUB_TOKEN");
    _ = unsetenv("GITHUB_TOKEN");
    try testing.expect(envToken() == null);

    _ = setenv("GITHUB_TOKEN", "fallback", 1);
    try testing.expectEqualStrings("fallback", std.mem.span(envToken().?));

    _ = setenv("SDT_GITHUB_TOKEN", "preferred", 1);
    try testing.expectEqualStrings("preferred", std.mem.span(envToken().?));

    _ = unsetenv("SDT_GITHUB_TOKEN");
    try testing.expectEqualStrings("fallback", std.mem.span(envToken().?));

    _ = unsetenv("GITHUB_TOKEN");
    try testing.expect(envToken() == null);
}

test "no token means no request is built at all" {
    _ = unsetenv("SDT_GITHUB_TOKEN");
    _ = unsetenv("GITHUB_TOKEN");
    try testing.expectEqual(@as(?[*:0]const u8, null), envToken());
}

test "the http code is read off the tail of the response" {
    try testing.expectEqual(@as(?u16, 201), httpCodeOf("{\"id\":1}\n201"));
    try testing.expectEqual(@as(?u16, 404), httpCodeOf("{\"message\":\"Not Found\"}\n404\n"));
    try testing.expectEqual(@as(?u16, 200), httpCodeOf("200"));
    try testing.expectEqual(@as(?u16, null), httpCodeOf(""));
    try testing.expectEqual(@as(?u16, null), httpCodeOf("{}\nnot-a-code"));
}
