const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const readset = @import("readset.zig");
const attribution = @import("attribution.zig");
const workspace = @import("workspace.zig");
const config = @import("config.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Why a bare green is not enough.
///
/// An agent that writes both the code and the check has proved only that it
/// agrees with itself, and a boolean cannot express that. Rather than trust the
/// boolean or point a model at the diff, a verdict carries a warrant on three
/// axes that are all deterministic and all cheap:
///
///   independence    did one actor author both the code and the check here?
///   relevance       did the check process actually open the changed files?
///   discrimination  would the check have failed on the previous tree?
///
/// They label, never gate. Nothing here blocks a push or fails a build, because
/// a signal wired to block becomes a target. And the honest limit: none of this
/// says whether the design is good. It answers a narrower question well, which
/// is whether the green in front of you is worth anything.
/// Which paths belong to the check rather than to the code.
///
/// This is a pattern heuristic, not a framework adapter: it matches the naming
/// conventions that Python, Go, Rust, JavaScript, Zig, Ruby and Java all
/// independently converged on. It is wrong sometimes, which is why
/// `checks.test_paths` overrides it and why a wrong answer degrades the
/// independence axis to `unknown` rather than to a confident lie.
pub const PathRules = struct {
    /// Substring patterns; a path matches if any is present. Empty means the
    /// built-in heuristic applies.
    custom: []const []const u8 = &.{},

    pub fn deinit(self: PathRules, alloc: std.mem.Allocator) void {
        for (self.custom) |p| alloc.free(p);
        if (self.custom.len != 0) alloc.free(self.custom);
    }

    pub fn isCheckPath(self: PathRules, path: []const u8) bool {
        if (self.custom.len != 0) {
            for (self.custom) |pat| {
                if (std.mem.indexOf(u8, path, pat) != null) return true;
            }
            return false;
        }
        return builtinIsCheckPath(path);
    }
};

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn builtinIsCheckPath(path: []const u8) bool {
    // Any directory component that is a test directory.
    var it = std.mem.splitScalar(u8, path, '/');
    var last: []const u8 = "";
    while (it.next()) |comp| {
        last = comp;
        if (eqlIgnoreCase(comp, "test") or eqlIgnoreCase(comp, "tests") or
            eqlIgnoreCase(comp, "spec") or eqlIgnoreCase(comp, "specs") or
            eqlIgnoreCase(comp, "__tests__") or eqlIgnoreCase(comp, "testing"))
        {
            return true;
        }
    }

    // Basename conventions: test_x, x_test.y, x.test.y, x.spec.y, xSpec.y.
    const base = last;
    const stem = if (std.mem.indexOfScalar(u8, base, '.')) |i| base[0..i] else base;
    if (std.mem.startsWith(u8, stem, "test_") or std.mem.startsWith(u8, stem, "Test")) return true;
    if (std.mem.endsWith(u8, stem, "_test") or std.mem.endsWith(u8, stem, "Test")) return true;
    if (std.mem.endsWith(u8, stem, "_spec") or std.mem.endsWith(u8, stem, "Spec")) return true;
    if (std.mem.indexOf(u8, base, ".test.") != null) return true;
    if (std.mem.indexOf(u8, base, ".spec.") != null) return true;
    return false;
}

/// Read `checks.test_paths`, a comma-separated list of substrings.
pub fn pathRules(store: *Store, alloc: std.mem.Allocator) PathRules {
    const raw = blk: {
        if (config.get(store, alloc, "checks.test_paths")) |maybe| {
            if (maybe) |v| break :blk v;
        } else |_| {}
        return .{};
    };
    defer alloc.free(raw);

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t");
        if (trimmed.len == 0) continue;
        const dup = alloc.dupe(u8, trimmed) catch continue;
        list.append(alloc, dup) catch {
            alloc.free(dup);
            continue;
        };
    }
    const owned = list.toOwnedSlice(alloc) catch return .{};
    return .{ .custom = owned };
}

// --- the span ---

