const std = @import("std");
const oid = @import("oid.zig");
const Oid = oid.Oid;

/// Passive reader of coding-agent session logs.
///
/// Agents (Claude Code, Codex, Pi, Gemini CLI, Cline/Roo, …) already write their
/// tool activity to plain-text logs on disk. We read those logs — never asking
/// the agent to cooperate — and surface the file edits they made as `EditEvent`s.
/// Attribution then matches a saved file against these events: an exact content
/// hash match is CERTAIN, a path+timing match is BEST-EFFORT, and a file with no
/// matching event at all is attributed to the HUMAN.
///
/// Sources are pluggable: each adapter knows how to find its artifacts and parse
/// them into the shared `EditEvent` shape. Adding a source is one array entry.
pub const EditEvent = struct {
    agent: []const u8, // "claude-code" | "pi" | "codex" | "gemini-cli" | "cline" | "roo" | "aider"
    session: []const u8, // session id (may be empty)
    prompt: []const u8, // truncated originating prompt (may be empty)
    path: []const u8, // ABSOLUTE file path edited (repo dir itself for repo-wide identity events)
    new_hash: ?Oid, // BLAKE3 of post-edit content when recoverable, else null
    timestamp_ms: i64,
    agent_id: []const u8 = "",
    prompt_id: []const u8 = "",
};

const prompt_cap = 500;
/// mtime slack: a session file appended slightly before `since` may still hold
/// events we care about, so widen the window a little when gating by mtime.
const mtime_slack_ms: i64 = 5 * 60 * 1000;

// --- adapter table ---

const Adapter = struct {
    name: []const u8,
    run: *const fn (ctx: *Ctx) anyerror!void,
};

const adapters = [_]Adapter{
    .{ .name = "claude-code", .run = scanClaude },
    .{ .name = "pi", .run = scanPi },
    .{ .name = "codex", .run = scanCodex },
    .{ .name = "gemini-cli", .run = scanGemini },
    .{ .name = "cline", .run = scanCline },
    .{ .name = "aider", .run = scanAider },
    // SQLite-backed sources are NOT implemented (no dependency-free sqlite reader
    // is available and adding a C sqlite library is out of scope). To wire one up
    // later, add an adapter entry here that opens the DB and pushes EditEvents:
    //   Cursor   ~/.cursor/ai-tracking/ai-code-tracking.db
    //   opencode ~/.local/share/opencode/opencode.db (or platform equivalent)
    //   Copilot  VS Code globalStorage .../session-store.db
    // Everything above is JSONL/JSON/git-trailer only — no native deps.
};

// --- public API ---

/// Scan every adapter for edit events touching files under `repo_abs_path`,
/// newer than `since_ms`. Best-effort: a failing adapter is skipped, never fatal.
/// Caller frees with `freeEvents`.
pub fn scan(alloc: std.mem.Allocator, io: std.Io, repo_abs_path: []const u8, since_ms: i64) ![]EditEvent {
    var events: std.ArrayList(EditEvent) = .empty;
    errdefer freeList(alloc, &events);

    // Normalise: drop any trailing slash so path-containment checks are exact.
    const repo_abs = std.mem.trimEnd(u8, repo_abs_path, "/");

    var ctx = Ctx{
        .alloc = alloc,
        .io = io,
        .repo_abs = repo_abs,
        .since_ms = since_ms,
        .events = &events,
    };

    for (adapters) |a| {
        a.run(&ctx) catch continue;
    }

    return events.toOwnedSlice(alloc);
}

pub fn freeEvents(alloc: std.mem.Allocator, events: []EditEvent) void {
    for (events) |e| freeEvent(alloc, e);
    alloc.free(events);
}

fn freeEvent(alloc: std.mem.Allocator, e: EditEvent) void {
    alloc.free(e.agent);
    alloc.free(e.session);
    alloc.free(e.prompt);
    alloc.free(e.path);
    alloc.free(e.agent_id);
    alloc.free(e.prompt_id);
}

fn freeList(alloc: std.mem.Allocator, events: *std.ArrayList(EditEvent)) void {
    for (events.items) |e| freeEvent(alloc, e);
    events.deinit(alloc);
}

// --- scan context + push ---

const Ctx = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    repo_abs: []const u8,
    since_ms: i64,
    events: *std.ArrayList(EditEvent),

    /// Could these bytes possibly name a file in this repo? An adapter that
    /// only ever reports absolute paths, or resolves relative ones against a
    /// `cwd` the file itself records, writes this repo's path down before it
    /// can report an edit inside it. Matching the directory's bare name instead
    /// was tried and is worthless: a repo called `big` or `web` appears in
    /// every session on the machine. The one case this gives up is an agent
    /// started *above* the repo that only ever wrote relative paths, which
    /// falls back to attributing the edit to the human.
    fn mentionsRepo(self: *const Ctx, data: []const u8) bool {
        return std.mem.indexOf(u8, data, self.repo_abs) != null;
    }

    /// Append an event iff its path is the repo dir or a file under it and it is
    /// recent enough. Dupes every string so parsed JSON can be freed immediately.
    fn push(self: *Ctx, agent: []const u8, session: []const u8, prompt: []const u8, abs_path: []const u8, new_hash: ?Oid, ts_ms: i64) !void {
        return self.pushDetail(agent, session, prompt, abs_path, new_hash, ts_ms, .{});
    }

    fn pushDetail(self: *Ctx, agent: []const u8, session: []const u8, prompt: []const u8, abs_path: []const u8, new_hash: ?Oid, ts_ms: i64, detail: Detail) !void {
        if (ts_ms < self.since_ms - mtime_slack_ms) return;
        if (!pathInRepo(self.repo_abs, abs_path)) return;

        const a = try self.alloc.dupe(u8, agent);
        errdefer self.alloc.free(a);
        const s = try self.alloc.dupe(u8, session);
        errdefer self.alloc.free(s);
        const p = try self.alloc.dupe(u8, trimTrunc(prompt));
        errdefer self.alloc.free(p);
        const path = try self.alloc.dupe(u8, abs_path);
        errdefer self.alloc.free(path);
        const aid = try self.alloc.dupe(u8, detail.agent_id);
        errdefer self.alloc.free(aid);
        const pid = try self.alloc.dupe(u8, detail.prompt_id);
        errdefer self.alloc.free(pid);

        try self.events.append(self.alloc, .{
            .agent = a,
            .session = s,
            .prompt = p,
            .path = path,
            .new_hash = new_hash,
            .timestamp_ms = ts_ms,
            .agent_id = aid,
            .prompt_id = pid,
        });
    }
};

