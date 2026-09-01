const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const proc = @import("proc.zig");
const lfs = @import("lfs.zig");
const ui = @import("ui.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

const c = @cImport({
    @cInclude("git2.h");
});

pub const Error = error{ GitError, NotFastForward };

/// Set by the last import/push so the CLI can report LFS work without having to
/// re-open a session: pointers that stayed pointers, and objects uploaded.
pub var lfs_unresolved: usize = 0;
pub var lfs_uploaded: usize = 0;

/// Live progress for the mirror-and-push path, set by a command that wants
/// those steps to report themselves. Mirroring a long history walks every file
/// of every saved state and the push that follows packs and uploads all of it,
/// so without a row on screen a big first push is indistinguishable from a hang.
pub var live_progress: ?*Progress = null;

/// Tree entries walked, and blobs actually read and compressed, during the last
/// export. They diverge exactly where the blob cache spared work: every saved
/// state carries a full tree, so a file that never changed must cost one blob,
/// not one per state.
pub var exported_files: u64 = 0;
pub var exported_blobs: u64 = 0;

var init_done: bool = false;

fn ensureInit() void {
    if (!init_done) {
        _ = c.git_libgit2_init();
        init_done = true;
    }
}

pub fn shutdown() void {
    _ = c.git_libgit2_shutdown();
}

var last_err_buf: [1024]u8 = undefined;
var last_err_len: usize = 0;

/// The text of the last libgit2 failure (or a message sdt recorded itself), so
/// the CLI can say what actually went wrong instead of "it failed".
pub fn lastError() []const u8 {
    return last_err_buf[0..last_err_len];
}

pub fn recordError(msg: []const u8) void {
    const n = @min(msg.len, last_err_buf.len);
    @memcpy(last_err_buf[0..n], msg[0..n]);
    last_err_len = n;
}

fn recordLibgitError() void {
    last_err_len = 0;
    const e = c.git_error_last();
    if (e == null) return;
    const m = e.*.message;
    if (m == null) return;
    recordError(std.mem.span(m));
}

fn check(rc: c_int) Error!void {
    if (rc != 0) {
        recordLibgitError();
        return Error.GitError;
    }
}

/// Git-side commits an export would drop, captured when a branch update is not
/// a fast-forward. Reported instead of being overwritten: history that git has
/// and sdt does not is still history, and losing it silently is not an option.
pub const AtRisk = struct {
    branch_buf: [256]u8 = undefined,
    branch_len: usize = 0,
    ids: [8][40]u8 = undefined,
    subject_bufs: [8][80]u8 = undefined,
    subject_lens: [8]usize = [_]usize{0} ** 8,
    shown: usize = 0,
    total: usize = 0,

    pub fn branch(self: *const AtRisk) []const u8 {
        return self.branch_buf[0..self.branch_len];
    }

    pub fn id(self: *const AtRisk, i: usize) []const u8 {
        return self.ids[i][0..];
    }

    pub fn subject(self: *const AtRisk, i: usize) []const u8 {
        return self.subject_bufs[i][0..self.subject_lens[i]];
    }
};

pub var at_risk: AtRisk = .{};

fn recordAtRisk(repo: ?*c.git_repository, old: *const c.git_oid, new_tip: *const c.git_oid, branch: []const u8) void {
    at_risk = .{};
    const bn = @min(branch.len, at_risk.branch_buf.len);
    @memcpy(at_risk.branch_buf[0..bn], branch[0..bn]);
    at_risk.branch_len = bn;

    var walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&walk, repo) != 0) return;
    defer c.git_revwalk_free(walk);
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL);
    if (c.git_revwalk_push(walk, old) != 0) return;
    _ = c.git_revwalk_hide(walk, new_tip);

    var woid: c.git_oid = undefined;
    while (c.git_revwalk_next(&woid, walk) == 0) {
        at_risk.total += 1;
        const i = at_risk.shown;
        if (i >= at_risk.ids.len) continue;
        at_risk.ids[i] = gitOidHex(&woid);
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &woid) == 0) {
            defer c.git_commit_free(commit);
            const sm = c.git_commit_summary(commit);
            if (sm != null) {
                const text = std.mem.span(sm);
                const n = @min(text.len, at_risk.subject_bufs[i].len);
                @memcpy(at_risk.subject_bufs[i][0..n], text[0..n]);
                at_risk.subject_lens[i] = n;
            }
        }
        at_risk.shown += 1;
    }
}

/// Refuse to move `ref_name` to `new_tip` when that would orphan commits: the
/// update is allowed only when the current tip is an ancestor of the new one.
fn guardFastForward(
    repo: ?*c.git_repository,
    ref_name: [*:0]const u8,
    new_tip: *const c.git_oid,
    branch: []const u8,
) Error!void {
    var old: c.git_oid = undefined;
    if (c.git_reference_name_to_id(&old, repo, ref_name) != 0) return;
    if (c.git_oid_equal(&old, new_tip) != 0) return;
    if (c.git_graph_descendant_of(repo, new_tip, &old) == 1) return;
    recordAtRisk(repo, &old, new_tip, branch);
    recordError("the git branch has commits that superdetermine does not have");
    return Error.NotFastForward;
}

const CredState = struct {
    token: ?[*:0]const u8 = null,
};
var g_cred: CredState = .{};

fn envToken() ?[*:0]const u8 {
    return proc.envToken();
}

const Cred = proc.Cred;

var g_helper: ?Cred = null;
var g_helper_tried: bool = false;

fn resetCredCache() void {
    if (g_helper) |hc| hc.free();
    g_helper = null;
    g_helper_tried = false;
}

fn credentialsCb(
    out: [*c]?*c.git_credential,
    url: [*c]const u8,
    username_from_url: [*c]const u8,
    allowed_types: c_uint,
    payload: ?*anyopaque,
) callconv(.c) c_int {
    _ = payload;
    if ((allowed_types & @as(c_uint, c.GIT_CREDENTIAL_USERPASS_PLAINTEXT)) != 0) {
        if (g_cred.token) |tok| {
            return c.git_credential_userpass_plaintext_new(out, tok, "x-oauth-basic");
        }
        if (!g_helper_tried) {
            g_helper_tried = true;
            if (url != null) {
                g_helper = proc.credentialFill(std.mem.span(url));
            }
        }
        if (g_helper) |hc| {
            return c.git_credential_userpass_plaintext_new(out, hc.user.ptr, hc.pass.ptr);
        }
    }
    if ((allowed_types & @as(c_uint, c.GIT_CREDENTIAL_SSH_KEY)) != 0) {
        const user: [*c]const u8 = if (username_from_url != null) username_from_url else "git";
        return c.git_credential_ssh_key_from_agent(out, user);
    }
    return -1;
}

pub const Phase = enum {
    receiving,
    resolving,
    checking_out,
    importing,
    exporting,
    packing,
    sending,

    fn live(self: Phase) []const u8 {
        return switch (self) {
            .receiving => "receiving objects",
            .resolving => "resolving deltas",
            .checking_out => "checking out",
            .importing => "importing history",
            .exporting => "mirroring history",
            .packing => "packing objects",
            .sending => "sending objects",
        };
    }

    fn past(self: Phase) []const u8 {
        return switch (self) {
            .receiving => "received",
            .resolving => "resolved",
            .checking_out => "checked out",
            .importing => "imported",
            .exporting => "mirrored",
            .packing => "packed",
            .sending => "sent",
        };
    }

    fn noun(self: Phase) []const u8 {
        return switch (self) {
            .receiving => "objects",
            .resolving => "deltas",
            .checking_out => "files",
            .importing => "changes",
            .exporting => "files",
            .packing => "objects",
            .sending => "objects",
        };
    }
};

/// Live clone progress: one terminal row that redraws in place, and a settled
/// line left behind for each phase that finishes. Silent when stdout is not a
/// terminal, so logs and pipes stay clean.
pub const Progress = struct {
    io: std.Io,
    w: *std.Io.Writer,
    phase: ?Phase = null,
    tick: usize = 0,
    last_ms: i64 = 0,
    last_done: u64 = 0,
    bytes: u64 = 0,
    drawn: bool = false,

    pub fn init(io: std.Io, w: *std.Io.Writer) Progress {
        return .{ .io = io, .w = w };
    }

    fn nowMillis(self: *Progress) i64 {
        return @intCast(@divTrunc(std.Io.Clock.now(.awake, self.io).nanoseconds, 1_000_000));
    }

    pub fn update(self: *Progress, phase: Phase, done: u64, total: ?u64) void {
        if (!ui.isTty()) return;
        const changed = self.phase == null or self.phase.? != phase;
        if (changed) self.settle();
        self.phase = phase;
        self.last_done = done;

        const now = self.nowMillis();
        if (!changed and now - self.last_ms < ui.redraw_interval_ms) return;
        self.last_ms = now;
        self.tick +%= 1;
        self.drawn = true;
        ui.drawProgress(self.w, phase.live(), done, total, self.tick, .count);
    }

    /// Replace the live row with a permanent one-line record of the phase.
    fn settle(self: *Progress) void {
        const phase = self.phase orelse return;
        self.phase = null;
        if (!self.drawn) return;
        self.drawn = false;
        ui.clearProgress(self.w);
        self.w.print("{s}{s}{s} {s} {d} {s}", .{
            ui.on(.green), ui.check,       ui.off(),
            phase.past(),  self.last_done, phase.noun(),
        }) catch return;
        if (phase == .receiving and self.bytes != 0) {
            var buf: [32]u8 = undefined;
            self.w.print(" {s}({s}){s}", .{
                ui.on(.dim), ui.humanBytes(self.bytes, &buf), ui.off(),
            }) catch return;
        }
        self.w.writeAll("\n") catch return;
        self.w.flush() catch {};
    }

    /// Settle whatever phase is running and leave the cursor on a clean row.
    pub fn finish(self: *Progress) void {
        self.settle();
        if (!ui.isTty()) return;
        ui.clearProgress(self.w);
    }
};

fn transferProgressCb(stats: [*c]const c.git_indexer_progress, payload: ?*anyopaque) callconv(.c) c_int {
    const p: *Progress = @ptrCast(@alignCast(payload orelse return 0));
    const s = stats.*;
    p.bytes = s.received_bytes;
    const total_objects: ?u64 = if (s.total_objects > 0) s.total_objects else null;
    if (s.total_deltas > 0 and s.received_objects >= s.total_objects) {
        p.update(.resolving, s.indexed_deltas, s.total_deltas);
    } else {
        p.update(.receiving, s.received_objects, total_objects);
    }
    return 0;
}

/// Pack building during a push. Stage 0 is object counting, stage 1 is delta
/// compression; both can run for minutes on a first push of a large history.
fn packProgressCb(stage: c_int, current: u32, total: u32, payload: ?*anyopaque) callconv(.c) c_int {
    _ = stage;
    const p: *Progress = @ptrCast(@alignCast(payload orelse return 0));
    p.update(.packing, current, if (total > 0) total else null);
    return 0;
}

fn pushTransferProgressCb(current: c_uint, total: c_uint, bytes: usize, payload: ?*anyopaque) callconv(.c) c_int {
    const p: *Progress = @ptrCast(@alignCast(payload orelse return 0));
    p.bytes = bytes;
    p.update(.sending, current, if (total > 0) total else null);
    return 0;
}

fn checkoutProgressCb(
    path: [*c]const u8,
    completed: usize,
    total: usize,
    payload: ?*anyopaque,
) callconv(.c) void {
    _ = path;
    const p: *Progress = @ptrCast(@alignCast(payload orelse return));
    p.update(.checking_out, completed, if (total > 0) total else null);
}

fn looksRemote(s: []const u8) bool {
    if (std.mem.indexOf(u8, s, "://") != null) return true;
    if (std.mem.startsWith(u8, s, "git@")) return true;
    if (std.mem.indexOfScalar(u8, s, '@')) |at| {
        if (std.mem.indexOfScalarPos(u8, s, at, ':') != null) return true;
    }
    return false;
}

fn modeFromGit(filemode: c.git_filemode_t) ?object.Mode {
    return switch (filemode) {
        c.GIT_FILEMODE_BLOB => .regular,
        c.GIT_FILEMODE_BLOB_EXECUTABLE => .executable,
        c.GIT_FILEMODE_LINK => .symlink,
        else => null,
    };
}

fn gitOidHex(o: *const c.git_oid) [40]u8 {
    var buf: [40]u8 = undefined;
    _ = c.git_oid_fmt(&buf, o);
    return buf;
}

/// Absolute path of a repo's git directory (`.git/`, or the repo itself when
/// bare). That is where git-lfs keeps `lfs/objects`, so sdt shares it. Caller
/// frees.
fn repoGitDir(alloc: std.mem.Allocator, repo: ?*c.git_repository) !?[]u8 {
    const p = c.git_repository_path(repo);
    if (p == null) return null;
    return try alloc.dupe(u8, std.mem.span(p));
}

/// URL of a named remote, or of the first remote when `origin` is absent.
/// Caller frees. null when the repo has no remotes.
fn repoRemoteUrl(alloc: std.mem.Allocator, repo: ?*c.git_repository) !?[]u8 {
    var remote: ?*c.git_remote = null;
    if (c.git_remote_lookup(&remote, repo, "origin") == 0) {
        defer c.git_remote_free(remote);
        const u = c.git_remote_url(remote);
        if (u != null) return try alloc.dupe(u8, std.mem.span(u));
        return null;
    }
    var names: c.git_strarray = undefined;
    if (c.git_remote_list(&names, repo) != 0) return null;
    defer c.git_strarray_dispose(&names);
    if (names.count == 0) return null;
    if (c.git_remote_lookup(&remote, repo, names.strings[0]) != 0) return null;
    defer c.git_remote_free(remote);
    const u = c.git_remote_url(remote);
    if (u == null) return null;
    return try alloc.dupe(u8, std.mem.span(u));
}

/// Open an LFS session pointed at `repo`'s object cache, using `remote_url` (or
/// the repo's own remote) for batch transfers. Never fails the caller: LFS is
/// an add-on, so an unusable session simply means pointers pass through.
fn lfsSessionFor(store: *Store, repo: ?*c.git_repository, remote_url: ?[]const u8) ?lfs.Session {
    const alloc = store.alloc;
    const git_dir = (repoGitDir(alloc, repo) catch null) orelse return null;
    defer alloc.free(git_dir);
    var owned_url: ?[]u8 = null;
    defer if (owned_url) |u| alloc.free(u);
    var url = remote_url;
    if (url == null) {
        owned_url = repoRemoteUrl(alloc, repo) catch null;
        url = owned_url;
    }
    return lfs.Session.open(store, git_dir, url) catch null;
}

