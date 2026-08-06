const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const oplog = @import("oplog.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Commitless flow, and the git bridge trailers that carry it out.
///
/// Two halves of one idea. A change is *cut* at a red-to-green boundary rather
/// than whenever somebody remembers to type a command, so every change this
/// module creates is verified by construction: the tree it points at is exactly
/// the tree a check just went green on. A commit is *rendered* at the same
/// boundary, so every commit superdetermine exports to git builds by construction,
/// which is the property git histories are always claimed to have and never do.
///
/// Nothing here removes anything. `gr save` and `gr push` never go away: a cut
/// mode is a default for the moments nobody bothered to name, not a replacement
/// for naming them. `.manual` is the default and cuts nothing at all.
///
/// Nothing here blocks anything either. `Sdt-Verified` is a HINT that a CI system
/// may treat as an independently verifiable cache key: it can re-run the check
/// itself and, finding the same tree and the same command, skip the work. It is
/// NEVER an authority. A verdict produced on somebody's laptop must never gate a
/// merge, because a signal wired to block becomes a target. Trailers are inert
/// text to git, so a teammate on plain git sees an ordinary branch with slightly
/// chattier commit messages and installs nothing.
pub const CutMode = enum {
    /// Cut when a check goes from red to green. Every cut is verified.
    green,
    /// Cut when the tree has been quiet for a while. The idle timer drives this
    /// at the CLI, not a verdict transition, so `shouldCut` never fires for it.
    idle,
    /// Cut only when asked. The default: nothing happens without a command.
    manual,

    pub fn label(self: CutMode) []const u8 {
        return @tagName(self);
    }

    pub fn fromLabel(s: []const u8) ?CutMode {
        inline for (@typeInfo(CutMode).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(CutMode, f.name);
        }
        return null;
    }
};

/// Resolved `flow.*` configuration. `publish_remote` is heap-allocated when
/// non-empty; free the whole thing with `deinit`.
pub const Settings = struct {
    cut: CutMode = .manual,
    publish: bool = false,
    publish_remote: []const u8 = "",

    /// Release the strings `settings` allocated. Safe on a default value.
    pub fn deinit(self: Settings, alloc: std.mem.Allocator) void {
        if (self.publish_remote.len != 0) alloc.free(self.publish_remote);
    }
};

// --- settings ---

/// Only an explicit affirmative counts. Anything absent, empty, or unrecognised
/// reads as off, because the two settings this gates (cutting changes and
/// pushing bytes off the machine) must never turn on by accident.
fn boolOf(v: []const u8) bool {
    return std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "on") or
        std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "yes");
}

/// Read `flow.cut`, `flow.publish` and `flow.publish.remote`. A malformed value
/// falls back to the default rather than erroring: a typo in config must not
/// take the working repo down.
pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "flow.cut")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.cut = CutMode.fromLabel(v) orelse out.cut;
        }
    } else |_| {}
    if (config.get(store, alloc, "flow.publish")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.publish = boolOf(v);
        }
    } else |_| {}
    if (config.get(store, alloc, "flow.publish.remote")) |maybe| {
        if (maybe) |v| {
            if (v.len == 0) {
                alloc.free(v);
            } else {
                out.publish_remote = v;
            }
        }
    } else |_| {}
    return out;
}

// --- cutting ---

/// Is `now` a boundary worth cutting a change at?
///
/// True only for a genuine red-to-green transition, or the first-ever green on a
/// tree that has never been graded (`prev == null`). Green after green is not a
/// boundary: the work was already captured by the cut that made it green, and
/// cutting again would fill the log with changes that changed nothing.
///
/// `.idle` is false here by construction. An idle cut is driven by a quiet-tree
/// timer at the CLI and has no verdict transition to observe; routing it through
/// this function would make it fire on every poll.
pub fn shouldCut(mode: CutMode, prev: ?verdict.Result, now: verdict.Result) bool {
    if (mode != .green) return false;
    if (now != .green) return false;
    const before = prev orelse return true;
    return before == .red;
}

