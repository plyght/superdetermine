const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const oplog = @import("oplog.zig");
const config = @import("config.zig");
const verdict = @import("verdict.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Superposition: conflicts that halt nothing.
///
/// A conflict today stops everything, and not because merging is hard. It stops
/// everything because conflict markers are syntactically invalid in every
/// language, so a tree carrying them cannot compile, cannot be graded, and
/// cannot be handed to an agent. That is tolerable when merges are rare. It is
/// intolerable once forking is free and several agents land on the same path in
/// the same hour.
///
/// The three-way merge in `merge.zig` runs first and is untouched. Superposition
/// replaces the *conflict markers*, never the merging: only the paths the
/// existing merge genuinely cannot reconcile enter superposition.
///
/// A superposed path holds several complete, individually valid whole-file
/// candidates. Path granularity is deliberate. A candidate must be a file
/// someone actually wrote, or it is neither independently valid nor gradeable;
/// a half-file hunk is neither. Hunks are never stored.
///
/// The worktree materializes exactly one primary candidate, so the tree always
/// builds. The alternatives are frozen at the moment of the merge and are never
/// auto-rebased onto a moving primary, which is the CRDT rabbit hole this
/// deliberately declines to enter. Staleness is reported honestly instead
/// (`renderStatus` prints when the alternatives were frozen).
///
/// Storage is an append-only log, one record per line, plus the candidate
/// contents as ordinary blobs in the object store. Nothing here touches the
/// object model or git interop.
pub const log_path = "superposed";

pub const Error = error{
    /// The path has no superposed record (or was already collapsed).
    NotSuperposed,
    /// The requested label is not one of the candidates.
    NoSuchCandidate,
    /// A record named a primary label that is not among its own candidates.
    InvalidSuperposedRecord,
};

// --- the model ---

/// One complete, individually valid whole-file version of a superposed path.
///
/// `blob` is a normal blob Oid, so a candidate costs exactly what the file costs
/// and dedups against every other copy of the same content in the repo. A
/// candidate blob is never deleted, not even when it loses a collapse.
pub const Candidate = struct {
    /// 'A', 'B', 'C', ... in the order the candidates were recorded.
    label: u8,
    /// Where this version came from: "ours", "theirs", or a branch name.
    origin: []const u8,
    blob: Oid,
    /// The moment this version was captured at, or empty when unknown. Empty is
    /// a normal answer, not a defect: a candidate can predate capture.
    moment_id: []const u8,
    author: []const u8,
};

/// A path in superposition, with its candidates and the one the worktree holds.
///
/// Values returned by `list` and `get` own their strings; free them with
/// `deinit` (or the whole slice with `freeAll`). Values built by hand for
/// `record` borrow their strings and must not be `deinit`ed.
pub const Superposed = struct {
    path: []const u8,
    /// The label materialized in the worktree. Exactly one, always.
    primary: u8,
    candidates: []Candidate,
    /// Unix seconds at which the alternatives were frozen.
    frozen_at: i64 = 0,

    pub fn deinit(self: Superposed, alloc: std.mem.Allocator) void {
        for (self.candidates) |c| {
            alloc.free(c.origin);
            alloc.free(c.moment_id);
            alloc.free(c.author);
        }
        alloc.free(self.candidates);
        alloc.free(self.path);
    }

    /// The candidate carrying `label`, or null.
    pub fn find(self: Superposed, label: u8) ?Candidate {
        for (self.candidates) |c| {
            if (c.label == label) return c;
        }
        return null;
    }

    /// The primary candidate. Records that fail this are rejected on write, so
    /// a stored record always has one.
    pub fn primaryCandidate(self: Superposed) !Candidate {
        return self.find(self.primary) orelse Error.InvalidSuperposedRecord;
    }
};

/// The label for the n-th candidate: 'A', 'B', 'C', ... Past 'Z' it keeps
/// counting into printable ASCII rather than wrapping onto an existing label,
/// because two candidates sharing a label would make `collapse` ambiguous.
pub fn labelFor(n: usize) u8 {
    return @intCast('A' + @as(u8, @intCast(n % 64)));
}

// --- settings ---

/// Which candidate the worktree gets. `greenest` exists, but it is not the
/// default: making evidence the automatic tiebreak on day one trains people to
/// trust a signal before it has earned it. Evidence has to be asked for.
pub const Primary = enum {
    ours,
    theirs,
    greenest,

    pub fn label(self: Primary) []const u8 {
        return @tagName(self);
    }

    pub fn fromLabel(s: []const u8) ?Primary {
        inline for (@typeInfo(Primary).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Primary, f.name);
        }
        return null;
    }
};