/// Persistent, bidirectional map between git commit ids (40-hex SHA-1) and
/// superdetermine change Oids (64-hex BLAKE3), stored at `.sdt/gitmap` as
/// "<git-hex> <sdt-hex>\n" lines. Loaded at the start of every import/export op
/// so the operations are incremental and consistent across runs.
const Gitmap = struct {
    alloc: std.mem.Allocator,
    git_to_gr: std.StringHashMapUnmanaged(Oid) = .{},
    gr_to_git: std.StringHashMapUnmanaged(c.git_oid) = .{},

    fn load(store: *Store) !Gitmap {
        var self = Gitmap{ .alloc = store.alloc };
        const data = store.root.readFileAlloc(store.io, "gitmap", store.alloc, .unlimited) catch
            return self;
        defer store.alloc.free(data);
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (t.len == 0) continue;
            var parts = std.mem.splitScalar(u8, t, ' ');
            const ghex = parts.next() orelse continue;
            const rhex = parts.next() orelse continue;
            if (ghex.len != 40 or rhex.len != 64) continue;
            const gr = Oid.fromHex(rhex) catch continue;
            var goid: c.git_oid = undefined;
            if (c.git_oid_fromstrn(&goid, ghex.ptr, 40) != 0) continue;
            try self.insertLatest(ghex, goid, gr);
        }
        return self;
    }

    fn insert(self: *Gitmap, git_hex: []const u8, git_oid: c.git_oid, gr: Oid) !void {
        if (!self.git_to_gr.contains(git_hex)) {
            const gk = try self.alloc.dupe(u8, git_hex);
            errdefer self.alloc.free(gk);
            try self.git_to_gr.put(self.alloc, gk, gr);
        }
        var rbuf: [64]u8 = undefined;
        const rhex = gr.toHex(&rbuf);
        if (!self.gr_to_git.contains(rhex)) {
            const rk = try self.alloc.dupe(u8, rhex);
            errdefer self.alloc.free(rk);
            try self.gr_to_git.put(self.alloc, rk, git_oid);
        }
    }

    fn insertLatest(self: *Gitmap, git_hex: []const u8, git_oid: c.git_oid, gr: Oid) !void {
        try self.insert(git_hex, git_oid, gr);
        var rbuf: [64]u8 = undefined;
        const rhex = gr.toHex(&rbuf);
        if (self.gr_to_git.getPtr(rhex)) |slot| slot.* = git_oid;
    }

    fn isCanonical(self: *Gitmap, git_hex: []const u8, gr: Oid) bool {
        var rbuf: [64]u8 = undefined;
        const rhex = gr.toHex(&rbuf);
        const mapped = self.gr_to_git.get(rhex) orelse return false;
        const mhex = gitOidHex(&mapped);
        return std.mem.eql(u8, &mhex, git_hex);
    }

    fn lookupGr(self: *Gitmap, git_hex: []const u8) ?Oid {
        return self.git_to_gr.get(git_hex);
    }

    fn lookupGit(self: *Gitmap, gr: Oid) ?c.git_oid {
        var rbuf: [64]u8 = undefined;
        const rhex = gr.toHex(&rbuf);
        return self.gr_to_git.get(rhex);
    }

    fn save(self: *Gitmap, store: *Store) !void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.alloc);
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            var it = self.git_to_gr.iterator();
            while (it.next()) |kv| {
                if (self.isCanonical(kv.key_ptr.*, kv.value_ptr.*) != (pass == 1)) continue;
                var rb: [64]u8 = undefined;
                const rhex = kv.value_ptr.toHex(&rb);
                try buf.appendSlice(self.alloc, kv.key_ptr.*);
                try buf.append(self.alloc, ' ');
                try buf.appendSlice(self.alloc, rhex);
                try buf.append(self.alloc, '\n');
            }
        }
        try store.root.writeFile(store.io, .{ .sub_path = "gitmap", .data = buf.items });
    }

    fn deinit(self: *Gitmap) void {
        var it1 = self.git_to_gr.keyIterator();
        while (it1.next()) |k| self.alloc.free(k.*);
        self.git_to_gr.deinit(self.alloc);
        var it2 = self.gr_to_git.keyIterator();
        while (it2.next()) |k| self.alloc.free(k.*);
        self.gr_to_git.deinit(self.alloc);
    }
};

const WalkCtx = struct {
    store: *Store,
    repo: ?*c.git_repository,
    alloc: std.mem.Allocator,
    entries: *std.ArrayList(object.TreeEntry),
    lfs_session: ?*lfs.Session = null,
};

fn walkTree(ctx: *WalkCtx, tree: ?*c.git_tree, prefix: []const u8) !void {
    const n = c.git_tree_entrycount(tree);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_tree_entry_byindex(tree, i);
        const name = std.mem.span(c.git_tree_entry_name(entry));
        const etype = c.git_tree_entry_type(entry);

        const path = if (prefix.len == 0)
            try ctx.alloc.dupe(u8, name)
        else
            try std.fmt.allocPrint(ctx.alloc, "{s}/{s}", .{ prefix, name });
        errdefer ctx.alloc.free(path);

        if (etype == c.GIT_OBJECT_TREE) {
            var sub: ?*c.git_tree = null;
            try check(c.git_tree_lookup(&sub, ctx.repo, c.git_tree_entry_id(entry)));
            defer c.git_tree_free(sub);
            try walkTree(ctx, sub, path);
            ctx.alloc.free(path);
        } else if (etype == c.GIT_OBJECT_BLOB) {
            const mode = modeFromGit(c.git_tree_entry_filemode(entry)) orelse {
                ctx.alloc.free(path);
                continue;
            };
            var blob: ?*c.git_blob = null;
            try check(c.git_blob_lookup(&blob, ctx.repo, c.git_tree_entry_id(entry)));
            defer c.git_blob_free(blob);
            const raw = c.git_blob_rawcontent(blob);
            const size: usize = @intCast(c.git_blob_rawsize(blob));
            const bytes: []const u8 = if (size == 0)
                &[_]u8{}
            else
                @as([*]const u8, @ptrCast(raw))[0..size];

            // Git LFS smudge: a pointer blob stands in for the real file, so
            // resolve it back to content before gr chunks and stores it. When
            // the content cannot be had (offline, or smudge is off) the pointer
            // is stored verbatim, exactly as git would.
            var smudged: ?[]u8 = null;
            defer if (smudged) |s| ctx.alloc.free(s);
            if (ctx.lfs_session) |sess| {
                if (sess.smudge) {
                    if (lfs.parsePointer(bytes)) |p| {
                        smudged = sess.resolve(p) catch null;
                    }
                }
            }
            const content: []const u8 = smudged orelse bytes;
            const blob_oid = try ctx.store.writeFileContent(content);
            try ctx.entries.append(ctx.alloc, .{ .mode = mode, .path = path, .blob = blob_oid });
        } else {
            // skip submodules / gitlinks / anything else
            ctx.alloc.free(path);
        }
    }
}

/// Import a single git commit (by id) into `store` as a superdetermine change, reusing
/// the gitmap if already imported. Parents must already be present in `map`
/// (guaranteed by a topological, oldest-first walk). Returns the gr change Oid.
fn importCommit(store: *Store, repo: ?*c.git_repository, map: *Gitmap, cid: *const c.git_oid, sess: ?*lfs.Session) !Oid {
    const git_hex = gitOidHex(cid);
    if (map.lookupGr(&git_hex)) |existing| return existing;

    const alloc = store.alloc;

    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, cid));
    defer c.git_commit_free(commit);

    var tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&tree, commit));
    defer c.git_tree_free(tree);

    var entries: std.ArrayList(object.TreeEntry) = .empty;
    defer {
        for (entries.items) |e| alloc.free(e.path);
        entries.deinit(alloc);
    }
    var ctx = WalkCtx{ .store = store, .repo = repo, .alloc = alloc, .entries = &entries, .lfs_session = sess };
    try walkTree(&ctx, tree, "");
    std.mem.sort(object.TreeEntry, entries.items, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = entries.items });

    var parents: std.ArrayList(Oid) = .empty;
    defer parents.deinit(alloc);
    const pcount = c.git_commit_parentcount(commit);
    var pi: c_uint = 0;
    while (pi < pcount) : (pi += 1) {
        const pid = c.git_commit_parent_id(commit, pi);
        const phex = gitOidHex(pid);
        if (map.lookupGr(&phex)) |pgr| try parents.append(alloc, pgr);
    }

    const sig = c.git_commit_author(commit);
    const name = std.mem.span(sig.*.name);
    const email = std.mem.span(sig.*.email);
    const author = try std.fmt.allocPrint(alloc, "{s} <{s}>", .{ name, email });
    defer alloc.free(author);

    const message = std.mem.span(c.git_commit_message(commit));
    const timestamp: i64 = @intCast(c.git_commit_time(commit));
    const tz_offset: i32 = @intCast(c.git_commit_time_offset(commit));

    // change_id = first 16 bytes of BLAKE3(git commit id raw bytes)
    const cid_bytes: []const u8 = @as([*]const u8, @ptrCast(&cid.*.id))[0..20];
    const cid_oid = Oid.ofBytes(cid_bytes);
    var change_id: object.ChangeId = undefined;
    @memcpy(&change_id, cid_oid.bytes[0..16]);

    const change = object.Change{
        .tree = tree_oid,
        .parents = parents.items,
        .change_id = change_id,
        .timestamp = timestamp,
        .tz_offset_min = tz_offset,
        .author = author,
        .message = message,
    };
    const change_oid = try store.writeChange(change);
    try map.insert(&git_hex, cid.*, change_oid);
    return change_oid;
}

/// Import the FULL history of the git repo's HEAD branch into `store`. Walks the
/// commit DAG oldest-first (topological + reverse) so every commit's parents are
/// imported before it, reproducing the full ancestry as superdetermine changes.
/// Returns the tip change Oid and updates the store's current branch ref.
pub fn importHead(store: *Store, git_repo_path: []const u8) !Oid {
    return importRefTo(store, git_repo_path, null, null);
}

/// Import one git branch's full history into `store`. `git_ref` is any git
/// revspec — a branch shorthand, tag, remote-tracking ref, raw SHA, `HEAD~3`
/// (null means the repo's HEAD) — and `dest_branch` is the sdt branch to
/// point at the imported tip (null means the sdt HEAD branch).
pub fn importRefTo(store: *Store, git_repo_path: []const u8, git_ref: ?[]const u8, dest_branch: ?[]const u8) !Oid {
    const alloc = store.alloc;
    const tip = try importRefChange(store, git_repo_path, git_ref);

    const head_branch = try store.headBranch();
    defer alloc.free(head_branch);
    const branch = if (dest_branch) |b| b else head_branch;
    try store.updateRef(branch, tip);

    return tip;
}

pub fn importRefChange(store: *Store, git_repo_path: []const u8, git_ref: ?[]const u8) !Oid {
    ensureInit();
    const alloc = store.alloc;

    const path_z = try alloc.dupeZ(u8, git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, path_z.ptr));
    defer c.git_repository_free(repo);

    var head_oid: c.git_oid = undefined;
    if (git_ref) |r| {
        const spec_z = try alloc.dupeZ(u8, r);
        defer alloc.free(spec_z);
        var obj: ?*c.git_object = null;
        if (c.git_revparse_single(&obj, repo, spec_z.ptr) != 0) {
            var ref_buf: [512]u8 = undefined;
            const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{r});
            try check(c.git_revparse_single(&obj, repo, ref_name.ptr));
        }
        defer c.git_object_free(obj);
        var peeled: ?*c.git_object = null;
        try check(c.git_object_peel(&peeled, obj, c.GIT_OBJECT_COMMIT));
        defer c.git_object_free(peeled);
        _ = c.git_oid_cpy(&head_oid, c.git_object_id(peeled));
    } else {
        var head_ref: ?*c.git_reference = null;
        try check(c.git_repository_head(&head_ref, repo));
        defer c.git_reference_free(head_ref);

        var commit_obj: ?*c.git_object = null;
        try check(c.git_reference_peel(&commit_obj, head_ref, c.GIT_OBJECT_COMMIT));
        defer c.git_object_free(commit_obj);
        _ = c.git_oid_cpy(&head_oid, c.git_object_id(commit_obj));
    }

    var map = try Gitmap.load(store);
    defer map.deinit();

    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_REVERSE);
    try check(c.git_revwalk_push(walk, &head_oid));

    lfs_unresolved = 0;
    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| {
        lfs_unresolved = s.unresolved;
        s.deinit();
    };

    var tip: Oid = Oid.zero();
    var woid: c.git_oid = undefined;
    while (c.git_revwalk_next(&woid, walk) == 0) {
        tip = try importCommit(store, repo, &map, &woid, if (session) |*s| s else null);
    }

    try map.save(store);

    return tip;
}

/// Push every local branch tip and every tag's target commit onto `walk`, so it
/// covers exactly the history an import has to cover.
fn pushImportTips(walk: ?*c.git_revwalk, repo: ?*c.git_repository) void {
    {
        var iter: ?*c.git_branch_iterator = null;
        if (c.git_branch_iterator_new(&iter, repo, c.GIT_BRANCH_LOCAL) == 0) {
            defer c.git_branch_iterator_free(iter);
            var ref: ?*c.git_reference = null;
            var btype: c.git_branch_t = undefined;
            while (c.git_branch_next(&ref, &btype, iter) == 0) {
                defer c.git_reference_free(ref);
                var obj: ?*c.git_object = null;
                if (c.git_reference_peel(&obj, ref, c.GIT_OBJECT_COMMIT) == 0) {
                    defer c.git_object_free(obj);
                    _ = c.git_revwalk_push(walk, c.git_object_id(obj));
                }
            }
        }
    }
    {
        var tagnames: c.git_strarray = undefined;
        if (c.git_tag_list(&tagnames, repo) == 0) {
            defer c.git_strarray_dispose(&tagnames);
            var i: usize = 0;
            while (i < tagnames.count) : (i += 1) {
                var rbuf: [512]u8 = undefined;
                const rn = std.fmt.bufPrintZ(&rbuf, "refs/tags/{s}", .{std.mem.span(tagnames.strings[i])}) catch continue;
                var ref: ?*c.git_reference = null;
                if (c.git_reference_lookup(&ref, repo, rn.ptr) != 0) continue;
                defer c.git_reference_free(ref);
                var obj: ?*c.git_object = null;
                if (c.git_reference_peel(&obj, ref, c.GIT_OBJECT_COMMIT) == 0) {
                    defer c.git_object_free(obj);
                    _ = c.git_revwalk_push(walk, c.git_object_id(obj));
                }
            }
        }
    }
}

/// Import ALL local branches and ALL tags (each with full history) from the git
/// repo into `store`. Shared ancestry is imported once (deduped via the gitmap).
/// Creates gr `refs/heads/<name>` for each local branch and `refs/tags/<name>`
/// for each tag (peeled to its commit). Points gr HEAD at the git repo's HEAD
/// branch. Lossless in structure/content/metadata (git SHAs are not preserved;
/// gr re-hashes with its own content-addressed store).
pub fn importAll(store: *Store, git_repo_path: []const u8, progress: ?*Progress) !void {
    ensureInit();
    const alloc = store.alloc;

    const path_z = try alloc.dupeZ(u8, git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, path_z.ptr));
    defer c.git_repository_free(repo);

    var map = try Gitmap.load(store);
    defer map.deinit();

    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL | c.GIT_SORT_REVERSE);
    pushImportTips(walk, repo);

    // Count the walk up front so the import bar has a real denominator. Only
    // worth the second pass when someone is watching it.
    var total_commits: ?u64 = null;
    if (progress != null and ui.isTty()) {
        var counter: ?*c.git_revwalk = null;
        if (c.git_revwalk_new(&counter, repo) == 0) {
            defer c.git_revwalk_free(counter);
            _ = c.git_revwalk_sorting(counter, c.GIT_SORT_TOPOLOGICAL);
            pushImportTips(counter, repo);
            var n: u64 = 0;
            var coid: c.git_oid = undefined;
            while (c.git_revwalk_next(&coid, counter) == 0) n += 1;
            total_commits = n;
        }
    }

    lfs_unresolved = 0;
    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| {
        lfs_unresolved = s.unresolved;
        s.deinit();
    };

    // Import the whole reachable DAG oldest-first.
    var woid: c.git_oid = undefined;
    var imported: u64 = 0;
    errdefer if (progress) |p| p.finish();
    while (c.git_revwalk_next(&woid, walk) == 0) {
        _ = try importCommit(store, repo, &map, &woid, if (session) |*s| s else null);
        imported += 1;
        if (progress) |p| p.update(.importing, imported, total_commits);
    }
    if (progress) |p| {
        if (total_commits) |t| p.update(.importing, t, t);
        p.finish();
    }

    // Create sdt branch refs.
    {
        var iter: ?*c.git_branch_iterator = null;
        try check(c.git_branch_iterator_new(&iter, repo, c.GIT_BRANCH_LOCAL));
        defer c.git_branch_iterator_free(iter);
        var ref: ?*c.git_reference = null;
        var btype: c.git_branch_t = undefined;
        while (c.git_branch_next(&ref, &btype, iter) == 0) {
            defer c.git_reference_free(ref);
            var name_c: [*c]const u8 = null;
            if (c.git_branch_name(&name_c, ref) != 0) continue;
            var obj: ?*c.git_object = null;
            if (c.git_reference_peel(&obj, ref, c.GIT_OBJECT_COMMIT) != 0) continue;
            defer c.git_object_free(obj);
            const chex = gitOidHex(c.git_object_id(obj));
            if (map.lookupGr(&chex)) |gr| try store.updateRef(std.mem.span(name_c), gr);
        }
    }
    // Create gr tag refs (lightweight; hex + '\n').
    {
        var tagnames: c.git_strarray = undefined;
        if (c.git_tag_list(&tagnames, repo) == 0) {
            defer c.git_strarray_dispose(&tagnames);
            if (tagnames.count > 0) try store.root.createDirPath(store.io, "refs/tags");
            var i: usize = 0;
            while (i < tagnames.count) : (i += 1) {
                const tname = std.mem.span(tagnames.strings[i]);
                var rbuf: [512]u8 = undefined;
                const rn = std.fmt.bufPrintZ(&rbuf, "refs/tags/{s}", .{tname}) catch continue;
                var ref: ?*c.git_reference = null;
                if (c.git_reference_lookup(&ref, repo, rn.ptr) != 0) continue;
                defer c.git_reference_free(ref);
                var obj: ?*c.git_object = null;
                if (c.git_reference_peel(&obj, ref, c.GIT_OBJECT_COMMIT) != 0) continue;
                defer c.git_object_free(obj);
                const chex = gitOidHex(c.git_object_id(obj));
                if (map.lookupGr(&chex)) |gr| {
                    var pbuf: [512]u8 = undefined;
                    const pth = std.fmt.bufPrint(&pbuf, "refs/tags/{s}", .{tname}) catch continue;
                    var hbuf: [65]u8 = undefined;
                    _ = gr.toHex(hbuf[0..64]);
                    hbuf[64] = '\n';
                    try store.root.writeFile(store.io, .{ .sub_path = pth, .data = hbuf[0..65] });
                }
            }
        }
    }

    // Point gr HEAD at the git repo's HEAD branch so gr commands resolve.
    {
        var hr: ?*c.git_reference = null;
        if (c.git_repository_head(&hr, repo) == 0) {
            defer c.git_reference_free(hr);
            const sh = c.git_reference_shorthand(hr);
            if (sh != null) try store.setHeadBranch(std.mem.span(sh));
        }
    }

    try map.save(store);
}

