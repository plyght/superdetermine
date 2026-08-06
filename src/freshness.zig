const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const config = @import("config.zig");
const oplog = @import("oplog.zig");
const proc = @import("proc.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Freshness: staleness as a property of the work, not an event to notice.
///
/// The problem is not that remotes move. It is that you find out they moved
/// after you have already written three hours of code on top of a base that no
/// longer exists. Git's answer is a habit ("fetch first"), which is exactly the
/// kind of answer that fails whenever the person is busy or is an agent.
///
/// The answer here is a record. Every `sdt` command that runs after the last
/// look has gone stale fires a refs-only probe alongside its real work, and the
/// result is appended to `.sdt/remote-refs`. Because the snapshot is timestamped
/// and durable, "was this written on top of current code?" is a question you can
/// ask about any moment after the fact, rather than a question you had to think
/// to ask beforehand.
///
/// There is no daemon. A probe is one `git ls-remote` round trip carrying a few
/// hundred bytes of refs and zero objects, which is cheap enough to hang off
/// ordinary commands and stay invisible.
///
/// Log format, one snapshot per line in `.sdt/remote-refs`:
///   <unix_ms> <remote-escaped> <name-escaped>=<oid_hex> <name-escaped>=<oid_hex>...\n
/// Remote and ref names are escaped the way `provenance.zig` escapes free text
/// (`\`→`\\`, newline→`\n`, tab→`\t`) plus the two delimiters this format adds
/// (space→`\s`, `=`→`\e`), so no ref name can break the framing.
pub const Entry = struct { name: []const u8, oid_hex: []const u8 };

/// A snapshot of a remote's advertised refs. Owns its strings.
pub const RemoteRefs = struct {
    entries: []Entry,

    /// Free every entry's strings and the backing slice.
    pub fn deinit(self: RemoteRefs, alloc: std.mem.Allocator) void {
        for (self.entries) |e| {
            alloc.free(e.name);
            alloc.free(e.oid_hex);
        }
        alloc.free(self.entries);
    }

    /// The oid recorded for `name`, or null when the snapshot lacks that ref.
    pub fn find(self: RemoteRefs, name: []const u8) ?[]const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.oid_hex;
        }
        return null;
    }
};

pub const Error = error{
    LsRemoteFailed,
};

pub const log_path = "remote-refs";

// --- escaping ---

fn escape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        ' ' => try out.appendSlice(alloc, "\\s"),
        '=' => try out.appendSlice(alloc, "\\e"),
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
                's' => try out.append(alloc, ' '),
                'e' => try out.append(alloc, '='),
                else => try out.append(alloc, s[i]),
            }
        } else {
            try out.append(alloc, s[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// --- the refs log ---

/// Append a refs snapshot for `remote`, taken at unix-milliseconds `ms`.
/// Append-only and O(1) in the log's length, like every other log.
pub fn record(store: *Store, remote: []const u8, refs: RemoteRefs, ms: i64) !void {
    const alloc = store.alloc;

    const remote_esc = try escape(alloc, remote);
    defer alloc.free(remote_esc);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    try line.print(alloc, "{d} {s}", .{ ms, remote_esc });
    for (refs.entries) |e| {
        const name_esc = try escape(alloc, e.name);
        defer alloc.free(name_esc);
        try line.print(alloc, " {s}={s}", .{ name_esc, e.oid_hex });
    }
    try line.append(alloc, '\n');

    try applog.append(store, log_path, line.items);
}

const Snapshot = struct { ms: i64, remote: []u8, refs: RemoteRefs };

fn freeSnapshot(alloc: std.mem.Allocator, s: Snapshot) void {
    alloc.free(s.remote);
    s.refs.deinit(alloc);
}

/// Parse one log line. Malformed lines yield null rather than an error, so a
/// single torn append cannot make the whole record unreadable.
fn parseLine(alloc: std.mem.Allocator, line: []const u8) !?Snapshot {
    var it = std.mem.splitScalar(u8, line, ' ');
    const ms_s = it.next() orelse return null;
    const ms = std.fmt.parseInt(i64, ms_s, 10) catch return null;
    const remote_s = it.next() orelse return null;

    const remote = try unescape(alloc, remote_s);
    errdefer alloc.free(remote);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.name);
            alloc.free(e.oid_hex);
        }
        entries.deinit(alloc);
    }

    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        // The name's own `=` characters are escaped, so the first literal `=`
        // is always the separator.
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const name = try unescape(alloc, pair[0..eq]);
        errdefer alloc.free(name);
        const hex = try alloc.dupe(u8, pair[eq + 1 ..]);
        try entries.append(alloc, .{ .name = name, .oid_hex = hex });
    }

    return .{
        .ms = ms,
        .remote = remote,
        .refs = .{ .entries = try entries.toOwnedSlice(alloc) },
    };
}

