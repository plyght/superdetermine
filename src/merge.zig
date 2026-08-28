const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const diff = @import("diff.zig");
const store_mod = @import("store.zig");
const superpose = @import("superpose.zig");
const Oid = oid.Oid;
const Store = store_mod.Store;

/// Find a shared ancestor change of `a` and `b` by walking the parent DAG.
/// Collects all ancestors of `a` (including `a`), then walks `b`'s ancestors
/// breadth-first, returning the first hit. null if the histories are disjoint.
pub fn commonAncestor(store: *Store, alloc: std.mem.Allocator, a: Oid, b: Oid) !?Oid {
    var seen = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer seen.deinit();
    try collectAncestors(store, alloc, a, &seen);

    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(alloc);
    var visited = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer visited.deinit();

    try queue.append(alloc, b);
    try visited.put(b.bytes, {});
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        if (seen.contains(cur.bytes)) return cur;
        const ch = store.readChange(cur) catch continue;
        defer object.freeChange(alloc, ch);
        for (ch.parents) |p| {
            if (!visited.contains(p.bytes)) {
                try visited.put(p.bytes, {});
                try queue.append(alloc, p);
            }
        }
    }
    return null;
}

fn collectAncestors(store: *Store, alloc: std.mem.Allocator, start: Oid, set: *std.AutoHashMap([Oid.len]u8, void)) !void {
    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(alloc);
    try queue.append(alloc, start);
    try set.put(start.bytes, {});
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const cur = queue.items[head];
        const ch = store.readChange(cur) catch continue;
        defer object.freeChange(alloc, ch);
        for (ch.parents) |p| {
            if (!set.contains(p.bytes)) {
                try set.put(p.bytes, {});
                try queue.append(alloc, p);
            }
        }
    }
}

pub const MergeResult = struct {
    tree: Oid,
    conflicts: [][]u8,
};

pub fn freeMergeResult(alloc: std.mem.Allocator, r: MergeResult) void {
    for (r.conflicts) |p| alloc.free(p);
    alloc.free(r.conflicts);
}

const PathMap = std.StringHashMap(object.TreeEntry);

/// Load a stored tree into a path->TreeEntry map, carrying each entry's mode.
/// Keys are duped into `alloc`.
fn loadPathMap(store: *Store, alloc: std.mem.Allocator, tree: ?Oid, map: *PathMap) !void {
    const t = tree orelse return;
    const loaded = try store.readTree(t);
    defer object.freeTree(alloc, loaded);
    for (loaded.entries) |e| {
        const key = try alloc.dupe(u8, e.path);
        errdefer alloc.free(key);
        try map.put(key, .{ .mode = e.mode, .path = key, .blob = e.blob });
    }
}

fn freePathMap(alloc: std.mem.Allocator, map: *PathMap) void {
    var it = map.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    map.deinit();
}

fn looksBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data, 0) != null;
}

/// Three-way merge of two tree Oids against an optional base tree.
pub fn mergeTrees(store: *Store, alloc: std.mem.Allocator, base: ?Oid, ours: Oid, theirs: Oid) !MergeResult {
    var base_map = PathMap.init(alloc);
    defer freePathMap(alloc, &base_map);
    var ours_map = PathMap.init(alloc);
    defer freePathMap(alloc, &ours_map);
    var theirs_map = PathMap.init(alloc);
    defer freePathMap(alloc, &theirs_map);

    try loadPathMap(store, alloc, base, &base_map);
    try loadPathMap(store, alloc, ours, &ours_map);
    try loadPathMap(store, alloc, theirs, &theirs_map);

    // Union of all paths.
    var paths = std.StringHashMap(void).init(alloc);
    defer paths.deinit();
    {
        var it = ours_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
        it = theirs_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
        it = base_map.keyIterator();
        while (it.next()) |k| try paths.put(k.*, {});
    }

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e.path);
        entries.deinit(alloc);
    }
    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }

    // Superposition is off unless the repo asks for it, and defaults off for
    // existing repos: a file quietly holding a second value is a real change to
    // the mental model, and disliking that is a preference, not a
    // misunderstanding.
    const sset = superpose.settings(store, alloc);
    var superposed: usize = superpose.count(store, alloc) catch 0;

    var pit = paths.keyIterator();
    while (pit.next()) |kp| {
        const path = kp.*;
        const b = base_map.get(path);
        const o = ours_map.get(path);
        const t = theirs_map.get(path);

        const result: ?object.TreeEntry = try resolveEntry(store, alloc, path, b, o, t, &conflicts, sset, &superposed);
        if (result) |e| {
            try entries.append(alloc, .{
                .mode = e.mode,
                .path = try alloc.dupe(u8, path),
                .blob = e.blob,
            });
        }
    }

    std.sort.pdq(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = entries.items });
    for (entries.items) |e| alloc.free(e.path);
    entries.deinit(alloc);

    return .{
        .tree = tree_oid,
        .conflicts = try conflicts.toOwnedSlice(alloc),
    };
}

