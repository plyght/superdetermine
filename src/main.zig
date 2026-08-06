const std = @import("std");
const oid = @import("oid.zig");
const cdc = @import("cdc.zig");
const object = @import("object.zig");
const store = @import("store.zig");
const workspace = @import("workspace.zig");
const oplog = @import("oplog.zig");
const git = @import("git.zig");
const diff = @import("diff.zig");
const branches = @import("branches.zig");
const config = @import("config.zig");
const merge = @import("merge.zig");
const watch = @import("watch.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const revspec = @import("revspec.zig");
const checks = @import("checks.zig");
const readset = @import("readset.zig");
const warrant = @import("warrant.zig");
const tracer = @import("tracer.zig");
const grade = @import("grade.zig");
const sched = @import("sched.zig");
const rewind = @import("rewind.zig");
const freshness = @import("freshness.zig");
const fork = @import("fork.zig");
const recap = @import("recap.zig");
const flow = @import("flow.zig");
const superpose = @import("superpose.zig");
const live = @import("live.zig");
const net = @import("net.zig");
const ignore = @import("ignore.zig");
const provenance = @import("provenance.zig");
const attribution = @import("attribution.zig");
const agentscan = @import("agentscan.zig");
const update = @import("update.zig");
const gc = @import("gc.zig");
const blame = @import("blame.zig");
const completions = @import("completions.zig");
const absorb = @import("absorb.zig");
const lfs = @import("lfs.zig");
const proc = @import("proc.zig");
const seal = @import("seal.zig");
const keyring = @import("keyring.zig");
const share = @import("share.zig");
const wormhole = @import("wormhole.zig");
const ui = @import("ui.zig");
const discovery = @import("discovery.zig");
const ipnet = std.Io.net;

const Oid = oid.Oid;
const Store = store.Store;

const version = "0.1.2";

const Entry = struct { name: []const u8, alias: []const u8 = "", args: []const u8 = "", desc: []const u8 };
const Section = struct { title: []const u8, entries: []const Entry };

const sections = [_]Section{
    .{ .title = "the everyday loop", .entries = &.{
        .{ .name = "save", .alias = "sv", .args = "[-m msg]", .desc = "checkpoint the working tree" },
        .{ .name = "status", .alias = "st", .desc = "what changed since the last save" },
        .{ .name = "diff", .alias = "d", .desc = "line-level diff vs the last save" },
        .{ .name = "log", .alias = "l", .desc = "the change history" },
        .{ .name = "describe", .alias = "desc", .args = "-m msg", .desc = "name or rename the current change" },
    } },
    .{ .title = "moving around", .entries = &.{
        .{ .name = "new", .alias = "n", .args = "<name>", .desc = "branch off here and switch to it" },
        .{ .name = "switch", .alias = "sw", .args = "<name>", .desc = "move to another branch (auto-saves)" },
        .{ .name = "branch", .alias = "b", .desc = "list branches" },
        .{ .name = "work", .alias = "wt", .args = "<dir>", .desc = "instant copy-on-write worktree" },
        .{ .name = "restore", .alias = "rs", .args = "<file>", .desc = "discard local edits to one file" },
        .{ .name = "merge", .alias = "mg", .args = "<branch>", .desc = "merge another branch into this one" },
        .{ .name = "resolve", .alias = "res", .args = "<file>", .desc = "mark a conflict resolved (--abort to bail)" },
        .{ .name = "revert", .alias = "rev", .desc = "undo a change as a new change" },
        .{ .name = "absorb", .alias = "ab", .desc = "fold edits into the changes they belong to" },
    } },
    .{ .title = "who wrote this", .entries = &.{
        .{ .name = "blame", .alias = "bl", .args = "<file>", .desc = "per-line authorship, incl. agent/prompt" },
        .{ .name = "provenance", .alias = "prov", .desc = "which agent/prompt produced each change" },
        .{ .name = "why", .args = "<file>", .desc = "who last authored a file" },
    } },
    .{ .title = "undo is never scary", .entries = &.{
        .{ .name = "undo", .alias = "u", .desc = "revert the last operation, whole repo" },
        .{ .name = "redo", .alias = "r", .desc = "reapply what you just undid" },
    } },
    .{ .title = "history that knows what worked", .entries = &.{
        .{ .name = "green", .alias = "gn", .desc = "rewind to the last state that passed" },
        .{ .name = "back", .alias = "bk", .args = "[n]", .desc = "rewind n moments, default 1" },
        .{ .name = "rewind", .alias = "rw", .args = "<ref>", .desc = "rewind to any @ref (--dry-run)" },
        .{ .name = "moments", .alias = "mo", .args = "[-n N]", .desc = "captured states and their verdicts" },
        .{ .name = "grade", .alias = "gd", .desc = "grade now; --on makes it automatic" },
        .{ .name = "doctor", .alias = "doc", .desc = "what is on, what is degraded, and why" },
        .{ .name = "recap", .alias = "rc", .args = "[@ref..]", .desc = "green and red spans, and what thrashed" },
    } },
    .{ .title = "conflicts that halt nothing", .entries = &.{
        .{ .name = "super", .alias = "sp", .args = "[path]", .desc = "paths holding more than one version" },
        .{ .name = "collapse", .alias = "cp", .args = "<path> <A|--greenest>", .desc = "keep one; nothing is deleted" },
        .{ .name = "note", .args = "<f>:<n> <text>", .desc = "annotate a line for whoever has it next" },
        .{ .name = "notes", .desc = "every annotation recorded here" },
    } },
    .{ .title = "secrets you can actually commit", .entries = &.{
        .{ .name = "seal", .alias = "sl", .args = "<path>", .desc = "seal a .env-style file" },
        .{ .name = "unseal", .alias = "us", .desc = "write the plaintext back out" },
        .{ .name = "key", .alias = "k", .args = "<cmd>", .desc = "new | show | add | remove | list" },
        .{ .name = "rotate", .alias = "rot", .desc = "new repo key, re-wrapped to every member" },
    } },
    .{ .title = "handing a repo to someone", .entries = &.{
        .{ .name = "send", .alias = "snd", .desc = "peer-to-peer on this network, via a code" },
        .{ .name = "send --file", .args = "<f>", .desc = "one sealed file, no network at all" },
        .{ .name = "send --link", .args = "<dir>", .desc = "static files you upload anywhere" },
        .{ .name = "get", .alias = "g", .args = "<code|url|file>", .desc = "the other side of all three" },
        .{ .name = "relay", .alias = "rv", .desc = "run a meeting point for internet transfers" },
    } },
    .{ .title = "distributed (no forced server)", .entries = &.{
        .{ .name = "serve", .alias = "srv", .args = "[port]", .desc = "share this repo's objects over TCP" },
        .{ .name = "serve --link", .args = "<dir>", .desc = "host a `send --link` export over HTTP" },
        .{ .name = "fetch", .alias = "f", .args = "<src>", .desc = "sparse-pull a branch" },
        .{ .name = "watch", .desc = "experimental: auto-save on every change" },
    } },
    .{ .title = "git, side by side", .entries = &.{
        .{ .name = "clone", .alias = "cl", .args = "<src> <dir>", .desc = "a git repo, a share URL, or a bundle" },
        .{ .name = "import", .args = "<repo>", .desc = "pull a git repo's HEAD into guardrail" },
        .{ .name = "export", .args = "<repo>", .desc = "write guardrail HEAD out as git commits" },
        .{ .name = "sync", .args = "<dir>", .desc = "mirror HEAD into the colocated .git" },
        .{ .name = "push", .alias = "ps", .desc = "uses your existing git credentials" },
        .{ .name = "pull", .alias = "pl", .desc = "fetch and merge from a git remote" },
        .{ .name = "lfs", .args = "<cmd>", .desc = "git-lfs interop" },
    } },
    .{ .title = "housekeeping", .entries = &.{
        .{ .name = "init", .desc = "create a guardrail repo here" },
        .{ .name = "gc", .args = "[--dry-run]", .desc = "reclaim unreachable objects" },
        .{ .name = "config", .alias = "cfg", .args = "<key> [val]", .desc = "identity and defaults" },
        .{ .name = "completions", .alias = "comp", .args = "<shell>", .desc = "fish | zsh | bash" },
        .{ .name = "update", .desc = "update gr (--nightly for the latest build)" },
        .{ .name = "version", .desc = "" },
    } },
};

fn printUsage(w: *std.Io.Writer) !void {
    try w.print("{s}gr{s} {s}guardrail: a fast independent VCS built for humans and agents{s}\n\n", .{
        ui.on(.bold), ui.off(), ui.on(.dim), ui.off(),
    });
    try w.print("  {s}usage:{s} gr <command> [args]\n", .{ ui.on(.dim), ui.off() });

    for (sections) |section| {
        try w.print("\n  {s}{s}{s}\n", .{ ui.on(.bold), section.title, ui.off() });
        for (section.entries) |e| {
            try w.print("    {s}{s}{s}", .{ ui.on(.cyan), e.name, ui.off() });
            var used = e.name.len;
            if (e.args.len != 0) {
                try w.print(" {s}{s}{s}", .{ ui.on(.dim), e.args, ui.off() });
                used += 1 + e.args.len;
            }
            try padTo(w, used, 26);
            if (e.alias.len != 0) {
                try w.print("{s}{s}{s}", .{ ui.on(.magenta), e.alias, ui.off() });
                try padTo(w, e.alias.len, 6);
            } else {
                try padTo(w, 0, 6);
            }
            try w.print("{s}\n", .{e.desc});
        }
    }
    try w.print("\n  {s}status and log take --json. NO_COLOR is respected.{s}\n", .{ ui.on(.dim), ui.off() });
}

fn padTo(w: *std.Io.Writer, used: usize, target: usize) !void {
    try w.splatByteAll(' ', if (used >= target) 1 else target - used);
}

const default_author = "you <you@localhost>";

const Alias = struct { short: []const u8, full: []const u8 };

const aliases = [_]Alias{
    .{ .short = "sv", .full = "save" },
    .{ .short = "snapshot", .full = "save" },
    .{ .short = "snap", .full = "save" },
    .{ .short = "ci", .full = "save" },
    .{ .short = "st", .full = "status" },
    .{ .short = "d", .full = "diff" },
    .{ .short = "l", .full = "log" },
    .{ .short = "desc", .full = "describe" },
    .{ .short = "b", .full = "branch" },
    .{ .short = "br", .full = "branch" },
    .{ .short = "branches", .full = "branch" },
    .{ .short = "n", .full = "new" },
    .{ .short = "sw", .full = "switch" },
    .{ .short = "co", .full = "switch" },
    .{ .short = "wt", .full = "work" },
    .{ .short = "rs", .full = "restore" },
    .{ .short = "mg", .full = "merge" },
    .{ .short = "res", .full = "resolve" },
    .{ .short = "rev", .full = "revert" },
    .{ .short = "ab", .full = "absorb" },
    .{ .short = "bl", .full = "blame" },
    .{ .short = "prov", .full = "provenance" },
    .{ .short = "u", .full = "undo" },
    .{ .short = "r", .full = "redo" },
    .{ .short = "gn", .full = "green" },
    .{ .short = "bk", .full = "back" },
    .{ .short = "rw", .full = "rewind" },
    .{ .short = "mo", .full = "moments" },
    .{ .short = "gd", .full = "grade" },
    .{ .short = "doc", .full = "doctor" },
    .{ .short = "rc", .full = "recap" },
    .{ .short = "sp", .full = "super" },
    .{ .short = "cp", .full = "collapse" },
    .{ .short = "srv", .full = "serve" },
    .{ .short = "f", .full = "fetch" },
    .{ .short = "cl", .full = "clone" },
    .{ .short = "ps", .full = "push" },
    .{ .short = "pl", .full = "pull" },
    .{ .short = "cfg", .full = "config" },
    .{ .short = "comp", .full = "completions" },
    .{ .short = "sl", .full = "seal" },
    .{ .short = "us", .full = "unseal" },
    .{ .short = "k", .full = "key" },
    .{ .short = "rot", .full = "rotate" },
    .{ .short = "snd", .full = "send" },
    .{ .short = "share", .full = "send" },
    .{ .short = "bundle", .full = "send" },
    .{ .short = "g", .full = "get" },
    .{ .short = "receive", .full = "get" },
    .{ .short = "recv", .full = "get" },
    .{ .short = "rc", .full = "get" },
    .{ .short = "rv", .full = "relay" },
    .{ .short = "rendezvous", .full = "relay" },
    .{ .short = "upgrade", .full = "update" },
    .{ .short = "-h", .full = "help" },
    .{ .short = "--help", .full = "help" },
    .{ .short = "--version", .full = "version" },
};

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);

    var prev: [65]usize = undefined;
    var cur: [65]usize = undefined;
    for (0..b.len + 1) |j| prev[j] = j;

    for (a, 0..) |ca, i| {
        cur[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (ca == cb) 0 else 1;
            cur[j + 1] = @min(@min(cur[j] + 1, prev[j + 1] + 1), prev[j] + cost);
        }
        @memcpy(prev[0 .. b.len + 1], cur[0 .. b.len + 1]);
    }
    return prev[b.len];
}

fn nearestCommand(cmd: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_score: usize = 3;
    for (sections) |section| {
        for (section.entries) |e| {
            const d = editDistance(cmd, e.name);
            if (d < best_score) {
                best_score = d;
                best = e.name;
            }
        }
    }
    for (aliases) |a| {
        const d = editDistance(cmd, a.short);
        if (d < best_score) {
            best_score = d;
            best = a.full;
        }
    }
    return best;
}