fn gitFilemode(mode: object.Mode) c.git_filemode_t {
    return switch (mode) {
        .executable => c.GIT_FILEMODE_BLOB_EXECUTABLE,
        .symlink => c.GIT_FILEMODE_LINK,
        else => c.GIT_FILEMODE_BLOB,
    };
}

const ExportNode = struct {
    is_dir: bool,
    children: std.StringHashMapUnmanaged(*ExportNode),
    blob_oid: c.git_oid,
    filemode: c.git_filemode_t,

    fn newDir(alloc: std.mem.Allocator) !*ExportNode {
        const n = try alloc.create(ExportNode);
        n.* = .{ .is_dir = true, .children = .{}, .blob_oid = undefined, .filemode = 0 };
        return n;
    }
};

/// Recursively write an ExportNode directory into `repo`, returning its git tree Oid.
fn writeExportTree(repo: ?*c.git_repository, node: *ExportNode) !c.git_oid {
    var bld: ?*c.git_treebuilder = null;
    try check(c.git_treebuilder_new(&bld, repo, null));
    defer c.git_treebuilder_free(bld);

    var it = node.children.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const child = kv.value_ptr.*;
        var name_z_buf: [1024]u8 = undefined;
        if (name.len >= name_z_buf.len) return Error.GitError;
        @memcpy(name_z_buf[0..name.len], name);
        name_z_buf[name.len] = 0;
        const name_z: [*c]const u8 = @ptrCast(&name_z_buf);
        if (child.is_dir) {
            var sub = try writeExportTree(repo, child);
            try check(c.git_treebuilder_insert(null, bld, name_z, &sub, c.GIT_FILEMODE_TREE));
        } else {
            try check(c.git_treebuilder_insert(null, bld, name_z, &child.blob_oid, child.filemode));
        }
    }

    var out: c.git_oid = undefined;
    try check(c.git_treebuilder_write(&out, bld));
    return out;
}

/// Split "Name <email>" into name/email spans. Falls back to the whole string.
fn splitAuthor(author: []const u8) struct { name: []const u8, email: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, author, '<')) |lt| {
        const gt = std.mem.lastIndexOfScalar(u8, author, '>') orelse author.len;
        const name = std.mem.trim(u8, author[0..lt], " \t");
        const email = if (gt > lt + 1) author[lt + 1 .. gt] else "";
        return .{
            .name = if (name.len == 0) "superdetermine" else name,
            .email = if (email.len == 0) "none@superdetermine" else email,
        };
    }
    return .{ .name = if (author.len == 0) "superdetermine" else author, .email = "none@superdetermine" };
}

/// Git blobs already written during one export, keyed by the superdetermine blob
/// they came from. Every saved state carries a FULL tree, so without this a file
/// that never changed is re-read and re-compressed once per state: exporting a
/// long history of a large tree turns quadratic and looks like a hang.
const BlobCache = struct {
    /// How the superdetermine blob was turned into git bytes. `plain` is the
    /// content verbatim, `pointer` is content that already was an LFS pointer,
    /// `cleaned` is content replaced by a pointer under the LFS rules of that
    /// state. The last two are only reusable where the same rules still apply.
    const Kind = enum { plain, pointer, cleaned };

    const Entry = struct {
        git_oid: c.git_oid,
        kind: Kind,
        lfs_oid_hex: [64]u8,
        lfs_size: u64,
    };

    map: std.AutoHashMapUnmanaged([Oid.len]u8, Entry) = .{},

    fn deinit(self: *BlobCache, alloc: std.mem.Allocator) void {
        self.map.deinit(alloc);
    }

    fn get(self: *const BlobCache, blob: Oid) ?Entry {
        return self.map.get(blob.bytes);
    }

    fn put(self: *BlobCache, alloc: std.mem.Allocator, blob: Oid, entry: Entry) !void {
        try self.map.put(alloc, blob.bytes, entry);
    }
};

/// Build a git tree object in `repo` from a superdetermine flat Tree, returning the
/// looked-up git tree (caller frees). Reuses the nested ExportNode builder.
fn buildGitTree(
    store: *Store,
    repo: ?*c.git_repository,
    tree: object.Tree,
    sess: ?*lfs.Session,
    cache: ?*BlobCache,
) !?*c.git_tree {
    const alloc = store.alloc;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();
    const root = try ExportNode.newDir(aa);

    // `.gitattributes` travels in the tree itself, so each exported change gets
    // the LFS rules that were in force at that point in history.
    var attrs = try lfs.attributesFromTree(store, tree);
    defer attrs.deinit();

    for (tree.entries) |e| {
        var blob_oid: c.git_oid = undefined;
        var reused = false;
        if (cache) |bc| {
            if (bc.get(e.blob)) |hit| {
                const usable = switch (hit.kind) {
                    .plain => sess == null or !attrs.isLfs(e.path),
                    .pointer => true,
                    .cleaned => sess != null and attrs.isLfs(e.path),
                };
                if (usable) {
                    if (sess) |s| {
                        if (hit.kind != .plain) s.markPending(&hit.lfs_oid_hex, hit.lfs_size) catch {};
                    }
                    blob_oid = hit.git_oid;
                    reused = true;
                }
            }
        }

        if (!reused) {
            const content = try store.readFileContent(e.blob);
            defer alloc.free(content);

            // Git LFS clean: a tracked path is committed to git as a pointer, with
            // the real bytes landing in the destination repo's LFS cache (and queued
            // for upload on push).
            var pointer: ?[]u8 = null;
            defer if (pointer) |p| alloc.free(p);
            var kind: BlobCache.Kind = .plain;
            var lfs_oid_hex: [64]u8 = [_]u8{0} ** 64;
            var lfs_size: u64 = 0;
            if (sess) |s| {
                if (lfs.parsePointer(content)) |existing| {
                    s.markPending(&existing.oid_hex, existing.size) catch {};
                    kind = .pointer;
                    lfs_oid_hex = existing.oid_hex;
                    lfs_size = existing.size;
                } else if (attrs.isLfs(e.path)) {
                    const hex = try s.writeObject(content);
                    s.markPending(&hex, content.len) catch {};
                    pointer = try lfs.pointerForContent(alloc, content);
                    kind = .cleaned;
                    lfs_oid_hex = hex;
                    lfs_size = content.len;
                }
            }
            const payload: []const u8 = pointer orelse content;

            try check(c.git_blob_create_from_buffer(&blob_oid, repo, payload.ptr, payload.len));
            exported_blobs += 1;
            if (cache) |bc| try bc.put(alloc, e.blob, .{
                .git_oid = blob_oid,
                .kind = kind,
                .lfs_oid_hex = lfs_oid_hex,
                .lfs_size = lfs_size,
            });
        }

        exported_files += 1;
        if (live_progress) |p| p.update(.exporting, exported_files, null);

        var cur = root;
        var comp_it = std.mem.splitScalar(u8, e.path, '/');
        var comp = comp_it.next() orelse continue;
        while (comp_it.peek() != null) : (comp = comp_it.next().?) {
            if (comp.len == 0) continue;
            const gop = try cur.children.getOrPut(aa, comp);
            if (!gop.found_existing) {
                gop.key_ptr.* = try aa.dupe(u8, comp);
                gop.value_ptr.* = try ExportNode.newDir(aa);
            }
            cur = gop.value_ptr.*;
        }
        const gop = try cur.children.getOrPut(aa, comp);
        gop.key_ptr.* = try aa.dupe(u8, comp);
        const leaf = try aa.create(ExportNode);
        leaf.* = .{ .is_dir = false, .children = .{}, .blob_oid = blob_oid, .filemode = gitFilemode(e.mode) };
        gop.value_ptr.* = leaf;
    }

    var git_tree_oid = try writeExportTree(repo, root);
    var git_tree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&git_tree, repo, &git_tree_oid));
    return git_tree;
}

/// Collect the ancestors of `tip` (inclusive) into `out` in oldest-first order
/// (a change appears after all its parents). `seen` dedups shared ancestors.
fn collectChain(store: *Store, o: Oid, out: *std.ArrayList(Oid), seen: *std.StringHashMapUnmanaged(void), alloc: std.mem.Allocator) !void {
    var hbuf: [64]u8 = undefined;
    const hx = o.toHex(&hbuf);
    if (seen.contains(hx)) return;
    try seen.put(alloc, try alloc.dupe(u8, hx), {});
    const change = try store.readChange(o);
    defer object.freeChange(alloc, change);
    for (change.parents) |p| try collectChain(store, p, out, seen, alloc);
    try out.append(alloc, o);
}

/// Export a single gr change as a git commit (parents already exported/mapped).
/// Reuses the mapped git commit if it still exists in `repo`. Root changes (no
/// gr parents) chain onto `graft` if provided (used to fast-forward onto an
/// existing branch tip). Returns the git commit id and records it in the map.
fn exportChange(store: *Store, repo: ?*c.git_repository, map: *Gitmap, gr: Oid, graft: ?*const c.git_oid, sess: ?*lfs.Session, cache: ?*BlobCache, fresh: bool) !c.git_oid {
    if (!fresh) {
        if (map.lookupGit(gr)) |existing| {
            var commit: ?*c.git_commit = null;
            if (c.git_commit_lookup(&commit, repo, &existing) == 0) {
                c.git_commit_free(commit);
                return existing;
            }
        }
    }

    const alloc = store.alloc;
    const change = try store.readChange(gr);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    const git_tree = try buildGitTree(store, repo, tree, sess, cache);
    defer c.git_tree_free(git_tree);

    const parsed = splitAuthor(change.author);
    const name_z = try alloc.dupeZ(u8, parsed.name);
    defer alloc.free(name_z);
    const email_z = try alloc.dupeZ(u8, parsed.email);
    defer alloc.free(email_z);
    var sig: ?*c.git_signature = null;
    try check(c.git_signature_new(&sig, name_z.ptr, email_z.ptr, @intCast(change.timestamp), @intCast(change.tz_offset_min)));
    defer c.git_signature_free(sig);
    const msg_z = try alloc.dupeZ(u8, change.message);
    defer alloc.free(msg_z);

    var parent_commits: std.ArrayList(?*const c.git_commit) = .empty;
    defer {
        for (parent_commits.items) |pc| c.git_commit_free(@constCast(pc));
        parent_commits.deinit(alloc);
    }
    if (change.parents.len == 0) {
        if (graft) |g| {
            var pc: ?*c.git_commit = null;
            if (c.git_commit_lookup(&pc, repo, g) == 0) try parent_commits.append(alloc, pc);
        }
    } else {
        for (change.parents) |p| {
            if (map.lookupGit(p)) |goid| {
                var pc: ?*c.git_commit = null;
                var gcopy = goid;
                if (c.git_commit_lookup(&pc, repo, &gcopy) == 0) try parent_commits.append(alloc, pc);
            }
        }
    }

    var commit_oid: c.git_oid = undefined;
    const pn: usize = parent_commits.items.len;
    if (pn == 0) {
        try check(c.git_commit_create(&commit_oid, repo, null, sig, sig, null, msg_z.ptr, git_tree, 0, null));
    } else {
        try check(c.git_commit_create(&commit_oid, repo, null, sig, sig, null, msg_z.ptr, git_tree, @intCast(pn), parent_commits.items.ptr));
    }
    const ghex = gitOidHex(&commit_oid);
    if (fresh) try map.insertLatest(&ghex, commit_oid, gr) else try map.insert(&ghex, commit_oid, gr);
    return commit_oid;
}

/// Export the full history reachable from `tip` into `repo`, oldest-first.
/// Returns the git commit id of the tip.
fn exportChain(store: *Store, repo: ?*c.git_repository, map: *Gitmap, tip: Oid, graft: ?*const c.git_oid, sess: ?*lfs.Session, fresh: bool) !c.git_oid {
    const alloc = store.alloc;
    var out: std.ArrayList(Oid) = .empty;
    defer out.deinit(alloc);
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| alloc.free(k.*);
        seen.deinit(alloc);
    }
    try collectChain(store, tip, &out, &seen, alloc);
    var cache: BlobCache = .{};
    defer cache.deinit(alloc);
    var last: c.git_oid = undefined;
    for (out.items) |o| last = try exportChange(store, repo, map, o, graft, sess, &cache, fresh);
    return last;
}

/// Pick the git branch that superdetermine branch `branch` mirrors onto, in the
/// dest repo `repo`. Caller frees.
///   - if `git_branch` is non-null, that branch is used verbatim;
///   - else if the dest repo already has a branch of the same name, that one is
///     used, so work on `feature` lands on git's `feature` and never on whatever
///     git happens to have checked out;
///   - else the dest repo's HEAD branch shorthand, unless that shorthand names
///     some OTHER superdetermine branch, in which case it is that branch's
///     mirror and must not be written to. This is what keeps the common
///     colocated case (sdt on `main`, git on `master`, no sdt `master`) updating
///     `master` as before;
///   - else it falls back to the superdetermine branch name.
fn resolveTargetBranch(
    store: *Store,
    repo: ?*c.git_repository,
    git_branch: ?[]const u8,
    branch: []const u8,
) ![]u8 {
    const alloc = store.alloc;
    if (git_branch) |gb| return alloc.dupe(u8, gb);

    var same_buf: [512]u8 = undefined;
    if (std.fmt.bufPrintZ(&same_buf, "refs/heads/{s}", .{branch})) |same_ref| {
        var same_oid: c.git_oid = undefined;
        if (c.git_reference_name_to_id(&same_oid, repo, same_ref.ptr) == 0) {
            return alloc.dupe(u8, branch);
        }
    } else |_| {}

    var head_ref: ?*c.git_reference = null;
    if (c.git_repository_head_detached(repo) == 0 and c.git_repository_head(&head_ref, repo) == 0) {
        defer c.git_reference_free(head_ref);
        const short = c.git_reference_shorthand(head_ref);
        if (short != null) {
            const name = std.mem.span(short);
            if (!store.refExists(name)) return alloc.dupe(u8, name);
        }
    }
    return alloc.dupe(u8, branch);
}

/// Export the superdetermine store's HEAD branch (FULL history) into a git repo at
/// `dest_git_repo_path`, creating (init) the repo if absent. Into a fresh repo
/// this reproduces the whole branch history losslessly (git assigns new SHAs).
pub fn exportHead(store: *Store, dest_git_repo_path: []const u8) !void {
    try exportHeadTo(store, dest_git_repo_path, null);
}

/// Branch-aware full-history export. Materializes the entire gr HEAD-branch
/// history as commits in the dest git repo on a target git branch chosen by
/// `resolveTargetBranch`.
/// If the target branch already exists, the gr root(s) are grafted onto its tip
/// so the update fast-forwards rather than replacing existing history (unforced
/// exports only; see `exportHeadToForced`).
pub fn exportHeadTo(store: *Store, dest_git_repo_path: []const u8, git_branch: ?[]const u8) !void {
    try exportHeadToForced(store, dest_git_repo_path, git_branch, false);
}