pub const Settings = struct {
    /// Off by default, and off for every existing repo. Off is a supported
    /// configuration and not a compatibility shim: with `merge.superpose =
    /// false` a conflict produces exactly today's markers, forever.
    superpose: bool = false,
    /// Defaults to `ours`, deliberately not `greenest`.
    primary: Primary = .ours,
    /// A cap on accumulation. Superposed paths are cheap but not free to think
    /// about, and a repo with a hundred of them has a process problem that more
    /// superposition will not fix.
    max_superposed: usize = 16,
};

fn boolOf(v: []const u8) bool {
    return !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no"));
}

/// Resolve `merge.superpose`, `merge.primary` and `merge.max_superposed`.
/// A malformed value falls back to the default rather than erroring: a typo in
/// config must not take merging down.
pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "merge.superpose")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.superpose = boolOf(v);
        }
    } else |_| {}
    if (config.get(store, alloc, "merge.primary")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.primary = Primary.fromLabel(v) orelse out.primary;
        }
    } else |_| {}
    if (config.get(store, alloc, "merge.max_superposed")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.max_superposed = std.fmt.parseInt(usize, v, 10) catch out.max_superposed;
        }
    } else |_| {}
    return out;
}

// --- record encoding ---

// Wire format, one record per line:
//   <unix_ts> <primary> <n> \t <path> [ \t <label> \t <origin> \t <blobhex>
//                                      \t <moment> \t <author> ] * n
//
// Every free-text field (path, origin, moment, author) is escaped exactly the
// way `provenance.zig` escapes: `\`→`\\`, `\n`→`\n`, `\t`→`\t`. After escaping
// no field can contain a literal tab or newline, so the framing is unambiguous
// for any path or author bytes whatsoever, including ones with tabs in them.
//
// `n == 0` is a tombstone: the path left superposition (it was collapsed). The
// primary field is then '-'.

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

fn nowSeconds(store: *Store) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, store.io).nanoseconds, std.time.ns_per_s));
}

fn appendRecord(
    store: *Store,
    path: []const u8,
    candidates: []const Candidate,
    primary: u8,
    ts: i64,
) !void {
    const alloc = store.alloc;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const path_esc = try escape(alloc, path);
    defer alloc.free(path_esc);

    try out.print(alloc, "{d} {c} {d}\t{s}", .{
        ts,
        if (candidates.len == 0) @as(u8, '-') else primary,
        candidates.len,
        path_esc,
    });

    for (candidates) |c| {
        const origin_esc = try escape(alloc, c.origin);
        defer alloc.free(origin_esc);
        const moment_esc = try escape(alloc, c.moment_id);
        defer alloc.free(moment_esc);
        const author_esc = try escape(alloc, c.author);
        defer alloc.free(author_esc);
        var hex: [Oid.len * 2]u8 = undefined;
        _ = c.blob.toHex(&hex);
        try out.print(alloc, "\t{c}\t{s}\t{s}\t{s}\t{s}", .{
            c.label,
            origin_esc,
            &hex,
            moment_esc,
            author_esc,
        });
    }
    try out.append(alloc, '\n');

    try applog.append(store, log_path, out.items);
}

