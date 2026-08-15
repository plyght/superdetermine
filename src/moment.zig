const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const applog = @import("applog.zig");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Continuous capture.
///
/// A moment is a content-addressed tree with a stable id, a timestamp, and a
/// cause. It is not a change: moments never enter `sdt log`, have no parents, no
/// author, and no message, so nothing can promote one into history by accident.
///
/// Storage is split in two:
///   `.sdt/moments/log`  one appended line per moment (metadata only)
///   the object store   the tree representation, either a keyframe or a delta
///
/// The representation is what keeps capture affordable. A flat tree of a 10k
/// file repo is ~700 KB, so storing one per moment would cost gigabytes an hour.
/// Instead each moment stores a delta against the previous moment's
/// representation, and every `keyframe_interval` moments stores a full tree. A
/// single-file edit becomes well under 100 bytes.
///
/// Losslessness is a test rather than a promise: every moment also records the
/// Oid the full flat tree *would* have had, and reconstruction recomputes that
/// Oid and compares. A mismatch is `error.MomentCorrupt`, never a best-effort
/// partial recovery, because a silently wrong reconstruction is worse than a
/// loud failure.
pub const MomentId = [8]u8;

pub const log_path = "moments/log";

/// How many captures pass between age-based retention sweeps. The count cap is
/// enforced exactly (the length is already known at capture time); this only
/// bounds how stale the time window may get.
const trim_interval: usize = 64;

pub const Error = error{
    MomentCorrupt,
    MomentNotFound,
    InvalidMomentRecord,
};

pub const Cause = enum {
    /// The content-signature poll noticed the tree changed.
    poll,
    /// Captured defensively before a mutating `gr` command ran.
    command,
    /// The user asked for a checkpoint explicitly.
    save,
    /// Captured just before a rewind, so the state being left stays addressable.
    rewind,
    /// Captured as part of a merge or pull.
    merge,
    /// Captured when a workspace was forked at this state.
    fork,

    pub fn label(self: Cause) []const u8 {
        return @tagName(self);
    }

    pub fn fromLabel(s: []const u8) Cause {
        inline for (@typeInfo(Cause).@"enum".fields) |f| {
            if (std.mem.eql(u8, s, f.name)) return @field(Cause, f.name);
        }
        return .poll;
    }
};

pub const ReprKind = enum {
    keyframe,
    delta,

    pub fn label(self: ReprKind) []const u8 {
        return switch (self) {
            .keyframe => "k",
            .delta => "d",
        };
    }
};

pub const Moment = struct {
    id: MomentId,
    /// Unix milliseconds. Milliseconds, not seconds, because two moments a poll
    /// apart must not collide in the id hash.
    ms: i64,
    /// The Oid a full flat `object.Tree` of this state would hash to. This is
    /// the reconstruction check, and it is also what makes a verdict cache key
    /// stable across keyframe boundaries.
    full_tree: Oid,
    /// The stored representation: a tree object for a keyframe, a delta object
    /// otherwise.
    repr: Oid,
    kind: ReprKind,
    cause: Cause,
    /// Heap-allocated when read back; borrowed when written.
    branch: []const u8,

    pub fn shortId(self: Moment, buf: []u8) []const u8 {
        std.debug.assert(buf.len >= 16);
        const hex = "0123456789abcdef";
        for (self.id, 0..) |b, i| {
            buf[i * 2] = hex[b >> 4];
            buf[i * 2 + 1] = hex[b & 0x0f];
        }
        return buf[0..16];
    }
};

pub fn freeMoments(alloc: std.mem.Allocator, list: []Moment) void {
    for (list) |m| alloc.free(m.branch);
    alloc.free(list);
}

/// `moment-id` = first 8 bytes of BLAKE3("gr-moment-v1" || branch || tree || ms).
/// Domain-separated so a moment id can never be confused with any other digest
/// in the system, and branch-qualified so the same tree captured on two branches
/// gets two ids.
pub fn computeId(branch: []const u8, tree: Oid, ms: i64) MomentId {
    var hasher = oid.Hasher.init();
    // Deliberately still "gr-moment-v1" after the rename: this digest produces
    // moment ids that are already written into `moments/log`, and re-spelling
    // the domain would silently invalidate every id ever recorded.
    hasher.update("gr-moment-v1");
    hasher.update(branch);
    hasher.update(&tree.bytes);
    var ms_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &ms_buf, @bitCast(ms), .big);
    hasher.update(&ms_buf);
    const full = hasher.finalOid();
    var out: MomentId = undefined;
    @memcpy(&out, full.bytes[0..8]);
    return out;
}

pub fn parseId(s: []const u8) !MomentId {
    if (s.len != 16) return Error.InvalidMomentRecord;
    var out: MomentId = undefined;
    _ = try std.fmt.hexToBytes(&out, s);
    return out;
}

// --- settings ---