fn oidEqOpt(a: ?Oid, b: ?Oid) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

fn blobOf(e: ?object.TreeEntry) ?Oid {
    return if (e) |x| x.blob else null;
}

fn modeOf(e: ?object.TreeEntry) ?object.Mode {
    return if (e) |x| x.mode else null;
}

fn isSymlink(e: ?object.TreeEntry) bool {
    return if (e) |x| x.mode == .symlink else false;
}

pub const ModeResolution = struct { mode: object.Mode, conflict: bool };

pub fn resolveMode(base: ?object.Mode, ours: ?object.Mode, theirs: ?object.Mode) ModeResolution {
    const o = ours orelse return .{ .mode = theirs orelse .regular, .conflict = false };
    const t = theirs orelse return .{ .mode = o, .conflict = false };
    if (o == t) return .{ .mode = o, .conflict = false };
    if (base) |f| {
        if (f == o) return .{ .mode = t, .conflict = false };
        if (f == t) return .{ .mode = o, .conflict = false };
    }
    return .{ .mode = t, .conflict = true };
}

pub fn resolveEntry(
    store: *Store,
    alloc: std.mem.Allocator,
    path: []const u8,
    base: ?object.TreeEntry,
    ours: ?object.TreeEntry,
    theirs: ?object.TreeEntry,
    conflicts: *std.ArrayList([]u8),
    sset: superpose.Settings,
    superposed: *usize,
) !?object.TreeEntry {
    const fb = blobOf(base);
    const ob = blobOf(ours);
    const tb = blobOf(theirs);

    const before = conflicts.items.len;
    var blob: ?Oid = null;

    const both_diverged = ob != null and tb != null and
        !oidEqOpt(ob, tb) and !oidEqOpt(ob, fb) and !oidEqOpt(tb, fb);

    if (both_diverged and (isSymlink(base) or isSymlink(ours) or isSymlink(theirs))) {
        try conflicts.append(alloc, try alloc.dupe(u8, path));
        blob = tb;
    } else {
        blob = try resolvePath(store, alloc, path, fb, ob, tb, conflicts, sset, superposed);
    }

    const b = blob orelse return null;
    const m = resolveMode(modeOf(base), modeOf(ours), modeOf(theirs));
    if (m.conflict and conflicts.items.len == before) {
        try conflicts.append(alloc, try alloc.dupe(u8, path));
    }
    return .{ .mode = m.mode, .path = path, .blob = b };
}

/// Resolve one path across base/ours/theirs. Returns the chosen blob Oid, or
/// null when the path should be absent (deleted) in the merged tree.
pub fn resolvePath(
    store: *Store,
    alloc: std.mem.Allocator,
    path: []const u8,
    base: ?Oid,
    ours: ?Oid,
    theirs: ?Oid,
    conflicts: *std.ArrayList([]u8),
    sset: superpose.Settings,
    superposed: *usize,
) !?Oid {
    // Both sides agree.
    if (oidEqOpt(ours, theirs)) return ours;
    // One side unchanged relative to base → take the other side.
    if (oidEqOpt(ours, base)) return theirs;
    if (oidEqOpt(theirs, base)) return ours;

    // Added on only one side (base absent, one side absent).
    if (base == null) {
        if (ours == null) return theirs;
        if (theirs == null) return ours;
    }

    // Deletion vs modification.
    if (ours == null) {
        // deleted on ours, modified on theirs → conflict, keep theirs.
        try conflicts.append(alloc, try alloc.dupe(u8, path));
        return theirs;
    }
    if (theirs == null) {
        try conflicts.append(alloc, try alloc.dupe(u8, path));
        return ours;
    }

    // Both sides changed. Attempt a line-level three-way merge.
    const ours_data = try store.readFileContent(ours.?);
    defer alloc.free(ours_data);
    const theirs_data = try store.readFileContent(theirs.?);
    defer alloc.free(theirs_data);
    const base_data: []u8 = if (base) |b| try store.readFileContent(b) else try alloc.alloc(u8, 0);
    defer alloc.free(base_data);

    if (looksBinary(ours_data) or looksBinary(theirs_data) or looksBinary(base_data)) {
        if (try superposeCandidates(store, alloc, path, ours.?, theirs.?, sset, superposed)) |primary| {
            return primary;
        }
        try conflicts.append(alloc, try alloc.dupe(u8, path));
        return ours;
    }

    const merged = try threeWayMerge(alloc, base_data, ours_data, theirs_data);
    defer alloc.free(merged.text);
    if (merged.conflict) {
        // The three-way merge ran first and could not reconcile this path.
        // Only now does superposition apply, and it replaces the conflict
        // markers rather than the merge: markers are syntactically invalid in
        // every language, so a tree carrying them cannot compile, cannot be
        // graded, and cannot be handed to an agent.
        if (try superposeCandidates(store, alloc, path, ours.?, theirs.?, sset, superposed)) |primary| {
            return primary;
        }
        try conflicts.append(alloc, try alloc.dupe(u8, path));
    }
    return try store.writeFileContent(merged.text);
}

