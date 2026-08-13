const std = @import("std");
const oid = @import("oid.zig");
const cdc = @import("cdc.zig");
const object = @import("object.zig");
const store = @import("store.zig");
const workspace = @import("workspace.zig");
const oplog = @import("oplog.zig");
const opdag = @import("opdag.zig");
const git = @import("git.zig");
const diff = @import("diff.zig");
const branches = @import("branches.zig");
const config = @import("config.zig");
const merge = @import("merge.zig");
const replay = @import("replay.zig");
const history = @import("history.zig");
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
const hook = @import("hook.zig");
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
const attest = @import("attest.zig");
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

const version = @import("build_options").version;

const Entry = struct { name: []const u8, alias: []const u8 = "", args: []const u8 = "", desc: []const u8 };
const Section = struct { title: []const u8, entries: []const Entry };

const sections = [_]Section{
    .{ .title = "the everyday loop", .entries = &.{
        .{ .name = "save", .alias = "sv", .args = "[-m msg]", .desc = "checkpoint the working tree" },
        .{ .name = "status", .alias = "st", .desc = "what changed since the last save" },
        .{ .name = "diff", .alias = "d", .desc = "line-level diff vs the last save" },
        .{ .name = "log", .alias = "l", .desc = "the change history" },
        .{ .name = "describe", .alias = "desc", .args = "-m msg [--at]", .desc = "name or rename any change" },
    } },
    .{ .title = "moving around", .entries = &.{
        .{ .name = "new", .alias = "n", .args = "<name>", .desc = "branch off here and switch to it" },
        .{ .name = "switch", .alias = "sw", .args = "<name>", .desc = "move to another branch (auto-saves)" },
        .{ .name = "branch", .alias = "b", .args = "[-d name]", .desc = "list branches, or delete one" },
        .{ .name = "work", .alias = "wt", .args = "<dir>", .desc = "instant copy-on-write worktree" },
        .{ .name = "restore", .alias = "rs", .args = "<file>", .desc = "discard local edits to one file" },
        .{ .name = "merge", .alias = "mg", .args = "<branch>", .desc = "merge another branch into this one" },
        .{ .name = "resolve", .alias = "res", .args = "<file>", .desc = "mark a conflict resolved (--abort to bail)" },
        .{ .name = "revert", .alias = "rev", .desc = "undo a change as a new change" },
        .{ .name = "absorb", .alias = "ab", .args = "[-- <paths>]", .desc = "fold edits into the changes they belong to" },
    } },
    .{ .title = "reshaping history", .entries = &.{
        .{ .name = "point", .alias = "pt", .args = "<ref>", .desc = "move this branch's tip to any ref" },
        .{ .name = "rebase", .alias = "rb", .args = "<ref>", .desc = "replay this branch onto a new base" },
        .{ .name = "amend", .alias = "am", .args = "[--at ref]", .desc = "fold working edits into a named change" },
        .{ .name = "squash", .alias = "sq", .args = "[n] [--at] [-m]", .desc = "collapse adjacent changes into one" },
        .{ .name = "split", .alias = "spl", .args = "[ref] -- <paths> | --hunk p:n", .desc = "split one change in two, by path or hunk" },
        .{ .name = "drop", .alias = "dr", .args = "[ref]", .desc = "remove a change, keep its edits in the tree" },
        .{ .name = "reorder", .alias = "ro", .args = "<order...>", .desc = "reorder the last changes, 1 = oldest" },
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
        .{ .name = "grade", .alias = "gd", .args = "[git-ref]", .desc = "grade now, or any git ref; --on automates" },
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
        .{ .name = "hook", .args = "[install [--write <path>]]", .desc = "tell a coding agent whether its work passed" },
    } },
    .{ .title = "git, side by side", .entries = &.{
        .{ .name = "clone", .alias = "cl", .args = "<src> [dir]", .desc = "a git repo, a share URL, or a bundle" },
        .{ .name = "import", .args = "<repo>", .desc = "pull a git repo's HEAD into superdetermine" },
        .{ .name = "export", .args = "<repo> [--force]", .desc = "write superdetermine HEAD out as git commits" },
        .{ .name = "sync", .args = "<dir> [--force]", .desc = "mirror HEAD into the colocated .git" },
        .{ .name = "push", .alias = "ps", .args = "[remote] [branch] [--require-green]", .desc = "uses your existing git credentials" },
        .{ .name = "pull", .alias = "pl", .args = "[remote] [branch]", .desc = "fetch and merge from a git remote" },
        .{ .name = "attest", .alias = "at", .args = "[ref] [--dry-run]", .desc = "post the warrant as a GitHub commit status" },
        .{ .name = "lfs", .args = "<cmd>", .desc = "git-lfs interop" },
    } },
    .{ .title = "housekeeping", .entries = &.{
        .{ .name = "init", .desc = "create a superdetermine repo here" },
        .{ .name = "gc", .args = "[--dry-run]", .desc = "reclaim unreachable objects" },
        .{ .name = "config", .alias = "cfg", .args = "<key> [val]", .desc = "identity and defaults" },
        .{ .name = "completions", .alias = "comp", .args = "<shell>", .desc = "fish | zsh | bash" },
        .{ .name = "update", .desc = "update sdt (--nightly for the latest build)" },
        .{ .name = "version", .desc = "" },
    } },
};

fn printUsage(w: *std.Io.Writer) !void {
    try w.print("{s}sdt{s} {s}superdetermine: a VCS that records what worked, not just what changed{s}\n\n", .{
        ui.on(.bold), ui.off(), ui.on(.dim), ui.off(),
    });
    try w.print("  {s}usage:{s} sdt <command> [args]\n", .{ ui.on(.dim), ui.off() });

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
    .{ .short = "pt", .full = "point" },
    .{ .short = "rb", .full = "rebase" },
    .{ .short = "am", .full = "amend" },
    .{ .short = "sq", .full = "squash" },
    .{ .short = "spl", .full = "split" },
    .{ .short = "dr", .full = "drop" },
    .{ .short = "ro", .full = "reorder" },
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
    .{ .short = "at", .full = "attest" },
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
        try w.print("sdt {s}\n", .{version});
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
        try cmdBranch(io, alloc, w, rest);
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
        const code = try cmdGrade(io, alloc, w, rest);
        if (code != 0) {
            try w.flush();
            std.process.exit(code);
        }
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
    } else if (eq(cmd, "attest")) {
        const code = try cmdAttest(io, alloc, w, rest);
        if (code != 0) {
            try w.flush();
            std.process.exit(code);
        }
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
        try cmdAbsorb(io, alloc, w, rest);
    } else if (eq(cmd, "amend")) {
        try cmdAmend(io, alloc, w, rest);
    } else if (eq(cmd, "drop")) {
        try cmdDrop(io, alloc, w, rest);
    } else if (eq(cmd, "point")) {
        try cmdPoint(io, alloc, w, rest);
    } else if (eq(cmd, "rebase")) {
        try cmdRebase(io, alloc, w, rest);
    } else if (eq(cmd, "squash")) {
        try cmdSquash(io, alloc, w, rest);
    } else if (eq(cmd, "split")) {
        try cmdSplit(io, alloc, w, rest);
    } else if (eq(cmd, "reorder")) {
        try cmdReorder(io, alloc, w, rest);
    } else if (eq(cmd, "hook")) {
        hook.run(io, alloc, w, rest);
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
            try w.print("  did you mean {s}sdt {s}{s}?\n", .{ ui.on(.cyan), guess, ui.off() });
        }
        try w.print("{s}run `sdt help` for the full list{s}\n", .{ ui.on(.dim), ui.off() });
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
// supplied (--prompt/--agent flag or SDT_PROMPT/SDT_AGENT env, or the older
// GR_ spellings), and never when
// config `provenance` is a falsy kill-switch.
fn recordProvenance(io: std.Io, alloc: std.mem.Allocator, s: *Store, change: Oid, rest: []const []const u8) void {
    const prompt = envOr("SDT_PROMPT", envOr("GR_PROMPT", flagValue(rest, "--prompt", "--prompt")));
    const agent = envOr("SDT_AGENT", envOr("GR_AGENT", flagValue(rest, "--agent", "--agent")));
    if (prompt.len == 0 and agent.len == 0) return;
    if (config.get(s, alloc, "provenance")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            if (eq(v, "off") or eq(v, "false") or eq(v, "0") or eq(v, "no")) return;
        }
    } else |_| {}
    provenance.record(s, change, agent, prompt, nowSeconds(io)) catch {};
}

/// The worktree root, which is the directory holding the repo dir and not the
/// directory the command was typed in. Tracked paths are stored repo-root
/// relative, so resolving them against the cwd would write a second copy of the
/// tree into whatever subdirectory happened to be current.
fn openWork(io: std.Io) !std.Io.Dir {
    // cwd() is a special AT_FDCWD handle that cannot be iterated/seeked.
    return openWorkFrom(io, std.Io.Dir.cwd());
}

fn openWorkFrom(io: std.Io, start: std.Io.Dir) !std.Io.Dir {
    var dir = try start.openDir(io, ".", .{ .iterate = true });
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        if (isWorkRoot(io, dir)) return dir;
        const parent = dir.openDir(io, "..", .{ .iterate = true }) catch break;
        dir.close(io);
        dir = parent;
    }
    dir.close(io);
    return start.openDir(io, ".", .{ .iterate = true });
}

fn isWorkRoot(io: std.Io, dir: std.Io.Dir) bool {
    if (dir.access(io, store.dir_name, .{})) |_| return true else |_| {}
    if (dir.access(io, store.legacy_dir_name, .{})) |_| return true else |_| {}
    return false;
}

fn openRepo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !?Store {
    return Store.discover(io, alloc, std.Io.Dir.cwd()) catch {
        try w.print("{s}{s}{s} not a superdetermine repo\n", .{ ui.on(.red), ui.cross, ui.off() });
        try ui.hint(w, "run `sdt init` here, or cd into a repo");
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
            try w.writeAll("superdetermine repo already exists here\n");
            return;
        },
        else => return e,
    };
    const db = config.defaultBranch(io, alloc) catch try alloc.dupe(u8, "main");
    defer alloc.free(db);
    s.setHeadBranch(db) catch {};
    s.deinit();
    try w.print("{s}{s}{s} initialized empty superdetermine repo in {s}{s}{s} on {s}{s}{s}\n", .{
        ui.on(.green), ui.check,       ui.off(),
        ui.on(.dim),   store.dir_name, ui.off(),
        ui.on(.cyan),  db,             ui.off(),
    });

    try excludeFromColocatedGit(io, alloc, w, std.Io.Dir.cwd());
    try startCapturing(io, alloc, w);
}