pub const Settings = struct {
    /// On by default. "Nothing is ever unsaved" is the whole claim, and a claim
    /// that only holds after you find a config key is not a claim. Capture is
    /// local, writes well under a kilobyte per moment, and runs nothing of the
    /// user's; `moments.enabled = false` turns it off.
    enabled: bool = true,
    interval_ms: u32 = 800,
    /// Retention window in seconds.
    retain_s: i64 = 14 * 24 * 60 * 60,
    max: usize = 10_000,
    keyframe_interval: usize = 200,
};

fn boolOf(v: []const u8) bool {
    return !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no"));
}

/// Parse a retention string: bare seconds, or a `<n><unit>` suffix where unit is
/// one of s/m/h/d. Invalid input falls back to the default rather than erroring,
/// because a typo in config must not take capture down.
pub fn parseDuration(s: []const u8, fallback: i64) i64 {
    if (s.len == 0) return fallback;
    const unit = s[s.len - 1];
    const mult: i64 = switch (unit) {
        's' => 1,
        'm' => 60,
        'h' => 60 * 60,
        'd' => 24 * 60 * 60,
        else => 0,
    };
    const digits = if (mult == 0) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(i64, digits, 10) catch return fallback;
    return n * (if (mult == 0) @as(i64, 1) else mult);
}

pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "moments.enabled")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.enabled = boolOf(v);
        }
    } else |_| {}
    if (config.get(store, alloc, "moments.interval_ms")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.interval_ms = std.fmt.parseInt(u32, v, 10) catch out.interval_ms;
        }
    } else |_| {}
    if (config.get(store, alloc, "moments.retain")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.retain_s = parseDuration(v, out.retain_s);
        }
    } else |_| {}
    if (config.get(store, alloc, "moments.max")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.max = std.fmt.parseInt(usize, v, 10) catch out.max;
        }
    } else |_| {}
    if (config.get(store, alloc, "moments.keyframe_interval")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            const n = std.fmt.parseInt(usize, v, 10) catch out.keyframe_interval;
            out.keyframe_interval = @max(1, n);
        }
    } else |_| {}
    return out;
}

// --- delta representation ---

const delta_tag: u8 = 'D';

/// A delta against a base representation. `removed` and `upserted` are both
/// sorted by path; upsert covers both "added" and "modified" because the
/// distinction costs a lookup and buys nothing at apply time.
const Delta = struct {
    base: Oid,
    removed: []const []const u8,
    upserted: []const object.TreeEntry,

    fn encode(self: Delta, alloc: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(alloc);
        try out.append(alloc, delta_tag);
        try out.appendSlice(alloc, &self.base.bytes);
        try putU32(&out, alloc, @intCast(self.removed.len));
        for (self.removed) |p| {
            try putU16(&out, alloc, @intCast(p.len));
            try out.appendSlice(alloc, p);
        }
        try putU32(&out, alloc, @intCast(self.upserted.len));
        for (self.upserted) |e| {
            try putU32(&out, alloc, @intFromEnum(e.mode));
            try out.appendSlice(alloc, &e.blob.bytes);
            try putU16(&out, alloc, @intCast(e.path.len));
            try out.appendSlice(alloc, e.path);
        }
        return out.toOwnedSlice(alloc);
    }
};

fn putU16(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .big);
    try list.appendSlice(alloc, &buf);
}

fn putU32(list: *std.ArrayList(u8), alloc: std.mem.Allocator, v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .big);
    try list.appendSlice(alloc, &buf);
}

const Cursor = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return Error.MomentCorrupt;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn u16v(self: *Cursor) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .big);
    }
    fn u32v(self: *Cursor) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .big);
    }
    fn oidv(self: *Cursor) !Oid {
        var o: Oid = undefined;
        @memcpy(&o.bytes, try self.take(Oid.len));
        return o;
    }
};

/// Compute the delta taking `base` to `next`. Both must be sorted by path.
fn diffEntries(
    alloc: std.mem.Allocator,
    base: []const object.TreeEntry,
    next: []const object.TreeEntry,
    removed: *std.ArrayList([]const u8),
    upserted: *std.ArrayList(object.TreeEntry),
) !void {
    var i: usize = 0;
    var j: usize = 0;
    while (i < base.len and j < next.len) {
        const ord = std.mem.order(u8, base[i].path, next[j].path);
        switch (ord) {
            .lt => {
                try removed.append(alloc, base[i].path);
                i += 1;
            },
            .gt => {
                try upserted.append(alloc, next[j]);
                j += 1;
            },
            .eq => {
                if (!base[i].blob.eql(next[j].blob) or base[i].mode != next[j].mode) {
                    try upserted.append(alloc, next[j]);
                }
                i += 1;
                j += 1;
            },
        }
    }
    while (i < base.len) : (i += 1) try removed.append(alloc, base[i].path);
    while (j < next.len) : (j += 1) try upserted.append(alloc, next[j]);
}