/// Record both whole-file versions of an irreconcilable path and return the
/// primary, so the worktree materializes exactly one complete, valid file and
/// therefore still builds.
///
/// Returns null when superposition is off or the cap is reached, in which case
/// the caller falls back to today's conflict-marker behaviour unchanged.
fn superposeCandidates(
    store: *Store,
    alloc: std.mem.Allocator,
    path: []const u8,
    ours: Oid,
    theirs: Oid,
    sset: superpose.Settings,
    superposed: *usize,
) !?Oid {
    if (!sset.superpose) return null;
    if (superposed.* >= sset.max_superposed) return null;

    const candidates = [_]superpose.Candidate{
        .{ .label = 'A', .origin = "ours", .blob = ours, .moment_id = "", .author = "" },
        .{ .label = 'B', .origin = "theirs", .blob = theirs, .moment_id = "", .author = "" },
    };

    // `merge.primary` defaults to `ours`, deliberately not `greenest`: making
    // evidence the automatic tiebreak on day one trains people to trust a
    // signal before it has earned it.
    const primary: u8 = switch (sset.primary) {
        .ours => 'A',
        .theirs => 'B',
        .greenest => 'A',
    };

    superpose.record(store, path, &candidates, primary) catch return null;
    superposed.* += 1;
    _ = alloc;
    return if (primary == 'A') ours else theirs;
}

const MergedText = struct { text: []u8, conflict: bool };

/// Split `buf` into lines on '\n'; a trailing newline yields no empty line.
fn splitLines(alloc: std.mem.Allocator, buf: []const u8) ![][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(alloc);
    var start: usize = 0;
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        if (buf[i] == '\n') {
            try list.append(alloc, buf[start..i]);
            start = i + 1;
        }
    }
    if (start < buf.len) try list.append(alloc, buf[start..]);
    return list.toOwnedSlice(alloc);
}

/// Map each base line to its matching line index in `x` (or null if deleted).
/// Derived from the line diff: kept lines are matches, dels are unmatched.
fn matchLines(alloc: std.mem.Allocator, base_text: []const u8, x_text: []const u8, base_len: usize) ![]?usize {
    const ops = try diff.diffLines(alloc, base_text, x_text);
    defer alloc.free(ops);
    const map = try alloc.alloc(?usize, base_len);
    var bi: usize = 0;
    var xi: usize = 0;
    for (ops) |op| switch (op.tag) {
        .keep => {
            map[bi] = xi;
            bi += 1;
            xi += 1;
        },
        .del => {
            map[bi] = null;
            bi += 1;
        },
        .add => xi += 1,
    };
    return map;
}

fn linesEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

fn emitLines(out: *std.ArrayList(u8), alloc: std.mem.Allocator, lines: []const []const u8) !void {
    for (lines) |l| {
        try out.appendSlice(alloc, l);
        try out.append(alloc, '\n');
    }
}

