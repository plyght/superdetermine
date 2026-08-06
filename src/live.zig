const std = @import("std");
const oid = @import("oid.zig");
const object = @import("object.zig");
const applog = @import("applog.zig");
const config = @import("config.zig");
const moment = @import("moment.zig");
const verdict = @import("verdict.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

/// Live session handoff: two machines watching one working state in real time.
///
/// The shape is deliberately small. One side is the author and holds the write
/// authority; the other side is a follower and is read-only. The follower never
/// writes into the shared state, and when it wants to change something it forks
/// the moment it is looking at and works there. Forking a moment is free (a
/// moment is a content-addressed tree with a stable id, so a fork is a new id
/// over the same objects), which is what makes "read-only" a non-restriction
/// rather than a limitation the user has to route around.
///
/// This is NOT co-editing. Two cursors are never live in one buffer, and there
/// is exactly one writer at any instant, enforced here rather than agreed by
/// convention. It is deliberately not a CRDT: a CRDT is a different system with
/// different failure modes, and it forces a synchronisation service to exist for
/// convergence to mean anything. guardrail has no such service and does not want
/// one, so authority is transferred explicitly with a `handoff` message instead
/// of being dissolved into a merge function.
///
/// What lives in this file is the protocol and the state machine: message
/// framing over the wormhole byte transport, the one-writer rule, note
/// persistence, and the opt-in setting. The transport itself is `wormhole.zig`
/// (SPAKE2 + an authenticated record stream); nothing here re-implements it.
/// Everything below is exercisable without a second machine, which is the point:
/// the wire format is the part that must not be wrong, so it is the part that is
/// unit-tested rather than the part that needs a live peer to observe.
pub const notes_log_path = "notes";

/// Which end of a live session this process is.
pub const Role = enum {
    /// Holds the write authority for the shared state.
    author,
    /// Read-only. Forks instead of writing.
    follower,

    /// The stable lowercase name, for config, logs and CLI output.
    pub fn label(self: Role) []const u8 {
        return @tagName(self);
    }
};

/// One end of a live session, as this process sees it.
///
/// `writer_is_me` is the authority bit and `role` is its human-facing name; the
/// two only ever move together (see `applyHandoff`), so a session can never be
/// an author that cannot write or a follower that can.
pub const Session = struct {
    role: Role,
    /// The other end's identity, borrowed from the caller. Not owned here.
    peer: []const u8,
    /// Unix milliseconds the session began.
    started_ms: i64,
    writer_is_me: bool,
};

/// Errors this layer can raise on its own behalf.
pub const Error = error{
    /// A frame ended before its declared contents did.
    Truncated,
    /// The first byte named a message kind this version does not know.
    UnknownKind,
    /// A frame was well-framed but its contents were not valid.
    BadFrame,
    /// A non-writer tried to transfer authority it does not hold.
    NotTheWriter,
    /// A writer tried to accept authority it already holds.
    AlreadyTheWriter,
    /// `path:line` did not parse.
    BadNoteTarget,
};

// --- message protocol ---

/// The wire kinds. The byte values are printable on purpose: a mis-framed
/// stream is diagnosable by eye, and the tag is never zero so an all-zero read
/// is always an error rather than a valid empty message.
pub const MessageKind = enum(u8) {
    moment = 'M',
    verdict = 'V',
    note = 'N',
    handoff = 'H',
    bye = 'B',

    /// The kind for a tag byte, or null if this version does not know it.
    pub fn fromByte(b: u8) ?MessageKind {
        inline for (@typeInfo(MessageKind).@"enum".fields) |f| {
            if (b == f.value) return @field(MessageKind, f.name);
        }
        return null;
    }

    /// The stable lowercase name, for logs and CLI output.
    pub fn label(self: MessageKind) []const u8 {
        return @tagName(self);
    }
};

/// A captured moment, with the tree entries needed to reconstruct it.
///
/// The entries are carried explicitly rather than as a delta against something
/// the peer may or may not hold: a live session is a stream a peer can join
/// late, and a frame that only makes sense in the context of frames you missed
/// is a frame you cannot join late on.
pub const MomentFrame = struct {
    id: moment.MomentId,
    /// Unix milliseconds.
    ms: i64,
    /// The Oid a full flat tree of this state hashes to. The receiver
    /// recomputes it and refuses a mismatch rather than accepting a partial.
    full_tree: Oid,
    entries: []const object.TreeEntry,
};

/// A verdict as it crosses the wire: the claim, plus the warrant that says
/// whether the claim is worth anything.
pub const VerdictFrame = struct {
    tree: Oid,
    tier: verdict.Tier,
    result: verdict.Result,
    /// Warrant axis 1: did the same actor write the code and the check?
    independence: verdict.Independence,
    /// Warrant axis 2: how many of the changed paths the check actually read.
    relevance_hit: u16,
    relevance_total: u16,
    /// Warrant axis 3: would the check have failed on the previous tree?
    discrimination: verdict.Discrimination,
};

/// An annotation sent back at a point in a file: `gr note src/foo.zig:42`.
///
/// This is the follower's whole write vocabulary. A note changes no tree and
/// takes no authority, which is why a read-only end is allowed to send one.
pub const NoteFrame = struct {
    path: []const u8,
    /// 1-based, as an editor counts.
    line: u32,
    text: []const u8,
};

/// Transfer of the write authority to a named peer. This is the only message
/// that changes who may write, and it is explicit for exactly that reason.
pub const HandoffFrame = struct {
    /// The new writer's identity.
    to: []const u8,
};

/// One protocol message.
pub const Message = union(MessageKind) {
    moment: MomentFrame,
    verdict: VerdictFrame,
    note: NoteFrame,
    handoff: HandoffFrame,
    bye: void,
};

/// Encode a message as `[kind][u32 payload length][payload]`, big-endian.
///
/// The outer length is what lets a reader skip a message it does not understand
/// instead of losing frame sync, and it is what makes truncation detectable at
/// the frame boundary rather than somewhere deep inside a field. Caller frees.
pub fn encode(alloc: std.mem.Allocator, msg: Message) ![]u8 {
    var body = Writer.init(alloc);
    defer body.deinit();

    switch (msg) {
        .moment => |f| {
            try body.bytes(&f.id);
            try body.putU64(@bitCast(f.ms));
            try body.oid(f.full_tree);
            try body.putU32(@intCast(f.entries.len));
            for (f.entries) |e| {
                try body.putU32(@intFromEnum(e.mode));
                try body.oid(e.blob);
                try body.putU16(@intCast(e.path.len));
                try body.bytes(e.path);
            }
        },
        .verdict => |f| {
            try body.oid(f.tree);
            try body.byte(enumByte(verdict.Tier, f.tier));
            try body.byte(enumByte(verdict.Result, f.result));
            try body.byte(enumByte(verdict.Independence, f.independence));
            try body.putU16(f.relevance_hit);
            try body.putU16(f.relevance_total);
            try body.byte(enumByte(verdict.Discrimination, f.discrimination));
        },
        .note => |f| {
            try body.putU16(@intCast(f.path.len));
            try body.bytes(f.path);
            try body.putU32(f.line);
            try body.putU32(@intCast(f.text.len));
            try body.bytes(f.text);
        },
        .handoff => |f| {
            try body.putU16(@intCast(f.to.len));
            try body.bytes(f.to);
        },
        .bye => {},
    }

    var out = Writer.init(alloc);
    errdefer out.deinit();
    try out.byte(@intFromEnum(std.meta.activeTag(msg)));
    try out.putU32(@intCast(body.list.items.len));
    try out.bytes(body.list.items);
    return out.finish();
}

/// Decode one message. Any byte string that ends early is `error.Truncated`;
/// an unknown tag is `error.UnknownKind`. Neither reads past the input.
/// Strings and entry slices are owned by `alloc`; free with `freeMessage`.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Message {
    var r = Reader.init(bytes);
    const tag = (try r.slice(1))[0];
    const kind = MessageKind.fromByte(tag) orelse return Error.UnknownKind;
    const len = try r.takeU32();
    var body = Reader.init(try r.slice(len));

    switch (kind) {
        .moment => {
            var id: moment.MomentId = undefined;
            @memcpy(&id, try body.slice(id.len));
            const ms: i64 = @bitCast(try body.takeU64());
            const full_tree = try body.oid();
            const n = try body.takeU32();
            // An entry cannot encode in fewer than mode + Oid + length bytes, so
            // a count the remaining bytes cannot possibly hold is truncation and
            // not a reason to attempt a huge allocation.
            if (n > body.remaining() / (4 + Oid.len + 2)) return Error.Truncated;

            const entries = try alloc.alloc(object.TreeEntry, n);
            var filled: usize = 0;
            errdefer {
                for (entries[0..filled]) |e| alloc.free(e.path);
                alloc.free(entries);
            }
            while (filled < n) : (filled += 1) {
                const mode: object.Mode = @enumFromInt(try body.takeU32());
                const blob = try body.oid();
                const plen = try body.takeU16();
                const path = try alloc.dupe(u8, try body.slice(plen));
                entries[filled] = .{ .mode = mode, .path = path, .blob = blob };
            }
            return .{ .moment = .{
                .id = id,
                .ms = ms,
                .full_tree = full_tree,
                .entries = entries,
            } };
        },
        .verdict => {
            const tree = try body.oid();
            const tier = try enumOf(verdict.Tier, (try body.slice(1))[0]);
            const result = try enumOf(verdict.Result, (try body.slice(1))[0]);
            const independence = try enumOf(verdict.Independence, (try body.slice(1))[0]);
            const hit = try body.takeU16();
            const total = try body.takeU16();
            const discrimination = try enumOf(verdict.Discrimination, (try body.slice(1))[0]);
            return .{ .verdict = .{
                .tree = tree,
                .tier = tier,
                .result = result,
                .independence = independence,
                .relevance_hit = hit,
                .relevance_total = total,
                .discrimination = discrimination,
            } };
        },
        .note => {
            const plen = try body.takeU16();
            const path = try alloc.dupe(u8, try body.slice(plen));
            errdefer alloc.free(path);
            const line = try body.takeU32();
            const tlen = try body.takeU32();
            const text = try alloc.dupe(u8, try body.slice(tlen));
            return .{ .note = .{ .path = path, .line = line, .text = text } };
        },
        .handoff => {
            const tlen = try body.takeU16();
            const to = try alloc.dupe(u8, try body.slice(tlen));
            return .{ .handoff = .{ .to = to } };
        },
        .bye => return .{ .bye = {} },
    }
}

