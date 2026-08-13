const std = @import("std");
const builtin = @import("builtin");
const ui = @import("ui.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

const bar_cells = 24;
const redraw_interval_ms = 80;
const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const partial_cells = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

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
    try argv.appendSlice(alloc, &.{ "curl", "-fsSL", "-A", "sdt-updater" });
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

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.awake, io).nanoseconds, 1_000_000));
}

fn humanBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    if (i == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[i] }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch unreachable;
}

fn renderProgress(buf: []u8, transferred: u64, total: ?u64, cells: usize, tick: usize) []const u8 {
    var out = std.Io.Writer.fixed(buf);
    const known = if (total) |t| (if (t == 0) null else t) else null;

    if (known == null) {
        var got_buf: [32]u8 = undefined;
        out.print("{s}{s}{s} {s}{s}{s}", .{
            ui.on(.cyan),
            spinner_frames[tick % spinner_frames.len],
            ui.off(),
            ui.on(.dim),
            humanBytes(transferred, &got_buf),
            ui.off(),
        }) catch unreachable;
        return out.buffered();
    }

    const t = known.?;
    const done = @min(transferred, t);
    const pct = (done * 100) / t;
    const eighths = (done * cells * 8) / t;
    const full = @min(eighths / 8, cells);
    const part = if (full == cells) 0 else eighths % 8;
    const empty = cells - full - @intFromBool(part != 0);

    var got_buf: [32]u8 = undefined;
    var want_buf: [32]u8 = undefined;
    out.print("{s}", .{ui.on(.green)}) catch unreachable;
    out.splatBytesAll("█", @intCast(full)) catch unreachable;
    if (part != 0) out.writeAll(partial_cells[@intCast(part)]) catch unreachable;
    out.print("{s}{s}", .{ ui.off(), ui.on(.dim) }) catch unreachable;
    out.splatBytesAll("░", @intCast(empty)) catch unreachable;
    out.print("{s}  {s}{d:>3}%{s}  {s}{s} / {s}{s}", .{
        ui.off(),
        ui.on(.bold),
        pct,
        ui.off(),
        ui.on(.dim),
        humanBytes(done, &got_buf),
        humanBytes(t, &want_buf),
        ui.off(),
    }) catch unreachable;
    return out.buffered();
}

fn drawProgress(w: *std.Io.Writer, transferred: u64, total: ?u64, tick: usize) void {
    var buf: [512]u8 = undefined;
    const line = renderProgress(&buf, transferred, total, bar_cells, tick);
    w.print("\x1b[2K\r{s}downloading{s}  {s}", .{ ui.on(.dim), ui.off(), line }) catch return;
    w.flush() catch {};
}

fn clearProgress(w: *std.Io.Writer) void {
    w.writeAll("\x1b[2K\r") catch return;
    w.flush() catch {};
}

fn downloadToFile(io: std.Io, w: *std.Io.Writer, url: []const u8, path: []const u8, total: ?u64) !u64 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "curl", "-fsSL", "-A", "sdt-updater", url },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return error.CurlFailed;
    defer child.kill(io);

    var file = std.Io.Dir.cwd().createFile(io, path, .{}) catch return error.CurlFailed;
    defer file.close(io);

    const animate = ui.isTty();
    defer if (animate) clearProgress(w);

    var buf: [32 * 1024]u8 = undefined;
    var transferred: u64 = 0;
    var tick: usize = 0;
    var last_draw = nowMillis(io);
    if (animate) drawProgress(w, 0, total, 0);

    while (true) {
        const n = child.stdout.?.readStreaming(io, &.{&buf}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.CurlFailed,
        };
        if (n != 0) {
            file.writeStreamingAll(io, buf[0..n]) catch return error.CurlFailed;
            transferred += n;
        }
        if (!animate) continue;
        const now = nowMillis(io);
        if (now - last_draw < redraw_interval_ms) continue;
        last_draw = now;
        tick += 1;
        drawProgress(w, transferred, total, tick);
    }

    const term = child.wait(io) catch return error.CurlFailed;
    switch (term) {
        .exited => |code| if (code != 0) return error.CurlFailed,
        else => return error.CurlFailed,
    }
    return transferred;
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

fn findAssetSize(assets: std.json.Array, name: []const u8) ?u64 {
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
        return switch (obj.get("size") orelse return null) {
            .integer => |i| if (i > 0) @intCast(i) else null,
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

    const bin_url = findAssetUrl(assets, asset) orelse {
        try w.print("sdt update: no asset '{s}' in release {s}\n", .{ asset, tag });
        return;
    };
    const effective = asset;

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

    const transferred = downloadToFile(io, w, bin_url, tmp, findAssetSize(assets, effective)) catch {
        std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
        try w.writeAll("sdt update: download failed\n");
        return;
    };
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp) catch {};

    var got_buf: [32]u8 = undefined;
    try w.print("{s}{s}{s} downloaded {s}\n", .{
        ui.on(.green),
        ui.check,
        ui.off(),
        humanBytes(transferred, &got_buf),
    });

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

test "humanBytes scales into the unit that fits" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", humanBytes(0, &buf));
    try std.testing.expectEqualStrings("512 B", humanBytes(512, &buf));
    try std.testing.expectEqualStrings("1.0 KB", humanBytes(1024, &buf));
    try std.testing.expectEqualStrings("1.5 KB", humanBytes(1536, &buf));
    try std.testing.expectEqualStrings("8.0 MB", humanBytes(8 * 1024 * 1024, &buf));
    try std.testing.expectEqualStrings("1.0 GB", humanBytes(1024 * 1024 * 1024, &buf));
}

