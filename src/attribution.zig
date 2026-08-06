const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const Store = @import("store.zig").Store;
const workspace = @import("workspace.zig");
const agentscan = @import("agentscan.zig");
const config = @import("config.zig");
const Oid = oid.Oid;

/// Per-file human-vs-agent attribution.
///
/// The prompt-level `provenance` sidecar is per-change-OID: too coarse to say
/// "file A was written by an agent, file B by the human" within one save. This
/// records, per (change-OID, file-path), whether that file was authored by the
/// HUMAN or by a specific AGENT — and, for agents, with what confidence:
///   certain — the file's current content BLAKE3 matched an agent write event.
///   likely  — the path matched an agent edit but content couldn't be confirmed.
///
/// Stored append-only in `.gr/attribution`, one record per line, in the same
/// spirit and escaping as `provenance`:
///   <change-hex-64> <unix_ms> <kind> <conf> <path>\t<agent>\t<session>\t<prompt>\n
/// Every free-text field is escaped so tabs/newlines can't break the framing.
pub const Kind = enum { human, agent };
pub const Confidence = enum { none, likely, certain };

pub const FileEntry = struct {
    kind: Kind,
    confidence: Confidence,
    agent: []const u8,
    session: []const u8,
    prompt: []const u8,
    path: []const u8,
    timestamp_ms: i64,
};

pub fn freeEntry(alloc: std.mem.Allocator, e: FileEntry) void {
    alloc.free(e.agent);
    alloc.free(e.session);
    alloc.free(e.prompt);
    alloc.free(e.path);
}

// --- escaping (mirrors provenance.zig) ---

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

// --- record / read ---

/// Append one per-file attribution record, in time independent of log length.
pub fn record(store: *Store, change: Oid, entry: FileEntry) !void {
    const alloc = store.alloc;

    const path_esc = try escape(alloc, entry.path);
    defer alloc.free(path_esc);
    const agent_esc = try escape(alloc, entry.agent);
    defer alloc.free(agent_esc);
    const session_esc = try escape(alloc, entry.session);
    defer alloc.free(session_esc);
    const prompt_esc = try escape(alloc, entry.prompt);
    defer alloc.free(prompt_esc);

    var hex: [Oid.len * 2]u8 = undefined;
    _ = change.toHex(&hex);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.print(alloc, "{s} {d} {s} {s} {s}\t{s}\t{s}\t{s}\n", .{
        &hex,
        entry.timestamp_ms,
        @tagName(entry.kind),
        @tagName(entry.confidence),
        path_esc,
        agent_esc,
        session_esc,
        prompt_esc,
    });

    try applog.append(store, "attribution", out.items);
}

const Parsed = struct { change: [Oid.len * 2]u8, entry: FileEntry };

fn parseLine(alloc: std.mem.Allocator, raw: []const u8) !?Parsed {
    const sp1 = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    const hex_str = raw[0..sp1];
    if (hex_str.len != Oid.len * 2) return null;
    var rest = raw[sp1 + 1 ..];

    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const ts = std.fmt.parseInt(i64, rest[0..sp2], 10) catch return null;
    rest = rest[sp2 + 1 ..];

    const sp3 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const kind = std.meta.stringToEnum(Kind, rest[0..sp3]) orelse return null;
    rest = rest[sp3 + 1 ..];

    const sp4 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const conf = std.meta.stringToEnum(Confidence, rest[0..sp4]) orelse return null;
    rest = rest[sp4 + 1 ..];

    // path\tagent\tsession\tprompt
    const t1 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const path = try unescape(alloc, rest[0..t1]);
    errdefer alloc.free(path);
    rest = rest[t1 + 1 ..];
    const t2 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const agent = try unescape(alloc, rest[0..t2]);
    errdefer alloc.free(agent);
    rest = rest[t2 + 1 ..];
    const t3 = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
    const session = try unescape(alloc, rest[0..t3]);
    errdefer alloc.free(session);
    const prompt = try unescape(alloc, rest[t3 + 1 ..]);
    errdefer alloc.free(prompt);

    var hex: [Oid.len * 2]u8 = undefined;
    @memcpy(&hex, hex_str);
    return .{ .change = hex, .entry = .{
        .kind = kind,
        .confidence = conf,
        .agent = agent,
        .session = session,
        .prompt = prompt,
        .path = path,
        .timestamp_ms = ts,
    } };
}