/// Release whatever `decode` allocated for a message.
pub fn freeMessage(alloc: std.mem.Allocator, msg: Message) void {
    switch (msg) {
        .moment => |f| {
            for (f.entries) |e| alloc.free(e.path);
            alloc.free(f.entries);
        },
        .verdict => {},
        .note => |f| {
            alloc.free(f.path);
            alloc.free(f.text);
        },
        .handoff => |f| alloc.free(f.to),
        .bye => {},
    }
}

fn enumByte(comptime T: type, v: T) u8 {
    return @intCast(@intFromEnum(v));
}

fn enumOf(comptime T: type, b: u8) Error!T {
    if (b >= @typeInfo(T).@"enum".fields.len) return Error.BadFrame;
    return @enumFromInt(b);
}

// --- note targets ---

/// Parse `src/foo.zig:42` into a path and a 1-based line.
///
/// The last colon wins, so a path that itself contains a colon still parses.
/// An empty path, a missing line, a non-numeric line and line 0 are all
/// `error.BadNoteTarget`: a note that cannot be placed is not a note.
pub fn parseNoteTarget(s: []const u8) !struct { path: []const u8, line: u32 } {
    const colon = std.mem.lastIndexOfScalar(u8, s, ':') orelse return Error.BadNoteTarget;
    const path = s[0..colon];
    const line_text = s[colon + 1 ..];
    if (path.len == 0 or line_text.len == 0) return Error.BadNoteTarget;
    for (line_text) |c| if (!std.ascii.isDigit(c)) return Error.BadNoteTarget;
    const line = std.fmt.parseInt(u32, line_text, 10) catch return Error.BadNoteTarget;
    if (line == 0) return Error.BadNoteTarget;
    return .{ .path = path, .line = line };
}

