const std = @import("std");
const proc = @import("proc.zig");
const ignore = @import("ignore.zig");
const object = @import("object.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{
    CurlFailed,
    BadBatchResponse,
    ChecksumMismatch,
    NoEndpoint,
    ObjectMissing,
};

/// The `version` line every Git LFS pointer starts with.
pub const spec_v1 = "https://git-lfs.github.com/spec/v1";
const spec_legacy = "https://hawser.github.com/spec/v1";

/// Pointers are specified to stay well under 1 KiB; anything larger is content.
pub const max_pointer_bytes = 1024;

const batch_media_type = "application/vnd.git-lfs+json";

// --- pointers ---

pub const Pointer = struct {
    oid_hex: [64]u8,
    size: u64,

    pub fn oid(self: *const Pointer) []const u8 {
        return &self.oid_hex;
    }
};

pub fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn isLowerHex(s: []const u8) bool {
    for (s) |ch| switch (ch) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// Recognize a Git LFS pointer blob. Returns null for anything that is not one,
/// including ordinary files that merely start with the word `version`.
pub fn parsePointer(data: []const u8) ?Pointer {
    if (data.len == 0 or data.len > max_pointer_bytes) return null;
    if (std.mem.indexOfScalar(u8, data, 0) != null) return null;

    var oid_hex: ?[]const u8 = null;
    var size: ?u64 = null;
    var saw_version = false;
    var first = true;

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
        const key = line[0..sp];
        const val = line[sp + 1 ..];

        if (first) {
            first = false;
            if (!std.mem.eql(u8, key, "version")) return null;
            if (!std.mem.eql(u8, val, spec_v1) and !std.mem.eql(u8, val, spec_legacy)) return null;
            saw_version = true;
            continue;
        }
        if (std.mem.eql(u8, key, "oid")) {
            const prefix = "sha256:";
            if (!std.mem.startsWith(u8, val, prefix)) return null;
            const hex = val[prefix.len..];
            if (hex.len != 64 or !isLowerHex(hex)) return null;
            oid_hex = hex;
        } else if (std.mem.eql(u8, key, "size")) {
            size = std.fmt.parseInt(u64, val, 10) catch return null;
        }
    }

    if (!saw_version) return null;
    const hex = oid_hex orelse return null;
    const sz = size orelse return null;
    var p: Pointer = .{ .oid_hex = undefined, .size = sz };
    @memcpy(&p.oid_hex, hex);
    return p;
}

/// Render a pointer in the canonical form git-lfs writes: `version` first, then
/// the remaining keys in alphabetical order, each line LF-terminated.
pub fn formatPointer(alloc: std.mem.Allocator, p: Pointer) ![]u8 {
    return std.fmt.allocPrint(alloc, "version {s}\noid sha256:{s}\nsize {d}\n", .{
        spec_v1,
        &p.oid_hex,
        p.size,
    });
}

/// Hash `content` and render the pointer that would stand in for it.
pub fn pointerForContent(alloc: std.mem.Allocator, content: []const u8) ![]u8 {
    return formatPointer(alloc, .{ .oid_hex = sha256Hex(content), .size = content.len });
}

// --- .gitattributes ---

/// The `filter=lfs` rules of a `.gitattributes` file. Last matching rule wins,
/// so a later `-filter` or `filter=` line can take a path back out of LFS.
pub const Attributes = struct {
    alloc: std.mem.Allocator,
    rules: []Rule,

    pub const Rule = struct {
        pattern: []u8,
        lfs: bool,
        anchored: bool,
    };

    pub fn parse(alloc: std.mem.Allocator, text: []const u8) !Attributes {
        var rules: std.ArrayList(Rule) = .empty;
        errdefer {
            for (rules.items) |r| alloc.free(r.pattern);
            rules.deinit(alloc);
        }

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#' or line[0] == '[') continue;

            var pattern: []const u8 = undefined;
            var rest: []const u8 = undefined;
            if (line[0] == '"') {
                const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse continue;
                pattern = line[1..close];
                rest = line[close + 1 ..];
            } else {
                const sp = std.mem.indexOfAny(u8, line, " \t") orelse continue;
                pattern = line[0..sp];
                rest = line[sp..];
            }
            if (pattern.len == 0) continue;

            var lfs: ?bool = null;
            var toks = std.mem.tokenizeAny(u8, rest, " \t");
            while (toks.next()) |tok| {
                if (std.mem.eql(u8, tok, "filter=lfs")) {
                    lfs = true;
                } else if (std.mem.eql(u8, tok, "-filter") or
                    std.mem.eql(u8, tok, "!filter") or
                    std.mem.eql(u8, tok, "filter="))
                {
                    lfs = false;
                } else if (std.mem.startsWith(u8, tok, "filter=")) {
                    lfs = false;
                }
            }
            const decided = lfs orelse continue;

            var pat = pattern;
            var anchored = false;
            if (pat.len > 1 and pat[0] == '/') {
                anchored = true;
                pat = pat[1..];
            }
            const owned = try alloc.dupe(u8, pat);
            errdefer alloc.free(owned);
            try rules.append(alloc, .{ .pattern = owned, .lfs = decided, .anchored = anchored });
        }

        return .{ .alloc = alloc, .rules = try rules.toOwnedSlice(alloc) };
    }

    pub fn empty(alloc: std.mem.Allocator) !Attributes {
        return .{ .alloc = alloc, .rules = try alloc.alloc(Rule, 0) };
    }

    pub fn deinit(self: *Attributes) void {
        for (self.rules) |r| self.alloc.free(r.pattern);
        self.alloc.free(self.rules);
    }

    /// `rel_path` is repo-root-relative and forward-slash separated.
    pub fn isLfs(self: Attributes, rel_path: []const u8) bool {
        const base = if (std.mem.lastIndexOfScalar(u8, rel_path, '/')) |i|
            rel_path[i + 1 ..]
        else
            rel_path;

        var tracked = false;
        for (self.rules) |r| {
            const hit = if (r.anchored or std.mem.indexOfScalar(u8, r.pattern, '/') != null)
                ignore.matchPath(r.pattern, rel_path)
            else
                ignore.matchSegment(r.pattern, base);
            if (hit) tracked = r.lfs;
        }
        return tracked;
    }

    pub fn tracks(self: Attributes, pattern: []const u8) bool {
        for (self.rules) |r| {
            if (r.lfs and std.mem.eql(u8, r.pattern, pattern)) return true;
        }
        return false;
    }
};