const Detail = struct {
    agent_id: []const u8 = "",
    prompt_id: []const u8 = "",
};

/// True if `path` equals `repo` (a repo-wide identity event) or is a file under it.
fn pathInRepo(repo: []const u8, path: []const u8) bool {
    if (std.mem.eql(u8, repo, path)) return true;
    if (path.len <= repo.len) return false;
    if (!std.mem.startsWith(u8, path, repo)) return false;
    return path[repo.len] == '/';
}

fn trimTrunc(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    return if (t.len > prompt_cap) t[0..prompt_cap] else t;
}

// --- shared filesystem helpers ---

/// Open a directory given by a path relative to $HOME. Null if HOME is unset or
/// the directory does not exist.
fn openHome(io: std.Io, alloc: std.mem.Allocator, sub: []const u8) ?std.Io.Dir {
    const home = std.c.getenv("HOME") orelse return null;
    const hs = std.mem.span(home);
    if (hs.len == 0) return null;
    const path = std.fs.path.join(alloc, &.{ hs, sub }) catch return null;
    defer alloc.free(path);
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch null;
}

fn mtimeMs(dir: std.Io.Dir, io: std.Io, path: []const u8) ?i64 {
    const st = dir.statFile(io, path, .{}) catch return null;
    return @intCast(@divTrunc(st.mtime.nanoseconds, 1_000_000));
}

/// Whether a session file has to name this repo before it is worth parsing.
///
/// An adapter whose every event carries an absolute path — or resolves a
/// relative one against a `cwd` the session file itself records — cannot
/// produce an event for this repo out of bytes that never mention it. For those,
/// one `indexOf` over the file replaces a full JSON parse of every line in it,
/// and a machine with months of sessions for other projects stops paying for
/// them on every save. Adapters that resolve paths against the repo directory
/// itself (the permissive harvester) have no such guarantee and scan as before.
const Mention = enum { required, not_required };

/// Walk `base` recursively, invoking `cb` with the bytes of every regular file
/// whose name ends in one of `exts` and whose mtime is recent enough. Each file's
/// bytes are freed after `cb` returns. Per-file errors are swallowed.
fn walkFiles(
    ctx: *Ctx,
    base: std.Io.Dir,
    exts: []const []const u8,
    mention: Mention,
    cb: *const fn (ctx: *Ctx, path: []const u8, data: []const u8, mtime_ms: i64) void,
) void {
    const io = ctx.io;
    const alloc = ctx.alloc;
    var walker = base.walkSelectively(alloc) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        switch (entry.kind) {
            .directory => walker.enter(io, entry) catch {},
            .file => {
                var matched = false;
                for (exts) |ext| {
                    if (std.mem.endsWith(u8, entry.path, ext)) matched = true;
                }
                if (!matched) continue;
                const mt = mtimeMs(base, io, entry.path) orelse continue;
                if (mt < ctx.since_ms - mtime_slack_ms) continue;
                const data = base.readFileAlloc(io, entry.path, alloc, .unlimited) catch continue;
                defer alloc.free(data);
                if (mention == .required and !ctx.mentionsRepo(data)) continue;
                cb(ctx, entry.path, data, mt);
            },
            else => {},
        }
    }
}

// --- JSON value helpers ---

const Value = std.json.Value;

fn objGet(v: Value, key: []const u8) ?Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn asStr(v: ?Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a user prompt from a Claude/Pi `message.content`, which is either a
/// bare string or an array of `{type:"text", text:"…"}` blocks. Returns the first
/// text found (a borrow into `v`). Empty if none.
fn contentText(v: Value) []const u8 {
    switch (v) {
        .string => |s| return s,
        .array => |arr| {
            for (arr.items) |item| {
                if (asStr(objGet(item, "type"))) |t| {
                    if (!std.mem.eql(u8, t, "text")) continue;
                }
                if (asStr(objGet(item, "text"))) |txt| return txt;
            }
        },
        else => {},
    }
    return "";
}

fn parseLineObj(alloc: std.mem.Allocator, line: []const u8) ?std.json.Parsed(Value) {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return null;
    return std.json.parseFromSlice(Value, alloc, trimmed, .{}) catch null;
}

// --- ISO-8601 → epoch milliseconds ---

fn parseUint(s: []const u8) ?i64 {
    if (s.len == 0) return null;
    var acc: i64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        acc = acc * 10 + (c - '0');
    }
    return acc;
}