/// Apply a delta to a base entry list, producing a new sorted list. Entries are
/// deep-copied so the result owns its paths independently of either input.
fn applyDelta(
    alloc: std.mem.Allocator,
    base: []const object.TreeEntry,
    d: Delta,
) ![]object.TreeEntry {
    var out: std.ArrayList(object.TreeEntry) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e.path);
        out.deinit(alloc);
    }

    var removed_idx: usize = 0;
    var up_idx: usize = 0;
    var i: usize = 0;

    // All three inputs are path-sorted, so one merge pass suffices.
    while (i < base.len or up_idx < d.upserted.len) {
        if (i < base.len) {
            // Drop this base path if the delta removed it.
            while (removed_idx < d.removed.len and
                std.mem.order(u8, d.removed[removed_idx], base[i].path) == .lt)
            {
                removed_idx += 1;
            }
            if (removed_idx < d.removed.len and
                std.mem.eql(u8, d.removed[removed_idx], base[i].path))
            {
                i += 1;
                continue;
            }
        }

        const take_upsert = if (i >= base.len)
            true
        else if (up_idx >= d.upserted.len)
            false
        else switch (std.mem.order(u8, d.upserted[up_idx].path, base[i].path)) {
            .lt => true,
            .eq => blk: {
                // An upsert of an existing path shadows the base entry.
                i += 1;
                break :blk true;
            },
            .gt => false,
        };

        const src = if (take_upsert) d.upserted[up_idx] else base[i];
        if (take_upsert) up_idx += 1 else i += 1;

        try out.append(alloc, .{
            .mode = src.mode,
            .path = try alloc.dupe(u8, src.path),
            .blob = src.blob,
        });
    }

    return out.toOwnedSlice(alloc);
}

// --- representation read/write ---

/// Read one representation object and, if it is a delta, report its base.
/// Returns entries only for a keyframe.
const Loaded = union(enum) {
    keyframe: []object.TreeEntry,
    delta: struct { base: Oid, raw: []u8 },
};

fn loadRepr(store: *Store, o: Oid) !Loaded {
    const alloc = store.alloc;
    const raw = store.readRaw(o) catch return Error.MomentNotFound;
    if (raw.len == 0) {
        alloc.free(raw);
        return Error.MomentCorrupt;
    }
    if (raw[0] == delta_tag) {
        var cur = Cursor{ .data = raw, .pos = 1 };
        const base = cur.oidv() catch {
            alloc.free(raw);
            return Error.MomentCorrupt;
        };
        return .{ .delta = .{ .base = base, .raw = raw } };
    }
    defer alloc.free(raw);
    const tree = object.Tree.decode(alloc, raw) catch return Error.MomentCorrupt;
    // Hand back a mutable slice with the same ownership contract as elsewhere.
    return .{ .keyframe = @constCast(tree.entries) };
}

fn decodeDeltaBody(alloc: std.mem.Allocator, raw: []const u8) !Delta {
    var cur = Cursor{ .data = raw, .pos = 1 };
    const base = try cur.oidv();

    const n_removed = try cur.u32v();
    const removed = try alloc.alloc([]const u8, n_removed);
    errdefer alloc.free(removed);
    for (removed) |*p| {
        const len = try cur.u16v();
        p.* = try cur.take(len);
    }

    const n_up = try cur.u32v();
    const upserted = try alloc.alloc(object.TreeEntry, n_up);
    errdefer alloc.free(upserted);
    for (upserted) |*e| {
        e.mode = @enumFromInt(try cur.u32v());
        e.blob = try cur.oidv();
        const len = try cur.u16v();
        e.path = try cur.take(len);
    }

    return .{ .base = base, .removed = removed, .upserted = upserted };
}

/// Reconstruct the full sorted entry list for a moment, then verify it against
/// the recorded full-tree Oid. Free with `workspace.freeTreeEntries`.
pub fn entriesOf(store: *Store, m: Moment) ![]object.TreeEntry {
    const alloc = store.alloc;

    // Walk back to the nearest keyframe, collecting delta bodies, then apply
    // them forward. Iterative rather than recursive so a long chain cannot
    // blow the stack.
    var chain: std.ArrayList([]u8) = .empty;
    defer {
        for (chain.items) |raw| alloc.free(raw);
        chain.deinit(alloc);
    }

    var entries: []object.TreeEntry = undefined;
    var cursor = m.repr;
    while (true) {
        const loaded = try loadRepr(store, cursor);
        switch (loaded) {
            .keyframe => |e| {
                entries = e;
                break;
            },
            .delta => |d| {
                try chain.append(alloc, d.raw);
                cursor = d.base;
            },
        }
        if (chain.items.len > 1_000_000) return Error.MomentCorrupt;
    }
    errdefer workspace.freeTreeEntries(alloc, entries);

    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        const d = try decodeDeltaBody(alloc, chain.items[i]);
        defer {
            alloc.free(d.removed);
            alloc.free(d.upserted);
        }
        const next = try applyDelta(alloc, entries, d);
        workspace.freeTreeEntries(alloc, entries);
        entries = next;
    }

    // The losslessness test. Cheap (one encode + hash) and absolute.
    const enc = try object.Tree.encode(.{ .entries = entries }, alloc);
    defer alloc.free(enc);
    if (!Oid.ofBytes(enc).eql(m.full_tree)) {
        workspace.freeTreeEntries(alloc, entries);
        return Error.MomentCorrupt;
    }

    return entries;
}