// --- the one-writer rule ---

/// True only for the end that currently holds the write authority.
pub fn canWrite(session: Session) bool {
    return session.writer_is_me and session.role == .author;
}

/// Transfer the write authority to `to_peer`.
///
/// Only the current writer may do this; anyone else gets `error.NotTheWriter`.
/// The caller's own session swaps to follower in the same step, so there is no
/// window in which two ends both believe they can write.
pub fn applyHandoff(session: *Session, to_peer: []const u8) !void {
    if (!canWrite(session.*)) return Error.NotTheWriter;
    session.role = .follower;
    session.writer_is_me = false;
    session.peer = to_peer;
}

/// The mirror of `applyHandoff` on the receiving end: take the authority the
/// writer just gave up. A session that already writes gets
/// `error.AlreadyTheWriter`, because accepting twice would mean the sender never
/// gave it up and the rule has already been broken upstream.
pub fn acceptHandoff(session: *Session, from_peer: []const u8) !void {
    if (canWrite(session.*)) return Error.AlreadyTheWriter;
    session.role = .author;
    session.writer_is_me = true;
    session.peer = from_peer;
}

/// The guard every write path calls first.
///
/// A follower write is impossible rather than discouraged: the error type is
/// closed and unignorable, so a caller that forgets the rule does not compile
/// into a system with two writers. The follower's answer to wanting to write is
/// to fork the moment, which costs nothing.
pub fn rejectWrite(session: Session) error{ReadOnlyFollower}!void {
    if (!canWrite(session)) return error.ReadOnlyFollower;
}