/// Days from 1970-01-01 for a proleptic-Gregorian y/m/d (Hinnant's algorithm).
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = y_in - @intFromBool(m <= 2);
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = if (m > 2) m - 3 else m + 9;
    const doy = @divTrunc(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divTrunc(yoe, 4) - @divTrunc(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

/// Parse "YYYY-MM-DDTHH:MM:SS[.mmm][Z]" into epoch ms. Null on malformed input.
fn isoToMs(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    if (s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':') return null;
    const year = parseUint(s[0..4]) orelse return null;
    const month = parseUint(s[5..7]) orelse return null;
    const day = parseUint(s[8..10]) orelse return null;
    const hour = parseUint(s[11..13]) orelse return null;
    const min = parseUint(s[14..16]) orelse return null;
    const sec = parseUint(s[17..19]) orelse return null;
    var ms: i64 = 0;
    if (s.len > 19 and s[19] == '.') {
        var i: usize = 20;
        var frac: i64 = 0;
        var digits: usize = 0;
        while (i < s.len and digits < 3 and s[i] >= '0' and s[i] <= '9') : (i += 1) {
            frac = frac * 10 + (s[i] - '0');
            digits += 1;
        }
        while (digits < 3) : (digits += 1) frac *= 10;
        ms = frac;
    }
    const days = daysFromCivil(year, month, day);
    return ((days * 86400 + hour * 3600 + min * 60 + sec) * 1000) + ms;
}

// --- adapter: Claude Code (verified against real logs) ---
//
// ~/.claude/projects/<slug>/<session-uuid>.jsonl, live-appended JSONL.
//   type:"assistant" → message.content[] {type:"tool_use", name:"Write"|"Edit"
//     |"MultiEdit", input:{file_path, content|old_string|new_string}}
//   type:"user"      → message.content is the originating prompt.
// Each line carries top-level cwd, sessionId, timestamp (ISO ms).

fn scanClaude(ctx: *Ctx) anyerror!void {
    var base = openHome(ctx.io, ctx.alloc, ".claude/projects") orelse return;
    defer base.close(ctx.io);
    walkFiles(ctx, base, &.{".jsonl"}, .required, claudeFile);
}

const ClaudePending = struct {
    id: []const u8,
    session: []const u8,
    prompt: []const u8,
    prompt_id: []const u8,
    agent_id: []const u8,
    path: []const u8,
    hash: ?Oid,
    ts: i64,
};

fn dupeClaudePending(alloc: std.mem.Allocator, p: ClaudePending) !ClaudePending {
    var out = p;
    out.id = try alloc.dupe(u8, p.id);
    errdefer alloc.free(out.id);
    out.session = try alloc.dupe(u8, p.session);
    errdefer alloc.free(out.session);
    out.prompt = try alloc.dupe(u8, p.prompt);
    errdefer alloc.free(out.prompt);
    out.prompt_id = try alloc.dupe(u8, p.prompt_id);
    errdefer alloc.free(out.prompt_id);
    out.agent_id = try alloc.dupe(u8, p.agent_id);
    errdefer alloc.free(out.agent_id);
    out.path = try alloc.dupe(u8, p.path);
    return out;
}

fn freeClaudePending(alloc: std.mem.Allocator, p: ClaudePending) void {
    alloc.free(p.id);
    alloc.free(p.session);
    alloc.free(p.prompt);
    alloc.free(p.prompt_id);
    alloc.free(p.agent_id);
    alloc.free(p.path);
}

fn pushClaudePending(ctx: *Ctx, p: ClaudePending, hash: ?Oid) void {
    ctx.pushDetail("claude-code", p.session, p.prompt, p.path, hash, p.ts, .{
        .agent_id = p.agent_id,
        .prompt_id = p.prompt_id,
    }) catch {};
}

fn isClaudeHumanPrompt(root: Value) bool {
    const source = asStr(objGet(root, "promptSource")) orelse return false;
    if (!std.mem.eql(u8, source, "typed")) return false;
    const origin = objGet(root, "origin") orelse return false;
    const kind = asStr(objGet(origin, "kind")) orelse return false;
    return std.mem.eql(u8, kind, "human");
}

fn boolOr(v: ?Value, default: bool) bool {
    const val = v orelse return default;
    return switch (val) {
        .bool => |b| b,
        else => default,
    };
}

fn rebuildEdit(alloc: std.mem.Allocator, original: []const u8, old: []const u8, new: []const u8, all: bool) ?[]u8 {
    if (old.len == 0) return null;
    if (std.mem.indexOf(u8, original, old) == null) return null;
    return rebuildEditAlloc(alloc, original, old, new, all) catch null;
}

fn rebuildEditAlloc(alloc: std.mem.Allocator, original: []const u8, old: []const u8, new: []const u8, all: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var rest = original;
    while (std.mem.indexOf(u8, rest, old)) |i| {
        try out.appendSlice(alloc, rest[0..i]);
        try out.appendSlice(alloc, new);
        rest = rest[i + old.len ..];
        if (!all) break;
    }
    try out.appendSlice(alloc, rest);
    return out.toOwnedSlice(alloc);
}

fn claudeResultHash(alloc: std.mem.Allocator, res: Value) ?Oid {
    if (boolOr(objGet(res, "userModified"), false)) return null;
    if (asStr(objGet(res, "content"))) |c| return Oid.ofBytes(c);
    const original = asStr(objGet(res, "originalFile")) orelse return null;
    const old = asStr(objGet(res, "oldString")) orelse return null;
    const new = asStr(objGet(res, "newString")) orelse return null;
    const rebuilt = rebuildEdit(alloc, original, old, new, boolOr(objGet(res, "replaceAll"), false)) orelse return null;
    defer alloc.free(rebuilt);
    return Oid.ofBytes(rebuilt);
}

fn claudeToolResultId(msg: Value) ?[]const u8 {
    const content = objGet(msg, "content") orelse return null;
    const arr = switch (content) {
        .array => |a| a,
        else => return null,
    };
    for (arr.items) |blk| {
        if (asStr(objGet(blk, "type"))) |t| {
            if (!std.mem.eql(u8, t, "tool_result")) continue;
        }
        if (asStr(objGet(blk, "tool_use_id"))) |id| return id;
    }
    return null;
}

fn claudeFile(ctx: *Ctx, _: []const u8, data: []const u8, _: i64) void {
    const alloc = ctx.alloc;
    var last_prompt: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(last_prompt);
    var last_prompt_id: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(last_prompt_id);

    var pending: std.ArrayList(ClaudePending) = .empty;
    defer {
        for (pending.items) |p| {
            pushClaudePending(ctx, p, p.hash);
            freeClaudePending(alloc, p);
        }
        pending.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const parsed = parseLineObj(alloc, line) orelse continue;
        defer parsed.deinit();
        const root = parsed.value;

        const rtype = asStr(objGet(root, "type")) orelse continue;
        const msg = objGet(root, "message") orelse continue;

        if (std.mem.eql(u8, rtype, "user")) {
            if (isClaudeHumanPrompt(root)) {
                const text = contentText(objGet(msg, "content") orelse Value{ .null = {} });
                if (text.len != 0) {
                    const dup = alloc.dupe(u8, text) catch continue;
                    alloc.free(last_prompt);
                    last_prompt = dup;
                    replaceDup(alloc, &last_prompt_id, asStr(objGet(root, "promptId")) orelse "");
                }
                continue;
            }
            const res = objGet(root, "toolUseResult") orelse continue;
            const id = claudeToolResultId(msg) orelse continue;
            for (pending.items, 0..) |p, i| {
                if (!std.mem.eql(u8, p.id, id)) continue;
                pushClaudePending(ctx, p, claudeResultHash(alloc, res) orelse p.hash);
                freeClaudePending(alloc, p);
                _ = pending.orderedRemove(i);
                break;
            }
            continue;
        }
        if (!std.mem.eql(u8, rtype, "assistant")) continue;

        const session = asStr(objGet(root, "sessionId")) orelse "";
        const agent_id = asStr(objGet(root, "agentId")) orelse "";
        const ts = if (asStr(objGet(root, "timestamp"))) |t| (isoToMs(t) orelse 0) else 0;

        const content = objGet(msg, "content") orelse continue;
        const arr = switch (content) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |blk| {
            const btype = asStr(objGet(blk, "type")) orelse continue;
            if (!std.mem.eql(u8, btype, "tool_use")) continue;
            const name = asStr(objGet(blk, "name")) orelse continue;
            const input = objGet(blk, "input") orelse continue;
            const fpath = asStr(objGet(input, "file_path")) orelse continue;

            var hash: ?Oid = null;
            if (std.mem.eql(u8, name, "Write")) {
                if (asStr(objGet(input, "content"))) |c| hash = Oid.ofBytes(c);
            }
            // Edit / MultiEdit inputs carry only fragments, but the matching
            // tool result does carry the full post-edit content → defer the push.
            const borrowed = ClaudePending{
                .id = asStr(objGet(blk, "id")) orelse "",
                .session = session,
                .prompt = last_prompt,
                .prompt_id = last_prompt_id,
                .agent_id = agent_id,
                .path = fpath,
                .hash = hash,
                .ts = ts,
            };
            if (borrowed.id.len == 0) {
                pushClaudePending(ctx, borrowed, hash);
                continue;
            }
            const owned = dupeClaudePending(alloc, borrowed) catch continue;
            pending.append(alloc, owned) catch freeClaudePending(alloc, owned);
        }
    }
}

// --- adapter: Pi (verified against real logs) ---
//
// ~/.pi/agent/sessions/<encoded-cwd>/<ts>_<uuid>.jsonl, JSONL.
//   first line type:"session" carries cwd + id.
//   message.role:"assistant" content[] {type:"toolCall", name:"write"|"edit",
//     arguments:{path, content | edits:[{oldText,newText}]}}. Paths may be
//     relative to the session cwd.
//   message.role:"user" content[] → prompt.

fn scanPi(ctx: *Ctx) anyerror!void {
    var base = openHome(ctx.io, ctx.alloc, ".pi/agent/sessions") orelse return;
    defer base.close(ctx.io);
    walkFiles(ctx, base, &.{".jsonl"}, .required, piFile);
}

fn piFile(ctx: *Ctx, _: []const u8, data: []const u8, mtime_ms: i64) void {
    const alloc = ctx.alloc;
    var session_id: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(session_id);
    var cwd: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(cwd);
    var last_prompt: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(last_prompt);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const parsed = parseLineObj(alloc, line) orelse continue;
        defer parsed.deinit();
        const root = parsed.value;
        const rtype = asStr(objGet(root, "type")) orelse continue;

        if (std.mem.eql(u8, rtype, "session")) {
            if (asStr(objGet(root, "id"))) |id| replaceDup(alloc, &session_id, id);
            if (asStr(objGet(root, "cwd"))) |c| replaceDup(alloc, &cwd, c);
            continue;
        }
        if (!std.mem.eql(u8, rtype, "message")) continue;
        const msg = objGet(root, "message") orelse continue;
        const role = asStr(objGet(msg, "role")) orelse continue;
        const ts = if (asStr(objGet(root, "timestamp"))) |t| (isoToMs(t) orelse mtime_ms) else mtime_ms;

        if (std.mem.eql(u8, role, "user")) {
            const text = contentText(objGet(msg, "content") orelse Value{ .null = {} });
            if (text.len != 0) replaceDup(alloc, &last_prompt, text);
            continue;
        }
        if (!std.mem.eql(u8, role, "assistant")) continue;

        const content = objGet(msg, "content") orelse continue;
        const arr = switch (content) {
            .array => |a| a,
            else => continue,
        };
        for (arr.items) |blk| {
            const btype = asStr(objGet(blk, "type")) orelse continue;
            if (!std.mem.eql(u8, btype, "toolCall")) continue;
            const name = asStr(objGet(blk, "name")) orelse continue;
            const args = objGet(blk, "arguments") orelse continue;
            const rel = asStr(objGet(args, "path")) orelse continue;

            const abs = resolvePath(alloc, cwd, rel) orelse continue;
            defer alloc.free(abs);

            var hash: ?Oid = null;
            if (std.mem.eql(u8, name, "write")) {
                if (asStr(objGet(args, "content"))) |c| hash = Oid.ofBytes(c);
            }
            ctx.push("pi", session_id, last_prompt, abs, hash, ts) catch {};
        }
    }
}

// --- adapter: Codex (verified against real logs) ---
//
// ~/.codex/sessions/YYYY/MM/DD/rollout-*-<uuid>.jsonl, JSONL.
//   session_meta line → payload.cwd, payload.id.
//   response_item payload {type:"function_call"|"custom_tool_call", name, input
//     |arguments}. apply_patch → input is a `*** Update/Add File: <path>` envelope
//     (paths absolute). exec_command → arguments.cmd shell string (best-effort
//     path parse: apply_patch envelope, `> file`, `tee file`, `sed -i … file`).
// Content is not reconstructable from a patch/diff → new_hash null (BEST-EFFORT).

fn scanCodex(ctx: *Ctx) anyerror!void {
    var base = openHome(ctx.io, ctx.alloc, ".codex/sessions") orelse return;
    defer base.close(ctx.io);
    walkFiles(ctx, base, &.{".jsonl"}, .required, codexFile);
}

fn codexFile(ctx: *Ctx, _: []const u8, data: []const u8, mtime_ms: i64) void {
    const alloc = ctx.alloc;
    var cwd: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(cwd);
    var session_id: []u8 = alloc.dupe(u8, "") catch return;
    defer alloc.free(session_id);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const parsed = parseLineObj(alloc, line) orelse continue;
        defer parsed.deinit();
        const root = parsed.value;
        const rtype = asStr(objGet(root, "type")) orelse continue;
        const payload = objGet(root, "payload") orelse continue;
        const ts = if (asStr(objGet(root, "timestamp"))) |t| (isoToMs(t) orelse mtime_ms) else mtime_ms;

        if (std.mem.eql(u8, rtype, "session_meta")) {
            if (asStr(objGet(payload, "cwd"))) |c| replaceDup(alloc, &cwd, c);
            if (asStr(objGet(payload, "id"))) |id| replaceDup(alloc, &session_id, id);
            continue;
        }

        const ptype = asStr(objGet(payload, "type")) orelse continue;
        if (!std.mem.eql(u8, ptype, "function_call") and !std.mem.eql(u8, ptype, "custom_tool_call")) continue;
        const name = asStr(objGet(payload, "name")) orelse continue;

        if (std.mem.eql(u8, name, "apply_patch")) {
            const input = asStr(objGet(payload, "input")) orelse "";
            codexApplyPatch(ctx, cwd, session_id, input, ts);
        } else if (std.mem.eql(u8, name, "exec_command") or std.mem.eql(u8, name, "shell")) {
            // arguments is a JSON-encoded string like {"cmd":"…"}; parse and read cmd.
            const argstr = asStr(objGet(payload, "arguments")) orelse continue;
            const args = std.json.parseFromSlice(Value, alloc, argstr, .{}) catch continue;
            defer args.deinit();
            const cmd = asStr(objGet(args.value, "cmd")) orelse continue;
            if (std.mem.indexOf(u8, cmd, "*** ") != null) {
                codexApplyPatch(ctx, cwd, session_id, cmd, ts);
            } else if (codexShellTarget(cmd)) |rel| {
                const abs = resolvePath(alloc, cwd, rel) orelse continue;
                defer alloc.free(abs);
                ctx.push("codex", session_id, "", abs, null, ts) catch {};
            }
        }
    }
}