/// Parse one line. Returns null for a malformed line so a single bad append can
/// never make the whole log unreadable. Caller frees with `Superposed.deinit`.
fn parseLine(alloc: std.mem.Allocator, line: []const u8) !?Superposed {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const head = fields.next() orelse return null;
    const path_esc = fields.next() orelse return null;

    var head_it = std.mem.splitScalar(u8, head, ' ');
    const ts_s = head_it.next() orelse return null;
    const primary_s = head_it.next() orelse return null;
    const n_s = head_it.next() orelse return null;
    if (primary_s.len != 1) return null;
    const ts = std.fmt.parseInt(i64, ts_s, 10) catch return null;
    const n = std.fmt.parseInt(usize, n_s, 10) catch return null;

    const path = try unescape(alloc, path_esc);
    errdefer alloc.free(path);

    var out: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (out.items) |c| {
            alloc.free(c.origin);
            alloc.free(c.moment_id);
            alloc.free(c.author);
        }
        out.deinit(alloc);
    }

    for (0..n) |_| {
        const label_s = fields.next() orelse return null;
        const origin_esc = fields.next() orelse return null;
        const blob_s = fields.next() orelse return null;
        const moment_esc = fields.next() orelse return null;
        const author_esc = fields.next() orelse return null;
        if (label_s.len != 1) return null;

        const blob = Oid.fromHex(blob_s) catch return null;
        const origin = try unescape(alloc, origin_esc);
        errdefer alloc.free(origin);
        const moment_id = try unescape(alloc, moment_esc);
        errdefer alloc.free(moment_id);
        const author = try unescape(alloc, author_esc);
        errdefer alloc.free(author);

        try out.append(alloc, .{
            .label = label_s[0],
            .origin = origin,
            .blob = blob,
            .moment_id = moment_id,
            .author = author,
        });
    }

    return .{
        .path = path,
        .primary = primary_s[0],
        .candidates = try out.toOwnedSlice(alloc),
        .frozen_at = ts,
    };
}

// --- writing ---

/// Store `content` as a blob and describe it as a candidate. The returned
/// candidate borrows `origin`, `moment_id` and `author`; `record` only reads
/// them, so a caller may pass stack or arena memory.
pub fn candidateFromContent(
    store: *Store,
    label: u8,
    origin: []const u8,
    content: []const u8,
    moment_id: []const u8,
    author: []const u8,
) !Candidate {
    return .{
        .label = label,
        .origin = origin,
        .blob = try store.writeFileContent(content),
        .moment_id = moment_id,
        .author = author,
    };
}

/// Put `path` into superposition with `candidates`, `primary` materialized.
///
/// Append-only: a later record for the same path supersedes the earlier one, so
/// re-recording after a second merge is a normal append and never a rewrite.
pub fn record(store: *Store, path: []const u8, candidates: []const Candidate, primary: u8) !void {
    if (candidates.len == 0) return Error.NoSuchCandidate;
    var ok = false;
    for (candidates) |c| {
        if (c.label == primary) ok = true;
    }
    if (!ok) return Error.NoSuchCandidate;
    try appendRecord(store, path, candidates, primary, nowSeconds(store));
}

/// Append the tombstone that takes `path` out of superposition. The candidate
/// blobs are untouched, because the losing candidate must stay readable.
fn tombstone(store: *Store, path: []const u8) !void {
    try appendRecord(store, path, &.{}, '-', nowSeconds(store));
}

// --- reading ---

/// Every path currently in superposition, in the order each first appeared.
/// The last record for a path wins, and a tombstone drops it. Free with
/// `freeAll`.
pub fn list(store: *Store, alloc: std.mem.Allocator) ![]Superposed {
    const data = try applog.readAll(store, alloc, log_path);
    defer alloc.free(data);

    var out: std.ArrayList(Superposed) = .empty;
    errdefer {
        for (out.items) |s| s.deinit(alloc);
        out.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const parsed = (parseLine(alloc, line) catch continue) orelse continue;

        var replaced = false;
        for (out.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing.path, parsed.path)) continue;
            existing.deinit(alloc);
            out.items[i] = parsed;
            replaced = true;
            break;
        }
        if (!replaced) try out.append(alloc, parsed);
    }

    // Drop tombstoned paths only after the replay, so a collapse followed by a
    // fresh conflict on the same path comes back cleanly.
    var i: usize = 0;
    while (i < out.items.len) {
        if (out.items[i].candidates.len == 0) {
            const dead = out.orderedRemove(i);
            dead.deinit(alloc);
        } else {
            i += 1;
        }
    }

    return out.toOwnedSlice(alloc);
}

pub fn freeAll(alloc: std.mem.Allocator, items: []Superposed) void {
    for (items) |s| s.deinit(alloc);
    alloc.free(items);
}

/// The superposition for one path, or null. Caller frees with `deinit`.
pub fn get(store: *Store, alloc: std.mem.Allocator, path: []const u8) !?Superposed {
    const items = try list(store, alloc);
    defer alloc.free(items);

    var found: ?Superposed = null;
    for (items) |s| {
        if (found == null and std.mem.eql(u8, s.path, path)) {
            found = s;
        } else {
            s.deinit(alloc);
        }
    }
    return found;
}