/// The canonical line `git lfs track` writes for `pattern`.
pub fn trackLine(alloc: std.mem.Allocator, pattern: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s} filter=lfs diff=lfs merge=lfs -text\n", .{pattern});
}

/// Append a tracking rule to `.gitattributes` text, returning the new text.
/// Re-tracking an already-tracked pattern is a no-op.
pub fn addTracking(alloc: std.mem.Allocator, old: []const u8, pattern: []const u8) !?[]u8 {
    var attrs = try Attributes.parse(alloc, old);
    defer attrs.deinit();
    if (attrs.tracks(pattern)) return null;

    const line = try trackLine(alloc, pattern);
    defer alloc.free(line);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, old);
    if (out.items.len != 0 and out.items[out.items.len - 1] != '\n') try out.append(alloc, '\n');
    try out.appendSlice(alloc, line);
    return try out.toOwnedSlice(alloc);
}

/// Drop every `filter=lfs` rule whose pattern equals `pattern`, returning the
/// new text, or null when nothing matched.
pub fn removeTracking(alloc: std.mem.Allocator, old: []const u8, pattern: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var removed = false;

    var lines = std.mem.splitScalar(u8, old, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0 and lines.peek() == null) break;
        const line = std.mem.trim(u8, raw, " \t\r");
        var drop = false;
        if (line.len != 0 and line[0] != '#' and line[0] != '[') {
            if (std.mem.indexOf(u8, line, "filter=lfs") != null) {
                const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
                const pat = std.mem.trim(u8, line[0..sp], "\"");
                if (std.mem.eql(u8, pat, pattern)) drop = true;
            }
        }
        if (drop) {
            removed = true;
            continue;
        }
        try out.appendSlice(alloc, raw);
        try out.append(alloc, '\n');
    }

    if (!removed) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

// --- endpoint discovery ---

fn trimSuffix(s: []const u8, suffix: []const u8) []const u8 {
    if (std.mem.endsWith(u8, s, suffix)) return s[0 .. s.len - suffix.len];
    return s;
}

/// Derive the LFS API endpoint from a git remote URL, the way git-lfs guesses
/// it: the repository URL with `.git/info/lfs` appended. ssh remotes fall back
/// to https on the same host. Returns null for local paths and `file://` URLs,
/// which have no LFS server. Caller frees.
pub fn endpointFromRemote(alloc: std.mem.Allocator, remote_url: []const u8) !?[]u8 {
    const url = std.mem.trimEnd(u8, remote_url, "/");
    if (url.len == 0) return null;
    if (std.mem.startsWith(u8, url, "file://")) return null;

    var host_and_path: []const u8 = undefined;

    if (std.mem.startsWith(u8, url, "https://")) {
        host_and_path = url["https://".len..];
    } else if (std.mem.startsWith(u8, url, "http://")) {
        host_and_path = url["http://".len..];
    } else if (std.mem.startsWith(u8, url, "ssh://")) {
        host_and_path = url["ssh://".len..];
    } else if (std.mem.startsWith(u8, url, "git://")) {
        host_and_path = url["git://".len..];
    } else if (std.mem.indexOfScalar(u8, url, ':')) |colon| {
        const at = std.mem.indexOfScalar(u8, url, '@') orelse 0;
        if (at > colon or std.mem.indexOf(u8, url, "://") != null) return null;
        const host = url[if (at == 0) 0 else at + 1..colon];
        const path = url[colon + 1 ..];
        if (host.len == 0 or path.len == 0) return null;
        return try finishEndpoint(alloc, host, path, false);
    } else {
        return null;
    }

    if (std.mem.indexOfScalar(u8, host_and_path, '@')) |at| {
        host_and_path = host_and_path[at + 1 ..];
    }
    const slash = std.mem.indexOfScalar(u8, host_and_path, '/') orelse return null;
    var host = host_and_path[0..slash];
    const path = host_and_path[slash + 1 ..];
    if (host.len == 0 or path.len == 0) return null;

    if (std.mem.startsWith(u8, url, "ssh://") or std.mem.startsWith(u8, url, "git://")) {
        if (std.mem.lastIndexOfScalar(u8, host, ':')) |port| host = host[0..port];
    }
    return try finishEndpoint(alloc, host, path, std.mem.startsWith(u8, url, "http://"));
}

fn finishEndpoint(alloc: std.mem.Allocator, host: []const u8, path: []const u8, plain: bool) ![]u8 {
    const scheme = if (plain) "http" else "https";
    const clean = std.mem.trimStart(u8, path, "/");
    if (std.mem.endsWith(u8, clean, ".git")) {
        return std.fmt.allocPrint(alloc, "{s}://{s}/{s}/info/lfs", .{ scheme, host, clean });
    }
    return std.fmt.allocPrint(alloc, "{s}://{s}/{s}.git/info/lfs", .{ scheme, host, clean });
}

// --- local object cache ---

/// Path of `oid_hex` inside an LFS cache root, matching git-lfs's own layout so
/// gr and `git lfs` can share one `.git/lfs/objects` directory.
pub fn objectRelPath(buf: []u8, oid_hex: []const u8) ![]const u8 {
    if (oid_hex.len < 4) return Error.ObjectMissing;
    return std.fmt.bufPrint(buf, "lfs/objects/{s}/{s}/{s}", .{
        oid_hex[0..2],
        oid_hex[2..4],
        oid_hex,
    });
}

// --- HTTP via curl ---

const BasicAuth = struct {
    header: []u8,

    fn deinit(self: BasicAuth, alloc: std.mem.Allocator) void {
        alloc.free(self.header);
    }
};