/// As `exportHeadTo`, but `force` opts out of the fast-forward guard and of the
/// graft, and rebuilds the chain's commits from sdt truth instead of reusing the
/// gitmap's existing ones, so a chain that was previously exported grafted is
/// repaired rather than replayed. It is how the caller says "yes, drop the
/// git-side commits I was just shown".
pub fn exportHeadToForced(store: *Store, dest_git_repo_path: []const u8, git_branch: ?[]const u8, force: bool) !void {
    ensureInit();
    exported_files = 0;
    exported_blobs = 0;
    const alloc = store.alloc;

    const branch = try store.headBranch();
    defer alloc.free(branch);
    const tip_gr = try store.readRef(branch);

    const path_z = try alloc.dupeZ(u8, dest_git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) {
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
    }
    defer c.git_repository_free(repo);

    const target = try resolveTargetBranch(store, repo, git_branch, branch);
    defer alloc.free(target);

    var ref_buf: [512]u8 = undefined;
    const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{target});

    var graft_oid: c.git_oid = undefined;
    const have_graft = c.git_reference_name_to_id(&graft_oid, repo, ref_name.ptr) == 0;

    var map = try Gitmap.load(store);
    defer map.deinit();

    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| s.deinit();

    const tip_git = try exportChain(store, repo, &map, tip_gr, if (have_graft and !force) &graft_oid else null, if (session) |*s| s else null, force);

    if (!force) try guardFastForward(repo, ref_name.ptr, &tip_git, target);

    var newref: ?*c.git_reference = null;
    try check(c.git_reference_create(&newref, repo, ref_name.ptr, &tip_git, 1, null));
    c.git_reference_free(newref);
    try check(c.git_repository_set_head(repo, ref_name.ptr));

    try map.save(store);
}

/// Export ALL gr branches and tags (each with full history) into `dest`. Into a
/// fresh/empty git repo this reproduces the whole project graph.
pub fn exportAll(store: *Store, dest_git_repo_path: []const u8) !void {
    try exportAllForced(store, dest_git_repo_path, false);
}

pub fn exportAllForced(store: *Store, dest_git_repo_path: []const u8, force: bool) !void {
    ensureInit();
    exported_files = 0;
    exported_blobs = 0;
    const alloc = store.alloc;

    const path_z = try alloc.dupeZ(u8, dest_git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) {
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
    }
    defer c.git_repository_free(repo);

    var map = try Gitmap.load(store);
    defer map.deinit();

    const head_branch = try store.headBranch();
    defer alloc.free(head_branch);

    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| s.deinit();

    // Export every sdt branch.
    {
        var dir = try store.root.openDir(store.io, "refs/heads", .{ .iterate = true });
        defer dir.close(store.io);
        var it = dir.iterate();
        while (try it.next(store.io)) |entry| {
            if (entry.kind != .file) continue;
            const bname = try alloc.dupe(u8, entry.name);
            defer alloc.free(bname);
            const tip_gr = store.readRef(bname) catch continue;

            var ref_buf: [512]u8 = undefined;
            const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{bname});
            var graft_oid: c.git_oid = undefined;
            const have_graft = c.git_reference_name_to_id(&graft_oid, repo, ref_name.ptr) == 0;

            const tip_git = try exportChain(store, repo, &map, tip_gr, if (have_graft and !force) &graft_oid else null, if (session) |*s| s else null, force);
            if (!force) try guardFastForward(repo, ref_name.ptr, &tip_git, bname);
            var newref: ?*c.git_reference = null;
            try check(c.git_reference_create(&newref, repo, ref_name.ptr, &tip_git, 1, null));
            c.git_reference_free(newref);
        }
    }

    // Point HEAD at the gr HEAD branch if it was exported.
    {
        var ref_buf: [512]u8 = undefined;
        const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{head_branch});
        var tmp_oid: c.git_oid = undefined;
        if (c.git_reference_name_to_id(&tmp_oid, repo, ref_name.ptr) == 0) {
            _ = c.git_repository_set_head(repo, ref_name.ptr);
        }
    }

    // Export every gr tag as a lightweight git tag.
    if (store.root.openDir(store.io, "refs/tags", .{ .iterate = true })) |*tdir_const| {
        var tdir = tdir_const.*;
        defer tdir.close(store.io);
        var it = tdir.iterate();
        while (try it.next(store.io)) |entry| {
            if (entry.kind != .file) continue;
            var pbuf: [512]u8 = undefined;
            const pth = try std.fmt.bufPrint(&pbuf, "refs/tags/{s}", .{entry.name});
            const data = store.root.readFileAlloc(store.io, pth, alloc, .unlimited) catch continue;
            defer alloc.free(data);
            const trimmed = std.mem.trim(u8, data, "\n \t\r");
            const gr = Oid.fromHex(trimmed) catch continue;
            const git_oid = map.lookupGit(gr) orelse continue;
            var target_obj: ?*c.git_object = null;
            var gcopy = git_oid;
            if (c.git_object_lookup(&target_obj, repo, &gcopy, c.GIT_OBJECT_COMMIT) != 0) continue;
            defer c.git_object_free(target_obj);
            var tref_buf: [512]u8 = undefined;
            const tref = try std.fmt.bufPrintZ(&tref_buf, "refs/tags/{s}", .{entry.name});
            var tag_ref: ?*c.git_reference = null;
            if (c.git_reference_create(&tag_ref, repo, tref.ptr, &gcopy, 1, null) == 0) {
                c.git_reference_free(tag_ref);
            }
        }
    } else |_| {}

    try map.save(store);
}

/// Export ONLY the gr HEAD tip change as a single commit chained onto the target
/// branch's existing tip (fast-forward). Used by `pushRemote` so pushing to an
/// existing remote does not rewrite or replay entire gr history there.
fn exportTipOnto(store: *Store, dest_git_repo_path: []const u8, git_branch: ?[]const u8, sess: ?*lfs.Session) !void {
    ensureInit();
    exported_files = 0;
    exported_blobs = 0;
    const alloc = store.alloc;

    const branch = try store.headBranch();
    defer alloc.free(branch);
    const change_oid = try store.readRef(branch);
    const change = try store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    const path_z = try alloc.dupeZ(u8, dest_git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) {
        try check(c.git_repository_init(&repo, path_z.ptr, 0));
    }
    defer c.git_repository_free(repo);

    const target = try resolveTargetBranch(store, repo, git_branch, branch);
    defer alloc.free(target);

    const git_tree = try buildGitTree(store, repo, tree, sess, null);
    defer c.git_tree_free(git_tree);

    const parsed = splitAuthor(change.author);
    const name_z = try alloc.dupeZ(u8, parsed.name);
    defer alloc.free(name_z);
    const email_z = try alloc.dupeZ(u8, parsed.email);
    defer alloc.free(email_z);

    var sig: ?*c.git_signature = null;
    try check(c.git_signature_new(&sig, name_z.ptr, email_z.ptr, @intCast(change.timestamp), @intCast(change.tz_offset_min)));
    defer c.git_signature_free(sig);

    const msg_z = try alloc.dupeZ(u8, change.message);
    defer alloc.free(msg_z);

    var ref_buf: [512]u8 = undefined;
    const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{target});

    var parent_commit: ?*c.git_commit = null;
    defer if (parent_commit) |pc| c.git_commit_free(pc);
    var tip_oid: c.git_oid = undefined;
    if (c.git_reference_name_to_id(&tip_oid, repo, ref_name.ptr) == 0) {
        _ = c.git_commit_lookup(&parent_commit, repo, &tip_oid);
    }

    var commit_oid: c.git_oid = undefined;
    if (parent_commit) |pc| {
        var parents = [_]?*const c.git_commit{pc};
        try check(c.git_commit_create(&commit_oid, repo, null, sig, sig, null, msg_z.ptr, git_tree, 1, &parents));
    } else {
        try check(c.git_commit_create(&commit_oid, repo, null, sig, sig, null, msg_z.ptr, git_tree, 0, null));
    }

    try guardFastForward(repo, ref_name.ptr, &commit_oid, target);

    var newref: ?*c.git_reference = null;
    try check(c.git_reference_create(&newref, repo, ref_name.ptr, &commit_oid, 1, null));
    c.git_reference_free(newref);

    try check(c.git_repository_set_head(repo, ref_name.ptr));
}

/// Clone a git repo (local path or file:// URL) into `into_dir`, then import its
/// HEAD into `store` so the superdetermine ref is populated.
pub fn cloneGit(store: *Store, url_or_path: []const u8, into_dir: []const u8) !void {
    try cloneGitOnly(store.alloc, url_or_path, into_dir, null);
    try importAll(store, into_dir, null);
}

pub fn cloneGitOnly(
    alloc: std.mem.Allocator,
    url_or_path: []const u8,
    into_dir: []const u8,
    progress: ?*Progress,
) !void {
    ensureInit();

    const url_z = try alloc.dupeZ(u8, url_or_path);
    defer alloc.free(url_z);
    const into_z = try alloc.dupeZ(u8, into_dir);
    defer alloc.free(into_z);

    resetCredCache();
    g_cred.token = envToken();

    var opts: c.git_clone_options = undefined;
    try check(c.git_clone_options_init(&opts, c.GIT_CLONE_OPTIONS_VERSION));
    opts.fetch_opts.callbacks.credentials = credentialsCb;
    if (progress) |p| {
        opts.fetch_opts.callbacks.transfer_progress = transferProgressCb;
        opts.fetch_opts.callbacks.payload = @ptrCast(p);
        opts.checkout_opts.progress_cb = checkoutProgressCb;
        opts.checkout_opts.progress_payload = @ptrCast(p);
    }

    var repo: ?*c.git_repository = null;
    errdefer if (progress) |p| p.finish();
    try check(c.git_clone(&repo, url_z.ptr, into_z.ptr, &opts));
    c.git_repository_free(repo);
    if (progress) |p| p.finish();
}

/// Ensure `.sdt/gitmirror` exists as a real git repo and return its absolute path.
/// Caller frees the returned slice.
fn mirrorRepoPath(store: *Store) ![:0]u8 {
    const io = store.io;
    const alloc = store.alloc;
    try store.root.createDirPath(io, "gitmirror");
    const abs = try store.root.realPathFileAlloc(io, "gitmirror", alloc);
    errdefer alloc.free(abs);
    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, abs.ptr) != 0) {
        try check(c.git_repository_init(&repo, abs.ptr, 0));
    }
    c.git_repository_free(repo);
    return abs;
}

/// Collect every Git LFS pointer blob in a git tree, recursively, as batch
/// requests. Caller frees each `oid_hex` and the list.
fn collectTreePointers(
    alloc: std.mem.Allocator,
    repo: ?*c.git_repository,
    tree: ?*c.git_tree,
    out: *std.ArrayList(lfs.Request),
) !void {
    const n = c.git_tree_entrycount(tree);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const entry = c.git_tree_entry_byindex(tree, i);
        const etype = c.git_tree_entry_type(entry);
        if (etype == c.GIT_OBJECT_TREE) {
            var sub: ?*c.git_tree = null;
            if (c.git_tree_lookup(&sub, repo, c.git_tree_entry_id(entry)) != 0) continue;
            defer c.git_tree_free(sub);
            try collectTreePointers(alloc, repo, sub, out);
            continue;
        }
        if (etype != c.GIT_OBJECT_BLOB) continue;
        var blob: ?*c.git_blob = null;
        if (c.git_blob_lookup(&blob, repo, c.git_tree_entry_id(entry)) != 0) continue;
        defer c.git_blob_free(blob);
        const size: usize = @intCast(c.git_blob_rawsize(blob));
        if (size == 0 or size > lfs.max_pointer_bytes) continue;
        const bytes = @as([*]const u8, @ptrCast(c.git_blob_rawcontent(blob)))[0..size];
        const p = lfs.parsePointer(bytes) orelse continue;
        const hex = try alloc.dupe(u8, &p.oid_hex);
        errdefer alloc.free(hex);
        try out.append(alloc, .{ .oid_hex = hex, .size = p.size });
    }
}

/// Upload the LFS objects backing `branch`'s tip tree that `remote_url` does not
/// already have. Runs before the git push so the remote never ends up with
/// pointers whose content is missing. Best-effort: a repo with no LFS content,
/// no endpoint or no local cache simply uploads nothing.
fn uploadLfsForBranch(
    store: *Store,
    repo: ?*c.git_repository,
    branch: []const u8,
    remote_url: []const u8,
) !usize {
    const alloc = store.alloc;

    var ref_buf: [512]u8 = undefined;
    const ref_name = std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{branch}) catch return 0;
    var tip: c.git_oid = undefined;
    if (c.git_reference_name_to_id(&tip, repo, ref_name.ptr) != 0) return 0;
    var commit: ?*c.git_commit = null;
    if (c.git_commit_lookup(&commit, repo, &tip) != 0) return 0;
    defer c.git_commit_free(commit);
    var tree: ?*c.git_tree = null;
    if (c.git_commit_tree(&tree, commit) != 0) return 0;
    defer c.git_tree_free(tree);

    var reqs: std.ArrayList(lfs.Request) = .empty;
    defer {
        for (reqs.items) |r| alloc.free(r.oid_hex);
        reqs.deinit(alloc);
    }
    try collectTreePointers(alloc, repo, tree, &reqs);
    if (reqs.items.len == 0) return 0;

    var session = lfsSessionFor(store, repo, remote_url) orelse return 0;
    defer session.deinit();
    return session.uploadObjects(reqs.items) catch 0;
}

/// Push `refspec` from the git repo at `repo_path` with the git CLI.
///
/// libgit2 builds the whole pack with the connection to the remote already
/// open, so a first push of a long history can spend minutes on delta
/// compression without writing a byte; the remote gives up and the push dies
/// with a bare transport error where `git push` of the very same refspec
/// succeeds. git streams the pack as it builds it, and brings the user's
/// credential helper with it, so it is the fallback for exactly that case.
/// stderr is inherited, so git's own progress and any refusal from the remote
/// reach the terminal.
fn pushViaGitCli(alloc: std.mem.Allocator, repo_path: []const u8, remote_url: []const u8, refspec: []const u8) !void {
    const out = proc.capture(alloc, &.{ "git", "-C", repo_path, "push", remote_url, refspec }, "") catch return Error.GitError;
    defer out.deinit(alloc);
    if (!out.ok()) return Error.GitError;
}

/// Push superdetermine HEAD to an actual git remote (https/ssh/file://) via libgit2's
/// smart protocol. Exports HEAD into the managed `.sdt/gitmirror` repo, then
/// pushes `refspec` (default `refs/heads/<branch>:refs/heads/<branch>`) to
/// `remote_url`. Auth: GIT_TOKEN/GITHUB_TOKEN as https userpass, else ssh agent.
pub fn pushRemote(store: *Store, remote_url: []const u8, branch_opt: ?[]const u8) !void {
    ensureInit();
    const alloc = store.alloc;

    const gr_branch = try store.headBranch();
    defer alloc.free(gr_branch);
    const branch = if (branch_opt) |b| b else gr_branch;

    const mirror_abs = try mirrorRepoPath(store);
    defer alloc.free(mirror_abs);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, mirror_abs.ptr));
    defer c.git_repository_free(repo);

    const url_z = try alloc.dupeZ(u8, remote_url);
    defer alloc.free(url_z);
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_create_anonymous(&remote, repo, url_z.ptr));
    defer c.git_remote_free(remote);

    resetCredCache();
    g_cred.token = envToken();

    // Fetch-first: pull the remote branch (if it exists) into the mirror so that
    // our new commit chains onto the remote tip and pushes fast-forward.
    const fetch_rs = try std.fmt.allocPrintSentinel(alloc, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch }, 0);
    defer alloc.free(fetch_rs);
    {
        var fr_arr = [_][*c]u8{fetch_rs.ptr};
        var fr_strarr = c.git_strarray{ .strings = &fr_arr, .count = 1 };
        var fopts: c.git_fetch_options = undefined;
        try check(c.git_fetch_options_init(&fopts, c.GIT_FETCH_OPTIONS_VERSION));
        fopts.callbacks.credentials = credentialsCb;
        // Best-effort: ignore errors (e.g. remote branch does not exist yet).
        _ = c.git_remote_fetch(remote, &fr_strarr, &fopts, null);
    }

    // Export superdetermine HEAD onto the target branch in the mirror. If the fetch
    // above populated refs/heads/<branch>, exportTipOnto chains onto that tip.
    lfs_uploaded = 0;
    var session = lfsSessionFor(store, repo, remote_url);
    defer if (session) |*s| s.deinit();
    try exportTipOnto(store, mirror_abs, branch, if (session) |*s| s else null);
    if (session) |*s| lfs_uploaded = s.flushPending() catch 0;

    const rs = try std.fmt.allocPrintSentinel(alloc, "refs/heads/{s}:refs/heads/{s}", .{ branch, branch }, 0);
    defer alloc.free(rs);
    var rs_arr = [_][*c]u8{rs.ptr};
    var strarr = c.git_strarray{ .strings = &rs_arr, .count = 1 };

    var opts: c.git_push_options = undefined;
    try check(c.git_push_options_init(&opts, c.GIT_PUSH_OPTIONS_VERSION));
    opts.callbacks.credentials = credentialsCb;
    // Auto-detect the thread count instead of compressing on one core, so the
    // remote is not left waiting through a single-threaded delta search.
    opts.pb_parallelism = 0;
    if (live_progress) |p| {
        opts.callbacks.pack_progress = packProgressCb;
        opts.callbacks.push_transfer_progress = pushTransferProgressCb;
        opts.callbacks.payload = @ptrCast(p);
    }

    check(c.git_remote_push(remote, &strarr, &opts)) catch |e| {
        if (live_progress) |p| p.finish();
        pushViaGitCli(alloc, mirror_abs, remote_url, rs) catch return e;
    };
}