/// True when `path` is currently superposed. Swallows read errors, because a
/// caller asking this question is deciding how to print a line, not deciding
/// whether the repo is intact.
pub fn isSuperposed(store: *Store, alloc: std.mem.Allocator, path: []const u8) bool {
    const found = get(store, alloc, path) catch return false;
    if (found) |s| {
        s.deinit(alloc);
        return true;
    }
    return false;
}

/// How many paths are superposed right now, for the `merge.max_superposed` cap.
pub fn count(store: *Store, alloc: std.mem.Allocator) !usize {
    const items = try list(store, alloc);
    defer freeAll(alloc, items);
    return items.len;
}

// --- the worktree ---

fn writeWorktree(store: *Store, work_dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirnamePosix(path)) |dir| {
        try work_dir.createDirPath(store.io, dir);
    }
    try work_dir.writeFile(store.io, .{ .sub_path = path, .data = data });
}

/// Write the primary candidate's bytes to the worktree, verbatim.
///
/// This is the whole point: the file on disk is one complete version somebody
/// wrote, with no markers in it, so the tree compiles, grades, and can be handed
/// to an agent while the conflict is still open.
pub fn materializePrimary(store: *Store, work_dir: std.Io.Dir, s: Superposed) !void {
    const c = try s.primaryCandidate();
    const data = try store.readFileContent(c.blob);
    defer store.alloc.free(data);
    try writeWorktree(store, work_dir, s.path, data);
}

// --- collapse ---

/// How a superposition is resolved.
pub const Choice = union(enum) {
    /// Keep the candidate carrying this label.
    label: u8,
    /// Keep the candidate with the best verdict. Requires evidence.
    greenest,
    /// Keep neither candidate: the supplied bytes are the resolution.
    edit: []const u8,
};

/// A candidate label paired with the tree Oid the candidate belongs to, which
/// is what a verdict is actually keyed by. Verdicts are per-tree, never per-file,
/// so answering "which candidate is greenest" needs this mapping from the caller.
pub const CandidateTree = struct { label: u8, tree: Oid };

/// Everything needed to turn `greenest` into an answer. Absent or incomplete
/// evidence is reported, never guessed around.
pub const Evidence = struct {
    index: ?*const verdict.Index = null,
    command_fast: Oid = Oid.zero(),
    command_full: Oid = Oid.zero(),
    trees: []const CandidateTree = &.{},

    /// The verdict for a candidate, or null when nothing graded its tree.
    pub fn verdictFor(self: Evidence, label: u8) ?verdict.Verdict {
        const ix = self.index orelse return null;
        for (self.trees) |t| {
            if (t.label == label) return ix.best(t.tree, self.command_fast, self.command_full);
        }
        return null;
    }
};

/// What a collapse actually did. `fell_back_to_primary` is the honest answer to
/// "pick the greenest" when nothing has been graded: the primary is kept and the
/// caller is told, rather than a candidate being silently guessed at.
pub const Outcome = enum {
    chosen,
    fell_back_to_primary,
    edited,
};

/// Rank two verdicts. Green beats red; among greens a warranted green beats a
/// hollow one, because a green that only agrees with itself is not evidence.
fn better(a: ?verdict.Verdict, b: ?verdict.Verdict) bool {
    const va = a orelse return false;
    const vb = b orelse return true;
    if (va.isGreen() != vb.isGreen()) return va.isGreen();
    if (va.isHollow() != vb.isHollow()) return !va.isHollow();
    return false;
}

fn greenestLabel(s: Superposed, ev: ?Evidence) ?u8 {
    const e = ev orelse return null;
    if (e.index == null or e.trees.len == 0) return null;

    var best: ?u8 = null;
    var best_v: ?verdict.Verdict = null;
    for (s.candidates) |c| {
        const v = e.verdictFor(c.label) orelse continue;
        if (best == null or better(v, best_v)) {
            best = c.label;
            best_v = v;
        }
    }
    return best;
}

