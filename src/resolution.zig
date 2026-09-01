const std = @import("std");
const oid = @import("oid.zig");
const applog = @import("applog.zig");
const verdict = @import("verdict.zig");
const Store = @import("store.zig").Store;
const Oid = oid.Oid;

pub const log_path = "resolutions";

pub const Error = error{
    InvalidConflict,
    CorruptResolutionRecord,
    CorruptResolutionObject,
};

pub const Conflict = struct {
    base: ?Oid,
    candidates: []const ?Oid,
};

pub const HistoricalEvidence = struct {
    tree: Oid,
    tier: verdict.Tier,
    command: Oid,
    inputs: Oid,
};

pub const Resolution = union(enum) {
    content: []const u8,
    deleted,
};

pub const StoredResolution = union(enum) {
    content: struct {
        blob: Oid,
        digest: Oid,
    },
    deleted,
};

pub const Entry = struct {
    fingerprint: Oid,
    base: ?Oid,
    candidates: []?Oid,
    resolution: StoredResolution,
    recorded_ms: i64,
    evidence: ?HistoricalEvidence,

    pub fn deinit(self: Entry, alloc: std.mem.Allocator) void {
        alloc.free(self.candidates);
    }
};

pub const Match = struct {
    fingerprint: Oid,
    resolution: union(enum) {
        content: []u8,
        deleted,
    },
    recorded_ms: i64,
    evidence: ?HistoricalEvidence,

    pub fn deinit(self: Match, alloc: std.mem.Allocator) void {
        switch (self.resolution) {
            .content => |bytes| alloc.free(bytes),
            .deleted => {},
        }
    }
};

pub const GcReport = struct {
    kept: usize,
    superseded: usize,
    forgotten: usize,
    corrupt: usize,
    malformed: usize,
};

const Scan = struct {
    entries: std.AutoHashMap([Oid.len]u8, Entry),
    poisoned: std.AutoHashMap([Oid.len]u8, void),
    records: usize = 0,
    forgotten: usize = 0,
    corrupt: usize = 0,
    malformed: usize = 0,

    fn deinit(self: *Scan, alloc: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |entry| entry.deinit(alloc);
        self.entries.deinit();
        self.poisoned.deinit();
    }
};

fn lessIdentity(a: ?Oid, b: ?Oid) bool {
    if (a == null) return b != null;
    if (b == null) return false;
    return std.mem.order(u8, &a.?.bytes, &b.?.bytes) == .lt;
}

fn identitiesEqual(a: ?Oid, b: ?Oid) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn canonicalCandidates(alloc: std.mem.Allocator, candidates: []const ?Oid) ![]?Oid {
    if (candidates.len < 2) return Error.InvalidConflict;
    const sorted = try alloc.dupe(?Oid, candidates);
    errdefer alloc.free(sorted);
    var i: usize = 1;
    while (i < sorted.len) : (i += 1) {
        const value = sorted[i];
        var j = i;
        while (j > 0 and lessIdentity(value, sorted[j - 1])) : (j -= 1) {
            sorted[j] = sorted[j - 1];
        }
        sorted[j] = value;
    }
    for (sorted[1..], 1..) |value, index| {
        if (identitiesEqual(sorted[index - 1], value)) return Error.InvalidConflict;
    }
    return sorted;
}

fn hashOptional(hasher: *oid.Hasher, value: ?Oid) void {
    if (value) |present| {
        hasher.update(&[_]u8{1});
        hasher.update(&present.bytes);
    } else {
        hasher.update(&[_]u8{0});
    }
}

fn fingerprintCanonical(base: ?Oid, candidates: []const ?Oid) Oid {
    var hasher = oid.Hasher.init();
    hasher.update("superdetermine-resolution-conflict-v1\x00");
    hashOptional(&hasher, base);
    var count: [8]u8 = undefined;
    std.mem.writeInt(u64, &count, @intCast(candidates.len), .little);
    hasher.update(&count);
    for (candidates) |value| hashOptional(&hasher, value);
    return hasher.finalOid();
}

pub fn fingerprint(alloc: std.mem.Allocator, conflict: Conflict) !Oid {
    const candidates = try canonicalCandidates(alloc, conflict.candidates);
    defer alloc.free(candidates);
    return fingerprintCanonical(conflict.base, candidates);
}