fn codexApplyPatch(ctx: *Ctx, cwd: []const u8, session: []const u8, envelope: []const u8, ts: i64) void {
    const alloc = ctx.alloc;
    const markers = [_][]const u8{ "*** Update File: ", "*** Add File: " };
    var lines = std.mem.splitScalar(u8, envelope, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        for (markers) |m| {
            if (std.mem.startsWith(u8, line, m)) {
                const rel = std.mem.trim(u8, line[m.len..], " \t\r");
                if (rel.len == 0) continue;
                const abs = resolvePath(alloc, cwd, rel) orelse continue;
                defer alloc.free(abs);
                ctx.push("codex", session, "", abs, null, ts) catch {};
            }
        }
    }
}

/// Best-effort: pull a written-file target out of a shell command string.
fn codexShellTarget(cmd: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, cmd, "tee ")) |i| {
        return firstToken(cmd[i + 4 ..]);
    }
    if (std.mem.indexOf(u8, cmd, "sed -i")) |_| {
        return lastToken(cmd);
    }
    // A `>` or `>>` redirection (skip `2>`): take the token that follows.
    var i: usize = 0;
    while (i < cmd.len) : (i += 1) {
        if (cmd[i] == '>') {
            if (i > 0 and (cmd[i - 1] == '2' or cmd[i - 1] == '&')) continue;
            var j = i + 1;
            if (j < cmd.len and cmd[j] == '>') j += 1;
            while (j < cmd.len and (cmd[j] == ' ' or cmd[j] == '\t')) j += 1;
            return firstToken(cmd[j..]);
        }
    }
    return null;
}

