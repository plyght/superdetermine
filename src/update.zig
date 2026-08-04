const std = @import("std");
const builtin = @import("builtin");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub fn assetName() ?[]const u8 {
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => return null,
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return null,
    };
    if (std.mem.eql(u8, os, "macos")) {
        return if (std.mem.eql(u8, arch, "arm64")) "gr-macos-arm64" else "gr-macos-x64";
    }
    return if (std.mem.eql(u8, arch, "arm64")) "gr-linux-arm64" else "gr-linux-x64";
}

pub fn isUpToDate(current: []const u8, tag: []const u8) bool {
    const t = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
    const c = if (current.len > 0 and current[0] == 'v') current[1..] else current;
    return std.mem.eql(u8, t, c);
}

pub fn sha256Hex(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

fn selfExePathAlloc(alloc: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            var buf: [4096]u8 = undefined;
            var size: u32 = buf.len;
            if (std.c._NSGetExecutablePath(&buf, &size) != 0) return error.PathTooLong;
            const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
            return alloc.dupe(u8, buf[0..len]);
        },
        .linux => {
            var buf: [4096]u8 = undefined;
            const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
            if (n <= 0) return error.SelfExeNotFound;
            return alloc.dupe(u8, buf[0..@intCast(n)]);
        },
        else => return error.Unsupported,
    }
}

fn curlCapture(io: std.Io, alloc: std.mem.Allocator, url: []const u8, api: bool) ![]u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "curl", "-fsSL", "-A", "gr-updater" });
    if (api) try argv.appendSlice(alloc, &.{ "-H", "Accept: application/vnd.github+json" });
    try argv.append(alloc, url);

    const res = try std.process.run(alloc, io, .{ .argv = argv.items });
    defer alloc.free(res.stderr);
    errdefer alloc.free(res.stdout);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }
    return res.stdout;
}

fn curlToFile(io: std.Io, alloc: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    const argv = [_][]const u8{ "curl", "-fsSL", "-A", "gr-updater", "-o", path, url };
    const res = try std.process.run(alloc, io, .{ .argv = &argv });
    defer alloc.free(res.stdout);
    defer alloc.free(res.stderr);
    switch (res.term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }
}

fn findAssetUrl(assets: std.json.Array, name: []const u8) ?[]const u8 {
    for (assets.items) |a| {
        const obj = switch (a) {
            .object => |o| o,
            else => continue,
        };
        const nm = obj.get("name") orelse continue;
        const nm_s = switch (nm) {
            .string => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, nm_s, name)) continue;
        const url = obj.get("browser_download_url") orelse return null;
        return switch (url) {
            .string => |s| s,
            else => null,
        };
    }
    return null;
}