/// Resolve `path`: write one version into the worktree and take the path out of
/// superposition.
///
/// The losing candidate's blob is deliberately never deleted. Content addressing
/// means it costs nothing to keep, and keeping it is what makes the collapse a
/// decision rather than a destruction: the record stays in the append-only log
/// and every candidate stays readable from the store afterwards.
///
/// A collapse also appends an `oplog` record so it lands on the undo stack and
/// `gr undo` walks back over it like any other operation.
pub fn collapse(
    store: *Store,
    work_dir: std.Io.Dir,
    alloc: std.mem.Allocator,
    path: []const u8,
    choice: Choice,
    ev: ?Evidence,
) !Outcome {
    const s = (try get(store, alloc, path)) orelse return Error.NotSuperposed;
    defer s.deinit(alloc);

    var outcome: Outcome = .chosen;
    var data: []u8 = undefined;
    switch (choice) {
        .edit => |content| {
            // Neither candidate wins; the supplied bytes are the resolution.
            // They are stored as a blob too, so the resolution is addressable.
            _ = try store.writeFileContent(content);
            data = try alloc.dupe(u8, content);
            outcome = .edited;
        },
        .label => |want| {
            const c = s.find(want) orelse return Error.NoSuchCandidate;
            data = try store.readFileContent(c.blob);
        },
        .greenest => {
            const picked = greenestLabel(s, ev) orelse blk: {
                outcome = .fell_back_to_primary;
                break :blk s.primary;
            };
            const c = s.find(picked) orelse return Error.NoSuchCandidate;
            data = try store.readFileContent(c.blob);
        },
    }
    defer alloc.free(data);

    try writeWorktree(store, work_dir, path, data);
    try tombstone(store, path);

    const branch = try store.headBranch();
    defer alloc.free(branch);
    // The collapse moves no ref, so `prev` and `new` are the current tip: the
    // record exists to put the collapse on the undo stack, and undoing it is
    // safe precisely because no candidate blob was destroyed.
    const tip = store.readRef(branch) catch Oid.zero();
    try oplog.record(store, .{
        .kind = .other,
        .branch = branch,
        .prev = tip,
        .new = tip,
        .timestamp = nowSeconds(store),
    });

    return outcome;
}

// --- rendering ---

fn padded(w: *std.Io.Writer, s: []const u8, width: usize) !void {
    try w.writeAll(s);
    var i = s.len;
    while (i < width) : (i += 1) try w.writeByte(' ');
}

fn writeVerdictCells(w: *std.Io.Writer, v: ?verdict.Verdict) !void {
    const got = v orelse {
        // No evidence is a real answer and gets said plainly. Grading a
        // candidate is optional, and an ungraded candidate is not a worse one.
        try w.writeAll("ungraded");
        return;
    };
    if (got.isGreen()) {
        try padded(w, got.result.label(), 7);
        try padded(w, got.tier.label(), 6);
        try padded(w, got.independence.label(), 13);
        try w.writeAll(got.discrimination.label());
    } else {
        try padded(w, got.result.label(), 7);
        try padded(w, got.tier.label(), 6);
        try w.print("check failed (exit {d})", .{got.exit_code});
    }
}

/// The `gr super` listing: every superposed path and every candidate under it.
///
/// Verdict information is optional; a candidate with no verdict prints
/// `ungraded`. The header names when the alternatives were frozen, because they
/// are frozen: they are not rebased onto the primary as it moves, and pretending
/// otherwise would be the one dishonest thing this feature could do.
pub fn renderStatus(w: *std.Io.Writer, items: []const Superposed, ev: ?Evidence) !void {
    for (items) |s| {
        try w.print("{s}  ({d} candidates, primary {c}, alternatives frozen at {d})\n", .{
            s.path,
            s.candidates.len,
            s.primary,
            s.frozen_at,
        });
        for (s.candidates) |c| {
            var hex: [Oid.len * 2]u8 = undefined;
            _ = c.blob.toHex(&hex);
            try w.print("  {c}  ", .{c.label});
            try padded(w, c.origin, 8);
            if (c.moment_id.len == 0) {
                try padded(w, "@", 9);
            } else {
                var mbuf: [10]u8 = undefined;
                const n = @min(c.moment_id.len, 6);
                mbuf[0] = '@';
                @memcpy(mbuf[1 .. 1 + n], c.moment_id[0..n]);
                try padded(w, mbuf[0 .. 1 + n], 9);
            }
            try padded(w, c.author, 13);
            try writeVerdictCells(w, if (ev) |e| e.verdictFor(c.label) else null);
            try w.writeByte('\n');
        }
    }
}