// --- persisted notes ---

/// Notes outlive the session that produced them. They go to an append-only
/// `.gr/notes` log, one record per line:
///   <unix_ms> <line> <path-escaped>\t<text-escaped>\n
/// Path and text are escaped (`\`→`\\`, `\n`→`\n`, `\t`→`\t`) so neither can
/// contain a literal tab or newline and the framing stays unambiguous.
pub fn recordNote(store: *Store, note: NoteFrame, ms: i64) !void {
    const alloc = store.alloc;

    const path_esc = try escape(alloc, note.path);
    defer alloc.free(path_esc);
    const text_esc = try escape(alloc, note.text);
    defer alloc.free(text_esc);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try out.print(alloc, "{d} {d} {s}\t{s}\n", .{ ms, note.line, path_esc, text_esc });

    try applog.append(store, notes_log_path, out.items);
}

/// Every recorded note in record order. Malformed lines are skipped rather than
/// failing the read, since one bad line must not hide the rest of the session.
/// Caller frees with `freeNotes`.
pub fn notes(store: *Store, alloc: std.mem.Allocator) ![]NoteFrame {
    const data = try applog.readAll(store, alloc, notes_log_path);
    defer alloc.free(data);

    var list: std.ArrayList(NoteFrame) = .empty;
    errdefer {
        for (list.items) |n| freeNote(alloc, n);
        list.deinit(alloc);
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        if (raw.len == 0) continue;
        const note = (try parseNoteLine(alloc, raw)) orelse continue;
        try list.append(alloc, note);
    }
    return list.toOwnedSlice(alloc);
}

/// Release one note read back from the log.
pub fn freeNote(alloc: std.mem.Allocator, note: NoteFrame) void {
    alloc.free(note.path);
    alloc.free(note.text);
}

/// Release a slice returned by `notes`.
pub fn freeNotes(alloc: std.mem.Allocator, list: []NoteFrame) void {
    for (list) |n| freeNote(alloc, n);
    alloc.free(list);
}

fn parseNoteLine(alloc: std.mem.Allocator, raw: []const u8) !?NoteFrame {
    const sp1 = std.mem.indexOfScalar(u8, raw, ' ') orelse return null;
    _ = std.fmt.parseInt(i64, raw[0..sp1], 10) catch return null;
    const rest = raw[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    const line = std.fmt.parseInt(u32, rest[0..sp2], 10) catch return null;
    const tail = rest[sp2 + 1 ..];
    const tab = std.mem.indexOfScalar(u8, tail, '\t') orelse return null;

    const path = try unescape(alloc, tail[0..tab]);
    errdefer alloc.free(path);
    const text = try unescape(alloc, tail[tab + 1 ..]);
    return .{ .path = path, .line = line, .text = text };
}

fn escape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (s) |ch| switch (ch) {
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => try out.append(alloc, ch),
    };
    return out.toOwnedSlice(alloc);
}

fn unescape(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '\\' => try out.append(alloc, '\\'),
                'n' => try out.append(alloc, '\n'),
                't' => try out.append(alloc, '\t'),
                else => try out.append(alloc, s[i]),
            }
        } else {
            try out.append(alloc, s[i]);
        }
    }
    return out.toOwnedSlice(alloc);
}

// --- settings ---

/// Live sessions are opt-in and off by default. Nothing in this file starts
/// listening, dials out or exposes a moment unless the repo said yes.
pub const Settings = struct {
    enabled: bool = false,
};

fn boolOf(v: []const u8) bool {
    return !(std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "off") or
        std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "no"));
}