/// Turn a verified moment into a real change on the current branch.
///
/// The tree comes from the moment, never from a fresh scan of the worktree, so
/// what lands is exactly the state the verdict was recorded against. A scan here
/// would race the editor and could commit a tree nothing ever checked.
///
/// Parent is the current branch tip when it exists, so an unborn branch cuts a
/// root change. An `oplog` record with `OpKind.snapshot` is appended last, which
/// is what makes an automatic cut as reversible as a manual one: `gr undo` puts
/// the ref straight back.
///
/// `work_dir` is in the signature so callers pass their worktree handle without
/// special-casing this path against `gr save`; the cut itself reads no files.
pub fn cutAt(
    store: *Store,
    work_dir: std.Io.Dir,
    m: moment.Moment,
    author: []const u8,
    message: []const u8,
    timestamp: i64,
) !Oid {
    _ = work_dir;
    const alloc = store.alloc;

    const entries = try moment.entriesOf(store, m);
    defer workspace.freeTreeEntries(alloc, entries);
    const tree_oid = try store.writeTree(.{ .entries = entries });

    const branch = try store.headBranch();
    defer alloc.free(branch);

    var parents_buf: [1]Oid = undefined;
    var parents: []const Oid = parents_buf[0..0];
    const prev = if (store.refExists(branch)) try store.readRef(branch) else Oid.zero();
    if (!prev.isZero()) {
        parents_buf[0] = prev;
        parents = parents_buf[0..1];
    }

    var seed: [Oid.len + 8]u8 = undefined;
    @memcpy(seed[0..Oid.len], &tree_oid.bytes);
    std.mem.writeInt(u64, seed[Oid.len..][0..8], @bitCast(timestamp), .big);
    var digest: [Oid.len]u8 = undefined;
    oid.Blake3.hash(&seed, &digest, .{});
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, digest[0..16]);

    const change_oid = try store.writeChange(.{
        .tree = tree_oid,
        .parents = parents,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = 0,
        .author = author,
        .message = message,
    });
    try store.updateRef(branch, change_oid);
    try oplog.record(store, .{
        .kind = .snapshot,
        .branch = branch,
        .prev = prev,
        .new = change_oid,
        .timestamp = timestamp,
    });
    return change_oid;
}

// --- publishing ---

/// May objects be replicated to a git remote without anyone asking again?
///
/// False unless `flow.publish` is explicitly affirmative. Code leaving the
/// machine is a consent problem, not a convenience one, so the default is off
/// and an unreadable or unrecognised setting stays off. The interactive prompt
/// that turns it on lives at the CLI; this function only reports the standing
/// answer, and this module performs no network IO of any kind.
pub fn publishAllowed(store: *Store, alloc: std.mem.Allocator) bool {
    const v = config.get(store, alloc, "flow.publish") catch return false;
    const value = v orelse return false;
    defer alloc.free(value);
    return boolOf(value);
}

/// The git ref a branch replicates under: `refs/sdt/<branch>`.
///
/// Under `refs/sdt/` rather than `refs/heads/`, so a publish never moves a branch
/// anybody is working on and a teammate who fetches it sees nothing new unless
/// they go looking. Caller frees.
pub fn refName(alloc: std.mem.Allocator, branch: []const u8) ![]u8 {
    return std.fmt.allocPrint(alloc, "refs/sdt/{s}", .{branch});
}

// --- git bridge trailers ---

const verified_key = "Sdt-Verified";
const legacy_verified_key = "Gr-Verified";
const span_key = "Sdt-Span";
const legacy_span_key = "Gr-Span";
const check_key = "Sdt-Check";
const legacy_check_key = "Gr-Check";

/// What superdetermine knows about a commit, in a form git will carry for free.
///
/// `verified_full` / `verified_fast` are the per-tier verdicts, `span` is the
/// moment range the commit covers (`<moment-id>..<moment-id>`), `check` is the
/// exact command that produced the verdict. Every field is optional: a commit
/// with nothing to say emits no trailers at all.
pub const Trailers = struct {
    verified_full: ?verdict.Result = null,
    verified_fast: ?verdict.Result = null,
    span: []const u8 = "",
    check: []const u8 = "",

    /// Release the strings `parseTrailers` allocated. A `Trailers` built by hand
    /// out of borrowed slices does not need it and must not get it.
    pub fn deinit(self: Trailers, alloc: std.mem.Allocator) void {
        if (self.span.len != 0) alloc.free(self.span);
        if (self.check.len != 0) alloc.free(self.check);
    }
};