/// The one-line warning `gr status` prints whenever anything is superposed.
///
/// Safety property: a superposed path must never be invisible. The worktree
/// builds, so nothing else will tell you a decision is still outstanding; this
/// line is the thing that keeps the listing reachable.
pub fn statusLine(w: *std.Io.Writer, n: usize) !void {
    if (n == 0) return;
    try w.print("{d} path{s} superposed (worktree holds the primary) - run `gr super`\n", .{
        n,
        if (n == 1) "" else "s",
    });
}

// --- tests ---

const testing = std.testing;

fn twoCandidates(store: *Store) ![2]Candidate {
    return .{
        try candidateFromContent(store, 'A', "ours", "fn main() {}\n", "aabbccdd", "you"),
        try candidateFromContent(store, 'B', "theirs", "fn main() { work(); }\n", "11223344", "claude-code"),
    };
}

test "record and read back a path with two candidates" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cands = try twoCandidates(&store);
    try record(&store, "src/main.zig", &cands, 'A');

    const got = (try get(&store, alloc, "src/main.zig")).?;
    defer got.deinit(alloc);
    try testing.expectEqualStrings("src/main.zig", got.path);
    try testing.expectEqual(@as(u8, 'A'), got.primary);
    try testing.expectEqual(@as(usize, 2), got.candidates.len);
    try testing.expectEqualStrings("ours", got.candidates[0].origin);
    try testing.expectEqualStrings("claude-code", got.candidates[1].author);
    try testing.expectEqualStrings("11223344", got.candidates[1].moment_id);
    try testing.expect(got.candidates[0].blob.eql(cands[0].blob));

    // Both candidates are complete, individually valid files, not hunks.
    const a = try store.readFileContent(got.candidates[0].blob);
    defer alloc.free(a);
    try testing.expectEqualStrings("fn main() {}\n", a);
}

test "weird paths, origins and authors roundtrip exactly" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const path = "src/we\tird\\path\nwith junk.zig";
    const cands = [_]Candidate{
        try candidateFromContent(&store, 'A', "branch\twith\ttabs", "one\n", "", "a\\uthor\nnewline"),
        try candidateFromContent(&store, 'B', "theirs", "two\n", "cafebabe", "b\tb"),
    };
    try record(&store, path, &cands, 'B');

    const got = (try get(&store, alloc, path)).?;
    defer got.deinit(alloc);
    try testing.expectEqualStrings(path, got.path);
    try testing.expectEqual(@as(u8, 'B'), got.primary);
    try testing.expectEqualStrings("branch\twith\ttabs", got.candidates[0].origin);
    try testing.expectEqualStrings("a\\uthor\nnewline", got.candidates[0].author);
    try testing.expectEqualStrings("", got.candidates[0].moment_id);
    try testing.expectEqualStrings("b\tb", got.candidates[1].author);
}

test "merge.superpose defaults to false and merge.primary to ours" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const fresh = settings(&store, alloc);
    // An existing repo gets today's behaviour, unchanged, until it opts in.
    try testing.expect(!fresh.superpose);
    // Not `greenest`: evidence is not the automatic tiebreak on day one.
    try testing.expectEqual(Primary.ours, fresh.primary);
    try testing.expectEqual(@as(usize, 16), fresh.max_superposed);

    try config.set(&store, "merge.superpose", "true");
    try config.set(&store, "merge.primary", "greenest");
    try config.set(&store, "merge.max_superposed", "3");
    const opted = settings(&store, alloc);
    try testing.expect(opted.superpose);
    try testing.expectEqual(Primary.greenest, opted.primary);
    try testing.expectEqual(@as(usize, 3), opted.max_superposed);

    // A typo falls back rather than erroring.
    try config.set(&store, "merge.primary", "nonsense");
    try testing.expectEqual(Primary.ours, settings(&store, alloc).primary);
}