fn basicAuthHeader(alloc: std.mem.Allocator, user: []const u8, pass: []const u8) ![]u8 {
    const raw = try std.fmt.allocPrint(alloc, "{s}:{s}", .{ user, pass });
    defer alloc.free(raw);
    const enc = std.base64.standard.Encoder;
    const buf = try alloc.alloc(u8, enc.calcSize(raw.len));
    defer alloc.free(buf);
    const b64 = enc.encode(buf, raw);
    return std.fmt.allocPrint(alloc, "Authorization: Basic {s}", .{b64});
}

/// Resolve HTTP credentials for `url`: an environment token first, then git's
/// configured credential helper. Returns null when neither yields anything.
fn resolveAuth(alloc: std.mem.Allocator, url: []const u8) !?BasicAuth {
    if (proc.envToken()) |tok| {
        const t = std.mem.span(tok);
        if (t.len != 0) return .{ .header = try basicAuthHeader(alloc, t, "x-oauth-basic") };
    }
    if (proc.credentialFill(url)) |cred| {
        defer cred.free();
        return .{ .header = try basicAuthHeader(alloc, cred.user, cred.pass) };
    }
    return null;
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

// --- batch API ---

pub const BatchOp = enum {
    download,
    upload,

    fn name(self: BatchOp) []const u8 {
        return switch (self) {
            .download => "download",
            .upload => "upload",
        };
    }
};

pub const Request = struct {
    oid_hex: []const u8,
    size: u64,
};

/// One object's slot in a batch response: `href`/`headers` when the server
/// wants a transfer, both null when it already has the object, `message` when
/// it reported an error for that object specifically.
pub const Slot = struct {
    oid_hex: []u8,
    size: u64,
    href: ?[]u8 = null,
    headers: [][]u8 = &.{},
    verify_href: ?[]u8 = null,
    verify_headers: [][]u8 = &.{},
    message: ?[]u8 = null,

    fn deinit(self: Slot, alloc: std.mem.Allocator) void {
        alloc.free(self.oid_hex);
        if (self.href) |h| alloc.free(h);
        for (self.headers) |h| alloc.free(h);
        alloc.free(self.headers);
        if (self.verify_href) |h| alloc.free(h);
        for (self.verify_headers) |h| alloc.free(h);
        alloc.free(self.verify_headers);
        if (self.message) |m| alloc.free(m);
    }
};

pub fn freeSlots(alloc: std.mem.Allocator, slots: []Slot) void {
    for (slots) |s| s.deinit(alloc);
    alloc.free(slots);
}

fn buildBatchBody(alloc: std.mem.Allocator, op: BatchOp, objects: []const Request) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(alloc);
    try body.print(alloc, "{{\"operation\":\"{s}\",\"transfers\":[\"basic\"],\"hash_algo\":\"sha256\",\"objects\":[", .{op.name()});
    for (objects, 0..) |o, i| {
        if (i != 0) try body.append(alloc, ',');
        try body.appendSlice(alloc, "{\"oid\":");
        try jsonQuote(alloc, &body, o.oid_hex);
        try body.print(alloc, ",\"size\":{d}}}", .{o.size});
    }
    try body.appendSlice(alloc, "]}");
    return body.toOwnedSlice(alloc);
}

fn collectHeaders(alloc: std.mem.Allocator, obj: std.json.ObjectMap) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |h| alloc.free(h);
        out.deinit(alloc);
    }
    const hdrs = switch (obj.get("header") orelse .null) {
        .object => |o| o,
        else => return out.toOwnedSlice(alloc),
    };
    var it = hdrs.iterator();
    while (it.next()) |kv| {
        const v = switch (kv.value_ptr.*) {
            .string => |s| s,
            else => continue,
        };
        try out.append(alloc, try std.fmt.allocPrint(alloc, "{s}: {s}", .{ kv.key_ptr.*, v }));
    }
    return out.toOwnedSlice(alloc);
}

fn jsonU64(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

/// POST an LFS batch request and decode the per-object answers. Caller frees
/// the result with `freeSlots`.
pub fn batch(
    alloc: std.mem.Allocator,
    endpoint: []const u8,
    op: BatchOp,
    objects: []const Request,
    auth: ?BasicAuth,
) ![]Slot {
    if (objects.len == 0) return alloc.alloc(Slot, 0);

    const body = try buildBatchBody(alloc, op, objects);
    defer alloc.free(body);

    const url = try std.fmt.allocPrint(alloc, "{s}/objects/batch", .{endpoint});
    defer alloc.free(url);

    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try curlQuote(alloc, &cfg, "url", url);
    try curlQuote(alloc, &cfg, "request", "POST");
    try curlQuote(alloc, &cfg, "header", "Accept: " ++ batch_media_type);
    try curlQuote(alloc, &cfg, "header", "Content-Type: " ++ batch_media_type);
    if (auth) |a| try curlQuote(alloc, &cfg, "header", a.header);
    try curlQuote(alloc, &cfg, "data-binary", body);
    try cfg.appendSlice(alloc, "silent\nshow-error\nlocation\n");

    const out = proc.capture(alloc, &.{ "curl", "--config", "-" }, cfg.items) catch return Error.CurlFailed;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.CurlFailed;

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, out.stdout, .{
        .ignore_unknown_fields = true,
    }) catch return Error.BadBatchResponse;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return Error.BadBatchResponse,
    };
    const arr = switch (root.get("objects") orelse .null) {
        .array => |a| a,
        else => return Error.BadBatchResponse,
    };

    var slots: std.ArrayList(Slot) = .empty;
    errdefer {
        for (slots.items) |s| s.deinit(alloc);
        slots.deinit(alloc);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const oid_hex = switch (obj.get("oid") orelse .null) {
            .string => |s| s,
            else => continue,
        };
        var slot = Slot{
            .oid_hex = try alloc.dupe(u8, oid_hex),
            .size = jsonU64(obj.get("size") orelse .null),
        };
        errdefer slot.deinit(alloc);

        if (obj.get("error")) |e| switch (e) {
            .object => |eo| {
                const msg = switch (eo.get("message") orelse .null) {
                    .string => |s| s,
                    else => "object error",
                };
                slot.message = try alloc.dupe(u8, msg);
            },
            else => {},
        };

        if (obj.get("actions")) |a| switch (a) {
            .object => |actions| {
                if (actions.get(op.name())) |act| switch (act) {
                    .object => |ao| {
                        if (ao.get("href")) |h| switch (h) {
                            .string => |s| slot.href = try alloc.dupe(u8, s),
                            else => {},
                        };
                        slot.headers = try collectHeaders(alloc, ao);
                    },
                    else => {},
                };
                if (actions.get("verify")) |vact| switch (vact) {
                    .object => |vo| {
                        if (vo.get("href")) |h| switch (h) {
                            .string => |s| slot.verify_href = try alloc.dupe(u8, s),
                            else => {},
                        };
                        slot.verify_headers = try collectHeaders(alloc, vo);
                    },
                    else => {},
                };
            },
            else => {},
        };

        try slots.append(alloc, slot);
    }

    return slots.toOwnedSlice(alloc);
}

