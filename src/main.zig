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

const Oid = oid.Oid;
const Store = store.Store;

const version = "0.1.2";

const usage =
    \\gr — guardrail, a fast independent VCS built for humans and agents
    \\
    \\usage: gr <command> [args]
    \\
    \\the everyday loop
    \\  save [-m msg]   checkpoint the working tree (--prompt records who/why)
    \\  status | st     what changed since the last save
    \\  diff            line-level diff of the working tree vs the last save
    \\  log             the change history
    \\  desc -m msg     name (or rename) the current change
    \\
    \\moving around
    \\  new <name>      start a new branch off the current one and switch to it
    \\  switch <name>   move to another branch (your work auto-saves first)
    \\  branch          list branches
    \\  work <dir>      instant copy-on-write worktree (great for agents)
    \\
    \\  restore <file>  discard local edits to one file (from last save)
    \\  merge <branch>  merge another branch into the current one
    \\  resolve <file>  mark a conflicted file resolved (--abort to bail out)
    \\  revert [change] undo a change as a new change (default: the last one)
    \\  absorb          fold working edits into the changes they belong to
    \\  blame <file>    per-line authorship, incl. agent/prompt provenance
    \\  provenance      show which agent/prompt produced each change (opt-in)
    \\  why <file>      who last authored a file — human or which agent
    \\
    \\undo is never scary
    \\  undo            revert the last change-making operation (whole repo)
    \\  redo            reapply what you just undid
    \\
    \\distributed (no forced server — a peer is just a store)
    \\  serve [port]    share this repo's objects over TCP (default 7777)
    \\  fetch <src> [p] sparse-pull a branch (optionally only paths under p)
    \\  watch           experimental: auto-save on every file change
    \\
    \\git, side by side
    \\  clone <src> <dir>   clone a git repo, a share URL, or a bundle
    \\  import <git-repo>   pull a git repo's HEAD into guardrail
    \\  export <git-repo>   write guardrail HEAD out as git commits
    \\  sync <dir>          mirror guardrail HEAD into the colocated .git
    \\  lfs <cmd>           git-lfs interop (track, ls, fetch, push, env)
    \\  push [remote] [branch] | pull [remote]   (remote defaults to origin)
    \\
    \\sharing without a service (the host stays blind)
    \\  share           encrypt every object under a fresh key, print a link
    \\  share serve <dir> [port]   host an exported share over HTTP
    \\  bundle -o <f>   one sealed file; send file and key separately
    \\
    \\secrets you can actually commit
    \\  seal <path>     seal a .env-style file; values become gr1: ciphertext
    \\  unseal          write the plaintext back out (needs your key)
    \\  key new | show | add <name> <pubkey> | remove <name> | list
    \\  rotate          new repo key, re-wrapped to every member
    \\
    \\  init            create a guardrail repo here
    \\  gc [--dry-run]  reclaim space from unreachable objects
    \\  config [--global] <key> [value]   get/set config (identity, defaults)
    \\  completions <fish|zsh|bash>       print shell completion script
    \\  update [--nightly]   update gr to the latest release (or nightly build)
    \\  version | help
    \\
    \\  (status and log accept --json for scripting)
    \\
;