fn canonical(cmd: []const u8) []const u8 {
    for (aliases) |a| {
        if (eq(cmd, a.short)) return a.full;
    }
    return cmd;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var arg_it = init.minimal.args.iterate();
    defer arg_it.deinit();
    while (arg_it.next()) |a| try args_list.append(alloc, a);
    const args = args_list.items;

    var stdout_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
    const w = &stdout.interface;
    ui.init(io, std.Io.File.stdout());
    defer w.flush() catch {};

    if (args.len < 2) {
        try printUsage(w);
        return;
    }

    const cmd = canonical(args[1]);
    const rest = args[2..];

    if (eq(cmd, "version")) {
        try w.print("gr {s}\n", .{version});
    } else if (eq(cmd, "update")) {
        var nightly = false;
        for (rest) |a| {
            if (eq(a, "--nightly")) nightly = true;
        }
        try update.run(io, alloc, w, version, nightly);
    } else if (eq(cmd, "help")) {
        try printUsage(w);
    } else if (eq(cmd, "init")) {
        try cmdInit(io, alloc, w);
    } else if (eq(cmd, "save")) {
        try cmdSave(io, alloc, w, rest);
    } else if (eq(cmd, "describe")) {
        try cmdDescribe(io, alloc, w, rest);
    } else if (eq(cmd, "status")) {
        try cmdStatus(io, alloc, w, rest);
    } else if (eq(cmd, "diff")) {
        try cmdDiff(io, alloc, w);
    } else if (eq(cmd, "log")) {
        try cmdLog(io, alloc, w, rest);
    } else if (eq(cmd, "branch")) {
        try cmdBranch(io, alloc, w);
    } else if (eq(cmd, "new")) {
        try cmdNew(io, alloc, w, rest);
    } else if (eq(cmd, "switch")) {
        try cmdSwitch(io, alloc, w, rest);
    } else if (eq(cmd, "work")) {
        try cmdWork(io, alloc, w, rest);
    } else if (eq(cmd, "restore")) {
        try cmdRestore(io, alloc, w, rest);
    } else if (eq(cmd, "merge")) {
        try cmdMerge(io, alloc, w, rest);
    } else if (eq(cmd, "serve")) {
        try cmdServe(io, alloc, w, rest);
    } else if (eq(cmd, "fetch")) {
        try cmdFetch(io, alloc, w, rest);
    } else if (eq(cmd, "watch")) {
        try cmdWatch(io, alloc, w);
    } else if (eq(cmd, "moments")) {
        try cmdMoments(io, alloc, w, rest);
    } else if (eq(cmd, "grade")) {
        try cmdGrade(io, alloc, w, rest);
    } else if (eq(cmd, "doctor")) {
        try cmdDoctor(io, alloc, w);
    } else if (eq(cmd, "rewind")) {
        try cmdRewind(io, alloc, w, rest);
    } else if (eq(cmd, "back")) {
        try cmdBack(io, alloc, w, rest);
    } else if (eq(cmd, "green")) {
        try cmdGreen(io, alloc, w);
    } else if (eq(cmd, "recap")) {
        try cmdRecap(io, alloc, w, rest);
    } else if (eq(cmd, "super")) {
        try cmdSuper(io, alloc, w, rest);
    } else if (eq(cmd, "collapse")) {
        try cmdCollapse(io, alloc, w, rest);
    } else if (eq(cmd, "note")) {
        try cmdNote(io, alloc, w, rest);
    } else if (eq(cmd, "notes")) {
        try cmdNotes(io, alloc, w);
    } else if (eq(cmd, "undo")) {
        try cmdUndo(io, alloc, w);
    } else if (eq(cmd, "redo")) {
        try cmdRedo(io, alloc, w);
    } else if (eq(cmd, "import")) {
        try cmdGit(io, alloc, w, rest, .import);
    } else if (eq(cmd, "export")) {
        try cmdGit(io, alloc, w, rest, .export_);
    } else if (eq(cmd, "sync")) {
        try cmdGit(io, alloc, w, rest, .sync);
    } else if (eq(cmd, "push")) {
        try cmdPush(io, alloc, w, rest);
    } else if (eq(cmd, "pull")) {
        try cmdPull(io, alloc, w, rest);
    } else if (eq(cmd, "clone")) {
        try cmdClone(io, alloc, w, rest);
    } else if (eq(cmd, "config")) {
        try cmdConfig(io, alloc, w, rest);
    } else if (eq(cmd, "why")) {
        try cmdWhy(io, alloc, w, rest);
    } else if (eq(cmd, "provenance")) {
        try cmdProvenance(io, alloc, w);
    } else if (eq(cmd, "blame")) {
        try cmdBlame(io, alloc, w, rest);
    } else if (eq(cmd, "resolve")) {
        try cmdResolve(io, alloc, w, rest);
    } else if (eq(cmd, "revert")) {
        try cmdRevert(io, alloc, w, rest);
    } else if (eq(cmd, "absorb")) {
        try cmdAbsorb(io, alloc, w);
    } else if (eq(cmd, "gc")) {
        try cmdGc(io, alloc, w, rest);
    } else if (eq(cmd, "lfs")) {
        try cmdLfs(io, alloc, w, rest);
    } else if (eq(cmd, "completions")) {
        try cmdCompletions(w, rest);
    } else if (eq(cmd, "key")) {
        try cmdKey(io, alloc, w, rest);
    } else if (eq(cmd, "seal")) {
        try cmdSeal(io, alloc, w, rest);
    } else if (eq(cmd, "unseal")) {
        try cmdUnseal(io, alloc, w);
    } else if (eq(cmd, "rotate")) {
        try cmdRotate(io, alloc, w);
    } else if (eq(cmd, "send")) {
        try cmdSend(io, alloc, w, rest);
    } else if (eq(cmd, "get")) {
        try cmdGet(io, alloc, w, rest);
    } else if (eq(cmd, "relay")) {
        try cmdRelay(io, alloc, w, rest);
    } else {
        try w.print("{s}{s}{s} unknown command: {s}{s}{s}\n", .{
            ui.on(.red), ui.cross, ui.off(), ui.on(.bold), cmd, ui.off(),
        });
        if (nearestCommand(cmd)) |guess| {
            try w.print("  did you mean {s}gr {s}{s}?\n", .{ ui.on(.cyan), guess, ui.off() });
        }
        try w.print("{s}run `gr help` for the full list{s}\n", .{ ui.on(.dim), ui.off() });
    }
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn nowSeconds(io: std.Io) i64 {
    const ns = std.Io.Clock.now(.real, io).nanoseconds;
    return @intCast(@divTrunc(ns, 1_000_000_000));
}

fn messageFlag(rest: []const []const u8) []const u8 {
    return flagValue(rest, "-m", "--message");
}

fn flagValue(rest: []const []const u8, short: []const u8, long: []const u8) []const u8 {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if ((eq(rest[i], short) or eq(rest[i], long)) and i + 1 < rest.len) {
            return rest[i + 1];
        }
    }
    return "";
}

fn envOr(name: [:0]const u8, fallback: []const u8) []const u8 {
    if (fallback.len != 0) return fallback;
    if (std.c.getenv(name)) |v| {
        const s = std.mem.span(v);
        if (s.len != 0) return s;
    }
    return "";
}

// Provenance is OFF by default: only recorded when a prompt/agent is explicitly
// supplied (--prompt/--agent flag or GR_PROMPT/GR_AGENT env), and never when
// config `provenance` is a falsy kill-switch.
fn recordProvenance(io: std.Io, alloc: std.mem.Allocator, s: *Store, change: Oid, rest: []const []const u8) void {
    const prompt = envOr("GR_PROMPT", flagValue(rest, "--prompt", "--prompt"));
    const agent = envOr("GR_AGENT", flagValue(rest, "--agent", "--agent"));
    if (prompt.len == 0 and agent.len == 0) return;
    if (config.get(s, alloc, "provenance")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            if (eq(v, "off") or eq(v, "false") or eq(v, "0") or eq(v, "no")) return;
        }
    } else |_| {}
    provenance.record(s, change, agent, prompt, nowSeconds(io)) catch {};
}

fn openWork(io: std.Io) !std.Io.Dir {
    // cwd() is a special AT_FDCWD handle that cannot be iterated/seeked.
    return std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
}

fn openRepo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !?Store {
    return Store.discover(io, alloc, std.Io.Dir.cwd()) catch {
        try w.print("{s}{s}{s} not a guardrail repo\n", .{ ui.on(.red), ui.cross, ui.off() });
        try ui.hint(w, "run `gr init` here, or cd into a repo");
        return null;
    };
}

fn shortHex(o: Oid, buf: []u8) []const u8 {
    _ = o.toHex(buf);
    return buf[0..12];
}

fn cmdInit(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = Store.init(io, alloc, std.Io.Dir.cwd()) catch |e| switch (e) {
        Store.Error.RepoExists => {
            try w.writeAll("guardrail repo already exists here\n");
            return;
        },
        else => return e,
    };
    const db = config.defaultBranch(io, alloc) catch try alloc.dupe(u8, "main");
    defer alloc.free(db);
    s.setHeadBranch(db) catch {};
    s.deinit();
    try w.print("{s}{s}{s} initialized empty guardrail repo in {s}.gr{s} on {s}{s}{s}\n", .{
        ui.on(.green), ui.check, ui.off(), ui.on(.dim), ui.off(), ui.on(.cyan), db, ui.off(),
    });
}

fn cmdProvenance(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const records = try provenance.all(&s, alloc);
    defer provenance.freeAll(alloc, records);
    if (records.len == 0) {
        try w.writeAll("no provenance recorded (set GR_PROMPT/GR_AGENT or use `gr save --prompt`)\n");
        return;
    }
    var buf: [Oid.len * 2]u8 = undefined;
    for (records) |r| {
        try w.print("{s}", .{shortHex(r.change, &buf)});
        if (r.entry.agent.len != 0) try w.print("  [{s}]", .{r.entry.agent});
        try w.print("\n    {s}\n", .{r.entry.prompt});
    }
}

fn cmdBlame(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr blame <file>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    try blame.run(&s, alloc, w, rest[0]);
}

fn cmdResolve(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    if (hasFlag(rest, "--abort")) {
        merge.abort(&s, alloc, work) catch |e| switch (e) {
            error.NoMergeInProgress => {
                try w.writeAll("no merge in progress\n");
                return;
            },
            else => return e,
        };
        try w.writeAll("merge aborted. working tree restored\n");
        return;
    }
    if (rest.len < 1) {
        const rem = try merge.remainingConflicts(&s, alloc);
        defer {
            for (rem) |p| alloc.free(p);
            alloc.free(rem);
        }
        if (rem.len == 0) {
            try w.writeAll("no merge in progress\n");
            return;
        }
        try w.writeAll("usage: gr resolve <file>   (or --abort)\nunresolved:\n");
        for (rem) |p| try w.print("  ! {s}\n", .{p});
        return;
    }
    merge.markResolved(&s, alloc, work, rest[0]) catch |e| switch (e) {
        error.StillConflicted => {
            try w.print("{s} still has conflict markers. fix them first\n", .{rest[0]});
            return;
        },
        error.NoMergeInProgress => {
            try w.writeAll("no merge in progress\n");
            return;
        },
        else => return e,
    };
    const rem = try merge.remainingConflicts(&s, alloc);
    defer {
        for (rem) |p| alloc.free(p);
        alloc.free(rem);
    }
    if (rem.len == 0) {
        try w.print("resolved {s}. all conflicts cleared, now `gr save`\n", .{rest[0]});
    } else {
        try w.print("resolved {s}. {d} conflict(s) left\n", .{ rest[0], rem.len });
    }
}

fn cmdRevert(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const tip = s.readRef(branch) catch {
        try w.writeAll("nothing to revert. no changes yet\n");
        return;
    };
    const head_change = try s.readChange(tip);
    defer object.freeChange(alloc, head_change);

    // Target tree: an explicit change hex, else the parent of HEAD (undo last).
    var target_tree: Oid = undefined;
    var target_desc: []const u8 = "";
    if (rest.len >= 1 and !std.mem.startsWith(u8, rest[0], "-")) {
        const target_oid = Oid.fromHex(rest[0]) catch {
            try w.print("not a change id: {s}\n", .{rest[0]});
            return;
        };
        const tc = s.readChange(target_oid) catch {
            try w.print("no such change: {s}\n", .{rest[0]});
            return;
        };
        defer object.freeChange(alloc, tc);
        target_tree = tc.tree;
        target_desc = rest[0];
    } else if (head_change.parents.len != 0) {
        const parent = try s.readChange(head_change.parents[0]);
        defer object.freeChange(alloc, parent);
        target_tree = parent.tree;
    } else {
        try w.writeAll("nothing before the first change to revert to\n");
        return;
    }

    var work = try openWork(io);
    defer work.close(io);

    // Clean-checkout the target tree: drop currently-tracked files that the
    // target does not have, then materialize the target's files.
    const cur_tree = try s.readTree(head_change.tree);
    defer object.freeTree(alloc, cur_tree);
    const tgt = try s.readTree(target_tree);
    defer object.freeTree(alloc, tgt);
    var keep = std.StringHashMap(void).init(alloc);
    defer keep.deinit();
    for (tgt.entries) |e| try keep.put(e.path, {});
    for (cur_tree.entries) |e| {
        if (!keep.contains(e.path)) work.deleteFile(io, e.path) catch {};
    }
    try workspace.materialize(&s, target_tree, work);

    const author = try config.author(&s, alloc);
    defer alloc.free(author);
    var msg_buf: [96]u8 = undefined;
    const msg = if (target_desc.len != 0)
        std.fmt.bufPrint(&msg_buf, "revert to {s}", .{target_desc}) catch "revert"
    else
        "revert last change";
    const prev = s.readRef(branch) catch Oid.zero();
    const change = try workspace.snapshot(&s, work, author, msg, nowSeconds(io));
    oplog.record(&s, .{ .kind = .other, .branch = branch, .prev = prev, .new = change, .timestamp = nowSeconds(io) }) catch {};
    var buf: [Oid.len * 2]u8 = undefined;
    try w.print("reverted. new change {s}\n", .{shortHex(change, &buf)});
}