/// Push a COLOCATED git repo's branch directly to a remote. Used when a `.git`
/// already exists next to `.sdt`: dual-write commits live in that repo, so we
/// push it as-is (keeping local `.git` and the remote identical) instead of
/// synthesizing a divergent history in the mirror.
pub fn pushColocated(store: *Store, work_dir_path: []const u8, remote_url: []const u8, branch: []const u8, force: bool) !void {
    ensureInit();
    const alloc = store.alloc;

    const path_z = try alloc.dupeZ(u8, work_dir_path);
    defer alloc.free(path_z);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, path_z.ptr));
    defer c.git_repository_free(repo);

    const url_z = try alloc.dupeZ(u8, remote_url);
    defer alloc.free(url_z);
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_create_anonymous(&remote, repo, url_z.ptr));
    defer c.git_remote_free(remote);

    resetCredCache();
    g_cred.token = envToken();

    lfs_uploaded = uploadLfsForBranch(store, repo, branch, remote_url) catch 0;

    const prefix = if (force) "+" else "";
    const rs = try std.fmt.allocPrintSentinel(alloc, "{s}refs/heads/{s}:refs/heads/{s}", .{ prefix, branch, branch }, 0);
    defer alloc.free(rs);
    var rs_arr = [_][*c]u8{rs.ptr};
    var strarr = c.git_strarray{ .strings = &rs_arr, .count = 1 };

    var opts: c.git_push_options = undefined;
    try check(c.git_push_options_init(&opts, c.GIT_PUSH_OPTIONS_VERSION));
    opts.callbacks.credentials = credentialsCb;
    // Auto-detect the thread count instead of compressing on one core, so the
    // remote is not left waiting through a single-threaded delta search.
    opts.pb_parallelism = 0;
    if (live_progress) |p| {
        opts.callbacks.pack_progress = packProgressCb;
        opts.callbacks.push_transfer_progress = pushTransferProgressCb;
        opts.callbacks.payload = @ptrCast(p);
    }
    check(c.git_remote_push(remote, &strarr, &opts)) catch |e| {
        if (live_progress) |p| p.finish();
        pushViaGitCli(alloc, work_dir_path, remote_url, rs) catch return e;
    };
}

/// Pull from an actual git remote (https/ssh/file://) into superdetermine. Fetches
/// heads into the managed `.sdt/gitmirror` repo, points its HEAD at the current
/// branch, then imports that HEAD so the superdetermine ref updates.
pub fn pullRemote(store: *Store, remote_url: []const u8) !void {
    var f = try fetchRemote(store, remote_url, null, null);
    f.deinit(store.alloc);
}

/// What a fetch brought back: the imported tip and the remote branch it came
/// from. `branch` is heap-allocated.
pub const Fetched = struct {
    tip: Oid,
    branch: []u8,

    pub fn deinit(self: *Fetched, alloc: std.mem.Allocator) void {
        alloc.free(self.branch);
    }
};

/// Fetch every branch of `remote_url` into the managed `.sdt/gitmirror`, then
/// import one of them into `store`. `branch_opt` names the wanted remote branch;
/// with none, the sdt HEAD branch is preferred, then `main`/`master`, then the
/// only branch there is. `dest_branch` is the sdt ref that ends up at the
/// imported tip (null means the sdt HEAD branch), so a caller can land the
/// remote history beside its own instead of on top of it.
pub fn fetchRemote(
    store: *Store,
    remote_url: []const u8,
    branch_opt: ?[]const u8,
    dest_branch: ?[]const u8,
) !Fetched {
    ensureInit();
    const alloc = store.alloc;

    const mirror_abs = try mirrorRepoPath(store);
    defer alloc.free(mirror_abs);

    const head_branch = try store.headBranch();
    defer alloc.free(head_branch);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, mirror_abs.ptr));
    defer c.git_repository_free(repo);

    const url_z = try alloc.dupeZ(u8, remote_url);
    defer alloc.free(url_z);
    var remote: ?*c.git_remote = null;
    try check(c.git_remote_create_anonymous(&remote, repo, url_z.ptr));
    defer c.git_remote_free(remote);

    const rs = try alloc.dupeZ(u8, "+refs/heads/*:refs/heads/*");
    defer alloc.free(rs);
    var rs_arr = [_][*c]u8{rs.ptr};
    var strarr = c.git_strarray{ .strings = &rs_arr, .count = 1 };

    resetCredCache();
    g_cred.token = envToken();
    var opts: c.git_fetch_options = undefined;
    try check(c.git_fetch_options_init(&opts, c.GIT_FETCH_OPTIONS_VERSION));
    opts.callbacks.credentials = credentialsCb;

    try check(c.git_remote_fetch(remote, &strarr, &opts, null));

    const chosen = (try pickFetchedBranch(store, repo, branch_opt, head_branch)) orelse {
        return Error.GitError;
    };
    errdefer alloc.free(chosen);

    const tip = try importRefTo(store, mirror_abs, chosen, dest_branch);
    return .{ .tip = tip, .branch = chosen };
}

/// Which branch in the mirror the pull should land. Records a message naming
/// what the remote actually has when nothing matches, so the caller can say so.
fn pickFetchedBranch(
    store: *Store,
    repo: ?*c.git_repository,
    branch_opt: ?[]const u8,
    head_branch: []const u8,
) !?[]u8 {
    const alloc = store.alloc;

    var names: c.git_strarray = undefined;
    var have_names = false;
    if (c.git_reference_list(&names, repo) == 0) have_names = true;
    defer if (have_names) c.git_strarray_dispose(&names);

    var local: std.ArrayList([]const u8) = .empty;
    defer local.deinit(alloc);
    if (have_names) {
        var i: usize = 0;
        while (i < names.count) : (i += 1) {
            const n = std.mem.span(names.strings[i]);
            if (!std.mem.startsWith(u8, n, "refs/heads/")) continue;
            try local.append(alloc, n["refs/heads/".len..]);
        }
    }

    const explicit = branch_opt != null;
    var wanted: [3][]const u8 = undefined;
    var nw: usize = 0;
    if (branch_opt) |b| {
        wanted[nw] = b;
        nw += 1;
    } else {
        wanted[nw] = head_branch;
        nw += 1;
        wanted[nw] = "main";
        nw += 1;
        wanted[nw] = "master";
        nw += 1;
    }
    for (wanted[0..nw]) |cand| {
        for (local.items) |have| {
            if (std.mem.eql(u8, have, cand)) return try alloc.dupe(u8, cand);
        }
    }
    if (!explicit and local.items.len == 1) return try alloc.dupe(u8, local.items[0]);

    var msg: std.ArrayList(u8) = .empty;
    defer msg.deinit(alloc);
    if (explicit) {
        try msg.appendSlice(alloc, "the remote has no branch '");
        try msg.appendSlice(alloc, branch_opt.?);
        try msg.appendSlice(alloc, "'");
    } else {
        try msg.appendSlice(alloc, "cannot tell which remote branch to pull");
    }
    if (local.items.len == 0) {
        try msg.appendSlice(alloc, "; it has no branches at all");
    } else {
        try msg.appendSlice(alloc, "; it has: ");
        for (local.items, 0..) |b, i| {
            if (i != 0) try msg.appendSlice(alloc, ", ");
            try msg.appendSlice(alloc, b);
        }
    }
    recordError(msg.items);
    return null;
}

/// Push superdetermine HEAD. If `target` looks like a URL/remote (contains "://",
/// "git@", or scp-style "user@host:"), performs a real remote push; otherwise
/// exports HEAD into a local git repo path (backward-compatible behavior).
pub fn pushHead(store: *Store, target: []const u8) !void {
    if (looksRemote(target)) return pushRemote(store, target, null);
    try exportHead(store, target);
}

/// Pull into superdetermine. If `target` looks like a URL/remote, performs a real
/// remote fetch; otherwise imports HEAD from a local git repo path.
pub fn pullHead(store: *Store, target: []const u8) !void {
    if (looksRemote(target)) return pullRemote(store, target);
    _ = try importHead(store, target);
}

/// Where a colocated git branch stands relative to superdetermine's own history.
pub const ColocatedState = enum {
    /// git's tip is a commit sdt exported for a change this branch still holds.
    /// The ordinary grafting mirror is right here.
    in_step,
    /// Every commit on the git branch is one sdt exported, but its tip is a
    /// change this branch no longer holds. Something rewrote sdt history out
    /// from under it, and only rebuilding git's chain from sdt truth will make
    /// the two agree.
    rewritten,
    /// The git branch holds commits sdt never exported, listed in `at_risk`.
    /// Nothing may be rewritten there.
    foreign,
    /// No colocated repo, no branch, or nothing readable to compare.
    unavailable,
};

/// Classify the colocated branch so a rewrite knows whether it may rebuild the
/// git chain, must graft, or must stop.
///
/// Errs toward `foreign`: anything unreadable counts as history worth keeping.
pub fn colocatedState(store: *Store, work_dir_path: []const u8, git_branch: ?[]const u8) ColocatedState {
    ensureInit();
    at_risk = .{};
    const alloc = store.alloc;

    const path_z = alloc.dupeZ(u8, work_dir_path) catch return .foreign;
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) return .unavailable;
    defer c.git_repository_free(repo);

    const branch = store.headBranch() catch return .unavailable;
    defer alloc.free(branch);
    if (!store.refExists(branch)) return .unavailable;
    const sdt_tip = store.readRef(branch) catch return .unavailable;

    const target = resolveTargetBranch(store, repo, git_branch, branch) catch return .foreign;
    defer alloc.free(target);

    const bn = @min(target.len, at_risk.branch_buf.len);
    @memcpy(at_risk.branch_buf[0..bn], target[0..bn]);
    at_risk.branch_len = bn;

    var ref_buf: [512]u8 = undefined;
    const ref_name = std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{target}) catch return .foreign;

    var tip: c.git_oid = undefined;
    // Nothing there yet: an ordinary export creates it.
    if (c.git_reference_name_to_id(&tip, repo, ref_name.ptr) != 0) return .in_step;

    var map = Gitmap.load(store) catch return .foreign;
    defer map.deinit();

    var walk: ?*c.git_revwalk = null;
    if (c.git_revwalk_new(&walk, repo) != 0) return .foreign;
    defer c.git_revwalk_free(walk);
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL);
    if (c.git_revwalk_push(walk, &tip) != 0) return .foreign;

    var woid: c.git_oid = undefined;
    var seen: usize = 0;
    while (c.git_revwalk_next(&woid, walk) == 0) {
        seen += 1;
        // A history this long is not one to move on an inference.
        if (seen > 100_000) return .foreign;

        const hex = gitOidHex(&woid);
        if (map.lookupGr(hex[0..]) != null) continue;

        at_risk.total += 1;
        const i = at_risk.shown;
        if (i >= at_risk.ids.len) continue;
        at_risk.ids[i] = hex;
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &woid) == 0) {
            defer c.git_commit_free(commit);
            const sm = c.git_commit_summary(commit);
            if (sm != null) {
                const text = std.mem.span(sm);
                const n = @min(text.len, at_risk.subject_bufs[i].len);
                @memcpy(at_risk.subject_bufs[i][0..n], text[0..n]);
                at_risk.subject_lens[i] = n;
            }
        }
        at_risk.shown += 1;
    }
    if (at_risk.total != 0) return .foreign;

    // Every commit there is ours. The question left is whether the change git
    // is standing on is still on this branch.
    const tip_hex = gitOidHex(&tip);
    const stands_on = map.lookupGr(tip_hex[0..]) orelse return .foreign;

    var cur = sdt_tip;
    var walked: usize = 0;
    while (walked < 100_000) : (walked += 1) {
        if (cur.eql(stands_on)) return .in_step;
        const change = store.readChange(cur) catch return .rewritten;
        defer object.freeChange(alloc, change);
        if (change.parents.len == 0) break;
        cur = change.parents[0];
    }
    return .rewritten;
}

/// Mirror superdetermine HEAD into a colocated git repo at `work_dir_path`, so `git log`
/// there reflects superdetermine's current change ("sdt and git coexist live").
pub fn syncColocated(store: *Store, work_dir_path: []const u8) !void {
    try syncColocatedTo(store, work_dir_path, null);
}

/// As `syncColocated`, but onto an explicit git branch. The sdt branch and the
/// git branch need not share a name: `init.defaultBranch = main` with a git repo
/// on `master` is the common case, and the sdt history lands on `master` there.
pub fn syncColocatedTo(store: *Store, work_dir_path: []const u8, git_branch: ?[]const u8) !void {
    try syncColocatedForced(store, work_dir_path, git_branch, false);
}

pub fn syncColocatedForced(store: *Store, work_dir_path: []const u8, git_branch: ?[]const u8, force: bool) !void {
    try exportHeadToForced(store, work_dir_path, git_branch, force);
    // gr wrote the commit straight to the branch ref, which leaves git's index
    // stale relative to the new HEAD (so `git status`/`git diff` show garbage).
    // Reset the index (MIXED: HEAD + index, working tree untouched) so git stays
    // consistent and `git status` shows exactly what changed since the sdt save.
    resetIndexToHead(store, work_dir_path) catch {};
}

/// What a git revision string meant to superdetermine. `missing` covers both
/// "no colocated git repo" and "git does not know that revision"; `unmapped`
/// means git resolved it but sdt has never imported that commit.
pub const RefLookup = union(enum) {
    missing,
    unmapped: [40]u8,
    mapped: Oid,
};

/// Resolve a git revision (`origin/master`, `HEAD~3`, a git sha) in the repo at
/// `work_dir_path` and translate it into the sdt change it was imported as.
pub fn lookupGitRef(store: *Store, work_dir_path: []const u8, spec: []const u8) RefLookup {
    ensureInit();
    const alloc = store.alloc;

    const path_z = alloc.dupeZ(u8, work_dir_path) catch return .missing;
    defer alloc.free(path_z);
    const spec_z = alloc.dupeZ(u8, spec) catch return .missing;
    defer alloc.free(spec_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) return .missing;
    defer c.git_repository_free(repo);

    var obj: ?*c.git_object = null;
    if (c.git_revparse_single(&obj, repo, spec_z.ptr) != 0) return .missing;
    defer c.git_object_free(obj);

    var commit: ?*c.git_object = null;
    if (c.git_object_peel(&commit, obj, c.GIT_OBJECT_COMMIT) != 0) return .missing;
    defer c.git_object_free(commit);

    const hex = gitOidHex(c.git_object_id(commit));

    var map = Gitmap.load(store) catch return .{ .unmapped = hex };
    defer map.deinit();
    if (map.lookupGr(hex[0..])) |gr| return .{ .mapped = gr };
    return .{ .unmapped = hex };
}

/// Hex id of `branch`'s tip in the git repo at `work_dir_path`, or null when the
/// repo or the branch is absent.
pub fn branchTipHex(store: *Store, work_dir_path: []const u8, branch: []const u8) ?[40]u8 {
    ensureInit();
    const alloc = store.alloc;
    const path_z = alloc.dupeZ(u8, work_dir_path) catch return null;
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) return null;
    defer c.git_repository_free(repo);

    var ref_buf: [512]u8 = undefined;
    const ref_name = std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{branch}) catch return null;
    var tip: c.git_oid = undefined;
    if (c.git_reference_name_to_id(&tip, repo, ref_name.ptr) != 0) return null;
    return gitOidHex(&tip);
}