/// Read `live.enabled` (local config, then global). A missing or unreadable key
/// leaves the default in place: opt-in means silence reads as off.
pub fn settings(store: *Store, alloc: std.mem.Allocator) Settings {
    var out: Settings = .{};
    if (config.get(store, alloc, "live.enabled")) |maybe| {
        if (maybe) |v| {
            defer alloc.free(v);
            out.enabled = boolOf(v);
        }
    } else |_| {}
    return out;
}

// --- tiny binary encode/decode helpers (big-endian, self-describing lengths) ---

const Writer = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Writer {
        return .{ .list = .empty, .alloc = alloc };
    }
    fn deinit(self: *Writer) void {
        self.list.deinit(self.alloc);
    }
    fn byte(self: *Writer, b: u8) !void {
        try self.list.append(self.alloc, b);
    }
    fn bytes(self: *Writer, b: []const u8) !void {
        try self.list.appendSlice(self.alloc, b);
    }
    fn putU16(self: *Writer, v: u16) !void {
        var buf: [2]u8 = undefined;
        std.mem.writeInt(u16, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn putU32(self: *Writer, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn putU64(self: *Writer, v: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .big);
        try self.bytes(&buf);
    }
    fn oid(self: *Writer, o: Oid) !void {
        try self.bytes(&o.bytes);
    }
    fn finish(self: *Writer) ![]u8 {
        return self.list.toOwnedSlice(self.alloc);
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize,

    fn init(data: []const u8) Reader {
        return .{ .data = data, .pos = 0 };
    }
    fn remaining(self: *const Reader) usize {
        return self.data.len - self.pos;
    }
    fn slice(self: *Reader, n: usize) Error![]const u8 {
        if (n > self.remaining()) return Error.Truncated;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
    fn takeU16(self: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try self.slice(2))[0..2], .big);
    }
    fn takeU32(self: *Reader) Error!u32 {
        return std.mem.readInt(u32, (try self.slice(4))[0..4], .big);
    }
    fn takeU64(self: *Reader) Error!u64 {
        return std.mem.readInt(u64, (try self.slice(8))[0..8], .big);
    }
    fn oid(self: *Reader) Error!Oid {
        var o: Oid = undefined;
        @memcpy(&o.bytes, try self.slice(Oid.len));
        return o;
    }
};

// --- tests ---

const testing = std.testing;

const sample_entries = [_]object.TreeEntry{
    .{ .mode = .regular, .path = "src/live.zig", .blob = .{ .bytes = [_]u8{0xa1} ** Oid.len } },
    .{ .mode = .executable, .path = "bin/run", .blob = .{ .bytes = [_]u8{0xb2} ** Oid.len } },
};

fn sampleMoment() Message {
    return .{ .moment = .{
        .id = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 },
        .ms = 1_700_000_000_123,
        .full_tree = Oid.ofBytes("full"),
        .entries = &sample_entries,
    } };
}

fn sampleVerdict() Message {
    return .{ .verdict = .{
        .tree = Oid.ofBytes("tree"),
        .tier = .full,
        .result = .green,
        .independence = .co_authored,
        .relevance_hit = 3,
        .relevance_total = 7,
        .discrimination = .vacuous,
    } };
}

fn sampleNote() Message {
    return .{ .note = .{ .path = "src/foo.zig", .line = 42, .text = "this branch never runs" } };
}

fn sampleHandoff() Message {
    return .{ .handoff = .{ .to = "nico@studio" } };
}

test "a moment frame round trips exactly" {
    const alloc = testing.allocator;
    const msg = sampleMoment();
    const enc = try encode(alloc, msg);
    defer alloc.free(enc);
    const dec = try decode(alloc, enc);
    defer freeMessage(alloc, dec);

    try testing.expectEqual(MessageKind.moment, std.meta.activeTag(dec));
    try testing.expectEqualSlices(u8, &msg.moment.id, &dec.moment.id);
    try testing.expectEqual(msg.moment.ms, dec.moment.ms);
    try testing.expect(dec.moment.full_tree.eql(msg.moment.full_tree));
    try testing.expectEqual(@as(usize, 2), dec.moment.entries.len);
    try testing.expectEqualStrings("src/live.zig", dec.moment.entries[0].path);
    try testing.expectEqual(object.Mode.executable, dec.moment.entries[1].mode);
    try testing.expect(dec.moment.entries[1].blob.eql(sample_entries[1].blob));
}

