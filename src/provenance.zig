const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Prompt-level provenance: which agent instruction produced which change.
///
/// Stored in an append-only sidecar `.gr/provenance`, one record per line, so
/// it never touches the object model or git interop. Each line is:
///   <change-hex-64> <unix_ts> <agent-escaped>\t<prompt-escaped>\n
/// Agent and prompt are escaped (`\`→`\\`, `\n`→`\n`, `\t`→`\t`) so neither can
/// contain a literal tab or newline; the record framing stays unambiguous.
pub const Entry = struct { agent: []const u8, prompt: []const u8, timestamp: i64 };

fn escape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, ch),
    };
    return out.toOwnedSlice(alloc);
}

fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, s[i]),
            }
        } else {
            try out.append(alloc, s[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Append a provenance record for `change`, in time independent of log length.
pub fn record(store: *Store, change: Oid, agent: []const u8, prompt: []const u8, timestamp: i64) !void {
    const alloc = store.alloc;

    const agent_esc = try escape(alloc, agent);
    defer alloc.free(agent_esc);
    const prompt_esc = try escape(alloc, prompt);
    defer alloc.free(prompt_esc);

    var hex: [Oid.len * 2]u8 = undefined;
    _ = change.toHex(&hex);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.print(alloc, "{s} {d} {s}\t{s}\n", .{ &hex, timestamp, agent_esc, prompt_esc });

    try applog.append(store, "provenance", out.items);
}

/// Return the LAST record for `change` (so an amend/re-record overrides), or
/// null if none. Caller frees `.agent` and `.prompt` (see `freeEntry`).
pub fn get(store: *Store, alloc: std.mem.Allocator, change: Oid) !?Entry {
    var hex: [Oid.len * 2]u8 = undefined;
    _ = change.toHex(&hex);

    const data = store.root.readFileAlloc(store.io, "provenance", alloc, .unlimited) catch return null;
    defer alloc.free(data);

    var found: ?Entry = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = (try parseLine(alloc, raw)) orelse continue;
        if (std.mem.eql(u8, &parsed.hex, &hex)) {
            if (found) |e| freeEntry(alloc, e);
            found = parsed.entry;
        } else {
            freeEntry(alloc, parsed.entry);
        }
    }
    return found;
}

const Parsed = struct { hex: [Oid.len * 2]u8, entry: Entry };

fn parseLine(alloc: std.mem.Allocator, raw: []const u8) !?Parsed {
    const sp1 = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    const hex_str = raw[0..sp1];
    if (hex_str.len != Oid.len * 2) return null;
    const rest = raw[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const ts = std.fmt.parseInt(i64, rest[0..sp2], 10) catch return null;
    const tail = rest[sp2 + 1 ..];
    const tab = std.mem.indexOfScalar(u8, tail, '\t') orelse return null;

    const agent = try unescape(alloc, tail[0..tab]);
    errdefer alloc.free(agent);
    const prompt = try unescape(alloc, tail[tab + 1 ..]);
    errdefer alloc.free(prompt);

    var hex: [Oid.len * 2]u8 = undefined;
    @memcpy(&hex, hex_str);
    return .{ .hex = hex, .entry = .{ .agent = agent, .prompt = prompt, .timestamp = ts } };
}

pub fn freeEntry(alloc: std.mem.Allocator, entry: Entry) void {
    alloc.free(entry.agent);
    alloc.free(entry.prompt);
}

/// A change Oid paired with its provenance record, for a future listing.
pub const Record = struct { change: Oid, entry: Entry };

/// All records in file order. Caller frees with `freeAll`.
pub fn all(store: *Store, alloc: std.mem.Allocator) ![]Record {
    var out: std.ArrayList(Record) = .empty;
    errdefer {
        for (out.items) |r| freeEntry(alloc, r.entry);
        out.deinit(alloc);
    }

    const data = store.root.readFileAlloc(store.io, "provenance", alloc, .unlimited) catch
        return out.toOwnedSlice(alloc);
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = (try parseLine(alloc, raw)) orelse continue;
        const change = Oid.fromHex(&parsed.hex) catch {
            freeEntry(alloc, parsed.entry);
            continue;
        };
        try out.append(alloc, .{ .change = change, .entry = parsed.entry });
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeAll(alloc: std.mem.Allocator, records: []Record) void {
    for (records) |r| freeEntry(alloc, r.entry);
    alloc.free(records);
}

// --- tests ---

const testing = std.testing;

test "record + get roundtrip" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("a change");
    try record(&s, change, "claude", "make the button blue", 1720000000);

    const got = (try get(&s, alloc, change)).?;
    defer freeEntry(alloc, got);
    try testing.expectEqualStrings("claude", got.agent);
    try testing.expectEqualStrings("make the button blue", got.prompt);
    try testing.expectEqual(@as(i64, 1720000000), got.timestamp);
}

test "prompt with newlines and tabs roundtrips exactly" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("c2");
    const prompt = "line1\nline2\twith tab\n\tand a backslash \\ end";
    const agent = "agent\twith\ttabs";
    try record(&s, change, agent, prompt, 42);

    const got = (try get(&s, alloc, change)).?;
    defer freeEntry(alloc, got);
    try testing.expectEqualStrings(agent, got.agent);
    try testing.expectEqualStrings(prompt, got.prompt);
    try testing.expectEqual(@as(i64, 42), got.timestamp);
}

test "get of unrecorded change is null" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try testing.expect((try get(&s, alloc, Oid.ofBytes("nope"))) == null);

    // Also null after other changes exist but not this one.
    try record(&s, Oid.ofBytes("other"), "a", "b", 1);
    try testing.expect((try get(&s, alloc, Oid.ofBytes("nope"))) == null);
}

test "re-record overrides with newer entry" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("amend me");
    try record(&s, change, "claude", "first prompt", 100);
    try record(&s, change, "opus", "second prompt", 200);

    const got = (try get(&s, alloc, change)).?;
    defer freeEntry(alloc, got);
    try testing.expectEqualStrings("opus", got.agent);
    try testing.expectEqualStrings("second prompt", got.prompt);
    try testing.expectEqual(@as(i64, 200), got.timestamp);
}

test "all lists every record in order" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    // empty file → empty slice
    const empty = try all(&s, alloc);
    defer freeAll(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    const c1 = Oid.ofBytes("one");
    const c2 = Oid.ofBytes("two");
    try record(&s, c1, "a1", "p1", 1);
    try record(&s, c2, "a2", "p2", 2);

    const recs = try all(&s, alloc);
    defer freeAll(alloc, recs);
    try testing.expectEqual(@as(usize, 2), recs.len);
    try testing.expect(recs[0].change.eql(c1));
    try testing.expect(recs[1].change.eql(c2));
    try testing.expectEqualStrings("p1", recs[0].entry.prompt);
}