fn resetIndexToHead(store: *Store, work_dir_path: []const u8) !void {
    ensureInit();
    const alloc = store.alloc;
    const path_z = try alloc.dupeZ(u8, work_dir_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    if (c.git_repository_open(&repo, path_z.ptr) != 0) return;
    defer c.git_repository_free(repo);

    var head: ?*c.git_object = null;
    if (c.git_revparse_single(&head, repo, "HEAD") != 0) return;
    defer c.git_object_free(head);

    _ = c.git_reset(repo, head, c.GIT_RESET_MIXED, null);
}

// --- tests ---

const testing = std.testing;

test "importHead from a libgit2-created repo" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create git repo in a subdir of the tmp dir.
    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs.ptr, 0));
    defer c.git_repository_free(repo);

    // Write a file into the workdir.
    try tmp.dir.writeFile(io, .{ .sub_path = "gitrepo/hello.txt", .data = "hello from git\n" });
    try tmp.dir.createDirPath(io, "gitrepo/sub");
    try tmp.dir.writeFile(io, .{ .sub_path = "gitrepo/sub/nested.txt", .data = "nested content\n" });

    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);
    try check(c.git_index_add_bypath(index, "hello.txt"));
    try check(c.git_index_add_bypath(index, "sub/nested.txt"));
    try check(c.git_index_write(index));

    var tree_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&tree_oid, index));
    var gtree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&gtree, repo, &tree_oid));
    defer c.git_tree_free(gtree);

    var sig: ?*c.git_signature = null;
    try check(c.git_signature_now(&sig, "Nico", "nico@example.com"));
    defer c.git_signature_free(sig);

    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(
        &commit_oid,
        repo,
        "HEAD",
        sig,
        sig,
        null,
        "initial commit\n",
        gtree,
        0,
        null,
    ));

    // Now set up a superdetermine store in a different subdir and import.
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const change_oid = try importHead(&store, abs);
    try testing.expect(!change_oid.isZero());

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try testing.expect(store.refExists(branch));

    const change = try store.readChange(change_oid);
    defer object.freeChange(alloc, change);
    try testing.expectEqualStrings("Nico <nico@example.com>", change.author);

    const rtree = try store.readTree(change.tree);
    defer object.freeTree(alloc, rtree);
    try testing.expectEqual(@as(usize, 2), rtree.entries.len);

    var found_hello = false;
    var found_nested = false;
    for (rtree.entries) |e| {
        if (std.mem.eql(u8, e.path, "hello.txt")) found_hello = true;
        if (std.mem.eql(u8, e.path, "sub/nested.txt")) found_nested = true;
    }
    try testing.expect(found_hello);
    try testing.expect(found_nested);
}

test "exportHead reproduces files, author and message in a git repo" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Build a superdetermine store directly.
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const root_blob = try store.writeFileContent("root content\n");
    const nested_blob = try store.writeFileContent("nested content\n");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "root.txt", .blob = root_blob },
        .{ .mode = .regular, .path = "dir/nested.txt", .blob = nested_blob },
    };
    var sorted = entries;
    std.mem.sort(object.TreeEntry, &sorted, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = &sorted });

    const change = object.Change{
        .tree = tree_oid,
        .parents = &[_]Oid{},
        .change_id = [_]u8{3} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = -480,
        .author = "Jamil <jamil@example.com>",
        .message = "export test commit\n",
    };
    const change_oid = try store.writeChange(change);
    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, change_oid);

    // Export into a fresh git repo dir.
    try tmp.dir.createDirPath(io, "gitout");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitout", alloc);
    defer alloc.free(abs);
    try exportHead(&store, abs);

    // Reopen with libgit2 and verify.
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, abs.ptr));
    defer c.git_repository_free(repo);

    var head_ref: ?*c.git_reference = null;
    try check(c.git_repository_head(&head_ref, repo));
    defer c.git_reference_free(head_ref);

    var commit_obj: ?*c.git_object = null;
    try check(c.git_reference_peel(&commit_obj, head_ref, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(commit_obj);
    const commit: ?*c.git_commit = @ptrCast(commit_obj);

    const sig = c.git_commit_author(commit);
    try testing.expectEqualStrings("Jamil", std.mem.span(sig.*.name));
    try testing.expectEqualStrings("jamil@example.com", std.mem.span(sig.*.email));
    try testing.expectEqual(@as(i64, 1_700_000_000), @as(i64, @intCast(sig.*.when.time)));
    try testing.expectEqualStrings("export test commit\n", std.mem.span(c.git_commit_message(commit)));

    var gtree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&gtree, commit));
    defer c.git_tree_free(gtree);

    // root.txt content
    var root_entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&root_entry, gtree, "root.txt"));
    defer c.git_tree_entry_free(root_entry);
    var root_blob_obj: ?*c.git_blob = null;
    try check(c.git_blob_lookup(&root_blob_obj, repo, c.git_tree_entry_id(root_entry)));
    defer c.git_blob_free(root_blob_obj);
    const rsize: usize = @intCast(c.git_blob_rawsize(root_blob_obj));
    const rraw = @as([*]const u8, @ptrCast(c.git_blob_rawcontent(root_blob_obj)))[0..rsize];
    try testing.expectEqualStrings("root content\n", rraw);

    // dir/nested.txt content (verifies nested tree building)
    var nested_entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&nested_entry, gtree, "dir/nested.txt"));
    defer c.git_tree_entry_free(nested_entry);
    var nested_blob_obj: ?*c.git_blob = null;
    try check(c.git_blob_lookup(&nested_blob_obj, repo, c.git_tree_entry_id(nested_entry)));
    defer c.git_blob_free(nested_blob_obj);
    const nsize: usize = @intCast(c.git_blob_rawsize(nested_blob_obj));
    const nraw = @as([*]const u8, @ptrCast(c.git_blob_rawcontent(nested_blob_obj)))[0..nsize];
    try testing.expectEqualStrings("nested content\n", nraw);
}

fn buildStoreWithChange(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
    var store = try Store.init(io, alloc, dir);
    errdefer store.deinit();
    const root_blob = try store.writeFileContent("remote root\n");
    const nested_blob = try store.writeFileContent("remote nested\n");
    const entries = [_]object.TreeEntry{
        .{ .mode = .regular, .path = "root.txt", .blob = root_blob },
        .{ .mode = .regular, .path = "dir/nested.txt", .blob = nested_blob },
    };
    var sorted = entries;
    std.mem.sort(object.TreeEntry, &sorted, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = &sorted });
    const change = object.Change{
        .tree = tree_oid,
        .parents = &[_]Oid{},
        .change_id = [_]u8{7} ** 16,
        .timestamp = 1_700_000_000,
        .tz_offset_min = 0,
        .author = "Remote <remote@example.com>",
        .message = "remote push test\n",
    };
    const change_oid = try store.writeChange(change);
    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, change_oid);
    return store;
}

test "pushRemote/pullRemote over file:// to a bare repo" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Bare git repo to act as the remote.
    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    // Guardrail store with a change, then push.
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try pushRemote(&store, url, null);

    // Reopen the bare repo and assert refs/heads/main now exists with our tree.
    var check_repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&check_repo, bare_z.ptr));
    defer c.git_repository_free(check_repo);

    var tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&tip, check_repo, "refs/heads/main"));
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, check_repo, &tip));
    defer c.git_commit_free(commit);
    var gtree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&gtree, commit));
    defer c.git_tree_free(gtree);
    var nested_entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&nested_entry, gtree, "dir/nested.txt"));
    c.git_tree_entry_free(nested_entry);

    // Now pull from the bare repo into a fresh store and assert the ref appears.
    try tmp.dir.createDirPath(io, "grrepo2");
    var gr_dir2 = try tmp.dir.openDir(io, "grrepo2", .{});
    defer gr_dir2.close(io);
    var store2 = try Store.init(io, alloc, gr_dir2);
    defer store2.deinit();

    const branch2 = try store2.headBranch();
    defer alloc.free(branch2);
    try testing.expect(!store2.refExists(branch2));

    try pullRemote(&store2, url);
    try testing.expect(store2.refExists(branch2));

    const pulled_oid = try store2.readRef(branch2);
    const pulled = try store2.readChange(pulled_oid);
    defer object.freeChange(alloc, pulled);
    const ptree = try store2.readTree(pulled.tree);
    defer object.freeTree(alloc, ptree);
    try testing.expectEqual(@as(usize, 2), ptree.entries.len);
}

/// A store whose HEAD branch carries `states` saved changes over `files` paths,
/// each state rewriting exactly one of them. Every state still records the FULL
/// tree, which is what a naive export re-reads and re-compresses per state.
fn buildStoreWithHistory(
    io: std.Io,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    files: usize,
    states: usize,
) !Store {
    var store = try Store.init(io, alloc, dir);
    errdefer store.deinit();

    const entries = try alloc.alloc(object.TreeEntry, files);
    defer {
        for (entries) |e| alloc.free(e.path);
        alloc.free(entries);
    }
    for (entries, 0..) |*e, i| {
        const path = try std.fmt.allocPrint(alloc, "f{d}.txt", .{i});
        errdefer alloc.free(path);
        const body = try std.fmt.allocPrint(alloc, "file {d} v0\n", .{i});
        defer alloc.free(body);
        e.* = .{ .mode = .regular, .path = path, .blob = try store.writeFileContent(body) };
    }

    const branch = try store.headBranch();
    defer alloc.free(branch);

    var parent: [1]Oid = undefined;
    var have_parent = false;
    var n: usize = 0;
    while (n < states) : (n += 1) {
        if (n != 0) {
            const i = n % files;
            const body = try std.fmt.allocPrint(alloc, "file {d} v{d}\n", .{ i, n });
            defer alloc.free(body);
            entries[i].blob = try store.writeFileContent(body);
        }
        const sorted = try alloc.dupe(object.TreeEntry, entries);
        defer alloc.free(sorted);
        std.mem.sort(object.TreeEntry, sorted, {}, object.Tree.lessThan);
        const tree_oid = try store.writeTree(.{ .entries = sorted });
        const change_oid = try store.writeChange(.{
            .tree = tree_oid,
            .parents = if (have_parent) parent[0..1] else &[_]Oid{},
            .change_id = [_]u8{@intCast(n)} ** 16,
            .timestamp = 1_700_000_000 + @as(i64, @intCast(n)),
            .tz_offset_min = 0,
            .author = "Historian <historian@example.com>",
            .message = "saved state\n",
        });
        parent[0] = change_oid;
        have_parent = true;
        try store.updateRef(branch, change_oid);
    }
    return store;
}

test "a first push of a history compresses each file once, not once per state" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The remote exists but is empty, as a just-created GitHub repo is: no refs
    // to negotiate against, so the whole history goes over in one push.
    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    // A git repo colocated with the store, as `sdt push` finds in a repo that
    // was a git repo first.
    try tmp.dir.createDirPath(io, "work");
    const work_abs = try tmp.dir.realPathFileAlloc(io, "work", alloc);
    defer alloc.free(work_abs);
    const work_z = try alloc.dupeZ(u8, work_abs);
    defer alloc.free(work_z);
    var work_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&work_repo, work_z.ptr, 0));
    c.git_repository_free(work_repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithHistory(io, alloc, gr_dir, 6, 5);
    defer store.deinit();

    try syncColocatedForced(&store, work_abs, "master", false);

    // 5 states x 6 files are walked, but only the 6 originals and the one file
    // each later state rewrites are ever read and compressed.
    try testing.expectEqual(@as(u64, 30), exported_files);
    try testing.expectEqual(@as(u64, 10), exported_blobs);

    try pushColocated(&store, work_abs, url, "master", false);

    var check_repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&check_repo, bare_z.ptr));
    defer c.git_repository_free(check_repo);
    try testing.expectEqual(@as(usize, 5), try countCommitsFrom(check_repo, "refs/heads/master"));
}

test "cloneGit populates the superdetermine ref" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create a source git repo with a commit.
    try tmp.dir.createDirPath(io, "src");
    const src_abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(src_abs);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, src_abs.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.writeFile(io, .{ .sub_path = "src/file.txt", .data = "cloned\n" });
    var index: ?*c.git_index = null;
    try check(c.git_repository_index(&index, repo));
    defer c.git_index_free(index);
    try check(c.git_index_add_bypath(index, "file.txt"));
    try check(c.git_index_write(index));
    var t_oid: c.git_oid = undefined;
    try check(c.git_index_write_tree(&t_oid, index));
    var gtree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&gtree, repo, &t_oid));
    defer c.git_tree_free(gtree);
    var sig: ?*c.git_signature = null;
    try check(c.git_signature_now(&sig, "Src", "src@example.com"));
    defer c.git_signature_free(sig);
    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(&commit_oid, repo, "HEAD", sig, sig, null, "src commit\n", gtree, 0, null));

    // Guardrail store to clone into.
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const dest_abs = try tmp.dir.realPathFileAlloc(io, "grrepo", alloc);
    defer alloc.free(dest_abs);
    var clone_path_buf: [1024]u8 = undefined;
    const clone_path = try std.fmt.bufPrint(&clone_path_buf, "{s}/clone", .{dest_abs});

    try cloneGit(&store, src_abs, clone_path);

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try testing.expect(store.refExists(branch));
}

/// Make an initial commit on `refs/heads/master` in a repo, returning its tip oid.
fn commitInitialMaster(repo: ?*c.git_repository, file_name: [*c]const u8, content: []const u8) !c.git_oid {
    var bld: ?*c.git_treebuilder = null;
    try check(c.git_treebuilder_new(&bld, repo, null));
    defer c.git_treebuilder_free(bld);
    var blob_oid: c.git_oid = undefined;
    try check(c.git_blob_create_from_buffer(&blob_oid, repo, content.ptr, content.len));
    try check(c.git_treebuilder_insert(null, bld, file_name, &blob_oid, c.GIT_FILEMODE_BLOB));
    var tree_oid: c.git_oid = undefined;
    try check(c.git_treebuilder_write(&tree_oid, bld));
    var gtree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&gtree, repo, &tree_oid));
    defer c.git_tree_free(gtree);
    var sig: ?*c.git_signature = null;
    try check(c.git_signature_new(&sig, "Orig", "orig@example.com", 1_600_000_000, 0));
    defer c.git_signature_free(sig);
    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(&commit_oid, repo, "refs/heads/master", sig, sig, null, "initial master\n", gtree, 0, null));
    return commit_oid;
}

test "exportHead lands on existing master branch and chains onto its tip" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Non-bare git repo whose HEAD points at master.
    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    const orig_tip = try commitInitialMaster(repo, "seed.txt", "seed\n");
    try check(c.git_repository_set_head(repo, "refs/heads/master"));

    // Guardrail store with a change (default branch "main").
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try exportHead(&store, abs);

    // The commit must land on refs/heads/master, NOT main.
    var main_oid: c.git_oid = undefined;
    try testing.expect(c.git_reference_name_to_id(&main_oid, repo, "refs/heads/main") != 0);

    var master_tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&master_tip, repo, "refs/heads/master"));
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, &master_tip));
    defer c.git_commit_free(commit);

    // Chains onto the previous master tip (single parent).
    try testing.expectEqual(@as(c_uint, 1), c.git_commit_parentcount(commit));
    const parent_id = c.git_commit_parent_id(commit, 0);
    try testing.expect(c.git_oid_cmp(parent_id, &orig_tip) == 0);
}

test "pushRemote fetch-first fast-forwards an existing master branch" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Bare repo acting as the remote, seeded with an initial master commit.
    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);

    const orig_tip = try commitInitialMaster(bare_repo, "seed.txt", "seed\n");

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    // Guardrail store with a different change, push to master.
    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try pushRemote(&store, url, "master");

    // master must have advanced to a commit whose parent is the original tip.
    var check_repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&check_repo, bare_z.ptr));
    defer c.git_repository_free(check_repo);

    var new_tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&new_tip, check_repo, "refs/heads/master"));
    try testing.expect(c.git_oid_cmp(&new_tip, &orig_tip) != 0);

    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, check_repo, &new_tip));
    defer c.git_commit_free(commit);
    try testing.expectEqual(@as(c_uint, 1), c.git_commit_parentcount(commit));
    const parent_id = c.git_commit_parent_id(commit, 0);
    try testing.expect(c.git_oid_cmp(parent_id, &orig_tip) == 0);
}

fn buildStoreOnFeature(io: std.Io, alloc: std.mem.Allocator, dir: std.Io.Dir) !Store {
    var store = try buildStoreWithChange(io, alloc, dir);
    errdefer store.deinit();
    const base = try store.readRef("main");
    const tip = try writeChangeWith(&store, &[_]Oid{base}, "feature.txt", "feature\n", "feature work\n", 11, 1_700_000_200);
    try store.updateRef("feature", tip);
    try store.setHeadBranch("feature");
    return store;
}

