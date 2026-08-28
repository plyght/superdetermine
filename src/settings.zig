const std = @import("std");
const config = @import("config.zig");

/// The settings a person actually configures, under the names a person would
/// use for them.
///
/// The file format is `key = value` with dotted keys, which is the right shape
/// for a file and the wrong shape for a command line: nobody remembers whether
/// the suite is `checks.full`, `check.full` or `checks.command`, and a typo in a
/// dotted key is indistinguishable from a key this version does not know yet, so
/// it is accepted in silence and does nothing. This table is the other half:
/// every setting carries a plain name, what it means, what values it takes, and
/// which scope it belongs in, so the CLI can name them, list them, validate what
/// it is given, and say what a near-miss probably meant. The dotted keys keep
/// working — in files, in scripts, and on the command line — because they are
/// the storage format; the names are the interface.
pub const Kind = enum {
    /// Free text.
    text,
    /// A shell command line.
    command,
    /// on / off.
    toggle,
    /// One of `choices`.
    choice,
    /// A human duration, stored the way it was written (`90s`, `2h`).
    duration,
    /// A human duration, stored as whole milliseconds because its reader wants
    /// a bare number.
    duration_ms,
    /// A non-negative whole number.
    count,
    /// 0–100, written with or without a `%`.
    percent,
    /// A signed whole number.
    number,
    /// A comma-separated list.
    list,
    /// A URL, or anything that names a remote.
    url,
    /// Set like anything else, never printed back.
    secret,
};

pub const Scope = enum { local, global };

pub const Setting = struct {
    /// What it is called on the command line.
    name: []const u8,
    /// What it is called on disk.
    key: []const u8,
    kind: Kind,
    group: []const u8,
    /// One line, lower case, no trailing period: this is printed in a list.
    desc: []const u8,
    /// What happens when it is unset, phrased as a value.
    default: []const u8 = "",
    choices: []const []const u8 = &.{},
    /// Other names that mean this setting.
    also: []const []const u8 = &.{},
    /// Where a bare `sdt config <name> <value>` writes it. Identity is about the
    /// person, so it belongs to the machine; everything else is about the repo.
    scope: Scope = .local,
};