// --- transfers ---

fn download(alloc: std.mem.Allocator, slot: Slot, dest_abs: []const u8) !void {
    const href = slot.href orelse return Error.ObjectMissing;
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try curlQuote(alloc, &cfg, "url", href);
    for (slot.headers) |h| try curlQuote(alloc, &cfg, "header", h);
    try curlQuote(alloc, &cfg, "output", dest_abs);
    try cfg.appendSlice(alloc, "silent\nshow-error\nlocation\nfail\ncreate-dirs\n");

    const out = proc.capture(alloc, &.{ "curl", "--config", "-" }, cfg.items) catch return Error.CurlFailed;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.CurlFailed;
}

fn upload(alloc: std.mem.Allocator, slot: Slot, src_abs: []const u8) !void {
    const href = slot.href orelse return;
    var cfg: std.ArrayList(u8) = .empty;
    defer cfg.deinit(alloc);
    try curlQuote(alloc, &cfg, "url", href);
    for (slot.headers) |h| try curlQuote(alloc, &cfg, "header", h);
    try curlQuote(alloc, &cfg, "upload-file", src_abs);
    try cfg.appendSlice(alloc, "silent\nshow-error\nlocation\nfail\n");

    const out = proc.capture(alloc, &.{ "curl", "--config", "-" }, cfg.items) catch return Error.CurlFailed;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.CurlFailed;

    const vhref = slot.verify_href orelse return;
    var vbody: std.ArrayList(u8) = .empty;
    defer vbody.deinit(alloc);
    try vbody.appendSlice(alloc, "{\"oid\":");
    try jsonQuote(alloc, &vbody, slot.oid_hex);
    try vbody.print(alloc, ",\"size\":{d}}}", .{slot.size});

    var vcfg: std.ArrayList(u8) = .empty;
    defer vcfg.deinit(alloc);
    try curlQuote(alloc, &vcfg, "url", vhref);
    try curlQuote(alloc, &vcfg, "request", "POST");
    try curlQuote(alloc, &vcfg, "header", "Content-Type: " ++ batch_media_type);
    for (slot.verify_headers) |h| try curlQuote(alloc, &vcfg, "header", h);
    try curlQuote(alloc, &vcfg, "data-binary", vbody.items);
    try vcfg.appendSlice(alloc, "silent\nshow-error\nlocation\nfail\n");

    const vout = proc.capture(alloc, &.{ "curl", "--config", "-" }, vcfg.items) catch return Error.CurlFailed;
    defer vout.deinit(alloc);
    if (!vout.ok()) return Error.CurlFailed;
}

// --- session ---