/// Keep the repo dir out of a colocated git repo's eyes.
///
/// Without this line `git status` in a colocated repo reports `.sdt/` as
/// untracked forever, which is not a cosmetic problem: it makes every git-side
/// check that expects a clean tree fail from the moment superdetermine is
/// initialized. `.git/info/exclude` is the right home for it because it is
/// local to the clone and is not itself a tracked file.
fn excludeFromColocatedGit(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, root: std.Io.Dir) !void {
    var git_dir = root.openDir(io, ".git", .{}) catch return;
    defer git_dir.close(io);

    const existing: ?[]u8 = git_dir.readFileAlloc(io, "info/exclude", alloc, .unlimited) catch null;
    defer if (existing) |e| alloc.free(e);

    if (existing) |e| {
        var it = std.mem.splitScalar(u8, e, '\n');
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r/");
            if (eq(t, store.dir_name)) return;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    if (existing) |e| {
        try out.appendSlice(alloc, e);
        if (e.len != 0 and e[e.len - 1] != '\n') try out.append(alloc, '\n');
    }
    try out.appendSlice(alloc, store.dir_name ++ "/\n");

    git_dir.createDirPath(io, "info") catch {};
    git_dir.writeFile(io, .{ .sub_path = "info/exclude", .data = out.items }) catch return;

    try w.print("{s}{s}{s} told the colocated git repo to ignore {s}{s}/{s}\n", .{
        ui.on(.green), ui.check,       ui.off(),
        ui.on(.dim),   store.dir_name, ui.off(),
    });
}

/// Turn on continuous capture for a new repo.
///
/// This is opinionated on purpose. The claim is that nothing is ever unsaved,
/// and that is only true if capture is running before anything goes wrong — a
/// safety net you have to switch on is a safety net you switch on after the
/// fall. Capture is cheap, stays entirely local, and runs none of your code:
/// grading is what runs your code, and grading stays inert until you configure
/// a check.
///
/// It is still one command to undo, and this says so rather than being quiet
/// about having registered something.
fn startCapturing(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var work = openWork(io) catch return;
    defer work.close(io);
    const repo_abs = work.realPathFileAlloc(io, ".", alloc) catch return;
    defer alloc.free(repo_abs);

    const exe = update.selfExePathAlloc(alloc) catch {
        try ui.hint(w, "run `sdt watch` to capture every state as you work");
        return;
    };
    defer alloc.free(exe);

    sched.install(io, alloc, exe, repo_abs, .{}) catch {
        // No OS scheduler here, or it refused. The foreground path does the
        // same work, so say that instead of failing the init.
        try ui.hint(w, "run `sdt watch` to capture every state as you work");
        return;
    };

    try w.print("{s}{s}{s} capturing every state, in the background, with no daemon\n", .{
        ui.on(.green), ui.check, ui.off(),
    });
    try ui.hint(w, "`sdt moments` lists them, `sdt green` needs a check: `sdt config checks.full \"...\"`");
    try ui.hint(w, "`sdt grade --off` stops it");
}

fn cmdProvenance(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const records = try provenance.all(&s, alloc);
    defer provenance.freeAll(alloc, records);
    if (records.len == 0) {
        try w.writeAll("no provenance recorded (set SDT_PROMPT/SDT_AGENT or use `sdt save --prompt`)\n");
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
        try w.writeAll("usage: sdt blame <file>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    try blame.run(&s, alloc, w, rest[0]);
}

fn cmdResolve(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
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
        try w.writeAll("usage: sdt resolve <file>   (or --abort)\nunresolved:\n");
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
        try w.print("resolved {s}. all conflicts cleared, now `sdt save`\n", .{rest[0]});
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
    try workspace.checkout(&s, work, head_change.tree, target_tree);

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

/// The shared surface of `absorb` and `amend`: an optional target, and an
/// optional scope of paths or hunks within the working tree.
const AmendArgs = struct {
    at: []const u8 = "",
    paths: std.ArrayList([]const u8) = .empty,
    hunks: std.ArrayList(history.HunkSpec) = .empty,

    fn deinit(self: *AmendArgs, alloc: std.mem.Allocator) void {
        self.paths.deinit(alloc);
        for (self.hunks.items) |h| alloc.free(h.indices);
        self.hunks.deinit(alloc);
    }

    fn scope(self: *const AmendArgs) absorb.Scope {
        if (self.hunks.items.len != 0) return .{ .hunks = self.hunks.items };
        if (self.paths.items.len != 0) return .{ .paths = self.paths.items };
        return .all;
    }
};

fn parseAmendArgs(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    rest: []const []const u8,
    args: *AmendArgs,
) !bool {
    var after_sep = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--")) {
            after_sep = true;
        } else if (after_sep) {
            try args.paths.append(alloc, a);
        } else if (eq(a, "--at")) {
            i += 1;
            if (i >= rest.len) {
                try amendUsage(w);
                return false;
            }
            args.at = rest[i];
        } else if (eq(a, "--hunk") or eq(a, "-H")) {
            i += 1;
            if (i >= rest.len) {
                try amendUsage(w);
                return false;
            }
            if (!try appendHunkSpec(alloc, w, rest[i], &args.hunks)) return false;
        } else if (a.len != 0 and a[0] == '-') {
            try w.print("unknown option '{s}'\n", .{a});
            return false;
        } else if (args.at.len == 0) {
            args.at = a;
        }
    }
    if (args.paths.items.len != 0 and args.hunks.items.len != 0) {
        try w.writeAll("amend takes paths or --hunk selectors, not both at once\n");
        return false;
    }
    return true;
}

fn amendUsage(w: *std.Io.Writer) !void {
    try w.writeAll("usage: sdt amend [--at <ref>] [-- <paths>]\n");
    try w.writeAll("       sdt amend --at <ref> --hunk <path>:<n[,n][,a-b]> ...\n");
    try ui.hint(w, "folds working-tree edits into that change, then replays everything after it");
    try ui.hint(w, "run it once per hunk to send different hunks of one file to different changes");
}

fn cmdAbsorb(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var args: AmendArgs = .{};
    defer args.deinit(alloc);
    if (!try parseAmendArgs(alloc, w, rest, &args)) return;

    if (args.hunks.items.len != 0 and args.at.len == 0) {
        try w.writeAll("--hunk needs a target change to absorb into\n");
        try ui.hint(w, "`sdt absorb --at <ref> --hunk <path>:<n>` picks the change by hand");
        return;
    }
    if (args.at.len != 0) return amendInto(io, alloc, w, &args, "absorbed");

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    var work = try openWork(io);
    defer work.close(io);
    try absorb.run(&s, alloc, work, args.paths.items, w);
}

fn cmdAmend(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var args: AmendArgs = .{};
    defer args.deinit(alloc);
    if (!try parseAmendArgs(alloc, w, rest, &args)) return;
    try amendInto(io, alloc, w, &args, "amended");
}

fn amendInto(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    args: *const AmendArgs,
    what: []const u8,
) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);

    const branch = try s.headBranch();
    defer alloc.free(branch);
    const target = if (args.at.len != 0)
        (try resolveChangeOrFail(io, alloc, w, &s, args.at)) orelse return
    else
        history.tipOf(&s, branch) catch {
            try w.writeAll("nothing saved on this branch yet\n");
            return;
        };
    const before_tree = branches.headTree(&s);

    var work = try openWork(io);
    defer work.close(io);

    const r = absorb.amend(&s, alloc, work, target, args.scope(), nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "amend")) return;
        return e;
    };
    defer r.deinit(alloc);

    // The working tree already holds the edit, and whatever was not selected is
    // still an edit, so it is left alone. A conflicted fold is the exception:
    // the marked-up merge is written out so it is in front of you rather than
    // only in the change.
    try reportRewrite(io, alloc, w, &s, before_tree, r, what, if (r.clean()) .keep else .checkout);
    if (r.clean()) try ui.hint(w, "`sdt status` shows whatever you did not fold in");
}

fn cmdDrop(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "drop");

    const branch = try s.headBranch();
    defer alloc.free(branch);
    const target = if (rest.len != 0 and rest[0].len != 0 and rest[0][0] != '-')
        (try resolveChangeOrFail(io, alloc, w, &s, rest[0])) orelse return
    else
        history.tipOf(&s, branch) catch {
            try w.writeAll("nothing saved on this branch yet\n");
            return;
        };
    const before_tree = branches.headTree(&s);

    const r = history.drop(&s, alloc, branch, target, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "drop")) return;
        return e;
    };
    defer r.deinit(alloc);

    if (r.new.isZero()) {
        try w.print("{s}{s}{s} dropped the only change; {s}{s}{s} is unborn again\n", .{
            ui.on(.green), ui.check, ui.off(), ui.on(.cyan), branch, ui.off(),
        });
        try ui.hint(w, "`sdt undo` puts the old history back");
    } else {
        // The whole point is that the content survives, so the working tree is
        // never touched: what the change held comes back as an uncommitted edit.
        try reportRewrite(io, alloc, w, &s, before_tree, r, "dropped", .keep);
    }
    try w.writeAll("its edits are still in the working tree\n");
}

/// Auto-save before a command that will overwrite the working tree, matching
/// what `switch` has always done. Merge and pull did not, and silently ate
/// uncommitted edits.
fn autoSaveIfDirty(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, s: *Store, verb: []const u8) !void {
    var work = openWork(io) catch return;
    defer work.close(io);
    const dirty = workspace.status(s, work, alloc) catch return;
    const had_changes = dirty.len > 0;
    for (dirty) |e| alloc.free(e.path);
    alloc.free(dirty);
    if (!had_changes) return;
    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "wip (auto-saved before {s})", .{verb}) catch "wip (auto-saved)";
    _ = try doSave(io, alloc, s, msg);
    try w.writeAll("auto-saved your work first\n");
}

/// Resolve any address to the change a branch could point at. Captured moments
/// that no change corresponds to are not such an address, and say so rather
/// than being rounded to something nearby.
fn resolveChangeOrFail(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    spec: []const u8,
) !?Oid {
    const set = checks.settings(s, alloc);
    defer set.deinit(alloc);
    var ix = try verdict.Index.load(s, alloc);
    defer ix.deinit();

    const resolved = resolveSpecOrFail(io, alloc, w, s, spec, &ix, set);
    defer resolved.deinit(alloc);

    const m = switch (resolved.target) {
        .live => {
            try w.writeAll("@ is the live tree, not a change. save it first\n");
            return null;
        },
        .at => |at| at,
    };

    return history.changeOfMoment(s, alloc, &m.id, m.full_tree) catch {
        try w.print("{s}{s}{s} {s}{s}{s} is a captured moment, not a change\n", .{
            ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
        });
        try ui.hint(w, "a branch can only point at a change; `sdt rewind` moves the working tree to a moment");
        return null;
    };
}

/// Whether a rewrite's report puts the new tip's tree on disk, or leaves the
/// working tree exactly as the command found it.
const TreeAfter = enum { checkout, keep };

fn reportRewrite(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    before_tree: ?Oid,
    r: history.Result,
    what: []const u8,
    tree_after: TreeAfter,
) !void {
    const tip = s.readChange(r.new) catch {
        try w.print("{s} done\n", .{what});
        return;
    };
    defer object.freeChange(alloc, tip);

    if (tree_after == .checkout) {
        var work = try openWork(io);
        defer work.close(io);
        workspace.checkout(s, work, before_tree, tip.tree) catch {};
    }

    var buf: [Oid.len * 2]u8 = undefined;
    if (r.rewritten == 0) {
        try w.print("{s}{s}{s} {s}, now at {s}{s}{s}\n", .{
            ui.on(.green), ui.check, ui.off(), what, ui.on(.cyan), shortHex(r.new, &buf), ui.off(),
        });
    } else {
        try w.print("{s}{s}{s} {s}: {d} change(s) rewritten, now at {s}{s}{s}\n", .{
            ui.on(.green), ui.check,     ui.off(),              what,
            r.rewritten,   ui.on(.cyan), shortHex(r.new, &buf), ui.off(),
        });
    }
    if (!r.clean()) {
        try w.print("{d} path(s) came out conflicted, with both sides marked:\n", .{r.conflicts.len});
        for (r.conflicts) |p| try w.print("  ! {s}\n", .{p});
        try ui.hint(w, "fix the markers and `sdt save`, or `sdt undo` to put history back");
        return;
    }
    try ui.hint(w, "`sdt undo` puts the old history back");
}

fn reportHistoryError(w: *std.Io.Writer, e: anyerror, what: []const u8) !bool {
    switch (e) {
        replay.Error.MergeChangeNotReplayable => {
            try w.print("{s}{s}{s} that span contains a merge, so it cannot be replayed\n", .{
                ui.on(.red), ui.cross, ui.off(),
            });
            try ui.hint(w, "rewrite the changes on one side of the merge instead");
        },
        history.Error.UnbornBranch => try w.writeAll("nothing saved on this branch yet\n"),
        history.Error.NothingToDo => try w.print("nothing to {s}\n", .{what}),
        history.Error.OutOfRange => try w.writeAll("that is more history than this branch has\n"),
        history.Error.NotAChange => try w.writeAll("that ref is not a change on this branch\n"),
        history.Error.NotAPermutation => try w.writeAll("the order must list each position exactly once, starting at 1\n"),
        history.Error.NoSuchHunk => {
            try w.writeAll("that change does not have a hunk with that number\n");
            try ui.hint(w, "`sdt diff` numbers the hunks of each file from 1, top to bottom");
        },
        history.Error.BinaryHasNoHunks => {
            try w.writeAll("that file is binary, so it has no hunks to select\n");
            try ui.hint(w, "move the whole file instead: `sdt split <ref> -- <path>`");
        },
        history.Error.PathNotModified => {
            try w.writeAll("that path is not modified in place by this change, so it has no hunks\n");
            try ui.hint(w, "added and deleted files move whole: `sdt split <ref> -- <path>`");
        },
        else => return false,
    }
    return true;
}

fn cmdPoint(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt point <ref>\n");
        try ui.hint(w, "moves this branch's tip anywhere: `sdt point @~2`, `sdt point other-branch`");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "point");

    const target = (try resolveChangeOrFail(io, alloc, w, &s, rest[0])) orelse return;
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const before_tree = branches.headTree(&s);

    const r = history.point(&s, alloc, branch, target, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "point at")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, &s, before_tree, r, "moved the tip", .checkout);
}

fn cmdRebase(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt rebase <ref>\n");
        try ui.hint(w, "replays this branch's own changes onto <ref>, keeping their identities");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "rebase");

    const onto = (try resolveChangeOrFail(io, alloc, w, &s, rest[0])) orelse return;
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const before_tree = branches.headTree(&s);

    const r = history.rebase(&s, alloc, branch, onto, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "rebase")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, &s, before_tree, r, "rebased", .checkout);
}

fn cmdSquash(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "squash");

    const message = messageFlag(rest);
    const at = flagValue(rest, "--at", "--at");
    var count: usize = 2;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "-m") or eq(a, "--message") or eq(a, "--at")) {
            i += 1;
        } else if (a.len != 0 and a[0] != '-') {
            count = std.fmt.parseInt(usize, a, 10) catch count;
        }
    }

    const branch = try s.headBranch();
    defer alloc.free(branch);
    const end = if (at.len != 0)
        (try resolveChangeOrFail(io, alloc, w, &s, at)) orelse return
    else
        history.tipOf(&s, branch) catch {
            try w.writeAll("nothing saved on this branch yet\n");
            return;
        };
    const before_tree = branches.headTree(&s);

    const r = history.squash(&s, alloc, branch, end, count, message, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "squash")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, &s, before_tree, r, "squashed", .checkout);
}

/// Parse `1,3-5` into 1-based hunk numbers. Ranges are inclusive and a bare
/// number is a range of one.
fn parseHunkNumbers(alloc: std.mem.Allocator, text: []const u8, out: *std.ArrayList(usize)) !void {
    var it = std.mem.splitScalar(u8, text, ',');
    while (it.next()) |part| {
        if (part.len == 0) return error.BadHunkSelector;
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const lo = std.fmt.parseInt(usize, part[0..dash], 10) catch return error.BadHunkSelector;
            const hi = std.fmt.parseInt(usize, part[dash + 1 ..], 10) catch return error.BadHunkSelector;
            if (lo == 0 or hi < lo) return error.BadHunkSelector;
            var n = lo;
            while (n <= hi) : (n += 1) try out.append(alloc, n);
        } else {
            const n = std.fmt.parseInt(usize, part, 10) catch return error.BadHunkSelector;
            if (n == 0) return error.BadHunkSelector;
            try out.append(alloc, n);
        }
    }
    if (out.items.len == 0) return error.BadHunkSelector;
}

fn badHunkSelector(w: *std.Io.Writer, sel: []const u8) !void {
    try w.print("not a hunk selector: {s}\n", .{sel});
    try ui.hint(w, "the form is <path>:<n>, e.g. `--hunk src/a.zig:1,3-4`");
}