// --- the log ---

fn formatLine(alloc: std.mem.Allocator, m: Moment) ![]u8 {
    var id_hex: [16]u8 = undefined;
    _ = m.shortId(&id_hex);
    var full_hex: [Oid.len * 2]u8 = undefined;
    _ = m.full_tree.toHex(&full_hex);
    var repr_hex: [Oid.len * 2]u8 = undefined;
    _ = m.repr.toHex(&repr_hex);
    return std.fmt.allocPrint(alloc, "{s} {d} {s} {s} {s} {s}\t{s}\n", .{
        &id_hex,
        m.ms,
        &full_hex,
        &repr_hex,
        m.kind.label(),
        m.cause.label(),
        m.branch,
    });
}

fn parseLine(alloc: std.mem.Allocator, line: []const u8) !Moment {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return Error.InvalidMomentRecord;
    const head = line[0..tab];
    const branch = line[tab + 1 ..];

    var it = std.mem.splitScalar(u8, head, ' ');
    const id_s = it.next() orelse return Error.InvalidMomentRecord;
    const ms_s = it.next() orelse return Error.InvalidMomentRecord;
    const full_s = it.next() orelse return Error.InvalidMomentRecord;
    const repr_s = it.next() orelse return Error.InvalidMomentRecord;
    const kind_s = it.next() orelse return Error.InvalidMomentRecord;
    const cause_s = it.next() orelse return Error.InvalidMomentRecord;

    return .{
        .id = try parseId(id_s),
        .ms = std.fmt.parseInt(i64, ms_s, 10) catch return Error.InvalidMomentRecord,
        .full_tree = Oid.fromHex(full_s) catch return Error.InvalidMomentRecord,
        .repr = Oid.fromHex(repr_s) catch return Error.InvalidMomentRecord,
        .kind = if (std.mem.eql(u8, kind_s, "k")) .keyframe else .delta,
        .cause = Cause.fromLabel(cause_s),
        .branch = try alloc.dupe(u8, branch),
    };
}

/// Every moment in capture order. Malformed lines are skipped rather than
/// fatal, so one corrupt append cannot make the whole history unreadable.
/// Free with `freeMoments`.
pub fn readAll(store: *Store, alloc: std.mem.Allocator) ![]Moment {
    const data = try applog.readAll(store, alloc, log_path);
    defer alloc.free(data);

    var list: std.ArrayList(Moment) = .empty;
    errdefer {
        for (list.items) |m| alloc.free(m.branch);
        list.deinit(alloc);
    }

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, data, "\n"), '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const m = parseLine(alloc, line) catch continue;
        try list.append(alloc, m);
    }
    return list.toOwnedSlice(alloc);
}

/// The most recent moment, or null when nothing has been captured.
/// Caller frees `.branch`.
pub fn last(store: *Store, alloc: std.mem.Allocator) !?Moment {
    const all = try readAll(store, alloc);
    defer {
        // Free every branch except the one we hand back.
        for (all[0..if (all.len == 0) 0 else all.len - 1]) |m| alloc.free(m.branch);
        alloc.free(all);
    }
    if (all.len == 0) return null;
    return all[all.len - 1];
}

pub fn count(store: *Store, alloc: std.mem.Allocator) !usize {
    const all = try readAll(store, alloc);
    defer freeMoments(alloc, all);
    return all.len;
}

// --- capture ---

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

pub const CaptureResult = union(enum) {
    /// The tree matched the previous moment exactly; nothing was written.
    unchanged,
    captured: Moment,
};