/// Everything an import/export/push needs to move LFS content around: where the
/// shared object cache lives, which remote to talk to, and whether pointers are
/// resolved to real bytes (smudge) or carried through verbatim.
pub const Session = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    /// Absolute path of the directory holding `lfs/objects`. Prefers a colocated
    /// git dir so gr and `git lfs` share one cache.
    cache_root: []u8,
    endpoint: ?[]u8,
    /// Resolved lazily, and only when a transfer actually needs it, so purely
    /// local commands never wake git's credential helper.
    auth: ?BasicAuth = null,
    auth_tried: bool = false,
    smudge: bool,
    uploads: bool,
    /// Pointers we could not turn back into content (offline, or the server does
    /// not have them). Callers surface this rather than failing the whole op.
    unresolved: usize = 0,
    pending: std.StringHashMapUnmanaged(u64) = .{},

    pub fn open(
        store: *Store,
        git_dir_abs: ?[]const u8,
        remote_url: ?[]const u8,
    ) !Session {
        const alloc = store.alloc;
        const io = store.io;

        const cache_root = blk: {
            if (git_dir_abs) |g| break :blk try alloc.dupe(u8, std.mem.trimEnd(u8, g, "/"));
            const abs = try store.root.realPathFileAlloc(io, ".", alloc);
            defer alloc.free(abs);
            break :blk try alloc.dupe(u8, abs);
        };
        errdefer alloc.free(cache_root);

        var endpoint: ?[]u8 = null;
        errdefer if (endpoint) |e| alloc.free(e);
        if (config.get(store, alloc, "lfs.url") catch null) |v| {
            if (v.len != 0) endpoint = v else alloc.free(v);
        }
        if (endpoint == null) {
            if (remote_url) |u| endpoint = try endpointFromRemote(alloc, u);
        }

        return .{
            .io = io,
            .alloc = alloc,
            .cache_root = cache_root,
            .endpoint = endpoint,
            .smudge = boolConfig(store, "lfs.smudge", true),
            .uploads = boolConfig(store, "lfs.upload", true),
        };
    }

    pub fn deinit(self: *Session) void {
        self.alloc.free(self.cache_root);
        if (self.endpoint) |e| self.alloc.free(e);
        if (self.auth) |a| a.deinit(self.alloc);
        var it = self.pending.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.pending.deinit(self.alloc);
    }

    fn ensureAuth(self: *Session) ?BasicAuth {
        if (!self.auth_tried) {
            self.auth_tried = true;
            const endpoint = self.endpoint orelse return null;
            self.auth = resolveAuth(self.alloc, endpoint) catch null;
        }
        return self.auth;
    }

    /// Absolute path of `oid_hex` in the local cache. Caller frees.
    pub fn objectPath(self: *Session, oid_hex: []const u8) ![]u8 {
        var buf: [128]u8 = undefined;
        const rel = try objectRelPath(&buf, oid_hex);
        return std.fmt.allocPrint(self.alloc, "{s}/{s}", .{ self.cache_root, rel });
    }

    pub fn hasObject(self: *Session, oid_hex: []const u8) bool {
        const path = self.objectPath(oid_hex) catch return false;
        defer self.alloc.free(path);
        std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
        return true;
    }

    /// Read `oid_hex` out of the local cache, verifying the digest. Caller frees.
    pub fn readObject(self: *Session, oid_hex: []const u8) !?[]u8 {
        const path = try self.objectPath(oid_hex);
        defer self.alloc.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.alloc, .unlimited) catch return null;
        errdefer self.alloc.free(data);
        const actual = sha256Hex(data);
        if (!std.mem.eql(u8, &actual, oid_hex)) {
            self.alloc.free(data);
            return null;
        }
        return data;
    }

    /// Write `content` into the local cache under its own sha256.
    pub fn writeObject(self: *Session, content: []const u8) ![64]u8 {
        const hex = sha256Hex(content);
        const path = try self.objectPath(&hex);
        defer self.alloc.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        }
        std.Io.Dir.cwd().access(self.io, path, .{}) catch {
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = content });
        };
        return hex;
    }

    /// Turn a pointer back into the bytes it stands for: local cache first, then
    /// a batch download. Returns null when neither can supply it, and bumps
    /// `unresolved` so the caller can report a partial result. Caller frees.
    pub fn resolve(self: *Session, p: Pointer) !?[]u8 {
        if (try self.readObject(&p.oid_hex)) |data| return data;

        const endpoint = self.endpoint orelse {
            self.unresolved += 1;
            return null;
        };

        const reqs = [_]Request{.{ .oid_hex = &p.oid_hex, .size = p.size }};
        const slots = batch(self.alloc, endpoint, .download, &reqs, self.ensureAuth()) catch {
            self.unresolved += 1;
            return null;
        };
        defer freeSlots(self.alloc, slots);
        if (slots.len == 0 or slots[0].href == null) {
            self.unresolved += 1;
            return null;
        }

        const path = try self.objectPath(&p.oid_hex);
        defer self.alloc.free(path);
        if (std.fs.path.dirname(path)) |dir| {
            std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        }
        download(self.alloc, slots[0], path) catch {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.unresolved += 1;
            return null;
        };

        const data = try self.readObject(&p.oid_hex) orelse {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.unresolved += 1;
            return null;
        };
        return data;
    }

    /// Record that `oid_hex` may need uploading on the next push.
    pub fn markPending(self: *Session, oid_hex: []const u8, size: u64) !void {
        if (self.pending.contains(oid_hex)) return;
        const key = try self.alloc.dupe(u8, oid_hex);
        errdefer self.alloc.free(key);
        try self.pending.put(self.alloc, key, size);
    }

    /// Ask the server which of `objects` it is missing and upload exactly those.
    /// Returns the number actually transferred.
    pub fn uploadObjects(self: *Session, objects: []const Request) !usize {
        if (!self.uploads or objects.len == 0) return 0;
        const endpoint = self.endpoint orelse return Error.NoEndpoint;

        const slots = try batch(self.alloc, endpoint, .upload, objects, self.ensureAuth());
        defer freeSlots(self.alloc, slots);

        var sent: usize = 0;
        for (slots) |slot| {
            if (slot.href == null) continue;
            const path = try self.objectPath(slot.oid_hex);
            defer self.alloc.free(path);
            std.Io.Dir.cwd().access(self.io, path, .{}) catch continue;
            try upload(self.alloc, slot, path);
            sent += 1;
        }
        return sent;
    }

    /// Upload everything `markPending` collected during an export.
    pub fn flushPending(self: *Session) !usize {
        if (self.pending.count() == 0) return 0;
        var reqs: std.ArrayList(Request) = .empty;
        defer reqs.deinit(self.alloc);
        var it = self.pending.iterator();
        while (it.next()) |kv| {
            try reqs.append(self.alloc, .{ .oid_hex = kv.key_ptr.*, .size = kv.value_ptr.* });
        }
        return self.uploadObjects(reqs.items);
    }
};

fn boolConfig(store: *Store, key: []const u8, default: bool) bool {
    const v = (config.get(store, store.alloc, key) catch return default) orelse return default;
    defer store.alloc.free(v);
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1") or
        std.mem.eql(u8, v, "yes") or std.mem.eql(u8, v, "on")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0") or
        std.mem.eql(u8, v, "no") or std.mem.eql(u8, v, "off")) return false;
    return default;
}

/// Load `.gitattributes` out of a superdetermine tree. Trees are flat, so this is a
/// direct lookup of the root file. Absent means "nothing is LFS-tracked".
pub fn attributesFromTree(store: *Store, tree: object.Tree) !Attributes {
    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, ".gitattributes")) continue;
        const data = store.readFileContent(e.blob) catch break;
        defer store.alloc.free(data);
        return Attributes.parse(store.alloc, data);
    }
    return Attributes.empty(store.alloc);
}

// --- the `sdt lfs` command ---

pub const Context = struct {
    store: *Store,
    work: std.Io.Dir,
    /// Absolute path of a colocated `.git`, so gr and `git lfs` share a cache.
    git_dir_abs: ?[]const u8 = null,
    remote_url: ?[]const u8 = null,
};

const usage =
    \\usage: sdt lfs <command>
    \\
    \\  track <pattern>    store matching files as LFS objects on git export
    \\  untrack <pattern>  stop tracking a pattern
    \\  ls                 LFS-tracked files in the last save
    \\  fetch              make sure every tracked object is in the local cache
    \\  push               upload objects the remote is missing
    \\  status             tracked patterns and how many objects are cached
    \\  env                endpoint, cache location and settings
    \\