/// The most recent snapshot recorded for `remote`, or null if we have never
/// looked. Caller frees with `RemoteRefs.deinit`.
pub fn latest(store: *Store, alloc: std.mem.Allocator, remote: []const u8) !?RemoteRefs {
    const data = try applog.readAll(store, alloc, log_path);
    defer alloc.free(data);

    var found: ?RemoteRefs = null;
    errdefer if (found) |f| f.deinit(alloc);

    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const snap = (try parseLine(alloc, line)) orelse continue;
        if (std.mem.eql(u8, snap.remote, remote)) {
            if (found) |f| f.deinit(alloc);
            alloc.free(snap.remote);
            found = snap.refs;
        } else {
            freeSnapshot(alloc, snap);
        }
    }
    return found;
}

/// Unix milliseconds of the newest snapshot of any remote, or null when the log
/// is empty. The log is chronological, so the last parseable line wins.
pub fn lastLookMs(store: *Store, alloc: std.mem.Allocator) ?i64 {
    const data = applog.readAll(store, alloc, log_path) catch return null;
    defer alloc.free(data);

    var out: ?i64 = null;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        out = std.fmt.parseInt(i64, line[0..sp], 10) catch continue;
    }
    return out;
}

// --- refs-only fetch ---

/// Parse `git ls-remote` output: one `<oid_hex>\t<refname>` line per ref.
///
/// Split out from `fetchRefsOnly` so the parser is testable without a network:
/// the transport is one process call, the meaning is all here. Lines that are
/// not a hex oid followed by a tab (banners, `ref: refs/heads/main\tHEAD`
/// symref lines, warnings on stdout) are skipped rather than fatal.
pub fn parseLsRemote(alloc: std.mem.Allocator, text: []const u8) !RemoteRefs {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| {
            alloc.free(e.name);
            alloc.free(e.oid_hex);
        }
        entries.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const hex = line[0..tab];
        // sha1 (40) or sha256 (64) object names; anything else is not a ref.
        if (hex.len != 40 and hex.len != 64) continue;
        if (!isHex(hex)) continue;
        const name = std.mem.trim(u8, line[tab + 1 ..], " \t");
        if (name.len == 0) continue;

        const name_owned = try alloc.dupe(u8, name);
        errdefer alloc.free(name_owned);
        const hex_owned = try alloc.dupe(u8, hex);
        try entries.append(alloc, .{ .name = name_owned, .oid_hex = hex_owned });
    }

    return .{ .entries = try entries.toOwnedSlice(alloc) };
}

