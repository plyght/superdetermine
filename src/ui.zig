const std = @import("std");

var enabled: bool = false;
var tty: bool = false;

pub const Color = enum {
    dim,
    bold,
    red,
    green,
    yellow,
    blue,
    cyan,
    magenta,

    fn code(self: Color) []const u8 {
        return switch (self) {
            .dim => "\x1b[2m",
            .bold => "\x1b[1m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .cyan => "\x1b[36m",
            .magenta => "\x1b[35m",
        };
    }
};

pub fn init(io: std.Io, file: std.Io.File) void {
    enabled = decide(io, file);
    tty = decideTty(io, file);
}

fn decideTty(io: std.Io, file: std.Io.File) bool {
    if (std.c.getenv("TERM")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "dumb")) return false;
    }
    return file.supportsAnsiEscapeCodes(io) catch false;
}

fn decide(io: std.Io, file: std.Io.File) bool {
    if (std.c.getenv("NO_COLOR")) |v| {
        if (std.mem.span(v).len != 0) return false;
    }
    if (std.c.getenv("CLICOLOR_FORCE")) |v| {
        const s = std.mem.span(v);
        if (s.len != 0 and !std.mem.eql(u8, s, "0")) return true;
    }
    if (std.c.getenv("TERM")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "dumb")) return false;
    }
    return file.supportsAnsiEscapeCodes(io) catch false;
}

pub fn isEnabled() bool {
    return enabled;
}

pub fn setEnabled(value: bool) void {
    enabled = value;
}

pub fn isTty() bool {
    return tty;
}

pub fn setTty(value: bool) void {
    tty = value;
}

pub fn on(color: Color) []const u8 {
    return if (enabled) color.code() else "";
}

pub fn off() []const u8 {
    return if (enabled) "\x1b[0m" else "";
}

pub fn paint(w: *std.Io.Writer, color: Color, text: []const u8) !void {
    try w.print("{s}{s}{s}", .{ on(color), text, off() });
}

pub fn heading(w: *std.Io.Writer, text: []const u8) !void {
    try w.print("{s}{s}{s}\n", .{ on(.bold), text, off() });
}

pub fn hint(w: *std.Io.Writer, text: []const u8) !void {
    try w.print("{s}{s}{s}\n", .{ on(.dim), text, off() });
}

pub fn note(w: *std.Io.Writer, symbol: []const u8, color: Color, text: []const u8) !void {
    try w.print("{s}{s}{s} {s}\n", .{ on(color), symbol, off(), text });
}

pub const bar_cells = 24;
pub const redraw_interval_ms = 80;
pub const label_width = 18;

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const partial_cells = [_][]const u8{ "", "▏", "▎", "▍", "▌", "▋", "▊", "▉" };

pub const Unit = enum { bytes, count };

pub const spinner_frame_count = spinner_frames.len;

pub fn spinner(tick: usize) []const u8 {
    return spinner_frames[tick % spinner_frames.len];
}

pub fn humanBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var v: f64 = @floatFromInt(bytes);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    if (i == 0) return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[i] }) catch unreachable;
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) catch unreachable;
}

fn amount(v: u64, unit: Unit, buf: []u8) []const u8 {
    return switch (unit) {
        .bytes => humanBytes(v, buf),
        .count => std.fmt.bufPrint(buf, "{d}", .{v}) catch unreachable,
    };
}

/// A bar when the total is known, a spinner when it is not. Never a fake
/// denominator: an unknown total shows what has actually arrived so far.
pub fn renderProgress(
    buf: []u8,
    done_raw: u64,
    total: ?u64,
    cells: usize,
    tick: usize,
    unit: Unit,
) []const u8 {
    var out = std.Io.Writer.fixed(buf);
    const known = if (total) |t| (if (t == 0) null else t) else null;

    if (known == null) {
        var got_buf: [32]u8 = undefined;
        out.print("{s}{s}{s} {s}{s}{s}", .{
            on(.cyan),
            spinner(tick),
            off(),
            on(.dim),
            amount(done_raw, unit, &got_buf),
            off(),
        }) catch unreachable;
        return out.buffered();
    }

    const t = known.?;
    const done = @min(done_raw, t);
    const pct = (done * 100) / t;
    const eighths = (done * cells * 8) / t;
    const full = @min(eighths / 8, cells);
    const part = if (full == cells) 0 else eighths % 8;
    const empty = cells - full - @intFromBool(part != 0);

    var got_buf: [32]u8 = undefined;
    var want_buf: [32]u8 = undefined;
    out.print("{s}", .{on(.green)}) catch unreachable;
    out.splatBytesAll("█", @intCast(full)) catch unreachable;
    if (part != 0) out.writeAll(partial_cells[@intCast(part)]) catch unreachable;
    out.print("{s}{s}", .{ off(), on(.dim) }) catch unreachable;
    out.splatBytesAll("░", @intCast(empty)) catch unreachable;
    out.print("{s}  {s}{d:>3}%{s}  {s}{s} / {s}{s}", .{
        off(),
        on(.bold),
        pct,
        off(),
        on(.dim),
        amount(done, unit, &got_buf),
        amount(t, unit, &want_buf),
        off(),
    }) catch unreachable;
    return out.buffered();
}