/// Git's own trailer shape: `Key: value`, key limited to letters, digits and
/// dashes, value separated by a space. Anything else is prose.
fn isTrailerLine(line: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    if (colon == 0) return false;
    for (line[0..colon]) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return false;
    }
    return colon + 1 == line.len or line[colon + 1] == ' ';
}

fn keyOf(line: []const u8, key: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, key)) return null;
    if (line.len <= key.len or line[key.len] != ':') return null;
    return std.mem.trim(u8, line[key.len + 1 ..], " \t\r");
}

fn isOurs(line: []const u8) bool {
    return keyOf(line, verified_key) != null or
        keyOf(line, span_key) != null or
        keyOf(line, check_key) != null;
}

fn renderTrailers(alloc: std.mem.Allocator, t: Trailers) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (t.verified_full != null or t.verified_fast != null) {
        try out.appendSlice(alloc, verified_key ++ ":");
        if (t.verified_full) |r| try out.print(alloc, " full={s}", .{r.label()});
        if (t.verified_fast) |r| try out.print(alloc, " fast={s}", .{r.label()});
        try out.append(alloc, '\n');
    }
    if (t.span.len != 0) try out.print(alloc, "{s}: {s}\n", .{ span_key, t.span });
    if (t.check.len != 0) try out.print(alloc, "{s}: {s}\n", .{ check_key, t.check });
    return out.toOwnedSlice(alloc);
}

/// Render a commit message carrying `t`, following git trailer convention: the
/// trailers form the last paragraph, one `Key: value` per line.
///
/// A message that already ends in a trailer paragraph gains its new lines inside
/// that paragraph instead of starting a second one, and any `Gr-` trailer
/// already present is replaced rather than repeated, so appending twice is
/// idempotent in shape and never corrupts what git will parse. A message with no
/// trailing newline is handled the same as one with any number of them: the
/// result always ends in exactly one. Caller frees.
pub fn appendTrailers(alloc: std.mem.Allocator, message: []const u8, t: Trailers) ![]u8 {
    const rendered = try renderTrailers(alloc, t);
    defer alloc.free(rendered);
    if (rendered.len == 0) return alloc.dupe(u8, message);

    const body = std.mem.trimEnd(u8, message, "\n");
    if (body.len == 0) return alloc.dupe(u8, rendered);

    const para_start = if (std.mem.lastIndexOf(u8, body, "\n\n")) |i| i + 2 else 0;
    const head = body[0..para_start];
    const para = body[para_start..];

    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(alloc);
    var all_trailers = true;
    var it = std.mem.splitScalar(u8, para, '\n');
    while (it.next()) |line| {
        if (isOurs(line)) continue;
        if (!isTrailerLine(line)) all_trailers = false;
        try kept.appendSlice(alloc, line);
        try kept.append(alloc, '\n');
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    if (kept.items.len == 0) {
        // The last paragraph held nothing but our own trailers; it is replaced.
        const trimmed = std.mem.trimEnd(u8, head, "\n");
        if (trimmed.len != 0) {
            try out.appendSlice(alloc, trimmed);
            try out.appendSlice(alloc, "\n\n");
        }
    } else {
        try out.appendSlice(alloc, head);
        try out.appendSlice(alloc, kept.items);
        // Prose gets a blank line; an existing trailer paragraph does not.
        if (!all_trailers) try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, rendered);
    return out.toOwnedSlice(alloc);
}

/// The exact inverse of `appendTrailers`, so a message survives a round trip
/// through `gr git export` and `gr git import` unchanged.
///
/// Every line of the message is considered, not just the last paragraph, because
/// a message that arrived through another tool may have been reflowed. Lines
/// that are not `Gr-` trailers are ignored, absent keys stay null, and a
/// repeated key takes its last value. Free with `Trailers.deinit`.
pub fn parseTrailers(alloc: std.mem.Allocator, message: []const u8) !Trailers {
    var out: Trailers = .{};
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        // Both spellings are accepted on read: commits exported before the
        // rename must keep round-tripping, and a trailer is inert text to git
        // either way.
        if (keyOf(line, verified_key) orelse keyOf(line, legacy_verified_key)) |value| {
            var parts = std.mem.splitScalar(u8, value, ' ');
            while (parts.next()) |part| {
                if (part.len == 0) continue;
                if (std.mem.startsWith(u8, part, "full=")) {
                    out.verified_full = resultOf(part["full=".len..]) orelse out.verified_full;
                } else if (std.mem.startsWith(u8, part, "fast=")) {
                    out.verified_fast = resultOf(part["fast=".len..]) orelse out.verified_fast;
                }
            }
        } else if (keyOf(line, span_key) orelse keyOf(line, legacy_span_key)) |value| {
            if (value.len == 0) continue;
            if (out.span.len != 0) alloc.free(out.span);
            out.span = try alloc.dupe(u8, value);
        } else if (keyOf(line, check_key) orelse keyOf(line, legacy_check_key)) |value| {
            if (value.len == 0) continue;
            if (out.check.len != 0) alloc.free(out.check);
            out.check = try alloc.dupe(u8, value);
        }
    }
    return out;
}