fn isHex(s: []const u8) bool {
    for (s) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

/// Ask a remote what refs it has, and nothing else.
///
/// `git ls-remote` is used deliberately: it is the one git operation that
/// transfers refs ONLY. Exactly one round trip, a few hundred bytes on the
/// wire, no object negotiation, no packfile, no working-tree touch, no hooks,
/// no daemon and no background process to supervise. That is what makes it
/// affordable to run alongside every ordinary command instead of asking a human
/// to remember to fetch. `proc.capture` runs it without a shell, so a hostile
/// remote URL can never be interpreted as a command.
///
/// Caller frees with `RemoteRefs.deinit`.
pub fn fetchRefsOnly(alloc: std.mem.Allocator, remote_url: []const u8) !RemoteRefs {
    const out = proc.capture(alloc, &.{ "git", "ls-remote", remote_url }, "") catch
        return Error.LsRemoteFailed;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.LsRemoteFailed;
    return parseLsRemote(alloc, out.stdout);
}

// --- settings ---

pub const Settings = struct {
    /// How long a refs snapshot stays trustworthy, in milliseconds.
    freshen_ms: i64 = 60_000,
    /// Whether a detected divergence may be pulled without being asked.
    autopull: enum { never, always } = .never,
};

/// Read `remote.freshen_ms` and `remote.autopull` from config. Unparseable
/// values fall back to the default rather than erroring, because a typo in
/// config must not take freshness down.
pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "remote.freshen_ms")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.freshen_ms = std.fmt.parseInt(i64, v, 10) catch out.freshen_ms;
        }
    } else |_| {}
    if (config.get(store, alloc, "remote.autopull")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            if (std.mem.eql(u8, v, "always")) out.autopull = .always;
        }
    } else |_| {}
    return out;
}

// --- staleness ---

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

/// True when the last refs snapshot is older than `freshen_ms`, and true when
/// there is no snapshot at all: a repo that has never looked is maximally
/// stale, not fresh.
///
/// This reads one local file and never touches the network, which is the whole
/// point: the predicate is cheap enough to consult on every command, and the
/// probe it triggers runs alongside the command's real work rather than in
/// front of it.
pub fn isStale(store: *Store, alloc: std.mem.Allocator, set: Settings) bool {
    const last = lastLookMs(store, alloc) orelse return true;
    return nowMillis(store.io) - last > set.freshen_ms;
}

/// What the CLI consults before deciding to fire a refs-only probe concurrently
/// with the command the user actually asked for. Never blocks on network.
pub fn shouldFreshen(store: *Store, alloc: std.mem.Allocator, set: Settings) bool {
    return isStale(store, alloc, set);
}

// --- divergence ---

/// Which refs moved between two snapshots. `changed` owns its strings.
pub const Divergence = struct {
    /// The remote has refs we had not seen, or moved refs we had seen: our
    /// recorded base is behind it.
    behind: bool,
    /// A ref we had recorded is gone from the remote, so our record holds
    /// something the remote no longer advertises.
    ahead: bool,
    changed: []const []const u8,
};

/// Free a `Divergence` produced by `compare`.
pub fn freeDivergence(alloc: std.mem.Allocator, d: Divergence) void {
    for (d.changed) |c| alloc.free(c);
    alloc.free(d.changed);
}

/// Which refs moved since we last looked. Added and modified refs both mean
/// "behind"; a ref that vanished means the remote dropped something we still
/// have a record of.
pub fn compare(alloc: std.mem.Allocator, old: RemoteRefs, new: RemoteRefs) !Divergence {
    var changed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (changed.items) |c| alloc.free(c);
        changed.deinit(alloc);
    }

    var behind = false;
    var ahead = false;

    for (new.entries) |n| {
        if (old.find(n.name)) |old_hex| {
            if (std.mem.eql(u8, old_hex, n.oid_hex)) continue;
        }
        behind = true;
        try changed.append(alloc, try alloc.dupe(u8, n.name));
    }
    for (old.entries) |o| {
        if (new.find(o.name) != null) continue;
        ahead = true;
        try changed.append(alloc, try alloc.dupe(u8, o.name));
    }

    return .{
        .behind = behind,
        .ahead = ahead,
        .changed = try changed.toOwnedSlice(alloc),
    };
}

// --- autopull ---

