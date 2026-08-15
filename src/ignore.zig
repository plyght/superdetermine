const std = @import("std");

/// A parsed `.sdtignore` file. Rules are matched in order; the last matching
/// rule decides, so a later `!pattern` can re-include a path an earlier rule
/// excluded. The repo dir and `.git` are always ignored regardless of ruleset.
pub const IgnoreList = struct {
    alloc: std.mem.Allocator,
    rules: []Rule,

    const Rule = struct {
        pattern: []u8,
        negated: bool,
        anchored: bool,
        dir_only: bool,
    };

    pub fn deinit(self: *IgnoreList) void {
        for (self.rules) |r| self.alloc.free(r.pattern);
        self.alloc.free(self.rules);
    }

    /// Read `.sdtignore` from `dir` if present; an absent file yields an empty
    /// (but valid) list.
    pub fn load(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) !IgnoreList {
        const text = dir.readFileAlloc(io, ".sdtignore", alloc, .unlimited) catch {
            return .{ .alloc = alloc, .rules = try alloc.alloc(Rule, 0) };
        };
        defer alloc.free(text);
        return loadFromText(alloc, text);
    }

    /// Read `.gitignore` first and then the ignore file, so `.gitignore` rules
    /// apply but ours, being later, wins on conflict (last matching rule
    /// decides). Any file may be absent.
    ///
    /// `.gitignore` is honored whether or not a colocated `.git` is present. A
    /// repo that is sdt-only today may still carry a `.gitignore` listing its
    /// build output, and reading it only once git interop happens to be set up
    /// means every save until then commits `zig-out/`, `target/` and the rest
    /// into permanent history.
    pub fn loadMerged(alloc: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) !IgnoreList {
        var rules: std.ArrayList(Rule) = .empty;
        errdefer {
            for (rules.items) |r| alloc.free(r.pattern);
            rules.deinit(alloc);
        }
        const names: []const []const u8 = &[_][]const u8{ ".gitignore", ".sdtignore" };
        for (names) |name| {
            const text = dir.readFileAlloc(io, name, alloc, .unlimited) catch continue;
            defer alloc.free(text);
            var parsed = try loadFromText(alloc, text);
            defer parsed.deinit();
            for (parsed.rules) |r| {
                const pat = try alloc.dupe(u8, r.pattern);
                errdefer alloc.free(pat);
                try rules.append(alloc, .{
                    .pattern = pat,
                    .negated = r.negated,
                    .anchored = r.anchored,
                    .dir_only = r.dir_only,
                });
            }
        }
        return .{ .alloc = alloc, .rules = try rules.toOwnedSlice(alloc) };
    }

    pub fn loadFromText(alloc: std.mem.Allocator, text: []const u8) !IgnoreList {
        var rules: std.ArrayList(Rule) = .empty;
        errdefer {
            for (rules.items) |r| alloc.free(r.pattern);
            rules.deinit(alloc);
        }

        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw_line| {
            var line = std.mem.trimEnd(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (line[0] == '#') continue;

            var negated = false;
            if (line[0] == '!') {
                negated = true;
                line = line[1..];
                if (line.len == 0) continue;
            }

            var dir_only = false;
            if (line.len > 0 and line[line.len - 1] == '/') {
                dir_only = true;
                line = line[0 .. line.len - 1];
                if (line.len == 0) continue;
            }

            var anchored = false;
            if (line.len > 0 and line[0] == '/') {
                anchored = true;
                line = line[1..];
                if (line.len == 0) continue;
            }

            const pat = try alloc.dupe(u8, line);
            errdefer alloc.free(pat);
            try rules.append(alloc, .{
                .pattern = pat,
                .negated = negated,
                .anchored = anchored,
                .dir_only = dir_only,
            });
        }

        return .{ .alloc = alloc, .rules = try rules.toOwnedSlice(alloc) };
    }

    /// `rel_path` is repo-root-relative and forward-slash separated.
    pub fn isIgnored(self: IgnoreList, rel_path: []const u8, is_dir: bool) bool {
        const base = basename(rel_path);
        if (std.mem.eql(u8, base, ".sdt") or std.mem.eql(u8, base, ".git")) return true;

        var ignored = false;
        for (self.rules) |r| {
            if (r.dir_only and !is_dir) continue;
            const hit = if (r.anchored or std.mem.indexOfScalar(u8, r.pattern, '/') != null)
                matchPath(r.pattern, rel_path)
            else
                matchSegment(r.pattern, base);
            if (hit) ignored = !r.negated;
        }
        return ignored;
    }
};

fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    return path;
}