fn cmdAbsorb(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    var work = try openWork(io);
    defer work.close(io);
    try absorb.run(&s, alloc, work, w);
}

fn cmdGc(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const dry_run = hasFlag(rest, "--dry-run") or hasFlag(rest, "-n");
    try gc.run(&s, alloc, w, dry_run);
}

fn cmdLfs(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    // Share `.git/lfs/objects` with git-lfs when a git repo sits alongside.
    var git_dir: ?[:0]u8 = null;
    defer if (git_dir) |g| alloc.free(g);
    if (std.Io.Dir.cwd().access(io, ".git", .{})) |_| {
        git_dir = std.Io.Dir.cwd().realPathFileAlloc(io, ".git", alloc) catch null;
    } else |_| {}

    const remote_name = flagValue(rest, "--remote", "--remote");
    const url = resolveRemote(io, alloc, &s, if (remote_name.len != 0) remote_name else "origin") catch null;
    defer if (url) |u| alloc.free(u);

    try lfs.run(.{
        .store = &s,
        .work = work,
        .git_dir_abs = git_dir,
        .remote_url = url,
    }, w, rest);
}

fn cmdCompletions(w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr completions <fish|zsh|bash>\n");
        return;
    }
    completions.run(rest[0], w) catch |e| switch (e) {
        error.UnknownShell => {},
        else => return e,
    };
}

fn cmdWhy(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr why <file>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const path = rest[0];
    const maybe = attribution.lastForPath(&s, alloc, path) catch null;
    const e = maybe orelse {
        try w.print("{s}\n  \u{21b3} no attribution yet (save it, or it predates auto-provenance)\n", .{path});
        return;
    };
    defer attribution.freeEntry(alloc, e);
    switch (e.kind) {
        .human => try w.print("{s}\n  \u{21b3} human\n", .{path}),
        .agent => {
            try w.print("{s}\n  \u{21b3} {s} ({s})\n", .{ path, e.agent, @tagName(e.confidence) });
            if (e.session.len != 0) try w.print("  \u{21b3} session: {s}\n", .{e.session});
            if (e.prompt.len != 0) try w.print("  \u{21b3} prompt: {s}\n", .{e.prompt});
        },
    }
}

fn cmdConfig(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var global = false;
    var pos: [2][]const u8 = undefined;
    var np: usize = 0;
    for (rest) |a| {
        if (eq(a, "--global") or eq(a, "-g")) {
            global = true;
        } else if (np < 2) {
            pos[np] = a;
            np += 1;
        }
    }
    if (np == 0) {
        try w.writeAll("usage: gr config [--global] <key> [value]\n");
        return;
    }
    const key = pos[0];
    if (global) {
        if (np >= 2) {
            try config.globalSet(io, alloc, key, pos[1]);
            try w.print("set (global) {s} = {s}\n", .{ key, pos[1] });
        } else {
            const v = try config.globalGet(io, alloc, key);
            defer if (v) |x| alloc.free(x);
            if (v) |x| try w.print("{s}\n", .{x}) else try w.writeAll("(unset)\n");
        }
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    if (np >= 2) {
        try config.set(&s, key, pos[1]);
        try w.print("set {s} = {s}\n", .{ key, pos[1] });
    } else {
        const v = try config.get(&s, alloc, key);
        defer if (v) |x| alloc.free(x);
        if (v) |x| try w.print("{s}\n", .{x}) else try w.writeAll("(unset)\n");
    }
}

fn cmdSave(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    const change = try doSave(io, alloc, &s, messageFlag(rest));
    recordProvenance(io, alloc, &s, change, rest);
    const branch = try s.headBranch();
    defer alloc.free(branch);
    var buf: [Oid.len * 2]u8 = undefined;
    try w.print("{s}{s}{s} saved {s}{s}{s} on {s}{s}{s}\n", .{
        ui.on(.green),  ui.check,               ui.off(),
        ui.on(.yellow), shortHex(change, &buf), ui.off(),
        ui.on(.cyan),   branch,                 ui.off(),
    });
}

// Snapshot the working tree and log the op. Shared by save and auto-save.
fn doSave(io: std.Io, alloc: std.mem.Allocator, s: *Store, message: []const u8) !Oid {
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const prev: Oid = s.readRef(branch) catch Oid.zero();
    const author = try config.author(s, alloc);
    defer alloc.free(author);
    var work = try openWork(io);
    defer work.close(io);
    // Capture what changed BEFORE the snapshot (afterwards the tree is clean), so
    // passive attribution can match each file against agent session logs.
    const changed = workspace.status(s, work, alloc) catch null;
    defer if (changed) |c| {
        for (c) |e| alloc.free(e.path);
        alloc.free(c);
    };
    const change = try workspace.snapshot(s, work, author, message, nowSeconds(io));
    try oplog.record(s, .{ .kind = .snapshot, .branch = branch, .prev = prev, .new = change, .timestamp = nowSeconds(io) });
    attribution.autoAttribute(s, work, change, changed orelse &.{});
    maybeSyncGit(io, alloc, s);
    return change;
}

// Opt-in dual-write: only when the folder is ALREADY a git repo AND config
// `sync.git` is enabled, mirror this save into the colocated `.git`. Best-effort.
fn maybeSyncGit(io: std.Io, alloc: std.mem.Allocator, s: *Store) void {
    std.Io.Dir.cwd().access(io, ".git", .{}) catch return;
    const v = (config.get(s, alloc, "sync.git") catch return) orelse return;
    defer alloc.free(v);
    const on = eq(v, "true") or eq(v, "1") or eq(v, "yes") or eq(v, "on");
    if (!on) return;
    git.syncColocated(s, ".") catch {};
}

fn cmdDescribe(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const message = messageFlag(rest);
    if (message.len == 0) {
        try w.writeAll("usage: gr desc -m \"message\"\n");
        return;
    }
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const tip = s.readRef(branch) catch {
        try w.writeAll("nothing to describe. save something first\n");
        return;
    };
    const change = try s.readChange(tip);
    defer object.freeChange(alloc, change);
    // Amend in place: same tree/parents/change_id, new message.
    const amended = object.Change{
        .tree = change.tree,
        .parents = change.parents,
        .change_id = change.change_id,
        .timestamp = change.timestamp,
        .tz_offset_min = change.tz_offset_min,
        .author = change.author,
        .message = message,
    };
    const new_oid = try s.writeChange(amended);
    try s.updateRef(branch, new_oid);
    oplog.record(&s, .{ .kind = .other, .branch = branch, .prev = tip, .new = new_oid, .timestamp = nowSeconds(io) }) catch {};
    var buf: [Oid.len * 2]u8 = undefined;
    try w.print("described {s}\n", .{shortHex(new_oid, &buf)});
}

fn hasFlag(rest: []const []const u8, name: []const u8) bool {
    for (rest) |a| if (eq(a, name)) return true;
    return false;
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn cmdStatus(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    const json = hasFlag(rest, "--json");
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);
    const entries = try workspace.status(&s, work, alloc);
    defer {
        for (entries) |e| alloc.free(e.path);
        alloc.free(entries);
    }
    const conflicts = try merge.remainingConflicts(&s, alloc);
    defer {
        for (conflicts) |p| alloc.free(p);
        alloc.free(conflicts);
    }
    // Safety rule: a superposed path is never invisible. A file quietly holding
    // a second value is a real change to the mental model, so it is surfaced
    // here every single time rather than only when someone goes looking.
    const superposed = superpose.count(&s, alloc) catch 0;

    if (json) {
        try w.writeAll("{\"changes\":[");
        for (entries, 0..) |e, i| {
            if (i != 0) try w.writeByte(',');
            const kind = switch (e.kind) {
                .added => "added",
                .modified => "modified",
                .deleted => "deleted",
            };
            try w.print("{{\"kind\":\"{s}\",\"path\":", .{kind});
            try writeJsonString(w, e.path);
            try w.writeByte('}');
        }
        try w.writeAll("],\"conflicts\":[");
        for (conflicts, 0..) |p, i| {
            if (i != 0) try w.writeByte(',');
            try writeJsonString(w, p);
        }
        try w.print("],\"superposed\":{d}}}\n", .{superposed});
        return;
    }

    if (superposed != 0) try superpose.statusLine(w, superposed);

    if (conflicts.len != 0) {
        try w.print("{s}{s} merge in progress: {d} unresolved conflict(s){s}\n", .{
            ui.on(.red), ui.warn, conflicts.len, ui.off(),
        });
        for (conflicts) |p| try w.print("  {s}{s}{s} {s}\n", .{ ui.on(.red), ui.warn, ui.off(), p });
        try ui.hint(w, "fix the markers then `gr resolve <file>`, or `gr resolve --abort`");
    }
    if (entries.len == 0) {
        if (conflicts.len == 0 and superposed == 0) {
            try w.print("{s}{s}{s} clean, nothing to save\n", .{ ui.on(.green), ui.check, ui.off() });
        }
        return;
    }
    var added: usize = 0;
    var modified: usize = 0;
    var deleted: usize = 0;
    for (entries) |e| {
        const symbol, const color = switch (e.kind) {
            .added => .{ "+", ui.Color.green },
            .modified => .{ "~", ui.Color.yellow },
            .deleted => .{ "-", ui.Color.red },
        };
        switch (e.kind) {
            .added => added += 1,
            .modified => modified += 1,
            .deleted => deleted += 1,
        }
        try w.print("  {s}{s}{s}  {s}\n", .{ ui.on(color), symbol, ui.off(), e.path });
    }
    try w.print("\n{s}{d} added · {d} modified · {d} deleted{s}\n", .{
        ui.on(.dim), added, modified, deleted, ui.off(),
    });
}

fn cmdDiff(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    // Build a path -> blobOid map of the last saved tree.
    var head_map = std.StringHashMap(Oid).init(alloc);
    defer {
        var it = head_map.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        head_map.deinit();
    }
    const branch = try s.headBranch();
    defer alloc.free(branch);
    if (s.readRef(branch)) |tip| {
        const change = try s.readChange(tip);
        defer object.freeChange(alloc, change);
        const tree = try s.readTree(change.tree);
        defer object.freeTree(alloc, tree);
        for (tree.entries) |e| try head_map.put(try alloc.dupe(u8, e.path), e.blob);
    } else |_| {}

    var work = try openWork(io);
    defer work.close(io);
    const entries = try workspace.status(&s, work, alloc);
    defer {
        for (entries) |e| alloc.free(e.path);
        alloc.free(entries);
    }
    if (entries.len == 0) {
        try w.print("{s}{s}{s} no changes\n", .{ ui.on(.green), ui.check, ui.off() });
        return;
    }

    for (entries) |e| {
        const old_content: []u8 = if (head_map.get(e.path)) |blob|
            try s.readFileContent(blob)
        else
            try alloc.dupe(u8, "");
        defer alloc.free(old_content);
        const new_content: []u8 = if (e.kind == .deleted)
            try alloc.dupe(u8, "")
        else
            readWorkFile(io, work, e.path, alloc) catch try alloc.dupe(u8, "");
        defer alloc.free(new_content);

        if (isBinary(old_content) or isBinary(new_content)) {
            try w.print("Binary file {s} differs\n", .{e.path});
            continue;
        }
        const ops = try diff.diffLines(alloc, old_content, new_content);
        defer alloc.free(ops);
        try diff.writeUnified(w, e.path, ops);
    }
}

fn readWorkFile(io: std.Io, work: std.Io.Dir, path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    return work.readFileAlloc(io, path, alloc, .unlimited);
}

fn isBinary(data: []const u8) bool {
    const n = @min(data.len, 8000);
    return std.mem.indexOfScalar(u8, data[0..n], 0) != null;
}

fn cmdLog(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    const json = hasFlag(rest, "--json");
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const branch = try s.headBranch();
    defer alloc.free(branch);
    var cur: Oid = s.readRef(branch) catch {
        if (json) try w.writeAll("[]\n") else try w.writeAll("no changes yet\n");
        return;
    };
    if (json) try w.writeByte('[');
    var first_change = true;
    var first = true;
    while (!cur.isZero()) {
        const change = try s.readChange(cur);
        defer object.freeChange(alloc, change);
        var buf: [Oid.len * 2]u8 = undefined;
        var hex: [Oid.len * 2]u8 = undefined;
        _ = cur.toHex(&hex);
        if (json) {
            if (!first) try w.writeByte(',');
            first = false;
            try w.print("{{\"id\":\"{s}\",\"author\":", .{hex});
            try writeJsonString(w, change.author);
            try w.print(",\"timestamp\":{d},\"message\":", .{change.timestamp});
            try writeJsonString(w, change.message);
            if (try provenance.get(&s, alloc, cur)) |p| {
                defer provenance.freeEntry(alloc, p);
                try w.writeAll(",\"agent\":");
                try writeJsonString(w, p.agent);
                try w.writeAll(",\"prompt\":");
                try writeJsonString(w, p.prompt);
            }
            try w.writeByte('}');
        } else {
            const full = if (change.message.len == 0) "(no message)" else change.message;
            const nl = std.mem.indexOfScalar(u8, full, '\n');
            const msg = if (nl) |k| full[0..k] else full;
            if (!first_change) try w.writeByte('\n');
            first_change = false;
            try w.print("{s}{s}{s} {s}{s}{s}  {s}{s}{s}\n", .{
                ui.on(.yellow), ui.branch_mark,      ui.off(),
                ui.on(.yellow), shortHex(cur, &buf), ui.off(),
                ui.on(.bold),   msg,                 ui.off(),
            });
            try w.print("  {s}{s}{s}\n", .{ ui.on(.dim), change.author, ui.off() });
            if (try provenance.get(&s, alloc, cur)) |p| {
                defer provenance.freeEntry(alloc, p);
                if (p.agent.len != 0) {
                    try w.print("  {s}{s} agent: {s}{s}\n", .{ ui.on(.magenta), ui.arrow, p.agent, ui.off() });
                }
                if (p.prompt.len != 0) {
                    try w.print("  {s}{s} prompt: {s}{s}\n", .{ ui.on(.dim), ui.arrow, p.prompt, ui.off() });
                }
            }
        }
        if (change.parents.len == 0) break;
        cur = change.parents[0];
    }
    if (json) try w.writeAll("]\n");
}

fn cmdBranch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const cur = try s.headBranch();
    defer alloc.free(cur);
    const names = try branches.list(&s, alloc);
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    if (names.len == 0) {
        try w.print("{s}{s} {s}{s} {s}(unborn){s}\n", .{
            ui.on(.cyan), ui.branch_mark, cur, ui.off(), ui.on(.dim), ui.off(),
        });
        return;
    }
    for (names) |n| {
        if (eq(n, cur)) {
            try w.print("{s}{s} {s}{s}\n", .{ ui.on(.cyan), ui.branch_mark, n, ui.off() });
        } else {
            try w.print("{s}{s}{s} {s}\n", .{ ui.on(.dim), ui.bullet, ui.off(), n });
        }
    }
}

