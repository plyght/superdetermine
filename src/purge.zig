const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const ignore = @import("ignore.zig");
const applog = @import("applog.zig");
const oplog = @import("oplog.zig");
const opdag = @import("opdag.zig");
const moment = @import("moment.zig");
const branches = @import("branches.zig");
const history = @import("history.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const Error = error{
    NoPathspec,
    NothingMatched,
};

pub const Stats = struct {
    /// Branches whose tip moved.
    branches: usize,
    /// Changes written with a new tree.
    changes: usize,
    /// Distinct paths removed across the whole history.
    paths: usize,
    /// What those paths held at their largest, as a floor on what `gc` can now
    /// reclaim. Chunks shared with a surviving path are still counted here, so
    /// treat it as an upper bound on the win, not a promise.
    bytes: u64,
    /// Gitmap entries dropped because the change they named no longer exists.
    /// Non-zero means the next export re-writes those commits, so the git
    /// remote will diverge.
    unmapped: usize,
};

/// True when `spec` names `path` itself, a directory containing it, or a glob
/// that covers it. Directory specs are the common case: `zig-out` and
/// `zig-out/` both take everything beneath.
///
/// Matching follows `.gitignore`, because that is where these specs get copied
/// from: a spec with no slash names a path component at any depth, so
/// `node_modules` reaches a nested `bindings/typescript/node_modules` too. A
/// leading `/` anchors to the repo root instead.
pub fn matches(spec: []const u8, path: []const u8) bool {
    var s = spec;
    while (s.len != 0 and s[s.len - 1] == '/') s = s[0 .. s.len - 1];

    var anchored = false;
    if (s.len != 0 and s[0] == '/') {
        anchored = true;
        s = s[1..];
    }
    if (s.len == 0) return false;

    if (!anchored and std.mem.indexOfScalar(u8, s, '/') == null) {
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |seg| {
            if (ignore.matchSegment(s, seg)) return true;
        }
        return false;
    }

    // A slash-bearing spec names a path or any directory above it, so test the
    // full path and every ancestor prefix of it.
    var end: usize = 0;
    while (end <= path.len) {
        const prefix = path[0..end];
        if (prefix.len != 0) {
            if (std.mem.eql(u8, s, prefix)) return true;
            if (ignore.matchPath(s, prefix)) return true;
        }
        if (end == path.len) break;
        const next = std.mem.indexOfScalarPos(u8, path, end + 1, '/') orelse path.len;
        end = next;
    }
    return false;
}

fn matchesAny(specs: []const []const u8, path: []const u8) bool {
    for (specs) |s| {
        if (matches(s, path)) return true;
    }
    return false;
}

const Seen = std.StringHashMap(void);

/// Rewrite one tree without the matching entries. Returns the original oid when
/// nothing matched, so an untouched change keeps its exact tree.
fn filterTree(
    store: *Store,
    alloc: std.mem.Allocator,
    tree_oid: Oid,
    specs: []const []const u8,
    seen: *Seen,
    bytes: *u64,
) !Oid {
    const tree = store.readTree(tree_oid) catch return tree_oid;
    defer object.freeTree(alloc, tree);

    var kept: std.ArrayList(object.TreeEntry) = .empty;
    defer kept.deinit(alloc);

    var dropped = false;
    for (tree.entries) |e| {
        if (!matchesAny(specs, e.path)) {
            try kept.append(alloc, e);
            continue;
        }
        dropped = true;
        if (!seen.contains(e.path)) {
            try seen.put(try alloc.dupe(u8, e.path), {});
            bytes.* += blobSize(store, e.blob);
        }
    }
    if (!dropped) return tree_oid;
    return store.writeTree(.{ .entries = kept.items });
}

fn blobSize(store: *Store, blob: Oid) u64 {
    const raw = store.readRaw(blob) catch return 0;
    defer store.alloc.free(raw);
    const decoded = object.Blob.decode(store.alloc, raw) catch return 0;
    defer store.alloc.free(decoded.chunks);
    return decoded.total_size;
}