/// Line-level three-way merge (diff3-style). Regions where only one side
/// changed are taken automatically; overlapping changes get conflict markers.
fn threeWayMerge(alloc: std.mem.Allocator, base_text: []const u8, ours_text: []const u8, theirs_text: []const u8) !MergedText {
    const base = try splitLines(alloc, base_text);
    defer alloc.free(base);
    const ours = try splitLines(alloc, ours_text);
    defer alloc.free(ours);
    const theirs = try splitLines(alloc, theirs_text);
    defer alloc.free(theirs);

    const map_o = try matchLines(alloc, base_text, ours_text, base.len);
    defer alloc.free(map_o);
    const map_t = try matchLines(alloc, base_text, theirs_text, base.len);
    defer alloc.free(map_t);

    const stable = try alloc.alloc(bool, base.len);
    defer alloc.free(stable);
    for (0..base.len) |i| stable[i] = map_o[i] != null and map_t[i] != null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var conflict = false;

    var i: usize = 0;
    var o: usize = 0;
    var t: usize = 0;
    while (true) {
        var j = i;
        while (j < base.len and !stable[j]) j += 1;
        const o_end = if (j < base.len) map_o[j].? else ours.len;
        const t_end = if (j < base.len) map_t[j].? else theirs.len;
        const o_region = ours[o..o_end];
        const t_region = theirs[t..t_end];
        const b_region = base[i..j];

        if (linesEql(o_region, t_region)) {
            try emitLines(&out, alloc, o_region);
        } else if (linesEql(o_region, b_region)) {
            try emitLines(&out, alloc, t_region);
        } else if (linesEql(t_region, b_region)) {
            try emitLines(&out, alloc, o_region);
        } else {
            conflict = true;
            try out.appendSlice(alloc, "<<<<<<< ours\n");
            try emitLines(&out, alloc, o_region);
            try out.appendSlice(alloc, "=======\n");
            try emitLines(&out, alloc, t_region);
            try out.appendSlice(alloc, ">>>>>>> theirs\n");
        }

        if (j >= base.len) break;
        try out.appendSlice(alloc, base[j]);
        try out.append(alloc, '\n');
        o = map_o[j].? + 1;
        t = map_t[j].? + 1;
        i = j + 1;
    }

    return .{ .text = try out.toOwnedSlice(alloc), .conflict = conflict };
}

/// Merge `from_branch` into `into_branch`: resolve tips, find their common
/// ancestor, three-way merge the trees, and record a merge change with both
/// tips as parents. Updates `into_branch`. Returns the result (conflict paths
/// included) so the caller can warn; conflict markers live in the files.
pub fn merge(store: *Store, alloc: std.mem.Allocator, into_branch: []const u8, from_branch: []const u8, author: []const u8, timestamp: i64) !MergeResult {
    const into_tip = try store.readRef(into_branch);
    const from_tip = try store.readRef(from_branch);

    const into_change = try store.readChange(into_tip);
    defer object.freeChange(alloc, into_change);
    const from_change = try store.readChange(from_tip);
    defer object.freeChange(alloc, from_change);

    const base = try commonAncestor(store, alloc, into_tip, from_tip);
    var base_tree: ?Oid = null;
    if (base) |b| {
        const bc = try store.readChange(b);
        defer object.freeChange(alloc, bc);
        base_tree = bc.tree;
    }

    const result = try mergeTrees(store, alloc, base_tree, into_change.tree, from_change.tree);

    var msg_buf: std.ArrayList(u8) = .empty;
    defer msg_buf.deinit(alloc);
    try msg_buf.appendSlice(alloc, "merge ");
    try msg_buf.appendSlice(alloc, from_branch);
    try msg_buf.appendSlice(alloc, " into ");
    try msg_buf.appendSlice(alloc, into_branch);

    const parents = [_]Oid{ into_tip, from_tip };
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, result.tree.bytes[0..16]);

    const change = object.Change{
        .tree = result.tree,
        .parents = &parents,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = 0,
        .author = author,
        .message = msg_buf.items,
    };
    const merge_oid = try store.writeChange(change);
    try store.updateRef(into_branch, merge_oid);

    return result;
}

const workspace = @import("workspace.zig");

const merge_state_path = "MERGE_STATE";

pub const MergeState = struct {
    from_branch: []u8,
    pre_merge: Oid,
    conflicts: [][]u8,
};

pub fn saveState(store: *Store, from_branch: []const u8, pre_merge: Oid, conflicts: []const []const u8) !void {
    const alloc = store.alloc;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try buf.appendSlice(alloc, from_branch);
    try buf.append(alloc, '\n');
    var hex: [Oid.len * 2]u8 = undefined;
    _ = pre_merge.toHex(&hex);
    try buf.appendSlice(alloc, &hex);
    try buf.append(alloc, '\n');
    for (conflicts) |c| {
        try buf.appendSlice(alloc, c);
        try buf.append(alloc, '\n');
    }
    try store.root.writeFile(store.io, .{ .sub_path = merge_state_path, .data = buf.items });
}