pub const Span = struct {
    /// Paths whose content differs between the two states, sorted.
    changed: []const []const u8,
    /// The subset of `changed` that the path rules call check-side.
    check_side: []const []const u8,
    /// The subset of `changed` that is code.
    code_side: []const []const u8,
    /// True when a path was added or removed, rather than only edited in place.
    ///
    /// This is the negative-dependency guard. A read-set records the files a
    /// check opened; it cannot record the files a check *looked for and did not
    /// find*. So an added file can change the answer while intersecting no
    /// previous read-set at all, and any read-set shortcut must refuse to fire
    /// when the set of paths itself moved. ccache documents this exact hole and
    /// accepts it; comparing the path set closes it.
    paths_changed: bool,

    pub fn deinit(self: Span, alloc: std.mem.Allocator) void {
        for (self.changed) |p| alloc.free(p);
        alloc.free(self.changed);
        alloc.free(self.check_side);
        alloc.free(self.code_side);
    }
};

/// The paths that differ between `base` and `target`. A null base means the
/// target's whole tree is the span, which is what a first-ever grade sees.
pub fn spanBetween(
    store: *Store,
    alloc: std.mem.Allocator,
    base: ?[]const object.TreeEntry,
    target: []const object.TreeEntry,
    rules: PathRules,
) !Span {
    _ = store;

    var changed: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (changed.items) |p| alloc.free(p);
        changed.deinit(alloc);
    }
    var paths_changed = false;

    if (base) |b| {
        var i: usize = 0;
        var j: usize = 0;
        while (i < b.len and j < target.len) {
            switch (std.mem.order(u8, b[i].path, target[j].path)) {
                .lt => {
                    try changed.append(alloc, try alloc.dupe(u8, b[i].path));
                    paths_changed = true;
                    i += 1;
                },
                .gt => {
                    try changed.append(alloc, try alloc.dupe(u8, target[j].path));
                    paths_changed = true;
                    j += 1;
                },
                .eq => {
                    if (!b[i].blob.eql(target[j].blob)) {
                        try changed.append(alloc, try alloc.dupe(u8, target[j].path));
                    }
                    i += 1;
                    j += 1;
                },
            }
        }
        while (i < b.len) : (i += 1) {
            try changed.append(alloc, try alloc.dupe(u8, b[i].path));
            paths_changed = true;
        }
        while (j < target.len) : (j += 1) {
            try changed.append(alloc, try alloc.dupe(u8, target[j].path));
            paths_changed = true;
        }
    } else {
        for (target) |e| try changed.append(alloc, try alloc.dupe(u8, e.path));
        paths_changed = true;
    }

    const all = try changed.toOwnedSlice(alloc);
    errdefer {
        for (all) |p| alloc.free(p);
        alloc.free(all);
    }

    var check_side: std.ArrayList([]const u8) = .empty;
    errdefer check_side.deinit(alloc);
    var code_side: std.ArrayList([]const u8) = .empty;
    errdefer code_side.deinit(alloc);
    for (all) |p| {
        if (rules.isCheckPath(p)) {
            try check_side.append(alloc, p);
        } else {
            try code_side.append(alloc, p);
        }
    }

    return .{
        .changed = all,
        .check_side = try check_side.toOwnedSlice(alloc),
        .code_side = try code_side.toOwnedSlice(alloc),
        .paths_changed = paths_changed,
    };
}

// --- independence ---

/// An actor identity for comparison: an agent's name, or the literal "human".
fn actorOf(store: *Store, alloc: std.mem.Allocator, path: []const u8) ?[]u8 {
    const rec = (attribution.lastForPath(store, alloc, path) catch return null) orelse return null;
    defer attribution.freeEntry(alloc, rec);
    return switch (rec.kind) {
        .human => alloc.dupe(u8, "human") catch null,
        .agent => alloc.dupe(u8, if (rec.agent.len != 0) rec.agent else "agent") catch null,
    };
}