/// The last recorded attribution for (change, path), or null. Caller frees.
pub fn get(store: *Store, alloc: std.mem.Allocator, change: Oid, path: []const u8) !?FileEntry {
    var hex: [Oid.len * 2]u8 = undefined;
    _ = change.toHex(&hex);

    const data = store.root.readFileAlloc(store.io, "attribution", alloc, .unlimited) catch return null;
    defer alloc.free(data);

    var found: ?FileEntry = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = (try parseLine(alloc, raw)) orelse continue;
        if (std.mem.eql(u8, &parsed.change, &hex) and std.mem.eql(u8, parsed.entry.path, path)) {
            if (found) |e| freeEntry(alloc, e);
            found = parsed.entry;
        } else {
            freeEntry(alloc, parsed.entry);
        }
    }
    return found;
}

/// The most recent attribution for `path` across all changes (file order = save
/// order), or null. This answers "who last authored this file". Caller frees.
pub fn lastForPath(store: *Store, alloc: std.mem.Allocator, path: []const u8) !?FileEntry {
    const data = store.root.readFileAlloc(store.io, "attribution", alloc, .unlimited) catch return null;
    defer alloc.free(data);

    var found: ?FileEntry = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const parsed = (try parseLine(alloc, raw)) orelse continue;
        if (std.mem.eql(u8, parsed.entry.path, path)) {
            if (found) |e| freeEntry(alloc, e);
            found = parsed.entry;
        } else {
            freeEntry(alloc, parsed.entry);
        }
    }
    return found;
}

// --- attribution logic ---

/// Pick the best matching event for an absolute path + current content hash.
/// Returns the chosen event index and confidence, or null for HUMAN.
fn bestMatch(events: []const agentscan.EditEvent, repo_abs: []const u8, abs_path: []const u8, content_hash: Oid) ?struct { idx: usize, conf: Confidence } {
    var certain: ?usize = null;
    var likely: ?usize = null;
    var identity: ?usize = null; // repo-wide event (path == repo dir), e.g. aider
    for (events, 0..) |e, i| {
        if (std.mem.eql(u8, e.path, repo_abs)) {
            if (identity == null or e.timestamp_ms > events[identity.?].timestamp_ms) identity = i;
            continue;
        }
        if (!std.mem.eql(u8, e.path, abs_path)) continue;
        if (e.new_hash) |h| {
            if (h.eql(content_hash)) {
                if (certain == null or e.timestamp_ms > events[certain.?].timestamp_ms) certain = i;
                continue;
            }
        }
        // Path matches but content unconfirmed → best-effort timing candidate.
        if (likely == null or e.timestamp_ms > events[likely.?].timestamp_ms) likely = i;
    }
    if (certain) |i| return .{ .idx = i, .conf = .certain };
    if (likely) |i| return .{ .idx = i, .conf = .likely };
    if (identity) |i| return .{ .idx = i, .conf = .likely };
    return null;
}

/// Is passive auto-scan enabled? Config `provenance.autoscan`, default ON. Any
/// falsy value turns it into a no-op.
fn autoscanEnabled(store: *Store, alloc: std.mem.Allocator) bool {
    const v = (config.get(store, alloc, "provenance.autoscan") catch return true) orelse return true;
    defer alloc.free(v);
    if (std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no")) return false;
    return true;
}

/// Passively attribute every changed file in a save. Never fails a save: any
/// error is swallowed by the caller (this returns void and swallows internally).
/// `changed` is the working-tree status captured BEFORE the snapshot.
pub fn autoAttribute(store: *Store, work_dir: std.Io.Dir, change: Oid, changed: []const workspace.StatusEntry) void {
    const io = store.io;
    const alloc = store.alloc;

    if (changed.len == 0) return;
    if (!autoscanEnabled(store, alloc)) return;

    const repo_abs = work_dir.realPathFileAlloc(io, ".", alloc) catch return;
    defer alloc.free(repo_abs);
    const repo_trim = std.mem.trimEnd(u8, repo_abs, "/");

    const now_ms = @as(i64, @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000)));
    // Look back a few hours: cheap because file scanning is gated by mtime.
    const since_ms = now_ms - 6 * 60 * 60 * 1000;

    const events = agentscan.scan(alloc, io, repo_trim, since_ms) catch return;
    defer agentscan.freeEvents(alloc, events);

    for (changed) |entry| {
        // Deleted files have no content to hash or match — skip.
        if (entry.kind == .deleted) continue;

        const abs = std.fs.path.join(alloc, &.{ repo_trim, entry.path }) catch continue;
        defer alloc.free(abs);

        const content = work_dir.readFileAlloc(io, entry.path, alloc, .unlimited) catch continue;
        defer alloc.free(content);
        const hash = Oid.ofBytes(content);

        const rec: FileEntry = if (bestMatch(events, repo_trim, abs, hash)) |m| .{
            .kind = .agent,
            .confidence = m.conf,
            .agent = events[m.idx].agent,
            .session = events[m.idx].session,
            .prompt = events[m.idx].prompt,
            .path = entry.path,
            .timestamp_ms = events[m.idx].timestamp_ms,
        } else .{
            .kind = .human,
            .confidence = .none,
            .agent = "",
            .session = "",
            .prompt = "",
            .path = entry.path,
            .timestamp_ms = now_ms,
        };
        record(store, change, rec) catch {};
    }
}