test "materializePrimary writes exactly the primary candidate's bytes" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const cands = [_]Candidate{
        try candidateFromContent(&store, 'A', "ours", "fn main() {}\n", "", "you"),
        try candidateFromContent(&store, 'B', "theirs", "fn main() { work(); }\n", "", "claude-code"),
    };
    try record(&store, "sub/dir/main.zig", &cands, 'B');

    const s = (try get(&store, alloc, "sub/dir/main.zig")).?;
    defer s.deinit(alloc);
    try materializePrimary(&store, work, s);

    const on_disk = try work.readFileAlloc(io, "sub/dir/main.zig", alloc, .unlimited);
    defer alloc.free(on_disk);
    // Byte-exact, and with no conflict markers in it: the tree still builds.
    try testing.expectEqualStrings("fn main() { work(); }\n", on_disk);
    try testing.expect(std.mem.indexOf(u8, on_disk, "<<<<<<<") == null);
}

test "count is accurate and the cap is readable" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expectEqual(@as(usize, 0), try count(&store, alloc));

    const cands = try twoCandidates(&store);
    try record(&store, "a.zig", &cands, 'A');
    try record(&store, "b.zig", &cands, 'A');
    try testing.expectEqual(@as(usize, 2), try count(&store, alloc));

    // Re-recording a path supersedes rather than accumulates.
    try record(&store, "a.zig", &cands, 'B');
    try testing.expectEqual(@as(usize, 2), try count(&store, alloc));
    const again = (try get(&store, alloc, "a.zig")).?;
    defer again.deinit(alloc);
    try testing.expectEqual(@as(u8, 'B'), again.primary);

    try config.set(&store, "merge.max_superposed", "2");
    try testing.expect(try count(&store, alloc) >= settings(&store, alloc).max_superposed);
}

test "isSuperposed tracks entry and exit" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    try testing.expect(!isSuperposed(&store, alloc, "a.zig"));
    const cands = try twoCandidates(&store);
    try record(&store, "a.zig", &cands, 'A');
    try testing.expect(isSuperposed(&store, alloc, "a.zig"));

    _ = try collapse(&store, work, alloc, "a.zig", .{ .label = 'A' }, null);
    try testing.expect(!isSuperposed(&store, alloc, "a.zig"));
    try testing.expectEqual(@as(usize, 0), try count(&store, alloc));
}

test "collapse to a label writes it, logs an op, and keeps the loser readable" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const cands = try twoCandidates(&store);
    const loser = cands[1].blob;
    try record(&store, "main.zig", &cands, 'B');

    try testing.expect((try oplog.lastOp(&store, alloc)) == null);
    const outcome = try collapse(&store, work, alloc, "main.zig", .{ .label = 'A' }, null);
    try testing.expectEqual(Outcome.chosen, outcome);

    const on_disk = try work.readFileAlloc(io, "main.zig", alloc, .unlimited);
    defer alloc.free(on_disk);
    try testing.expectEqualStrings("fn main() {}\n", on_disk);

    // The collapse is on the undo stack.
    const op = (try oplog.lastOp(&store, alloc)).?;
    defer alloc.free(op.branch);
    try testing.expectEqual(oplog.OpKind.other, op.kind);
    try testing.expectEqualStrings("main", op.branch);

    // The losing blob was not deleted, and never will be.
    const kept = try store.readFileContent(loser);
    defer alloc.free(kept);
    try testing.expectEqualStrings("fn main() { work(); }\n", kept);

    try testing.expectError(Error.NotSuperposed, collapse(&store, work, alloc, "main.zig", .{ .label = 'A' }, null));
}

test "collapse to an edit writes neither candidate" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const cands = try twoCandidates(&store);
    try record(&store, "main.zig", &cands, 'A');

    const merged = "fn main() { work(); tidy(); }\n";
    try testing.expectEqual(Outcome.edited, try collapse(&store, work, alloc, "main.zig", .{ .edit = merged }, null));

    const on_disk = try work.readFileAlloc(io, "main.zig", alloc, .unlimited);
    defer alloc.free(on_disk);
    try testing.expectEqualStrings(merged, on_disk);
    try testing.expect(!std.mem.eql(u8, on_disk, "fn main() {}\n"));
    try testing.expect(!std.mem.eql(u8, on_disk, "fn main() { work(); }\n"));
    try testing.expect(!isSuperposed(&store, alloc, "main.zig"));
}

