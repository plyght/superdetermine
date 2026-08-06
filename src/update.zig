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
        return if (std.mem.eql(u8, arch, "arm64")) "sdt-macos-arm64" else "sdt-macos-x64";
    }
    return if (std.mem.eql(u8, arch, "arm64")) "sdt-linux-arm64" else "sdt-linux-x64";
}

/// The pre-rename asset name for this platform.
///
/// Releases cut before the rename only carry `gr-<platform>`, so an update that
/// reaches back to one of those still has something to download.
pub fn legacyAssetName() ?[]const u8 {
    const name = assetName() orelse return null;
    return if (std.mem.eql(u8, name, "sdt-macos-arm64"))
        "gr-macos-arm64"
    else if (std.mem.eql(u8, name, "sdt-macos-x64"))
        "gr-macos-x64"
    else if (std.mem.eql(u8, name, "sdt-linux-arm64"))
        "gr-linux-arm64"
    else
        "gr-linux-x64";
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

pub fn selfExePathAlloc(alloc: std.mem.Allocator) ![]u8 {
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

/// Make sure an `sdt` command exists beside a binary invoked under the old name.
///
/// Someone who installed `gr` and runs `gr update` gets the new binary in place,
/// but the command they type is still `gr` and nothing else on their machine is
/// called `sdt`. This runs before the up-to-date check on purpose: once the
/// binary has already been replaced there is no version change left to trigger
/// on, and without this the alias would never appear.
fn ensureAlias(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) void {
    const exe = selfExePathAlloc(alloc) catch return;
    defer alloc.free(exe);

    const invoked = std.fs.path.basename(exe);
    if (std.mem.eql(u8, invoked, "sdt")) return;

    const dir = std.fs.path.dirname(exe) orelse return;
    const sibling = std.fs.path.join(alloc, &.{ dir, "sdt" }) catch return;
    defer alloc.free(sibling);
    if (std.Io.Dir.cwd().access(io, sibling, .{})) |_| return else |_| {}

    const data = std.Io.Dir.cwd().readFileAlloc(io, exe, alloc, .unlimited) catch return;
    defer alloc.free(data);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sibling, .data = data }) catch return;

    const sib_z = alloc.dupeZ(u8, sibling) catch return;
    defer alloc.free(sib_z);
    _ = std.c.chmod(sib_z, 0o755);

    w.print("this tool is now called {s}sdt{s} (superdetermine).\n", .{ "\x1b[1m", "\x1b[0m" }) catch {};
    w.print("installed as {s}/sdt; `{s}` still works and is the same binary.\n\n", .{ dir, invoked }) catch {};
}