/// Match a slash-bearing pattern against a full rel_path. `**` spans segments;
/// `*`/`?` stay within a single segment.
pub fn matchPath(pattern: []const u8, path: []const u8) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var pat_segs: [256][]const u8 = undefined;
    var np: usize = 0;
    while (pat_it.next()) |s| {
        if (np == pat_segs.len) return false;
        pat_segs[np] = s;
        np += 1;
    }
    var path_it = std.mem.splitScalar(u8, path, '/');
    var path_segs: [256][]const u8 = undefined;
    var nq: usize = 0;
    while (path_it.next()) |s| {
        if (nq == path_segs.len) return false;
        path_segs[nq] = s;
        nq += 1;
    }
    return matchSegs(pat_segs[0..np], path_segs[0..nq]);
}

fn matchSegs(pat: []const []const u8, path: []const []const u8) bool {
    if (pat.len == 0) return path.len == 0;
    if (std.mem.eql(u8, pat[0], "**")) {
        if (matchSegs(pat[1..], path)) return true;
        if (path.len > 0) return matchSegs(pat, path[1..]);
        return false;
    }
    if (path.len == 0) return false;
    if (!matchSegment(pat[0], path[0])) return false;
    return matchSegs(pat[1..], path[1..]);
}

/// Single-segment glob supporting `*` and `?` (neither crosses a segment).
pub fn matchSegment(pat: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    var star_pi: ?usize = null;
    var star_si: usize = 0;
    while (si < s.len) {
        if (pi < pat.len and (pat[pi] == '?' or pat[pi] == s[si])) {
            pi += 1;
            si += 1;
        } else if (pi < pat.len and pat[pi] == '*') {
            star_pi = pi;
            star_si = si;
            pi += 1;
        } else if (star_pi) |sp| {
            pi = sp + 1;
            star_si += 1;
            si = star_si;
        } else {
            return false;
        }
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// --- tests ---

const testing = std.testing;

test "ignore rules: dir, glob, negation, anchored, nested" {
    const alloc = testing.allocator;
    var list = try IgnoreList.loadFromText(alloc,
        \\# comment
        \\target/
        \\*.o
        \\!keep.o
        \\/dist
        \\src/foo.o
    );
    defer list.deinit();

    try testing.expect(list.isIgnored("target", true));
    try testing.expect(list.isIgnored("a/target", true));
    try testing.expect(!list.isIgnored("target", false)); // dir-only rule
    try testing.expect(list.isIgnored("main.o", false));
    try testing.expect(list.isIgnored("a/b/main.o", false));
    try testing.expect(!list.isIgnored("keep.o", false)); // negated
    try testing.expect(list.isIgnored("dist", true)); // anchored root
    try testing.expect(!list.isIgnored("a/dist", true)); // anchored: not nested
    try testing.expect(list.isIgnored("src/foo.o", false));
}

test "always ignore the repo dir and .git" {
    const alloc = testing.allocator;
    var list = try IgnoreList.loadFromText(alloc, "");
    defer list.deinit();
    try testing.expect(list.isIgnored(".sdt", true));
    try testing.expect(list.isIgnored(".git", true));
    try testing.expect(list.isIgnored("a/.git", true));
    try testing.expect(!list.isIgnored("normal.txt", false));
}

test "loadMerged reads gitignore and sdtignore, sdtignore wins" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nbuild/\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = ".sdtignore", .data = "!keep.log\n" });
    var list = try IgnoreList.loadMerged(alloc, tmp.dir, io);
    defer list.deinit();
    try testing.expect(list.isIgnored("a.log", false)); // from .gitignore
    try testing.expect(list.isIgnored("build", true)); // from .gitignore
    try testing.expect(!list.isIgnored("keep.log", false)); // .sdtignore re-includes
}

test "loadMerged honors gitignore with no colocated .git" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "*.log\nzig-out/\n" });
    var list = try IgnoreList.loadMerged(alloc, tmp.dir, io);
    defer list.deinit();
    try testing.expect(list.isIgnored("a.log", false));
    try testing.expect(list.isIgnored("zig-out", true));
}

test "loadMerged with neither file yields empty list" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var list = try IgnoreList.loadMerged(alloc, tmp.dir, io);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.rules.len);
}

test "absent file yields empty list" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var list = try IgnoreList.load(alloc, tmp.dir, io);
    defer list.deinit();
    try testing.expectEqual(@as(usize, 0), list.rules.len);
    try testing.expect(!list.isIgnored("foo.txt", false));
}