test "greenest without evidence falls back to the primary and says so" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const cands = try twoCandidates(&store);
    try record(&store, "main.zig", &cands, 'A');

    const outcome = try collapse(&store, work, alloc, "main.zig", .greenest, null);
    try testing.expectEqual(Outcome.fell_back_to_primary, outcome);

    const on_disk = try work.readFileAlloc(io, "main.zig", alloc, .unlimited);
    defer alloc.free(on_disk);
    try testing.expectEqualStrings("fn main() {}\n", on_disk);
}

test "greenest picks the graded candidate when evidence exists" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const cmd = verdict.commandHash("zig build test");
    const tree_a = Oid.ofBytes("tree for A");
    const tree_b = Oid.ofBytes("tree for B");
    try verdict.record(&store, .{
        .tree = tree_a,
        .tier = .full,
        .command = cmd,
        .result = .red,
        .exit_code = 1,
        .duration_ms = 10,
        .ms = 0,
        .readset = Oid.zero(),
    });
    try verdict.record(&store, .{
        .tree = tree_b,
        .tier = .full,
        .command = cmd,
        .result = .green,
        .exit_code = 0,
        .duration_ms = 10,
        .ms = 0,
        .readset = Oid.zero(),
        .independence = .independent,
        .discrimination = .discriminating,
    });

    var ix = try verdict.Index.load(&store, alloc);
    defer ix.deinit();
    const trees = [_]CandidateTree{
        .{ .label = 'A', .tree = tree_a },
        .{ .label = 'B', .tree = tree_b },
    };
    const ev = Evidence{
        .index = &ix,
        .command_fast = verdict.commandHash(""),
        .command_full = cmd,
        .trees = &trees,
    };

    const cands = try twoCandidates(&store);
    // Primary is A (red); asking for the greenest must move to B.
    try record(&store, "main.zig", &cands, 'A');
    try testing.expectEqual(Outcome.chosen, try collapse(&store, work, alloc, "main.zig", .greenest, ev));

    const on_disk = try work.readFileAlloc(io, "main.zig", alloc, .unlimited);
    defer alloc.free(on_disk);
    try testing.expectEqualStrings("fn main() { work(); }\n", on_disk);
}

test "renderStatus prints a row per candidate and ungraded without evidence" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cands = try twoCandidates(&store);
    try record(&store, "src/main.zig", &cands, 'A');

    const items = try list(&store, alloc);
    defer freeAll(alloc, items);

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try renderStatus(&out.writer, items, null);
    const text = out.written();

    try testing.expect(std.mem.indexOf(u8, text, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  A  ours") != null);
    try testing.expect(std.mem.indexOf(u8, text, "  B  theirs") != null);
    try testing.expect(std.mem.indexOf(u8, text, "claude-code") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@aabbcc") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ungraded") != null);
    // Alternatives are frozen, and the listing says so rather than implying
    // they track the primary.
    try testing.expect(std.mem.indexOf(u8, text, "frozen") != null);
}

test "statusLine warns only when something is superposed" {
    const alloc = testing.allocator;

    var quiet: std.Io.Writer.Allocating = .init(alloc);
    defer quiet.deinit();
    try statusLine(&quiet.writer, 0);
    try testing.expectEqualStrings("", quiet.written());

    var loud: std.Io.Writer.Allocating = .init(alloc);
    defer loud.deinit();
    try statusLine(&loud.writer, 3);
    try testing.expect(std.mem.indexOf(u8, loud.written(), "3 paths superposed") != null);
    try testing.expect(std.mem.indexOf(u8, loud.written(), "gr super") != null);
}

test "record rejects a primary that is not one of its candidates" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const cands = try twoCandidates(&store);
    try testing.expectError(Error.NoSuchCandidate, record(&store, "a.zig", &cands, 'Z'));
    try testing.expectError(Error.NoSuchCandidate, record(&store, "a.zig", &.{}, 'A'));
    try testing.expectEqual(@as(usize, 0), try count(&store, alloc));
}

test "labels are distinct for as many candidates as anyone will ever record" {
    var seen: [40]u8 = undefined;
    for (0..40) |i| seen[i] = labelFor(i);
    for (0..40) |i| {
        for (i + 1..40) |j| try testing.expect(seen[i] != seen[j]);
    }
    try testing.expectEqual(@as(u8, 'A'), labelFor(0));
    try testing.expectEqual(@as(u8, 'B'), labelFor(1));
}