/// Remove `specs` from every change on every branch, rewriting history in place.
///
/// This is the one operation `sdt undo` cannot reverse, because reclaiming the
/// content is the entire point: the moment log and the operation history both
/// pin the old trees, so they are reset rather than rewritten. Everything the
/// purge orphans is left for `sdt gc` to sweep.
pub fn purge(
    store: *Store,
    alloc: std.mem.Allocator,
    specs: []const []const u8,
    timestamp: i64,
    dry_run: bool,
) !Stats {
    if (specs.len == 0) return Error.NoPathspec;

    var seen = Seen.init(alloc);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit();
    }

    var stats: Stats = .{ .branches = 0, .changes = 0, .paths = 0, .bytes = 0, .unmapped = 0 };

    // Which changes stopped existing under their old Oid. The gitmap names
    // changes by Oid, so every one of these leaves a dangling entry.
    var replaced = std.AutoHashMap([32]u8, void).init(alloc);
    defer replaced.deinit();

    const names = try branches.list(store, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }

    for (names) |name| {
        const tip = store.readRef(name) catch continue;
        const chain = history.chainOf(store, alloc, tip) catch continue;
        defer alloc.free(chain);

        var parent: ?Oid = null;
        var moved = false;

        for (chain) |c| {
            const change = store.readChange(c) catch continue;
            defer object.freeChange(alloc, change);

            const tree = try filterTree(store, alloc, change.tree, specs, &seen, &stats.bytes);
            const same_tree = tree.eql(change.tree);
            if (!same_tree) stats.changes += 1;

            if (dry_run) {
                // A change's Oid covers its parent, so everything after the
                // first rewritten change is rewritten too.
                if (!same_tree) moved = true;
                if (moved) stats.unmapped += 1;
                continue;
            }

            var buf: [1]Oid = undefined;
            var parents: []const Oid = buf[0..0];
            if (parent) |p| {
                buf[0] = p;
                parents = buf[0..1];
            }
            const written = try store.writeChange(.{
                .tree = tree,
                .parents = parents,
                .change_id = change.change_id,
                .timestamp = change.timestamp,
                .tz_offset_min = change.tz_offset_min,
                .author = change.author,
                .message = change.message,
            });
            if (!written.eql(c)) {
                moved = true;
                try replaced.put(c.bytes, {});
            }
            parent = written;
        }

        if (!moved) continue;
        stats.branches += 1;
        if (dry_run) continue;
        if (parent) |p| try store.updateRef(name, p);
    }

    stats.paths = seen.count();
    if (stats.paths == 0) return Error.NothingMatched;
    if (dry_run) return stats;

    stats.unmapped = try pruneGitmap(store, alloc, &replaced);
    try resetHistory(store, alloc, timestamp);
    return stats;
}

/// Drop every `.sdt/gitmap` line naming a change the purge replaced. Keeping
/// them would be worse than dropping them: the git commit still holds the
/// purged path, so treating it as already-exported would export nothing and
/// leave the two histories quietly disagreeing.
fn pruneGitmap(
    store: *Store,
    alloc: std.mem.Allocator,
    replaced: *const std.AutoHashMap([32]u8, void),
) !usize {
    const data = store.root.readFileAlloc(store.io, "gitmap", alloc, .unlimited) catch return 0;
    defer alloc.free(data);

    var kept: std.ArrayList(u8) = .empty;
    defer kept.deinit(alloc);

    var dropped: usize = 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (t.len == 0) continue;
        var parts = std.mem.splitScalar(u8, t, ' ');
        _ = parts.next();
        const rhex = parts.next() orelse continue;
        if (Oid.fromHex(rhex)) |o| {
            if (replaced.contains(o.bytes)) {
                dropped += 1;
                continue;
            }
        } else |_| {}
        try kept.appendSlice(alloc, t);
        try kept.append(alloc, '\n');
    }

    if (dropped == 0) return 0;
    try store.root.writeFile(store.io, .{ .sub_path = "gitmap", .data = kept.items });
    return dropped;
}