/// Parse one `<path>:<n[,n][,a-b]>` selector onto `out`. Returns false when the
/// selector was malformed, having already said so.
fn appendHunkSpec(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    sel: []const u8,
    out: *std.ArrayList(history.HunkSpec),
) !bool {
    const colon = std.mem.lastIndexOfScalar(u8, sel, ':') orelse 0;
    if (colon == 0 or colon + 1 == sel.len) {
        try badHunkSelector(w, sel);
        return false;
    }
    var numbers: std.ArrayList(usize) = .empty;
    errdefer numbers.deinit(alloc);
    parseHunkNumbers(alloc, sel[colon + 1 ..], &numbers) catch {
        numbers.deinit(alloc);
        try badHunkSelector(w, sel);
        return false;
    };
    try out.append(alloc, .{
        .path = sel[0..colon],
        .indices = try numbers.toOwnedSlice(alloc),
    });
    return true;
}

fn splitUsage(w: *std.Io.Writer) !void {
    try w.writeAll("usage: sdt split [ref] [-m msg] -- <paths>\n");
    try w.writeAll("       sdt split [ref] [-m msg] --hunk <path>:<n[,n][,a-b]> ...\n");
    try ui.hint(w, "the listed paths become the first change; everything else stays in the second");
    try ui.hint(w, "--hunk works within a file: `sdt split --hunk src/a.zig:1,3-4` takes those hunks only");
}

fn cmdSplit(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var spec: []const u8 = "";
    var message: []const u8 = "";
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(alloc);
    var hunks: std.ArrayList(history.HunkSpec) = .empty;
    defer {
        for (hunks.items) |h| alloc.free(h.indices);
        hunks.deinit(alloc);
    }

    var after_sep = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--")) {
            after_sep = true;
        } else if (eq(a, "-m") or eq(a, "--message")) {
            // Also after `--`: a message placed there used to be swallowed as a
            // pathspec, which silently split on a path nobody named.
            i += 1;
            if (i < rest.len) message = rest[i];
        } else if (after_sep) {
            try paths.append(alloc, a);
        } else if (eq(a, "--hunk") or eq(a, "-H")) {
            i += 1;
            if (i >= rest.len) {
                try splitUsage(w);
                return;
            }
            if (!try appendHunkSpec(alloc, w, rest[i], &hunks)) return;
        } else if (spec.len == 0 and a.len != 0 and a[0] != '-') {
            spec = a;
        }
    }

    if (paths.items.len != 0 and hunks.items.len != 0) {
        try w.writeAll("split takes paths or --hunk selectors, not both at once\n");
        try ui.hint(w, "run the path split first, then split the result by hunk");
        return;
    }
    if (paths.items.len == 0 and hunks.items.len == 0) {
        try splitUsage(w);
        return;
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "split");

    const branch = try s.headBranch();
    defer alloc.free(branch);
    const target = if (spec.len != 0)
        (try resolveChangeOrFail(io, alloc, w, &s, spec)) orelse return
    else
        history.tipOf(&s, branch) catch {
            try w.writeAll("nothing saved on this branch yet\n");
            return;
        };
    const before_tree = branches.headTree(&s);

    const attempt = if (hunks.items.len != 0)
        history.splitHunks(&s, alloc, branch, target, hunks.items, message, nowSeconds(io))
    else
        history.split(&s, alloc, branch, target, paths.items, message, nowSeconds(io));

    const r = attempt catch |e| {
        if (try reportHistoryError(w, e, "split")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, &s, before_tree, r, "split", .checkout);
}

fn cmdReorder(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(alloc);
    for (rest) |a| {
        if (a.len == 0 or a[0] == '-') continue;
        const n = std.fmt.parseInt(usize, a, 10) catch {
            try w.print("not a position: {s}\n", .{a});
            return;
        };
        try order.append(alloc, n);
    }
    if (order.items.len < 2) {
        try w.writeAll("usage: sdt reorder <order...>\n");
        try ui.hint(w, "`sdt reorder 2 1` swaps the last two changes; 1 is the oldest of the span");
        return;
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "reorder");

    const branch = try s.headBranch();
    defer alloc.free(branch);
    const before_tree = branches.headTree(&s);

    const r = history.reorder(&s, alloc, branch, order.items, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "reorder")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, &s, before_tree, r, "reordered", .checkout);
}

fn cmdGc(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
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
        try w.writeAll("usage: sdt completions <fish|zsh|bash>\n");
        return;
    }
    completions.run(rest[0], w) catch |e| switch (e) {
        error.UnknownShell => {},
        else => return e,
    };
}