/// Redraw the current terminal row with `label` and a bar. Labels are padded to
/// a common width so the bars of successive phases line up.
pub fn drawProgress(
    w: *std.Io.Writer,
    label: []const u8,
    done: u64,
    total: ?u64,
    tick: usize,
    unit: Unit,
) void {
    var buf: [512]u8 = undefined;
    const line = renderProgress(&buf, done, total, bar_cells, tick, unit);
    w.print("\x1b[2K\r{s}{s}{s}", .{ on(.dim), label, off() }) catch return;
    pad(w, label, label_width) catch return;
    w.print(" {s}", .{line}) catch return;
    w.flush() catch {};
}

pub fn clearProgress(w: *std.Io.Writer) void {
    w.writeAll("\x1b[2K\r") catch return;
    w.flush() catch {};
}

pub const check = "✓";
pub const cross = "✗";
pub const warn = "!";
pub const arrow = "→";
pub const bullet = "·";
pub const branch_mark = "●";

/// Visible width of `s`, ignoring ANSI escape sequences and counting a UTF-8
/// sequence as one column. Good enough for the short, mostly-ASCII strings the
/// CLI aligns; it does not attempt full east-asian width handling.
pub fn width(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            while (i < s.len and s[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        if (s[i] & 0xc0 != 0x80) n += 1;
        i += 1;
    }
    return n;
}

pub fn pad(w: *std.Io.Writer, s: []const u8, to: usize) !void {
    const n = width(s);
    if (n >= to) return;
    try w.splatByteAll(' ', to - n);
}

// --- tests ---

const testing = std.testing;

test "escape codes vanish when color is off" {
    const prev = enabled;
    defer setEnabled(prev);

    setEnabled(false);
    try testing.expectEqualStrings("", on(.red));
    try testing.expectEqualStrings("", off());

    setEnabled(true);
    try testing.expectEqualStrings("\x1b[31m", on(.red));
    try testing.expectEqualStrings("\x1b[0m", off());
}

test "width ignores escapes and counts utf-8 runes once" {
    try testing.expectEqual(@as(usize, 3), width("abc"));
    try testing.expectEqual(@as(usize, 3), width("\x1b[31mabc\x1b[0m"));
    try testing.expectEqual(@as(usize, 1), width(check));
    try testing.expectEqual(@as(usize, 1), width(arrow));
    try testing.expectEqual(@as(usize, 5), width("a\x1b[1mb\x1b[0mcde"));
}

test "counts are rendered as counts, not byte sizes" {
    const prev = enabled;
    defer setEnabled(prev);
    setEnabled(false);

    var buf: [512]u8 = undefined;
    try testing.expectEqualStrings(
        "████░░░░   50%  512 / 1024",
        renderProgress(&buf, 512, 1024, 8, 0, .count),
    );
    try testing.expectEqualStrings("⠋ 512", renderProgress(&buf, 512, null, 8, 0, .count));
}

test "a drawn line pads its label so successive bars line up" {
    const prev_color = enabled;
    const prev_tty = tty;
    defer setEnabled(prev_color);
    defer setTty(prev_tty);
    setEnabled(false);
    setTty(true);

    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = w.toArrayList();

    drawProgress(&w.writer, "checking out", 1, 2, 0, .count);
    const line = w.written();
    const bar_at = std.mem.indexOf(u8, line, "█").?;
    try testing.expectEqual(@as(usize, "\x1b[2K\r".len + label_width + 1), bar_at);
}

test "pad fills to the visible width" {
    const alloc = testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var w = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = w.toArrayList();

    try w.writer.writeAll("ab");
    try pad(&w.writer, "ab", 5);
    try w.writer.writeAll("|");
    try testing.expectEqualStrings("ab   |", w.written());
}