/// Drop every root that would otherwise keep the purged trees alive: the moment
/// log, the operation log, and the operation DAG's heads. Without this the
/// rewrite is cosmetic — `gc` walks all three and would mark the old trees.
fn resetHistory(store: *Store, alloc: std.mem.Allocator, timestamp: i64) !void {
    const io = store.io;

    applog.rewrite(store, moment.log_path, "") catch {};
    applog.rewrite(store, "oplog", "") catch {};

    const hs = opdag.heads(store, alloc) catch &[_]Oid{};
    defer alloc.free(hs);
    for (hs) |h| opdag.removeHead(store, h) catch {};
    store.root.deleteTree(io, opdag.heads_dir) catch {};

    var view = try opdag.snapshot(store, alloc);
    defer view.deinit(alloc);
    const view_oid = try opdag.writeView(store, view);
    _ = opdag.commitWith(store, alloc, &.{}, view_oid, "purge", timestamp, "") catch {};
}

// --- tests ---

const testing = std.testing;

test "matches names a path, a directory above it, and a glob" {
    try testing.expect(matches("zig-out", "zig-out/bin/et"));
    try testing.expect(matches("zig-out/", "zig-out/bin/et"));
    try testing.expect(matches(".zig-cache", ".zig-cache/h/timestamp"));
    try testing.expect(matches("a/b.txt", "a/b.txt"));
    try testing.expect(matches("*.dylib", "zig-out/lib/libevanescent.dylib"));
    try testing.expect(matches("bindings/*/target", "bindings/rust/target"));
    try testing.expect(matches("bindings/rust/target", "bindings/rust/target/debug/app"));
    try testing.expect(matches("bindings/*/target", "bindings/rust/target/debug/app"));

    try testing.expect(!matches("zig-out", "zig-outer/bin"));
    try testing.expect(!matches("*.dylib", "src/main.zig"));
    try testing.expect(!matches("", "anything"));
    try testing.expect(!matches("/", "anything"));

    // A slash-free spec reaches any depth, the way a .gitignore line does.
    try testing.expect(matches("node_modules", "bindings/typescript/node_modules/.bin/tsc"));
    try testing.expect(matches("zig-out", "src/zig-out/bin/et"));

    // A leading slash pins it to the root instead.
    try testing.expect(matches("/node_modules", "node_modules/x/y"));
    try testing.expect(!matches("/node_modules", "bindings/typescript/node_modules/.bin/tsc"));
}

fn writeBlob(store: *Store, data: []const u8) !Oid {
    return store.writeFileContent(data);
}

test "purge drops a path from every change and moves the branch" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const src = try writeBlob(&store, "source");
    const junk = try writeBlob(&store, "a build artifact nobody wants");

    const first = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "src/main.zig", .blob = src },
        .{ .mode = .regular, .path = "zig-out/bin/et", .blob = junk },
    };
    const t1 = try store.writeTree(.{ .entries = &first });
    const c1 = try store.writeChange(.{
        .tree = t1,
        .parents = &.{},
        .change_id = [_]u8{1} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "one",
    });
    const c2 = try store.writeChange(.{
        .tree = t1,
        .parents = &[_]Oid{c1},
        .change_id = [_]u8{2} ** 16,
        .timestamp = 2,
        .tz_offset_min = 0,
        .author = "t",
        .message = "two",
    });
    try store.updateRef("main", c2);

    const specs = [_][]const u8{"zig-out"};
    const stats = try purge(&store, alloc, &specs, 3, false);

    try testing.expectEqual(@as(usize, 1), stats.branches);
    try testing.expectEqual(@as(usize, 2), stats.changes);
    try testing.expectEqual(@as(usize, 1), stats.paths);

    const tip = try store.readRef("main");
    try testing.expect(!tip.eql(c2));

    const chain = try history.chainOf(&store, alloc, tip);
    defer alloc.free(chain);
    try testing.expectEqual(@as(usize, 2), chain.len);

    for (chain) |c| {
        const change = try store.readChange(c);
        defer object.freeChange(alloc, change);
        const tree = try store.readTree(change.tree);
        defer object.freeTree(alloc, tree);
        try testing.expectEqual(@as(usize, 1), tree.entries.len);
        try testing.expectEqualStrings("src/main.zig", tree.entries[0].path);
    }

    // Messages and identities survive the rewrite; only the tree differs.
    const head = try store.readChange(chain[1]);
    defer object.freeChange(alloc, head);
    try testing.expectEqualStrings("two", head.message);
    try testing.expectEqual([_]u8{2} ** 16, head.change_id);
}