fn initGitOnMain(io: std.Io, alloc: std.mem.Allocator, tmp: *std.Io.Dir, name: []const u8) !struct { abs: [:0]u8, repo: ?*c.git_repository, tip: c.git_oid } {
    try tmp.createDirPath(io, name);
    const abs = try tmp.realPathFileAlloc(io, name, alloc);
    errdefer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    errdefer c.git_repository_free(repo);
    const tip = try commitOnto(repo, "refs/heads/main", "seed.txt", "seed\n", "seed main\n", null, 1_600_000_000);
    try check(c.git_repository_set_head(repo, "refs/heads/main"));
    return .{ .abs = abs, .repo = repo, .tip = tip };
}

test "the mirror follows the sdt branch, not git's checked-out branch" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const git_repo = try initGitOnMain(io, alloc, &tmp.dir, "gitrepo");
    defer alloc.free(git_repo.abs);
    defer c.git_repository_free(git_repo.repo);
    const repo = git_repo.repo;
    const main_tip = git_repo.tip;

    const feature_tip = try commitOnto(repo, "refs/heads/feature", "feature.txt", "git feature\n", "git feature\n", &main_tip, 1_600_000_100);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreOnFeature(io, alloc, gr_dir);
    defer store.deinit();

    try syncColocated(&store, git_repo.abs);

    var main_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&main_after, repo, "refs/heads/main"));
    try testing.expect(c.git_oid_cmp(&main_after, &main_tip) == 0);

    var feature_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&feature_after, repo, "refs/heads/feature"));
    try testing.expect(c.git_oid_cmp(&feature_after, &feature_tip) != 0);
    try testing.expect(c.git_graph_descendant_of(repo, &feature_after, &feature_tip) == 1);
}

test "the mirror creates the sdt branch rather than writing git's checked-out one" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const git_repo = try initGitOnMain(io, alloc, &tmp.dir, "gitrepo");
    defer alloc.free(git_repo.abs);
    defer c.git_repository_free(git_repo.repo);
    const repo = git_repo.repo;
    const main_tip = git_repo.tip;

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreOnFeature(io, alloc, gr_dir);
    defer store.deinit();

    try syncColocated(&store, git_repo.abs);

    var main_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&main_after, repo, "refs/heads/main"));
    try testing.expect(c.git_oid_cmp(&main_after, &main_tip) == 0);
    try testing.expectEqual(@as(usize, 1), try countCommitsFrom(repo, "refs/heads/main"));

    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/feature"));
}

test "an explicit branch beats both the sdt branch and git's HEAD" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const git_repo = try initGitOnMain(io, alloc, &tmp.dir, "gitrepo");
    defer alloc.free(git_repo.abs);
    defer c.git_repository_free(git_repo.repo);
    const repo = git_repo.repo;
    const main_tip = git_repo.tip;

    const feature_tip = try commitOnto(repo, "refs/heads/feature", "feature.txt", "git feature\n", "git feature\n", &main_tip, 1_600_000_100);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreOnFeature(io, alloc, gr_dir);
    defer store.deinit();

    try syncColocatedTo(&store, git_repo.abs, "release");

    var main_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&main_after, repo, "refs/heads/main"));
    try testing.expect(c.git_oid_cmp(&main_after, &main_tip) == 0);
    var feature_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&feature_after, repo, "refs/heads/feature"));
    try testing.expect(c.git_oid_cmp(&feature_after, &feature_tip) == 0);
    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/release"));
}

test "the resolved branch still repairs a grafted chain when forced" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const git_repo = try initGitOnMain(io, alloc, &tmp.dir, "gitrepo");
    defer alloc.free(git_repo.abs);
    defer c.git_repository_free(git_repo.repo);
    const repo = git_repo.repo;
    const main_tip = git_repo.tip;

    _ = try commitOnto(repo, "refs/heads/feature", "feature.txt", "git feature\n", "git feature\n", &main_tip, 1_600_000_100);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreOnFeature(io, alloc, gr_dir);
    defer store.deinit();

    try syncColocated(&store, git_repo.abs);
    try testing.expectEqual(@as(usize, 4), try countCommitsFrom(repo, "refs/heads/feature"));

    try syncColocatedForced(&store, git_repo.abs, null, true);
    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/feature"));

    var main_after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&main_after, repo, "refs/heads/main"));
    try testing.expect(c.git_oid_cmp(&main_after, &main_tip) == 0);
}

/// Commit `content` at `file_name` onto `branch_ref`, chaining onto `parent` if
/// non-null. Returns the new commit oid. `ts` sets a deterministic time.
fn commitOnto(
    repo: ?*c.git_repository,
    branch_ref: [*c]const u8,
    file_name: [*c]const u8,
    content: []const u8,
    message: [*c]const u8,
    parent: ?*const c.git_oid,
    ts: c.git_time_t,
) !c.git_oid {
    var bld: ?*c.git_treebuilder = null;
    try check(c.git_treebuilder_new(&bld, repo, null));
    defer c.git_treebuilder_free(bld);
    var blob_oid: c.git_oid = undefined;
    try check(c.git_blob_create_from_buffer(&blob_oid, repo, content.ptr, content.len));
    try check(c.git_treebuilder_insert(null, bld, file_name, &blob_oid, c.GIT_FILEMODE_BLOB));
    var tree_oid: c.git_oid = undefined;
    try check(c.git_treebuilder_write(&tree_oid, bld));
    var gtree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&gtree, repo, &tree_oid));
    defer c.git_tree_free(gtree);
    var sig: ?*c.git_signature = null;
    try check(c.git_signature_new(&sig, "Auth", "auth@example.com", ts, 0));
    defer c.git_signature_free(sig);
    var commit_oid: c.git_oid = undefined;
    if (parent) |p| {
        var pc: ?*c.git_commit = null;
        try check(c.git_commit_lookup(&pc, repo, p));
        defer c.git_commit_free(pc);
        var parents = [_]?*const c.git_commit{pc};
        try check(c.git_commit_create(&commit_oid, repo, branch_ref, sig, sig, null, message, gtree, 1, &parents));
    } else {
        try check(c.git_commit_create(&commit_oid, repo, branch_ref, sig, sig, null, message, gtree, 0, null));
    }
    return commit_oid;
}

test "importHead brings full history with parent chain" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    const abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    const c1 = try commitOnto(repo, "refs/heads/master", "f.txt", "one\n", "c1\n", null, 1_600_000_001);
    const c2 = try commitOnto(repo, "refs/heads/master", "f.txt", "two\n", "c2\n", &c1, 1_600_000_002);
    _ = try commitOnto(repo, "refs/heads/master", "f.txt", "three\n", "c3\n", &c2, 1_600_000_003);
    try check(c.git_repository_set_head(repo, "refs/heads/master"));

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const tip = try importHead(&store, abs);

    // Walk gr change parents from the tip back to the root, collecting messages.
    var msgs: std.ArrayList([]u8) = .empty;
    defer {
        for (msgs.items) |m| alloc.free(m);
        msgs.deinit(alloc);
    }
    var cur = tip;
    while (true) {
        const ch = try store.readChange(cur);
        try msgs.append(alloc, try alloc.dupe(u8, ch.message));
        const has_parent = ch.parents.len == 1;
        const next = if (has_parent) ch.parents[0] else Oid.zero();
        object.freeChange(alloc, ch);
        if (!has_parent) break;
        cur = next;
    }
    try testing.expectEqual(@as(usize, 3), msgs.items.len);
    // msgs is newest->oldest; verify oldest->newest ordering.
    try testing.expectEqualStrings("c3\n", msgs.items[0]);
    try testing.expectEqualStrings("c2\n", msgs.items[1]);
    try testing.expectEqualStrings("c1\n", msgs.items[2]);
}

test "importAll brings all branches and tags with history" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    const abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    // master: two commits; feature branches off m1 with its own commit.
    const m1 = try commitOnto(repo, "refs/heads/master", "f.txt", "m1\n", "m1\n", null, 1_600_000_001);
    const m2 = try commitOnto(repo, "refs/heads/master", "f.txt", "m2\n", "m2\n", &m1, 1_600_000_002);
    _ = try commitOnto(repo, "refs/heads/feature", "g.txt", "feat\n", "feat\n", &m1, 1_600_000_003);
    try check(c.git_repository_set_head(repo, "refs/heads/master"));

    // Tag v1 on master tip (lightweight).
    var m2_commit: ?*c.git_object = null;
    try check(c.git_object_lookup(&m2_commit, repo, &m2, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(m2_commit);
    var tag_ref: ?*c.git_reference = null;
    try check(c.git_reference_create(&tag_ref, repo, "refs/tags/v1", &m2, 0, null));
    c.git_reference_free(tag_ref);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    try importAll(&store, abs, null);

    try testing.expect(store.refExists("master"));
    try testing.expect(store.refExists("feature"));

    // feature's tip change parent is the branch point (m1's gr change).
    const feat_tip = try store.readRef("feature");
    const feat = try store.readChange(feat_tip);
    defer object.freeChange(alloc, feat);
    try testing.expectEqual(@as(usize, 1), feat.parents.len);
    const branch_point = feat.parents[0];
    const bp = try store.readChange(branch_point);
    defer object.freeChange(alloc, bp);
    try testing.expectEqualStrings("m1\n", bp.message);

    // Tag ref exists on disk pointing at the master-tip gr change.
    const master_tip = try store.readRef("master");
    const tag_data = try store.root.readFileAlloc(io, "refs/tags/v1", alloc, .unlimited);
    defer alloc.free(tag_data);
    const trimmed = std.mem.trim(u8, tag_data, "\n \t\r");
    const tag_oid = try Oid.fromHex(trimmed);
    try testing.expect(tag_oid.eql(master_tip));
}

test "exportAll writes full history and multiple branches into fresh repo" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    // Build a 3-change linear history on the HEAD branch (main).
    const branch = try store.headBranch();
    defer alloc.free(branch);

    var prev: ?Oid = null;
    const msgs = [_][]const u8{ "a\n", "b\n", "c\n" };
    var last: Oid = undefined;
    for (msgs, 0..) |m, i| {
        var namebuf: [16]u8 = undefined;
        const fname = try std.fmt.bufPrint(&namebuf, "f{d}.txt", .{i});
        const blob = try store.writeFileContent(m);
        const entries = [_]object.TreeEntry{.{ .mode = .regular, .path = fname, .blob = blob }};
        const tree_oid = try store.writeTree(.{ .entries = &entries });
        const parents: []const Oid = if (prev) |p| &[_]Oid{p} else &[_]Oid{};
        const change = object.Change{
            .tree = tree_oid,
            .parents = parents,
            .change_id = [_]u8{@intCast(i)} ** 16,
            .timestamp = 1_700_000_000 + @as(i64, @intCast(i)),
            .tz_offset_min = 0,
            .author = "X <x@example.com>",
            .message = m,
        };
        const coid = try store.writeChange(change);
        try store.updateRef(branch, coid);
        prev = coid;
        last = coid;
    }
    // Second branch: point "side" at the root change ("a"), found by walking back.
    var walk_oid = last;
    while (true) {
        const ch = try store.readChange(walk_oid);
        const has = ch.parents.len == 1;
        const nxt = if (has) ch.parents[0] else Oid.zero();
        object.freeChange(alloc, ch);
        if (!has) break;
        walk_oid = nxt;
    }
    try store.updateRef("side", walk_oid);

    // Export everything into a fresh git repo.
    try tmp.dir.createDirPath(io, "gitout");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitout", alloc);
    defer alloc.free(abs);
    try exportAll(&store, abs);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, abs.ptr));
    defer c.git_repository_free(repo);

    // main has 3 commits in order c (tip) -> b -> a.
    var main_tip: c.git_oid = undefined;
    var main_ref_buf: [64]u8 = undefined;
    const main_ref = try std.fmt.bufPrintZ(&main_ref_buf, "refs/heads/{s}", .{branch});
    try check(c.git_reference_name_to_id(&main_tip, repo, main_ref.ptr));

    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    _ = c.git_revwalk_sorting(walk, c.GIT_SORT_TOPOLOGICAL);
    try check(c.git_revwalk_push(walk, &main_tip));

    var seen_msgs: std.ArrayList([]u8) = .empty;
    defer {
        for (seen_msgs.items) |mm| alloc.free(mm);
        seen_msgs.deinit(alloc);
    }
    var woid: c.git_oid = undefined;
    while (c.git_revwalk_next(&woid, walk) == 0) {
        var cm: ?*c.git_commit = null;
        try check(c.git_commit_lookup(&cm, repo, &woid));
        defer c.git_commit_free(cm);
        try seen_msgs.append(alloc, try alloc.dupe(u8, std.mem.span(c.git_commit_message(cm))));
    }
    try testing.expectEqual(@as(usize, 3), seen_msgs.items.len);
    // Topological (default newest-first): c, b, a.
    try testing.expectEqualStrings("c\n", seen_msgs.items[0]);
    try testing.expectEqualStrings("b\n", seen_msgs.items[1]);
    try testing.expectEqualStrings("a\n", seen_msgs.items[2]);

    // The second branch exists.
    var side_tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&side_tip, repo, "refs/heads/side"));
    var side_commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&side_commit, repo, &side_tip));
    defer c.git_commit_free(side_commit);
    try testing.expectEqualStrings("a\n", std.mem.span(c.git_commit_message(side_commit)));
}

/// Seed a git repo with an LFS-tracked file: `.gitattributes`, a pointer blob
/// standing in for `payload`, and `payload` itself in the repo's LFS cache.
fn commitLfsFixture(
    io: std.Io,
    alloc: std.mem.Allocator,
    tmp_dir: std.Io.Dir,
    repo: ?*c.git_repository,
    repo_sub: []const u8,
    payload: []const u8,
    cache_it: bool,
) !void {
    const pointer = try lfs.pointerForContent(alloc, payload);
    defer alloc.free(pointer);

    var bld: ?*c.git_treebuilder = null;
    try check(c.git_treebuilder_new(&bld, repo, null));
    defer c.git_treebuilder_free(bld);

    const attrs = "*.bin filter=lfs diff=lfs merge=lfs -text\n";
    var attr_oid: c.git_oid = undefined;
    try check(c.git_blob_create_from_buffer(&attr_oid, repo, attrs.ptr, attrs.len));
    try check(c.git_treebuilder_insert(null, bld, ".gitattributes", &attr_oid, c.GIT_FILEMODE_BLOB));

    var ptr_oid: c.git_oid = undefined;
    try check(c.git_blob_create_from_buffer(&ptr_oid, repo, pointer.ptr, pointer.len));
    try check(c.git_treebuilder_insert(null, bld, "big.bin", &ptr_oid, c.GIT_FILEMODE_BLOB));

    var tree_oid: c.git_oid = undefined;
    try check(c.git_treebuilder_write(&tree_oid, bld));
    var gtree: ?*c.git_tree = null;
    try check(c.git_tree_lookup(&gtree, repo, &tree_oid));
    defer c.git_tree_free(gtree);

    var sig: ?*c.git_signature = null;
    try check(c.git_signature_new(&sig, "Lfs", "lfs@example.com", 1_600_000_000, 0));
    defer c.git_signature_free(sig);
    var commit_oid: c.git_oid = undefined;
    try check(c.git_commit_create(&commit_oid, repo, "refs/heads/master", sig, sig, null, "lfs fixture\n", gtree, 0, null));
    try check(c.git_repository_set_head(repo, "refs/heads/master"));

    if (!cache_it) return;
    const hex = lfs.sha256Hex(payload);
    var rel_buf: [128]u8 = undefined;
    const rel = try lfs.objectRelPath(&rel_buf, &hex);
    const dir = try std.fmt.allocPrint(alloc, "{s}/.git/{s}", .{ repo_sub, std.fs.path.dirname(rel).? });
    defer alloc.free(dir);
    try tmp_dir.createDirPath(io, dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/.git/{s}", .{ repo_sub, rel });
    defer alloc.free(path);
    try tmp_dir.writeFile(io, .{ .sub_path = path, .data = payload });
}

test "import smudges lfs pointers into real content, export cleans them back" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "PAYLOAD " ** 64;

    try tmp.dir.createDirPath(io, "src");
    const src_abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(src_abs);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, src_abs.ptr, 0));
    defer c.git_repository_free(repo);
    try commitLfsFixture(io, alloc, tmp.dir, repo, "src", payload, true);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const tip = try importHead(&store, src_abs);
    try testing.expectEqual(@as(usize, 0), lfs_unresolved);

    // gr's own tree holds the real bytes, not the pointer.
    const change = try store.readChange(tip);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    var found = false;
    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, "big.bin")) continue;
        found = true;
        const content = try store.readFileContent(e.blob);
        defer alloc.free(content);
        try testing.expectEqualStrings(payload, content);
        try testing.expect(lfs.parsePointer(content) == null);
    }
    try testing.expect(found);

    // Exporting puts the pointer back in git and the bytes in the dest cache.
    try tmp.dir.createDirPath(io, "gitout");
    const out_abs = try tmp.dir.realPathFileAlloc(io, "gitout", alloc);
    defer alloc.free(out_abs);
    try exportHead(&store, out_abs);

    var out_repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&out_repo, out_abs.ptr));
    defer c.git_repository_free(out_repo);

    var head_ref: ?*c.git_reference = null;
    try check(c.git_repository_head(&head_ref, out_repo));
    defer c.git_reference_free(head_ref);
    var commit_obj: ?*c.git_object = null;
    try check(c.git_reference_peel(&commit_obj, head_ref, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(commit_obj);
    var out_tree: ?*c.git_tree = null;
    try check(c.git_commit_tree(&out_tree, @ptrCast(commit_obj)));
    defer c.git_tree_free(out_tree);

    var entry: ?*c.git_tree_entry = null;
    try check(c.git_tree_entry_bypath(&entry, out_tree, "big.bin"));
    defer c.git_tree_entry_free(entry);
    var blob: ?*c.git_blob = null;
    try check(c.git_blob_lookup(&blob, out_repo, c.git_tree_entry_id(entry)));
    defer c.git_blob_free(blob);
    const bsize: usize = @intCast(c.git_blob_rawsize(blob));
    const braw = @as([*]const u8, @ptrCast(c.git_blob_rawcontent(blob)))[0..bsize];

    const p = lfs.parsePointer(braw) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, payload.len), p.size);
    try testing.expectEqualStrings(&lfs.sha256Hex(payload), &p.oid_hex);

    var rel_buf: [128]u8 = undefined;
    const rel = try lfs.objectRelPath(&rel_buf, &p.oid_hex);
    const cached_path = try std.fmt.allocPrint(alloc, "gitout/.git/{s}", .{rel});
    defer alloc.free(cached_path);
    const cached = try tmp.dir.readFileAlloc(io, cached_path, alloc, .unlimited);
    defer alloc.free(cached);
    try testing.expectEqualStrings(payload, cached);
}