/// Whether `remote.autopull = always` may actually fire.
///
/// An automatic pull is something git cannot safely offer, and the reason is
/// not politeness. A pull that conflicts writes `<<<<<<<` markers into the
/// working files. A human notices those; an agent does not. It reads the
/// marked-up file as source, edits around the markers, and commits the result.
/// So under git the honest default is "never touch the tree unasked", and every
/// automatic-pull feature is a trap waiting for the one merge that does not
/// apply cleanly.
///
/// Superposition removes the trap rather than mitigating it. A conflicting pull
/// under superposition cannot write markers into a file, because both sides are
/// kept as distinct labelled states instead of being smashed into one buffer.
/// The pull stops being an emergency and becomes a label: the work continues on
/// the state you were already on, and the remote's version sits beside it until
/// something resolves it. That is the entire justification for allowing an
/// unasked pull at all.
///
/// Therefore this returns true only when BOTH hold: the user opted in with
/// `remote.autopull = always`, AND superposition is enabled. With superposition
/// off, `always` is REFUSED no matter how explicitly it was configured, because
/// honouring it would reintroduce exactly the failure the setting is only safe
/// without.
pub fn autopullAllowed(store: *Store, alloc: std.mem.Allocator, superpose_enabled: bool) bool {
    if (!superpose_enabled) return false;
    return settings(store, alloc).autopull == .always;
}

/// Log an autopull as an op, so `sdt undo` reverses it completely.
///
/// This is the second half of what makes an unasked pull acceptable: it is not
/// merely survivable, it is undoable by the same single command the user
/// already uses for everything else. `OpKind.other` because a pull is a branch
/// move that the user did not initiate, and the undo machinery only needs the
/// branch and the two endpoints to put it back.
pub fn recordPull(store: *Store, branch: []const u8, prev: Oid, new: Oid, ms: i64) !void {
    try oplog.record(store, .{
        .kind = .other,
        .branch = branch,
        .prev = prev,
        .new = new,
        .timestamp = ms,
    });
}

// --- tests ---

const testing = std.testing;

fn makeRefs(alloc: std.mem.Allocator, pairs: []const [2][]const u8) !RemoteRefs {
    const entries = try alloc.alloc(Entry, pairs.len);
    for (pairs, 0..) |p, i| {
        entries[i] = .{
            .name = try alloc.dupe(u8, p[0]),
            .oid_hex = try alloc.dupe(u8, p[1]),
        };
    }
    return .{ .entries = entries };
}

const hex_a = "1111111111111111111111111111111111111111";
const hex_b = "2222222222222222222222222222222222222222";
const hex_c = "3333333333333333333333333333333333333333";

test "a refs snapshot roundtrips through the log" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    // A ref name carrying every character that could break the framing.
    const awkward = "refs/heads/weird name=with\tequals\nand \\ backslash";
    const in = try makeRefs(alloc, &.{
        .{ "refs/heads/main", hex_a },
        .{ awkward, hex_b },
    });
    defer in.deinit(alloc);

    try record(&s, "origin", in, 1_700_000_000_000);

    const got = (try latest(&s, alloc, "origin")).?;
    defer got.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), got.entries.len);
    try testing.expectEqualStrings("refs/heads/main", got.entries[0].name);
    try testing.expectEqualStrings(hex_a, got.entries[0].oid_hex);
    try testing.expectEqualStrings(awkward, got.entries[1].name);
    try testing.expectEqualStrings(hex_b, got.entries[1].oid_hex);
}

