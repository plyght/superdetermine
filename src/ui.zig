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