fn cmdNew(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr new <branch-name>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const name = rest[0];

    // `gr new <name> @<moment>` turns a fork into a branch once you decide it
    // was worth keeping.
    if (rest.len >= 2 and revspec.looksLikeRevspec(rest[1])) {
        const set = checks.settings(&s, alloc);
        defer set.deinit(alloc);
        var ix = try verdict.Index.load(&s, alloc);
        defer ix.deinit();
        const resolved = resolveSpec(io, alloc, &s, rest[1], &ix, set) catch {
            try w.print("could not resolve {s}\n", .{rest[1]});
            return;
        };
        defer resolved.deinit(alloc);
        if (resolved.target == .live) {
            try w.writeAll("@ is the live tree; `gr new <name>` already branches from here\n");
            return;
        }
        const author = try config.author(&s, alloc);
        defer alloc.free(author);
        _ = fork.newBranchAt(&s, name, resolved.target.at, author, nowSeconds(io)) catch |e| switch (e) {
            fork.Error.BranchExists => {
                try w.print("branch {s} already exists\n", .{name});
                return;
            },
            else => return e,
        };
        var work2 = try openWork(io);
        defer work2.close(io);
        try branches.switchTo(&s, work2, name);
        try w.print("on new branch {s}, at that moment\n", .{name});
        return;
    }

    branches.create(&s, name) catch |e| switch (e) {
        branches.Error.BranchExists => {
            try w.print("branch {s} already exists\n", .{name});
            return;
        },
        else => return e,
    };
    var work = try openWork(io);
    defer work.close(io);
    try branches.switchTo(&s, work, name);
    try w.print("on new branch {s}\n", .{name});
}

fn cmdSwitch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr switch <branch-name>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);

    // Never lose work: auto-save the current tree before moving.
    var work = try openWork(io);
    defer work.close(io);
    const dirty = try workspace.status(&s, work, alloc);
    const had_changes = dirty.len > 0;
    for (dirty) |e| alloc.free(e.path);
    alloc.free(dirty);
    if (had_changes) {
        _ = try doSave(io, alloc, &s, "wip (auto-saved before switch)");
        try w.writeAll("auto-saved your work first\n");
    }

    branches.switchTo(&s, work, rest[0]) catch |e| {
        try w.print("could not switch to {s}: {s}\n", .{ rest[0], @errorName(e) });
        return;
    };
    try w.print("switched to {s}\n", .{rest[0]});
}

fn cmdWork(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr work <new-dir>\n");
        return;
    }
    const src_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(src_abs);
    const dst = rest[0];
    // dst must not already exist (clonefile requirement).
    if (std.Io.Dir.cwd().access(io, dst, .{})) |_| {
        try w.print("{s} already exists\n", .{dst});
        return;
    } else |_| {}
    const dst_abs = if (std.fs.path.isAbsolute(dst))
        try alloc.dupe(u8, dst)
    else
        try std.fs.path.join(alloc, &.{ src_abs, dst });
    defer alloc.free(dst_abs);

    // `--at <ref>` is the whole point of forking mid-run: an agent is forty
    // minutes in, you want the approach it considered at minute twelve, and no
    // commit exists there.
    const at = flagValue(rest, "--at", "--at");
    if (at.len != 0) {
        var s = (try openRepo(io, alloc, w)) orelse return;
        defer s.deinit();
        var work = try openWork(io);
        defer work.close(io);

        const set = checks.settings(&s, alloc);
        defer set.deinit(alloc);
        var ix = try verdict.Index.load(&s, alloc);
        defer ix.deinit();

        const resolved = resolveSpec(io, alloc, &s, at, &ix, set) catch {
            try w.print("could not resolve {s}\n", .{at});
            return;
        };
        defer resolved.deinit(alloc);
        if (resolved.target == .live) {
            try w.writeAll("@ is the live tree; `gr work <dir>` already gives you that\n");
            return;
        }

        fork.workAt(&s, work, dst_abs, resolved.target.at) catch |e| {
            try w.print("could not create worktree: {s}\n", .{@errorName(e)});
            return;
        };
        var id_hex: [16]u8 = undefined;
        _ = resolved.target.at.shortId(&id_hex);
        try w.print("worktree at {s}, holding {s}@{s}{s}", .{ dst, ui.on(.cyan), id_hex[0..12], ui.off() });
        if (resolved.verdict) |v| {
            try w.print(" {s}({s} {s}){s}", .{ ui.on(.dim), v.result.label(), v.tier.label(), ui.off() });
        }
        try w.writeAll("\n");
        return;
    }

    branches.work(io, src_abs, dst_abs) catch |e| {
        try w.print("could not create worktree: {s}\n", .{@errorName(e)});
        return;
    };
    try w.print("instant copy-on-write worktree at {s}\n", .{dst});
}

fn cmdRestore(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr restore <file>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    var work = try openWork(io);
    defer work.close(io);
    workspace.restoreFile(&s, work, rest[0]) catch |e| switch (e) {
        error.PathNotInHead => {
            try w.print("{s} is not in the last save\n", .{rest[0]});
            return;
        },
        else => return e,
    };
    try w.print("restored {s}\n", .{rest[0]});
}

fn cmdMerge(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr merge <branch>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    const into = try s.headBranch();
    defer alloc.free(into);
    const author = try config.author(&s, alloc);
    defer alloc.free(author);

    const before = s.readRef(into) catch Oid.zero();
    const result = merge.merge(&s, alloc, into, rest[0], author, nowSeconds(io)) catch |e| {
        try w.print("merge failed: {s}\n", .{@errorName(e)});
        return;
    };
    defer merge.freeMergeResult(alloc, result);
    const after = s.readRef(into) catch Oid.zero();
    oplog.record(&s, .{ .kind = .other, .branch = into, .prev = before, .new = after, .timestamp = nowSeconds(io) }) catch {};

    // Materialize the merged tree into the working directory.
    var work = try openWork(io);
    defer work.close(io);
    workspace.materialize(&s, result.tree, work) catch {};

    if (result.conflicts.len == 0) {
        try w.print("merged {s} into {s}, clean\n", .{ rest[0], into });
    } else {
        merge.saveState(&s, rest[0], before, result.conflicts) catch {};
        try w.print("merged {s} into {s} with {d} conflict(s):\n", .{ rest[0], into, result.conflicts.len });
        for (result.conflicts) |p| try w.print("  ! {s}\n", .{p});
        try w.writeAll("fix the markers, then `gr resolve <file>` each, or `gr resolve --abort`\n");
    }
}

fn cmdServe(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len >= 2 and eq(rest[0], "--link")) {
        var dir = std.Io.Dir.cwd().openDir(io, rest[1], .{}) catch {
            try w.print("no such directory: {s}\n", .{rest[1]});
            return;
        };
        defer dir.close(io);
        const link_port: u16 = if (rest.len >= 3)
            std.fmt.parseInt(u16, rest[2], 10) catch 7788
        else
            7788;
        try w.print("serving {s}{s}{s} on port {d} (ctrl-c to stop)\n", .{
            ui.on(.cyan), rest[1], ui.off(), link_port,
        });
        try ui.hint(w, "this process cannot decrypt what it is serving.");
        try w.flush();
        return share.serveDir(io, alloc, dir, link_port);
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var port: u16 = 7777;
    if (rest.len >= 1) port = std.fmt.parseInt(u16, rest[0], 10) catch 7777;
    try w.print("serving guardrail objects on port {d} (ctrl-c to stop)\n", .{port});
    try w.flush();
    try net.serve(&s, port);
}

fn cmdFetch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr fetch <src-repo-dir> [path-prefix]\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const prefix = if (rest.len >= 2) rest[1] else "";
    const change = net.fetchSparse(&s, rest[0], branch, prefix) catch |e| {
        try w.print("fetch failed: {s}\n", .{@errorName(e)});
        return;
    };
    var buf: [Oid.len * 2]u8 = undefined;
    if (prefix.len == 0) {
        try w.print("fetched {s} ({s})\n", .{ shortHex(change, &buf), branch });
    } else {
        try w.print("sparse-fetched {s}: only paths under '{s}' ({s})\n", .{ shortHex(change, &buf), prefix, branch });
    }
}

fn cmdWatch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    const rules = warrant.pathRules(&s, alloc);
    defer rules.deinit(alloc);

    var mset = moment.settings(&s, alloc);
    mset.enabled = true;

    try w.print("{s}watching{s} ", .{ ui.on(.bold), ui.off() });
    if (set.enabled) {
        try w.print("and grading, every {d}ms\n", .{mset.interval_ms});
    } else {
        try w.print("every {d}ms; no check configured, so nothing is ever run\n", .{mset.interval_ms});
        try ui.hint(w, "set one with `gr config checks.full \"zig build test\"`");
    }
    try ui.hint(w, "ctrl-c to stop; `gr grade --on` does this with no terminal and no daemon");
    try w.flush();

    const ctx = gradeContext(alloc, &s, work, set, rules);
    try watch.live(&s, work, ctx, mset, .{});
}

// --- verified history ---

fn momentSettings(s: *Store, alloc: std.mem.Allocator) moment.Settings {
    var mset = moment.settings(s, alloc);
    // The CLI captures on demand rather than on a poll, so an unconfigured repo
    // still gets a moment when it explicitly asks for one.
    mset.enabled = true;
    return mset;
}

fn gradeContext(
    alloc: std.mem.Allocator,
    s: *Store,
    work: std.Io.Dir,
    set: checks.Settings,
    rules: warrant.PathRules,
) grade.Context {
    return .{
        .store = s,
        .work_dir = work,
        .alloc = alloc,
        .set = set,
        .rules = rules,
    };
}

fn nowMillis(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, 1_000_000));
}

/// Resolve a revspec with verdicts wired in, so `@green` can answer.
fn resolveSpec(
    io: std.Io,
    alloc: std.mem.Allocator,
    s: *Store,
    spec: []const u8,
    ix: *const verdict.Index,
    set: checks.Settings,
) !revspec.Resolved {
    return revspec.resolve(.{
        .store = s,
        .alloc = alloc,
        .verdicts = ix,
        .command_fast = verdict.commandHash(set.command(.fast)),
        .command_full = verdict.commandHash(set.command(.full)),
        .now_ms = nowMillis(io),
    }, spec);
}