/// Capture the working tree as a moment. Returns `.unchanged` when the tree is
/// byte-identical to the previous moment, which is the common case on a quiet
/// repo and costs no writes at all.
///
/// The caller owns `.captured.branch`.
pub fn capture(
    store: *Store,
    work_dir: std.Io.Dir,
    cause: Cause,
    set: Settings,
) !CaptureResult {
    const alloc = store.alloc;

    const entries = try workspace.captureEntries(store, work_dir);
    defer workspace.freeTreeEntries(alloc, entries);

    const enc = try object.Tree.encode(.{ .entries = entries }, alloc);
    defer alloc.free(enc);
    const full_tree = Oid.ofBytes(enc);

    // One read of the log, not three. `last`, `count` and `trim` each used to
    // re-read it, which made capturing the n-th moment cost O(n) log parsing
    // and the whole session O(n^2), which is exactly the shape this module exists to
    // avoid, reintroduced one convenience call at a time.
    const existing = try readAll(store, alloc);
    defer freeMoments(alloc, existing);
    const prev: ?Moment = if (existing.len == 0) null else existing[existing.len - 1];

    if (prev) |p| {
        if (p.full_tree.eql(full_tree)) return .unchanged;
    }

    const branch = try store.headBranch();
    errdefer alloc.free(branch);

    const total = existing.len;
    const want_keyframe = prev == null or
        set.keyframe_interval <= 1 or
        total % set.keyframe_interval == 0;

    var kind: ReprKind = .keyframe;
    var repr: Oid = undefined;

    if (want_keyframe) {
        repr = try store.writeRaw(enc);
    } else {
        const base_entries = entriesOf(store, prev.?) catch |e| switch (e) {
            // A broken chain must not stop capture; fall back to a keyframe,
            // which also re-anchors every future delta on solid ground.
            Error.MomentCorrupt, Error.MomentNotFound => {
                repr = try store.writeRaw(enc);
                return try finish(store, alloc, branch, full_tree, repr, .keyframe, cause, set, total);
            },
            else => return e,
        };
        defer workspace.freeTreeEntries(alloc, base_entries);

        var removed: std.ArrayList([]const u8) = .empty;
        defer removed.deinit(alloc);
        var upserted: std.ArrayList(object.TreeEntry) = .empty;
        defer upserted.deinit(alloc);
        try diffEntries(alloc, base_entries, entries, &removed, &upserted);

        const d = Delta{
            .base = prev.?.repr,
            .removed = removed.items,
            .upserted = upserted.items,
        };
        const d_enc = try d.encode(alloc);
        defer alloc.free(d_enc);

        // A delta that is not actually smaller than a keyframe is a waste of a
        // chain link; store the keyframe instead and shorten every future walk.
        if (d_enc.len >= enc.len) {
            repr = try store.writeRaw(enc);
        } else {
            repr = try store.writeRaw(d_enc);
            kind = .delta;
        }
    }

    return try finish(store, alloc, branch, full_tree, repr, kind, cause, set, total);
}

fn finish(
    store: *Store,
    alloc: std.mem.Allocator,
    branch: []u8,
    full_tree: Oid,
    repr: Oid,
    kind: ReprKind,
    cause: Cause,
    set: Settings,
    total: usize,
) !CaptureResult {
    const ms = nowMillis(store.io);
    const m = Moment{
        .id = computeId(branch, full_tree, ms),
        .ms = ms,
        .full_tree = full_tree,
        .repr = repr,
        .kind = kind,
        .cause = cause,
        .branch = branch,
    };

    store.root.createDirPath(store.io, "moments") catch {};
    const line = try formatLine(alloc, m);
    defer alloc.free(line);
    try applog.append(store, log_path, line);

    // Retention almost always decides nothing, and deciding it costs a full
    // log read, so it is not run on every capture. The count is already known
    // here for free, which makes the count cap exact rather than approximate:
    // sweep the moment it is exceeded, and otherwise only periodically, which
    // is all the age-based window needs.
    const over_cap = set.max != 0 and total + 1 > set.max;
    const periodic = (total + 1) % trim_interval == 0;
    if (over_cap or periodic) trim(store, alloc, set) catch {};

    return .{ .captured = m };
}

// --- retention ---