pub fn loadState(store: *Store, alloc: std.mem.Allocator) !?MergeState {
    const data = store.root.readFileAlloc(store.io, merge_state_path, alloc, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    const from_line = lines.next() orelse return error.InvalidMergeState;
    const oid_line = lines.next() orelse return error.InvalidMergeState;

    const from_branch = try alloc.dupe(u8, from_line);
    errdefer alloc.free(from_branch);
    const pre_merge = Oid.fromHex(oid_line) catch return error.InvalidMergeState;

    var conflicts: std.ArrayList([]u8) = .empty;
    errdefer {
        for (conflicts.items) |p| alloc.free(p);
        conflicts.deinit(alloc);
    }

    while (lines.next()) |l| {
        if (l.len == 0) continue;
        try conflicts.append(alloc, try alloc.dupe(u8, l));
    }

    return .{
        .from_branch = from_branch,
        .pre_merge = pre_merge,
        .conflicts = try conflicts.toOwnedSlice(alloc),
    };
}

pub fn freeState(alloc: std.mem.Allocator, s: MergeState) void {
    alloc.free(s.from_branch);
    for (s.conflicts) |p| alloc.free(p);
    alloc.free(s.conflicts);
}

pub fn clearState(store: *Store) !void {
    store.root.deleteFile(store.io, merge_state_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// A conflict marker is exactly seven of the marker character, alone on the
/// line or followed by a space and a label. A longer run is a rule in the
/// text: plain-text licences underline their headings with dozens of `=`, and
/// treating one as an unresolved conflict wedges every later save in the repo.
fn isMarkerLine(line: []const u8, ch: u8) bool {
    var l = line;
    if (l.len != 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
    if (l.len < 7) return false;
    for (l[0..7]) |c| {
        if (c != ch) return false;
    }
    return l.len == 7 or l[7] == ' ';
}

/// Blobs already scanned and found free of conflict markers.
///
/// `sdt status` will not let a `<<<<<<<` reach a push, so it looks at every
/// tracked file, not only the ones a merge remembers. Read literally that is
/// the whole worktree on every status. Whether a blob holds markers is a
/// property of its bytes alone, so the answer keys on the content hash and
/// survives: the stat cache says which blob a file holds without opening it,
/// and a blob already known clean is never read again. The file is rewritten
/// from what the last scan saw, so it stays the size of the tree rather than
/// growing with history, and losing it costs one slow status.
pub const CleanBlobs = struct {
    const file = "marker-clean";

    seen: std.AutoHashMapUnmanaged([Oid.len]u8, void),
    keep: std.AutoHashMapUnmanaged([Oid.len]u8, void),
    alloc: std.mem.Allocator,

    pub fn load(store: *Store, alloc: std.mem.Allocator) CleanBlobs {
        var self: CleanBlobs = .{ .seen = .empty, .keep = .empty, .alloc = alloc };
        const data = store.root.readFileAlloc(store.io, file, alloc, .unlimited) catch return self;
        defer alloc.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len != Oid.len * 2) continue;
            const o = Oid.fromHex(line) catch continue;
            self.seen.put(alloc, o.bytes, {}) catch return self;
        }
        return self;
    }

    pub fn deinit(self: *CleanBlobs) void {
        self.seen.deinit(self.alloc);
        self.keep.deinit(self.alloc);
    }

    pub fn isClean(self: *const CleanBlobs, o: Oid) bool {
        return self.seen.contains(o.bytes);
    }

    /// Record that `o` holds no markers, and that it is still in the tree.
    pub fn markClean(self: *CleanBlobs, o: Oid) void {
        self.keep.put(self.alloc, o.bytes, {}) catch {};
    }

    pub fn save(self: *CleanBlobs, store: *Store) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        var it = self.keep.keyIterator();
        while (it.next()) |k| {
            const o = Oid{ .bytes = k.* };
            var hex: [Oid.len * 2]u8 = undefined;
            _ = o.toHex(&hex);
            out.appendSlice(self.alloc, &hex) catch return;
            out.append(self.alloc, '\n') catch return;
        }
        store.writeFileAtomic(file, out.items) catch {};
    }
};

pub fn hasConflictMarkers(data: []const u8) bool {
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |l| {
        if (isMarkerLine(l, '<')) return true;
        if (isMarkerLine(l, '>')) return true;
        if (isMarkerLine(l, '=')) return true;
    }
    return false;
}

pub fn markResolved(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir, path: []const u8) !void {
    const data = try work_dir.readFileAlloc(store.io, path, alloc, .unlimited);
    defer alloc.free(data);
    if (hasConflictMarkers(data)) return error.StillConflicted;

    const state = (try loadState(store, alloc)) orelse return error.NoMergeInProgress;
    defer freeState(alloc, state);

    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(alloc);
    for (state.conflicts) |c| {
        if (!std.mem.eql(u8, c, path)) try kept.append(alloc, c);
    }

    if (kept.items.len == 0) {
        try clearState(store);
    } else {
        try saveState(store, state.from_branch, state.pre_merge, kept.items);
    }
}

pub fn remainingConflicts(store: *Store, alloc: std.mem.Allocator) ![][]u8 {
    const state = (try loadState(store, alloc)) orelse return alloc.alloc([]u8, 0);
    alloc.free(state.from_branch);
    return state.conflicts;
}

pub fn abort(store: *Store, alloc: std.mem.Allocator, work_dir: std.Io.Dir) !void {
    const state = (try loadState(store, alloc)) orelse return error.NoMergeInProgress;
    defer freeState(alloc, state);

    const branch = try store.headBranch();
    defer alloc.free(branch);

    var from_tree: ?Oid = null;
    if (store.readRef(branch)) |tip| {
        if (store.readChange(tip)) |cur| {
            defer object.freeChange(alloc, cur);
            from_tree = cur.tree;
        } else |_| {}
    } else |_| {}

    try store.updateRef(branch, state.pre_merge);

    const change = try store.readChange(state.pre_merge);
    defer object.freeChange(alloc, change);
    try workspace.checkout(store, work_dir, from_tree, change.tree);

    try clearState(store);
}

// --- tests ---

const testing = std.testing;

fn commitTree(store: *Store, tree: Oid, parents: []const Oid, msg: []const u8) !Oid {
    const change = object.Change{
        .tree = tree,
        .parents = parents,
        .change_id = [_]u8{0} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "T <t@e.com>",
        .message = msg,
    };
    return store.writeChange(change);
}

fn singleFileTree(store: *Store, path: []const u8, blob: Oid) !Oid {
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = path, .blob = blob },
    };
    return store.writeTree(.{ .entries = &entries });
}