fn nowMillis(store: *Store) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, store.io).nanoseconds, std.time.ns_per_ms));
}

fn oidToken(value: ?Oid, buf: *[Oid.len * 2]u8) []const u8 {
    if (value) |present| return present.toHex(buf);
    return "-";
}

fn parseOptionalOid(token: []const u8) !?Oid {
    if (std.mem.eql(u8, token, "-")) return null;
    return Oid.fromHex(token) catch return error.InvalidResolutionRecord;
}

fn encodeCandidates(alloc: std.mem.Allocator, candidates: []const ?Oid) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    for (candidates, 0..) |value, i| {
        if (i != 0) try out.append(alloc, ',');
        if (value) |present| {
            var hex: [Oid.len * 2]u8 = undefined;
            try out.appendSlice(alloc, present.toHex(&hex));
        } else {
            try out.append(alloc, '-');
        }
    }
    return out.toOwnedSlice(alloc);
}

fn parseCandidates(alloc: std.mem.Allocator, token: []const u8) ![]?Oid {
    var out: std.ArrayList(?Oid) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, token, ',');
    while (it.next()) |item| {
        if (item.len == 0) return error.InvalidResolutionRecord;
        try out.append(alloc, try parseOptionalOid(item));
    }
    const values = try out.toOwnedSlice(alloc);
    errdefer alloc.free(values);
    if (values.len < 2) return error.InvalidResolutionRecord;
    for (values[1..], 1..) |value, index| {
        if (!lessIdentity(values[index - 1], value)) return error.InvalidResolutionRecord;
    }
    return values;
}

fn checksum(payload: []const u8) Oid {
    return Oid.ofBytes(payload);
}

fn formatEntry(alloc: std.mem.Allocator, entry: Entry) ![]u8 {
    var fp_hex: [Oid.len * 2]u8 = undefined;
    var base_hex: [Oid.len * 2]u8 = undefined;
    var blob_hex: [Oid.len * 2]u8 = undefined;
    var digest_hex: [Oid.len * 2]u8 = undefined;
    var tree_hex: [Oid.len * 2]u8 = undefined;
    var cmd_hex: [Oid.len * 2]u8 = undefined;
    var inputs_hex: [Oid.len * 2]u8 = undefined;
    const candidates = try encodeCandidates(alloc, entry.candidates);
    defer alloc.free(candidates);

    const kind: []const u8 = switch (entry.resolution) {
        .content => "content",
        .deleted => "deleted",
    };
    const blob: ?Oid = switch (entry.resolution) {
        .content => |stored| stored.blob,
        .deleted => null,
    };
    const digest: ?Oid = switch (entry.resolution) {
        .content => |stored| stored.digest,
        .deleted => null,
    };
    const evidence_tree: ?Oid = if (entry.evidence) |e| e.tree else null;
    const tier: []const u8 = if (entry.evidence) |e| e.tier.label() else "-";
    const command: ?Oid = if (entry.evidence) |e| e.command else null;
    const inputs: ?Oid = if (entry.evidence) |e| e.inputs else null;

    const payload = try std.fmt.allocPrint(
        alloc,
        "R\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{s}\t{s}\t{s}\t{s}",
        .{
            entry.fingerprint.toHex(&fp_hex),
            oidToken(entry.base, &base_hex),
            candidates,
            kind,
            oidToken(blob, &blob_hex),
            oidToken(digest, &digest_hex),
            entry.recorded_ms,
            oidToken(evidence_tree, &tree_hex),
            tier,
            oidToken(command, &cmd_hex),
            oidToken(inputs, &inputs_hex),
        },
    );
    defer alloc.free(payload);
    var sum_hex: [Oid.len * 2]u8 = undefined;
    return std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ payload, checksum(payload).toHex(&sum_hex) });
}

fn appendEntry(store: *Store, entry: Entry) !void {
    const line = try formatEntry(store.alloc, entry);
    defer store.alloc.free(line);
    try applog.append(store, log_path, line);
}