fn cmdMoments(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    var limit: usize = 20;
    if (flagValue(rest, "-n", "--number").len != 0) {
        limit = std.fmt.parseInt(usize, flagValue(rest, "-n", "--number"), 10) catch 20;
    }

    const all = try moment.readAll(&s, alloc);
    defer moment.freeMoments(alloc, all);
    if (all.len == 0) {
        try w.writeAll("no moments captured yet\n");
        try ui.hint(w, "run `gr grade --once`, or `gr watch`, to start capturing");
        return;
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    var ix = try verdict.Index.load(&s, alloc);
    defer ix.deinit();

    const start = if (all.len > limit) all.len - limit else 0;
    for (all[start..]) |m| {
        var id_hex: [16]u8 = undefined;
        _ = m.shortId(&id_hex);
        const v = ix.best(
            m.full_tree,
            verdict.commandHash(set.command(.fast)),
            verdict.commandHash(set.command(.full)),
        );
        try w.print("{s}@{s}{s}  ", .{ ui.on(.cyan), id_hex[0..12], ui.off() });
        if (v) |got| {
            const colour: ui.Color = if (got.result == .green) .green else .red;
            try w.print("{s}{s}{s} {s}{s}{s}", .{
                ui.on(colour), got.result.label(), ui.off(),
                ui.on(.dim),   got.tier.label(),   ui.off(),
            });
            // A green is never shown bare: the warrant travels with the claim.
            if (got.result == .green) {
                try w.print("  {s}{s}  relevance {d}/{d}  {s}{s}", .{
                    ui.on(.dim),
                    got.independence.label(),
                    got.relevance_hit,
                    got.relevance_total,
                    got.discrimination.label(),
                    ui.off(),
                });
            }
        } else {
            try w.print("{s}ungraded{s}", .{ ui.on(.dim), ui.off() });
        }
        try w.print("  {s}{s}{s}\n", .{ ui.on(.dim), m.cause.label(), ui.off() });
    }
}

fn rewindTo(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    spec: []const u8,
    dry_run: bool,
    paths: ?[]const []const u8,
) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    var ix = try verdict.Index.load(&s, alloc);
    defer ix.deinit();

    const resolved = resolveSpec(io, alloc, &s, spec, &ix, set) catch |e| {
        switch (e) {
            revspec.Error.NoSuchMoment => {
                try w.print("{s}{s}{s} nothing matches {s}{s}{s}\n", .{
                    ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
                });
                if (std.mem.indexOf(u8, spec, "green") != null) {
                    try ui.hint(w, "no state has been graded green yet; set `checks.full` and run `gr grade`");
                }
            },
            revspec.Error.UnknownSelector => try w.print("not a revspec: {s}\n", .{spec}),
            revspec.Error.AmbiguousMoment => try w.print("{s} matches more than one moment\n", .{spec}),
            else => return e,
        }
        return;
    };
    defer resolved.deinit(alloc);

    const target_moment = switch (resolved.target) {
        .live => {
            try w.writeAll("already there\n");
            return;
        },
        .at => |m| m,
    };

    const entries = try moment.entriesOf(&s, target_moment);
    defer workspace.freeTreeEntries(alloc, entries);

    var id_hex: [16]u8 = undefined;
    _ = target_moment.shortId(&id_hex);

    if (dry_run) {
        const pv = try rewind.preview(&s, alloc, work, entries, paths);
        defer pv.deinit(alloc);
        if (pv.changes.len == 0) {
            try w.writeAll("nothing would change\n");
            return;
        }
        try w.print("would rewind to {s}@{s}{s}\n", .{ ui.on(.cyan), id_hex[0..12], ui.off() });
        for (pv.changes) |c| {
            try w.print("  {s}{s}{s} {s}\n", .{ ui.on(.dim), c.label(), ui.off(), c.path });
        }
        return;
    }

    const applied = try rewind.apply(&s, work, entries, momentSettings(&s, alloc), paths);

    try w.print("{s}{s}{s} rewound to {s}@{s}{s}", .{
        ui.on(.green), ui.check, ui.off(), ui.on(.cyan), id_hex[0..12], ui.off(),
    });
    if (resolved.verdict) |v| {
        try w.print(" {s}({s} {s}){s}", .{ ui.on(.dim), v.result.label(), v.tier.label(), ui.off() });
    }
    try w.print(", {d} file{s} changed\n", .{ applied.changed, if (applied.changed == 1) "" else "s" });
    try ui.hint(w, "`gr undo` puts it back; the state you left is still addressable");
}

fn cmdRewind(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var spec: []const u8 = "";
    var dry_run = false;
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);

    var after_sep = false;
    for (rest) |a| {
        if (eq(a, "--")) {
            after_sep = true;
        } else if (after_sep) {
            try paths.append(alloc, a);
        } else if (eq(a, "--dry-run") or eq(a, "-n")) {
            dry_run = true;
        } else if (spec.len == 0) {
            spec = a;
        }
    }

    if (spec.len == 0) {
        try w.writeAll("usage: gr rewind <ref> [--dry-run] [-- <paths>]\n");
        try ui.hint(w, "try `gr rewind @green`, `gr rewind @2h`, or `gr back`");
        return;
    }

    try rewindTo(io, alloc, w, spec, dry_run, if (paths.items.len == 0) null else paths.items);
}

fn cmdBack(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var n: usize = 1;
    for (rest) |a| {
        if (a.len != 0 and a[0] != '-') {
            n = std.fmt.parseInt(usize, a, 10) catch 1;
            break;
        }
    }
    const spec = try std.fmt.allocPrint(alloc, "@~{d}", .{n});
    defer alloc.free(spec);
    try rewindTo(io, alloc, w, spec, false, null);
}

fn cmdGreen(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    try rewindTo(io, alloc, w, "@green", false, null);
}

fn cmdGrade(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    const repo_abs = try work.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(repo_abs);

    for (rest) |a| {
        if (eq(a, "--install") or eq(a, "--on")) {
            const exe = update.selfExePathAlloc(alloc) catch |e| {
                try w.print("could not locate the gr binary: {s}\n", .{@errorName(e)});
                return;
            };
            defer alloc.free(exe);

            // Apple documents WatchPaths but not whether it fires for a change
            // inside a watched directory, and the whole design rests on that.
            // Measure it here rather than promise it.
            try w.writeAll("checking that this machine can watch a directory... ");
            try w.flush();
            if (!sched.selfTest(io, alloc, 8000)) {
                try w.print("{s}no{s}\n", .{ ui.on(.yellow), ui.off() });
                try w.writeAll("automatic grading is not available here\n");
                try ui.hint(w, "run `gr watch` in a terminal instead; it does the same work");
                return;
            }
            try w.print("{s}yes{s}\n", .{ ui.on(.green), ui.off() });

            sched.install(io, alloc, exe, repo_abs, .{}) catch |e| {
                try w.print("{s}{s}{s} could not install the agent: {s}\n", .{
                    ui.on(.red), ui.cross, ui.off(), @errorName(e),
                });
                try ui.hint(w, "`gr watch` does the same work in the foreground");
                return;
            };
            try w.print("{s}{s}{s} automatic grading is on for this repo\n", .{
                ui.on(.green), ui.check, ui.off(),
            });
            try ui.hint(w, "edits are captured and graded with no gr command and no resident process");
            return;
        }
        if (eq(a, "--uninstall") or eq(a, "--off")) {
            sched.uninstall(io, alloc, repo_abs) catch {};
            try w.writeAll("automatic grading off; `gr grade` still works by hand\n");
            return;
        }
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    if (!set.enabled) {
        try w.writeAll("no check configured, so nothing to grade\n");
        try ui.hint(w, "set one with `gr config checks.full \"zig build test\"`");
        return;
    }

    const rules = warrant.pathRules(&s, alloc);
    defer rules.deinit(alloc);

    const ctx = gradeContext(alloc, &s, work, set, rules);
    const r = try sched.tick(&s, work, ctx, momentSettings(&s, alloc), .{});

    if (r.skipped) |why| {
        try w.print("{s}skipped: {s}{s}\n", .{ ui.on(.dim), why, ui.off() });
        return;
    }
    if (r.captured) try w.writeAll("captured a moment\n");
    if (r.cut) try w.print("{s}{s}{s} cut a verified change at the green boundary\n", .{
        ui.on(.green), ui.check, ui.off(),
    });
    if (r.graded == 0) {
        try w.writeAll("nothing needed running\n");
    } else {
        try w.print("ran {d} check{s}\n", .{ r.graded, if (r.graded == 1) "" else "s" });
    }
    if (r.boundary) |b| {
        try w.print("{s}broke between moment {d} and {d}{s}\n", .{
            ui.on(.yellow), b.last_green, b.first_red, ui.off(),
        });
        try ui.hint(w, "`gr green` rewinds to the last state that worked");
    }
}

fn cmdDoctor(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    try w.print("{s}guardrail doctor{s}\n\n", .{ ui.on(.bold), ui.off() });

    const mset = moment.settings(&s, alloc);
    const count = moment.count(&s, alloc) catch 0;
    // `moments.enabled` governs only the polling loop. Commands capture on
    // demand regardless, so reporting a bare "off" beside a moment count would
    // read as a contradiction.
    try w.print("  capture      {s} ({d} moment{s}, keyframe every {d})\n", .{
        if (mset.enabled) "continuous" else "on demand",
        count,
        if (count == 1) "" else "s",
        mset.keyframe_interval,
    });
    if (mset.enabled) {
        try w.print("               polling every {d}ms\n", .{mset.interval_ms});
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    if (!set.enabled) {
        try w.writeAll("  checks       none configured, so nothing is ever run\n");
    } else {
        if (set.has(.fast)) try w.print("  checks.fast  {s}\n", .{set.fast});
        if (set.has(.full)) try w.print("  checks.full  {s}\n", .{set.full});
        try w.print("  budget       {d}% of one core, nice {d}, battery floor {d}%\n", .{
            set.budget_percent, set.nice, set.battery_floor,
        });
    }

    // Read-set tracing, probed here rather than assumed, since the honest
    // answer differs per filesystem.
    const work_abs = try work.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(work_abs);
    const av = tracer.detect(io, alloc, work, work_abs);
    const tracer_colour: ui.Color = if (av.mode.isExact()) .green else .yellow;
    try w.print("  read-sets    {s}{s}{s} ({s})\n", .{
        ui.on(tracer_colour), av.mode.label(), ui.off(), av.reason,
    });
    if (!av.mode.isExact()) {
        try ui.hint(w, "every tracked file is assumed read, which costs extra runs but is never wrong");
    }

    const status = sched.agentStatus(io, alloc, work_abs) catch .unsupported;
    try w.print("  background   {s}\n", .{switch (status) {
        .installed => "on, via launchd, with no resident process",
        .not_installed => "off (`gr grade --install`, or run `gr watch`)",
        .unsupported => "not available here; use `gr watch` in a terminal",
    }});

    const verdicts = try verdict.readAll(&s, alloc);
    defer alloc.free(verdicts);
    var greens: usize = 0;
    var hollow: usize = 0;
    for (verdicts) |v| {
        if (v.isGreen()) greens += 1;
        if (v.isHollow()) hollow += 1;
    }
    try w.print("  verdicts     {d} recorded, {d} green", .{ verdicts.len, greens });
    if (hollow != 0) {
        try w.print(", {s}{d} green but hollow{s}", .{ ui.on(.yellow), hollow, ui.off() });
    }
    try w.writeAll("\n");
}

fn cmdRecap(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    var as_json = false;
    var spec: []const u8 = "";
    for (rest) |a| {
        if (eq(a, "--json")) as_json = true else if (spec.len == 0 and a.len != 0 and a[0] != '-') spec = a;
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    var ix = try verdict.Index.load(&s, alloc);
    defer ix.deinit();

    const all = try moment.readAll(&s, alloc);
    defer moment.freeMoments(alloc, all);
    if (all.len == 0) {
        try w.writeAll("nothing captured yet, so nothing to recap\n");
        return;
    }

    // A range narrows the window; without one the recap covers all of history.
    var from: usize = 0;
    if (spec.len != 0) {
        const range = revspec.resolveRange(.{
            .store = &s,
            .alloc = alloc,
            .verdicts = &ix,
            .command_fast = verdict.commandHash(set.command(.fast)),
            .command_full = verdict.commandHash(set.command(.full)),
            .now_ms = nowMillis(io),
        }, spec) catch {
            try w.print("could not resolve {s}\n", .{spec});
            return;
        };
        defer range.deinit(alloc);
        if (range.from) |f| {
            if (f.target == .at) {
                for (all, 0..) |m, i| {
                    if (std.mem.eql(u8, &m.id, &f.target.at.id)) {
                        from = i;
                        break;
                    }
                }
            }
        }
    }

    const report = try recap.build(
        &s,
        alloc,
        all[from..],
        &ix,
        verdict.commandHash(set.command(.fast)),
        verdict.commandHash(set.command(.full)),
    );
    defer report.deinit(alloc);

    if (as_json) try recap.renderJson(w, report) else try recap.render(w, report);
}

fn cmdSuper(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    const items = try superpose.list(&s, alloc);
    defer superpose.freeAll(alloc, items);

    if (items.len == 0) {
        try w.writeAll("nothing is superposed\n");
        return;
    }

    for (items) |sp| {
        if (rest.len != 0 and !eq(rest[0], sp.path)) continue;
        try w.print("{s}{s}{s}\n", .{ ui.on(.bold), sp.path, ui.off() });
        try superpose.renderStatus(w, &.{sp}, null);
    }
    try ui.hint(w, "`gr collapse <path> A` keeps one; the other is never deleted");
}

fn cmdCollapse(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr collapse <path> <A|B|--greenest|--edit>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    var work = try openWork(io);
    defer work.close(io);

    const path = rest[0];
    var choice: superpose.Choice = .{ .label = 'A' };
    if (rest.len >= 2) {
        if (eq(rest[1], "--greenest")) {
            choice = .greenest;
        } else if (eq(rest[1], "--edit")) {
            // Neither candidate: whatever is in the worktree right now wins.
            const data = work.readFileAlloc(io, path, alloc, .unlimited) catch {
                try w.print("could not read {s} to use as the resolution\n", .{path});
                return;
            };
            defer alloc.free(data);
            choice = .{ .edit = data };
        } else if (rest[1].len == 1) {
            choice = .{ .label = std.ascii.toUpper(rest[1][0]) };
        }
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    var ix = try verdict.Index.load(&s, alloc);
    defer ix.deinit();
    const ev = superpose.Evidence{
        .index = &ix,
        .command_fast = verdict.commandHash(set.command(.fast)),
        .command_full = verdict.commandHash(set.command(.full)),
    };

    const outcome = superpose.collapse(&s, work, alloc, path, choice, ev) catch |e| switch (e) {
        superpose.Error.NotSuperposed => {
            try w.print("{s} is not superposed\n", .{path});
            return;
        },
        superpose.Error.NoSuchCandidate => {
            try w.print("no such candidate for {s}\n", .{path});
            return;
        },
        else => return e,
    };

    switch (outcome) {
        .chosen => try w.print("{s}{s}{s} collapsed {s}\n", .{ ui.on(.green), ui.check, ui.off(), path }),
        .edited => try w.print("{s}{s}{s} collapsed {s} to your own edit\n", .{ ui.on(.green), ui.check, ui.off(), path }),
        .fell_back_to_primary => {
            try w.print("{s}{s}{s} no verdict to choose by, so kept the primary for {s}\n", .{
                ui.on(.yellow), ui.warn, ui.off(), path,
            });
        },
    }
    try ui.hint(w, "`gr undo` reverses it; the losing version is still in the store");
}

fn cmdNote(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 2) {
        try w.writeAll("usage: gr note <file>:<line> <text>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    const target = live.parseNoteTarget(rest[0]) catch {
        try w.print("expected <file>:<line>, got {s}\n", .{rest[0]});
        return;
    };

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(alloc);
    for (rest[1..], 0..) |part, i| {
        if (i != 0) try text.append(alloc, ' ');
        try text.appendSlice(alloc, part);
    }

    try live.recordNote(&s, .{
        .path = target.path,
        .line = target.line,
        .text = text.items,
    }, nowMillis(io));
    try w.print("{s}{s}{s} noted {s}:{d}\n", .{ ui.on(.green), ui.check, ui.off(), target.path, target.line });
}

fn cmdNotes(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const list = try live.notes(&s, alloc);
    defer live.freeNotes(alloc, list);
    if (list.len == 0) {
        try w.writeAll("no notes\n");
        return;
    }
    for (list) |n| {
        try w.print("{s}{s}:{d}{s}  {s}\n", .{ ui.on(.cyan), n.path, n.line, ui.off(), n.text });
    }
}

/// Capture the working tree before a command that will change it.
///
/// Every mutating command is a defensive capture point: whatever the command
/// then does, the state it was asked to leave stays addressable as a moment, so
/// `gr back` and `@~1` reach it even if the command itself has no undo of its
/// own. Failure is deliberately silent — a capture that cannot happen must
/// never stop the command the user actually asked for.
fn captureBefore(io: std.Io, alloc: std.mem.Allocator, s: *Store) void {
    var work = openWork(io) catch return;
    defer work.close(io);
    const r = moment.capture(s, work, .command, momentSettings(s, alloc)) catch return;
    if (r == .captured) alloc.free(r.captured.branch);
}

fn cmdUndo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var undo_work = openWork(io) catch null;
    defer if (undo_work) |*d| d.close(io);
    oplog.undo(&s, undo_work) catch |e| switch (e) {
        error.NothingToUndo => {
            try w.writeAll("nothing to undo\n");
            return;
        },
        else => return e,
    };
    try w.writeAll("undone\n");
}

fn cmdRedo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var redo_work = openWork(io) catch null;
    defer if (redo_work) |*d| d.close(io);
    oplog.redo(&s, redo_work) catch |e| switch (e) {
        error.NothingToRedo => {
            try w.writeAll("nothing to redo\n");
            return;
        },
        else => return e,
    };
    try w.writeAll("redone\n");
}

const GitOp = enum { import, export_, sync };

fn cmdGit(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8, op: GitOp) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: gr <import|export|sync> <path>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const target = rest[0];

    switch (op) {
        .import => {
            git.importAll(&s, target) catch {
                try w.writeAll("git import failed (is that a git repo with commits?)\n");
                return;
            };
            // importAll sets HEAD to the git repo's branch, so read it afterward.
            const branch = try s.headBranch();
            defer alloc.free(branch);
            const tip: Oid = s.readRef(branch) catch Oid.zero();
            oplog.record(&s, .{ .kind = .import, .branch = branch, .prev = Oid.zero(), .new = tip, .timestamp = nowSeconds(io) }) catch {};
            var buf: [Oid.len * 2]u8 = undefined;
            try w.print("imported git repo (full history, all branches + tags); on {s} at {s}\n", .{ branch, shortHex(tip, &buf) });
        },
        .export_ => {
            // Refuse while anything is superposed. A superposed path holds more
            // than one real version, and exporting would silently pick one and
            // present it to git as the answer.
            const n = superpose.count(&s, alloc) catch 0;
            if (n != 0) {
                try w.print("{s}{s}{s} {d} path{s} still superposed\n", .{
                    ui.on(.red), ui.cross, ui.off(), n, if (n == 1) "" else "s",
                });
                try ui.hint(w, "`gr super` lists them; `gr collapse <path> <A|B>` picks one");
                return;
            }
            git.exportAll(&s, target) catch {
                try w.writeAll("git export failed\n");
                return;
            };
            try w.print("exported guardrail (full history, all branches + tags) to git at {s}\n", .{target});
        },
        .sync => {
            git.syncColocated(&s, target) catch {
                try w.writeAll("sync failed\n");
                return;
            };
            try w.print("synced guardrail HEAD into .git at {s}\n", .{target});
        },
    }
}

fn isUrl(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "://") != null or
        std.mem.startsWith(u8, s, "git@") or
        std.mem.startsWith(u8, s, "ssh://");
}