test "clean non-overlapping merge" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const base_blob = try store.writeFileContent("a\nb\nc\n");
    const base_tree = try singleFileTree(&store, "f", base_blob);
    const base_c = try commitTree(&store, base_tree, &.{}, "base");

    // ours: change line 1
    const ours_blob = try store.writeFileContent("A\nb\nc\n");
    const ours_tree = try singleFileTree(&store, "f", ours_blob);
    const ours_c = try commitTree(&store, ours_tree, &.{base_c}, "ours");

    // theirs: change line 3
    const theirs_blob = try store.writeFileContent("a\nb\nC\n");
    const theirs_tree = try singleFileTree(&store, "f", theirs_blob);
    const theirs_c = try commitTree(&store, theirs_tree, &.{base_c}, "theirs");

    const anc = try commonAncestor(&store, alloc, ours_c, theirs_c);
    try testing.expect(anc != null);
    try testing.expect(anc.?.eql(base_c));

    try store.updateRef("ours", ours_c);
    try store.updateRef("theirs", theirs_c);

    const result = try merge(&store, alloc, "ours", "theirs", "T <t@e.com>", 1_700_000_100);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.conflicts.len);

    // merged file should carry both edits.
    const merged_tree = try store.readTree(result.tree);
    defer object.freeTree(alloc, merged_tree);
    try testing.expectEqual(@as(usize, 1), merged_tree.entries.len);
    const merged_data = try store.readFileContent(merged_tree.entries[0].blob);
    defer alloc.free(merged_data);
    try testing.expectEqualStrings("A\nb\nC\n", merged_data);
}

test "conflicting merge produces markers" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const base_blob = try store.writeFileContent("a\nb\nc\n");
    const base_tree = try singleFileTree(&store, "f", base_blob);
    const base_c = try commitTree(&store, base_tree, &.{}, "base");

    const ours_blob = try store.writeFileContent("X\nb\nc\n");
    const ours_tree = try singleFileTree(&store, "f", ours_blob);
    const ours_c = try commitTree(&store, ours_tree, &.{base_c}, "ours");

    const theirs_blob = try store.writeFileContent("Y\nb\nc\n");
    const theirs_tree = try singleFileTree(&store, "f", theirs_blob);
    const theirs_c = try commitTree(&store, theirs_tree, &.{base_c}, "theirs");

    try store.updateRef("ours", ours_c);
    try store.updateRef("theirs", theirs_c);

    const result = try merge(&store, alloc, "ours", "theirs", "T <t@e.com>", 1_700_000_100);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try testing.expectEqualStrings("f", result.conflicts[0]);

    const merged_tree = try store.readTree(result.tree);
    defer object.freeTree(alloc, merged_tree);
    const merged_data = try store.readFileContent(merged_tree.entries[0].blob);
    defer alloc.free(merged_data);
    try testing.expect(std.mem.indexOf(u8, merged_data, "<<<<<<< ours") != null);
    try testing.expect(std.mem.indexOf(u8, merged_data, "=======") != null);
    try testing.expect(std.mem.indexOf(u8, merged_data, ">>>>>>> theirs") != null);
    try testing.expect(std.mem.indexOf(u8, merged_data, "X") != null);
    try testing.expect(std.mem.indexOf(u8, merged_data, "Y") != null);
}