test "renderProgress draws a bar against a known total" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(false);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "░░░░░░░░    0%  0 B / 1.0 KB",
        renderProgress(&buf, 0, 1024, 8, 0),
    );
    try std.testing.expectEqualStrings(
        "████░░░░   50%  512 B / 1.0 KB",
        renderProgress(&buf, 512, 1024, 8, 0),
    );
    try std.testing.expectEqualStrings(
        "████████  100%  1.0 KB / 1.0 KB",
        renderProgress(&buf, 1024, 1024, 8, 0),
    );
}

test "renderProgress fills a partial cell rather than jumping" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(false);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "█▌░░░░░░   18%  192 B / 1.0 KB",
        renderProgress(&buf, 192, 1024, 8, 0),
    );
}

test "renderProgress never exceeds the bar or the total" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(false);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "████████  100%  1.0 KB / 1.0 KB",
        renderProgress(&buf, 4096, 1024, 8, 0),
    );
}

test "renderProgress spins instead of inventing a denominator" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(false);

    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("⠋ 512 B", renderProgress(&buf, 512, null, 8, 0));
    try std.testing.expectEqualStrings("⠙ 1.0 KB", renderProgress(&buf, 1024, null, 8, 1));
    try std.testing.expectEqualStrings("⠋ 512 B", renderProgress(&buf, 512, 0, 8, 0));
    try std.testing.expectEqualStrings(
        "⠋ 512 B",
        renderProgress(&buf, 512, null, 8, spinner_frames.len),
    );
}

test "the drawn line carries no escape codes when colour is off" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(false);

    var buf: [512]u8 = undefined;
    for ([_]?u64{ 1024, null }) |total| {
        const line = renderProgress(&buf, 512, total, 8, 3);
        try std.testing.expect(std.mem.indexOfScalar(u8, line, 0x1b) == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\r') == null);
        try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    }
}

test "the bar wears colour only when colour is on" {
    const prev = ui.isEnabled();
    defer ui.setEnabled(prev);
    ui.setEnabled(true);

    var buf: [512]u8 = undefined;
    const line = renderProgress(&buf, 512, 1024, 8, 0);
    try std.testing.expect(std.mem.indexOf(u8, line, ui.on(.green)) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, ui.on(.dim)) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "50%") != null);

    const spun = renderProgress(&buf, 512, null, 8, 0);
    try std.testing.expect(std.mem.indexOf(u8, spun, ui.on(.cyan)) != null);
}

test "nothing is painted when stdout is not a terminal" {
    const prev_tty = ui.isTty();
    const prev_color = ui.isEnabled();
    defer ui.setTty(prev_tty);
    defer ui.setEnabled(prev_color);
    ui.setTty(false);
    ui.setEnabled(false);

    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = w.toArrayList();

    if (ui.isTty()) drawProgress(&w.writer, 512, 1024, 1);
    var got_buf: [32]u8 = undefined;
    try w.writer.print("{s}{s}{s} downloaded {s}\n", .{
        ui.on(.green),
        ui.check,
        ui.off(),
        humanBytes(1024, &got_buf),
    });

    try std.testing.expectEqualStrings("✓ downloaded 1.0 KB\n", w.written());
}

test "findAssetSize reads the size beside the download url" {
    const body =
        \\{"assets":[{"name":"sdt-macos-arm64","size":4194304,"browser_download_url":"https://x/bin"},
        \\{"name":"sdt-linux-x64","size":0,"browser_download_url":"https://x/other"},
        \\{"name":"sdt-macos-arm64.sha256","browser_download_url":"https://x/sum"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const assets = parsed.value.object.get("assets").?.array;

    try std.testing.expectEqual(@as(?u64, 4 * 1024 * 1024), findAssetSize(assets, "sdt-macos-arm64"));
    try std.testing.expectEqual(@as(?u64, null), findAssetSize(assets, "sdt-linux-x64"));
    try std.testing.expectEqual(@as(?u64, null), findAssetSize(assets, "sdt-macos-arm64.sha256"));
    try std.testing.expectEqual(@as(?u64, null), findAssetSize(assets, "nope"));
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

test "asset names follow the current binary" {
    const name = assetName() orelse return;
    try std.testing.expect(std.mem.startsWith(u8, name, "sdt-"));
}
