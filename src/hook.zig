const std = @import("std");
const moment = @import("moment.zig");
const sched = @import("sched.zig");
const config = @import("config.zig");
const grade = @import("grade.zig");
const checks = @import("checks.zig");
const verdict = @import("verdict.zig");
const warrant = @import("warrant.zig");
const update = @import("update.zig");
const store = @import("store.zig");
const Store = store.Store;

pub const max_context = 10_000;
pub const max_payload = 4 * 1024 * 1024;
pub const timeout_seconds = 600;

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

fn arrayLen(v: ?Value) usize {
    const val = v orelse return 0;
    return switch (val) {
        .array => |a| a.items.len,
        else => 0,
    };
}

pub const Event = enum { stop, unknown };

pub fn eventOf(v: Value) Event {
    const name = asStr(objGet(v, "hook_event_name")) orelse return .unknown;
    if (std.mem.eql(u8, name, "Stop")) return .stop;
    return .unknown;
}

pub fn stopShouldGrade(v: Value) bool {
    if (eventOf(v) != .stop) return false;
    if (arrayLen(objGet(v, "background_tasks")) != 0) return false;
    return true;
}

pub fn truncated(s: []const u8) []const u8 {
    if (s.len <= max_context) return s;
    var end: usize = max_context;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

pub fn emit(w: *std.Io.Writer, event_name: []const u8, context: []const u8) !void {
    const body = truncated(context);
    if (body.len == 0) return;
    try std.json.Stringify.value(.{
        .hookSpecificOutput = .{
            .hookEventName = event_name,
            .additionalContext = body,
        },
    }, .{}, w);
    try w.writeAll("\n");
    try w.flush();
}

pub fn verdictContext(
    alloc: std.mem.Allocator,
    id_hex: []const u8,
    command: []const u8,
    v: verdict.Verdict,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const w = &out.writer;

    if (v.result == .red) {
        try w.print(
            "sdt: the state you just left graded red. `{s}` exited {d}.\n",
            .{ command, v.exit_code },
        );
    } else if (v.isHollow()) {
        try w.print(
            "sdt: the state you just left graded green under `{s}`, but the green is hollow.\n",
            .{command},
        );
        if (v.independence == .co_authored) {
            try w.writeAll(
                "the same actor wrote both the code and the check across this span, so the pass proves only that it agrees with itself.\n",
            );
        }
        if (v.discrimination == .vacuous) {
            try w.writeAll(
                "the check also passed on the previous state, so it did not test this change.\n",
            );
        }
    } else {
        try w.print(
            "sdt: the state you just left graded green under `{s}`.\n",
            .{command},
        );
    }

    try warrant.render(w, id_hex, v);

    if (v.result == .red) {
        try w.writeAll("`sdt green` rewinds to the last state that passed.\n");
    }
    return out.toOwnedSlice();
}

pub fn stopContext(
    alloc: std.mem.Allocator,
    s: *Store,
    work: std.Io.Dir,
    ctx: grade.Context,
    mset: moment.Settings,
) !?[]u8 {
    _ = try sched.tick(s, work, ctx, mset, sched.settings(s, alloc));
    if (!ctx.set.enabled) return null;

    const all = try moment.readAll(s, alloc);
    defer moment.freeMoments(alloc, all);
    if (all.len == 0) return null;
    const head = all[all.len - 1];

    var ix = try verdict.Index.load(s, alloc);
    defer ix.deinit();

    const v = ix.best(
        head.full_tree,
        verdict.commandHash(ctx.set.command(.fast)),
        verdict.commandHash(ctx.set.command(.full)),
    ) orelse return null;

    var id_buf: [16]u8 = undefined;
    return try verdictContext(alloc, head.shortId(&id_buf), ctx.set.command(v.tier), v);
}

fn openWork(io: std.Io) !std.Io.Dir {
    var dir = try std.Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    var depth: usize = 0;
    while (depth < 64) : (depth += 1) {
        if (dir.access(io, store.dir_name, .{})) |_| return dir else |_| {}
        const parent = dir.openDir(io, "..", .{ .iterate = true }) catch break;
        dir.close(io);
        dir = parent;
    }
    return dir;
}

fn runStop(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer) void {
    var work = openWork(io) catch return;
    defer work.close(io);

    var s = Store.discover(io, alloc, std.Io.Dir.cwd()) catch return;
    defer s.deinit();

    const set = checks.settings(&s, alloc);
    defer set.deinit(alloc);
    const rules = warrant.pathRules(&s, alloc);
    defer rules.deinit(alloc);

    var mset = moment.settings(&s, alloc);
    mset.enabled = true;

    const ctx = grade.Context{
        .store = &s,
        .work_dir = work,
        .alloc = alloc,
        .set = set,
        .rules = rules,
    };

    const context = (stopContext(alloc, &s, work, ctx, mset) catch return) orelse return;
    defer alloc.free(context);
    emit(w, "Stop", context) catch {};
}

pub fn handle(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, data: []const u8) void {
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '{') return;
    const parsed = std.json.parseFromSlice(Value, alloc, trimmed, .{}) catch return;
    defer parsed.deinit();

    switch (eventOf(parsed.value)) {
        .stop => {
            if (!stopShouldGrade(parsed.value)) return;
            runStop(io, alloc, w);
        },
        .unknown => {},
    }
}