fn cmdWhy(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt why <file>\n");
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
        try w.writeAll("usage: sdt config [--global] <key> [value]\n");
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
    resolveOps(alloc, &s);
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
    if (sync_blocked) try reportNotFastForward(w, git.at_risk.branch(), "sdt sync . --force");
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
fn configTruthy(s: *Store, alloc: std.mem.Allocator, key: []const u8) bool {
    const v = (config.get(s, alloc, key) catch return false) orelse return false;
    defer alloc.free(v);
    return eq(v, "true") or eq(v, "1") or eq(v, "yes") or eq(v, "on");
}

/// The gate: a red or ungraded tree does not leave this machine. A hollow green
/// passes and says so, because the warrant labels and never blocks.
fn gateOnGreen(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, s: *Store) !bool {
    const set = checks.settings(s, alloc);
    defer set.deinit(alloc);
    if (!set.enabled or !(set.has(.full) or set.has(.fast))) {
        try w.print("{s}{s}{s} no check configured, so nothing can be verified\n", .{
            ui.on(.red), ui.cross, ui.off(),
        });
        try ui.hint(w, "set one with `sdt config checks.full \"zig build test\"`, or pass `--no-require-green`");
        return false;
    }

    const all = try moment.readAll(s, alloc);
    defer moment.freeMoments(alloc, all);
    if (all.len == 0) {
        try w.print("{s}{s}{s} nothing has been captured, so nothing has been graded\n", .{
            ui.on(.red), ui.cross, ui.off(),
        });
        try ui.hint(w, "`sdt grade` grades the tree you have now");
        return false;
    }

    const head = all[all.len - 1];
    var ix = try verdict.Index.load(s, alloc);
    defer ix.deinit();
    const v = ix.best(
        head.full_tree,
        verdict.commandHash(set.command(.fast)),
        verdict.commandHash(set.command(.full)),
    ) orelse {
        try w.print("{s}{s}{s} this tree has never been graded\n", .{
            ui.on(.red), ui.cross, ui.off(),
        });
        try ui.hint(w, "`sdt grade` grades it; `sdt green` rewinds to the last state that passed");
        return false;
    };

    if (v.result != .green) {
        var id_buf: [16]u8 = undefined;
        try w.print("{s}{s}{s} this tree graded {s}\n", .{
            ui.on(.red), ui.cross, ui.off(), v.result.label(),
        });
        try warrant.render(w, head.shortId(&id_buf), v);
        try ui.hint(w, "`sdt green` rewinds to the last state that passed");
        return false;
    }

    var id_buf: [16]u8 = undefined;
    try warrant.render(w, head.shortId(&id_buf), v);
    if (v.isHollow()) {
        try ui.hint(w, "green, but the warrant says this green proves little; pushing anyway");
    }
    _ = io;
    return true;
}

// `sync.git` is enabled, mirror this save into the colocated `.git`. Best-effort.
fn maybeSyncGit(io: std.Io, alloc: std.mem.Allocator, s: *Store) void {
    std.Io.Dir.cwd().access(io, ".git", .{}) catch return;
    if (!configTruthy(s, alloc, "sync.git")) return;
    sync_blocked = false;
    git.syncColocated(s, ".") catch |e| {
        if (e == git.Error.NotFastForward) sync_blocked = true;
    };
}

// Set when the last save could not mirror into .git because doing so would have
// dropped git-side commits. The save itself still happened; only the mirror was
// held back, and the command that ran the save says so.
var sync_blocked: bool = false;

fn cmdDescribe(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
    const message = messageFlag(rest);
    if (message.len == 0) {
        try w.writeAll("usage: sdt desc -m \"message\" [--at <ref>]\n");
        try ui.hint(w, "--at renames a change further back, replaying everything after it");
        return;
    }
    const at = flagValue(rest, "--at", "--at");
    if (at.len != 0) return describeAt(io, alloc, w, &s, at, message);

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

/// Rename a change that is not the tip. Every descendant is replayed onto an
/// identical tree, so nothing but the message and the parent links move.
fn describeAt(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    at: []const u8,
    message: []const u8,
) !void {
    captureBefore(io, alloc, s);
    try autoSaveIfDirty(io, alloc, w, s, "describe");

    const target = (try resolveChangeOrFail(io, alloc, w, s, at)) orelse return;
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const before_tree = branches.headTree(s);

    const r = history.reword(s, alloc, branch, target, message, nowSeconds(io)) catch |e| {
        if (try reportHistoryError(w, e, "describe")) return;
        return e;
    };
    defer r.deinit(alloc);
    try reportRewrite(io, alloc, w, s, before_tree, r, "described", .checkout);
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

/// A file bigger than this is not scanned for conflict markers. Markers are a
/// text-file problem, and reading a large asset on every `status` would cost
/// more than it can ever find.
const conflict_scan_limit = 4 * 1024 * 1024;

/// Tracked files that currently hold conflict markers.
///
/// This looks at the files rather than at recorded state on purpose. A rebase
/// saves its conflicted result as a change, so by the time anyone runs `status`
/// there is no operation in progress to ask — and markers can also arrive from a
/// split, an amend, a git import, or a bad paste. Bytes on disk are the one
/// source that is true for all of them, and there is no state to go stale when
/// the rewrite is undone.
fn markedTrackedPaths(io: std.Io, alloc: std.mem.Allocator, s: *Store, work: std.Io.Dir) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| alloc.free(p);
        out.deinit(alloc);
    }

    const branch = s.headBranch() catch return out.toOwnedSlice(alloc);
    defer alloc.free(branch);
    if (!s.refExists(branch)) return out.toOwnedSlice(alloc);
    const tip = s.readRef(branch) catch return out.toOwnedSlice(alloc);
    const change = s.readChange(tip) catch return out.toOwnedSlice(alloc);
    defer object.freeChange(alloc, change);
    const tree = s.readTree(change.tree) catch return out.toOwnedSlice(alloc);
    defer object.freeTree(alloc, tree);

    for (tree.entries) |e| {
        if (e.mode == .symlink) continue;
        const st = work.statFile(io, e.path, .{}) catch continue;
        if (st.size > conflict_scan_limit) continue;
        const data = readWorkFile(io, work, e.path, alloc) catch continue;
        defer alloc.free(data);
        if (isBinary(data)) continue;
        if (!merge.hasConflictMarkers(data)) continue;
        try out.append(alloc, try alloc.dupe(u8, e.path));
    }
    return out.toOwnedSlice(alloc);
}

fn listed(paths: []const []const u8, p: []const u8) bool {
    for (paths) |x| {
        if (eq(x, p)) return true;
    }
    return false;
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
    // Safety rule, same reasoning as superposition below: a conflict a merge no
    // longer knows about is still a conflict, and shipping `<<<<<<< ours` is
    // worse than any cost of looking.
    const marked = try markedTrackedPaths(io, alloc, &s, work);
    defer {
        for (marked) |p| alloc.free(p);
        alloc.free(marked);
    }
    // Safety rule: a superposed path is never invisible. A file quietly holding
    // a second value is a real change to the mental model, so it is surfaced
    // here every single time rather than only when someone goes looking.
    const superposed = superpose.count(&s, alloc) catch 0;
    const diverged = divergence(alloc, &s);
    defer if (diverged) |v| v.deinit(alloc);

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
        try w.writeAll("],\"marked\":[");
        for (marked, 0..) |p, i| {
            if (i != 0) try w.writeByte(',');
            try writeJsonString(w, p);
        }
        try w.writeAll("],\"diverged\":[");
        if (diverged) |v| {
            var n: usize = 0;
            for (v.refs) |r| {
                if (!r.diverged()) continue;
                if (n != 0) try w.writeByte(',');
                n += 1;
                try w.writeAll("{\"branch\":");
                try writeJsonString(w, r.name);
                try w.print(",\"tips\":{d}}}", .{r.tips.len});
            }
        }
        try w.print("],\"superposed\":{d}}}\n", .{superposed});
        return;
    }

    if (superposed != 0) try superpose.statusLine(w, superposed);

    if (diverged) |v| {
        for (v.refs) |r| {
            if (!r.diverged()) continue;
            try w.print("{s}{s} branch {s} diverged: {d} tips{s}\n", .{
                ui.on(.yellow), ui.warn, r.name, r.tips.len, ui.off(),
            });
        }
        try ui.hint(w, "`sdt branch` lists every tip; `sdt point <ref>` keeps the one you want");
    }

    if (conflicts.len != 0) {
        try w.print("{s}{s} merge in progress: {d} unresolved conflict(s){s}\n", .{
            ui.on(.red), ui.warn, conflicts.len, ui.off(),
        });
        for (conflicts) |p| try w.print("  {s}{s}{s} {s}\n", .{ ui.on(.red), ui.warn, ui.off(), p });
        try ui.hint(w, "fix the markers then `sdt resolve <file>`, or `sdt resolve --abort`");
    }

    var unresolved: usize = 0;
    for (marked) |p| {
        if (listed(conflicts, p)) continue;
        unresolved += 1;
    }
    if (unresolved != 0) {
        try w.print("{s}{s} unresolved conflict in {d} saved file(s){s}\n", .{
            ui.on(.red), ui.warn, unresolved, ui.off(),
        });
        for (marked) |p| {
            if (listed(conflicts, p)) continue;
            try w.print("  {s}{s}{s} {s}\n", .{ ui.on(.red), ui.warn, ui.off(), p });
        }
        try ui.hint(w, "the markers are already inside the last saved change: fix them and `sdt save`");
        try ui.hint(w, "`sdt undo` puts the history back the way it was");
    }

    if (entries.len == 0) {
        if (conflicts.len == 0 and unresolved == 0 and superposed == 0 and diverged == null) {
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

fn cmdBranch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var deleting = false;
    var force = false;
    var name: []const u8 = "";
    for (rest) |a| {
        if (eq(a, "-d") or eq(a, "--delete")) {
            deleting = true;
        } else if (eq(a, "-D")) {
            deleting = true;
            force = true;
        } else if (eq(a, "-f") or eq(a, "--force")) {
            force = true;
        } else if (a.len != 0 and a[0] == '-') {
            try w.print("unknown option '{s}'\n", .{a});
            return;
        } else if (name.len == 0) {
            name = a;
        }
    }
    if (deleting or name.len != 0) return branchDelete(io, alloc, w, name, force, deleting);

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
    const diverged = divergence(alloc, &s);
    defer if (diverged) |v| v.deinit(alloc);

    var any_diverged = false;
    for (names) |n| {
        if (eq(n, cur)) {
            try w.print("{s}{s} {s}{s}\n", .{ ui.on(.cyan), ui.branch_mark, n, ui.off() });
        } else {
            try w.print("{s}{s}{s} {s}\n", .{ ui.on(.dim), ui.bullet, ui.off(), n });
        }
        const state = if (diverged) |v| v.find(n) else null;
        if (state) |r| {
            if (!r.diverged()) continue;
            any_diverged = true;
            const tip: Oid = s.readRef(n) catch Oid.zero();
            for (r.tips) |t| {
                var buf: [Oid.len * 2]u8 = undefined;
                const mark = if (t.eql(tip)) ui.arrow else " ";
                try w.print("    {s}{s} {s}{s}\n", .{
                    ui.on(.yellow), mark, shortHex(t, &buf), ui.off(),
                });
            }
        }
    }
    if (any_diverged) {
        try ui.hint(w, "more than one tip: `sdt point <ref>` keeps the one you want");
    }
}

/// Really delete a branch ref. `sdt export` publishes every branch it finds, so
/// a scratch branch that cannot be deleted is a scratch branch that ends up in
/// git forever; refusing to delete the current one, and refusing history no
/// other branch reaches unless forced, keeps that from becoming a way to lose
/// work instead.
fn branchDelete(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    name: []const u8,
    force: bool,
    deleting: bool,
) !void {
    if (!deleting or name.len == 0) {
        try w.writeAll("usage: sdt branch            (list)\n");
        try w.writeAll("       sdt branch -d <name>  (delete; -D deletes unmerged history too)\n");
        try ui.hint(w, "`sdt new <name>` is how you make one");
        return;
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);

    const tip = history.deleteBranch(&s, alloc, name, force, nowSeconds(io)) catch |e| switch (e) {
        history.Error.CurrentBranch => {
            try w.print("{s}{s}{s} {s} is the branch you are on\n", .{
                ui.on(.red), ui.cross, ui.off(), name,
            });
            try ui.hint(w, "`sdt switch <other>` first, then delete it");
            return;
        },
        history.Error.NoSuchBranch => {
            try w.print("no such branch: {s}\n", .{name});
            return;
        },
        history.Error.BranchNotMerged => {
            try w.print("{s}{s}{s} {s} holds changes no other branch reaches\n", .{
                ui.on(.red), ui.cross, ui.off(), name,
            });
            try ui.hint(w, "`sdt branch -D <name>` deletes it anyway; `sdt undo` puts it back");
            return;
        },
        else => return e,
    };

    var buf: [Oid.len * 2]u8 = undefined;
    try w.print("{s}{s}{s} deleted branch {s}{s}{s}, was at {s}{s}{s}\n", .{
        ui.on(.green), ui.check,            ui.off(),
        ui.on(.cyan),  name,                ui.off(),
        ui.on(.dim),   shortHex(tip, &buf), ui.off(),
    });
    try ui.hint(w, "`sdt undo` puts the branch back");
}

fn cmdNew(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt new <branch-name>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
    const name = rest[0];

    // `sdt new <name> @<moment>` turns a fork into a branch once you decide it
    // was worth keeping.
    if (rest.len >= 2 and revspec.looksLikeRevspec(rest[1])) {
        const set = checks.settings(&s, alloc);
        defer set.deinit(alloc);
        var ix = try verdict.Index.load(&s, alloc);
        defer ix.deinit();
        const resolved = resolveSpecOrFail(io, alloc, w, &s, rest[1], &ix, set);
        defer resolved.deinit(alloc);
        if (resolved.target == .live) {
            try w.writeAll("@ is the live tree; `sdt new <name>` already branches from here\n");
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
        try autoSaveIfDirty(io, alloc, w, &s, "new");
        var work2 = try openWork(io);
        defer work2.close(io);
        try branches.switchTo(&s, work2, name);
        try w.print("on new branch {s}, at that moment\n", .{name});
        return;
    }

    try autoSaveIfDirty(io, alloc, w, &s, "new");
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
        try w.writeAll("usage: sdt switch <branch-name>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);

    // Never lose work: auto-save the current tree before moving.
    try autoSaveIfDirty(io, alloc, w, &s, "switch");

    var work = try openWork(io);
    defer work.close(io);
    branches.switchTo(&s, work, rest[0]) catch |e| {
        try w.print("could not switch to {s}: {s}\n", .{ rest[0], @errorName(e) });
        return;
    };
    try w.print("switched to {s}\n", .{rest[0]});
}

fn cmdWork(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt work <new-dir>\n");
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

        const resolved = resolveSpecOrFail(io, alloc, w, &s, at, &ix, set);
        defer resolved.deinit(alloc);
        if (resolved.target == .live) {
            try w.writeAll("@ is the live tree; `sdt work <dir>` already gives you that\n");
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
        try w.writeAll("usage: sdt restore <file>\n");
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
        try w.writeAll("usage: sdt merge <branch>\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "merge");
    const into = try s.headBranch();
    defer alloc.free(into);
    const author = try config.author(&s, alloc);
    defer alloc.free(author);

    const before = s.readRef(into) catch Oid.zero();
    const before_tree = branches.headTree(&s);
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
    workspace.checkout(&s, work, before_tree, result.tree) catch {};

    if (result.conflicts.len == 0) {
        try w.print("merged {s} into {s}, clean\n", .{ rest[0], into });
    } else {
        merge.saveState(&s, rest[0], before, result.conflicts) catch {};
        try w.print("merged {s} into {s} with {d} conflict(s):\n", .{ rest[0], into, result.conflicts.len });
        for (result.conflicts) |p| try w.print("  ! {s}\n", .{p});
        try w.writeAll("fix the markers, then `sdt resolve <file>` each, or `sdt resolve --abort`\n");
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
    try w.print("serving superdetermine objects on port {d} (ctrl-c to stop)\n", .{port});
    try w.flush();
    try net.serve(&s, port);
}

fn cmdFetch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt fetch <src-repo-dir> [path-prefix]\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
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
        try ui.hint(w, "set one with `sdt config checks.full \"zig build test\"`");
    }
    try ui.hint(w, "ctrl-c to stop; `sdt grade --on` does this with no terminal and no daemon");
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
    const ctx = specContext(io, alloc, s, ix, set);
    return revspec.resolve(ctx, spec) catch |e| {
        switch (e) {
            revspec.Error.NotARevspec, revspec.Error.UnknownSelector => {
                // A colocated repo makes git revisions real addresses here, so
                // `origin/master` resolves to whatever sdt imported it as.
                switch (git.lookupGitRef(s, ".", spec)) {
                    .mapped => |o| return revspec.resolveChangeOid(ctx, o),
                    else => return e,
                }
            },
            else => return e,
        }
    };
}

fn specContext(
    io: std.Io,
    alloc: std.mem.Allocator,
    s: *Store,
    ix: *const verdict.Index,
    set: checks.Settings,
) revspec.Context {
    return .{
        .store = s,
        .alloc = alloc,
        .verdicts = ix,
        .command_fast = verdict.commandHash(set.command(.fast)),
        .command_full = verdict.commandHash(set.command(.full)),
        .now_ms = nowMillis(io),
    };
}

fn failSpec(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    spec: []const u8,
    ix: *const verdict.Index,
    set: checks.Settings,
    e: anyerror,
) noreturn {
    reportSpec(io, alloc, w, s, spec, ix, set, e) catch {};
    w.flush() catch {};
    std.process.exit(1);
}

fn reportSpec(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    spec: []const u8,
    ix: *const verdict.Index,
    set: checks.Settings,
    e: anyerror,
) !void {
    switch (e) {
        revspec.Error.NoSuchMoment => {
            try w.print("{s}{s}{s} nothing matches {s}{s}{s}\n", .{
                ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
            });
            if (std.mem.indexOf(u8, spec, "green") != null) {
                try ui.hint(w, "no state has been graded green yet; set `checks.full` and run `sdt grade`");
            }
        },
        revspec.Error.AmbiguousMoment => {
            try w.print("{s}{s}{s} {s}{s}{s} matches more than one state\n", .{
                ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
            });
            var found: std.ArrayList(revspec.Match) = .empty;
            defer found.deinit(alloc);
            revspec.matches(specContext(io, alloc, s, ix, set), spec, &found) catch {};
            for (found.items) |m| {
                const id = m.id();
                try w.print("  {s}{s}{s}  {s}{s}{s}\n", .{
                    ui.on(.cyan), id[0..@min(id.len, 12)], ui.off(),
                    ui.on(.dim),  @tagName(m.kind),        ui.off(),
                });
            }
            try ui.hint(w, "use more characters of the id");
        },
        revspec.Error.NotARevspec, revspec.Error.UnknownSelector => {
            switch (git.lookupGitRef(s, ".", spec)) {
                .unmapped => {
                    try w.print("{s}{s}{s} git knows {s}{s}{s}, but superdetermine has not imported it\n", .{
                        ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
                    });
                    try ui.hint(w, "`sdt pull` brings a remote branch in; `sdt import .` brings the whole colocated repo in");
                    return;
                },
                else => {},
            }
            try w.print("{s}{s}{s} not a ref: {s}{s}{s}\n", .{
                ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(),
            });
            try ui.hint(w, "refs are @green, @2h, @yesterday, @save, '@~1', a branch name, an imported git ref, or an id from `sdt log`");
        },
        else => {
            try w.print("{s}{s}{s} could not resolve {s}{s}{s}: {s}\n", .{
                ui.on(.red), ui.cross, ui.off(), ui.on(.bold), spec, ui.off(), @errorName(e),
            });
        },
    }
}

fn resolveSpecOrFail(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    spec: []const u8,
    ix: *const verdict.Index,
    set: checks.Settings,
) revspec.Resolved {
    return resolveSpec(io, alloc, s, spec, ix, set) catch |e|
        failSpec(io, alloc, w, s, spec, ix, set, e);
}

fn resolveRangeOrFail(
    io: std.Io,
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    spec: []const u8,
    ix: *const verdict.Index,
    set: checks.Settings,
) revspec.Range {
    return revspec.resolveRange(specContext(io, alloc, s, ix, set), spec) catch |e|
        failSpec(io, alloc, w, s, spec, ix, set, e);
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
        try ui.hint(w, "run `sdt grade --once`, or `sdt watch`, to start capturing");
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

    const resolved = resolveSpecOrFail(io, alloc, w, &s, spec, &ix, set);
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
    try ui.hint(w, "`sdt undo` puts it back; the state you left is still addressable");
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
        try w.writeAll("usage: sdt rewind <ref> [--dry-run] [-- <paths>]\n");
        try ui.hint(w, "try `sdt rewind @green`, `sdt rewind @2h`, or `sdt back`");
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

fn cmdGrade(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !u8 {
    var s = (try openRepo(io, alloc, w)) orelse return 0;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    const repo_abs = try work.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(repo_abs);

    var git_ref: []const u8 = "";
    var git_repo: []const u8 = "";
    var ref_tier: verdict.Tier = .full;
    var ref_json = false;
    var automated = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--json")) {
            ref_json = true;
        } else if (eq(a, "--once")) {
            automated = true;
        } else if (eq(a, "--fast")) {
            ref_tier = .fast;
        } else if (eq(a, "--full")) {
            ref_tier = .full;
        } else if (eq(a, "--repo")) {
            i += 1;
            if (i < rest.len) git_repo = rest[i];
        } else if (a.len != 0 and a[0] != '-' and git_ref.len == 0) {
            git_ref = a;
        }
    }
    if (git_ref.len != 0 or git_repo.len != 0) {
        return cmdGradeRef(
            alloc,
            w,
            &s,
            work,
            git_ref,
            if (git_repo.len != 0) git_repo else repo_abs,
            ref_tier,
            ref_json,
        );
    }

    for (rest) |a| {
        if (eq(a, "--install") or eq(a, "--on")) {
            const exe = update.selfExePathAlloc(alloc) catch |e| {
                try w.print("could not locate the gr binary: {s}\n", .{@errorName(e)});
                return 0;
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
                try ui.hint(w, "run `sdt watch` in a terminal instead; it does the same work");
                return 0;
            }
            try w.print("{s}yes{s}\n", .{ ui.on(.green), ui.off() });

            sched.install(io, alloc, exe, repo_abs, .{}) catch |e| {
                try w.print("{s}{s}{s} could not install the agent: {s}\n", .{
                    ui.on(.red), ui.cross, ui.off(), @errorName(e),
                });
                try ui.hint(w, "`sdt watch` does the same work in the foreground");
                return 0;
            };
            try w.print("{s}{s}{s} automatic grading is on for this repo\n", .{
                ui.on(.green), ui.check, ui.off(),
            });
            try ui.hint(w, "edits are captured and graded with no gr command and no resident process");
            return 0;
        }
        if (eq(a, "--uninstall") or eq(a, "--off")) {
            sched.uninstall(io, alloc, repo_abs) catch {};
            try w.writeAll("automatic grading off; `sdt grade` still works by hand\n");
            return 0;
        }
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);

    // Deliberately no early return when no check is configured. Capture and
    // grading are separate promises: capture must keep running so nothing is
    // ever unsaved, and this is the entry point the background agent calls, so
    // returning here would mean a repo without a check captures nothing at all.
    const rules = warrant.pathRules(&s, alloc);
    defer rules.deinit(alloc);

    const ctx = gradeContext(alloc, &s, work, set, rules);
    const r = try sched.tick(&s, work, ctx, momentSettings(&s, alloc), sched.settings(&s, alloc));

    const tier: verdict.Tier = if (set.has(.full)) .full else .fast;
    const inputs = try grade.currentInputs(ctx);
    defer inputs.deinit(alloc);
    var report = grade.Report{
        .status = .ungraded,
        .tier = tier,
        .ran = r.graded,
        .captured = r.captured,
        .cut = r.cut,
        .boundary = r.boundary,
        .skipped = r.skipped,
    };
    defer report.deinit(alloc);
    if (!set.enabled or !set.has(tier)) {
        report.status = .no_check;
    } else if (r.skipped == null) {
        const all = try moment.readAll(&s, alloc);
        defer moment.freeMoments(alloc, all);
        if (all.len != 0) {
            const head = all[all.len - 1];
            var ix = try verdict.Index.load(&s, alloc);
            defer ix.deinit();
            if (ix.get(.{
                .tree = head.full_tree,
                .tier = tier,
                .command = verdict.commandHash(set.command(tier)),
            })) |v| {
                report.v = v;
                report.status = grade.statusOf(v);
            }
            report.miss = grade.missReason(ctx, head.full_tree, tier, inputs) catch null;
        }
    }

    if (ref_json) {
        try report.writeJson(w);
        return if (automated) 0 else report.exitCode();
    }

    if (r.skipped) |why| {
        if (r.captured) try w.writeAll("captured a moment\n");
        try w.print("{s}skipped: {s}{s}\n", .{ ui.on(.dim), why, ui.off() });
        return if (automated) 0 else report.exitCode();
    }
    if (r.captured) try w.writeAll("captured a moment\n");
    if (!set.enabled) {
        if (r.captured) {
            try ui.hint(w, "no check configured, so nothing was graded");
            try ui.hint(w, "set one with `sdt config checks.full \"zig build test\"`");
        }
        return if (automated) 0 else report.exitCode();
    }
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
        try ui.hint(w, "`sdt green` rewinds to the last state that worked");
    }
    return if (automated) 0 else report.exitCode();
}

fn cmdGradeRef(
    alloc: std.mem.Allocator,
    w: *std.Io.Writer,
    s: *Store,
    work: std.Io.Dir,
    git_ref: []const u8,
    git_repo: []const u8,
    tier: verdict.Tier,
    as_json: bool,
) !u8 {
    const shown = if (git_ref.len != 0) git_ref else "HEAD";

    const set = checks.settings(s, alloc);
    defer set.deinit(alloc);
    if (!set.has(tier)) {
        try w.print("{s}{s}{s} no {s} check configured, so there is nothing to grade with\n", .{
            ui.on(.red), ui.cross, ui.off(), tier.label(),
        });
        try ui.hint(w, "set one with `sdt config checks.full \"zig build test\"`");
        return grade.exit_no_check;
    }

    const change_oid = git.importRefChange(
        s,
        git_repo,
        if (git_ref.len != 0) git_ref else null,
    ) catch |e| {
        try w.print("{s}{s}{s} could not resolve {s}{s}{s} in {s}: {s}\n", .{
            ui.on(.red),  ui.cross,      ui.off(),
            ui.on(.bold), shown,         ui.off(),
            git_repo,     @errorName(e),
        });
        try ui.hint(w, "pass `--repo <path>` for a git repo other than this one");
        return grade.exit_ungraded;
    };

    const rules = warrant.pathRules(s, alloc);
    defer rules.deinit(alloc);
    const ctx = gradeContext(alloc, s, work, set, rules);
    const v = try grade.gradeChange(ctx, change_oid, tier);

    var change_buf: [Oid.len * 2]u8 = undefined;
    var tree_buf: [Oid.len * 2]u8 = undefined;
    const change_hex = shortHex(change_oid, &change_buf);
    const tree_hex = shortHex(v.tree, &tree_buf);

    if (as_json) {
        try w.writeAll("{\"ref\":");
        try writeJsonString(w, shown);
        try w.writeAll(",\"repo\":");
        try writeJsonString(w, git_repo);
        try w.writeAll(",\"change\":");
        try writeJsonString(w, change_hex);
        try w.writeAll(",\"tree\":");
        try writeJsonString(w, tree_hex);
        try w.print(",\"tier\":\"{s}\",\"result\":\"{s}\",\"exit_code\":{d},\"duration_ms\":{d}", .{
            v.tier.label(), v.result.label(), v.exit_code, v.duration_ms,
        });
        try w.print(",\"independence\":\"{s}\",\"relevance_hit\":{d},\"relevance_total\":{d}", .{
            v.independence.label(), v.relevance_hit, v.relevance_total,
        });
        try w.print(",\"discrimination\":\"{s}\",\"hollow\":{s}", .{
            v.discrimination.label(), if (v.isHollow()) "true" else "false",
        });
        try w.print(",\"status\":\"{s}\",\"outcome\":\"{s}\"}}\n", .{
            @tagName(grade.statusOf(v)), v.outcome.label(),
        });
        return (grade.Report{ .status = grade.statusOf(v), .v = v, .tier = tier, .ran = 1 }).exitCode();
    }

    const colour: ui.Color = if (v.result == .green) .green else .red;
    try w.print("{s}{s}{s} {s}{s}{s} in {s}\n", .{
        ui.on(colour), if (v.result == .green) ui.check else ui.cross, ui.off(),
        ui.on(.bold),  shown,                                          ui.off(),
        git_repo,
    });
    try warrant.render(w, change_hex, v);
    if (v.result == .red) {
        try w.print("  exit {d} after {d}ms\n", .{ v.exit_code, v.duration_ms });
    }
    if (v.isHollow()) {
        try ui.hint(w, "green, but the warrant says this green proves little");
    } else if (v.independence == .unknown and v.discrimination == .unknown) {
        try ui.hint(w, "no attribution for these commits, so the warrant is unknown rather than clean");
    }
    return (grade.Report{ .status = grade.statusOf(v), .v = v, .tier = tier, .ran = 1 }).exitCode();
}

// Resolve a revision to the full git sha the remote knows it by. `lookupGitRef`
// answers in sdt ids and `branchTipHex` only takes a branch name, so the git
// side of the question is asked of git.
fn gitShaOf(alloc: std.mem.Allocator, repo_path: []const u8, spec: []const u8) !?[]u8 {
    const peeled = try std.fmt.allocPrint(alloc, "{s}^{{commit}}", .{spec});
    defer alloc.free(peeled);
    const out = proc.capture(
        alloc,
        &.{ "git", "-C", repo_path, "rev-parse", "--verify", "--quiet", peeled },
        "",
    ) catch return null;
    defer out.deinit(alloc);
    if (!out.ok()) return null;
    const sha = std.mem.trim(u8, out.stdout, " \t\r\n");
    if (!attest.isFullSha(sha)) return null;
    return try alloc.dupe(u8, sha);
}

/// Tell a git host what this tree's warrant says. The status is a label, not a
/// gate: whoever configures branch protection decides what to do with it, and
/// a hollow green posts as a success that says out loud that it is hollow.
/// Nothing here runs unless the user typed `sdt attest`.
fn cmdAttest(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !u8 {
    var s = (try openRepo(io, alloc, w)) orelse return 0;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    const repo_abs = try work.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(repo_abs);

    var git_ref: []const u8 = "HEAD";
    var remote_name: []const u8 = "origin";
    var tier: verdict.Tier = .full;
    var dry_run = false;
    var as_json = false;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (eq(a, "--dry-run")) {
            dry_run = true;
        } else if (eq(a, "--json")) {
            as_json = true;
        } else if (eq(a, "--fast")) {
            tier = .fast;
        } else if (eq(a, "--full")) {
            tier = .full;
        } else if (eq(a, "--remote")) {
            i += 1;
            if (i < rest.len) remote_name = rest[i];
        } else if (a.len != 0 and a[0] != '-') {
            git_ref = a;
        }
    }

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    if (!set.has(tier)) {
        try w.print("{s}{s}{s} no {s} check configured, so there is nothing to attest to\n", .{
            ui.on(.red), ui.cross, ui.off(), tier.label(),
        });
        try ui.hint(w, "set one with `sdt config checks.full \"zig build test\"`");
        return grade.exit_no_check;
    }

    const sha = (try gitShaOf(alloc, repo_abs, git_ref)) orelse {
        try w.print("{s}{s}{s} could not resolve {s}{s}{s} to a git commit here\n", .{
            ui.on(.red),  ui.cross, ui.off(),
            ui.on(.bold), git_ref,  ui.off(),
        });
        try ui.hint(w, "a status attaches to a git sha, so the change has to exist in .git first");
        return grade.exit_ungraded;
    };
    defer alloc.free(sha);

    const remote_url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}'. pass `--remote <name>`, or set it in git\n", .{remote_name});
        return grade.exit_ungraded;
    };
    defer alloc.free(remote_url);

    const target = (try attest.targetFromRemote(alloc, remote_url)) orelse {
        try w.print("{s}{s}{s} remote '{s}' is not a hosted repository, so there is nowhere to post\n", .{
            ui.on(.red), ui.cross, ui.off(), remote_name,
        });
        return grade.exit_ungraded;
    };
    defer target.deinit(alloc);

    const change_oid = git.importRefChange(&s, repo_abs, git_ref) catch |e| {
        try w.print("{s}{s}{s} could not read {s}{s}{s} out of git: {s}\n", .{
            ui.on(.red),   ui.cross, ui.off(),
            ui.on(.bold),  git_ref,  ui.off(),
            @errorName(e),
        });
        return grade.exit_ungraded;
    };

    const change = try s.readChange(change_oid);
    defer object.freeChange(alloc, change);

    var ix = try verdict.Index.load(&s, alloc);
    defer ix.deinit();
    const cached = ix.best(
        change.tree,
        verdict.commandHash(set.command(.fast)),
        verdict.commandHash(set.command(.full)),
    );

    const v = cached orelse blk: {
        const rules = warrant.pathRules(&s, alloc);
        defer rules.deinit(alloc);
        const ctx = gradeContext(alloc, &s, work, set, rules);
        break :blk try grade.gradeChange(ctx, change_oid, tier);
    };

    var desc_buf: [attest.max_description]u8 = undefined;
    const description = attest.describe(&desc_buf, v);
    var ctx_buf: [32]u8 = undefined;
    const context = attest.contextFor(&ctx_buf, v.tier);
    const state = attest.stateFor(v);

    const url = attest.statusUrl(alloc, target, sha) catch {
        try w.print("{s}{s}{s} {s} is not a full git sha\n", .{ ui.on(.red), ui.cross, ui.off(), sha });
        return grade.exit_ungraded;
    };
    defer alloc.free(url);

    const exit_result: u8 = if (v.result == .green) grade.exit_green else grade.exit_red;

    if (dry_run) {
        if (as_json) {
            try attestJson(w, url, context, state, description, v, null);
        } else {
            try w.print("{s}would POST{s} {s}\n", .{ ui.on(.dim), ui.off(), url });
            try w.print("  {s}{s}{s}  {s}  {s}\n", .{
                ui.on(.cyan), context, ui.off(), state.label(), description,
            });
        }
        return exit_result;
    }

    const tok = attest.envToken() orelse {
        try w.print("{s}{s}{s} no token, so nothing was sent\n", .{ ui.on(.red), ui.cross, ui.off() });
        try ui.hint(w, "set SDT_GITHUB_TOKEN (or GITHUB_TOKEN) to a token with `repo:status`; `--dry-run` shows what would go");
        return attest.exit_no_token;
    };
    const token = std.mem.span(tok);
    if (token.len == 0) {
        try w.print("{s}{s}{s} the token in the environment is empty, so nothing was sent\n", .{
            ui.on(.red), ui.cross, ui.off(),
        });
        return attest.exit_no_token;
    }

    const body = try attest.buildBody(alloc, state, context, description);
    defer alloc.free(body);

    const code = attest.post(alloc, url, token, body) catch |e| {
        try w.print("{s}{s}{s} could not reach {s}: {s}\n", .{
            ui.on(.red), ui.cross, ui.off(), target.api_base, @errorName(e),
        });
        return attest.exit_network;
    };
    if (code < 200 or code >= 300) {
        try w.print("{s}{s}{s} {s} refused the status (HTTP {d})\n", .{
            ui.on(.red), ui.cross, ui.off(), target.api_base, code,
        });
        try ui.hint(w, "the token needs `repo:status` here, and the commit has to be pushed already");
        return attest.exit_network;
    }

    if (as_json) {
        try attestJson(w, url, context, state, description, v, code);
        return exit_result;
    }

    const colour: ui.Color = if (v.result == .green) .green else .red;
    try w.print("{s}{s}{s} {s}{s}{s} on {s}{s}{s}\n", .{
        ui.on(colour), if (v.result == .green) ui.check else ui.cross, ui.off(),
        ui.on(.cyan),  context,                                        ui.off(),
        ui.on(.bold),  sha[0..12],                                     ui.off(),
    });
    try w.print("  {s}\n", .{description});
    if (v.isHollow()) {
        try ui.hint(w, "posted as a success, and the description says the green proves little");
    }
    return exit_result;
}

fn attestJson(
    w: *std.Io.Writer,
    url: []const u8,
    context: []const u8,
    state: attest.State,
    description: []const u8,
    v: verdict.Verdict,
    code: ?u16,
) !void {
    try w.writeAll("{\"url\":");
    try writeJsonString(w, url);
    try w.writeAll(",\"context\":");
    try writeJsonString(w, context);
    try w.print(",\"state\":\"{s}\",\"description\":", .{state.label()});
    try writeJsonString(w, description);
    try w.print(",\"result\":\"{s}\",\"tier\":\"{s}\",\"hollow\":{s},\"http_status\":", .{
        v.result.label(), v.tier.label(), if (v.isHollow()) "true" else "false",
    });
    if (code) |c| {
        try w.print("{d}}}\n", .{c});
    } else {
        try w.writeAll("null}\n");
    }
}

fn cmdDoctor(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    try w.print("{s}superdetermine doctor{s}\n\n", .{ ui.on(.bold), ui.off() });

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
        .not_installed => "off (`sdt grade --on`, or run `sdt watch`)",
        .unsupported => "not available here; use `sdt watch` in a terminal",
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

    const op_heads = opdag.heads(&s, alloc) catch try alloc.alloc(Oid, 0);
    defer alloc.free(op_heads);
    try w.print("  op-log       {d} head{s}\n", .{ op_heads.len, if (op_heads.len == 1) "" else "s" });
    if (divergence(alloc, &s)) |v| {
        defer v.deinit(alloc);
        for (v.refs) |r| {
            if (!r.diverged()) continue;
            try w.print("               {s}{s} branch {s} diverged: {d} tips{s}\n", .{
                ui.on(.yellow), ui.warn, r.name, r.tips.len, ui.off(),
            });
        }
        try ui.hint(w, "               `sdt branch` lists every tip; `sdt point <ref>` keeps one");
    }
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
        const range = resolveRangeOrFail(io, alloc, w, &s, spec, &ix, set);
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

    // renderStatus already names the path, so the caller must not repeat it.
    for (items) |sp| {
        if (rest.len != 0 and !eq(rest[0], sp.path)) continue;
        try superpose.renderStatus(w, &.{sp}, null);
    }
    try ui.hint(w, "`sdt collapse <path> A` keeps one; the other is never deleted");
}

fn cmdCollapse(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt collapse <path> <A|B|--greenest|--edit>\n");
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
    // Accurate rather than flattering: undo puts the file back, but the path
    // does not become superposed again. Nothing is lost either way, because the
    // losing candidate is still a blob in the store.
    try ui.hint(w, "`sdt undo` puts the file back; the losing version stays in the store");
}

fn cmdNote(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 2) {
        try w.writeAll("usage: sdt note <file>:<line> <text>\n");
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

fn resolveOps(alloc: std.mem.Allocator, s: *Store) void {
    _ = opdag.resolve(s, alloc) catch {};
}

fn divergence(alloc: std.mem.Allocator, s: *Store) ?opdag.View {
    const hs = opdag.heads(s, alloc) catch return null;
    const n = hs.len;
    alloc.free(hs);
    if (n == 0) return null;

    var view = opdag.currentView(s, alloc) catch return null;
    if (!view.diverged()) {
        view.deinit(alloc);
        return null;
    }
    return view;
}

/// Capture the working tree before a command that will change it.
///
/// Not used by `save`: a save already writes an addressable change, so
/// capturing first would walk and hash the whole tree twice for nothing.
///
/// Every mutating command is a defensive capture point: whatever the command
/// then does, the state it was asked to leave stays addressable as a moment, so
/// `sdt back` and `@~1` reach it even if the command itself has no undo of its
/// own. Failure is deliberately silent — a capture that cannot happen must
/// never stop the command the user actually asked for.
fn captureBefore(io: std.Io, alloc: std.mem.Allocator, s: *Store) void {
    resolveOps(alloc, s);
    var work = openWork(io) catch return;
    defer work.close(io);
    const r = moment.capture(s, work, .command, momentSettings(s, alloc)) catch return;
    if (r == .captured) alloc.free(r.captured.branch);
}

fn cmdUndo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);
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
    resolveOps(alloc, &s);
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
    var force = false;
    var target_opt: ?[]const u8 = null;
    var branch_opt: ?[]const u8 = null;
    var gi: usize = 0;
    while (gi < rest.len) : (gi += 1) {
        const a = rest[gi];
        if (eq(a, "-f") or eq(a, "--force")) {
            force = true;
        } else if (eq(a, "--branch")) {
            gi += 1;
            if (gi < rest.len) branch_opt = rest[gi];
        } else if (a.len != 0 and a[0] == '-') {
            try w.print("unknown option '{s}'\n", .{a});
            return;
        } else if (target_opt == null) {
            target_opt = a;
        } else if (branch_opt == null) {
            branch_opt = a;
        }
    }
    const target = target_opt orelse {
        try w.writeAll("usage: sdt <import|export|sync> <path> [branch] [--force]\n");
        return;
    };
    if (force and op == .import) {
        try w.writeAll("--force applies to export and sync, not import\n");
        return;
    }
    if (branch_opt != null and op == .import) {
        try w.writeAll("a branch argument applies to export and sync, not import\n");
        return;
    }
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);

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
                try ui.hint(w, "`sdt super` lists them; `sdt collapse <path> <A|B>` picks one");
                return;
            }
            if (branch_opt) |b| {
                git.exportHeadToForced(&s, target, b, force) catch |e| {
                    if (e == git.Error.NotFastForward) {
                        try reportNotFastForward(w, git.at_risk.branch(), "sdt export <path> --force");
                        return;
                    }
                    try w.writeAll("git export failed\n");
                    try reportGitError(w);
                    return;
                };
                if (force) {
                    try w.print("exported superdetermine HEAD to git branch {s} at {s}, replacing what was there\n", .{ b, target });
                } else {
                    try w.print("exported superdetermine HEAD to git branch {s} at {s}\n", .{ b, target });
                }
            } else {
                git.exportAllForced(&s, target, force) catch |e| {
                    if (e == git.Error.NotFastForward) {
                        try reportNotFastForward(w, git.at_risk.branch(), "sdt export <path> --force");
                        return;
                    }
                    try w.writeAll("git export failed\n");
                    try reportGitError(w);
                    return;
                };
                if (force) {
                    try w.print("exported superdetermine (full history, all branches + tags) to git at {s}, replacing what was there\n", .{target});
                } else {
                    try w.print("exported superdetermine (full history, all branches + tags) to git at {s}\n", .{target});
                }
            }
        },
        .sync => {
            git.syncColocatedForced(&s, target, branch_opt, force) catch |e| {
                if (e == git.Error.NotFastForward) {
                    try reportNotFastForward(w, git.at_risk.branch(), "sdt sync <path> --force");
                    return;
                }
                try w.writeAll("sync failed\n");
                try reportGitError(w);
                return;
            };
            if (force) {
                try w.print("synced superdetermine HEAD into .git at {s}, replacing what was there\n", .{target});
            } else {
                try w.print("synced superdetermine HEAD into .git at {s}\n", .{target});
            }
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

// The branch a colocated .git is on (from .git/HEAD), so `sdt push` targets the
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

// Print whatever libgit2 (or sdt) said about the last failure. Silence is worse
// than a raw message: it leaves the user with nothing to act on.
fn reportGitError(w: *std.Io.Writer) !void {
    const msg = git.lastError();
    if (msg.len == 0) return;
    try w.print("  {s}{s}{s}\n", .{ ui.on(.dim), msg, ui.off() });
}

// Name the commits that would have been dropped. The branch is left untouched.
fn reportNotFastForward(w: *std.Io.Writer, branch: []const u8, remedy: []const u8) !void {
    const r = &git.at_risk;
    try w.print("{s}{s}{s} refusing to move {s}{s}{s} in .git: {d} commit{s} there {s} not in superdetermine\n", .{
        ui.on(.red),  ui.cross,                      ui.off(),
        ui.on(.bold), branch,                        ui.off(),
        r.total,      if (r.total == 1) "" else "s", if (r.total == 1) "is" else "are",
    });
    var i: usize = 0;
    while (i < r.shown) : (i += 1) {
        const id = r.id(i);
        try w.print("  {s}{s}{s}  {s}\n", .{ ui.on(.cyan), id[0..12], ui.off(), r.subject(i) });
    }
    if (r.total > r.shown) try w.print("  {s}... and {d} more{s}\n", .{ ui.on(.dim), r.total - r.shown, ui.off() });
    try w.print("  {s}hint:{s} `sdt pull` brings them in; `{s}` drops them on purpose\n", .{ ui.on(.dim), ui.off(), remedy });
}

fn cmdPush(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    resolveOps(alloc, &s);

    // Positional args are remote then branch; -f/--force is a flag anywhere.
    var force = false;
    var verbose = false;
    var require_green = configTruthy(&s, alloc, "push.require_green");
    var pos: [2][]const u8 = undefined;
    var np: usize = 0;
    for (rest) |a| {
        if (eq(a, "-f") or eq(a, "--force")) {
            force = true;
        } else if (eq(a, "-v") or eq(a, "--verbose")) {
            verbose = true;
        } else if (eq(a, "--require-green")) {
            require_green = true;
        } else if (eq(a, "--no-require-green")) {
            require_green = false;
        } else if (a.len != 0 and a[0] == '-') {
            try w.print("unknown option '{s}'\n", .{a});
            return;
        } else if (np < 2) {
            pos[np] = a;
            np += 1;
        }
    }
    if (require_green and !(try gateOnGreen(io, alloc, w, &s))) return;
    const remote_name = if (np >= 1) pos[0] else "origin";
    const url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}'. pass a URL, or set it in git or `sdt config remote.{s}.url`\n", .{ remote_name, remote_name });
        return;
    };
    defer alloc.free(url);
    const branch = try targetBranch(io, alloc, &s, if (np >= 2) pos[1] else null);
    defer alloc.free(branch);

    // If a git repo is colocated here, push IT directly so local .git and the
    // remote stay identical. Mirror the saved states onto the target branch
    // first: dual-write is opt-in, so without this a push of an unmoved ref
    // succeeds and reports success while leaving every save behind. Otherwise
    // synthesize a history in the mirror and push that.
    const colocated = if (std.Io.Dir.cwd().access(io, ".git", .{})) |_| true else |_| false;
    if (colocated) {
        const before = git.branchTipHex(&s, ".", branch);
        git.syncColocatedForced(&s, ".", branch, force) catch |e| {
            if (e == git.Error.NotFastForward) {
                try reportNotFastForward(w, branch, "sdt push --force");
            } else {
                try w.print("cannot mirror the saved states onto {s} in .git, so nothing was pushed\n", .{branch});
                try reportGitError(w);
            }
            return;
        };
        const after = git.branchTipHex(&s, ".", branch);
        git.pushColocated(&s, ".", url, branch, force) catch {
            try w.print("push to {s} failed (diverged? try `sdt push --force`; or auth/URL)\n", .{remote_name});
            try reportGitError(w);
            return;
        };
        const moved = if (before) |b| if (after) |a| !eq(&b, &a) else false else after != null;
        if (moved) {
            if (after) |a| try w.print("mirrored {s} into .git at {s}\n", .{ branch, a[0..12] });
        }
    } else {
        git.pushRemote(&s, url, branch) catch |e| {
            if (e == git.Error.NotFastForward) {
                try reportNotFastForward(w, branch, "sdt push --force");
            } else {
                try w.print("push to {s} failed (auth? or check the URL)\n", .{remote_name});
                try reportGitError(w);
            }
            return;
        };
    }
    try w.print("pushed {s} → {s} ({s})\n", .{ branch, remote_name, url });
}