test "lfs.smudge off keeps pointers verbatim through import and export" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "OTHER PAYLOAD " ** 32;

    try tmp.dir.createDirPath(io, "src");
    const src_abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(src_abs);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, src_abs.ptr, 0));
    defer c.git_repository_free(repo);
    try commitLfsFixture(io, alloc, tmp.dir, repo, "src", payload, true);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();
    try @import("config.zig").set(&store, "lfs.smudge", "false");

    const tip = try importHead(&store, src_abs);
    const change = try store.readChange(tip);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, "big.bin")) continue;
        const content = try store.readFileContent(e.blob);
        defer alloc.free(content);
        const p = lfs.parsePointer(content) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(&lfs.sha256Hex(payload), &p.oid_hex);
    }
}

test "import leaves a pointer alone when the object cannot be resolved" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const payload = "UNCACHED " ** 16;

    try tmp.dir.createDirPath(io, "src");
    const src_abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(src_abs);
    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, src_abs.ptr, 0));
    defer c.git_repository_free(repo);
    // cache_it = false: the bytes exist nowhere, and there is no remote.
    try commitLfsFixture(io, alloc, tmp.dir, repo, "src", payload, false);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const tip = try importHead(&store, src_abs);
    try testing.expectEqual(@as(usize, 1), lfs_unresolved);

    const change = try store.readChange(tip);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);
    for (tree.entries) |e| {
        if (!std.mem.eql(u8, e.path, "big.bin")) continue;
        const content = try store.readFileContent(e.blob);
        defer alloc.free(content);
        try testing.expect(lfs.parsePointer(content) != null);
    }
}

test "syncColocatedTo refuses to drop git-side commits" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try exportHeadTo(&store, abs, "master");

    var mirrored: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&mirrored, repo, "refs/heads/master"));

    // Git moves on by itself, exactly as a `git merge origin/master` would.
    const git_side = try commitOnto(repo, "refs/heads/master", "merged.txt", "from git\n", "merge from the remote\n", &mirrored, 1_700_000_100);

    try testing.expectError(Error.NotFastForward, syncColocatedTo(&store, abs, "master"));

    var after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&after, repo, "refs/heads/master"));
    try testing.expect(c.git_oid_cmp(&after, &git_side) == 0);

    try testing.expectEqual(@as(usize, 1), at_risk.total);
    try testing.expectEqual(@as(usize, 1), at_risk.shown);
    try testing.expectEqualStrings("master", at_risk.branch());
    try testing.expectEqualStrings(&gitOidHex(&git_side), at_risk.id(0));
    try testing.expectEqualStrings("merge from the remote", at_risk.subject(0));
    try testing.expect(lastError().len != 0);
}

test "syncColocatedForced drops git-side commits only when asked" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try exportHeadTo(&store, abs, "master");
    var mirrored: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&mirrored, repo, "refs/heads/master"));
    const git_side = try commitOnto(repo, "refs/heads/master", "merged.txt", "from git\n", "merge from the remote\n", &mirrored, 1_700_000_100);

    try syncColocatedForced(&store, abs, "master", true);

    var after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&after, repo, "refs/heads/master"));
    try testing.expect(c.git_oid_cmp(&after, &git_side) != 0);
    try testing.expect(c.git_oid_cmp(&after, &mirrored) == 0);
}

fn countCommitsFrom(repo: ?*c.git_repository, ref_name: [*:0]const u8) !usize {
    var tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&tip, repo, ref_name));
    var walk: ?*c.git_revwalk = null;
    try check(c.git_revwalk_new(&walk, repo));
    defer c.git_revwalk_free(walk);
    try check(c.git_revwalk_push(walk, &tip));
    var n: usize = 0;
    var cur: c.git_oid = undefined;
    while (c.git_revwalk_next(&cur, walk) == 0) n += 1;
    return n;
}

test "forced sync replaces a rewritten chain instead of grafting it" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try exportHeadTo(&store, abs, "master");
    try testing.expectEqual(@as(usize, 1), try countCommitsFrom(repo, "refs/heads/master"));

    const blob = try store.writeFileContent("rewritten\n");
    const entries = [_]object.TreeEntry{.{ .mode = .regular, .path = "root.txt", .blob = blob }};
    var sorted = entries;
    std.mem.sort(object.TreeEntry, &sorted, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = &sorted });
    const rewritten = object.Change{
        .tree = tree_oid,
        .parents = &[_]Oid{},
        .change_id = [_]u8{9} ** 16,
        .timestamp = 1_700_000_500,
        .tz_offset_min = 0,
        .author = "Remote <remote@example.com>",
        .message = "rewritten root\n",
    };
    const rewritten_oid = try store.writeChange(rewritten);
    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, rewritten_oid);

    try syncColocatedForced(&store, abs, "master", true);
    try testing.expectEqual(@as(usize, 1), try countCommitsFrom(repo, "refs/heads/master"));

    var after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&after, repo, "refs/heads/master"));
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, repo, &after));
    defer c.git_commit_free(commit);
    try testing.expectEqual(@as(c_uint, 0), c.git_commit_parentcount(commit));
}

fn writeChangeWith(
    store: *Store,
    parents: []const Oid,
    path: []const u8,
    content: []const u8,
    msg: []const u8,
    id: u8,
    ts: i64,
) !Oid {
    const blob = try store.writeFileContent(content);
    const entries = [_]object.TreeEntry{.{ .mode = .regular, .path = path, .blob = blob }};
    var sorted = entries;
    std.mem.sort(object.TreeEntry, &sorted, {}, object.Tree.lessThan);
    const tree_oid = try store.writeTree(.{ .entries = &sorted });
    return store.writeChange(.{
        .tree = tree_oid,
        .parents = parents,
        .change_id = [_]u8{id} ** 16,
        .timestamp = ts,
        .tz_offset_min = 0,
        .author = "Remote <remote@example.com>",
        .message = msg,
    });
}

test "forced export repairs a chain that was already exported grafted" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    const branch = try store.headBranch();
    defer alloc.free(branch);

    const c1 = try store.readRef(branch);
    const c2 = try writeChangeWith(&store, &[_]Oid{c1}, "second.txt", "second\n", "second\n", 8, 1_700_000_100);
    try store.updateRef(branch, c2);

    try exportHeadTo(&store, abs, "master");
    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/master"));
    const old_tip = branchTipHex(&store, abs, "master").?;

    const r1 = try writeChangeWith(&store, &[_]Oid{}, "root.txt", "rewritten\n", "rewritten root\n", 9, 1_700_000_500);
    const r2 = try writeChangeWith(&store, &[_]Oid{r1}, "second.txt", "rewritten second\n", "rewritten second\n", 10, 1_700_000_600);
    try store.updateRef(branch, r2);

    try exportHeadTo(&store, abs, "master");
    try testing.expectEqual(@as(usize, 4), try countCommitsFrom(repo, "refs/heads/master"));

    try exportHeadToForced(&store, abs, "master", true);
    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/master"));

    var tip_oid: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&tip_oid, repo, "refs/heads/master"));
    var tip_commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&tip_commit, repo, &tip_oid));
    defer c.git_commit_free(tip_commit);
    try testing.expectEqual(@as(c_uint, 1), c.git_commit_parentcount(tip_commit));
    var root_commit: ?*c.git_commit = null;
    try check(c.git_commit_parent(&root_commit, tip_commit, 0));
    defer c.git_commit_free(root_commit);
    try testing.expectEqual(@as(c_uint, 0), c.git_commit_parentcount(root_commit));

    switch (lookupGitRef(&store, abs, "master")) {
        .mapped => |o| try testing.expect(o.eql(r2)),
        else => return error.TestUnexpectedResult,
    }
    switch (lookupGitRef(&store, abs, old_tip[0..])) {
        .mapped => |o| try testing.expect(o.eql(c2)),
        else => return error.TestUnexpectedResult,
    }

    try exportHeadTo(&store, abs, "master");
    try testing.expectEqual(@as(usize, 2), try countCommitsFrom(repo, "refs/heads/master"));
    var again: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&again, repo, "refs/heads/master"));
    try testing.expect(c.git_oid_cmp(&again, &tip_oid) == 0);
}

test "pushRemote refuses when the mirror would drop fetched remote commits" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try pushRemote(&store, url, "master");

    var pushed: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&pushed, bare_repo, "refs/heads/master"));

    // Someone else lands a commit on the remote between the two pushes.
    const theirs = try commitOnto(bare_repo, "refs/heads/master", "theirs.txt", "theirs\n", "their work\n", &pushed, 1_700_000_200);

    try pushRemote(&store, url, "master");

    var after: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&after, bare_repo, "refs/heads/master"));
    var commit: ?*c.git_commit = null;
    try check(c.git_commit_lookup(&commit, bare_repo, &after));
    defer c.git_commit_free(commit);
    try testing.expectEqual(@as(c_uint, 1), c.git_commit_parentcount(commit));
    try testing.expect(c.git_oid_cmp(c.git_commit_parent_id(commit, 0), &theirs) == 0);
}

test "fetchRemote picks a differently named remote branch" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);
    _ = try commitInitialMaster(bare_repo, "seed.txt", "seed\n");

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try testing.expectEqualStrings("main", branch);

    var fetched = try fetchRemote(&store, url, null, "sdt-remote");
    defer fetched.deinit(alloc);
    try testing.expectEqualStrings("master", fetched.branch);
    try testing.expect(store.refExists("sdt-remote"));
    try testing.expect(!store.refExists("main"));
}

test "fetchRemote names the branches the remote actually has" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "bare");
    const bare_abs = try tmp.dir.realPathFileAlloc(io, "bare", alloc);
    defer alloc.free(bare_abs);
    const bare_z = try alloc.dupeZ(u8, bare_abs);
    defer alloc.free(bare_z);
    var bare_repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&bare_repo, bare_z.ptr, 1));
    defer c.git_repository_free(bare_repo);
    _ = try commitInitialMaster(bare_repo, "seed.txt", "seed\n");

    const url = try std.fmt.allocPrint(alloc, "file://{s}", .{bare_abs});
    defer alloc.free(url);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    recordError("");
    try testing.expectError(Error.GitError, fetchRemote(&store, url, "nope", null));
    const msg = lastError();
    try testing.expect(std.mem.indexOf(u8, msg, "nope") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "master") != null);
}

test "fetchRemote surfaces the real error for an unreachable remote" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const missing = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(missing);
    const url = try std.fmt.allocPrint(alloc, "file://{s}/no-such-repo", .{missing});
    defer alloc.free(url);

    recordError("");
    try testing.expectError(Error.GitError, fetchRemote(&store, url, null, null));
    try testing.expect(lastError().len != 0);
}

test "lookupGitRef translates a git revision into an sdt change" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "gitrepo");
    const abs = try tmp.dir.realPathFileAlloc(io, "gitrepo", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try buildStoreWithChange(io, alloc, gr_dir);
    defer store.deinit();

    try exportHeadTo(&store, abs, "master");

    const branch = try store.headBranch();
    defer alloc.free(branch);
    const tip = try store.readRef(branch);

    switch (lookupGitRef(&store, abs, "master")) {
        .mapped => |o| try testing.expect(o.eql(tip)),
        else => return error.TestUnexpectedResult,
    }

    // A commit git has but sdt never imported is reported as such, not as a
    // missing ref.
    var master_tip: c.git_oid = undefined;
    try check(c.git_reference_name_to_id(&master_tip, repo, "refs/heads/master"));
    _ = try commitOnto(repo, "refs/heads/other", "extra.txt", "extra\n", "git only\n", &master_tip, 1_700_000_300);
    switch (lookupGitRef(&store, abs, "other")) {
        .unmapped => {},
        else => return error.TestUnexpectedResult,
    }

    switch (lookupGitRef(&store, abs, "no-such-ref")) {
        .missing => {},
        else => return error.TestUnexpectedResult,
    }
}

test "importRefChange resolves a tag or a raw sha and moves no sdt ref" {
    ensureInit();
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "src");
    const abs = try tmp.dir.realPathFileAlloc(io, "src", alloc);
    defer alloc.free(abs);
    const abs_z = try alloc.dupeZ(u8, abs);
    defer alloc.free(abs_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_init(&repo, abs_z.ptr, 0));
    defer c.git_repository_free(repo);

    const m1 = try commitOnto(repo, "refs/heads/master", "f.txt", "m1\n", "m1\n", null, 1_600_000_001);
    const m2 = try commitOnto(repo, "refs/heads/master", "f.txt", "m2\n", "m2\n", &m1, 1_600_000_002);
    try check(c.git_repository_set_head(repo, "refs/heads/master"));

    var tag_ref: ?*c.git_reference = null;
    try check(c.git_reference_create(&tag_ref, repo, "refs/tags/v1", &m1, 0, null));
    c.git_reference_free(tag_ref);

    try tmp.dir.createDirPath(io, "grrepo");
    var gr_dir = try tmp.dir.openDir(io, "grrepo", .{});
    defer gr_dir.close(io);
    var store = try Store.init(io, alloc, gr_dir);
    defer store.deinit();

    const branch = try store.headBranch();
    defer alloc.free(branch);

    const tagged = try importRefChange(&store, abs, "v1");
    const tc = try store.readChange(tagged);
    defer object.freeChange(alloc, tc);
    try testing.expectEqualStrings("m1\n", tc.message);
    try testing.expect(!store.refExists(branch));

    const hex = gitOidHex(&m2);
    const by_sha = try importRefChange(&store, abs, hex[0..]);
    const sc = try store.readChange(by_sha);
    defer object.freeChange(alloc, sc);
    try testing.expectEqualStrings("m2\n", sc.message);
    try testing.expectEqual(@as(usize, 1), sc.parents.len);
    try testing.expect(sc.parents[0].eql(tagged));
    try testing.expect(!store.refExists(branch));

    const to_tip = try importRefTo(&store, abs, "master", "graded");
    try testing.expect(store.refExists("graded"));
    try testing.expect(to_tip.eql(by_sha));
}
