# Zig 0.16 API notes (guardrail)

Zig 0.16 reworked std heavily. Use these exact idioms — older tutorials are wrong.

## Entry point & IO
- `main` signature: `pub fn main(init: std.process.Init) !void`.
  - `init.gpa` → general-purpose `std.mem.Allocator` (leak-checked in Debug).
  - `init.io` → `std.Io` value threaded through ALL filesystem calls.
  - `init.minimal.args` → args; iterate with `var it = init.minimal.args.iterate(); defer it.deinit(); while (it.next()) |a| {...}` (a is `[:0]const u8`).
- Stdout: `var w = std.Io.File.stdout().writer(init.io, &buf); const out = &w.interface;` then `out.writeAll(...)`, `out.print(fmt, args)`, and finally `out.flush()`.
- Writer type is `*std.Io.Writer`. Custom `format` methods take `(self, writer: *std.Io.Writer) !void`.

## Filesystem — everything is on `std.Io.Dir` / `std.Io.File`, and takes `io`
- `const cwd = std.Io.Dir.cwd();`
- `dir.createDirPath(io, "a/b/c")` = `mkdir -p` (no permissions arg).
- `dir.createDir(io, sub, permissions)` — errors `error.PathAlreadyExists`.
- `dir.access(io, sub, .{})` — returns error if missing (use for existence checks).
- `dir.createFile(io, sub, .{})` / `dir.openFile(io, sub, .{})` → `std.Io.File`.
- `dir.writeFile(io, .{ .sub_path = p, .data = bytes })` — write whole file.
- `dir.readFileAlloc(io, sub, gpa, limit)` where limit is `std.Io.Limit` (e.g. `.limited(n)` or `.unlimited`). Caller frees.
- `dir.deleteTree(io, sub)`, `dir.deleteFile(io, sub)`.
- `dir.openDir(io, sub, .{})`, close with `d.close(io)`.
- File read/write streaming: `file.reader(io, &buf)` / `file.writer(io, &buf)`, use `.interface`.

## ArrayList is unmanaged; allocator passed per-call
- `var list: std.ArrayList(T) = .empty;`
- `try list.append(alloc, x);` `try list.appendSlice(alloc, s);`
- `list.deinit(alloc);` `try list.toOwnedSlice(alloc);`
- Same pattern for `std.ArrayHashMap` / `std.HashMap` unmanaged variants.

## Allocator
- `std.heap.GeneralPurposeAllocator` → renamed `std.heap.DebugAllocator(.{})`. Prefer `init.gpa`.

## Naming gotchas
- Method names cannot shadow primitives: no `fn u32(...)`. Use `putU32`/`takeU32` etc.
- `std.mem.writeInt(u32, &buf, v, .big)` / `std.mem.readInt(u32, buf[0..4], .big)`.

## Hashing
- `std.crypto.hash.Blake3` — `Blake3.hash(data, &out, .{})` one-shot, or `.init(.{})/.update/.final(&out)`. 32-byte digest.

## Build (build.zig)
- Linking is on the Module, not the Compile step:
  - `const mod = b.createModule(.{ .root_source_file=..., .target=, .optimize=, .link_libc = true });`
  - `mod.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });` `mod.addLibraryPath(...)`; `mod.linkSystemLibrary("git2", .{});`
  - `b.addExecutable(.{ .name=, .root_module = mod });`

## libgit2 via @cImport
- `const c = @cImport({ @cInclude("git2.h"); });` works given the include path above. `c.git_libgit2_init()`, etc.