fn appendForget(store: *Store, value: Oid) !void {
    const alloc = store.alloc;
    var fp_hex: [Oid.len * 2]u8 = undefined;
    const payload = try std.fmt.allocPrint(alloc, "F\t{s}", .{value.toHex(&fp_hex)});
    defer alloc.free(payload);
    var sum_hex: [Oid.len * 2]u8 = undefined;
    const line = try std.fmt.allocPrint(alloc, "{s}\t{s}\n", .{ payload, checksum(payload).toHex(&sum_hex) });
    defer alloc.free(line);
    try applog.append(store, log_path, line);
}

const Parsed = union(enum) {
    record: Entry,
    forget: Oid,
};

fn looseFingerprint(line: []const u8) ?Oid {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const kind = fields.next() orelse return null;
    if (!std.mem.eql(u8, kind, "R") and !std.mem.eql(u8, kind, "F")) return null;
    const fp = fields.next() orelse return null;
    return Oid.fromHex(fp) catch null;
}

fn parseLine(alloc: std.mem.Allocator, line: []const u8) !Parsed {
    const last_tab = std.mem.lastIndexOfScalar(u8, line, '\t') orelse return error.InvalidResolutionRecord;
    const payload = line[0..last_tab];
    const expected = Oid.fromHex(line[last_tab + 1 ..]) catch return error.InvalidResolutionRecord;
    if (!checksum(payload).eql(expected)) return error.InvalidResolutionRecord;

    var fields = std.mem.splitScalar(u8, payload, '\t');
    const kind = fields.next() orelse return error.InvalidResolutionRecord;
    const fp = Oid.fromHex(fields.next() orelse return error.InvalidResolutionRecord) catch return error.InvalidResolutionRecord;
    if (std.mem.eql(u8, kind, "F")) {
        if (fields.next() != null) return error.InvalidResolutionRecord;
        return .{ .forget = fp };
    }
    if (!std.mem.eql(u8, kind, "R")) return error.InvalidResolutionRecord;

    const base = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    const candidates = try parseCandidates(alloc, fields.next() orelse return error.InvalidResolutionRecord);
    errdefer alloc.free(candidates);
    const resolution_kind = fields.next() orelse return error.InvalidResolutionRecord;
    const blob = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    const digest = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    const recorded_ms = std.fmt.parseInt(i64, fields.next() orelse return error.InvalidResolutionRecord, 10) catch return error.InvalidResolutionRecord;
    const evidence_tree = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    const tier_token = fields.next() orelse return error.InvalidResolutionRecord;
    const command = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    const inputs = try parseOptionalOid(fields.next() orelse return error.InvalidResolutionRecord);
    if (fields.next() != null) return error.InvalidResolutionRecord;

    const resolution: StoredResolution = if (std.mem.eql(u8, resolution_kind, "content")) blk: {
        if (blob == null or digest == null) return error.InvalidResolutionRecord;
        break :blk .{ .content = .{ .blob = blob.?, .digest = digest.? } };
    } else if (std.mem.eql(u8, resolution_kind, "deleted")) blk: {
        if (blob != null or digest != null) return error.InvalidResolutionRecord;
        break :blk .deleted;
    } else return error.InvalidResolutionRecord;

    const any_evidence = evidence_tree != null or !std.mem.eql(u8, tier_token, "-") or command != null or inputs != null;
    const evidence: ?HistoricalEvidence = if (any_evidence) blk: {
        if (evidence_tree == null or command == null or inputs == null) return error.InvalidResolutionRecord;
        const tier = verdict.Tier.fromLabel(tier_token) orelse return error.InvalidResolutionRecord;
        break :blk .{ .tree = evidence_tree.?, .tier = tier, .command = command.?, .inputs = inputs.? };
    } else null;

    const actual = fingerprintCanonical(base, candidates);
    if (!actual.eql(fp)) return error.InvalidResolutionRecord;
    return .{ .record = .{
        .fingerprint = fp,
        .base = base,
        .candidates = candidates,
        .resolution = resolution,
        .recorded_ms = recorded_ms,
        .evidence = evidence,
    } };
}