/// Drop moments that are past the retention window or over the count cap.
///
/// Deltas chain backwards, so a moment may only be dropped if no surviving
/// moment's chain reaches it. That is guaranteed by cutting only at a keyframe:
/// everything before the first surviving keyframe is unreachable from anything
/// after it. A cut point with no keyframe at or after it means nothing can be
/// dropped yet, which is correct and self-healing (the next keyframe unblocks
/// it).
pub fn trim(store: *Store, alloc: std.mem.Allocator, set: Settings) !void {
    const all = try readAll(store, alloc);
    defer freeMoments(alloc, all);
    if (all.len == 0) return;

    const now_ms = nowMillis(store.io);
    const cutoff_ms = now_ms - set.retain_s * 1000;

    var want: usize = 0;
    while (want < all.len and all[want].ms < cutoff_ms) want += 1;
    if (all.len - want > set.max) want = all.len - set.max;
    if (want == 0) return;

    if (want >= all.len) {
        try applog.rewrite(store, log_path, "");
        return;
    }

    // Advance to the first keyframe at or after the tentative cut.
    var cut = want;
    while (cut < all.len and all[cut].kind != .keyframe) cut += 1;
    if (cut == 0) return;

    // No keyframe survives the cut. Giving up here is what let a short moment
    // log pin the whole store forever: with a keyframe interval of 200, a repo
    // under 200 moments has exactly one keyframe, at the very start, so every
    // trim bailed out and nothing was ever reclaimable. Re-anchor instead — a
    // delta cannot outlive the keyframe its chain rests on, so rebuild the
    // survivors on a fresh one.
    if (cut >= all.len) return reanchor(store, alloc, all[want..]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    for (all[cut..]) |m| {
        const line = try formatLine(alloc, m);
        defer alloc.free(line);
        try out.appendSlice(alloc, line);
    }
    try applog.rewrite(store, log_path, out.items);
}

/// Rewrite `survivors` so the first is a keyframe and the rest are deltas along
/// the rebuilt chain. Each moment keeps its id, timestamp, cause and full_tree;
/// only the representation changes, so nothing observable about a moment moves.
fn reanchor(store: *Store, alloc: std.mem.Allocator, survivors: []const Moment) !void {
    if (survivors.len == 0) {
        try applog.rewrite(store, log_path, "");
        return;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var prev_entries: ?[]object.TreeEntry = null;
    defer if (prev_entries) |e| workspace.freeTreeEntries(alloc, e);
    var prev_repr: Oid = Oid.zero();

    for (survivors, 0..) |src, i| {
        const entries = try entriesOf(store, src);
        errdefer workspace.freeTreeEntries(alloc, entries);

        var m = src;
        const enc = try object.Tree.encode(.{ .entries = entries }, alloc);
        defer alloc.free(enc);

        if (i == 0) {
            m.repr = try store.writeRaw(enc);
            m.kind = .keyframe;
        } else {
            var removed: std.ArrayList([]const u8) = .empty;
            defer removed.deinit(alloc);
            var upserted: std.ArrayList(object.TreeEntry) = .empty;
            defer upserted.deinit(alloc);
            try diffEntries(alloc, prev_entries.?, entries, &removed, &upserted);

            const d = Delta{
                .base = prev_repr,
                .removed = removed.items,
                .upserted = upserted.items,
            };
            const d_enc = try d.encode(alloc);
            defer alloc.free(d_enc);
            if (d_enc.len >= enc.len) {
                m.repr = try store.writeRaw(enc);
                m.kind = .keyframe;
            } else {
                m.repr = try store.writeRaw(d_enc);
                m.kind = .delta;
            }
        }

        const line = try formatLine(alloc, m);
        defer alloc.free(line);
        try out.appendSlice(alloc, line);

        if (prev_entries) |e| workspace.freeTreeEntries(alloc, e);
        prev_entries = entries;
        prev_repr = m.repr;
    }

    try applog.rewrite(store, log_path, out.items);
}

/// Every object a moment's representation chain depends on, so `gc` can treat
/// moments as roots instead of collecting them out from under capture.
/// Caller frees.
pub fn reachableObjects(store: *Store, alloc: std.mem.Allocator) ![]Oid {
    const all = try readAll(store, alloc);
    defer freeMoments(alloc, all);

    var seen = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer seen.deinit();
    var out: std.ArrayList(Oid) = .empty;
    errdefer out.deinit(alloc);

    for (all) |m| {
        var cursor = m.repr;
        while (true) {
            if (seen.contains(cursor.bytes)) break;
            try seen.put(cursor.bytes, {});
            try out.append(alloc, cursor);

            const raw = store.readRaw(cursor) catch break;
            defer alloc.free(raw);
            if (raw.len == 0) break;
            if (raw[0] == delta_tag) {
                var cur = Cursor{ .data = raw, .pos = 1 };
                cursor = cur.oidv() catch break;
                // Blobs referenced by the delta's upserts stay alive too.
                const d = decodeDeltaBody(alloc, raw) catch break;
                defer {
                    alloc.free(d.removed);
                    alloc.free(d.upserted);
                }
                for (d.upserted) |e| {
                    if (seen.contains(e.blob.bytes)) continue;
                    try seen.put(e.blob.bytes, {});
                    try out.append(alloc, e.blob);
                }
            } else {
                const tree = object.Tree.decode(alloc, raw) catch break;
                defer object.freeTree(alloc, tree);
                for (tree.entries) |e| {
                    if (seen.contains(e.blob.bytes)) continue;
                    try seen.put(e.blob.bytes, {});
                    try out.append(alloc, e.blob);
                }
                break;
            }
        }
    }

    return out.toOwnedSlice(alloc);
}

// --- tests ---

const testing = std.testing;

fn testSettings() Settings {
    return .{ .enabled = true, .keyframe_interval = 5 };
}

test "capture writes a keyframe first, then deltas" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const set = testSettings();

    // Wide enough that a one-path delta is genuinely smaller than a full tree.
    // On a one-file repo it is not, and the size guard below correctly stores a
    // keyframe instead of a delta that costs more than what it replaces.
    for (0..50) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d}.txt", .{i});
        defer alloc.free(name);
        try work.writeFile(io, .{ .sub_path = name, .data = "contents" });
    }

    const first = try capture(&store, work, .poll, set);
    alloc.free(first.captured.branch);
    try testing.expectEqual(ReprKind.keyframe, first.captured.kind);

    try work.writeFile(io, .{ .sub_path = "f3.txt", .data = "edited" });
    const second = try capture(&store, work, .poll, set);
    alloc.free(second.captured.branch);
    try testing.expectEqual(ReprKind.delta, second.captured.kind);
}