test "a moment frame with no entries round trips" {
    const alloc = testing.allocator;
    const msg = Message{ .moment = .{
        .id = [_]u8{0} ** 8,
        .ms = -1,
        .full_tree = Oid.zero(),
        .entries = &.{},
    } };
    const enc = try encode(alloc, msg);
    defer alloc.free(enc);
    const dec = try decode(alloc, enc);
    defer freeMessage(alloc, dec);
    try testing.expectEqual(@as(usize, 0), dec.moment.entries.len);
    try testing.expectEqual(@as(i64, -1), dec.moment.ms);
}

test "a verdict frame round trips with all three warrant axes" {
    const alloc = testing.allocator;
    const msg = sampleVerdict();
    const enc = try encode(alloc, msg);
    defer alloc.free(enc);
    const dec = try decode(alloc, enc);
    defer freeMessage(alloc, dec);

    try testing.expect(dec.verdict.tree.eql(msg.verdict.tree));
    try testing.expectEqual(verdict.Tier.full, dec.verdict.tier);
    try testing.expectEqual(verdict.Result.green, dec.verdict.result);
    try testing.expectEqual(verdict.Independence.co_authored, dec.verdict.independence);
    try testing.expectEqual(@as(u16, 3), dec.verdict.relevance_hit);
    try testing.expectEqual(@as(u16, 7), dec.verdict.relevance_total);
    try testing.expectEqual(verdict.Discrimination.vacuous, dec.verdict.discrimination);
}

test "every verdict enum combination survives the wire" {
    const alloc = testing.allocator;
    inline for (@typeInfo(verdict.Tier).@"enum".fields) |tier| {
        inline for (@typeInfo(verdict.Result).@"enum".fields) |result| {
            inline for (@typeInfo(verdict.Independence).@"enum".fields) |ind| {
                inline for (@typeInfo(verdict.Discrimination).@"enum".fields) |dis| {
                    const msg = Message{ .verdict = .{
                        .tree = Oid.ofBytes("t"),
                        .tier = @field(verdict.Tier, tier.name),
                        .result = @field(verdict.Result, result.name),
                        .independence = @field(verdict.Independence, ind.name),
                        .relevance_hit = 0,
                        .relevance_total = 0,
                        .discrimination = @field(verdict.Discrimination, dis.name),
                    } };
                    const enc = try encode(alloc, msg);
                    defer alloc.free(enc);
                    const dec = try decode(alloc, enc);
                    defer freeMessage(alloc, dec);
                    try testing.expectEqual(msg.verdict.tier, dec.verdict.tier);
                    try testing.expectEqual(msg.verdict.result, dec.verdict.result);
                    try testing.expectEqual(msg.verdict.independence, dec.verdict.independence);
                    try testing.expectEqual(msg.verdict.discrimination, dec.verdict.discrimination);
                }
            }
        }
    }
}

test "a note frame round trips, including empty strings and utf-8" {
    const alloc = testing.allocator;
    const cases = [_]NoteFrame{
        .{ .path = "src/foo.zig", .line = 42, .text = "this branch never runs" },
        .{ .path = "", .line = 1, .text = "" },
        .{ .path = "docs/ünïcode.md", .line = 4_294_967_295, .text = "λ → ✓ 日本語 🚦 tabs\tand\nnewlines" },
    };
    for (cases) |note| {
        const enc = try encode(alloc, .{ .note = note });
        defer alloc.free(enc);
        const dec = try decode(alloc, enc);
        defer freeMessage(alloc, dec);
        try testing.expectEqualStrings(note.path, dec.note.path);
        try testing.expectEqual(note.line, dec.note.line);
        try testing.expectEqualStrings(note.text, dec.note.text);
    }
}

test "a handoff frame round trips, including an empty identity" {
    const alloc = testing.allocator;
    for ([_][]const u8{ "nico@studio", "", "peer with spaces and ünïcode" }) |who| {
        const enc = try encode(alloc, .{ .handoff = .{ .to = who } });
        defer alloc.free(enc);
        const dec = try decode(alloc, enc);
        defer freeMessage(alloc, dec);
        try testing.expectEqualStrings(who, dec.handoff.to);
    }
}

test "a bye frame round trips and carries no payload" {
    const alloc = testing.allocator;
    const enc = try encode(alloc, .bye);
    defer alloc.free(enc);
    try testing.expectEqual(@as(usize, 5), enc.len);
    try testing.expectEqual(@as(u8, 'B'), enc[0]);
    const dec = try decode(alloc, enc);
    defer freeMessage(alloc, dec);
    try testing.expectEqual(MessageKind.bye, std.meta.activeTag(dec));
}