;

const TrackedEntry = struct {
    path: []u8,
    oid_hex: [64]u8,
    size: u64,
    /// True when gr holds the real bytes; false when its tree holds a pointer.
    inlined: bool,
};

fn freeTracked(alloc: std.mem.Allocator, list: []TrackedEntry) void {
    for (list) |t| alloc.free(t.path);
    alloc.free(list);
}

/// Every LFS-tracked path in the current HEAD tree, with the object each one
/// resolves to. Works in both smudge modes: a stored pointer yields its own oid,
/// stored content is hashed.
fn trackedInHead(store: *Store, alloc: std.mem.Allocator) ![]TrackedEntry {
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return alloc.alloc(TrackedEntry, 0);

    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    var attrs = try attributesFromTree(store, tree);
    defer attrs.deinit();

    var out: std.ArrayList(TrackedEntry) = .empty;
    errdefer {
        for (out.items) |t| alloc.free(t.path);
        out.deinit(alloc);
    }

    for (tree.entries) |e| {
        const content = store.readFileContent(e.blob) catch continue;
        defer alloc.free(content);
        if (parsePointer(content)) |p| {
            const path = try alloc.dupe(u8, e.path);
            errdefer alloc.free(path);
            try out.append(alloc, .{ .path = path, .oid_hex = p.oid_hex, .size = p.size, .inlined = false });
        } else if (attrs.isLfs(e.path)) {
            const path = try alloc.dupe(u8, e.path);
            errdefer alloc.free(path);
            try out.append(alloc, .{
                .path = path,
                .oid_hex = sha256Hex(content),
                .size = content.len,
                .inlined = true,
            });
        }
    }
    return out.toOwnedSlice(alloc);
}

/// `.gitattributes` as it stands in the working tree, falling back to the copy
/// in the last save so `ls`/`status` still work in a repo whose working tree has
/// not been materialized.
fn readAttributes(ctx: Context, alloc: std.mem.Allocator) ![]u8 {
    if (ctx.work.readFileAlloc(ctx.store.io, ".gitattributes", alloc, .unlimited)) |data| {
        if (data.len != 0) return data;
        alloc.free(data);
    } else |_| {}

    const store = ctx.store;
    const branch = try store.headBranch();
    defer alloc.free(branch);
    if (!store.refExists(branch)) return alloc.dupe(u8, "");

    const change = try store.readChange(try store.readRef(branch));
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, ".gitattributes")) continue;
        return store.readFileContent(e.blob) catch break;
    }
    return alloc.dupe(u8, "");
}