// Resolve a remote NAME (e.g. "origin") to a URL: a literal URL passes through;
// otherwise look it up in the colocated .git/config, then gr's own config
// (`remote.<name>.url`). Caller frees. null if it can't be resolved.
fn resolveRemote(io: std.Io, alloc: std.mem.Allocator, s: *Store, name: []const u8) !?[]u8 {
    if (isUrl(name)) return try alloc.dupe(u8, name);
    if (try gitConfigRemoteUrl(io, alloc, name)) |u| return u;
    var kbuf: [128]u8 = undefined;
    const key = std.fmt.bufPrint(&kbuf, "remote.{s}.url", .{name}) catch return null;
    return config.get(s, alloc, key) catch null;
}

// Parse `url = ...` from the `[remote "<name>"]` section of .git/config.
fn gitConfigRemoteUrl(io: std.Io, alloc: std.mem.Allocator, name: []const u8) !?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, ".git/config", alloc, .unlimited) catch return null;
    defer alloc.free(data);
    var hdr_buf: [128]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "[remote \"{s}\"]", .{name}) catch return null;
    var in_section = false;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '[') {
            in_section = std.mem.eql(u8, line, hdr);
            continue;
        }
        if (!in_section) continue;
        if (std.mem.startsWith(u8, line, "url")) {
            if (std.mem.indexOfScalar(u8, line, '=')) |eqi| {
                const v = std.mem.trim(u8, line[eqi + 1 ..], " \t\r");
                if (v.len != 0) return try alloc.dupe(u8, v);
            }
        }
    }
    return null;
}

// The branch a colocated .git is on (from .git/HEAD), so `gr push` targets the
// same branch git uses (e.g. `master`). Caller frees. null if not colocated.
fn colocatedGitBranch(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    const data = std.Io.Dir.cwd().readFileAlloc(io, ".git/HEAD", alloc, .unlimited) catch return null;
    defer alloc.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    const prefix = "ref: refs/heads/";
    if (!std.mem.startsWith(u8, trimmed, prefix)) return null;
    return alloc.dupe(u8, trimmed[prefix.len..]) catch null;
}

// Branch to push/pull: explicit arg > colocated git branch > gr's current branch.
fn targetBranch(io: std.Io, alloc: std.mem.Allocator, s: *Store, explicit: ?[]const u8) ![]u8 {
    if (explicit) |b| return alloc.dupe(u8, b);
    if (colocatedGitBranch(io, alloc)) |b| return b;
    return s.headBranch();
}

fn cmdPush(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    // Positional args are remote then branch; -f/--force is a flag anywhere.
    var force = false;
    var pos: [2][]const u8 = undefined;
    var np: usize = 0;
    for (rest) |a| {
        if (eq(a, "-f") or eq(a, "--force")) {
            force = true;
        } else if (np < 2) {
            pos[np] = a;
            np += 1;
        }
    }
    const remote_name = if (np >= 1) pos[0] else "origin";
    const url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}'. pass a URL, or set it in git or `gr config remote.{s}.url`\n", .{ remote_name, remote_name });
        return;
    };
    defer alloc.free(url);
    const branch = try targetBranch(io, alloc, &s, if (np >= 2) pos[1] else null);
    defer alloc.free(branch);

    // If a git repo is colocated here, push IT directly (dual-write commits live
    // there) so local .git and the remote stay identical. Otherwise synthesize a
    // history in the mirror and push that.
    const colocated = if (std.Io.Dir.cwd().access(io, ".git", .{})) |_| true else |_| false;
    if (colocated) {
        git.pushColocated(&s, ".", url, branch, force) catch {
            try w.print("push to {s} failed (diverged? try `gr push --force`; or auth/URL)\n", .{remote_name});
            return;
        };
    } else {
        git.pushRemote(&s, url, branch) catch {
            try w.print("push to {s} failed (auth? or check the URL)\n", .{remote_name});
            return;
        };
    }
    try w.print("pushed {s} → {s} ({s})\n", .{ branch, remote_name, url });
}

fn cmdPull(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    const remote_name = if (rest.len >= 1) rest[0] else "origin";
    const url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}'. pass a URL, or set it in git or `gr config remote.{s}.url`\n", .{ remote_name, remote_name });
        return;
    };
    defer alloc.free(url);
    git.pullRemote(&s, url) catch {
        try w.print("pull from {s} failed\n", .{remote_name});
        return;
    };
    try w.print("pulled from {s} ({s})\n", .{ remote_name, url });
}

fn cmdClone(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 2) {
        try w.writeAll("usage: gr clone <git-src|share-url|bundle#k=...> <dir>\n");
        return;
    }
    if (std.mem.indexOf(u8, rest[0], "#k=") != null) {
        return cloneShare(io, alloc, w, rest[0], rest[1]);
    }
    const into = rest[1];
    // Create the destination as a guardrail repo, then clone git into it.
    std.Io.Dir.cwd().createDirPath(io, into) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, into, .{});
    defer dest.close(io);
    var s = Store.init(io, alloc, dest) catch |e| switch (e) {
        Store.Error.RepoExists => try Store.open(io, alloc, dest),
        else => return e,
    };
    defer s.deinit();
    git.cloneGit(&s, rest[0], into) catch {
        try w.writeAll("clone failed\n");
        return;
    };
    try w.print("cloned {s} into {s}\n", .{ rest[0], into });
}

fn shareBranches(alloc: std.mem.Allocator, rest: []const []const u8, from: usize) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(alloc);
    var i = from;
    while (i < rest.len) : (i += 1) {
        if (std.mem.startsWith(u8, rest[i], "-")) {
            i += 1;
            continue;
        }
        try out.append(alloc, rest[i]);
    }
    return out.toOwnedSlice(alloc);
}

const default_relay_port: u16 = 7790;

fn relayFlag(rest: []const []const u8, host: *[]const u8, port: *u16) void {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (!eq(rest[i], "--relay") or i + 1 >= rest.len) continue;
        const spec = rest[i + 1];
        if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
            host.* = spec[0..c];
            port.* = std.fmt.parseInt(u16, spec[c + 1 ..], 10) catch default_relay_port;
        } else {
            host.* = spec;
        }
        i += 1;
    }
}

fn sendUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: gr send                    hand it to someone on this network
        \\       gr send --file <path>      one sealed file, no network at all
        \\       gr send --link <dir>       static files you upload anywhere
        \\       gr send --relay <host:port>  across the internet, via a relay
        \\
        \\       gr get <code | url | file>   the other side of all of these
        \\
    );
}

const lan_wait_ms: u64 = 90_000;
const announce_every_ms: u64 = 500;
const send_port_base: u16 = 7787;

fn announceLoop(io: std.Io, slot: u16, tcp_port: u16, stop: *std.atomic.Value(bool)) void {
    var broadcaster = discovery.Broadcaster.init(io) catch return;
    defer broadcaster.deinit(io);
    while (!stop.load(.acquire)) {
        _ = broadcaster.pulse(io, slot, tcp_port);
        io.sleep(.{ .nanoseconds = announce_every_ms * std.time.ns_per_ms }, .awake) catch return;
    }
}