test "a dry run reports the same counts and changes nothing" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const src = try writeBlob(&store, "source");
    const junk = try writeBlob(&store, "junk");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep.txt", .blob = src },
        .{ .mode = .regular, .path = "target/debug/app", .blob = junk },
    };
    const t = try store.writeTree(.{ .entries = &entries });
    const c = try store.writeChange(.{
        .tree = t,
        .parents = &.{},
        .change_id = [_]u8{7} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "m",
    });
    try store.updateRef("main", c);

    const specs = [_][]const u8{"target"};
    const stats = try purge(&store, alloc, &specs, 2, true);
    try testing.expectEqual(@as(usize, 1), stats.changes);
    try testing.expectEqual(@as(usize, 1), stats.paths);
    try testing.expect(stats.bytes > 0);

    try testing.expect((try store.readRef("main")).eql(c));
}

test "purging a path no change holds is an error, not a silent rewrite" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const src = try writeBlob(&store, "source");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep.txt", .blob = src },
    };
    const t = try store.writeTree(.{ .entries = &entries });
    const c = try store.writeChange(.{
        .tree = t,
        .parents = &.{},
        .change_id = [_]u8{9} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "m",
    });
    try store.updateRef("main", c);

    const specs = [_][]const u8{"zig-out"};
    try testing.expectError(Error.NothingMatched, purge(&store, alloc, &specs, 2, false));
    try testing.expect((try store.readRef("main")).eql(c));
}

test "purge drops the gitmap lines whose change it replaced, and keeps the rest" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const src = try writeBlob(&store, "source");
    const junk = try writeBlob(&store, "junk");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "keep.txt", .blob = src },
        .{ .mode = .regular, .path = "zig-out/bin/et", .blob = junk },
    };
    const t = try store.writeTree(.{ .entries = &entries });
    const c = try store.writeChange(.{
        .tree = t,
        .parents = &.{},
        .change_id = [_]u8{4} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "m",
    });
    try store.updateRef("main", c);

    var c_hex: [64]u8 = undefined;
    _ = c.toHex(&c_hex);
    const unrelated = "b" ** 64;
    const map = try std.fmt.allocPrint(alloc, "{s} {s}\n{s} {s}\n", .{
        "a" ** 40, c_hex, "c" ** 40, unrelated,
    });
    defer alloc.free(map);
    try store.root.writeFile(io, .{ .sub_path = "gitmap", .data = map });

    const specs = [_][]const u8{"zig-out"};
    const stats = try purge(&store, alloc, &specs, 2, false);
    try testing.expectEqual(@as(usize, 1), stats.unmapped);

    const after = try store.root.readFileAlloc(io, "gitmap", alloc, .unlimited);
    defer alloc.free(after);
    try testing.expect(std.mem.indexOf(u8, after, &c_hex) == null);
    try testing.expect(std.mem.indexOf(u8, after, unrelated) != null);
}

test "purge leaves nothing pinning the old trees" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const src = try writeBlob(&store, "source");
    const junk = try writeBlob(&store, "a build artifact nobody wants");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "src/main.zig", .blob = src },
        .{ .mode = .regular, .path = "zig-out/bin/et", .blob = junk },
    };
    const t = try store.writeTree(.{ .entries = &entries });
    const c = try store.writeChange(.{
        .tree = t,
        .parents = &.{},
        .change_id = [_]u8{3} ** 16,
        .timestamp = 1,
        .tz_offset_min = 0,
        .author = "t",
        .message = "m",
    });
    try store.updateRef("main", c);
    try oplog.record(&store, .{
        .kind = .snapshot,
        .branch = "main",
        .prev = Oid.zero(),
        .new = c,
        .timestamp = 1,
    });

    const specs = [_][]const u8{"zig-out"};
    _ = try purge(&store, alloc, &specs, 2, false);

    const gc = @import("gc.zig");
    const swept = try gc.collect(&store, alloc, false);
    try testing.expect(swept.swept > 0);
    try testing.expect(!store.has(junk));
    try testing.expect(store.has(src));
}