pub fn run(ctx: Context, w: *std.Io.Writer, rest: []const []const u8) !void {
    const store = ctx.store;
    const alloc = store.alloc;
    const io = store.io;
    const sub = if (rest.len >= 1) rest[0] else "status";

    if (std.mem.eql(u8, sub, "help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "--help")) {
        try w.writeAll(usage);
        return;
    }

    if (std.mem.eql(u8, sub, "track") or std.mem.eql(u8, sub, "untrack")) {
        if (rest.len < 2) {
            try w.print("usage: sdt lfs {s} <pattern>\n", .{sub});
            return;
        }
        const pattern = rest[1];
        const old = try readAttributes(ctx, alloc);
        defer alloc.free(old);

        const updated = if (std.mem.eql(u8, sub, "track"))
            try addTracking(alloc, old, pattern)
        else
            try removeTracking(alloc, old, pattern);

        const text = updated orelse {
            if (std.mem.eql(u8, sub, "track")) {
                try w.print("already tracking {s}\n", .{pattern});
            } else {
                try w.print("{s} is not tracked\n", .{pattern});
            }
            return;
        };
        defer alloc.free(text);
        try ctx.work.writeFile(io, .{ .sub_path = ".gitattributes", .data = text });
        if (std.mem.eql(u8, sub, "track")) {
            try w.print("tracking {s}: files matching it export to git as LFS pointers\n", .{pattern});
        } else {
            try w.print("stopped tracking {s}\n", .{pattern});
        }
        return;
    }

    if (std.mem.eql(u8, sub, "env")) {
        var session = try Session.open(store, ctx.git_dir_abs, ctx.remote_url);
        defer session.deinit();
        try w.print("cache      {s}/lfs/objects\n", .{session.cache_root});
        if (session.endpoint) |e| {
            try w.print("endpoint   {s}\n", .{e});
        } else {
            try w.writeAll("endpoint   (none: no remote, or a local/file:// one)\n");
        }
        try w.print("smudge     {s}  (lfs.smudge)\n", .{if (session.smudge) "on" else "off"});
        try w.print("upload     {s}  (lfs.upload)\n", .{if (session.uploads) "on" else "off"});
        return;
    }

    const tracked = try trackedInHead(store, alloc);
    defer freeTracked(alloc, tracked);

    if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "status")) {
        var session = try Session.open(store, ctx.git_dir_abs, ctx.remote_url);
        defer session.deinit();

        const old = try readAttributes(ctx, alloc);
        defer alloc.free(old);
        var attrs = try Attributes.parse(alloc, old);
        defer attrs.deinit();

        if (attrs.rules.len == 0 and tracked.len == 0) {
            try w.writeAll("nothing tracked by LFS. try `sdt lfs track \"*.psd\"`\n");
            return;
        }
        if (std.mem.eql(u8, sub, "status")) {
            try w.writeAll("patterns:\n");
            for (attrs.rules) |r| {
                if (r.lfs) try w.print("  {s}\n", .{r.pattern});
            }
        }
        var cached: usize = 0;
        for (tracked) |t| {
            const have = t.inlined or session.hasObject(&t.oid_hex);
            if (have) cached += 1;
            if (std.mem.eql(u8, sub, "ls")) {
                try w.print("  {s}  {d} bytes  {s}  {s}\n", .{
                    t.oid_hex[0..12],
                    t.size,
                    if (t.inlined) "content" else "pointer",
                    t.path,
                });
            }
        }
        if (std.mem.eql(u8, sub, "status")) {
            try w.print("{d} tracked file(s) in the last save, {d} available locally\n", .{ tracked.len, cached });
        }
        return;
    }

    if (std.mem.eql(u8, sub, "fetch")) {
        var session = try Session.open(store, ctx.git_dir_abs, ctx.remote_url);
        defer session.deinit();
        var added: usize = 0;
        var missing: usize = 0;
        for (tracked) |t| {
            if (session.hasObject(&t.oid_hex)) continue;
            if (t.inlined) {
                // gr already holds the bytes; seed the shared cache from them so
                // a colocated `git lfs` checkout finds the object too.
                const branch = try store.headBranch();
                defer alloc.free(branch);
                const change = try store.readChange(try store.readRef(branch));
                defer object.freeChange(alloc, change);
                const tree = try store.readTree(change.tree);
                defer object.freeTree(alloc, tree);
                for (tree.entries) |e| {
                    if (!std.mem.eql(u8, e.path, t.path)) continue;
                    const content = try store.readFileContent(e.blob);
                    defer alloc.free(content);
                    _ = try session.writeObject(content);
                    added += 1;
                    break;
                }
                continue;
            }
            const p = Pointer{ .oid_hex = t.oid_hex, .size = t.size };
            if (try session.resolve(p)) |data| {
                alloc.free(data);
                added += 1;
            } else {
                missing += 1;
            }
        }
        try w.print("lfs fetch: {d} object(s) added to the cache", .{added});
        if (missing != 0) {
            try w.print(", {d} unavailable (no endpoint or not on the server)", .{missing});
        }
        try w.writeByte('\n');
        return;
    }

    if (std.mem.eql(u8, sub, "push")) {
        var session = try Session.open(store, ctx.git_dir_abs, ctx.remote_url);
        defer session.deinit();
        if (session.endpoint == null) {
            try w.writeAll("no LFS endpoint. set a remote, or `sdt config lfs.url <endpoint>`\n");
            return;
        }
        var reqs: std.ArrayList(Request) = .empty;
        defer reqs.deinit(alloc);
        for (tracked) |*t| {
            if (t.inlined and !session.hasObject(&t.oid_hex)) {
                const branch = try store.headBranch();
                defer alloc.free(branch);
                const change = try store.readChange(try store.readRef(branch));
                defer object.freeChange(alloc, change);
                const tree = try store.readTree(change.tree);
                defer object.freeTree(alloc, tree);
                for (tree.entries) |e| {
                    if (!std.mem.eql(u8, e.path, t.path)) continue;
                    const content = try store.readFileContent(e.blob);
                    defer alloc.free(content);
                    _ = try session.writeObject(content);
                    break;
                }
            }
            if (!session.hasObject(&t.oid_hex)) continue;
            try reqs.append(alloc, .{ .oid_hex = &t.oid_hex, .size = t.size });
        }
        const sent = session.uploadObjects(reqs.items) catch |e| {
            try w.print("lfs push failed: {s}\n", .{@errorName(e)});
            return;
        };
        try w.print("lfs push: {d} object(s) uploaded, {d} already on the server\n", .{
            sent,
            reqs.items.len - sent,
        });
        return;
    }

    try w.print("unknown lfs command: {s}\n\n", .{sub});
    try w.writeAll(usage);
}

// --- tests ---

const testing = std.testing;

test "parsePointer accepts a canonical pointer" {
    const blob =
        "version https://git-lfs.github.com/spec/v1\n" ++
        "oid sha256:4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393\n" ++
        "size 12345\n";
    const p = parsePointer(blob) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 12345), p.size);
    try testing.expectEqualStrings(
        "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393",
        &p.oid_hex,
    );
}

test "parsePointer rejects non-pointers" {
    try testing.expect(parsePointer("") == null);
    try testing.expect(parsePointer("hello world\n") == null);
    try testing.expect(parsePointer("version 1.2.3\nfoo bar\n") == null);
    try testing.expect(parsePointer("version https://git-lfs.github.com/spec/v1\nsize 5\n") == null);
    try testing.expect(parsePointer("version https://git-lfs.github.com/spec/v1\noid sha256:abc\nsize 5\n") == null);
    try testing.expect(parsePointer("version https://git-lfs.github.com/spec/v1\noid sha256:" ++ ("A" ** 64) ++ "\nsize 5\n") == null);
    var binary = [_]u8{ 'v', 'e', 'r', 0, 's' };
    try testing.expect(parsePointer(&binary) == null);
}

test "parsePointer rejects an oversized blob" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_pointer_bytes + 1);
    defer alloc.free(big);
    @memset(big, 'v');
    try testing.expect(parsePointer(big) == null);
}

test "pointerForContent round-trips through parsePointer" {
    const alloc = testing.allocator;
    const text = try pointerForContent(alloc, "big file contents");
    defer alloc.free(text);
    const p = parsePointer(text) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 17), p.size);
    try testing.expectEqualStrings(&sha256Hex("big file contents"), &p.oid_hex);
}

test "attributes match lfs patterns, last rule wins" {
    const alloc = testing.allocator;
    var attrs = try Attributes.parse(alloc,
        \\# comment
        \\*.psd filter=lfs diff=lfs merge=lfs -text
        \\assets/**/*.bin filter=lfs diff=lfs merge=lfs -text
        \\small.psd -filter
        \\"has space.zip" filter=lfs
    );
    defer attrs.deinit();

    try testing.expect(attrs.isLfs("art.psd"));
    try testing.expect(attrs.isLfs("nested/dir/art.psd"));
    try testing.expect(attrs.isLfs("assets/models/mesh.bin"));
    try testing.expect(attrs.isLfs("has space.zip"));
    try testing.expect(!attrs.isLfs("small.psd"));
    try testing.expect(!attrs.isLfs("readme.md"));
    try testing.expect(!attrs.isLfs("other/mesh.bin"));
}