const default_author = "you <you@localhost>";

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
    defer w.flush() catch {};

    if (args.len < 2) {
        try w.writeAll(usage);
        return;
    }

    const cmd = args[1];
    const rest = args[2..];

    if (eq(cmd, "version") or eq(cmd, "--version")) {
        try w.print("gr {s}\n", .{version});
    } else if (eq(cmd, "update") or eq(cmd, "upgrade")) {
        var nightly = false;
        for (rest) |a| {
            if (eq(a, "--nightly")) nightly = true;
        }
        try update.run(io, alloc, w, version, nightly);
    } else if (eq(cmd, "help") or eq(cmd, "-h") or eq(cmd, "--help")) {
        try w.writeAll(usage);
    } else if (eq(cmd, "init")) {
        try cmdInit(io, alloc, w);
    } else if (eq(cmd, "save") or eq(cmd, "snapshot") or eq(cmd, "snap")) {
        try cmdSave(io, alloc, w, rest);
    } else if (eq(cmd, "describe") or eq(cmd, "desc")) {
        try cmdDescribe(io, alloc, w, rest);
    } else if (eq(cmd, "status") or eq(cmd, "st")) {
        try cmdStatus(io, alloc, w, rest);
    } else if (eq(cmd, "diff")) {
        try cmdDiff(io, alloc, w);
    } else if (eq(cmd, "log")) {
        try cmdLog(io, alloc, w, rest);
    } else if (eq(cmd, "branch") or eq(cmd, "branches")) {
        try cmdBranch(io, alloc, w);
    } else if (eq(cmd, "new")) {
        try cmdNew(io, alloc, w, rest);
    } else if (eq(cmd, "switch") or eq(cmd, "sw")) {
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
    } else if (eq(cmd, "share")) {
        try cmdShare(io, alloc, w, rest);
    } else if (eq(cmd, "bundle")) {
        try cmdBundle(io, alloc, w, rest);
    } else {
        try w.print("unknown command: {s}\n\n", .{cmd});
        try w.writeAll(usage);
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
        try w.writeAll("not a guardrail repo (run `gr init`)\n");
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
    try w.print("initialized empty guardrail repo in .gr (branch {s})\n", .{db});
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
        try w.writeAll("merge aborted — working tree restored\n");
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
            try w.print("{s} still has conflict markers — fix them first\n", .{rest[0]});
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
        try w.print("resolved {s} — all conflicts cleared, now `gr save`\n", .{rest[0]});
    } else {
        try w.print("resolved {s} — {d} conflict(s) left\n", .{ rest[0], rem.len });
    }
}

fn cmdRevert(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const branch = try s.headBranch();
    defer alloc.free(branch);
    const tip = s.readRef(branch) catch {
        try w.writeAll("nothing to revert — no changes yet\n");
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
    try w.print("reverted — new change {s}\n", .{shortHex(change, &buf)});
}

fn cmdAbsorb(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
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
    const change = try doSave(io, alloc, &s, messageFlag(rest));
    recordProvenance(io, alloc, &s, change, rest);
    const branch = try s.headBranch();
    defer alloc.free(branch);
    var buf: [Oid.len * 2]u8 = undefined;
    try w.print("saved {s} on {s}\n", .{ shortHex(change, &buf), branch });
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
        try w.writeAll("nothing to describe — save something first\n");
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
        try w.writeAll("]}\n");
        return;
    }

    if (conflicts.len != 0) {
        try w.print("merge in progress — {d} unresolved conflict(s):\n", .{conflicts.len});
        for (conflicts) |p| try w.print("  ! {s}\n", .{p});
        try w.writeAll("fix the markers then `gr resolve <file>`, or `gr resolve --abort`\n");
    }
    if (entries.len == 0) {
        if (conflicts.len == 0) try w.writeAll("clean — nothing to save\n");
        return;
    }
    for (entries) |e| {
        const tag = switch (e.kind) {
            .added => "new",
            .modified => "mod",
            .deleted => "del",
        };
        try w.print("  {s}  {s}\n", .{ tag, e.path });
    }
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
        try w.writeAll("no changes\n");
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
            const msg = if (change.message.len == 0) "(no message)" else change.message;
            try w.print("{s}  {s}\n    {s}\n", .{ shortHex(cur, &buf), change.author, msg });
            if (try provenance.get(&s, alloc, cur)) |p| {
                defer provenance.freeEntry(alloc, p);
                if (p.agent.len != 0) try w.print("    ↳ agent: {s}\n", .{p.agent});
                if (p.prompt.len != 0) try w.print("    ↳ prompt: {s}\n", .{p.prompt});
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
        try w.print("* {s} (unborn)\n", .{cur});
        return;
    }
    for (names) |n| {
        const mark: []const u8 = if (eq(n, cur)) "*" else " ";
        try w.print("{s} {s}\n", .{ mark, n });
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
        try w.print("merged {s} into {s} — clean\n", .{ rest[0], into });
    } else {
        merge.saveState(&s, rest[0], before, result.conflicts) catch {};
        try w.print("merged {s} into {s} with {d} conflict(s):\n", .{ rest[0], into, result.conflicts.len });
        for (result.conflicts) |p| try w.print("  ! {s}\n", .{p});
        try w.writeAll("fix the markers, then `gr resolve <file>` each — or `gr resolve --abort`\n");
    }
}

fn cmdServe(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
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
        try w.print("sparse-fetched {s} — only paths under '{s}' ({s})\n", .{ shortHex(change, &buf), prefix, branch });
    }
}