test "latest returns the newest snapshot for the right remote" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try testing.expect((try latest(&s, alloc, "origin")) == null);

    const first = try makeRefs(alloc, &.{.{ "refs/heads/main", hex_a }});
    defer first.deinit(alloc);
    try record(&s, "origin", first, 1000);

    const other = try makeRefs(alloc, &.{.{ "refs/heads/main", hex_c }});
    defer other.deinit(alloc);
    try record(&s, "upstream", other, 1500);

    const second = try makeRefs(alloc, &.{.{ "refs/heads/main", hex_b }});
    defer second.deinit(alloc);
    try record(&s, "origin", second, 2000);

    const got = (try latest(&s, alloc, "origin")).?;
    defer got.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), got.entries.len);
    try testing.expectEqualStrings(hex_b, got.entries[0].oid_hex);

    const up = (try latest(&s, alloc, "upstream")).?;
    defer up.deinit(alloc);
    try testing.expectEqualStrings(hex_c, up.entries[0].oid_hex);
}

test "an empty snapshot roundtrips as empty" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const empty = try makeRefs(alloc, &.{});
    defer empty.deinit(alloc);
    try record(&s, "origin", empty, 5);

    const got = (try latest(&s, alloc, "origin")).?;
    defer got.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), got.entries.len);
}

test "compare detects moved, added, and removed refs" {
    const alloc = testing.allocator;

    const old = try makeRefs(alloc, &.{
        .{ "refs/heads/main", hex_a },
        .{ "refs/heads/gone", hex_c },
        .{ "refs/heads/same", hex_c },
    });
    defer old.deinit(alloc);
    const new = try makeRefs(alloc, &.{
        .{ "refs/heads/main", hex_b },
        .{ "refs/heads/added", hex_c },
        .{ "refs/heads/same", hex_c },
    });
    defer new.deinit(alloc);

    const d = try compare(alloc, old, new);
    defer freeDivergence(alloc, d);

    try testing.expect(d.behind);
    try testing.expect(d.ahead);
    try testing.expectEqual(@as(usize, 3), d.changed.len);
    try testing.expectEqualStrings("refs/heads/main", d.changed[0]);
    try testing.expectEqualStrings("refs/heads/added", d.changed[1]);
    try testing.expectEqualStrings("refs/heads/gone", d.changed[2]);
}

test "compare of identical snapshots reports no divergence" {
    const alloc = testing.allocator;

    const a = try makeRefs(alloc, &.{
        .{ "refs/heads/main", hex_a },
        .{ "refs/tags/v1", hex_b },
    });
    defer a.deinit(alloc);
    const b = try makeRefs(alloc, &.{
        .{ "refs/heads/main", hex_a },
        .{ "refs/tags/v1", hex_b },
    });
    defer b.deinit(alloc);

    const d = try compare(alloc, a, b);
    defer freeDivergence(alloc, d);
    try testing.expect(!d.behind);
    try testing.expect(!d.ahead);
    try testing.expectEqual(@as(usize, 0), d.changed.len);
}

test "staleness is false right after a look and true once it ages out" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const set = Settings{};

    // Never looked: maximally stale.
    try testing.expect(isStale(&s, alloc, set));
    try testing.expect(shouldFreshen(&s, alloc, set));

    const snap = try makeRefs(alloc, &.{.{ "refs/heads/main", hex_a }});
    defer snap.deinit(alloc);

    const now = nowMillis(io);
    try record(&s, "origin", snap, now);
    try testing.expect(!isStale(&s, alloc, set));
    try testing.expect(!shouldFreshen(&s, alloc, set));

    // Backdate the newest snapshot well past the window.
    try record(&s, "origin", snap, now - 10 * set.freshen_ms);
    try testing.expect(isStale(&s, alloc, set));
    try testing.expect(shouldFreshen(&s, alloc, set));
}

test "settings read freshen_ms and autopull from config" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const defaults = settings(&s, alloc);
    try testing.expectEqual(@as(i64, 60_000), defaults.freshen_ms);
    try testing.expect(defaults.autopull == .never);

    try config.set(&s, "remote.freshen_ms", "5000");
    try config.set(&s, "remote.autopull", "always");
    const got = settings(&s, alloc);
    try testing.expectEqual(@as(i64, 5000), got.freshen_ms);
    try testing.expect(got.autopull == .always);

    // Junk falls back to the default rather than erroring.
    try config.set(&s, "remote.freshen_ms", "soon");
    try testing.expectEqual(@as(i64, 60_000), settings(&s, alloc).freshen_ms);
}

