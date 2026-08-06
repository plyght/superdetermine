const std = @import("std");
const oid = @import("oid.zig");
const workspace = @import("workspace.zig");
const moment = @import("moment.zig");
const sched = @import("sched.zig");
const grade = @import("grade.zig");
const ui = @import("ui.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const Options = struct {
    interval_ms: u32 = 800,
    author: []const u8 = "you <you@localhost>",
    on_change: ?*const fn () void = null,
};

fn skipDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".gr") or std.mem.eql(u8, name, ".git");
}

/// Cheap state signature of the working tree: a BLAKE3 over (path, size,
/// content hash) of every file, skipping `.gr` and `.git`. Content is folded
/// in so a change is detected regardless of mtime resolution. A file that
/// vanishes mid-walk is skipped rather than fatal.
pub fn signature(store: *Store, work_dir: std.Io.Dir) !Oid {
    const io = store.io;
    const alloc = store.alloc;

    var hasher = oid.Hasher.init();

    var walker = try work_dir.walkSelectively(alloc);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .directory => {
                if (!skipDir(std.fs.path.basenamePosix(entry.path))) {
                    walker.enter(io, entry) catch continue;
                }
            },
            .file => {
                const st = work_dir.statFile(io, entry.path, .{}) catch continue;
                const data = work_dir.readFileAlloc(io, entry.path, alloc, .unlimited) catch continue;
                defer alloc.free(data);
                var content: Oid = undefined;
                oid.Blake3.hash(data, &content.bytes, .{});

                var sz: [8]u8 = undefined;
                std.mem.writeInt(u64, &sz, st.size, .big);

                hasher.update(entry.path);
                hasher.update(&sz);
                hasher.update(&content.bytes);
            },
            .sym_link => {
                var buf: [4096]u8 = undefined;
                const n = work_dir.readLink(io, entry.path, &buf) catch continue;
                hasher.update(entry.path);
                hasher.update(buf[0..n]);
            },
            else => {},
        }
    }

    return hasher.finalOid();
}

fn nowSeconds(store: *Store) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, store.io).nanoseconds, 1_000_000_000));
}

/// The foreground path for continuous capture and grading.
///
/// This does exactly what the launchd agent does, in a terminal you can watch,
/// for machines where an OS scheduler is unavailable or unwanted. It is the same
/// `sched.tick` either way, so there is one implementation of the policy and no
/// second code path to drift.
///
/// Unlike `watch`, this creates moments rather than changes: nothing here ever
/// writes to `sdt log`, because a captured state is not a commit.
pub fn live(
    store: *Store,
    work_dir: std.Io.Dir,
    ctx: grade.Context,
    mset: moment.Settings,
    sset: sched.Settings,
) !void {
    const io = store.io;

    var buf: [512]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var last = signature(store, work_dir) catch oid.Oid.zero();

    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(mset.interval_ms), .awake) catch {};

        // The content signature is the cheap gate: unchanged tree, no work, and
        // therefore no CPU at all while the developer is thinking.
        const sig = signature(store, work_dir) catch continue;
        if (sig.eql(last)) continue;
        last = sig;

        if (!sched.due(store, sset)) continue;

        const r = sched.tick(store, work_dir, ctx, mset, sset) catch continue;
        if (r.skipped != null) continue;

        if (r.captured) {
            out.print("{s}captured{s}", .{ ui.on(.dim), ui.off() }) catch {};
            if (r.graded != 0) {
                out.print(", ran {d} check{s}", .{ r.graded, if (r.graded == 1) "" else "s" }) catch {};
            }
            out.writeAll("\n") catch {};
        }
        if (r.boundary) |b| {
            out.print("{s}broke between moment {d} and {d}{s}  ", .{
                ui.on(.yellow), b.last_green, b.first_red, ui.off(),
            }) catch {};
            out.print("{s}`sdt green` rewinds to the last state that worked{s}\n", .{
                ui.on(.dim), ui.off(),
            }) catch {};
        }
        out.flush() catch {};
    }
}

/// Poll the working tree forever, auto-saving a snapshot whenever it changes.
/// Runs until the process is killed (Ctrl-C).
pub fn watch(store: *Store, work_dir: std.Io.Dir, opts: Options) !void {
    const io = store.io;
    const alloc = store.alloc;

    var buf: [256]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &buf);
    const out = &w.interface;

    var last = try signature(store, work_dir);

    while (true) {
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(opts.interval_ms), .awake) catch {};

        const sig = signature(store, work_dir) catch continue;
        if (sig.eql(last)) continue;
        last = sig;

        const st = workspace.status(store, work_dir, alloc) catch continue;
        const changed = st.len > 0;
        for (st) |e| alloc.free(e.path);
        alloc.free(st);
        if (!changed) continue;

        const change_oid = workspace.snapshot(store, work_dir, opts.author, "live: auto-save", nowSeconds(store)) catch continue;

        var hex: [Oid.len * 2]u8 = undefined;
        _ = change_oid.toHex(&hex);
        out.print("\u{25cf} auto-saved {s}\n", .{hex[0..12]}) catch {};
        out.flush() catch {};

        if (opts.on_change) |cb| cb();
    }
}

// --- tests ---

const testing = std.testing;

test "signature changes on content change, stable otherwise" {
    const io = std.testing.io;
    const alloc = testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "hello" });

    var work = try tmp.dir.openDir(io, "work", .{ .iterate = true });
    defer work.close(io);

    const s1 = try signature(&store, work);
    const s1b = try signature(&store, work);
    try testing.expect(s1.eql(s1b));

    try tmp.dir.writeFile(io, .{ .sub_path = "work/a.txt", .data = "hello world!!" });
    const s2 = try signature(&store, work);
    try testing.expect(!s1.eql(s2));
}