pub fn settingsJson(alloc: std.mem.Allocator, exe_abs: []const u8) ![]u8 {
    const command = try std.fmt.allocPrint(alloc, "{s} hook", .{exe_abs});
    defer alloc.free(command);
    return std.json.Stringify.valueAlloc(alloc, .{
        .hooks = .{
            .Stop = .{
                .{
                    .hooks = .{
                        .{
                            .type = "command",
                            .command = command,
                            .timeout = @as(u32, timeout_seconds),
                            .async = true,
                        },
                    },
                },
            },
        },
    }, .{ .whitespace = .indent_2 });
}

fn install(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) void {
    const exe = update.selfExePathAlloc(alloc) catch (alloc.dupe(u8, "sdt") catch return);
    defer alloc.free(exe);

    const body = settingsJson(alloc, exe) catch return;
    defer alloc.free(body);

    var path: []const u8 = "";
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--write")) {
            i += 1;
            if (i < rest.len) path = rest[i];
        }
    }

    if (path.len != 0) {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = body }) catch {};
        w.print("wrote the Stop hook block to {s}\n", .{path}) catch {};
        w.flush() catch {};
        return;
    }

    w.writeAll(body) catch {};
    w.writeAll("\n") catch {};
    w.flush() catch {};
}

fn readPayload(io: std.Io, alloc: std.mem.Allocator) ?[]u8 {
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().readerStreaming(io, &buf);
    return reader.interface.allocRemaining(alloc, .limited(max_payload)) catch null;
}

pub fn run(io: std.Io, alloc: std.mem.Allocator, w: *std.Io.Writer, rest: []const []const u8) void {
    if (rest.len != 0 and std.mem.eql(u8, rest[0], "install")) {
        install(io, alloc, w, rest[1..]);
        return;
    }
    const data = readPayload(io, alloc) orelse return;
    defer alloc.free(data);
    handle(io, alloc, w, data);
}

// --- tests ---

const testing = std.testing;

fn parseFixture(alloc: std.mem.Allocator, text: []const u8) !std.json.Parsed(Value) {
    return std.json.parseFromSlice(Value, alloc, text, .{});
}

test "a stop with no background work asks for grading" {
    const alloc = testing.allocator;
    const p = try parseFixture(alloc,
        \\{"session_id":"s","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/repo",
        \\ "permission_mode":"default","hook_event_name":"Stop","prompt_id":"p",
        \\ "stop_hook_active":false,"last_assistant_message":"done",
        \\ "background_tasks":[],"session_crons":[]}
    );
    defer p.deinit();
    try testing.expectEqual(Event.stop, eventOf(p.value));
    try testing.expect(stopShouldGrade(p.value));
}