test "truncating any frame at any length is an error, never a read past the end" {
    const alloc = testing.allocator;
    const msgs = [_]Message{ sampleMoment(), sampleVerdict(), sampleNote(), sampleHandoff(), .bye };
    for (msgs) |msg| {
        const enc = try encode(alloc, msg);
        defer alloc.free(enc);
        var cut: usize = 0;
        while (cut < enc.len) : (cut += 1) {
            try testing.expectError(Error.Truncated, decode(alloc, enc[0..cut]));
        }
    }
}

test "an empty input is truncated, not a valid message" {
    try testing.expectError(Error.Truncated, decode(testing.allocator, ""));
}

test "an unknown kind byte errors cleanly" {
    const alloc = testing.allocator;
    const enc = try encode(alloc, sampleNote());
    defer alloc.free(enc);
    const bad = try alloc.dupe(u8, enc);
    defer alloc.free(bad);
    bad[0] = 'Z';
    try testing.expectError(Error.UnknownKind, decode(alloc, bad));
    bad[0] = 0;
    try testing.expectError(Error.UnknownKind, decode(alloc, bad));
}

test "an absurd entry count is truncation, not a huge allocation" {
    const alloc = testing.allocator;
    const enc = try encode(alloc, sampleMoment());
    defer alloc.free(enc);
    const bad = try alloc.dupe(u8, enc);
    defer alloc.free(bad);
    // The entry count sits after kind(1) + len(4) + id(8) + ms(8) + tree Oid.
    const at = 1 + 4 + 8 + 8 + Oid.len;
    std.mem.writeInt(u32, bad[at..][0..4], 0xffff_ffff, .big);
    try testing.expectError(Error.Truncated, decode(alloc, bad));
}

test "an out of range enum byte is a bad frame" {
    const alloc = testing.allocator;
    const enc = try encode(alloc, sampleVerdict());
    defer alloc.free(enc);
    const bad = try alloc.dupe(u8, enc);
    defer alloc.free(bad);
    bad[1 + 4 + Oid.len] = 200;
    try testing.expectError(Error.BadFrame, decode(alloc, bad));
}

test "parseNoteTarget accepts a path and a line" {
    const t = try parseNoteTarget("a/b/c.zig:1");
    try testing.expectEqualStrings("a/b/c.zig", t.path);
    try testing.expectEqual(@as(u32, 1), t.line);

    const deep = try parseNoteTarget("src/live.zig:4096");
    try testing.expectEqualStrings("src/live.zig", deep.path);
    try testing.expectEqual(@as(u32, 4096), deep.line);
}

test "parseNoteTarget lets the last colon win" {
    const t = try parseNoteTarget("weird:dir/f.zig:42");
    try testing.expectEqualStrings("weird:dir/f.zig", t.path);
    try testing.expectEqual(@as(u32, 42), t.line);
}