fn cmdSend(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len != 0 and (eq(rest[0], "-h") or eq(rest[0], "--help"))) return sendUsage(w);

    var link_dir: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var base: []const u8 = "https://YOUR-HOST";
    var relay_host: ?[]const u8 = null;
    var relay_port: u16 = default_relay_port;

    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eq(rest[i], "--link") and i + 1 < rest.len) {
            link_dir = rest[i + 1];
            i += 1;
        } else if ((eq(rest[i], "--file") or eq(rest[i], "-o")) and i + 1 < rest.len) {
            file_path = rest[i + 1];
            i += 1;
        } else if (eq(rest[i], "--base") and i + 1 < rest.len) {
            base = rest[i + 1];
            i += 1;
        } else if (eq(rest[i], "--relay") and i + 1 < rest.len) {
            const spec = rest[i + 1];
            if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
                relay_host = spec[0..c];
                relay_port = std.fmt.parseInt(u16, spec[c + 1 ..], 10) catch default_relay_port;
            } else {
                relay_host = spec;
            }
            i += 1;
        }
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const wanted = try shareBranches(alloc, rest, 0);
    defer alloc.free(wanted);

    if (file_path) |path| return sendFile(io, alloc, w, &s, path, wanted);
    if (link_dir) |dir| return sendLink(io, alloc, w, &s, dir, base, wanted);

    const code = try wormhole.generateCode(io, alloc);
    defer alloc.free(code);
    const parsed = wormhole.Code.parse(code) catch return sendUsage(w);

    if (relay_host) |host| return sendViaRelay(io, alloc, w, &s, code, host, relay_port, wanted);

    var server: ipnet.Server = undefined;
    var bound: u16 = 0;
    var candidate: u16 = send_port_base;
    while (candidate < send_port_base + 16) : (candidate += 1) {
        var address: ipnet.IpAddress = .{ .ip4 = ipnet.Ip4Address.unspecified(candidate) };
        server = address.listen(io, .{ .reuse_address = true }) catch continue;
        bound = candidate;
        break;
    }
    if (bound == 0) {
        try w.writeAll("could not open a port to listen on\n");
        return;
    }
    defer server.deinit(io);

    try w.print("  {s}{s}{s}\n\n", .{ ui.on(.bold), code, ui.off() });
    try w.writeAll("on the other machine, on this same network, run:\n\n");
    try w.print("  gr get {s}\n\n", .{code});
    try ui.hint(w, "say the words out loud. they never touch the network.");
    try w.print("{s}waiting for a peer on this network...{s}\n", .{ ui.on(.dim), ui.off() });
    try w.flush();

    var stop = std.atomic.Value(bool).init(false);
    const announcer = std.Thread.spawn(.{}, announceLoop, .{ io, parsed.slot, bound, &stop }) catch null;
    defer if (announcer) |th| {
        stop.store(true, .release);
        th.join();
    };

    const stream = try server.accept(io);
    stop.store(true, .release);

    const conn = try wormhole.Conn.adopt(io, alloc, stream);
    defer conn.destroy();

    var session = wormhole.senderHandshake(io, alloc, conn.channel(), code) catch |e| {
        try reportHandshake(w, e);
        return;
    };

    const payload = try share.buildBundle(&s, alloc, session.key, wanted);
    defer alloc.free(payload);
    try session.sendStream(io, alloc, conn.channel(), payload);

    try w.print("{s}{s}{s} sent {d} bytes directly. nothing left this network.\n", .{
        ui.on(.green), ui.check, ui.off(), payload.len,
    });
}

fn sendFile(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    path: []const u8,
    wanted: []const []const u8,
) !void {
    const key = share.newShareKey(io);
    share.writeBundle(s, alloc, io, key, path, wanted) catch |e| {
        try w.print("could not write {s}: {t}\n", .{ path, e });
        return;
    };
    const url = try share.encodeUrl(alloc, "file", key);
    defer alloc.free(url);
    const frag = std.mem.indexOf(u8, url, "#k=") orelse url.len;

    try w.print("{s}{s}{s} wrote {s}{s}{s}\n\n  {s}key{s}  {s}{s}{s}\n\n", .{
        ui.on(.green), ui.check, ui.off(),
        ui.on(.cyan),  path,     ui.off(),
        ui.on(.dim),   ui.off(), ui.on(.bold),
        url[frag..],   ui.off(),
    });
    try w.print("open it with:  gr get '{s}{s}'\n", .{ path, url[frag..] });
    try ui.hint(w, "send the file and the key over different channels. either alone is useless.");
}

fn sendLink(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    dir: []const u8,
    base: []const u8,
    wanted: []const []const u8,
) !void {
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer dest.close(io);

    const key = share.newShareKey(io);
    share.exportDir(s, alloc, io, key, dest, wanted) catch |e| {
        try w.print("could not write {s}: {t}\n", .{ dir, e });
        return;
    };
    const url = try share.encodeUrl(alloc, base, key);
    defer alloc.free(url);

    try w.print("{s}{s}{s} wrote encrypted files to {s}{s}/{s}\n\n  {s}{s}{s}\n\n", .{
        ui.on(.green), ui.check, ui.off(),
        ui.on(.cyan),  dir,      ui.off(),
        ui.on(.bold),  url,      ui.off(),
    });
    try w.writeAll("upload that directory to any static host. it never receives the key:\n");
    try ui.hint(w, "the key is after the '#', which browsers and gr never put in a request.");
}

fn sendViaRelay(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    code: []const u8,
    host: []const u8,
    port: u16,
    wanted: []const []const u8,
) !void {
    try w.print("  {s}{s}{s}\n\n", .{ ui.on(.bold), code, ui.off() });
    try w.print("  gr get {s} --relay {s}:{d}\n\n", .{ code, host, port });
    try w.print("{s}waiting via {s}:{d}...{s}\n", .{ ui.on(.dim), host, port, ui.off() });
    try w.flush();

    const conn = wormhole.Conn.open(io, alloc, host, port) catch {
        try relayUnreachable(w, host, port);
        return;
    };
    defer conn.destroy();

    wormhole.join(conn.channel(), code) catch |e| {
        try reportHandshake(w, e);
        return;
    };
    var session = wormhole.senderHandshake(io, alloc, conn.channel(), code) catch |e| {
        try reportHandshake(w, e);
        return;
    };

    const payload = try share.buildBundle(s, alloc, session.key, wanted);
    defer alloc.free(payload);
    try session.sendStream(io, alloc, conn.channel(), payload);
    try w.print("{s}{s}{s} sent {d} bytes. the relay saw ciphertext and nothing else.\n", .{
        ui.on(.green), ui.check, ui.off(), payload.len,
    });
}

fn relayUnreachable(w: *std.Io.Writer, host: []const u8, port: u16) !void {
    try w.print("{s}{s}{s} cannot reach a relay at {s}{s}:{d}{s}\n", .{
        ui.on(.red), ui.cross, ui.off(), ui.on(.bold), host, port, ui.off(),
    });
    try ui.hint(w, "start one with `gr relay`, or use `gr send --file` instead");
}

fn looksLikeCode(text: []const u8) bool {
    _ = wormhole.Code.parse(text) catch return false;
    return true;
}

fn cmdGet(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1 or eq(rest[0], "-h") or eq(rest[0], "--help")) {
        try w.writeAll("usage: gr get <code | url | file> [dir]\n");
        return;
    }
    const source = rest[0];

    var into: []const u8 = ".";
    var relay_host: ?[]const u8 = null;
    var relay_port: u16 = default_relay_port;
    var i: usize = 1;
    while (i < rest.len) : (i += 1) {
        if (eq(rest[i], "--relay") and i + 1 < rest.len) {
            const spec = rest[i + 1];
            if (std.mem.lastIndexOfScalar(u8, spec, ':')) |c| {
                relay_host = spec[0..c];
                relay_port = std.fmt.parseInt(u16, spec[c + 1 ..], 10) catch default_relay_port;
            } else {
                relay_host = spec;
            }
            i += 1;
        } else if (!std.mem.startsWith(u8, rest[i], "-")) {
            into = rest[i];
        }
    }

    if (std.mem.indexOf(u8, source, "#k=") != null) {
        return cloneShare(io, alloc, w, source, into);
    }
    if (!looksLikeCode(source)) {
        try w.print("{s}{s}{s} not a code, a share url, or a bundle: {s}{s}{s}\n", .{
            ui.on(.red), ui.cross, ui.off(), ui.on(.bold), source, ui.off(),
        });
        try ui.hint(w, "codes look like 43-hydrant-hostel; links and files carry a #k=... key");
        return;
    }
    return receiveCode(io, alloc, w, source, into, relay_host, relay_port);
}

fn receiveCode(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    code: []const u8,
    into: []const u8,
    relay_host: ?[]const u8,
    relay_port: u16,
) !void {
    const parsed = wormhole.Code.parse(code) catch {
        try w.writeAll("that does not look like a gr code\n");
        return;
    };

    std.Io.Dir.cwd().createDirPath(io, into) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, into, .{});
    defer dest.close(io);
    var s = Store.init(io, alloc, dest) catch |e| switch (e) {
        Store.Error.RepoExists => try Store.open(io, alloc, dest),
        else => return e,
    };
    defer s.deinit();

    const conn = blk: {
        if (relay_host) |host| {
            const c = wormhole.Conn.open(io, alloc, host, relay_port) catch {
                try relayUnreachable(w, host, relay_port);
                return;
            };
            wormhole.join(c.channel(), code) catch |e| {
                c.destroy();
                try reportHandshake(w, e);
                return;
            };
            break :blk c;
        }
        try w.print("{s}looking for {s} on this network...{s}\n", .{ ui.on(.dim), code, ui.off() });
        try w.flush();
        const peer = discovery.discover(io, parsed.slot, lan_wait_ms) catch {
            try w.print("{s}{s}{s} nobody is sending {s} on this network\n", .{
                ui.on(.red), ui.cross, ui.off(), code,
            });
            try ui.hint(w, "same wifi? otherwise ask them for `gr send --file`, or pass --relay host:port");
            return;
        };
        break :blk wormhole.Conn.adopt(io, alloc, try peer.address.connect(io, .{ .mode = .stream })) catch {
            try w.writeAll("found a peer but could not connect\n");
            return;
        };
    };
    defer conn.destroy();

    var session = wormhole.receiverHandshake(io, alloc, conn.channel(), code) catch |e| {
        try reportHandshake(w, e);
        return;
    };
    const payload = session.recvStream(io, alloc, conn.channel()) catch |e| {
        try w.print("transfer failed: {t}\n", .{e});
        return;
    };
    defer alloc.free(payload);

    try share.importBundle(&s, alloc, session.key, payload);
    try materializeHead(io, alloc, &s, dest);

    try w.print("{s}{s}{s} received into {s}{s}{s}\n", .{
        ui.on(.green), ui.check, ui.off(), ui.on(.cyan), into, ui.off(),
    });
    try ui.hint(w, "any sealed values are still sealed. the code moved the code, not the secrets.");
}

fn materializeHead(io: std.Io, alloc: std.mem.Allocator, s: *Store, dest: std.Io.Dir) !void {
    _ = io;
    const branch = try s.headBranch();
    defer alloc.free(branch);
    if (!s.refExists(branch)) return;
    const change = try s.readChange(try s.readRef(branch));
    defer object.freeChange(alloc, change);
    try workspace.materialize(s, change.tree, dest);
}

fn reportHandshake(w: *std.Io.Writer, e: anyerror) !void {
    switch (e) {
        wormhole.Error.ConfirmationFailed => {
            try w.print("{s}{s}{s} the codes do not match. nothing was transferred.\n", .{
                ui.on(.red), ui.cross, ui.off(),
            });
            try ui.hint(w, "check the words, or start over: a wrong guess costs the sender a try.");
        },
        wormhole.Error.SlotBurned => {
            try w.writeAll("that code is used up. generate a fresh one with `gr send`.\n");
        },
        wormhole.Error.BadCode => try w.writeAll("that does not look like a gr code\n"),
        error.EndOfStream, error.ReadFailed, error.WriteFailed => {
            try w.writeAll("the peer hung up before the transfer, usually a mistyped code.\n");
            try ui.hint(w, "nothing was sent. run `gr send` again for a fresh one.");
        },
        else => try w.print("handshake failed: {t}\n", .{e}),
    }
}

fn cmdRelay(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var port: u16 = default_relay_port;
    if (rest.len >= 1) port = std.fmt.parseInt(u16, rest[0], 10) catch default_relay_port;
    try w.print("relay on port {d} (ctrl-c to stop)\n", .{port});
    try ui.hint(w, "it pairs two connections and forwards bytes. it never sees a code or a key.");
    try w.flush();
    return wormhole.rendezvous(io, alloc, port);
}

fn cloneShare(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    source: []const u8,
    into: []const u8,
) !void {
    std.Io.Dir.cwd().createDirPath(io, into) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, into, .{});
    defer dest.close(io);
    var s = Store.init(io, alloc, dest) catch |e| switch (e) {
        Store.Error.RepoExists => try Store.open(io, alloc, dest),
        else => return e,
    };
    defer s.deinit();

    const is_http = std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "https://");

    if (is_http) {
        share.fetchHttp(&s, alloc, io, source) catch |e| {
            try w.print("clone failed: {t}\n", .{e});
            return;
        };
    } else {
        const cut = std.mem.indexOf(u8, source, "#k=").?;
        const encoded = source[cut + "#k=".len ..];
        var key: share.ShareKey = undefined;
        const decoder = std.base64.url_safe_no_pad.Decoder;
        const n = decoder.calcSizeForSlice(encoded) catch 0;
        if (n != share.key_len) {
            try w.writeAll("that key does not look like a gr share key\n");
            return;
        }
        decoder.decode(&key, encoded) catch {
            try w.writeAll("that key does not look like a gr share key\n");
            return;
        };
        share.readBundle(&s, alloc, io, key, source[0..cut]) catch |e| {
            try w.print("clone failed: {t}\n", .{e});
            return;
        };
    }

    const branch = try s.headBranch();
    defer alloc.free(branch);
    if (s.refExists(branch)) {
        const change = try s.readChange(try s.readRef(branch));
        defer object.freeChange(alloc, change);
        try workspace.materialize(&s, change.tree, dest);
    }
    try w.print("{s}{s}{s} cloned into {s}{s}{s}\n", .{
        ui.on(.green), ui.check, ui.off(), ui.on(.cyan), into, ui.off(),
    });
    try w.writeAll("any sealed values are still sealed. `gr unseal` needs a key you were not given.\n");
}

fn sealUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: gr seal <path>       start sealing a file (creates .grsealed)
        \\       gr seal             re-seal every tracked path now
        \\       gr seal status      show sealed paths and who can read them
        \\       gr unseal           write the plaintext files back out
        \\       gr rotate           new repo key, re-wrapped to every member
        \\
    );
}