// The sdt ref the fetched remote history lands on, so a pull never overwrites
// the local branch before the two have been reconciled.
const pull_ref = "sdt-remote";

fn cmdPull(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    captureBefore(io, alloc, &s);
    try autoSaveIfDirty(io, alloc, w, &s, "pull");

    var pos: [2][]const u8 = undefined;
    var np: usize = 0;
    for (rest) |a| {
        if (eq(a, "-v") or eq(a, "--verbose")) {
            continue;
        } else if (a.len != 0 and a[0] == '-') {
            try w.print("unknown option '{s}'\n", .{a});
            return;
        } else if (np < 2) {
            pos[np] = a;
            np += 1;
        }
    }

    const remote_name = if (np >= 1) pos[0] else "origin";
    const url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}'. pass a URL, or set it in git or `sdt config remote.{s}.url`\n", .{ remote_name, remote_name });
        return;
    };
    defer alloc.free(url);

    const owned_branch: ?[]u8 = if (np >= 2) null else colocatedGitBranch(io, alloc);
    defer if (owned_branch) |b| alloc.free(b);
    const want_branch: ?[]const u8 = if (np >= 2) pos[1] else owned_branch;

    const local = try s.headBranch();
    defer alloc.free(local);
    const had_local = s.refExists(local);
    const before = if (had_local) try s.readRef(local) else Oid.zero();

    var fetched = git.fetchRemote(&s, url, want_branch, pull_ref) catch |e| {
        try w.print("pull from {s} failed: {s}\n", .{ remote_name, @errorName(e) });
        try reportGitError(w);
        return;
    };
    defer fetched.deinit(alloc);

    if (!had_local) {
        try s.updateRef(local, fetched.tip);
        try checkoutTree(io, alloc, &s, before, fetched.tip);
        try w.print("pulled {s} from {s} ({s})\n", .{ fetched.branch, remote_name, url });
        return;
    }
    if (before.eql(fetched.tip)) {
        try w.print("already up to date with {s}/{s}\n", .{ remote_name, fetched.branch });
        return;
    }

    const base = merge.commonAncestor(&s, alloc, before, fetched.tip) catch null;
    if (base) |b| {
        if (b.eql(fetched.tip)) {
            try w.print("already up to date with {s}/{s}\n", .{ remote_name, fetched.branch });
            return;
        }
    }
    const fast_forward = if (base) |b| b.eql(before) else false;
    if (fast_forward) {
        try s.updateRef(local, fetched.tip);
        oplog.record(&s, .{ .kind = .import, .branch = local, .prev = before, .new = fetched.tip, .timestamp = nowSeconds(io) }) catch {};
        try checkoutTree(io, alloc, &s, before, fetched.tip);
        try w.print("fast-forwarded {s} to {s}/{s}\n", .{ local, remote_name, fetched.branch });
        return;
    }

    const author = try config.author(&s, alloc);
    defer alloc.free(author);
    const before_tree = branches.headTree(&s);
    const result = merge.merge(&s, alloc, local, pull_ref, author, nowSeconds(io)) catch |e| {
        try w.print("pull from {s} failed to merge: {s}\n", .{ remote_name, @errorName(e) });
        return;
    };
    defer merge.freeMergeResult(alloc, result);
    const after = s.readRef(local) catch before;
    oplog.record(&s, .{ .kind = .other, .branch = local, .prev = before, .new = after, .timestamp = nowSeconds(io) }) catch {};

    {
        var work = try openWork(io);
        defer work.close(io);
        workspace.checkout(&s, work, before_tree, result.tree) catch {};
    }

    if (result.conflicts.len == 0) {
        try w.print("merged {s}/{s} into {s}, clean\n", .{ remote_name, fetched.branch, local });
        return;
    }
    merge.saveState(&s, pull_ref, before, result.conflicts) catch {};
    try w.print("merged {s}/{s} into {s} with {d} conflict(s):\n", .{ remote_name, fetched.branch, local, result.conflicts.len });
    for (result.conflicts) |p| try w.print("  ! {s}\n", .{p});
    try w.writeAll("fix the markers, then `sdt resolve <file>` each, or `sdt resolve --abort`\n");
}