test "autopull is refused whenever superposition is off" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    // Default (never), either way.
    try testing.expect(!autopullAllowed(&s, alloc, false));
    try testing.expect(!autopullAllowed(&s, alloc, true));

    // Explicit opt-in still refused without superposition: the marker hazard is
    // the reason for the setting's existence, not a detail of it.
    try config.set(&s, "remote.autopull", "always");
    try testing.expect(!autopullAllowed(&s, alloc, false));
    try testing.expect(autopullAllowed(&s, alloc, true));

    // And superposition alone never implies consent.
    try config.set(&s, "remote.autopull", "never");
    try testing.expect(!autopullAllowed(&s, alloc, true));
}

test "recordPull appends an oplog entry that undo reverses" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = Oid.ofBytes("base");
    const after = Oid.ofBytes("pulled");

    try s.updateRef("main", before);
    try oplog.record(&s, .{ .kind = .snapshot, .branch = "main", .prev = Oid.zero(), .new = before, .timestamp = 1 });

    try s.updateRef("main", after);
    try recordPull(&s, "main", before, after, 2);

    {
        const last = (try oplog.lastOp(&s, alloc)).?;
        defer alloc.free(last.branch);
        try testing.expectEqual(oplog.OpKind.other, last.kind);
        try testing.expectEqualStrings("main", last.branch);
        try testing.expect(last.prev.eql(before));
        try testing.expect(last.new.eql(after));
    }

    try oplog.undo(&s, null);
    try testing.expect((try s.readRef("main")).eql(before));
}

test "parseLsRemote reads real output and skips junk" {
    const alloc = testing.allocator;

    const sha256 = "a" ** 64;
    const text =
        "ref: refs/heads/main\tHEAD\n" ++
        hex_a ++ "\tHEAD\n" ++
        hex_a ++ "\trefs/heads/main\n" ++
        hex_b ++ "\trefs/heads/feature/thing\n" ++
        sha256 ++ "\trefs/tags/v1.0.0\n" ++
        "warning: something happened\n" ++
        "zzzz\trefs/heads/nothex\n" ++
        "\n" ++
        hex_c ++ "\n" ++
        hex_c ++ "\t\n";

    const got = try parseLsRemote(alloc, text);
    defer got.deinit(alloc);

    try testing.expectEqual(@as(usize, 4), got.entries.len);
    try testing.expectEqualStrings("HEAD", got.entries[0].name);
    try testing.expectEqualStrings("refs/heads/main", got.entries[1].name);
    try testing.expectEqualStrings(hex_a, got.entries[1].oid_hex);
    try testing.expectEqualStrings("refs/heads/feature/thing", got.entries[2].name);
    try testing.expectEqualStrings("refs/tags/v1.0.0", got.entries[3].name);
    try testing.expectEqualStrings(sha256, got.entries[3].oid_hex);
}

test "parseLsRemote output records and compares end to end" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const first = try parseLsRemote(alloc, hex_a ++ "\trefs/heads/main\n");
    defer first.deinit(alloc);
    try record(&s, "origin", first, 1000);

    const stored = (try latest(&s, alloc, "origin")).?;
    defer stored.deinit(alloc);

    const probe = try parseLsRemote(alloc, hex_b ++ "\trefs/heads/main\n");
    defer probe.deinit(alloc);

    const d = try compare(alloc, stored, probe);
    defer freeDivergence(alloc, d);
    try testing.expect(d.behind);
    try testing.expect(!d.ahead);
    try testing.expectEqual(@as(usize, 1), d.changed.len);
    try testing.expectEqualStrings("refs/heads/main", d.changed[0]);
}