fn firstToken(s: []const u8) ?[]const u8 {
    const t = std.mem.trimStart(u8, s, " \t");
    if (t.len == 0) return null;
    const end = std.mem.indexOfAny(u8, t, " \t\n\r;|&'\"") orelse t.len;
    if (end == 0) return null;
    return t[0..end];
}

fn lastToken(s: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, s, " \t\n\r");
    var last: ?[]const u8 = null;
    while (it.next()) |tok| last = tok;
    return last;
}

// --- adapter: Gemini CLI (implemented from documented schema — NOT verified) ---
//
// ~/.gemini/tmp/<projectHash>/chats/session-*.jsonl. Tool calls write_file /
// replace carry args.file_path + content. Schema not present on this machine, so
// parsing is permissive/best-effort via the generic tool-call harvester.

fn scanGemini(ctx: *Ctx) anyerror!void {
    var base = openHome(ctx.io, ctx.alloc, ".gemini/tmp") orelse return;
    defer base.close(ctx.io);
    walkFiles(ctx, base, &.{".jsonl"}, .not_required, geminiFile);
}

fn geminiFile(ctx: *Ctx, _: []const u8, data: []const u8, mtime_ms: i64) void {
    const alloc = ctx.alloc;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const parsed = parseLineObj(alloc, line) orelse continue;
        defer parsed.deinit();
        const ts = if (asStr(objGet(parsed.value, "timestamp"))) |t| (isoToMs(t) orelse mtime_ms) else mtime_ms;
        harvest(ctx, "gemini-cli", "", parsed.value, ts, 0);
    }
}