/// Did the same actor author the code and the check across this span?
///
/// Free: `attribution.zig` already recorded who wrote each file. With no
/// attribution on either side the axis reports `unknown` rather than guessing,
/// because a wrong confident answer here is exactly the failure the warrant
/// exists to prevent.
pub fn independence(store: *Store, alloc: std.mem.Allocator, span: Span) verdict.Independence {
    if (span.check_side.len == 0 or span.code_side.len == 0) return .unknown;

    var code_actors = std.StringHashMap(void).init(alloc);
    defer freeKeys(&code_actors, alloc);
    var check_actors = std.StringHashMap(void).init(alloc);
    defer freeKeys(&check_actors, alloc);

    for (span.code_side) |p| {
        const a = actorOf(store, alloc, p) orelse continue;
        if (code_actors.contains(a)) {
            alloc.free(a);
            continue;
        }
        code_actors.put(a, {}) catch alloc.free(a);
    }
    for (span.check_side) |p| {
        const a = actorOf(store, alloc, p) orelse continue;
        if (check_actors.contains(a)) {
            alloc.free(a);
            continue;
        }
        check_actors.put(a, {}) catch alloc.free(a);
    }

    if (code_actors.count() == 0 or check_actors.count() == 0) return .unknown;

    // Co-authored exactly when one actor wrote everything on both sides.
    if (code_actors.count() == 1 and check_actors.count() == 1) {
        var it = code_actors.keyIterator();
        const only_code = it.next().?.*;
        var it2 = check_actors.keyIterator();
        const only_check = it2.next().?.*;
        if (std.mem.eql(u8, only_code, only_check)) return .co_authored;
    }
    return .independent;
}

fn freeKeys(map: *std.StringHashMap(void), alloc: std.mem.Allocator) void {
    var it = map.keyIterator();
    while (it.next()) |k| alloc.free(k.*);
    map.deinit();
}

// --- relevance ---

/// Did the check open the files that changed? A set intersection over the
/// read-set that layer 2 already recorded, so it costs nothing extra.
pub fn relevance(rs: ?readset.ReadSet, span: Span) struct { hit: u16, total: u16 } {
    const set = rs orelse return .{ .hit = 0, .total = 0 };
    const cov = set.coverage(span.changed);
    return .{
        .hit = @intCast(@min(cov.hit, std.math.maxInt(u16))),
        .total = @intCast(@min(cov.total, std.math.maxInt(u16))),
    };
}

// --- discrimination ---

/// The tree that answers "would this check have failed on the previous code?":
/// the previous state's files, with every check-side path replaced by the
/// version under test.
///
/// This is a cheap approximation of mutation testing. Rather than synthesising
/// mutants, it uses the one mutant history already handed us, which is also the
/// only mutant that matters for this change. Free with
/// `workspace.freeTreeEntries`.
pub fn hybridEntries(
    alloc: std.mem.Allocator,
    previous: []const object.TreeEntry,
    target: []const object.TreeEntry,
    rules: PathRules,
) ![]object.TreeEntry {
    var out: std.ArrayList(object.TreeEntry) = .empty;
    errdefer {
        for (out.items) |e| alloc.free(e.path);
        out.deinit(alloc);
    }

    // Previous state's non-check files.
    for (previous) |e| {
        if (rules.isCheckPath(e.path)) continue;
        try out.append(alloc, .{
            .mode = e.mode,
            .path = try alloc.dupe(u8, e.path),
            .blob = e.blob,
        });
    }
    // Target state's check files.
    for (target) |e| {
        if (!rules.isCheckPath(e.path)) continue;
        try out.append(alloc, .{
            .mode = e.mode,
            .path = try alloc.dupe(u8, e.path),
            .blob = e.blob,
        });
    }

    const slice = try out.toOwnedSlice(alloc);
    std.mem.sort(object.TreeEntry, slice, {}, object.Tree.lessThan);
    return slice;
}

/// Whether discrimination is worth measuring at all. It costs one run, so it is
/// only asked when the check itself changed; otherwise the answer is already
/// implied by the previous state's own verdict and the axis stays `unknown`.
pub fn shouldMeasureDiscrimination(span: Span) bool {
    return span.check_side.len != 0;
}

/// Turn the hybrid run's result into the axis. The hybrid failing means the new
/// check responds to the change; the hybrid passing means it does not.
pub fn discriminationFrom(hybrid: verdict.Result) verdict.Discrimination {
    return switch (hybrid) {
        .red => .discriminating,
        .green => .vacuous,
    };
}