test "hasConflictMarkers detects markers" {
    try testing.expect(hasConflictMarkers("a\n<<<<<<< ours\nb\n"));
    try testing.expect(hasConflictMarkers("a\n=======\nb\n"));
    try testing.expect(hasConflictMarkers("a\n>>>>>>> theirs\n"));
    try testing.expect(hasConflictMarkers("a\n=======\r\nb\n"));
    try testing.expect(!hasConflictMarkers("a\nb\nc\n"));
}

test "a plain-text rule is not a conflict marker" {
    // CC BY 4.0 underlines its headings with 71 `=`; an earlier check used
    // startsWith and rejected the file, which then blocked every later save.
    const rule = "=" ** 71;
    try testing.expect(!hasConflictMarkers("Creative Commons\n" ++ rule ++ "\ntext\n"));
    try testing.expect(!hasConflictMarkers("title\n" ++ "-" ** 40 ++ "\n"));
    try testing.expect(!hasConflictMarkers("<<<<<<<<\nnot a marker, eight of them\n"));
    try testing.expect(!hasConflictMarkers(">>>>>>>>>>\n"));
    try testing.expect(!hasConflictMarkers("======\nsix is too few\n"));

    // The real thing still trips it.
    try testing.expect(hasConflictMarkers("x\n<<<<<<< HEAD\ny\n"));
}

test "merge state roundtrip" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try testing.expect((try loadState(&store, alloc)) == null);

    const pre = Oid.ofBytes("pre-merge tip");
    const paths = [_][]const u8{ "a.txt", "sub/b.txt" };
    try saveState(&store, "feature", pre, &paths);

    const state = (try loadState(&store, alloc)).?;
    defer freeState(alloc, state);
    try testing.expectEqualStrings("feature", state.from_branch);
    try testing.expect(state.pre_merge.eql(pre));
    try testing.expectEqual(@as(usize, 2), state.conflicts.len);
    try testing.expectEqualStrings("a.txt", state.conflicts[0]);
    try testing.expectEqualStrings("sub/b.txt", state.conflicts[1]);

    try clearState(&store);
    try testing.expect((try loadState(&store, alloc)) == null);
}

test "markResolved removes clean path and clears when empty" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const pre = Oid.ofBytes("tip");
    const paths = [_][]const u8{ "a.txt", "b.txt" };
    try saveState(&store, "feature", pre, &paths);

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "<<<<<<< ours\nx\n=======\ny\n>>>>>>> theirs\n" });
    try testing.expectError(error.StillConflicted, markResolved(&store, alloc, work, "a.txt"));

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "resolved\n" });
    try markResolved(&store, alloc, work, "a.txt");

    {
        const rem = try remainingConflicts(&store, alloc);
        defer {
            for (rem) |p| alloc.free(p);
            alloc.free(rem);
        }
        try testing.expectEqual(@as(usize, 1), rem.len);
        try testing.expectEqualStrings("b.txt", rem[0]);
    }

    try work.writeFile(io, .{ .sub_path = "b.txt", .data = "resolved\n" });
    try markResolved(&store, alloc, work, "b.txt");
    try testing.expect((try loadState(&store, alloc)) == null);
}

test "abort restores working tree and branch to pre-merge" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/f", .data = "original\n" });
    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const pre = try workspace.snapshot(&store, work, "T <t@e.com>", "base", 1_700_000_000);

    try work.writeFile(io, .{ .sub_path = "f", .data = "<<<<<<< ours\nmess\n>>>>>>> theirs\n" });
    const bogus = Oid.ofBytes("bogus merge tip");
    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, bogus);

    const paths = [_][]const u8{"f"};
    try saveState(&store, "feature", pre, &paths);

    try abort(&store, alloc, work);

    const restored = try work.readFileAlloc(io, "f", alloc, .unlimited);
    defer alloc.free(restored);
    try testing.expectEqualStrings("original\n", restored);
    try testing.expect((try store.readRef(branch)).eql(pre));
    try testing.expect((try loadState(&store, alloc)) == null);
    try testing.expectError(error.NoMergeInProgress, abort(&store, alloc, work));
}

fn treeOf(store: *Store, entries: []object.TreeEntry) !Oid {
    std.sort.pdq(object.TreeEntry, entries, {}, object.Tree.lessThan);
    return store.writeTree(.{ .entries = entries });
}

fn entryAt(store: *Store, alloc: std.mem.Allocator, tree: Oid, path: []const u8) !object.TreeEntry {
    const loaded = try store.readTree(tree);
    defer object.freeTree(alloc, loaded);
    for (loaded.entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return .{ .mode = e.mode, .path = "", .blob = e.blob };
    }
    return error.MissingPath;
}