test "a delta that would cost more than a keyframe is stored as a keyframe" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const set = Settings{ .enabled = true, .keyframe_interval = 1000 };

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const first = try capture(&store, work, .poll, set);
    alloc.free(first.captured.branch);

    // A single-file repo: the delta header alone exceeds the whole tree, so
    // storing one would be a chain link that costs more than it saves.
    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "two" });
    const second = try capture(&store, work, .poll, set);
    alloc.free(second.captured.branch);
    try testing.expectEqual(ReprKind.keyframe, second.captured.kind);

    const entries = try entriesOf(&store, second.captured);
    defer workspace.freeTreeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
}

test "an unchanged tree captures nothing" {
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
    const first = try capture(&store, work, .poll, testSettings());
    alloc.free(first.captured.branch);

    const again = try capture(&store, work, .poll, testSettings());
    try testing.expect(again == .unchanged);
    try testing.expectEqual(@as(usize, 1), try count(&store, alloc));
}

test "a single-file edit costs well under a kilobyte" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    // A repo wide enough that a full tree is meaningfully large.
    for (0..300) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d}.txt", .{i});
        defer alloc.free(name);
        try work.writeFile(io, .{ .sub_path = name, .data = "contents" });
    }

    const set = Settings{ .enabled = true, .keyframe_interval = 1000 };
    const first = try capture(&store, work, .poll, set);
    alloc.free(first.captured.branch);

    try work.writeFile(io, .{ .sub_path = "f7.txt", .data = "edited" });
    const second = try capture(&store, work, .poll, set);
    alloc.free(second.captured.branch);
    try testing.expectEqual(ReprKind.delta, second.captured.kind);

    const full = try store.readRaw(first.captured.repr);
    defer alloc.free(full);
    const delta = try store.readRaw(second.captured.repr);
    defer alloc.free(delta);

    try testing.expect(delta.len < 1024);
    try testing.expect(delta.len * 10 < full.len);
}

test "reconstruction is lossless across many moments and keyframes" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    // keyframe_interval of 7 over 500 captures crosses ~70 keyframe boundaries,
    // which is the case the delta chain has to survive.
    const set = Settings{ .enabled = true, .keyframe_interval = 7 };

    var expected: std.ArrayList([]u8) = .empty;
    defer {
        for (expected.items) |s| alloc.free(s);
        expected.deinit(alloc);
    }

    for (0..500) |i| {
        // Mix every edit shape: create, modify, and delete.
        const name = try std.fmt.allocPrint(alloc, "f{d}.txt", .{i % 40});
        defer alloc.free(name);
        if (i % 11 == 10) {
            work.deleteFile(io, name) catch {};
        } else {
            const body = try std.fmt.allocPrint(alloc, "value {d}", .{i});
            defer alloc.free(body);
            try work.writeFile(io, .{ .sub_path = name, .data = body });
        }

        const r = try capture(&store, work, .poll, set);
        if (r == .captured) {
            alloc.free(r.captured.branch);
            // Record what the tree looked like right now, independently.
            const live = try workspace.captureEntries(&store, work);
            defer workspace.freeTreeEntries(alloc, live);
            const enc = try object.Tree.encode(.{ .entries = live }, alloc);
            try expected.append(alloc, enc);
        }
    }

    const all = try readAll(&store, alloc);
    defer freeMoments(alloc, all);
    try testing.expect(all.len > 200);
    try testing.expectEqual(expected.items.len, all.len);

    // Every single moment must reconstruct to exactly the tree that was live
    // when it was captured. This is the losslessness gate.
    for (all, expected.items) |m, want| {
        const got = try entriesOf(&store, m);
        defer workspace.freeTreeEntries(alloc, got);
        const enc = try object.Tree.encode(.{ .entries = got }, alloc);
        defer alloc.free(enc);
        try testing.expectEqualSlices(u8, want, enc);
    }
}

test "a corrupted representation is a hard error, not a partial recovery" {
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
    const first = try capture(&store, work, .poll, testSettings());
    alloc.free(first.captured.branch);

    // Point the moment at a representation that decodes but describes a
    // different tree; the full-tree hash must catch it.
    var fake = first.captured;
    fake.repr = try store.writeRaw("not a tree at all");
    try testing.expectError(Error.MomentCorrupt, entriesOf(&store, fake));
}

test "retention cuts only at a keyframe" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const set = Settings{ .enabled = true, .keyframe_interval = 4, .max = 10 };
    for (0..40) |i| {
        const body = try std.fmt.allocPrint(alloc, "v{d}", .{i});
        defer alloc.free(body);
        try work.writeFile(io, .{ .sub_path = "a.txt", .data = body });
        const r = try capture(&store, work, .poll, set);
        if (r == .captured) alloc.free(r.captured.branch);
    }

    const all = try readAll(&store, alloc);
    defer freeMoments(alloc, all);
    try testing.expect(all.len <= 14);
    // Whatever survived must still reconstruct, which is only possible if the
    // cut landed on a keyframe.
    try testing.expectEqual(ReprKind.keyframe, all[0].kind);
    for (all) |m| {
        const got = try entriesOf(&store, m);
        workspace.freeTreeEntries(alloc, got);
    }
}

