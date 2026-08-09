const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const proc = @import("proc.zig");
const lfs = @import("lfs.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

const c = @cImport({
    @cInclude("git2.h");
});

pub const Error = error{GitError};

/// Set by the last import/push so the CLI can report LFS work without having to
/// re-open a session: pointers that stayed pointers, and objects uploaded.
pub var lfs_unresolved: usize = 0;
pub var lfs_uploaded: usize = 0;

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

fn check(rc: c_int) Error!void {
    if (rc != 0) return Error.GitError;
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
            try self.insert(ghex, goid, gr);
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
        var it = self.git_to_gr.iterator();
        while (it.next()) |kv| {
            var rb: [64]u8 = undefined;
            const rhex = kv.value_ptr.toHex(&rb);
            try buf.appendSlice(self.alloc, kv.key_ptr.*);
            try buf.append(self.alloc, ' ');
            try buf.appendSlice(self.alloc, rhex);
            try buf.append(self.alloc, '\n');
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
    ensureInit();
    const alloc = store.alloc;

    const path_z = try alloc.dupeZ(u8, git_repo_path);
    defer alloc.free(path_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_repository_open(&repo, path_z.ptr));
    defer c.git_repository_free(repo);

    var head_ref: ?*c.git_reference = null;
    try check(c.git_repository_head(&head_ref, repo));
    defer c.git_reference_free(head_ref);

    var commit_obj: ?*c.git_object = null;
    try check(c.git_reference_peel(&commit_obj, head_ref, c.GIT_OBJECT_COMMIT));
    defer c.git_object_free(commit_obj);
    var head_oid: c.git_oid = undefined;
    _ = c.git_oid_cpy(&head_oid, c.git_object_id(commit_obj));

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

    const branch = try store.headBranch();
    defer alloc.free(branch);
    try store.updateRef(branch, tip);

    return tip;
}

/// Import ALL local branches and ALL tags (each with full history) from the git
/// repo into `store`. Shared ancestry is imported once (deduped via the gitmap).
/// Creates gr `refs/heads/<name>` for each local branch and `refs/tags/<name>`
/// for each tag (peeled to its commit). Points gr HEAD at the git repo's HEAD
/// branch. Lossless in structure/content/metadata (git SHAs are not preserved;
/// gr re-hashes with its own content-addressed store).
pub fn importAll(store: *Store, git_repo_path: []const u8) !void {
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

    // Push every local branch tip.
    {
        var iter: ?*c.git_branch_iterator = null;
        try check(c.git_branch_iterator_new(&iter, repo, c.GIT_BRANCH_LOCAL));
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
    // Push every tag's target commit.
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

    lfs_unresolved = 0;
    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| {
        lfs_unresolved = s.unresolved;
        s.deinit();
    };

    // Import the whole reachable DAG oldest-first.
    var woid: c.git_oid = undefined;
    while (c.git_revwalk_next(&woid, walk) == 0) {
        _ = try importCommit(store, repo, &map, &woid, if (session) |*s| s else null);
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

/// Build a git tree object in `repo` from a superdetermine flat Tree, returning the
/// looked-up git tree (caller frees). Reuses the nested ExportNode builder.
fn buildGitTree(store: *Store, repo: ?*c.git_repository, tree: object.Tree, sess: ?*lfs.Session) !?*c.git_tree {
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
        const content = try store.readFileContent(e.blob);
        defer alloc.free(content);

        // Git LFS clean: a tracked path is committed to git as a pointer, with
        // the real bytes landing in the destination repo's LFS cache (and queued
        // for upload on push).
        var pointer: ?[]u8 = null;
        defer if (pointer) |p| alloc.free(p);
        if (sess) |s| {
            if (lfs.parsePointer(content)) |existing| {
                s.markPending(&existing.oid_hex, existing.size) catch {};
            } else if (attrs.isLfs(e.path)) {
                const hex = try s.writeObject(content);
                s.markPending(&hex, content.len) catch {};
                pointer = try lfs.pointerForContent(alloc, content);
            }
        }
        const payload: []const u8 = pointer orelse content;

        var blob_oid: c.git_oid = undefined;
        try check(c.git_blob_create_from_buffer(&blob_oid, repo, payload.ptr, payload.len));

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
fn exportChange(store: *Store, repo: ?*c.git_repository, map: *Gitmap, gr: Oid, graft: ?*const c.git_oid, sess: ?*lfs.Session) !c.git_oid {
    if (map.lookupGit(gr)) |existing| {
        var commit: ?*c.git_commit = null;
        if (c.git_commit_lookup(&commit, repo, &existing) == 0) {
            c.git_commit_free(commit);
            return existing;
        }
    }

    const alloc = store.alloc;
    const change = try store.readChange(gr);
    defer object.freeChange(alloc, change);
    const tree = try store.readTree(change.tree);
    defer object.freeTree(alloc, tree);

    const git_tree = try buildGitTree(store, repo, tree, sess);
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
    try map.insert(&ghex, commit_oid, gr);
    return commit_oid;
}

/// Export the full history reachable from `tip` into `repo`, oldest-first.
/// Returns the git commit id of the tip.
fn exportChain(store: *Store, repo: ?*c.git_repository, map: *Gitmap, tip: Oid, graft: ?*const c.git_oid, sess: ?*lfs.Session) !c.git_oid {
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
    var last: c.git_oid = undefined;
    for (out.items) |o| last = try exportChange(store, repo, map, o, graft, sess);
    return last;
}

/// Export the superdetermine store's HEAD branch (FULL history) into a git repo at
/// `dest_git_repo_path`, creating (init) the repo if absent. Into a fresh repo
/// this reproduces the whole branch history losslessly (git assigns new SHAs).
pub fn exportHead(store: *Store, dest_git_repo_path: []const u8) !void {
    try exportHeadTo(store, dest_git_repo_path, null);
}

/// Branch-aware full-history export. Materializes the entire gr HEAD-branch
/// history as commits in the dest git repo on a target git branch:
///   - if `git_branch` is non-null, that branch is used verbatim;
///   - else if the dest repo has a resolvable HEAD, its current branch shorthand
///     is used (e.g. "master") so a colocated repo updates its own branch;
///   - else it falls back to the superdetermine branch name.
/// If the target branch already exists, the gr root(s) are grafted onto its tip
/// so the update fast-forwards rather than replacing existing history.
pub fn exportHeadTo(store: *Store, dest_git_repo_path: []const u8, git_branch: ?[]const u8) !void {
    ensureInit();
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

    var target: []u8 = undefined;
    if (git_branch) |gb| {
        target = try alloc.dupe(u8, gb);
    } else blk: {
        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, repo) == 0) {
            defer c.git_reference_free(head_ref);
            const short = c.git_reference_shorthand(head_ref);
            if (short != null) {
                target = try alloc.dupe(u8, std.mem.span(short));
                break :blk;
            }
        }
        target = try alloc.dupe(u8, branch);
    }
    defer alloc.free(target);

    var ref_buf: [512]u8 = undefined;
    const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{target});

    var graft_oid: c.git_oid = undefined;
    const have_graft = c.git_reference_name_to_id(&graft_oid, repo, ref_name.ptr) == 0;

    var map = try Gitmap.load(store);
    defer map.deinit();

    var session = lfsSessionFor(store, repo, null);
    defer if (session) |*s| s.deinit();

    const tip_git = try exportChain(store, repo, &map, tip_gr, if (have_graft) &graft_oid else null, if (session) |*s| s else null);

    var newref: ?*c.git_reference = null;
    try check(c.git_reference_create(&newref, repo, ref_name.ptr, &tip_git, 1, null));
    c.git_reference_free(newref);
    try check(c.git_repository_set_head(repo, ref_name.ptr));

    try map.save(store);
}

/// Export ALL gr branches and tags (each with full history) into `dest`. Into a
/// fresh/empty git repo this reproduces the whole project graph.
pub fn exportAll(store: *Store, dest_git_repo_path: []const u8) !void {
    ensureInit();
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

            const tip_git = try exportChain(store, repo, &map, tip_gr, if (have_graft) &graft_oid else null, if (session) |*s| s else null);
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

    var target: []u8 = undefined;
    if (git_branch) |gb| {
        target = try alloc.dupe(u8, gb);
    } else blk: {
        var head_ref: ?*c.git_reference = null;
        if (c.git_repository_head(&head_ref, repo) == 0) {
            defer c.git_reference_free(head_ref);
            const short = c.git_reference_shorthand(head_ref);
            if (short != null) {
                target = try alloc.dupe(u8, std.mem.span(short));
                break :blk;
            }
        }
        target = try alloc.dupe(u8, branch);
    }
    defer alloc.free(target);

    const git_tree = try buildGitTree(store, repo, tree, sess);
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
        try check(c.git_commit_create(&commit_oid, repo, ref_name.ptr, sig, sig, null, msg_z.ptr, git_tree, 1, &parents));
    } else {
        try check(c.git_commit_create(&commit_oid, repo, ref_name.ptr, sig, sig, null, msg_z.ptr, git_tree, 0, null));
    }

    try check(c.git_repository_set_head(repo, ref_name.ptr));
}

/// Clone a git repo (local path or file:// URL) into `into_dir`, then import its
/// HEAD into `store` so the superdetermine ref is populated.
pub fn cloneGit(store: *Store, url_or_path: []const u8, into_dir: []const u8) !void {
    try cloneGitOnly(store.alloc, url_or_path, into_dir);
    try importAll(store, into_dir);
}

pub fn cloneGitOnly(alloc: std.mem.Allocator, url_or_path: []const u8, into_dir: []const u8) !void {
    ensureInit();

    const url_z = try alloc.dupeZ(u8, url_or_path);
    defer alloc.free(url_z);
    const into_z = try alloc.dupeZ(u8, into_dir);
    defer alloc.free(into_z);

    var repo: ?*c.git_repository = null;
    try check(c.git_clone(&repo, url_z.ptr, into_z.ptr, null));
    c.git_repository_free(repo);
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

    try check(c.git_remote_push(remote, &strarr, &opts));
}

/// Push a COLOCATED git repo's branch directly to a remote. Used when a `.git`
/// already exists next to `.gr`: dual-write commits live in that repo, so we
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
    try check(c.git_remote_push(remote, &strarr, &opts));
}

/// Pull from an actual git remote (https/ssh/file://) into superdetermine. Fetches
/// heads into the managed `.sdt/gitmirror` repo, points its HEAD at the current
/// branch, then imports that HEAD so the superdetermine ref updates.
pub fn pullRemote(store: *Store, remote_url: []const u8) !void {
    ensureInit();
    const alloc = store.alloc;

    const mirror_abs = try mirrorRepoPath(store);
    defer alloc.free(mirror_abs);

    const branch = try store.headBranch();
    defer alloc.free(branch);

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

    var ref_buf: [512]u8 = undefined;
    const ref_name = try std.fmt.bufPrintZ(&ref_buf, "refs/heads/{s}", .{branch});
    try check(c.git_repository_set_head(repo, ref_name.ptr));

    _ = try importHead(store, mirror_abs);
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

/// Mirror superdetermine HEAD into a colocated git repo at `work_dir_path`, so `git log`
/// there reflects superdetermine's current change ("sdt and git coexist live").
pub fn syncColocated(store: *Store, work_dir_path: []const u8) !void {
    try exportHead(store, work_dir_path);
    // gr wrote the commit straight to the branch ref, which leaves git's index
    // stale relative to the new HEAD (so `git status`/`git diff` show garbage).
    // Reset the index (MIXED: HEAD + index, working tree untouched) so git stays
    // consistent and `git status` shows exactly what changed since the sdt save.
    resetIndexToHead(store, work_dir_path) catch {};
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

    try importAll(&store, abs);

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