fn scan(store: *Store, alloc: std.mem.Allocator) !Scan {
    var out: Scan = .{
        .entries = std.AutoHashMap([Oid.len]u8, Entry).init(alloc),
        .poisoned = std.AutoHashMap([Oid.len]u8, void).init(alloc),
    };
    errdefer out.deinit(alloc);
    const data = try applog.readAll(store, alloc, log_path);
    defer alloc.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        out.records += 1;
        const parsed = parseLine(alloc, line) catch {
            if (looseFingerprint(line)) |fp| {
                if (out.entries.fetchRemove(fp.bytes)) |removed| removed.value.deinit(alloc);
                try out.poisoned.put(fp.bytes, {});
                out.corrupt += 1;
            } else {
                out.malformed += 1;
            }
            continue;
        };
        switch (parsed) {
            .record => |entry| {
                _ = out.poisoned.remove(entry.fingerprint.bytes);
                if (try out.entries.fetchPut(entry.fingerprint.bytes, entry)) |old| old.value.deinit(alloc);
            },
            .forget => |fp| {
                _ = out.poisoned.remove(fp.bytes);
                if (out.entries.fetchRemove(fp.bytes)) |removed| removed.value.deinit(alloc);
                out.forgotten += 1;
            },
        }
    }
    return out;
}

fn cloneEntry(alloc: std.mem.Allocator, entry: Entry) !Entry {
    var copy = entry;
    copy.candidates = try alloc.dupe(?Oid, entry.candidates);
    return copy;
}

pub fn record(store: *Store, alloc: std.mem.Allocator, conflict: Conflict, resolution: Resolution, evidence: ?HistoricalEvidence) !Oid {
    const candidates = try canonicalCandidates(alloc, conflict.candidates);
    defer alloc.free(candidates);
    const fp = fingerprintCanonical(conflict.base, candidates);
    const stored: StoredResolution = switch (resolution) {
        .content => |bytes| .{ .content = .{
            .blob = try store.writeFileContent(bytes),
            .digest = Oid.ofBytes(bytes),
        } },
        .deleted => .deleted,
    };
    try appendEntry(store, .{
        .fingerprint = fp,
        .base = conflict.base,
        .candidates = candidates,
        .resolution = stored,
        .recorded_ms = nowMillis(store),
        .evidence = evidence,
    });
    return fp;
}

pub fn restore(store: *Store, entry: Entry) !void {
    if (entry.candidates.len < 2) return Error.InvalidConflict;
    for (entry.candidates[1..], 1..) |value, index| {
        if (!lessIdentity(entry.candidates[index - 1], value)) return Error.InvalidConflict;
    }
    if (!fingerprintCanonical(entry.base, entry.candidates).eql(entry.fingerprint)) return Error.InvalidConflict;
    switch (entry.resolution) {
        .deleted => {},
        .content => |stored| {
            const bytes = store.readFileContent(stored.blob) catch return Error.CorruptResolutionObject;
            defer store.alloc.free(bytes);
            if (!Oid.ofBytes(bytes).eql(stored.digest)) return Error.CorruptResolutionObject;
        },
    }
    try appendEntry(store, entry);
}

pub fn forget(store: *Store, alloc: std.mem.Allocator, fp: Oid) !?Entry {
    var state = try scan(store, alloc);
    defer state.deinit(alloc);
    if (state.poisoned.contains(fp.bytes)) return Error.CorruptResolutionRecord;
    const found = state.entries.get(fp.bytes) orelse return null;
    const previous = try cloneEntry(alloc, found);
    errdefer previous.deinit(alloc);
    try appendForget(store, fp);
    return previous;
}

pub fn lookup(store: *Store, alloc: std.mem.Allocator, conflict: Conflict) !?Match {
    const fp = try fingerprint(alloc, conflict);
    var state = try scan(store, alloc);
    defer state.deinit(alloc);
    if (state.poisoned.contains(fp.bytes)) return Error.CorruptResolutionRecord;
    const entry = state.entries.get(fp.bytes) orelse return null;
    const resolved = switch (entry.resolution) {
        .deleted => Match{ .fingerprint = fp, .resolution = .deleted, .recorded_ms = entry.recorded_ms, .evidence = entry.evidence },
        .content => |stored| blk: {
            const bytes = store.readFileContent(stored.blob) catch return Error.CorruptResolutionObject;
            errdefer alloc.free(bytes);
            if (!Oid.ofBytes(bytes).eql(stored.digest)) return Error.CorruptResolutionObject;
            break :blk Match{ .fingerprint = fp, .resolution = .{ .content = bytes }, .recorded_ms = entry.recorded_ms, .evidence = entry.evidence };
        },
    };
    return resolved;
}

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, &a.fingerprint.bytes, &b.fingerprint.bytes) == .lt;
}