// --- adapter: Cline / Roo (implemented from documented schema — NOT verified) ---
//
// VS Code globalStorage task files for saoudrizwan.claude-dev (Cline) and
// RooVeterinaryInc.roo-cline (Roo). Tool events newFileCreated / editedExistingFile
// carry a path + full new content and an epoch-ms `ts`. JSON (whole-file), so the
// generic harvester walks the tree. Not present on this machine → best-effort.

fn scanCline(ctx: *Ctx) anyerror!void {
    clineExtension(ctx, "saoudrizwan.claude-dev", "cline");
    clineExtension(ctx, "RooVeterinaryInc.roo-cline", "roo");
}

fn clineExtension(ctx: *Ctx, ext_id: []const u8, agent: []const u8) void {
    const alloc = ctx.alloc;
    // VS Code stores globalStorage under a platform-specific application dir.
    const roots = [_][]const u8{
        "Library/Application Support/Code/User/globalStorage",
        ".config/Code/User/globalStorage",
        ".vscode-server/data/User/globalStorage",
    };
    for (roots) |root| {
        const sub = std.fs.path.join(alloc, &.{ root, ext_id }) catch continue;
        defer alloc.free(sub);
        var base = openHome(ctx.io, ctx.alloc, sub) orelse continue;
        defer base.close(ctx.io);
        // Bind the agent name for this pass via a small closure-substitute.
        var pass = ClinePass{ .ctx = ctx, .agent = agent };
        walkFilesClosure(&pass, base, &.{".json"});
    }
}

const ClinePass = struct { ctx: *Ctx, agent: []const u8 };

fn walkFilesClosure(pass: *ClinePass, base: std.Io.Dir, exts: []const []const u8) void {
    const ctx = pass.ctx;
    const io = ctx.io;
    const alloc = ctx.alloc;
    var walker = base.walkSelectively(alloc) catch return;
    defer walker.deinit();
    while (walker.next(io) catch return) |entry| {
        switch (entry.kind) {
            .directory => walker.enter(io, entry) catch {},
            .file => {
                var matched = false;
                for (exts) |ext| {
                    if (std.mem.endsWith(u8, entry.path, ext)) matched = true;
                }
                if (!matched) continue;
                const mt = mtimeMs(base, io, entry.path) orelse continue;
                if (mt < ctx.since_ms - mtime_slack_ms) continue;
                const data = base.readFileAlloc(io, entry.path, alloc, .unlimited) catch continue;
                defer alloc.free(data);
                const parsed = std.json.parseFromSlice(Value, alloc, data, .{}) catch continue;
                defer parsed.deinit();
                harvest(ctx, pass.agent, "", parsed.value, mt, 0);
            },
            else => {},
        }
    }
}

// --- adapter: Aider (identity-only, keyed off git history — best-effort) ---
//
// Aider signs its commits with `Co-authored-by: aider (<model>) <aider@aider.chat>`.
// There is no per-file post-edit content, so aider cannot content-match a file.
// When a recent commit message in the colocated .git carries the trailer, we emit
// ONE repo-wide identity event (path == repo dir). Attribution uses it only as a
// last resort for files no other adapter claimed → agent=aider, confidence likely.

fn scanAider(ctx: *Ctx) anyerror!void {
    // Read the last commit message written by the colocated git, if any.
    const io = ctx.io;
    const alloc = ctx.alloc;
    const candidates = [_][]const u8{ ".git/COMMIT_EDITMSG", ".git/MERGE_MSG" };
    for (candidates) |rel| {
        const path = std.fs.path.join(alloc, &.{ ctx.repo_abs, rel }) catch continue;
        defer alloc.free(path);
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .unlimited) catch continue;
        defer alloc.free(data);
        if (std.mem.indexOf(u8, data, "aider@aider.chat") != null) {
            const mt = mtimeMs(std.Io.Dir.cwd(), io, path) orelse ctx.since_ms;
            // Repo-wide identity event: path is the repo directory itself.
            ctx.push("aider", "", "", ctx.repo_abs, null, mt) catch {};
            return;
        }
    }
}

// --- generic permissive tool-call harvester (Gemini / Cline / future JSON) ---

const write_tool_names = [_][]const u8{
    "write_file",  "write_to_file",      "replace",        "edit",
    "create_file", "editedExistingFile", "newFileCreated", "str_replace",
    "apply_diff",  "insert_content",
};
const path_keys = [_][]const u8{ "file_path", "path", "filePath", "filename" };
const content_keys = [_][]const u8{ "content", "new_string", "newText", "new_content", "fileContent" };

fn isWriteTool(name: []const u8) bool {
    for (write_tool_names) |w| {
        if (std.mem.eql(u8, name, w)) return true;
    }
    return false;
}

/// Recursively search a JSON value for write-tool calls, pushing an event for
/// each. `depth` guards against pathological nesting. Best-effort: paths may be
/// absolute or relative to the repo (we resolve relatives against repo_abs).
fn harvest(ctx: *Ctx, agent: []const u8, session: []const u8, v: Value, ts: i64, depth: usize) void {
    if (depth > 24) return;
    switch (v) {
        .object => |o| {
            harvestObject(ctx, agent, session, o, ts);
            var it = o.iterator();
            while (it.next()) |e| harvest(ctx, agent, session, e.value_ptr.*, ts, depth + 1);
        },
        .array => |arr| {
            for (arr.items) |item| harvest(ctx, agent, session, item, ts, depth + 1);
        },
        else => {},
    }
}