test "merge preserves the exec bit on an untouched file" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const script = try store.writeFileContent("#!/bin/sh\necho hi\n");

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .executable, .path = "run.sh", .blob = script },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("a\nb\nc\n") },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .executable, .path = "run.sh", .blob = script },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("A\nb\nc\n") },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .executable, .path = "run.sh", .blob = script },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("a\nb\nC\n") },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.conflicts.len);
    const run = try entryAt(&store, alloc, result.tree, "run.sh");
    try testing.expectEqual(object.Mode.executable, run.mode);
    try testing.expect(run.blob.eql(script));

    const merged = try entryAt(&store, alloc, result.tree, "f");
    try testing.expectEqual(object.Mode.regular, merged.mode);
    const merged_data = try store.readFileContent(merged.blob);
    defer alloc.free(merged_data);
    try testing.expectEqualStrings("A\nb\nC\n", merged_data);
}

test "merge takes an exec bit set on one side only" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const script = try store.writeFileContent("#!/bin/sh\n");

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "run.sh", .blob = script },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .executable, .path = "run.sh", .blob = script },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "run.sh", .blob = script },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.conflicts.len);
    const run = try entryAt(&store, alloc, result.tree, "run.sh");
    try testing.expectEqual(object.Mode.executable, run.mode);
}

test "merge reports an exec-vs-regular divergence as a conflict" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const script = try store.writeFileContent("#!/bin/sh\n");

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
        .{ .mode = .executable, .path = "run.sh", .blob = script },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
        .{ .mode = .regular, .path = "run.sh", .blob = script },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try testing.expectEqualStrings("run.sh", result.conflicts[0]);
    const run = try entryAt(&store, alloc, result.tree, "run.sh");
    try testing.expect(run.blob.eql(script));
}

test "merge preserves an untouched symlink" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const target = try store.writeFileContent("a/target");

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = target },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("a\nb\nc\n") },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = target },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("A\nb\nc\n") },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = target },
        .{ .mode = .regular, .path = "f", .blob = try store.writeFileContent("a\nb\nC\n") },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.conflicts.len);
    const link = try entryAt(&store, alloc, result.tree, "link");
    try testing.expectEqual(object.Mode.symlink, link.mode);
    const link_data = try store.readFileContent(link.blob);
    defer alloc.free(link_data);
    try testing.expectEqualStrings("a/target", link_data);
}

test "merge takes a symlink retargeted on one side only" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const old_target = try store.writeFileContent("old/target");

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = old_target },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try store.writeFileContent("new/target") },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = old_target },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 0), result.conflicts.len);
    const link = try entryAt(&store, alloc, result.tree, "link");
    try testing.expectEqual(object.Mode.symlink, link.mode);
    const link_data = try store.readFileContent(link.blob);
    defer alloc.free(link_data);
    try testing.expectEqualStrings("new/target", link_data);
}

test "merge conflicts a divergent symlink without writing markers" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try store.writeFileContent("base/target") },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try store.writeFileContent("ours/target") },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .symlink, .path = "link", .blob = try store.writeFileContent("theirs/target") },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try testing.expectEqualStrings("link", result.conflicts[0]);
    const link = try entryAt(&store, alloc, result.tree, "link");
    try testing.expectEqual(object.Mode.symlink, link.mode);
    const link_data = try store.readFileContent(link.blob);
    defer alloc.free(link_data);
    try testing.expectEqualStrings("theirs/target", link_data);
    try testing.expect(!hasConflictMarkers(link_data));
}

test "merge conflicts a symlink against a regular file" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    var base_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
    };
    const base_tree = try treeOf(&store, &base_entries);

    var ours_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
        .{ .mode = .regular, .path = "p", .blob = try store.writeFileContent("plain\n") },
    };
    const ours_tree = try treeOf(&store, &ours_entries);

    var theirs_entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "other", .blob = try store.writeFileContent("other\n") },
        .{ .mode = .symlink, .path = "p", .blob = try store.writeFileContent("some/target") },
    };
    const theirs_tree = try treeOf(&store, &theirs_entries);

    const result = try mergeTrees(&store, alloc, base_tree, ours_tree, theirs_tree);
    defer freeMergeResult(alloc, result);

    try testing.expectEqual(@as(usize, 1), result.conflicts.len);
    try testing.expectEqualStrings("p", result.conflicts[0]);
    const p = try entryAt(&store, alloc, result.tree, "p");
    try testing.expectEqual(object.Mode.symlink, p.mode);
    const p_data = try store.readFileContent(p.blob);
    defer alloc.free(p_data);
    try testing.expectEqualStrings("some/target", p_data);
    try testing.expect(!hasConflictMarkers(p_data));
}
