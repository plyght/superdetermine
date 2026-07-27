# guardrail (`gr`)

A fast, independent version control system. Content-addressed storage with sub-file dedup, whole-repo undo, and instant copy-on-write worktrees. It runs beside git and pushes to GitHub, so you can adopt it gradually without giving anything up.

## Why

git is excellent, but much of its friction is incidental: a staging area to manage, stashing just to switch branches, resets that feel dangerous, whole-file handling for binaries, and heavyweight worktrees. guardrail keeps a familiar flow and removes that friction while staying compatible with the git world you already use.

## Features

| Feature | What it gives you |
| --- | --- |
| Content-addressed store (BLAKE3 + FastCDC) | Large files and binaries are first-class, deduped at the chunk level. No LFS. |
| Working copy is always a change | No staging, no stash. Edit, then `gr save`. |
| Operation log | `gr undo` and `gr redo` across the whole repo. Nothing gets lost. |
| Instant copy-on-write worktrees | `gr work <dir>` spins up a workspace in milliseconds (APFS clonefile, Linux reflink). |
| Stat-cache index | `status` and `save` skip re-hashing unchanged files (mtime/size/inode). |
| Three-way merge + resolve | Conflict markers, then `gr resolve <file>` / `gr resolve --abort`. |
| Absorb | `gr absorb` folds working edits into the changes they belong to. |
| Garbage collection | `gr gc` reclaims space from unreachable objects (`--dry-run` to preview). |
| Prompt provenance (opt-in) | Record which agent or prompt produced a change, stored in the repo. |
| Per-line blame | `gr blame <file>` shows per-line authorship, including agent/prompt. |
| Scriptable output | `gr status --json` and `gr log --json`; `gr completions <fish\|zsh\|bash>`. |
| Bidirectional git interop | Import and export full history, branches, and tags. Push and pull to GitHub. |
| Git LFS interop | Pointers resolve to real content on import and clean back to pointers on export, sharing `.git/lfs/objects` with git-lfs. |
| Sparse fetch and serve | Pull only the paths you need. A peer is just an object store, no forced server. |

## Git, side by side

guardrail does not replace git or GitHub, and adopting it is reversible. It sits next to your `.git`, and you decide how far to lean in:

- Keep committing and pushing with git as usual. guardrail imports and exports full history losslessly, so you are never locked in.
- Or enable dual-write (`gr config --global sync.git true`) and every `gr save` also lands a normal git commit, so your team, GitHub, and CI keep working while you drive with gr.
- Run `gr export <dir>` to materialize a plain git repo at any time.

If gr turns out not to be for you, your git history is right there, untouched.

## Quick start

```
gr init
gr save -m "message"      # snapshot the working tree (no add, no stash)
gr status | gr diff | gr log
gr new feature            # branch and switch
gr work ../agent-copy     # instant worktree
gr undo   /   gr redo
gr blame file.txt         # per-line authorship + provenance
gr absorb                 # fold edits into the changes they belong to
gr gc                     # reclaim unreachable objects
```

Working with git:

```
gr clone <git-url> <dir>
gr import <git-repo>   /   gr export <git-repo>
gr push [remote] [branch]     # uses your existing git credentials
```

Large files (Git LFS):

```
gr lfs track "*.psd"      # matching files export to git as LFS pointers
gr lfs ls | gr lfs status # what is tracked, and what is cached locally
gr lfs fetch | gr lfs push
gr lfs env                # endpoint, cache location, settings
```

On import, gr resolves LFS pointers to the real bytes (from `.git/lfs/objects`, else the LFS batch API) and stores them chunked in its own object database, so `gr diff`, `gr blame` and `gr work` all see real files. On export and push it writes the pointers back and uploads any objects the remote is missing. Set `gr config lfs.smudge false` to keep pointers verbatim instead, `lfs.url` to override the endpoint, and `lfs.upload false` to skip uploads.

## Install

Grab a binary from [Releases](https://github.com/plyght/guardrail/releases), or update in place:

```
gr update             # latest stable
gr update --nightly   # latest nightly build
```

Binaries are statically linked, so no system libgit2 is required.

## Build from source

Requires Zig 0.16.

```
zig build           # produces zig-out/bin/gr
zig build test
```

## Status

Early and opinionated. Interfaces may still change.