fn cmdWatch(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    const author = try config.author(&s, alloc);
    defer alloc.free(author);
    var work = try openWork(io);
    defer work.close(io);
    try w.writeAll("watching for changes — auto-saving (ctrl-c to stop)\n");
    try w.flush();
    try watch.watch(&s, work, .{ .author = author });
}

fn cmdUndo(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    oplog.undo(&s) catch |e| switch (e) {
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
    oplog.redo(&s) catch |e| switch (e) {
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
        try w.print("unknown remote '{s}' — pass a URL, or set it in git or `gr config remote.{s}.url`\n", .{ remote_name, remote_name });
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
    const remote_name = if (rest.len >= 1) rest[0] else "origin";
    const url = (try resolveRemote(io, alloc, &s, remote_name)) orelse {
        try w.print("unknown remote '{s}' — pass a URL, or set it in git or `gr config remote.{s}.url`\n", .{ remote_name, remote_name });
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

fn shareUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: gr share [--base <url>] [--out <dir>] [branch...]
        \\           encrypt this repo's objects under a fresh key and write them out
        \\       gr share serve <dir> [port]
        \\           host an exported share over HTTP (it never sees the key)
        \\       gr bundle -o <file> [branch...]
        \\           one sealed file; send the file one way, the key another
        \\       gr clone <url-with-#k=> <dir>
        \\
    );
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

fn cmdShare(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    if (rest.len != 0 and (eq(rest[0], "-h") or eq(rest[0], "--help"))) return shareUsage(w);

    if (rest.len != 0 and eq(rest[0], "serve")) {
        if (rest.len < 2) return shareUsage(w);
        var dir = std.Io.Dir.cwd().openDir(io, rest[1], .{}) catch {
            try w.print("no such directory: {s}\n", .{rest[1]});
            return;
        };
        defer dir.close(io);
        const port: u16 = if (rest.len >= 3)
            std.fmt.parseInt(u16, rest[2], 10) catch 7788
        else
            7788;
        try w.print("serving encrypted objects from {s} on port {d} (ctrl-c to stop)\n", .{ rest[1], port });
        try w.writeAll("this process cannot decrypt what it is serving\n");
        try w.flush();
        return share.serveDir(io, alloc, dir, port);
    }

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    var base: []const u8 = "https://YOUR-HOST";
    var out_dir: []const u8 = "share";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (eq(rest[i], "--base") and i + 1 < rest.len) {
            base = rest[i + 1];
            i += 1;
        } else if (eq(rest[i], "--out") and i + 1 < rest.len) {
            out_dir = rest[i + 1];
            i += 1;
        }
    }

    const wanted = try shareBranches(alloc, rest, 0);
    defer alloc.free(wanted);

    std.Io.Dir.cwd().createDirPath(io, out_dir) catch {};
    var dest = try std.Io.Dir.cwd().openDir(io, out_dir, .{});
    defer dest.close(io);

    const key = share.newShareKey(io);
    share.exportDir(&s, alloc, io, key, dest, wanted) catch |e| {
        try w.print("share failed: {t}\n", .{e});
        return;
    };

    const url = try share.encodeUrl(alloc, base, key);
    defer alloc.free(url);

    try w.print("wrote encrypted objects to {s}/\n\n{s}\n\n", .{ out_dir, url });
    try w.writeAll("upload that directory anywhere static. the host never receives the key —\n");
    try w.writeAll("it lives after the '#', which browsers and gr never put in a request.\n");
    try w.print("sealed values stay sealed: whoever opens this gets the code, not the secrets.\n", .{});
}

fn cmdBundle(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var out_path: ?[]const u8 = null;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if ((eq(rest[i], "-o") or eq(rest[i], "--out")) and i + 1 < rest.len) {
            out_path = rest[i + 1];
            i += 1;
        }
    }
    const path = out_path orelse {
        try w.writeAll("usage: gr bundle -o <file> [branch...]\n");
        return;
    };

    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();

    const wanted = try shareBranches(alloc, rest, 0);
    defer alloc.free(wanted);

    const key = share.newShareKey(io);
    share.writeBundle(&s, alloc, io, key, path, wanted) catch |e| {
        try w.print("bundle failed: {t}\n", .{e});
        return;
    };

    const url = try share.encodeUrl(alloc, "file", key);
    defer alloc.free(url);
    const frag = std.mem.indexOf(u8, url, "#k=") orelse url.len;

    try w.print("wrote {s}\n\nkey: {s}\n\n", .{ path, url[frag..] });
    try w.print("open it with:  gr clone '{s}{s}' <dir>\n", .{ path, url[frag..] });
    try w.writeAll("send the file and the key over different channels — either alone is useless.\n");
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
    try w.print("cloned into {s}\n", .{into});
    try w.writeAll("any sealed values are still sealed — `gr unseal` needs a key you were not given.\n");
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
        try w.writeAll("no keypair yet — run `gr key new`\n");
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
            try w.print("{s}  {s}{s}\n", .{ m.name, fp, if (is_me) "  (you)" else "" });
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
        try w.print("{s} can now read the sealed values\n", .{name});
        try w.print("  fingerprint  {s}\n", .{fp});
        try w.print("confirm that out loud with them, then commit {s}\n", .{seal.manifest_name});
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
        try w.writeAll("(new database password, new API keys) — only that actually revokes them.\n");
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
    try w.print("{s}\n\n{s}\n\nfingerprint  {s}\n", .{ label, enc, fp });
}

fn cmdSeal(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) !void {
    var s = (try openRepo(io, alloc, w)) orelse return;
    defer s.deinit();
    var work = try openWork(io);
    defer work.close(io);

    if (rest.len != 0 and eq(rest[0], "status")) {
        var manifest = (try loadRepoManifest(io, alloc, w, work)) orelse return;
        defer manifest.deinit();
        for (manifest.paths.items) |p| {
            const sealed = try seal.sealedPathAlloc(alloc, p);
            defer alloc.free(sealed);
            const present = if (work.access(io, p, .{})) |_| true else |_| false;
            try w.print("{s} -> {s}{s}\n", .{ p, sealed, if (present) "" else "  (no local plaintext)" });
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
            try w.writeAll("you cannot read this repo's secrets — ask a member to `gr key add` you\n");
            return;
        };
        _ = key;

        if (!try manifest.addPath(path)) {
            try w.print("{s} is already sealed\n", .{path});
        }
        try keyring.saveManifest(io, alloc, work, &manifest);
        try keyring.protectPath(io, alloc, work, path);
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
        try w.writeAll("you cannot read this repo's secrets — ask a member to `gr key add` you\n");
        return;
    }
    for (plan.sources, plan.outputs) |src, dst| {
        try w.print("{s} -> {s}\n", .{ src, dst });
    }
    try w.print("commit {s} and the sealed file; the plaintext stays out of every change\n", .{seal.manifest_name});
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
            try w.writeAll("you cannot read this repo's secrets — ask a member to `gr key add` you\n");
            try w.writeAll("(`gr key show` prints the public key they need)\n");
            return;
        },
        seal.Error.BadToken => {
            try w.writeAll("a sealed value failed to decrypt — the file may be corrupt or edited\n");
            return;
        },
        else => return e,
    };
    try w.print("wrote {d} file(s)", .{out.written});
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

    for (manifest.paths.items) |src| {
        const dst = try seal.sealedPathAlloc(alloc, src);
        defer alloc.free(dst);
        if (work.access(io, src, .{})) |_| continue else |_| {}
        const sealed = work.readFileAlloc(io, dst, alloc, .unlimited) catch continue;
        defer alloc.free(sealed);
        const plain = try seal.unsealText(alloc, old, src, sealed);
        defer alloc.free(plain);
        try work.writeFile(io, .{
            .sub_path = src,
            .data = plain,
            .flags = .{ .permissions = .fromMode(0o600) },
        });
    }

    const fresh = seal.newRepoKey(io);
    try manifest.rewrapAll(io, fresh);
    try keyring.saveManifest(io, alloc, work, &manifest);

    for (manifest.paths.items) |src| {
        const dst = try seal.sealedPathAlloc(alloc, src);
        defer alloc.free(dst);
        const plain = work.readFileAlloc(io, src, alloc, .unlimited) catch continue;
        defer alloc.free(plain);
        const sealed = try seal.sealText(alloc, fresh, src, plain);
        defer alloc.free(sealed);
        try work.writeFile(io, .{ .sub_path = dst, .data = sealed });
    }

    try w.print("rotated the repo key, re-wrapped to {d} member(s)\n", .{manifest.members.items.len});
    try w.writeAll("anyone removed earlier still holds the OLD key and any commit they cloned.\n");
    try w.writeAll("rotate the secrets themselves too — new password, new API key — or they keep working.\n");
}

test {
    std.testing.refAllDecls(@This());
    _ = seal;
    _ = keyring;
    _ = share;
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
    _ = @import("index.zig");
}