// --- tests ---

const testing = std.testing;

test "record + get roundtrip with escaping" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("chg");
    try record(&s, change, .{
        .kind = .agent,
        .confidence = .certain,
        .agent = "claude-code",
        .session = "sess-1",
        .prompt = "make it\tblue\nplease",
        .path = "src/a.zig",
        .timestamp_ms = 1720000000000,
    });

    const got = (try get(&s, alloc, change, "src/a.zig")).?;
    defer freeEntry(alloc, got);
    try testing.expectEqual(Kind.agent, got.kind);
    try testing.expectEqual(Confidence.certain, got.confidence);
    try testing.expectEqualStrings("claude-code", got.agent);
    try testing.expectEqualStrings("sess-1", got.session);
    try testing.expectEqualStrings("make it\tblue\nplease", got.prompt);
    try testing.expectEqualStrings("src/a.zig", got.path);
    try testing.expectEqual(@as(i64, 1720000000000), got.timestamp_ms);
}

test "human record and per-path last-wins" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try record(&s, Oid.ofBytes("c1"), .{
        .kind = .agent,
        .confidence = .likely,
        .agent = "pi",
        .session = "x",
        .prompt = "p",
        .path = "f.txt",
        .timestamp_ms = 1,
    });
    try record(&s, Oid.ofBytes("c2"), .{
        .kind = .human,
        .confidence = .none,
        .agent = "",
        .session = "",
        .prompt = "",
        .path = "f.txt",
        .timestamp_ms = 2,
    });

    const last = (try lastForPath(&s, alloc, "f.txt")).?;
    defer freeEntry(alloc, last);
    try testing.expectEqual(Kind.human, last.kind);
}

test "bestMatch: content hash beats timing; no match = human" {
    const content = "hello world";
    const h = Oid.ofBytes(content);

    var events = [_]agentscan.EditEvent{
        // path matches, content matches → certain
        .{ .agent = "claude-code", .session = "s", .prompt = "p", .path = "/repo/a.txt", .new_hash = h, .timestamp_ms = 100 },
        // path matches, no hash → likely (older)
        .{ .agent = "pi", .session = "s2", .prompt = "p2", .path = "/repo/a.txt", .new_hash = null, .timestamp_ms = 50 },
    };
    const m = bestMatch(&events, "/repo", "/repo/a.txt", h).?;
    try testing.expectEqual(Confidence.certain, m.conf);
    try testing.expectEqualStrings("claude-code", events[m.idx].agent);

    // A path with no events at all → human (null).
    try testing.expect(bestMatch(&events, "/repo", "/repo/other.txt", h) == null);

    // Path match but content differs → likely.
    var only_likely = [_]agentscan.EditEvent{
        .{ .agent = "pi", .session = "s", .prompt = "p", .path = "/repo/b.txt", .new_hash = Oid.ofBytes("different"), .timestamp_ms = 10 },
    };
    const m2 = bestMatch(&only_likely, "/repo", "/repo/b.txt", h).?;
    try testing.expectEqual(Confidence.likely, m2.conf);

    // Repo-wide identity event (aider) is a last resort → likely.
    var identity = [_]agentscan.EditEvent{
        .{ .agent = "aider", .session = "", .prompt = "", .path = "/repo", .new_hash = null, .timestamp_ms = 5 },
    };
    const m3 = bestMatch(&identity, "/repo", "/repo/c.txt", h).?;
    try testing.expectEqual(Confidence.likely, m3.conf);
    try testing.expectEqualStrings("aider", identity[m3.idx].agent);
}