/// One line rendering of a verdict and its warrant, which is the only form a
/// green is ever shown in.
pub fn render(
    w: *std.Io.Writer,
    id_hex: []const u8,
    v: verdict.Verdict,
) !void {
    try w.print("@{s}   {s}   {s}   {s}   relevance {d}/{d}   {s}\n", .{
        id_hex,
        v.result.label(),
        v.tier.label(),
        v.independence.label(),
        v.relevance_hit,
        v.relevance_total,
        v.discrimination.label(),
    });
}

// --- tests ---

const testing = std.testing;

test "the built-in heuristic recognises test paths across ecosystems" {
    const rules = PathRules{};
    try testing.expect(rules.isCheckPath("tests/test_thing.py"));
    try testing.expect(rules.isCheckPath("src/foo_test.go"));
    try testing.expect(rules.isCheckPath("src/components/Button.test.tsx"));
    try testing.expect(rules.isCheckPath("spec/models/user_spec.rb"));
    try testing.expect(rules.isCheckPath("__tests__/api.js"));
    try testing.expect(rules.isCheckPath("src/test/java/AppTest.java"));

    try testing.expect(!rules.isCheckPath("src/main.zig"));
    try testing.expect(!rules.isCheckPath("README.md"));
    try testing.expect(!rules.isCheckPath("src/latest.js"));
    try testing.expect(!rules.isCheckPath("contest/entry.c"));
}

test "custom path rules replace the heuristic entirely" {
    const alloc = testing.allocator;
    const pats = try alloc.alloc([]const u8, 1);
    pats[0] = try alloc.dupe(u8, "verify/");
    const rules = PathRules{ .custom = pats };
    defer rules.deinit(alloc);

    try testing.expect(rules.isCheckPath("verify/a.zig"));
    // The heuristic no longer applies once an override exists.
    try testing.expect(!rules.isCheckPath("tests/test_thing.py"));
}

fn entry(path: []const u8, content: []const u8) object.TreeEntry {
    return .{ .mode = .regular, .path = path, .blob = Oid.ofBytes(content) };
}

test "span splits changed paths into code and check sides" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = [_]object.TreeEntry{
        entry("src/a.zig", "old"),
        entry("src/b.zig", "same"),
        entry("tests/a_test.zig", "old test"),
    };
    const after = [_]object.TreeEntry{
        entry("src/a.zig", "new"),
        entry("src/b.zig", "same"),
        entry("tests/a_test.zig", "new test"),
    };

    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), span.changed.len);
    try testing.expectEqual(@as(usize, 1), span.code_side.len);
    try testing.expectEqual(@as(usize, 1), span.check_side.len);
    try testing.expectEqualStrings("src/a.zig", span.code_side[0]);
    try testing.expectEqualStrings("tests/a_test.zig", span.check_side[0]);
}

test "span with no base is the whole tree" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const after = [_]object.TreeEntry{ entry("a", "1"), entry("b", "2") };
    const span = try spanBetween(&s, alloc, null, &after, .{});
    defer span.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), span.changed.len);
}

test "span catches additions and deletions, not just edits" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = [_]object.TreeEntry{ entry("gone.zig", "x"), entry("kept.zig", "same") };
    const after = [_]object.TreeEntry{ entry("added.zig", "y"), entry("kept.zig", "same") };

    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), span.changed.len);
    try testing.expectEqualStrings("added.zig", span.changed[0]);
    try testing.expectEqualStrings("gone.zig", span.changed[1]);
}

test "independence is unknown when only one side changed" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = [_]object.TreeEntry{entry("src/a.zig", "old")};
    const after = [_]object.TreeEntry{entry("src/a.zig", "new")};
    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);

    try testing.expectEqual(verdict.Independence.unknown, independence(&s, alloc, span));
}

test "one agent writing both code and check reads as co-authored" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("c1");
    try attribution.record(&s, change, .{
        .path = "src/a.zig",
        .kind = .agent,
        .confidence = .certain,
        .agent = "claude-code",
        .session = "s",
        .prompt = "p",
        .timestamp_ms = 1,
    });
    try attribution.record(&s, change, .{
        .path = "tests/a_test.zig",
        .kind = .agent,
        .confidence = .certain,
        .agent = "claude-code",
        .session = "s",
        .prompt = "p",
        .timestamp_ms = 2,
    });

    const before = [_]object.TreeEntry{ entry("src/a.zig", "old"), entry("tests/a_test.zig", "old") };
    const after = [_]object.TreeEntry{ entry("src/a.zig", "new"), entry("tests/a_test.zig", "new") };
    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);

    try testing.expectEqual(verdict.Independence.co_authored, independence(&s, alloc, span));
}