test "attributes ignores non-lfs lines" {
    const alloc = testing.allocator;
    var attrs = try Attributes.parse(alloc, "*.txt text eol=lf\n[attr]binary -diff\n");
    defer attrs.deinit();
    try testing.expectEqual(@as(usize, 0), attrs.rules.len);
    try testing.expect(!attrs.isLfs("a.txt"));
}

test "addTracking and removeTracking edit gitattributes" {
    const alloc = testing.allocator;

    const added = (try addTracking(alloc, "", "*.bin")) orelse return error.TestUnexpectedResult;
    defer alloc.free(added);
    try testing.expectEqualStrings("*.bin filter=lfs diff=lfs merge=lfs -text\n", added);

    try testing.expect((try addTracking(alloc, added, "*.bin")) == null);

    const second = (try addTracking(alloc, added, "*.psd")) orelse return error.TestUnexpectedResult;
    defer alloc.free(second);
    var attrs = try Attributes.parse(alloc, second);
    defer attrs.deinit();
    try testing.expect(attrs.isLfs("a.bin"));
    try testing.expect(attrs.isLfs("a.psd"));

    const removed = (try removeTracking(alloc, second, "*.bin")) orelse return error.TestUnexpectedResult;
    defer alloc.free(removed);
    var attrs2 = try Attributes.parse(alloc, removed);
    defer attrs2.deinit();
    try testing.expect(!attrs2.isLfs("a.bin"));
    try testing.expect(attrs2.isLfs("a.psd"));

    try testing.expect((try removeTracking(alloc, removed, "*.nope")) == null);
}

test "endpointFromRemote covers https, ssh and scp forms" {
    const alloc = testing.allocator;

    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "https://github.com/o/r.git", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "https://github.com/o/r", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "https://github.com/o/r/", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "git@github.com:o/r.git", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "ssh://git@github.com:22/o/r.git", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "ssh://git@github.com/o/r", .want = "https://github.com/o/r.git/info/lfs" },
        .{ .in = "http://localhost:3000/o/r.git", .want = "http://localhost:3000/o/r.git/info/lfs" },
    };
    for (cases) |c| {
        const got = (try endpointFromRemote(alloc, c.in)) orelse return error.TestUnexpectedResult;
        defer alloc.free(got);
        try testing.expectEqualStrings(c.want, got);
    }

    try testing.expect((try endpointFromRemote(alloc, "file:///tmp/bare")) == null);
    try testing.expect((try endpointFromRemote(alloc, "/tmp/bare")) == null);
    try testing.expect((try endpointFromRemote(alloc, "")) == null);
}

test "objectRelPath matches the git-lfs layout" {
    var buf: [128]u8 = undefined;
    const hex = "4d7a214614ab2935c943f9e0ff69d22eadbb8f32b1258daaa5e2ca24d17e2393";
    const got = try objectRelPath(&buf, hex);
    try testing.expectEqualStrings("lfs/objects/4d/7a/" ++ hex, got);
}

test "batch request body is well formed json" {
    const alloc = testing.allocator;
    const reqs = [_]Request{
        .{ .oid_hex = "aa" ** 32, .size = 10 },
        .{ .oid_hex = "bb" ** 32, .size = 20 },
    };
    const body = try buildBatchBody(alloc, .upload, &reqs);
    defer alloc.free(body);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("upload", root.get("operation").?.string);
    try testing.expectEqual(@as(usize, 2), root.get("objects").?.array.items.len);
    try testing.expectEqual(@as(i64, 20), root.get("objects").?.array.items[1].object.get("size").?.integer);
}

test "curlQuote escapes quotes and backslashes" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try curlQuote(alloc, &out, "header", "X: a\"b\\c");
    try testing.expectEqualStrings("header = \"X: a\\\"b\\\\c\"\n", out.items);
}

test "session caches, reads and verifies objects" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var session = try Session.open(&store, null, null);
    defer session.deinit();

    try testing.expect(session.smudge);
    try testing.expect(session.endpoint == null);

    const hex = try session.writeObject("large payload");
    try testing.expect(session.hasObject(&hex));

    const back = (try session.readObject(&hex)) orelse return error.TestUnexpectedResult;
    defer alloc.free(back);
    try testing.expectEqualStrings("large payload", back);

    const bogus = "0" ** 64;
    try testing.expect(!session.hasObject(bogus));
    try testing.expect((try session.readObject(bogus)) == null);

    const p = Pointer{ .oid_hex = hex, .size = 13 };
    const resolved = (try session.resolve(p)) orelse return error.TestUnexpectedResult;
    defer alloc.free(resolved);
    try testing.expectEqualStrings("large payload", resolved);

    var missing = Pointer{ .oid_hex = undefined, .size = 1 };
    @memcpy(&missing.oid_hex, bogus);
    try testing.expect((try session.resolve(missing)) == null);
    try testing.expectEqual(@as(usize, 1), session.unresolved);
}

test "session honors lfs.smudge and lfs.url config" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try config.set(&store, "lfs.smudge", "false");
    try config.set(&store, "lfs.url", "https://example.com/custom/info/lfs");

    var session = try Session.open(&store, null, "https://github.com/o/r.git");
    defer session.deinit();
    try testing.expect(!session.smudge);
    try testing.expectEqualStrings("https://example.com/custom/info/lfs", session.endpoint.?);
}

test "attributesFromTree reads the tracked patterns out of a tree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const attr_blob = try store.writeFileContent("*.bin filter=lfs diff=lfs merge=lfs -text\n");
    const other_blob = try store.writeFileContent("hi");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = ".gitattributes", .blob = attr_blob },
        .{ .mode = .regular, .path = "a.txt", .blob = other_blob },
    };

    var attrs = try attributesFromTree(&store, .{ .entries = &entries });
    defer attrs.deinit();
    try testing.expect(attrs.isLfs("data/blob.bin"));
    try testing.expect(!attrs.isLfs("a.txt"));

    var none = try attributesFromTree(&store, .{ .entries = entries[1..] });
    defer none.deinit();
    try testing.expect(!none.isLfs("data/blob.bin"));
}