pub fn run(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, current_version: []const u8, nightly: bool) !void {
    const asset = assetName() orelse {
        try w.writeAll("gr update: unsupported platform (no prebuilt release for this OS/arch)\n");
        return;
    };

    const api_url = if (nightly)
        "https://api.github.com/repos/plyght/guardrail/releases/tags/nightly"
    else
        "https://api.github.com/repos/plyght/guardrail/releases/latest";
    const body = curlCapture(io, alloc, api_url, true) catch {
        if (nightly) {
            try w.writeAll("no nightly build available yet\n");
            return;
        }
        try w.writeAll("gr update: could not reach GitHub (network? curl available?)\n");
        return;
    };
    defer alloc.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try w.writeAll("gr update: could not parse the release metadata\n");
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try w.writeAll("gr update: unexpected release metadata\n");
            return;
        },
    };
    const tag = switch (root.get("tag_name") orelse .null) {
        .string => |s| s,
        else => {
            if (nightly) {
                try w.writeAll("no nightly build available yet\n");
                return;
            }
            try w.writeAll("gr update: release has no tag_name\n");
            return;
        },
    };
    const assets = switch (root.get("assets") orelse .null) {
        .array => |a| a,
        else => {
            try w.writeAll("gr update: release has no assets\n");
            return;
        },
    };

    if (!nightly and isUpToDate(current_version, tag)) {
        try w.print("gr is already up to date ({s})\n", .{tag});
        return;
    }

    const label = if (nightly) blk: {
        const published = switch (root.get("published_at") orelse .null) {
            .string => |s| s,
            else => tag,
        };
        break :blk published;
    } else tag;

    const bin_url = findAssetUrl(assets, asset) orelse {
        try w.print("gr update: no asset '{s}' in release {s}\n", .{ asset, tag });
        return;
    };
    var sha_name_buf: [128]u8 = undefined;
    const sha_name = try std.fmt.bufPrint(&sha_name_buf, "{s}.sha256", .{asset});
    const sha_url = findAssetUrl(assets, sha_name) orelse {
        try w.print("gr update: no checksum '{s}' in release {s}\n", .{ sha_name, tag });
        return;
    };

    const exe = try selfExePathAlloc(alloc);
    defer alloc.free(exe);
    const dir = std.fs.path.dirname(exe) orelse ".";
    const tmp = try std.fs.path.join(alloc, &.{ dir, "gr.new" });
    defer alloc.free(tmp);

    curlToFile(io, alloc, bin_url, tmp) catch {
        try w.writeAll("gr update: download failed\n");
        return;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const expected_raw = curlCapture(io, alloc, sha_url, false) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("gr update: checksum download failed\n");
        return;
    };
    defer alloc.free(expected_raw);
    var it = std.mem.tokenizeAny(u8, expected_raw, " \t\r\n");
    const expected = it.next() orelse "";

    const data = std.Io.Dir.cwd().readFileAlloc(io, tmp, alloc, .unlimited) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("gr update: could not read downloaded binary\n");
        return;
    };
    defer alloc.free(data);
    const actual = try sha256Hex(alloc, data);
    defer alloc.free(actual);

    if (!std.ascii.eqlIgnoreCase(expected, actual)) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("gr update: checksum mismatch, refusing to install\n");
        return;
    }

    const tmp_z = try alloc.dupeZ(u8, tmp);
    defer alloc.free(tmp_z);
    const exe_z = try alloc.dupeZ(u8, exe);
    defer alloc.free(exe_z);

    if (std.c.chmod(tmp_z, 0o755) != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("gr update: could not set permissions\n");
        return;
    }
    if (std.c.rename(tmp_z, exe_z) != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("gr update: could not replace the running binary\n");
        return;
    }

    if (nightly) {
        try w.print("updated gr to nightly ({s})\n", .{label});
    } else {
        try w.print("updated gr to {s}\n", .{label});
    }
}

test "assetName matches current build target" {
    const got = assetName();
    switch (builtin.os.tag) {
        .macos, .linux => try std.testing.expect(got != null),
        else => return,
    }
    const os = switch (builtin.os.tag) {
        .macos => "macos",
        .linux => "linux",
        else => unreachable,
    };
    const arch = switch (builtin.cpu.arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        else => return,
    };
    var buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "gr-{s}-{s}", .{ os, arch });
    try std.testing.expectEqualStrings(want, got.?);
}

test "sha256Hex known vector" {
    const hex = try sha256Hex(std.testing.allocator, "abc");
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}

test "sha256Hex empty" {
    const hex = try sha256Hex(std.testing.allocator, "");
    defer std.testing.allocator.free(hex);
    try std.testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        hex,
    );
}

test "isUpToDate strips leading v" {
    try std.testing.expect(isUpToDate("0.2.0", "v0.2.0"));
    try std.testing.expect(isUpToDate("v0.2.0", "0.2.0"));
    try std.testing.expect(isUpToDate("0.2.0", "0.2.0"));
    try std.testing.expect(!isUpToDate("0.2.0", "v0.3.0"));
    try std.testing.expect(!isUpToDate("0.0.0", "v0.2.0"));
}