test "a log whose only keyframe expires is re-anchored, not left un-trimmable" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    // A keyframe interval wider than the run, which is the ordinary case: the
    // default is 200 and most repos never get that far. Only moment 0 is a
    // keyframe, so every later one is a delta chained back to it.
    const set = Settings{ .enabled = true, .keyframe_interval = 10_000, .max = 10_000 };
    for (0..40) |i| {
        const name = try std.fmt.allocPrint(alloc, "f{d}.txt", .{i});
        defer alloc.free(name);
        try work.writeFile(io, .{ .sub_path = name, .data = "contents" });
        const r = try capture(&store, work, .poll, set);
        if (r == .captured) alloc.free(r.captured.branch);
    }

    const before = try readAll(&store, alloc);
    defer freeMoments(alloc, before);
    try testing.expect(before.len > 1);
    try testing.expectEqual(ReprKind.keyframe, before[0].kind);
    // The premise: nothing after the first is a keyframe, so the old cut-only-
    // at-a-keyframe search finds nothing and used to bail out entirely.
    for (before[1..]) |m| try testing.expectEqual(ReprKind.delta, m.kind);

    const want_last = before[before.len - 1];

    // Expire everything but keep the cap generous, so `max` is not what cuts.
    try trim(&store, alloc, .{ .enabled = true, .retain_s = 0, .max = 10_000 });

    const after = try readAll(&store, alloc);
    defer freeMoments(alloc, after);
    try testing.expect(after.len < before.len);

    // Whatever survived has to reconstruct, which needs a keyframe at the head.
    if (after.len != 0) {
        try testing.expectEqual(ReprKind.keyframe, after[0].kind);
        for (after) |m| {
            const got = try entriesOf(&store, m);
            workspace.freeTreeEntries(alloc, got);
        }
        // Identity is preserved across the rewrite: only the representation
        // changes, never what the moment is.
        const newest = after[after.len - 1];
        try testing.expectEqual(want_last.ms, newest.ms);
        try testing.expect(want_last.full_tree.eql(newest.full_tree));
    }
}

test "re-anchored moments still reconstruct the exact trees they held" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const set = Settings{ .enabled = true, .keyframe_interval = 10_000, .max = 10_000 };
    for (0..12) |i| {
        const body = try std.fmt.allocPrint(alloc, "v{d}", .{i});
        defer alloc.free(body);
        try work.writeFile(io, .{ .sub_path = "a.txt", .data = body });
        for (0..30) |k| {
            const name = try std.fmt.allocPrint(alloc, "pad{d}.txt", .{k});
            defer alloc.free(name);
            try work.writeFile(io, .{ .sub_path = name, .data = "pad" });
        }
        const r = try capture(&store, work, .poll, set);
        if (r == .captured) alloc.free(r.captured.branch);
    }

    const before = try readAll(&store, alloc);
    defer freeMoments(alloc, before);
    const survivors = before[before.len - 3 ..];

    // What the last three moments held, read before any rewrite.
    var want: [3]Oid = undefined;
    for (survivors, 0..) |m, i| want[i] = m.full_tree;

    try reanchor(&store, alloc, survivors);

    const after = try readAll(&store, alloc);
    defer freeMoments(alloc, after);
    try testing.expectEqual(@as(usize, 3), after.len);
    try testing.expectEqual(ReprKind.keyframe, after[0].kind);

    for (after, 0..) |m, i| {
        try testing.expect(want[i].eql(m.full_tree));
        const got = try entriesOf(&store, m);
        defer workspace.freeTreeEntries(alloc, got);
        // The reconstructed tree must hash to exactly what the moment records.
        const enc = try object.Tree.encode(.{ .entries = got }, alloc);
        defer alloc.free(enc);
        try testing.expect(Oid.ofBytes(enc).eql(m.full_tree));
    }
}

test "moment ids are stable, branch-qualified, and time-qualified" {
    const tree = Oid.ofBytes("t");
    const a = computeId("main", tree, 1000);
    try testing.expectEqualSlices(u8, &a, &computeId("main", tree, 1000));
    try testing.expect(!std.mem.eql(u8, &a, &computeId("other", tree, 1000)));
    try testing.expect(!std.mem.eql(u8, &a, &computeId("main", tree, 1001)));
}

test "parseDuration understands units and falls back on junk" {
    try testing.expectEqual(@as(i64, 90), parseDuration("90", 1));
    try testing.expectEqual(@as(i64, 120), parseDuration("2m", 1));
    try testing.expectEqual(@as(i64, 7200), parseDuration("2h", 1));
    try testing.expectEqual(@as(i64, 14 * 86400), parseDuration("14d", 1));
    try testing.expectEqual(@as(i64, 42), parseDuration("nonsense", 42));
}