test "a stop with background work still running does not grade" {
    const alloc = testing.allocator;
    const p = try parseFixture(alloc,
        \\{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false,
        \\ "last_assistant_message":"still building",
        \\ "background_tasks":[{"id":"b1","type":"bash","status":"running",
        \\ "description":"zig build","command":"zig build"}]}
    );
    defer p.deinit();
    try testing.expect(!stopShouldGrade(p.value));
}

test "a payload without the background field is a finished turn" {
    const alloc = testing.allocator;
    const p = try parseFixture(alloc,
        \\{"session_id":"s","hook_event_name":"Stop","stop_hook_active":false}
    );
    defer p.deinit();
    try testing.expect(stopShouldGrade(p.value));
}

test "other hook events are ignored" {
    const alloc = testing.allocator;
    const p = try parseFixture(alloc,
        \\{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}
    );
    defer p.deinit();
    try testing.expectEqual(Event.unknown, eventOf(p.value));
    try testing.expect(!stopShouldGrade(p.value));
}

test "malformed input writes nothing and does not fail" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    handle(io, alloc, &out.writer, "not json at all");
    handle(io, alloc, &out.writer, "{\"hook_event_name\":");
    handle(io, alloc, &out.writer, "");
    handle(io, alloc, &out.writer, "[1,2,3]");
    handle(io, alloc, &out.writer, "{\"hook_event_name\":42}");

    try testing.expectEqualStrings("", out.written());
}

test "an oversized context is truncated to the cap" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_context * 3);
    defer alloc.free(big);
    @memset(big, 'a');

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try emit(&out.writer, "Stop", big);

    const p = try std.json.parseFromSlice(Value, alloc, out.written(), .{});
    defer p.deinit();
    const hso = objGet(p.value, "hookSpecificOutput").?;
    try testing.expectEqual(@as(usize, max_context), asStr(objGet(hso, "additionalContext")).?.len);
}

test "truncation never splits a multi-byte character" {
    const alloc = testing.allocator;
    const big = try alloc.alloc(u8, max_context + 8);
    defer alloc.free(big);
    @memset(big, 'a');
    // "é" is two bytes, straddling the cap by one.
    big[max_context - 1] = 0xc3;
    big[max_context] = 0xa9;

    const cut = truncated(big);
    try testing.expectEqual(@as(usize, max_context - 1), cut.len);
    try testing.expect(std.unicode.utf8ValidateSlice(cut));
}

test "the emitted json is well formed and is the only output" {
    const alloc = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try emit(&out.writer, "Stop", "graded green\nwith \"quotes\" and a \\ backslash");

    const text = out.written();
    try testing.expect(std.mem.startsWith(u8, text, "{\"hookSpecificOutput\""));
    try testing.expectEqualStrings("}\n", text[text.len - 2 ..]);
    try testing.expect(std.mem.indexOfScalar(u8, text[0 .. text.len - 1], '\n') == null);

    const p = try std.json.parseFromSlice(Value, alloc, text, .{});
    defer p.deinit();
    const hso = objGet(p.value, "hookSpecificOutput").?;
    try testing.expectEqualStrings("Stop", asStr(objGet(hso, "hookEventName")).?);
    try testing.expectEqualStrings(
        "graded green\nwith \"quotes\" and a \\ backslash",
        asStr(objGet(hso, "additionalContext")).?,
    );
}

test "an empty context emits nothing at all" {
    const alloc = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try emit(&out.writer, "Stop", "");
    try testing.expectEqualStrings("", out.written());
}

fn sampleVerdict(result: verdict.Result) verdict.Verdict {
    return .{
        .tree = @import("oid.zig").Oid.ofBytes("tree"),
        .tier = .full,
        .command = verdict.commandHash("zig build test"),
        .result = result,
        .exit_code = if (result == .green) 0 else 1,
        .duration_ms = 900,
        .ms = 1_700_000_000_000,
        .readset = @import("oid.zig").Oid.zero(),
    };
}