fn checkoutTree(io: std.Io, alloc: std.mem.Allocator, s: *Store, from: Oid, to: Oid) !void {
    _ = alloc;
    const to_change = s.readChange(to) catch return;
    defer object.freeChange(s.alloc, to_change);
    var from_tree: ?Oid = null;
    if (!from.eql(Oid.zero())) {
        if (s.readChange(from)) |fc| {
            defer object.freeChange(s.alloc, fc);
            from_tree = fc.tree;
        } else |_| {}
    }
    var work = try openWork(io);
    defer work.close(io);
    workspace.checkout(s, work, from_tree, to_change.tree) catch {};
}

fn defaultCloneDir(src: []const u8) ?[]const u8 {
    var t = src;
    if (std.mem.indexOfScalar(u8, t, '#')) |c| t = t[0..c];
    if (std.mem.indexOfScalar(u8, t, '?')) |c| t = t[0..c];
    while (t.len > 0 and (t[t.len - 1] == '/' or t[t.len - 1] == '\\')) t = t[0 .. t.len - 1];
    if (std.mem.endsWith(u8, t, ".git")) t = t[0 .. t.len - ".git".len];
    if (std.mem.endsWith(u8, t, ".bundle")) t = t[0 .. t.len - ".bundle".len];
    while (t.len > 0 and (t[t.len - 1] == '/' or t[t.len - 1] == '\\')) t = t[0 .. t.len - 1];
    if (std.mem.lastIndexOfAny(u8, t, "/\\:")) |c| t = t[c + 1 ..];
    if (t.len == 0 or eq(t, ".") or eq(t, "..")) return null;
    return t;
}