test "parseNoteTarget rejects malformed targets" {
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("no-line.zig"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig:abc"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget(":42"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget(""));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig:"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig:0"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig:-3"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig: 3"));
    try testing.expectError(Error.BadNoteTarget, parseNoteTarget("f.zig:99999999999"));
}

test "a follower cannot write" {
    const follower = Session{
        .role = .follower,
        .peer = "author@laptop",
        .started_ms = 1,
        .writer_is_me = false,
    };
    try testing.expect(!canWrite(follower));
    try testing.expectError(error.ReadOnlyFollower, rejectWrite(follower));

    // The flag and the role move together: neither half alone grants a write.
    try testing.expect(!canWrite(.{
        .role = .author,
        .peer = "p",
        .started_ms = 1,
        .writer_is_me = false,
    }));
    try testing.expect(!canWrite(.{
        .role = .follower,
        .peer = "p",
        .started_ms = 1,
        .writer_is_me = true,
    }));
}

test "the author writes and a handoff swaps the roles" {
    var author = Session{
        .role = .author,
        .peer = "follower@studio",
        .started_ms = 10,
        .writer_is_me = true,
    };
    try testing.expect(canWrite(author));
    try rejectWrite(author);

    try applyHandoff(&author, "follower@studio");
    try testing.expectEqual(Role.follower, author.role);
    try testing.expect(!author.writer_is_me);
    try testing.expect(!canWrite(author));
    try testing.expectError(error.ReadOnlyFollower, rejectWrite(author));
    try testing.expectEqualStrings("follower@studio", author.peer);
}

test "only the writer may hand off" {
    var follower = Session{
        .role = .follower,
        .peer = "author@laptop",
        .started_ms = 10,
        .writer_is_me = false,
    };
    try testing.expectError(Error.NotTheWriter, applyHandoff(&follower, "someone"));
    // The rejected attempt changed nothing.
    try testing.expectEqual(Role.follower, follower.role);
    try testing.expectEqualStrings("author@laptop", follower.peer);
}

test "the other end accepts the authority exactly once" {
    var follower = Session{
        .role = .follower,
        .peer = "author@laptop",
        .started_ms = 10,
        .writer_is_me = false,
    };
    try acceptHandoff(&follower, "author@laptop");
    try testing.expectEqual(Role.author, follower.role);
    try testing.expect(canWrite(follower));
    try rejectWrite(follower);
    try testing.expectError(Error.AlreadyTheWriter, acceptHandoff(&follower, "author@laptop"));
}

test "a handoff round trip leaves exactly one writer at every step" {
    var a = Session{ .role = .author, .peer = "b", .started_ms = 0, .writer_is_me = true };
    var b = Session{ .role = .follower, .peer = "a", .started_ms = 0, .writer_is_me = false };
    try testing.expect(canWrite(a) != canWrite(b));

    try applyHandoff(&a, "b");
    try acceptHandoff(&b, "a");
    try testing.expect(canWrite(a) != canWrite(b));
    try testing.expect(canWrite(b));

    try applyHandoff(&b, "a");
    try acceptHandoff(&a, "b");
    try testing.expect(canWrite(a) != canWrite(b));
    try testing.expect(canWrite(a));
}

test "notes persist and read back in order" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const empty = try notes(&s, alloc);
    defer freeNotes(alloc, empty);
    try testing.expectEqual(@as(usize, 0), empty.len);

    try recordNote(&s, .{ .path = "src/a.zig", .line = 1, .text = "first" }, 1000);
    try recordNote(&s, .{ .path = "src/b.zig", .line = 99, .text = "second" }, 2000);

    const got = try notes(&s, alloc);
    defer freeNotes(alloc, got);
    try testing.expectEqual(@as(usize, 2), got.len);
    try testing.expectEqualStrings("src/a.zig", got[0].path);
    try testing.expectEqualStrings("first", got[0].text);
    try testing.expectEqual(@as(u32, 99), got[1].line);
    try testing.expectEqualStrings("second", got[1].text);
}

test "note escaping survives the log" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const text = "line1\nline2\twith tab\n\tand a backslash \\ end ünïcode 🚦";
    const path = "src/weird\tname\\dir.zig";
    try recordNote(&s, .{ .path = path, .line = 7, .text = text }, 42);

    const got = try notes(&s, alloc);
    defer freeNotes(alloc, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings(path, got[0].path);
    try testing.expectEqualStrings(text, got[0].text);
    try testing.expectEqual(@as(u32, 7), got[0].line);
}

test "a note survives the wire and then the log" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    const target = try parseNoteTarget("src/live.zig:128");
    const enc = try encode(alloc, .{ .note = .{
        .path = target.path,
        .line = target.line,
        .text = "handoff here",
    } });
    defer alloc.free(enc);
    const dec = try decode(alloc, enc);
    defer freeMessage(alloc, dec);

    try recordNote(&s, dec.note, 1_700_000_000_000);
    const got = try notes(&s, alloc);
    defer freeNotes(alloc, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("src/live.zig", got[0].path);
    try testing.expectEqual(@as(u32, 128), got[0].line);
    try testing.expectEqualStrings("handoff here", got[0].text);
}

test "malformed note lines are skipped, not fatal" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try applog.append(&s, notes_log_path, "garbage\nnotanumber 3 p\tt\n1 x p\tt\n5 6 ok\tfine\n");
    const got = try notes(&s, alloc);
    defer freeNotes(alloc, got);
    try testing.expectEqual(@as(usize, 1), got.len);
    try testing.expectEqualStrings("ok", got[0].path);
    try testing.expectEqualStrings("fine", got[0].text);
}

test "live is off unless the repo opts in" {
    const io = std.testing.io;
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try Store.init(io, alloc, tmp.dir);
    defer s.deinit();

    try testing.expect(!settings(&s, alloc).enabled);

    try config.set(&s, "live.enabled", "true");
    try testing.expect(settings(&s, alloc).enabled);

    try config.set(&s, "live.enabled", "off");
    try testing.expect(!settings(&s, alloc).enabled);
}