test "a plain green says so and carries its warrant line" {
    const alloc = testing.allocator;
    var v = sampleVerdict(.green);
    v.independence = .independent;
    v.discrimination = .discriminating;
    v.relevance_hit = 3;
    v.relevance_total = 4;

    const msg = try verdictContext(alloc, "abcdef0123456789", "zig build test", v);
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "graded green") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "hollow") == null);
    try testing.expect(std.mem.indexOf(u8, msg, "@abcdef0123456789") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "relevance 3/4") != null);
}

test "a hollow green names why the green is worth little" {
    const alloc = testing.allocator;
    var v = sampleVerdict(.green);
    v.independence = .co_authored;
    v.discrimination = .vacuous;

    const msg = try verdictContext(alloc, "abcdef0123456789", "zig build test", v);
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "hollow") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "agrees with itself") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "did not test this change") != null);
}

test "a red says so and points at the rewind" {
    const alloc = testing.allocator;
    const msg = try verdictContext(alloc, "abcdef0123456789", "zig build test", sampleVerdict(.red));
    defer alloc.free(msg);
    try testing.expect(std.mem.indexOf(u8, msg, "graded red") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "exited 1") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "sdt green") != null);
}

test "the stop path captures, grades and reports a real verdict" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);
    var s = try Store.init(io, alloc, work);
    defer s.deinit();
    const scratch = try tmp.dir.realPathFileAlloc(io, ".", alloc);
    defer alloc.free(scratch);

    const set = checks.Settings{ .enabled = true, .full = "grep -q good a.txt" };
    const ctx = grade.Context{
        .store = &s,
        .work_dir = work,
        .alloc = alloc,
        .set = set,
        .rules = .{},
        .scratch_parent = scratch,
    };
    const mset = moment.Settings{ .enabled = true, .keyframe_interval = 4 };
    try config.set(&s, "checks.battery_floor", "0");

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "good one" });
    const green = (try stopContext(alloc, &s, work, ctx, mset)).?;
    defer alloc.free(green);
    try testing.expect(std.mem.indexOf(u8, green, "graded green") != null);

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "broken" });
    const red = (try stopContext(alloc, &s, work, ctx, mset)).?;
    defer alloc.free(red);
    try testing.expect(std.mem.indexOf(u8, red, "graded red") != null);
}

test "a repo with no check configured reports nothing" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "repo");
    var work = try tmp.dir.openDir(io, "repo", .{ .iterate = true });
    defer work.close(io);
    var s = try Store.init(io, alloc, work);
    defer s.deinit();

    try work.writeFile(io, .{ .sub_path = "a.txt", .data = "one" });
    const ctx = grade.Context{
        .store = &s,
        .work_dir = work,
        .alloc = alloc,
        .set = .{},
        .rules = .{},
    };
    try testing.expect((try stopContext(alloc, &s, work, ctx, .{ .enabled = true })) == null);
}

test "the installer generates an async command hook and touches no file" {
    const alloc = testing.allocator;
    const body = try settingsJson(alloc, "/usr/local/bin/sdt");
    defer alloc.free(body);

    const p = try std.json.parseFromSlice(Value, alloc, body, .{});
    defer p.deinit();
    const stop = objGet(objGet(p.value, "hooks").?, "Stop").?;
    const entry = stop.array.items[0];
    const inner = objGet(entry, "hooks").?.array.items[0];

    try testing.expectEqualStrings("command", asStr(objGet(inner, "type")).?);
    try testing.expectEqualStrings("/usr/local/bin/sdt hook", asStr(objGet(inner, "command")).?);
    try testing.expectEqual(@as(i64, timeout_seconds), objGet(inner, "timeout").?.integer);
    try testing.expectEqual(true, objGet(inner, "async").?.bool);
}