fn cmdClone(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1) {
        try w.writeAll("usage: sdt clone <git-src|share-url|bundle#k=...> [dir]\n");
        return;
    }
    const into = if (rest.len >= 2) rest[1] else defaultCloneDir(rest[0]) orelse {
        try w.print("cannot tell what to name the directory for {s}. pass one: sdt clone <src> <dir>\n", .{rest[0]});
        return;
    };
    if (std.mem.indexOf(u8, rest[0], "#k=") != null) {
        return cloneShare(io, alloc, w, rest[0], into);
    }
    // Create the destination as a superdetermine repo, then clone git into it.
    git.cloneGitOnly(alloc, rest[0], into) catch {
        try w.print("clone failed. check the URL, your access, and that {s} is empty\n", .{into});
        return;
    };
    var dest = try std.Io.Dir.cwd().openDir(io, into, .{});
    defer dest.close(io);
    var s = Store.init(io, alloc, dest) catch |e| switch (e) {
        Store.Error.RepoExists => try Store.open(io, alloc, dest),
        else => return e,
    };
    defer s.deinit();
    git.importAll(&s, into) catch {
        try w.writeAll("cloned, but importing the git history failed\n");
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
        \\usage: sdt send                    hand it to someone on this network
        \\       sdt send --file <path>      one sealed file, no network at all
        \\       sdt send --link <dir>       static files you upload anywhere
        \\       sdt send --relay <host:port>  across the internet, via a relay
        \\
        \\       sdt get <code | url | file>   the other side of all of these
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
    try w.print("  sdt get {s}\n\n", .{code});
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
    try w.print("open it with:  sdt get '{s}{s}'\n", .{ path, url[frag..] });
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
    try w.print("  sdt get {s} --relay {s}:{d}\n\n", .{ code, host, port });
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
    try ui.hint(w, "start one with `sdt relay`, or use `sdt send --file` instead");
}

fn looksLikeCode(text: []const u8) bool {
    _ = wormhole.Code.parse(text) catch return false;
    return true;
}

fn cmdGet(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len < 1 or eq(rest[0], "-h") or eq(rest[0], "--help")) {
        try w.writeAll("usage: sdt get <code | url | file> [dir]\n");
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
            try ui.hint(w, "same wifi? otherwise ask them for `sdt send --file`, or pass --relay host:port");
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
            try w.writeAll("that code is used up. generate a fresh one with `sdt send`.\n");
        },
        wormhole.Error.BadCode => try w.writeAll("that does not look like a gr code\n"),
        error.EndOfStream, error.ReadFailed, error.WriteFailed => {
            try w.writeAll("the peer hung up before the transfer, usually a mistyped code.\n");
            try ui.hint(w, "nothing was sent. run `sdt send` again for a fresh one.");
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
    try w.writeAll("any sealed values are still sealed. `sdt unseal` needs a key you were not given.\n");
}

fn sealUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: sdt seal <path>       start sealing a file (creates .grsealed)
        \\       sdt seal             re-seal every tracked path now
        \\       sdt seal status      show sealed paths and who can read them
        \\       sdt unseal           write the plaintext files back out
        \\       sdt rotate           new repo key, re-wrapped to every member
        \\
    );
}

fn keyUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: sdt key new                 create your keypair
        \\       sdt key show                print your public key (share this)
        \\       sdt key add <name> <pubkey> grant someone access to the secrets
        \\       sdt key remove <name>       revoke (then `sdt rotate`)
        \\       sdt key list                who can read the sealed values
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
        try w.print("nothing is sealed here yet (run `sdt seal <path>`)\n", .{});
        return null;
    };
}

fn requireIdentity(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !?seal.Identity {
    return (try keyring.loadIdentity(io, alloc)) orelse {
        try w.print("{s}{s}{s} no keypair yet. run {s}sdt key new{s}\n", .{ ui.on(.red), ui.cross, ui.off(), ui.on(.cyan), ui.off() });
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
        try w.writeAll("run `sdt rotate`, then rotate the underlying secrets themselves\n");
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
            if (!present) try ui.hint(w, "      no local plaintext. run `sdt unseal`");
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
            try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `sdt key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
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
        try w.writeAll("nothing is sealed here yet (run `sdt seal <path>`)\n");
        return;
    }
    if (!plan.have_key) {
        try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `sdt key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
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
            try w.writeAll("nothing is sealed here yet (run `sdt seal <path>`)\n");
            return;
        },
        seal.Error.NotAMember => {
            try w.print("{s}{s}{s} you cannot read this repo's secrets. ask a member to `sdt key add` you\n", .{ ui.on(.red), ui.cross, ui.off() });
            try w.writeAll("(`sdt key show` prints the public key they need)\n");
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
    _ = opdag;
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

extern "c" fn chdir(path: [*:0]const u8) c_int;

test "openWorkFrom finds the repo root from a nested subdirectory" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/native/deep");
    var root = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer root.close(io);
    var s = try Store.init(io, alloc, root);
    defer s.deinit();
    try root.writeFile(io, .{ .sub_path = "top.txt", .data = "root file" });

    var nested = try tmp.dir.openDir(io, "repo/native/deep", .{ .iterate = true });
    defer nested.close(io);

    var work = try openWorkFrom(io, nested);
    defer work.close(io);

    const got = try work.readFileAlloc(io, "top.txt", alloc, .unlimited);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("root file", got);
}

test "a checkout run from a nested subdirectory writes to the repo root" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo/native");
    var root = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer root.close(io);
    var s = try Store.init(io, alloc, root);
    defer s.deinit();

    try root.writeFile(io, .{ .sub_path = "native/lib.zig", .data = "v1" });
    _ = try workspace.snapshot(&s, root, "Nico <n@x>", "main", 1_700_000_000);

    try branches.create(&s, "side");
    try branches.switchTo(&s, root, "side");
    try root.writeFile(io, .{ .sub_path = "native/lib.zig", .data = "v2" });
    _ = try workspace.snapshot(&s, root, "Nico <n@x>", "side", 1_700_000_001);

    const before_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(before_path);
    const before = try alloc.dupeZ(u8, before_path);
    defer alloc.free(before);
    const nested_path = try tmp.dir.realPathFileAlloc(io, "repo/native", alloc);
    defer alloc.free(nested_path);
    const nested_abs = try alloc.dupeZ(u8, nested_path);
    defer alloc.free(nested_abs);

    try std.testing.expectEqual(@as(c_int, 0), chdir(nested_abs.ptr));
    defer _ = chdir(before.ptr);

    var work = try openWork(io);
    defer work.close(io);
    try branches.switchTo(&s, work, "main");

    const got = try root.readFileAlloc(io, "native/lib.zig", alloc, .unlimited);
    defer alloc.free(got);
    try std.testing.expectEqualStrings("v1", got);
    try std.testing.expectError(error.FileNotFound, root.access(io, "native/native", .{}));
    try std.testing.expectError(error.FileNotFound, root.access(io, "native/repo", .{}));
}

fn singleTipView(alloc: std.mem.Allocator, name: []const u8, tip: Oid) !opdag.View {
    const refs = try alloc.alloc(opdag.RefState, 1);
    errdefer alloc.free(refs);
    const tips = try alloc.alloc(Oid, 1);
    errdefer alloc.free(tips);
    tips[0] = tip;
    refs[0] = .{ .name = try alloc.dupe(u8, name), .tips = tips };
    return .{ .refs = refs, .head_branch = try alloc.dupe(u8, name) };
}

fn divergeMain(io: std.Io, alloc: std.mem.Allocator, s: *Store, root: std.Io.Dir) !void {
    try root.writeFile(io, .{ .sub_path = "a.txt", .data = "v1" });
    const c1 = try workspace.snapshot(s, root, "Nico <n@x>", "main", 1_700_000_000);
    _ = try opdag.commit(s, alloc, "snapshot", 1, "main");

    try root.writeFile(io, .{ .sub_path = "a.txt", .data = "v2" });
    const c2 = try workspace.snapshot(s, root, "Nico <n@x>", "main", 1_700_000_001);

    try s.updateRef("main", c1);
    try root.writeFile(io, .{ .sub_path = "a.txt", .data = "v3" });
    const c3 = try workspace.snapshot(s, root, "Nico <n@x>", "main", 1_700_000_002);

    const base = try opdag.heads(s, alloc);
    defer alloc.free(base);

    var left = try singleTipView(alloc, "main", c2);
    defer left.deinit(alloc);
    var right = try singleTipView(alloc, "main", c3);
    defer right.deinit(alloc);

    const lv = try opdag.writeView(s, left);
    const rv = try opdag.writeView(s, right);
    _ = try opdag.commitWith(s, alloc, base, lv, "snapshot", 2, "main");
    _ = try opdag.commitWith(s, alloc, base, rv, "snapshot", 3, "main");
}

fn enterRepo(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) ![:0]u8 {
    const before_path = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", alloc);
    defer alloc.free(before_path);
    const before = try alloc.dupeZ(u8, before_path);
    errdefer alloc.free(before);

    const here_path = try dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(here_path);
    const here = try alloc.dupeZ(u8, here_path);
    defer alloc.free(here);

    if (chdir(here.ptr) != 0) return error.ChdirFailed;
    return before;
}

test "a single op head is left alone and never decoded" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const ghost = Oid.ofBytes("an operation whose object was never written");
    try opdag.addHead(&s, ghost);
    try s.updateRef("main", Oid.ofBytes("tip"));

    resolveOps(alloc, &s);

    const hs = try opdag.heads(&s, alloc);
    defer alloc.free(hs);
    try std.testing.expectEqual(@as(usize, 1), hs.len);
    try std.testing.expect(hs[0].eql(ghost));
    try std.testing.expect((try s.readRef("main")).eql(Oid.ofBytes("tip")));
    try std.testing.expect(divergence(alloc, &s) == null);
}