pub fn run(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, current_version: []const u8, nightly: bool) !void {
    ensureAlias(io, alloc, w);

    const asset = assetName() orelse {
        try w.writeAll("sdt update: unsupported platform (no prebuilt release for this OS/arch)\n");
        return;
    };

    const api_url = if (nightly)
        "https://api.github.com/repos/plyght/superdetermine/releases/tags/nightly"
    else
        "https://api.github.com/repos/plyght/superdetermine/releases/latest";
    const body = curlCapture(io, alloc, api_url, true) catch {
        if (nightly) {
            try w.writeAll("no nightly build available yet\n");
            return;
        }
        try w.writeAll("sdt update: could not reach GitHub (network? curl available?)\n");
        return;
    };
    defer alloc.free(body);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{
        .ignore_unknown_fields = true,
    }) catch {
        try w.writeAll("sdt update: could not parse the release metadata\n");
        return;
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            try w.writeAll("sdt update: unexpected release metadata\n");
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
            try w.writeAll("sdt update: release has no tag_name\n");
            return;
        },
    };
    const assets = switch (root.get("assets") orelse .null) {
        .array => |a| a,
        else => {
            try w.writeAll("sdt update: release has no assets\n");
            return;
        },
    };

    if (!nightly and isUpToDate(current_version, tag)) {
        try w.print("sdt is already up to date ({s})\n", .{tag});
        return;
    }

    const label = if (nightly) blk: {
        const published = switch (root.get("published_at") orelse .null) {
            .string => |s| s,
            else => tag,
        };
        break :blk published;
    } else tag;

    // Prefer the current asset name, then the pre-rename one, so this works
    // against releases cut on either side of the rename.
    const chosen = findAssetUrl(assets, asset) orelse blk: {
        const legacy = legacyAssetName() orelse {
            try w.print("sdt update: no asset '{s}' in release {s}\n", .{ asset, tag });
            return;
        };
        break :blk findAssetUrl(assets, legacy) orelse {
            try w.print("sdt update: no asset '{s}' in release {s}\n", .{ asset, tag });
            return;
        };
    };
    const bin_url = chosen;
    const effective = if (findAssetUrl(assets, asset) != null) asset else (legacyAssetName() orelse asset);

    var sha_name_buf: [128]u8 = undefined;
    const sha_name = try std.fmt.bufPrint(&sha_name_buf, "{s}.sha256", .{effective});
    const sha_url = findAssetUrl(assets, sha_name) orelse {
        try w.print("sdt update: no checksum '{s}' in release {s}\n", .{ sha_name, tag });
        return;
    };

    const exe = try selfExePathAlloc(alloc);
    defer alloc.free(exe);
    const dir = std.fs.path.dirname(exe) orelse ".";
    const tmp = try std.fs.path.join(alloc, &.{ dir, "sdt.new" });
    defer alloc.free(tmp);

    curlToFile(io, alloc, bin_url, tmp) catch {
        try w.writeAll("sdt update: download failed\n");
        return;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    const expected_raw = curlCapture(io, alloc, sha_url, false) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: checksum download failed\n");
        return;
    };
    defer alloc.free(expected_raw);
    var it = std.mem.tokenizeAny(u8, expected_raw, " \t\r\n");
    const expected = it.next() orelse "";

    const data = std.Io.Dir.cwd().readFileAlloc(io, tmp, alloc, .unlimited) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: could not read downloaded binary\n");
        return;
    };
    defer alloc.free(data);
    const actual = try sha256Hex(alloc, data);
    defer alloc.free(actual);

    if (!std.ascii.eqlIgnoreCase(expected, actual)) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: checksum mismatch, refusing to install\n");
        return;
    }

    const tmp_z = try alloc.dupeZ(u8, tmp);
    defer alloc.free(tmp_z);
    const exe_z = try alloc.dupeZ(u8, exe);
    defer alloc.free(exe_z);

    if (std.c.chmod(tmp_z, 0o755) != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: could not set permissions\n");
        return;
    }
    if (std.c.rename(tmp_z, exe_z) != 0) {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: could not replace the running binary\n");
        return;
    }

    // The running binary has been replaced in place. If it was invoked under
    // the old name, the command the user typed still works but is now the new
    // binary, so also install it under the new name beside it and say so. That
    // is what makes `gr update` migrate someone to `sdt` rather than quietly
    // leaving them on a name that no longer exists anywhere else.
    const invoked = std.fs.path.basename(exe);
    const migrated = !std.mem.eql(u8, invoked, "sdt");
    if (migrated) {
        const sibling = try std.fs.path.join(alloc, &.{ dir, "sdt" });
        defer alloc.free(sibling);
        if (std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sibling, .data = data })) |_| {
            const sib_z = try alloc.dupeZ(u8, sibling);
            defer alloc.free(sib_z);
            _ = std.c.chmod(sib_z, 0o755);
        } else |_| {}
    }

    if (nightly) {
        try w.print("updated sdt to nightly ({s})\n", .{label});
    } else {
        try w.print("updated sdt to {s}\n", .{label});
    }
    if (migrated) {
        try w.print("\nthis tool is now called {s}sdt{s} (superdetermine).\n", .{ "\x1b[1m", "\x1b[0m" });
        try w.print("installed alongside as {s}/sdt; `{s}` still works and is the same binary.\n", .{ dir, invoked });
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
    const want = try std.fmt.bufPrint(&buf, "sdt-{s}-{s}", .{ os, arch });
    try std.testing.expectEqualStrings(want, got.?);

    var legacy_buf: [64]u8 = undefined;
    const want_legacy = try std.fmt.bufPrint(&legacy_buf, "gr-{s}-{s}", .{ os, arch });
    try std.testing.expectEqualStrings(want_legacy, legacyAssetName().?);
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

test "asset names follow the current binary, with a pre-rename fallback" {
    const name = assetName() orelse return;
    try std.testing.expect(std.mem.startsWith(u8, name, "sdt-"));

    const legacy = legacyAssetName() orelse return;
    try std.testing.expect(std.mem.startsWith(u8, legacy, "gr-"));
    // Same platform suffix on both, or an update would fetch the wrong binary.
    try std.testing.expectEqualStrings(name["sdt-".len..], legacy["gr-".len..]);
}