fn harvestObject(ctx: *Ctx, agent: []const u8, session: []const u8, o: std.json.ObjectMap, ts: i64) void {
    const obj = Value{ .object = o };
    // A tool call may name itself via name/tool/type, or just present path+content.
    var is_tool = false;
    if (asStr(objGet(obj, "name"))) |n| {
        if (isWriteTool(n)) is_tool = true;
    }
    if (asStr(objGet(obj, "tool"))) |n| {
        if (isWriteTool(n)) is_tool = true;
    }
    if (asStr(objGet(obj, "type"))) |n| {
        if (isWriteTool(n)) is_tool = true;
    }

    // Require a recognized write-tool name: a bare path+content object (e.g. the
    // nested args of a call we already matched) must not double-count.
    if (!is_tool) return;

    // Args may be nested under a wrapper object.
    const arg_candidates = [_]?Value{ obj, objGet(obj, "args"), objGet(obj, "arguments"), objGet(obj, "input"), objGet(obj, "tool_input"), objGet(obj, "params") };
    for (arg_candidates) |maybe| {
        const args = maybe orelse continue;
        const rel = firstStr(args, &path_keys) orelse continue;
        const abs = resolvePath(ctx.alloc, ctx.repo_abs, rel) orelse continue;
        defer ctx.alloc.free(abs);
        var hash: ?Oid = null;
        if (firstStr(args, &content_keys)) |c| hash = Oid.ofBytes(c);
        const lts = if (asStr(objGet(args, "ts"))) |t| (parseUint(t) orelse ts) else ts;
        ctx.push(agent, session, "", abs, hash, lts) catch {};
        return;
    }
}

fn firstStr(v: Value, keys: []const []const u8) ?[]const u8 {
    for (keys) |k| {
        if (asStr(objGet(v, k))) |s| return s;
    }
    return null;
}

// --- misc ---

fn replaceDup(alloc: std.mem.Allocator, dst: *[]u8, src: []const u8) void {
    const dup = alloc.dupe(u8, src) catch return;
    alloc.free(dst.*);
    dst.* = dup;
}

/// Resolve `rel` against `base`: absolute paths pass through, relatives join.
/// Caller frees.
fn resolvePath(alloc: std.mem.Allocator, base: []const u8, rel: []const u8) ?[]u8 {
    if (rel.len == 0) return null;
    if (std.fs.path.isAbsolute(rel)) return alloc.dupe(u8, rel) catch null;
    if (base.len == 0) return null;
    return std.fs.path.join(alloc, &.{ base, rel }) catch null;
}

// --- tests ---

const testing = std.testing;

test "isoToMs parses UTC timestamps" {
    // 2026-06-19T16:02:38.699Z
    const ms = isoToMs("2026-06-19T16:02:38.699Z").?;
    // 1970→2026 sanity: positive, and fractional ms preserved.
    try testing.expect(ms > 1_700_000_000_000);
    try testing.expectEqual(@as(i64, 699), @mod(ms, 1000));
    // Epoch itself.
    try testing.expectEqual(@as(i64, 0), isoToMs("1970-01-01T00:00:00.000Z").?);
    try testing.expectEqual(@as(i64, 1000), isoToMs("1970-01-01T00:00:01Z").?);
}

test "pathInRepo containment" {
    try testing.expect(pathInRepo("/a/b", "/a/b/c.txt"));
    try testing.expect(pathInRepo("/a/b", "/a/b")); // repo-wide identity event
    try testing.expect(!pathInRepo("/a/b", "/a/bc.txt"));
    try testing.expect(!pathInRepo("/a/b", "/a"));
    try testing.expect(!pathInRepo("/a/b", "/x/y"));
}

test "codex shell target parsing" {
    try testing.expectEqualStrings("out.txt", codexShellTarget("echo hi > out.txt").?);
    try testing.expectEqualStrings("log", codexShellTarget("echo hi >> log").?);
    try testing.expectEqualStrings("f.txt", codexShellTarget("printf x | tee f.txt").?);
    try testing.expect(codexShellTarget("ls -la") == null);
}

// A test-only Ctx over an in-memory events list, so adapter parsers can be
// exercised without touching any real ~/.claude etc. files.
fn testCtx(alloc: std.mem.Allocator, repo_abs: []const u8, events: *std.ArrayList(EditEvent)) Ctx {
    return .{
        .alloc = alloc,
        .io = std.testing.io,
        .repo_abs = repo_abs,
        .since_ms = 0,
        .events = events,
    };
}

test "claude-code JSONL parses into an EditEvent with content hash" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"user","promptSource":"typed","origin":{"kind":"human"},"promptId":"P1","message":{"role":"user","content":"make a.txt"},"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"S1","cwd":"/repo"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/a.txt","content":"hello"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S1","cwd":"/repo"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    const e = events.items[0];
    try testing.expectEqualStrings("claude-code", e.agent);
    try testing.expectEqualStrings("S1", e.session);
    try testing.expectEqualStrings("make a.txt", e.prompt);
    try testing.expectEqualStrings("P1", e.prompt_id);
    try testing.expectEqualStrings("/repo/a.txt", e.path);
    try testing.expect(e.new_hash != null);
    try testing.expect(e.new_hash.?.eql(Oid.ofBytes("hello")));
}