fn resultOf(s: []const u8) ?verdict.Result {
    if (std.mem.eql(u8, s, "green")) return .green;
    if (std.mem.eql(u8, s, "red")) return .red;
    return null;
}

// --- tests ---

const testing = std.testing;

test "shouldCut fires only on a red-to-green transition in green mode" {
    const results = [_]?verdict.Result{ null, .red, .green };

    for (results) |prev| {
        // Manual never cuts, whatever just happened.
        try testing.expect(!shouldCut(.manual, prev, .green));
        try testing.expect(!shouldCut(.manual, prev, .red));
        // Idle is driven by a timer, not a transition.
        try testing.expect(!shouldCut(.idle, prev, .green));
        try testing.expect(!shouldCut(.idle, prev, .red));
        // A red is never a boundary.
        try testing.expect(!shouldCut(.green, prev, .red));
    }

    try testing.expect(shouldCut(.green, null, .green));
    try testing.expect(shouldCut(.green, .red, .green));
    try testing.expect(!shouldCut(.green, .green, .green));
}

test "cut mode defaults to manual and reads from config" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    {
        const set = settings(&store, alloc);
        defer set.deinit(alloc);
        try testing.expectEqual(CutMode.manual, set.cut);
        try testing.expect(!set.publish);
        try testing.expectEqualStrings("", set.publish_remote);
    }

    try config.set(&store, "flow.cut", "green");
    try config.set(&store, "flow.publish", "true");
    try config.set(&store, "flow.publish.remote", "origin");
    {
        const set = settings(&store, alloc);
        defer set.deinit(alloc);
        try testing.expectEqual(CutMode.green, set.cut);
        try testing.expect(set.publish);
        try testing.expectEqualStrings("origin", set.publish_remote);
    }

    // Junk falls back rather than erroring.
    try config.set(&store, "flow.cut", "sideways");
    {
        const set = settings(&store, alloc);
        defer set.deinit(alloc);
        try testing.expectEqual(CutMode.manual, set.cut);
    }
}

fn captureOne(store: *Store, work: std.Io.Dir) !moment.Moment {
    const r = try moment.capture(store, work, .poll, .{ .enabled = true, .keyframe_interval = 5 });
    return r.captured;
}

test "cutAt creates a change on the branch whose tree is the moment's tree" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const m = try captureOne(&store, work);
    defer alloc.free(m.branch);

    const cut = try cutAt(&store, work, m, "Nico <n@x.com>", "verified\n", 1700);

    // Reachable from the branch, and pointing at exactly the captured tree.
    try testing.expect((try store.readRef("main")).eql(cut));
    const change = try store.readChange(cut);
    defer object.freeChange(alloc, change);
    try testing.expect(change.tree.eql(m.full_tree));
    try testing.expectEqual(@as(usize, 0), change.parents.len);
    try testing.expectEqualStrings("verified\n", change.message);
    try testing.expectEqual(@as(i64, 1700), change.timestamp);

    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    try testing.expectEqual(@as(usize, 1), tree.entries.len);
    try testing.expectEqualStrings("a.txt", tree.entries[0].path);

    // And it is undoable, because the cut logged itself as a snapshot.
    const last = (try oplog.lastOp(&store, alloc)).?;
    defer alloc.free(last.branch);
    try testing.expectEqual(oplog.OpKind.snapshot, last.kind);
    try testing.expectEqualStrings("main", last.branch);
    try testing.expect(last.new.eql(cut));
    try testing.expect(last.prev.isZero());

    try oplog.undo(&store, null);
    try testing.expect(!store.refExists("main"));
}