pub const table = [_]Setting{
    .{
        .name = "name",
        .key = "user.name",
        .kind = .text,
        .group = "who you are",
        .desc = "the name on changes you save",
        .scope = .global,
    },
    .{
        .name = "email",
        .key = "user.email",
        .kind = .text,
        .group = "who you are",
        .desc = "the email on changes you save",
        .scope = .global,
    },
    .{
        .name = "default-branch",
        .key = "init.defaultBranch",
        .kind = .text,
        .group = "who you are",
        .desc = "branch name `sdt init` starts with",
        .default = "main",
        .also = &.{"init.defaultbranch"},
        .scope = .global,
    },

    .{
        .name = "check",
        .key = "checks.full",
        .kind = .command,
        .group = "what says your code works",
        .desc = "the command that has to pass",
        .default = "nothing is ever run",
        .also = &.{ "test", "suite", "full-check" },
    },
    .{
        .name = "fast-check",
        .key = "checks.fast",
        .kind = .command,
        .group = "what says your code works",
        .desc = "a quicker command, run when the suite is too slow",
        .also = &.{ "lint", "typecheck" },
    },
    .{
        .name = "grading",
        .key = "checks.enabled",
        .kind = .toggle,
        .group = "what says your code works",
        .desc = "master switch: off means no check ever runs",
        .default = "on once a check is set",
        .also = &.{ "auto-grade", "checks-enabled" },
    },
    .{
        .name = "timeout",
        .key = "checks.timeout",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "how long one run may take before it is killed",
        .default = "10m",
    },
    .{
        .name = "fast-timeout",
        .key = "checks.timeout.fast",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "timeout for the fast check alone",
    },
    .{
        .name = "full-timeout",
        .key = "checks.timeout.full",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "timeout for the suite alone",
    },
    .{
        .name = "fresh-for",
        .key = "checks.fresh",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "how long a pass keeps answering before it is re-run",
        .default = "forever",
    },
    .{
        .name = "check-inputs",
        .key = "checks.inputs",
        .kind = .list,
        .group = "what says your code works",
        .desc = "globs whose contents decide what the check says",
    },
    .{
        .name = "check-paths",
        .key = "checks.test_paths",
        .kind = .list,
        .group = "what says your code works",
        .desc = "globs naming the tests themselves",
    },
    .{
        .name = "cpu-budget",
        .key = "checks.budget",
        .kind = .percent,
        .group = "what says your code works",
        .desc = "share of one core a background check may use",
        .default = "25%",
    },
    .{
        .name = "tick-budget",
        .key = "checks.tick_budget",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "wall-clock ceiling on one slice of background work",
        .default = "2m",
    },
    .{
        .name = "battery-floor",
        .key = "checks.battery_floor",
        .kind = .percent,
        .group = "what says your code works",
        .desc = "stop grading on battery below this",
        .default = "30%",
    },
    .{
        .name = "nice",
        .key = "checks.nice",
        .kind = .number,
        .group = "what says your code works",
        .desc = "scheduling priority of a background check; higher yields more",
        .default = "10",
    },

    .{
        .name = "kill-grace",
        .key = "checks.kill_grace",
        .kind = .duration,
        .group = "what says your code works",
        .desc = "how long a timed-out check gets to exit before it is killed",
    },

    .{
        .name = "capture",
        .key = "moments.enabled",
        .kind = .toggle,
        .group = "what is captured",
        .desc = "keep capturing the worktree as it moves",
        .default = "on",
    },
    .{
        .name = "capture-every",
        .key = "moments.interval_ms",
        .kind = .duration_ms,
        .group = "what is captured",
        .desc = "shortest gap between two captures",
        .default = "800ms",
        .also = &.{"interval"},
    },
    .{
        .name = "keep-moments",
        .key = "moments.max",
        .kind = .count,
        .group = "what is captured",
        .desc = "how many moments to keep at most",
        .default = "10000",
    },
    .{
        .name = "keep-moments-for",
        .key = "moments.retain",
        .kind = .duration,
        .group = "what is captured",
        .desc = "how long a moment is kept",
        .default = "14d",
    },
    .{
        .name = "keyframe-every",
        .key = "moments.keyframe_interval",
        .kind = .count,
        .group = "what is captured",
        .desc = "moments between full trees; lower is faster to read, larger on disk",
        .default = "200",
    },
    .{
        .name = "gc-retain",
        .key = "gc.retain",
        .kind = .duration,
        .group = "what is captured",
        .desc = "how long an unreachable object survives a `sdt gc`",
        .default = "14d",
    },

    .{
        .name = "cut",
        .key = "flow.cut",
        .kind = .choice,
        .group = "how changes get made",
        .desc = "when a change is cut for you",
        .default = "manual",
        .choices = &.{ "green", "idle", "manual" },
    },
    .{
        .name = "publish",
        .key = "flow.publish",
        .kind = .toggle,
        .group = "how changes get made",
        .desc = "let a cut change replicate to a remote on its own",
        .default = "off",
    },
    .{
        .name = "publish-to",
        .key = "flow.publish.remote",
        .kind = .text,
        .group = "how changes get made",
        .desc = "which remote `publish` uses",
        .default = "origin",
    },
    .{
        .name = "superpose",
        .key = "merge.superpose",
        .kind = .toggle,
        .group = "how changes get made",
        .desc = "keep both versions of a conflicted path instead of halting",
    },
    .{
        .name = "primary",
        .key = "merge.primary",
        .kind = .text,
        .group = "how changes get made",
        .desc = "which side a superposed path shows by default",
    },
    .{
        .name = "max-superposed",
        .key = "merge.max_superposed",
        .kind = .count,
        .group = "how changes get made",
        .desc = "how many paths may hold more than one version at once",
    },

    .{
        .name = "remote",
        .key = "remote.origin.url",
        .kind = .url,
        .group = "talking to other repos",
        .desc = "where `sdt push` and `sdt pull` go",
        .default = "whatever git has",
    },
    .{
        .name = "auto-pull",
        .key = "remote.autopull",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "pull what the remote gained before work that needs it",
    },
    .{
        .name = "freshen-every",
        .key = "remote.freshen_ms",
        .kind = .duration_ms,
        .group = "talking to other repos",
        .desc = "how often to ask the remote what it has",
    },
    .{
        .name = "require-green",
        .key = "push.require_green",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "refuse to push a state the check has not passed",
        .default = "off",
    },
    .{
        .name = "git-sync",
        .key = "sync.git",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "mirror every save into a colocated .git",
        .default = "off",
    },
    .{
        .name = "lfs-url",
        .key = "lfs.url",
        .kind = .url,
        .group = "talking to other repos",
        .desc = "git-lfs endpoint for large files",
    },
    .{
        .name = "lfs-smudge",
        .key = "lfs.smudge",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "resolve git-lfs pointers to the real bytes on import",
        .default = "on",
    },
    .{
        .name = "lfs-upload",
        .key = "lfs.upload",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "upload lfs objects the remote is missing on push",
        .default = "on",
    },
    .{
        .name = "mesh",
        .key = "mesh.enabled",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "join the live room this repo has a secret for",
    },
    .{
        .name = "mesh-verdicts",
        .key = "mesh.verdicts",
        .kind = .toggle,
        .group = "talking to other repos",
        .desc = "share what your checks said with the room",
    },
    .{
        .name = "mesh-every",
        .key = "mesh.interval-ms",
        .kind = .duration_ms,
        .group = "talking to other repos",
        .desc = "how often the room notices your tree moved",
        .default = "25ms",
    },
    .{
        .name = "mesh-secret",
        .key = "mesh.secret",
        .kind = .secret,
        .group = "talking to other repos",
        .desc = "the room's secret; set by `sdt mesh open|join`",
    },

    .{
        .name = "provenance",
        .key = "provenance",
        .kind = .toggle,
        .group = "who wrote it",
        .desc = "record where a change came from",
        .default = "on",
    },
    .{
        .name = "agent-scan",
        .key = "provenance.autoscan",
        .kind = .toggle,
        .group = "who wrote it",
        .desc = "read coding-agent session logs to attribute edits",
        .default = "on",
    },
    .{
        .name = "live",
        .key = "live.enabled",
        .kind = .toggle,
        .group = "who wrote it",
        .desc = "show what collaborators are touching right now",
    },
};