pub fn list(store: *Store, alloc: std.mem.Allocator) ![]Entry {
    var state = try scan(store, alloc);
    defer state.deinit(alloc);
    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |entry| entry.deinit(alloc);
        out.deinit(alloc);
    }
    var it = state.entries.valueIterator();
    while (it.next()) |entry| try out.append(alloc, try cloneEntry(alloc, entry.*));
    std.sort.pdq(Entry, out.items, {}, entryLess);
    return out.toOwnedSlice(alloc);
}

pub fn freeEntries(alloc: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| entry.deinit(alloc);
    alloc.free(entries);
}

pub fn gc(store: *Store, alloc: std.mem.Allocator) !GcReport {
    var state = try scan(store, alloc);
    defer state.deinit(alloc);
    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| entry.deinit(alloc);
        entries.deinit(alloc);
    }
    var it = state.entries.valueIterator();
    while (it.next()) |entry| try entries.append(alloc, try cloneEntry(alloc, entry.*));
    std.sort.pdq(Entry, entries.items, {}, entryLess);
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(alloc);
    for (entries.items) |entry| {
        const line = try formatEntry(alloc, entry);
        defer alloc.free(line);
        try data.appendSlice(alloc, line);
    }
    try store.writeFileAtomic(log_path, data.items);
    return .{
        .kept = entries.items.len,
        .superseded = state.records - state.forgotten - state.corrupt - state.malformed - entries.items.len,
        .forgotten = state.forgotten,
        .corrupt = state.corrupt,
        .malformed = state.malformed,
    };
}

const testing = std.testing;

fn testOid(text: []const u8) Oid {
    return Oid.ofBytes(text);
}

test "fingerprints are canonical across candidate order" {
    const alloc = testing.allocator;
    const a = testOid("a");
    const b = testOid("b");
    const base = testOid("base");
    const first = [_]?Oid{ a, b, null };
    const second = [_]?Oid{ null, b, a };
    const x = try fingerprint(alloc, .{ .base = base, .candidates = &first });
    const y = try fingerprint(alloc, .{ .base = base, .candidates = &second });
    try testing.expect(x.eql(y));
}

test "fingerprints reject non-conflicts and duplicate identities" {
    const alloc = testing.allocator;
    const a = testOid("a");
    const one = [_]?Oid{a};
    const duplicate = [_]?Oid{ a, a };
    try testing.expectError(Error.InvalidConflict, fingerprint(alloc, .{ .base = null, .candidates = &one }));
    try testing.expectError(Error.InvalidConflict, fingerprint(alloc, .{ .base = null, .candidates = &duplicate }));
}

test "record lookup list forget and restore preserve historical evidence" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = testOid("ours");
    const b = testOid("theirs");
    const candidates = [_]?Oid{ a, b };
    const conflict: Conflict = .{ .base = testOid("base"), .candidates = &candidates };
    const evidence: HistoricalEvidence = .{
        .tree = testOid("resolved tree"),
        .tier = .full,
        .command = testOid("zig build check"),
        .inputs = testOid("inputs"),
    };
    const fp = try record(&store, alloc, conflict, .{ .content = "resolved\n" }, evidence);

    var found = (try lookup(&store, alloc, conflict)).?;
    defer found.deinit(alloc);
    try testing.expect(fp.eql(found.fingerprint));
    try testing.expectEqualStrings("resolved\n", found.resolution.content);
    try testing.expect(found.evidence.?.tree.eql(evidence.tree));

    const entries = try list(&store, alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);

    const removed = (try forget(&store, alloc, fp)).?;
    defer removed.deinit(alloc);
    try testing.expect((try lookup(&store, alloc, conflict)) == null);
    try restore(&store, removed);
    var restored = (try lookup(&store, alloc, conflict)).?;
    defer restored.deinit(alloc);
    try testing.expectEqualStrings("resolved\n", restored.resolution.content);
}