test "a second cut parents onto the first" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const first_m = try captureOne(&store, work);
    defer alloc.free(first_m.branch);
    const first = try cutAt(&store, work, first_m, "a <a@x>", "one\n", 1);

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "two" });
    const second_m = try captureOne(&store, work);
    defer alloc.free(second_m.branch);
    const second = try cutAt(&store, work, second_m, "a <a@x>", "two\n", 2);

    try testing.expect(!first.eql(second));
    const change = try store.readChange(second);
    defer object.freeChange(alloc, change);
    try testing.expectEqual(@as(usize, 1), change.parents.len);
    try testing.expect(change.parents[0].eql(first));
    try testing.expect(change.tree.eql(second_m.full_tree));
}

test "publishing is off until explicitly enabled" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expect(!publishAllowed(&store, alloc));

    // Setting the remote is not consent to use it.
    try config.set(&store, "flow.publish.remote", "origin");
    try testing.expect(!publishAllowed(&store, alloc));

    try config.set(&store, "flow.publish", "maybe");
    try testing.expect(!publishAllowed(&store, alloc));

    try config.set(&store, "flow.publish", "false");
    try testing.expect(!publishAllowed(&store, alloc));

    try config.set(&store, "flow.publish", "true");
    try testing.expect(publishAllowed(&store, alloc));
}

test "refName puts a branch under refs/sdt" {
    const alloc = testing.allocator;
    const r = try refName(alloc, "main");
    defer alloc.free(r);
    try testing.expectEqualStrings("refs/sdt/main", r);

    const f = try refName(alloc, "feature/x");
    defer alloc.free(f);
    try testing.expectEqualStrings("refs/sdt/feature/x", f);
}

test "trailers round trip with every field set" {
    const alloc = testing.allocator;
    const t = Trailers{
        .verified_full = .green,
        .verified_fast = .green,
        .span = "0011223344556677..8899aabbccddeeff",
        .check = "zig build test",
    };
    const msg = try appendTrailers(alloc, "make the thing work", t);
    defer alloc.free(msg);

    try testing.expectEqualStrings(
        \\make the thing work
        \\
        \\Sdt-Verified: full=green fast=green
        \\Sdt-Span: 0011223344556677..8899aabbccddeeff
        \\Sdt-Check: zig build test
        \\
    , msg);

    const back = try parseTrailers(alloc, msg);
    defer back.deinit(alloc);
    try testing.expectEqual(verdict.Result.green, back.verified_full.?);
    try testing.expectEqual(verdict.Result.green, back.verified_fast.?);
    try testing.expectEqualStrings(t.span, back.span);
    try testing.expectEqualStrings(t.check, back.check);
}

test "trailers round trip with only some fields set" {
    const alloc = testing.allocator;
    const t = Trailers{ .verified_fast = .red, .check = "bun test" };
    const msg = try appendTrailers(alloc, "wip\n", t);
    defer alloc.free(msg);

    try testing.expectEqualStrings("wip\n\nSdt-Verified: fast=red\nSdt-Check: bun test\n", msg);

    const back = try parseTrailers(alloc, msg);
    defer back.deinit(alloc);
    try testing.expect(back.verified_full == null);
    try testing.expectEqual(verdict.Result.red, back.verified_fast.?);
    try testing.expectEqualStrings("", back.span);
    try testing.expectEqualStrings("bun test", back.check);
}

test "a message with nothing to say keeps its trailers off" {
    const alloc = testing.allocator;
    const msg = try appendTrailers(alloc, "just a message\n", .{});
    defer alloc.free(msg);
    try testing.expectEqualStrings("just a message\n", msg);

    const back = try parseTrailers(alloc, msg);
    defer back.deinit(alloc);
    try testing.expect(back.verified_full == null);
    try testing.expect(back.verified_fast == null);
    try testing.expectEqualStrings("", back.span);
    try testing.expectEqualStrings("", back.check);
}

test "appending to a message with no trailing newline is well formed" {
    const alloc = testing.allocator;
    const msg = try appendTrailers(alloc, "no newline here", .{ .span = "aa..bb" });
    defer alloc.free(msg);
    try testing.expectEqualStrings("no newline here\n\nSdt-Span: aa..bb\n", msg);

    // And so is one drowning in them.
    const many = try appendTrailers(alloc, "trailing\n\n\n", .{ .span = "aa..bb" });
    defer alloc.free(many);
    try testing.expectEqualStrings("trailing\n\nSdt-Span: aa..bb\n", many);
}