test "a mutating command merges two op heads down to one" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    var root = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer root.close(io);

    var s = try Store.init(io, alloc, root);
    defer s.deinit();
    try divergeMain(io, alloc, &s, root);

    {
        const hs = try opdag.heads(&s, alloc);
        defer alloc.free(hs);
        try std.testing.expectEqual(@as(usize, 2), hs.len);
    }

    const before = try enterRepo(io, alloc, root);
    defer alloc.free(before);
    defer _ = chdir(before.ptr);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = aw.toArrayList();
    try cmdSave(io, alloc, &aw.writer, &.{});

    var after = try Store.discover(io, alloc, std.Io.Dir.cwd());
    defer after.deinit();
    const hs = try opdag.heads(&after, alloc);
    defer alloc.free(hs);
    try std.testing.expectEqual(@as(usize, 1), hs.len);

    const head_op = try opdag.readOperation(&after, alloc, hs[0]);
    defer opdag.freeOperation(alloc, head_op);
    try std.testing.expectEqual(@as(usize, 1), head_op.parents.len);

    const merged = try opdag.readOperation(&after, alloc, head_op.parents[0]);
    defer opdag.freeOperation(alloc, merged);
    try std.testing.expectEqualStrings("merge", merged.kind);
    try std.testing.expectEqual(@as(usize, 2), merged.parents.len);

    var view = try opdag.readView(&after, alloc, merged.view);
    defer view.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), view.find("main").?.tips.len);
}

test "status names a branch that holds more than one tip" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo");
    var root = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer root.close(io);

    var s = try Store.init(io, alloc, root);
    defer s.deinit();
    try divergeMain(io, alloc, &s, root);
    resolveOps(alloc, &s);

    const before = try enterRepo(io, alloc, root);
    defer alloc.free(before);
    defer _ = chdir(before.ptr);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = aw.toArrayList();

    try cmdStatus(io, alloc, &aw.writer, &.{});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "branch main diverged: 2 tips") != null);

    aw.clearRetainingCapacity();
    try cmdStatus(io, alloc, &aw.writer, &.{"--json"});
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\"diverged\":[{\"branch\":\"main\",\"tips\":2}]") != null);

    aw.clearRetainingCapacity();
    try cmdDoctor(io, alloc, &aw.writer);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "branch main diverged: 2 tips") != null);

    aw.clearRetainingCapacity();
    try cmdBranch(io, alloc, &aw.writer, &.{});
    var buf: [Oid.len * 2]u8 = undefined;
    var view = try opdag.currentView(&s, alloc);
    defer view.deinit(alloc);
    for (view.find("main").?.tips) |t| {
        try std.testing.expect(std.mem.indexOf(u8, aw.written(), shortHex(t, &buf)) != null);
    }
}

test "a damaged op-heads directory is silent and never fails a command" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try s.updateRef("main", Oid.ofBytes("tip"));
    try s.root.writeFile(io, .{ .sub_path = opdag.heads_dir, .data = "not a directory" });

    resolveOps(alloc, &s);
    try std.testing.expect(divergence(alloc, &s) == null);
    try std.testing.expect((try s.readRef("main")).eql(Oid.ofBytes("tip")));

    oplog.record(&s, .{
        .kind = .other,
        .branch = "main",
        .prev = Oid.zero(),
        .new = Oid.ofBytes("tip"),
        .timestamp = 1_700_000_000,
    }) catch {};
    resolveOps(alloc, &s);
    try std.testing.expect((try s.readRef("main")).eql(Oid.ofBytes("tip")));
}

const CliFixture = struct {
    tmp: std.testing.TmpDir,
    root: std.Io.Dir,
    store: Store,
    back: [:0]u8,
    out: std.ArrayList(u8),
    aw: std.Io.Writer.Allocating,

    fn init() !*CliFixture {
        const io = std.testing.io;
        const alloc = std.testing.allocator;
        const self = try alloc.create(CliFixture);
        errdefer alloc.destroy(self);

        self.tmp = std.testing.tmpDir(.{});
        try self.tmp.dir.createDirPath(io, "repo");
        self.root = try self.tmp.dir.openDir(io, "repo", .{ .iterate = true });
        self.store = try Store.init(io, alloc, self.root);
        self.back = try enterRepo(io, alloc, self.root);
        self.out = .empty;
        self.aw = std.Io.Writer.Allocating.fromArrayList(alloc, &self.out);
        return self;
    }

    fn deinit(self: *CliFixture) void {
        const io = std.testing.io;
        const alloc = std.testing.allocator;
        self.out = self.aw.toArrayList();
        self.out.deinit(alloc);
        _ = chdir(self.back.ptr);
        alloc.free(self.back);
        self.store.deinit();
        self.root.close(io);
        self.tmp.cleanup();
        alloc.destroy(self);
    }

    fn w(self: *CliFixture) *std.Io.Writer {
        return &self.aw.writer;
    }

    fn said(self: *CliFixture) []const u8 {
        return self.aw.written();
    }

    fn clear(self: *CliFixture) void {
        self.aw.clearRetainingCapacity();
    }

    fn write(self: *CliFixture, path: []const u8, data: []const u8) !void {
        try self.root.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
    }

    fn read(self: *CliFixture, path: []const u8) ![]u8 {
        return self.root.readFileAlloc(std.testing.io, path, std.testing.allocator, .unlimited);
    }

    fn save(self: *CliFixture, message: []const u8) !Oid {
        return workspace.snapshot(&self.store, self.root, "T <t@e.com>", message, nowSeconds(std.testing.io));
    }

    fn tip(self: *CliFixture) !Oid {
        const branch = try self.store.headBranch();
        defer std.testing.allocator.free(branch);
        return self.store.readRef(branch);
    }

    fn messageOf(self: *CliFixture, change: Oid) ![]u8 {
        const c = try self.store.readChange(change);
        defer object.freeChange(std.testing.allocator, c);
        return std.testing.allocator.dupe(u8, c.message);
    }

    fn chain(self: *CliFixture) ![]Oid {
        return history.chainOf(&self.store, std.testing.allocator, try self.tip());
    }
};

test "status reports conflict markers a rewrite left inside a saved change" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    try f.write("f.txt", "a\nb\nc\n");
    _ = try f.save("root");

    try branches.create(&f.store, "feature");
    try branches.switchTo(&f.store, f.root, "feature");
    try f.write("f.txt", "X\nb\nc\n");
    _ = try f.save("mine");

    try branches.switchTo(&f.store, f.root, "main");
    try f.write("f.txt", "Y\nb\nc\n");
    _ = try f.save("theirs");
    try branches.switchTo(&f.store, f.root, "feature");

    try cmdRebase(io, alloc, f.w(), &.{"main"});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "came out conflicted") != null);

    const on_disk = try f.read("f.txt");
    defer alloc.free(on_disk);
    try std.testing.expect(merge.hasConflictMarkers(on_disk));

    f.clear();
    try cmdStatus(io, alloc, f.w(), &.{});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "clean, nothing to save") == null);
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "unresolved conflict in 1 saved file(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "f.txt") != null);

    f.clear();
    try cmdStatus(io, alloc, f.w(), &.{"--json"});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "\"marked\":[\"f.txt\"]") != null);

    try f.write("f.txt", "X\nb\nc\n");
    _ = try f.save("resolved");
    f.clear();
    try cmdStatus(io, alloc, f.w(), &.{});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "unresolved conflict") == null);
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "clean, nothing to save") != null);
}

test "split takes -m after the path separator instead of eating it" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    try f.write("keep.txt", "keep\n");
    _ = try f.save("root");
    try f.root.createDirPath(io, "docs");
    try f.write("src.zig", "code\n");
    try f.write("docs/readme.md", "docs\n");
    _ = try f.save("code and docs");

    try cmdSplit(io, alloc, f.w(), &.{ "--", "docs", "-m", "docs only" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "split") != null);

    const chain = try f.chain();
    defer alloc.free(chain);
    try std.testing.expectEqual(@as(usize, 3), chain.len);

    const extracted = try f.messageOf(chain[1]);
    defer alloc.free(extracted);
    try std.testing.expectEqualStrings("docs only", extracted);

    const remainder = try f.messageOf(chain[2]);
    defer alloc.free(remainder);
    try std.testing.expectEqualStrings("code and docs", remainder);
}

test "describe renames a change below the tip and keeps the rest" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    try f.write("a.txt", "a\n");
    const root = try f.save("wip");
    try f.write("b.txt", "b\n");
    _ = try f.save("the tip");

    var hex: [Oid.len * 2]u8 = undefined;
    _ = root.toHex(&hex);
    try cmdDescribe(io, alloc, f.w(), &.{ "-m", "add the a module", "--at", hex[0..12] });

    const chain = try f.chain();
    defer alloc.free(chain);
    try std.testing.expectEqual(@as(usize, 2), chain.len);

    const renamed = try f.messageOf(chain[0]);
    defer alloc.free(renamed);
    try std.testing.expectEqualStrings("add the a module", renamed);

    const kept = try f.messageOf(chain[1]);
    defer alloc.free(kept);
    try std.testing.expectEqualStrings("the tip", kept);
}

test "drop removes a change and leaves its content in the working tree" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    try f.write("a.txt", "a\n");
    _ = try f.save("root");
    try f.write("debris.txt", "debris\n");
    _ = try f.save("debris");

    try cmdDrop(io, alloc, f.w(), &.{});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "still in the working tree") != null);

    const chain = try f.chain();
    defer alloc.free(chain);
    try std.testing.expectEqual(@as(usize, 1), chain.len);

    const on_disk = try f.read("debris.txt");
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings("debris\n", on_disk);

    f.clear();
    try cmdStatus(io, alloc, f.w(), &.{});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "debris.txt") != null);

    f.clear();
    try cmdUndo(io, alloc, f.w());
    const back = try f.chain();
    defer alloc.free(back);
    try std.testing.expectEqual(@as(usize, 2), back.len);
}

test "branch -d refuses the current branch, refuses unmerged work, then deletes" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    try f.write("a.txt", "a\n");
    _ = try f.save("root");
    try branches.create(&f.store, "scratch");
    try branches.switchTo(&f.store, f.root, "scratch");
    try f.write("scratch.txt", "scratch\n");
    _ = try f.save("scratch work");
    try branches.switchTo(&f.store, f.root, "main");

    try cmdBranch(io, alloc, f.w(), &.{ "-d", "main" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "is the branch you are on") != null);
    try std.testing.expect(f.store.refExists("main"));

    f.clear();
    try cmdBranch(io, alloc, f.w(), &.{ "-d", "ghost" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "no such branch") != null);

    f.clear();
    try cmdBranch(io, alloc, f.w(), &.{ "-d", "scratch" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "no other branch reaches") != null);
    try std.testing.expect(f.store.refExists("scratch"));

    f.clear();
    try cmdBranch(io, alloc, f.w(), &.{ "-D", "scratch" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "deleted branch") != null);
    try std.testing.expect(!f.store.refExists("scratch"));

    f.clear();
    try cmdUndo(io, alloc, f.w());
    try std.testing.expect(f.store.refExists("scratch"));
}

test "amend sends a hunk of the working tree back into a named change" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var f = try CliFixture.init();
    defer f.deinit();

    const old = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
    const new = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10a\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";
    const first_only = "1a\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19\n20\n";

    try f.write("app.zig", old);
    const root = try f.save("root");
    try f.write("later.txt", "later\n");
    _ = try f.save("later work");
    try f.write("app.zig", new);

    var hex: [Oid.len * 2]u8 = undefined;
    _ = root.toHex(&hex);
    try cmdAmend(io, alloc, f.w(), &.{ "--at", hex[0..12], "--hunk", "app.zig:1" });
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "amended") != null);

    const chain = try f.chain();
    defer alloc.free(chain);
    try std.testing.expectEqual(@as(usize, 2), chain.len);

    const folded = try f.store.readChange(chain[0]);
    defer object.freeChange(alloc, folded);
    const tree = try f.store.readTree(folded.tree);
    defer object.freeTree(alloc, tree);
    var found: ?Oid = null;
    for (tree.entries) |e| {
        if (eq(e.path, "app.zig")) found = e.blob;
    }
    const text = try f.store.readFileContent(found.?);
    defer alloc.free(text);
    try std.testing.expectEqualStrings(first_only, text);

    const on_disk = try f.read("app.zig");
    defer alloc.free(on_disk);
    try std.testing.expectEqualStrings(new, on_disk);

    f.clear();
    try cmdStatus(io, alloc, f.w(), &.{});
    try std.testing.expect(std.mem.indexOf(u8, f.said(), "app.zig") != null);
}

test "init tells a colocated git repo to ignore the repo dir, once" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git/info");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/.git/info/exclude", .data = "# git ls-files --others\nbuild/\n" });
    var root = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer root.close(io);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = aw.toArrayList();

    try excludeFromColocatedGit(io, alloc, &aw.writer, root);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "ignore") != null);

    const first = try root.readFileAlloc(io, ".git/info/exclude", alloc, .unlimited);
    defer alloc.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "build/\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, store.dir_name ++ "/\n") != null);

    aw.clearRetainingCapacity();
    try excludeFromColocatedGit(io, alloc, &aw.writer, root);
    try std.testing.expectEqualStrings("", aw.written());

    const again = try root.readFileAlloc(io, ".git/info/exclude", alloc, .unlimited);
    defer alloc.free(again);
    try std.testing.expectEqualStrings(first, again);
}

test "init writes the exclude file when git has none, and skips a repo without git" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "with/.git");
    try tmp.dir.createDirPath(io, "without");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    var aw = std.Io.Writer.Allocating.fromArrayList(alloc, &out);
    defer out = aw.toArrayList();

    var with = try tmp.dir.openDir(io, "with", .{ .iterate = true });
    defer with.close(io);
    try excludeFromColocatedGit(io, alloc, &aw.writer, with);
    const written = try with.readFileAlloc(io, ".git/info/exclude", alloc, .unlimited);
    defer alloc.free(written);
    try std.testing.expectEqualStrings(store.dir_name ++ "/\n", written);

    aw.clearRetainingCapacity();
    var without = try tmp.dir.openDir(io, "without", .{ .iterate = true });
    defer without.close(io);
    try excludeFromColocatedGit(io, alloc, &aw.writer, without);
    try std.testing.expectEqualStrings("", aw.written());
}