test "reuse is symmetric in candidates and exact in base" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();

    const a = testOid("ours");
    const b = testOid("theirs");
    const forward = [_]?Oid{ a, b };
    const reverse = [_]?Oid{ b, a };
    const base = testOid("base");
    _ = try record(&store, alloc, .{ .base = base, .candidates = &forward }, .{ .content = "resolved" }, null);
    var reused = (try lookup(&store, alloc, .{ .base = base, .candidates = &reverse })).?;
    defer reused.deinit(alloc);
    try testing.expectEqualStrings("resolved", reused.resolution.content);
    try testing.expect((try lookup(&store, alloc, .{ .base = testOid("other base"), .candidates = &forward })) == null);
}

test "deleted resolutions round trip" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    const candidates = [_]?Oid{ testOid("ours"), null };
    const conflict: Conflict = .{ .base = testOid("base"), .candidates = &candidates };
    _ = try record(&store, alloc, conflict, .deleted, null);
    const found = (try lookup(&store, alloc, conflict)).?;
    switch (found.resolution) {
        .deleted => {},
        .content => return error.TestUnexpectedResult,
    }
}

test "a corrupt latest record blocks reuse of an older record" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    const candidates = [_]?Oid{ testOid("ours"), testOid("theirs") };
    const conflict: Conflict = .{ .base = testOid("base"), .candidates = &candidates };
    const fp = try record(&store, alloc, conflict, .{ .content = "safe" }, null);
    var fp_hex: [Oid.len * 2]u8 = undefined;
    const bad = try std.fmt.allocPrint(alloc, "F\t{s}\t{s}\n", .{ fp.toHex(&fp_hex), "0" ** 64 });
    defer alloc.free(bad);
    try applog.append(&store, log_path, bad);
    try testing.expectError(Error.CorruptResolutionRecord, lookup(&store, alloc, conflict));
}

test "corrupt stored content is never reapplied" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    const candidates = [_]?Oid{ testOid("ours"), testOid("theirs") };
    const conflict: Conflict = .{ .base = testOid("base"), .candidates = &candidates };
    _ = try record(&store, alloc, conflict, .{ .content = "safe" }, null);
    const entries = try list(&store, alloc);
    defer freeEntries(alloc, entries);
    const blob = entries[0].resolution.content.blob;
    var hex: [Oid.len * 2]u8 = undefined;
    _ = blob.toHex(&hex);
    var path_buf: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "objects/{s}/{s}", .{ hex[0..2], hex[2..] });
    try store.root.writeFile(io, .{ .sub_path = path, .data = "corrupt" });
    try testing.expectError(Error.CorruptResolutionObject, lookup(&store, alloc, conflict));
}

test "gc compacts superseded and forgotten records" {
    const io = testing.io;
    const alloc = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = try Store.init(io, alloc, tmp.dir);
    defer store.deinit();
    const first_candidates = [_]?Oid{ testOid("a"), testOid("b") };
    const second_candidates = [_]?Oid{ testOid("c"), testOid("d") };
    const first: Conflict = .{ .base = null, .candidates = &first_candidates };
    const second: Conflict = .{ .base = null, .candidates = &second_candidates };
    _ = try record(&store, alloc, first, .{ .content = "one" }, null);
    _ = try record(&store, alloc, first, .{ .content = "two" }, null);
    const second_fp = try record(&store, alloc, second, .{ .content = "three" }, null);
    const removed = (try forget(&store, alloc, second_fp)).?;
    defer removed.deinit(alloc);
    const report = try gc(&store, alloc);
    try testing.expectEqual(@as(usize, 1), report.kept);
    try testing.expectEqual(@as(usize, 2), report.superseded);
    try testing.expectEqual(@as(usize, 1), report.forgotten);
    var found = (try lookup(&store, alloc, first)).?;
    defer found.deinit(alloc);
    try testing.expectEqualStrings("two", found.resolution.content);
    try testing.expect((try lookup(&store, alloc, second)) == null);
}