test "claude-code only genuine human turns become the prompt" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    // A real prompt, then three impostors that also arrive as type:"user":
    // a bare tool result, a task-notification injection, and a queued peer turn.
    const fixture =
        \\{"type":"user","promptSource":"typed","origin":{"kind":"human"},"promptId":"P7","message":{"role":"user","content":"add the flag"},"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"S1"}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_x","content":"ok"}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S1"}
        \\{"type":"user","promptSource":"system","origin":{"kind":"task-notification"},"message":{"role":"user","content":"agent finished"},"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"S1"}
        \\{"type":"user","promptSource":"queued","origin":{"kind":"peer"},"message":{"role":"user","content":"peer says hi"},"timestamp":"2026-01-01T00:00:03.000Z","sessionId":"S1"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/a.txt","content":"hello"}}]},"timestamp":"2026-01-01T00:00:04.000Z","sessionId":"S1"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("add the flag", events.items[0].prompt);
    try testing.expectEqualStrings("P7", events.items[0].prompt_id);
}

test "claude-code Edit recovers full post-edit content from toolUseResult" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"user","promptSource":"typed","origin":{"kind":"human"},"promptId":"P2","message":{"role":"user","content":"rename it"},"timestamp":"2026-01-01T00:00:00.000Z","sessionId":"S2"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_1","name":"Edit","input":{"file_path":"/repo/a.zig","old_string":"old","new_string":"new"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S2"}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"done"}]},"toolUseResult":{"filePath":"/repo/a.zig","oldString":"old","newString":"new","originalFile":"a old b","replaceAll":false,"userModified":false,"structuredPatch":[]},"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"S2"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    const e = events.items[0];
    try testing.expectEqualStrings("/repo/a.zig", e.path);
    try testing.expectEqualStrings("rename it", e.prompt);
    try testing.expect(e.new_hash != null);
    try testing.expect(e.new_hash.?.eql(Oid.ofBytes("a new b")));
}

test "claude-code userModified suppresses the content hash" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_2","name":"Edit","input":{"file_path":"/repo/a.zig","old_string":"old","new_string":"new"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S3"}
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_2","content":"done"}]},"toolUseResult":{"filePath":"/repo/a.zig","oldString":"old","newString":"new","originalFile":"a old b","replaceAll":false,"userModified":true,"structuredPatch":[]},"timestamp":"2026-01-01T00:00:02.000Z","sessionId":"S3"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expect(events.items[0].new_hash == null);
}

test "claude-code unanswered tool_use is still emitted once" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu_3","name":"Write","input":{"file_path":"/repo/a.txt","content":"hello"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S4"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expect(events.items[0].new_hash.?.eql(Oid.ofBytes("hello")));
}

test "claude-code subagent transcript carries the agent id" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"assistant","agentId":"aacedf99bce2ac913","isSidechain":true,"message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/sub.txt","content":"sub"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S5"}
    ;
    claudeFile(&ctx, "f.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("S5", events.items[0].session);
    try testing.expectEqualStrings("aacedf99bce2ac913", events.items[0].agent_id);
}

test "rebuildEdit replaces first occurrence or all" {
    const alloc = testing.allocator;
    const once = rebuildEdit(alloc, "a x b x c", "x", "y", false).?;
    defer alloc.free(once);
    try testing.expectEqualStrings("a y b x c", once);

    const all = rebuildEdit(alloc, "a x b x c", "x", "y", true).?;
    defer alloc.free(all);
    try testing.expectEqualStrings("a y b y c", all);

    try testing.expect(rebuildEdit(alloc, "abc", "zzz", "y", false) == null);
    try testing.expect(rebuildEdit(alloc, "abc", "", "y", false) == null);
}

test "walkFiles descends into nested subagents directories" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var nested = try tmp.dir.createDirPathOpen(io, "-Users-x-repo/sess-1/subagents", .{});
    defer nested.close(io);
    try nested.writeFile(io, .{
        .sub_path = "agent-abc123.jsonl",
        .data =
        \\{"type":"assistant","agentId":"abc123","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/repo/deep.txt","content":"deep"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S6"}
        ,
    });

    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);
    walkFiles(&ctx, tmp.dir, &.{".jsonl"}, .required, claudeFile);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    try testing.expectEqualStrings("/repo/deep.txt", events.items[0].path);
    try testing.expectEqualStrings("abc123", events.items[0].agent_id);
}

test "walkFiles skips a session that never names this repo" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "elsewhere.jsonl",
        .data =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/other/deep.txt","content":"deep"}}]},"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"S7"}
        ,
    });

    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);
    walkFiles(&ctx, tmp.dir, &.{".jsonl"}, .required, claudeFile);
    try testing.expectEqual(@as(usize, 0), events.items.len);
}

test "codex apply_patch exec_command parses the edited path" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    // session_meta sets cwd; a custom_tool_call apply_patch names an updated file;
    // an exec_command redirect writes a relative path resolved against cwd.
    const fixture =
        \\{"type":"session_meta","payload":{"id":"C1","cwd":"/repo"},"timestamp":"2026-01-01T00:00:00.000Z"}
        \\{"type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /repo/src/x.zig\n@@\n-old\n+new\n*** End Patch"},"timestamp":"2026-01-01T00:00:01.000Z"}
        \\{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"echo hi > notes.md\"}"},"timestamp":"2026-01-01T00:00:02.000Z"}
    ;
    codexFile(&ctx, "rollout.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 2), events.items.len);
    try testing.expectEqualStrings("/repo/src/x.zig", events.items[0].path);
    try testing.expectEqualStrings("codex", events.items[0].agent);
    try testing.expect(events.items[0].new_hash == null); // patch → content unrecoverable
    try testing.expectEqualStrings("/repo/notes.md", events.items[1].path);
}

test "gemini write_file tool call harvested with content hash" {
    const alloc = testing.allocator;
    var events: std.ArrayList(EditEvent) = .empty;
    defer freeList(alloc, &events);
    var ctx = testCtx(alloc, "/repo", &events);

    const fixture =
        \\{"type":"assistant","timestamp":"2026-01-01T00:00:00.000Z","content":[{"functionCall":{"name":"write_file","args":{"file_path":"/repo/gen.txt","content":"world"}}}]}
    ;
    geminiFile(&ctx, "session-1.jsonl", fixture, 0);

    try testing.expectEqual(@as(usize, 1), events.items.len);
    const e = events.items[0];
    try testing.expectEqualStrings("gemini-cli", e.agent);
    try testing.expectEqualStrings("/repo/gen.txt", e.path);
    try testing.expect(e.new_hash.?.eql(Oid.ofBytes("world")));
}