test "appending twice neither duplicates nor corrupts" {
    const alloc = testing.allocator;
    const once = try appendTrailers(alloc, "subject\n\nbody text\n", .{
        .verified_full = .green,
        .span = "aa..bb",
    });
    defer alloc.free(once);

    const twice = try appendTrailers(alloc, once, .{
        .verified_full = .red,
        .span = "cc..dd",
        .check = "make",
    });
    defer alloc.free(twice);

    try testing.expectEqualStrings(
        \\subject
        \\
        \\body text
        \\
        \\Sdt-Verified: full=red
        \\Sdt-Span: cc..dd
        \\Sdt-Check: make
        \\
    , twice);

    // Exactly one of each key survived.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, twice, "Sdt-Verified:"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, twice, "Sdt-Span:"));

    const back = try parseTrailers(alloc, twice);
    defer back.deinit(alloc);
    try testing.expectEqual(verdict.Result.red, back.verified_full.?);
    try testing.expectEqualStrings("cc..dd", back.span);
}

test "appending joins an existing trailer paragraph rather than starting one" {
    const alloc = testing.allocator;
    const msg = try appendTrailers(
        alloc,
        "subject\n\nSigned-off-by: Someone <s@x.com>\n",
        .{ .check = "cargo test" },
    );
    defer alloc.free(msg);

    try testing.expectEqualStrings(
        \\subject
        \\
        \\Signed-off-by: Someone <s@x.com>
        \\Sdt-Check: cargo test
        \\
    , msg);
}

test "unrelated trailers and prose are ignored when parsing" {
    const alloc = testing.allocator;
    const message =
        \\fix the parser
        \\
        \\Foo: bar
        \\this line is not a trailer at all
        \\Gr-Span: aaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbb
        \\Co-authored-by: Someone <s@x.com>
        \\Gr-Verified: full=green
        \\
    ;
    const back = try parseTrailers(alloc, message);
    defer back.deinit(alloc);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaa..bbbbbbbbbbbbbbbb", back.span);
    try testing.expectEqual(verdict.Result.green, back.verified_full.?);
    try testing.expect(back.verified_fast == null);
    try testing.expectEqualStrings("", back.check);
}

test "a message with no trailers at all parses to nothing" {
    const alloc = testing.allocator;
    const back = try parseTrailers(alloc, "plain commit\n\nwith a body\n");
    defer back.deinit(alloc);
    try testing.expect(back.verified_full == null);
    try testing.expect(back.verified_fast == null);
    try testing.expectEqualStrings("", back.span);
    try testing.expectEqualStrings("", back.check);
}

test "a repeated key takes its last value" {
    const alloc = testing.allocator;
    const back = try parseTrailers(
        alloc,
        "m\n\nGr-Check: first\nGr-Check: second\nGr-Verified: full=red\nGr-Verified: full=green\n",
    );
    defer back.deinit(alloc);
    try testing.expectEqualStrings("second", back.check);
    try testing.expectEqual(verdict.Result.green, back.verified_full.?);
}

test "trailers written before the rename still parse" {
    const alloc = testing.allocator;
    const old =
        \\shipped
        \\
        \\Gr-Verified: full=green fast=red
        \\Gr-Span: aaaa..bbbb
        \\Gr-Check: make test
        \\
    ;
    const t = try parseTrailers(alloc, old);
    defer t.deinit(alloc);
    try testing.expectEqual(verdict.Result.green, t.verified_full.?);
    try testing.expectEqual(verdict.Result.red, t.verified_fast.?);
    try testing.expectEqualStrings("aaaa..bbbb", t.span);
    try testing.expectEqualStrings("make test", t.check);
}

test "a message carrying both spellings resolves without losing either field" {
    const alloc = testing.allocator;
    const mixed =
        \\mixed
        \\
        \\Gr-Span: old..span
        \\Sdt-Check: zig build test
        \\
    ;
    const t = try parseTrailers(alloc, mixed);
    defer t.deinit(alloc);
    try testing.expectEqualStrings("old..span", t.span);
    try testing.expectEqualStrings("zig build test", t.check);
}