test "a human check over agent code reads as independent" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const change = Oid.ofBytes("c1");
    try attribution.record(&s, change, .{
        .path = "src/a.zig",
        .kind = .agent,
        .confidence = .certain,
        .agent = "claude-code",
        .session = "s",
        .prompt = "p",
        .timestamp_ms = 1,
    });
    try attribution.record(&s, change, .{
        .path = "tests/a_test.zig",
        .kind = .human,
        .confidence = .none,
        .agent = "",
        .session = "",
        .prompt = "",
        .timestamp_ms = 2,
    });

    const before = [_]object.TreeEntry{ entry("src/a.zig", "old"), entry("tests/a_test.zig", "old") };
    const after = [_]object.TreeEntry{ entry("src/a.zig", "new"), entry("tests/a_test.zig", "new") };
    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);

    try testing.expectEqual(verdict.Independence.independent, independence(&s, alloc, span));
}

test "relevance counts changed paths the check opened" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = [_]object.TreeEntry{ entry("src/a.zig", "old"), entry("docs/x.md", "old") };
    const after = [_]object.TreeEntry{ entry("src/a.zig", "new"), entry("docs/x.md", "new") };
    const span = try spanBetween(&s, alloc, &before, &after, .{});
    defer span.deinit(alloc);

    const rs = try readset.build(alloc, &.{ "src/a.zig", "src/unrelated.zig" });
    defer rs.deinit(alloc);

    const r = relevance(rs, span);
    try testing.expectEqual(@as(u16, 1), r.hit);
    try testing.expectEqual(@as(u16, 2), r.total);

    // With no read-set the axis reports nothing rather than a fake full score.
    const none = relevance(null, span);
    try testing.expectEqual(@as(u16, 0), none.total);
}

test "the hybrid tree is old code with the new check" {
    const alloc = testing.allocator;

    const previous = [_]object.TreeEntry{
        entry("src/a.zig", "old code"),
        entry("tests/a_test.zig", "old test"),
    };
    const target = [_]object.TreeEntry{
        entry("src/a.zig", "new code"),
        entry("tests/a_test.zig", "new test"),
    };

    const hybrid = try hybridEntries(alloc, &previous, &target, .{});
    defer workspace.freeTreeEntries(alloc, hybrid);

    try testing.expectEqual(@as(usize, 2), hybrid.len);
    try testing.expectEqualStrings("src/a.zig", hybrid[0].path);
    try testing.expect(hybrid[0].blob.eql(Oid.ofBytes("old code")));
    try testing.expectEqualStrings("tests/a_test.zig", hybrid[1].path);
    try testing.expect(hybrid[1].blob.eql(Oid.ofBytes("new test")));
}

test "discrimination is only measured when the check itself changed" {
    const alloc = testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const before = [_]object.TreeEntry{ entry("src/a.zig", "old"), entry("tests/t_test.zig", "same") };
    const after = [_]object.TreeEntry{ entry("src/a.zig", "new"), entry("tests/t_test.zig", "same") };
    const code_only = try spanBetween(&s, alloc, &before, &after, .{});
    defer code_only.deinit(alloc);
    try testing.expect(!shouldMeasureDiscrimination(code_only));

    const after2 = [_]object.TreeEntry{ entry("src/a.zig", "new"), entry("tests/t_test.zig", "changed") };
    const both = try spanBetween(&s, alloc, &before, &after2, .{});
    defer both.deinit(alloc);
    try testing.expect(shouldMeasureDiscrimination(both));
}

test "a check that passes on the old code is vacuous" {
    try testing.expectEqual(verdict.Discrimination.vacuous, discriminationFrom(.green));
    try testing.expectEqual(verdict.Discrimination.discriminating, discriminationFrom(.red));
}