fn keyUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: gr key new                 create your keypair
        \\       gr key show                print your public key (share this)
        \\       gr key add <name> <pubkey> grant someone access to the secrets
        \\       gr key remove <name>       revoke (then `gr rotate`)
        \\       gr key list                who can read the sealed values
        \\
    );
}

fn loadRepoManifest(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    work: std.Io.Dir,
) !?seal.Manifest {
    return (keyring.loadManifest(io, alloc, work) catch |e| {
        try w.print("cannot read {s}: {t}\n", .{ seal.manifest_name, e });
        return null;
    }) orelse {
        try w.print("nothing is sealed here yet (run `gr seal <path>`)\n", .{});
        return null;
    };
}

fn requireIdentity(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !?seal.Identity {
    return (try keyring.loadIdentity(io, alloc)) orelse {
        try w.print("{s}{s}{s} no keypair yet. run {s}gr key new{s}\n", .{ ui.on(.red), ui.cross, ui.off(), ui.on(.cyan), ui.off() });
        return null;
    };
}

fn cmdKey(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len == 0) return keyUsage(w);
    const sub = rest[0];

    if (eq(sub, "new")) {
        const id = keyring.createIdentity(io, alloc, false) catch |e| switch (e) {
            keyring.Error.IdentityExists => {
                const path = (try keyring.identityPath(alloc)) orelse "";
                defer if (path.len != 0) alloc.free(path);
                try w.print("you already have a keypair at {s}\n", .{path});
                return;
            },
            keyring.Error.NoHome => {
                try w.writeAll("cannot locate a config directory (set HOME or XDG_CONFIG_HOME)\n");
                return;
            },
            else => return e,
        };
        try printPublicKey(alloc, w, id.publicId(), "created");
        return;
    }

    if (eq(sub, "show")) {
        const id = (try requireIdentity(io, alloc, w)) orelse return;
        try printPublicKey(alloc, w, id.publicId(), "your public key");
        return;
    }

    var work = try openWork(io);
    defer work.close(io);

    if (eq(sub, "list")) {
        var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
        defer manifest.deinit();
        const mine = if (try keyring.loadIdentity(io, alloc)) |id| id.publicId() else null;
        for (manifest.members.items) |m| {
            const fp = try m.public.fingerprint(alloc);
            defer alloc.free(fp);
            const is_me = if (mine) |p| std.mem.eql(u8, &p.x, &m.public.x) else false;
            const mark = if (is_me) ui.branch_mark else ui.bullet;
            const mark_color: ui.Color = if (is_me) .cyan else .dim;
            try w.print("{s}{s}{s} {s}", .{ ui.on(mark_color), mark, ui.off(), m.name });
            try ui.pad(w, m.name, 14);
            try w.print("{s}{s}{s}{s}\n", .{ ui.on(.magenta), fp, ui.off(), if (is_me) "  (you)" else "" });
        }
        return;
    }

    if (eq(sub, "add")) {
        if (rest.len < 3) return keyUsage(w);
        const name = rest[1];
        const public = seal.PublicId.decode(rest[2]) catch {
            try w.writeAll("that does not look like a gr public key\n");
            return;
        };
        var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
        defer manifest.deinit();

        const key = (try keyring.repoKey(io, alloc, &manifest)) orelse {
            try w.writeAll("you cannot read this repo's secrets, so you cannot grant access\n");
            return;
        };
        if (manifest.findMember(name)) |i| {
            if (!std.mem.eql(u8, &manifest.members.items[i].public.x, &public.x)) {
                const old_fp = try manifest.members.items[i].public.fingerprint(alloc);
                defer alloc.free(old_fp);
                try w.print("warning: {s} already exists with a different key ({s})\n", .{ name, old_fp });
                try w.writeAll("if you did not expect this, stop and verify out of band\n");
            }
        }
        try manifest.putMember(io, key, name, public);
        try keyring.saveManifest(io, alloc, work, &manifest);

        const fp = try public.fingerprint(alloc);
        defer alloc.free(fp);
        try w.print("{s}{s}{s} {s} can now read the sealed values\n", .{ ui.on(.green), ui.check, ui.off(), name });
        try w.print("  {s}fingerprint{s}  {s}{s}{s}\n", .{ ui.on(.dim), ui.off(), ui.on(.magenta), fp, ui.off() });
        try w.print("{s}confirm that out loud with them, then commit {s}{s}\n", .{ ui.on(.dim), seal.manifest_name, ui.off() });
        return;
    }

    if (eq(sub, "remove")) {
        if (rest.len < 2) return keyUsage(w);
        var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
        defer manifest.deinit();
        if (!manifest.removeMember(rest[1])) {
            try w.print("no member named {s}\n", .{rest[1]});
            return;
        }
        try keyring.saveManifest(io, alloc, work, &manifest);
        try w.print("removed {s} from {s}\n", .{ rest[1], seal.manifest_name });
        try w.writeAll("they still hold the old key and every commit they already cloned.\n");
        try w.writeAll("run `gr rotate`, then rotate the underlying secrets themselves\n");
        try w.writeAll("(new database password, new API keys). only that actually revokes them.\n");
        return;
    }

    try keyUsage(w);
}

fn printPublicKey(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    public: seal.PublicId,
    label: []const u8,
) !void {
    const enc = try public.encode(alloc);
    defer alloc.free(enc);
    const fp = try public.fingerprint(alloc);
    defer alloc.free(fp);
    try w.print("{s}{s}{s}\n\n{s}\n\n  {s}fingerprint{s}  {s}{s}{s}\n", .{
        ui.on(.bold), label, ui.off(), enc, ui.on(.dim), ui.off(), ui.on(.magenta), fp, ui.off(),
    });
}

fn pathInHistory(alloc: std.mem.Allocator, s: *Store, path: []const u8) !bool {
    const branch = try s.headBranch();
    defer alloc.free(branch);
    if (!s.refExists(branch)) return false;

    var seen = std.AutoHashMap([Oid.len]u8, void).init(alloc);
    defer seen.deinit();
    var queue: std.ArrayList(Oid) = .empty;
    defer queue.deinit(alloc);
    try queue.append(alloc, s.readRef(branch) catch return false);

    while (queue.pop()) |current| {
        if ((try seen.getOrPut(current.bytes)).found_existing) continue;
        const change = s.readChange(current) catch continue;
        defer object.freeChange(alloc, change);
        const tree = s.readTree(change.tree) catch continue;
        defer object.freeTree(alloc, tree);
        for (tree.entries) |e| {
            if (std.mem.eql(u8, e.path, path)) return true;
        }
        for (change.parents) |p| try queue.append(alloc, p);
    }
    return false;
}

fn cmdSeal(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    if (rest.len != 0 and eq(rest[0], "status")) {
        var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
        defer manifest.deinit();
        for (manifest.files.items) |f| {
            const present = if (work.access(io, f.path, .{})) |_| true else |_| false;
            try w.print("  {s}{s}{s} {s} {s}{s}{s} {s}{s}{s}\n", .{
                ui.on(if (present) .green else .yellow), if (present) ui.check else ui.warn, ui.off(),
                f.path,                                  ui.on(.dim),                        ui.arrow,
                ui.off(),                                ui.on(.cyan),                       seal.manifest_name,
                ui.off(),
            });
            if (!present) try ui.hint(w, "      no local plaintext. run `gr unseal`");
        }
        try w.print("{d} member(s) can read these values\n", .{manifest.members.items.len});
        const key = try keyring.repoKey(io, alloc, &manifest);
        if (key == null) try w.writeAll("you are not one of them\n");
        return;
    }

    if (rest.len != 0 and (eq(rest[0], "-h") or eq(rest[0], "--help"))) return sealUsage(w);

    if (rest.len != 0) {
        const path = rest[0];
        work.access(io, path, .{}) catch {
            try w.print("no such file: {s}\n", .{path});
            return;
        };
        const id = (try requireIdentity(io, alloc, w)) orelse return;

        var manifest = (try keyring.loadManifest(io, alloc, work)) orelse
            seal.Manifest.empty(alloc);
        defer manifest.deinit();

        const key = if (manifest.members.items.len == 0) blk: {
            const fresh = seal.newRepoKey(io);
            var name = try config.get(&s, alloc, "user.name") orelse
                try alloc.dupe(u8, "me");
            defer alloc.free(name);
            if (name.len == 0) {
                alloc.free(name);
                name = try alloc.dupe(u8, "me");
            }
            try manifest.putMember(io, fresh, name, id.publicId());
            break :blk fresh;
        } else (try keyring.repoKey(io, alloc, &manifest)) orelse {
            try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `gr key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
            return;
        };
        _ = key;

        if (!try manifest.addPath(path)) {
            try w.print("{s} is already sealed\n", .{path});
        }
        try keyring.saveManifest(io, alloc, work, &manifest);
        try keyring.protectPath(io, alloc, work, path);

        if (try pathInHistory(alloc, &s, path)) {
            try w.print("warning: {s} is already committed in this repo's history.\n", .{path});
            try w.writeAll("sealing it now protects future changes only. the old plaintext is\n");
            try w.writeAll("still in past changes and in every clone. treat those values as leaked\n");
            try w.writeAll("and rotate them.\n\n");
        }
    }

    var plan = keyring.prepare(io, alloc, work) catch |e| {
        try w.print("seal failed: {t}\n", .{e});
        return;
    };
    defer plan.deinit();

    if (plan.outputs.len == 0) {
        try w.writeAll("nothing is sealed here yet (run `gr seal <path>`)\n");
        return;
    }
    if (!plan.have_key) {
        try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `gr key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
        return;
    }
    for (plan.sources) |src| {
        try w.print("  {s}{s}{s} {s} {s}{s}{s} {s}{s}{s}\n", .{
            ui.on(.green), ui.check,     ui.off(),
            src,           ui.on(.dim),  ui.arrow,
            ui.off(),      ui.on(.cyan), seal.manifest_name,
            ui.off(),
        });
    }
    try w.print("\n{s}commit {s}; the plaintext stays out of every change{s}\n", .{
        ui.on(.dim), seal.manifest_name, ui.off(),
    });
}

fn cmdUnseal(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var work = try openWork(io);
    defer work.close(io);

    const out = keyring.unsealAll(io, alloc, work) catch |e| switch (e) {
        keyring.Error.NoManifest => {
            try w.writeAll("nothing is sealed here yet (run `gr seal <path>`)\n");
            return;
        },
        seal.Error.NotAMember => {
            try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `gr key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
            try w.writeAll("(`gr key show` prints the public key they need)\n");
            return;
        },
        seal.Error.BadToken => {
            try w.writeAll("a sealed value failed to decrypt. the file may be corrupt or edited\n");
            return;
        },
        else => return e,
    };
    try w.print("{s}{s}{s} wrote {d} file(s)", .{ ui.on(.green), ui.check, ui.off(), out.written });
    if (out.skipped != 0) try w.print(", skipped {d} with no sealed form", .{out.skipped});
    try w.writeAll("\n");
}

fn cmdRotate(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var work = try openWork(io);
    defer work.close(io);

    var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
    defer manifest.deinit();

    const old = (try keyring.repoKey(io, alloc, &manifest)) orelse {
        try w.writeAll("you cannot read this repo's secrets, so you cannot rotate them\n");
        return;
    };

    for (manifest.files.items) |f| {
        if (work.access(io, f.path, .{})) |_| continue else |_| {}
        const sealed = f.body orelse continue;
        const plain = try seal.unsealText(alloc, old, f.path, sealed);
        defer alloc.free(plain);
        try work.writeFile(io, .{
            .sub_path = f.path,
            .data = plain,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }

    const fresh = seal.newRepoKey(io);
    try manifest.rewrapAll(io, fresh);

    for (manifest.files.items) |f| {
        const plain = work.readFileAlloc(io, f.path, alloc, .unlimited) catch continue;
        defer alloc.free(plain);
        const sealed = try seal.sealText(alloc, fresh, f.path, plain);
        defer alloc.free(sealed);
        _ = try manifest.setBody(f.path, sealed);
    }
    try keyring.saveManifest(io, alloc, work, &manifest);

    try w.print("{s}{s}{s} rotated the repo key, re-wrapped to {d} member(s)\n", .{
        ui.on(.green), ui.check, ui.off(), manifest.members.items.len,
    });
    try w.writeAll("anyone removed earlier still holds the OLD key and any commit they cloned.\n");
    try w.writeAll("rotate the secrets themselves too (new password, new API key), or they keep working.\n");
}

test {
    std.testing.refAllDecls(@This());
    _ = seal;
    _ = keyring;
    _ = share;
    _ = wormhole;
    _ = ui;
    _ = discovery;
    _ = oid;
    _ = cdc;
    _ = object;
    _ = store;
    _ = workspace;
    _ = oplog;
    _ = git;
    _ = diff;
    _ = branches;
    _ = config;
    _ = merge;
    _ = watch;
    _ = net;
    _ = ignore;
    _ = provenance;
    _ = attribution;
    _ = agentscan;
    _ = update;
    _ = gc;
    _ = blame;
    _ = completions;
    _ = absorb;
    _ = lfs;
    _ = proc;
    _ = @import("applog.zig");
    _ = moment;
    _ = verdict;
    _ = revspec;
    _ = checks;
    _ = readset;
    _ = warrant;
    _ = tracer;
    _ = grade;
    _ = sched;
    _ = rewind;
    _ = freshness;
    _ = fork;
    _ = recap;
    _ = flow;
    _ = superpose;
    _ = live;
    _ = @import("index.zig");
}