fn sameName(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const cx = if (x == '_') '-' else std.ascii.toLower(x);
        const cy = if (y == '_') '-' else std.ascii.toLower(y);
        if (cx != cy) return false;
    }
    return true;
}

/// The setting `name` refers to, whether it was written as a name, one of its
/// other names, or the dotted key it is stored under.
pub fn find(name: []const u8) ?*const Setting {
    for (&table) |*s| {
        if (sameName(s.name, name)) return s;
        if (sameName(s.key, name)) return s;
        for (s.also) |alt| {
            if (sameName(alt, name)) return s;
        }
    }
    return null;
}

fn distance(a: []const u8, b: []const u8, budget: usize) usize {
    // Bounded Levenshtein: only used to answer "did you mean", so anything
    // past the budget is reported as the budget and the caller ignores it.
    var prev: [64]usize = undefined;
    var cur: [64]usize = undefined;
    if (a.len >= prev.len or b.len >= prev.len) return budget + 1;
    for (0..b.len + 1) |j| prev[j] = j;
    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

/// The setting a misspelling most likely meant, if one is close enough to be
/// worth suggesting.
pub fn suggest(name: []const u8) ?*const Setting {
    var best: ?*const Setting = null;
    var best_d: usize = 4;
    for (&table) |*s| {
        const candidates = [_][]const u8{ s.name, s.key };
        for (candidates) |c| {
            const d = distance(name, c, best_d);
            if (d < best_d) {
                best_d = d;
                best = s;
            }
        }
        for (s.also) |alt| {
            const d = distance(name, alt, best_d);
            if (d < best_d) {
                best_d = d;
                best = s;
            }
        }
    }
    return best;
}

pub const ValueError = error{ NotABool, NotAChoice, NotADuration, NotANumber, OutOfRange };

const truthy = [_][]const u8{ "on", "true", "yes", "y", "1", "enable", "enabled" };
const falsy = [_][]const u8{ "off", "false", "no", "n", "0", "disable", "disabled" };

pub fn boolOf(raw: []const u8) ?bool {
    for (truthy) |t| {
        if (std.ascii.eqlIgnoreCase(raw, t)) return true;
    }
    for (falsy) |f| {
        if (std.ascii.eqlIgnoreCase(raw, f)) return false;
    }
    return null;
}

/// Turn what somebody typed into what goes in the file, or say why it is not a
/// value for this setting. Caller frees.
pub fn normalize(alloc: std.mem.Allocator, s: *const Setting, raw: []const u8) ![]u8 {
    const v = std.mem.trim(u8, raw, " \t\r\n");
    switch (s.kind) {
        .toggle => {
            const b = boolOf(v) orelse return ValueError.NotABool;
            return alloc.dupe(u8, if (b) "true" else "false");
        },
        .choice => {
            for (s.choices) |c| {
                if (std.ascii.eqlIgnoreCase(v, c)) return alloc.dupe(u8, c);
            }
            return ValueError.NotAChoice;
        },
        .duration => {
            _ = config.parseDurationMs(v) orelse return ValueError.NotADuration;
            return alloc.dupe(u8, v);
        },
        .duration_ms => {
            const ms = config.parseDurationMs(v) orelse return ValueError.NotADuration;
            return std.fmt.allocPrint(alloc, "{d}", .{ms});
        },
        .count => {
            const n = std.fmt.parseInt(u64, v, 10) catch return ValueError.NotANumber;
            return std.fmt.allocPrint(alloc, "{d}", .{n});
        },
        .number => {
            const n = std.fmt.parseInt(i64, v, 10) catch return ValueError.NotANumber;
            return std.fmt.allocPrint(alloc, "{d}", .{n});
        },
        .percent => {
            const bare = std.mem.trimEnd(u8, v, "%");
            const n = std.fmt.parseInt(u8, bare, 10) catch return ValueError.NotANumber;
            if (n > 100) return ValueError.OutOfRange;
            return std.fmt.allocPrint(alloc, "{d}", .{n});
        },
        .text, .command, .list, .url, .secret => return alloc.dupe(u8, v),
    }
}

/// How a stored value is shown back. Toggles read as `on`/`off` however they
/// were written, durations kept in milliseconds read as durations again, and a
/// secret is never printed. Caller frees.
pub fn display(alloc: std.mem.Allocator, s: *const Setting, stored: []const u8) ![]u8 {
    switch (s.kind) {
        .toggle => {
            const b = boolOf(stored) orelse return alloc.dupe(u8, stored);
            return alloc.dupe(u8, if (b) "on" else "off");
        },
        .duration_ms => {
            const ms = std.fmt.parseInt(i64, std.mem.trim(u8, stored, " \t"), 10) catch
                return alloc.dupe(u8, stored);
            return humanDuration(alloc, ms);
        },
        .percent => return std.fmt.allocPrint(alloc, "{s}%", .{stored}),
        .secret => return alloc.dupe(u8, if (stored.len == 0) "" else "set"),
        else => return alloc.dupe(u8, stored),
    }
}

fn humanDuration(alloc: std.mem.Allocator, ms: i64) ![]u8 {
    if (ms != 0 and @rem(ms, std.time.ms_per_day) == 0)
        return std.fmt.allocPrint(alloc, "{d}d", .{@divTrunc(ms, std.time.ms_per_day)});
    if (ms != 0 and @rem(ms, std.time.ms_per_hour) == 0)
        return std.fmt.allocPrint(alloc, "{d}h", .{@divTrunc(ms, std.time.ms_per_hour)});
    if (ms != 0 and @rem(ms, std.time.ms_per_min) == 0)
        return std.fmt.allocPrint(alloc, "{d}m", .{@divTrunc(ms, std.time.ms_per_min)});
    if (ms != 0 and @rem(ms, std.time.ms_per_s) == 0)
        return std.fmt.allocPrint(alloc, "{d}s", .{@divTrunc(ms, std.time.ms_per_s)});
    return std.fmt.allocPrint(alloc, "{d}ms", .{ms});
}

/// What to say when a value is rejected, phrased as what this setting takes.
pub fn expected(s: *const Setting) []const u8 {
    return switch (s.kind) {
        .toggle => "on or off",
        .choice => "one of its choices",
        .duration => "a duration, like 90s or 2h",
        .duration_ms => "a duration, like 800ms or 3s",
        .count => "a whole number",
        .number => "a whole number, negative allowed",
        .percent => "a percentage from 0 to 100",
        else => "any text",
    };
}

// --- tests ---

const testing = std.testing;

test "a setting is found by name, by other name, and by dotted key" {
    try testing.expectEqualStrings("checks.full", find("check").?.key);
    try testing.expectEqualStrings("checks.full", find("test").?.key);
    try testing.expectEqualStrings("checks.full", find("checks.full").?.key);
    // Underscores and case are the same word.
    try testing.expectEqualStrings("checks.battery_floor", find("battery_floor").?.key);
    try testing.expectEqualStrings("checks.battery_floor", find("Battery-Floor").?.key);
    try testing.expect(find("nonsense") == null);
}

test "every setting has a unique name and key" {
    for (&table, 0..) |*a, i| {
        for (table[i + 1 ..]) |b| {
            try testing.expect(!sameName(a.name, b.name));
            try testing.expect(!sameName(a.key, b.key));
        }
    }
}

test "a near miss suggests the setting it probably meant" {
    try testing.expectEqualStrings("check", suggest("chek").?.name);
    try testing.expectEqualStrings("grading", suggest("autograde").?.name);
    try testing.expectEqualStrings("email", suggest("emial").?.name);
}

test "values are normalized into what the file format stores" {
    const alloc = testing.allocator;

    const on = try normalize(alloc, find("grading").?, "yes");
    defer alloc.free(on);
    try testing.expectEqualStrings("true", on);

    const off = try normalize(alloc, find("capture").?, "OFF");
    defer alloc.free(off);
    try testing.expectEqualStrings("false", off);

    // A duration whose reader wants a bare number is converted for it.
    const ms = try normalize(alloc, find("capture-every").?, "3s");
    defer alloc.free(ms);
    try testing.expectEqualStrings("3000", ms);

    // A duration whose reader parses durations is kept as written.
    const dur = try normalize(alloc, find("timeout").?, "90s");
    defer alloc.free(dur);
    try testing.expectEqualStrings("90s", dur);

    const pct = try normalize(alloc, find("cpu-budget").?, "40%");
    defer alloc.free(pct);
    try testing.expectEqualStrings("40", pct);

    const cut = try normalize(alloc, find("cut").?, "GREEN");
    defer alloc.free(cut);
    try testing.expectEqualStrings("green", cut);

    try testing.expectError(ValueError.NotABool, normalize(alloc, find("capture").?, "maybe"));
    try testing.expectError(ValueError.NotADuration, normalize(alloc, find("timeout").?, "soon"));
    try testing.expectError(ValueError.NotAChoice, normalize(alloc, find("cut").?, "sometimes"));
    try testing.expectError(ValueError.OutOfRange, normalize(alloc, find("cpu-budget").?, "150"));
}

test "stored values are shown the way they were asked for" {
    const alloc = testing.allocator;

    const t = try display(alloc, find("capture").?, "true");
    defer alloc.free(t);
    try testing.expectEqualStrings("on", t);

    const d = try display(alloc, find("capture-every").?, "3000");
    defer alloc.free(d);
    try testing.expectEqualStrings("3s", d);

    const ms = try display(alloc, find("capture-every").?, "800");
    defer alloc.free(ms);
    try testing.expectEqualStrings("800ms", ms);

    const secret = try display(alloc, find("mesh-secret").?, "hunter2");
    defer alloc.free(secret);
    try testing.expectEqualStrings("set", secret);
}
