# 03. Moments

Status: draft. Phase 1, the only foundation. Depends on: nothing.
Blocks: 04, 05, 06, 10.

## Problem

An agent run produces hundreds of file writes and one `gr save`. Everything in
between is invisible. If the agent went down a wrong path at minute three,
recovered at minute nine, and you only notice at minute forty, the intermediate
states are not addressable. You have the start and the end.

`gr watch` gets close. It polls a content signature of the worktree every 800ms
and calls `doSave` when it changes, which means the states do exist as changes.
But they are full saves on the branch: they pollute `gr log`, they each become a
git commit under `sync.git`, and they are named by a change Oid that carries no
information about what caused them. It is described as experimental in the help
text for good reason.

What is missing is a second tier of history: fine grained, cheap, addressable,
and clearly not a commit.

## Why us

The capture loop exists. The content addressed store makes an unchanged file
free to re-snapshot. The op log already models "the repo was in state X, now it
is in state Y". A moment is a small amount of new structure over parts that are
already built and already fast.

The identity design borrows from jj, which gives every change a stable id that
survives rewriting, so you can name your work even as it changes underneath you.
We want the same property one level finer.

## What it is

A moment is a captured worktree state between saves, with a stable short id and
a cause. Moments are what [10](10-verified-states.md) grades, so this is the
foundation everything else stands on.

### Record

Appended to `.gr/moments`, one line per moment, in the same escaped line format
as `provenance` and `attribution`:

```
<moment-id> <tree-oid> <unix_ms> <cause> <branch>\t<agent>\t<session>\t<summary>
```

| Field | Notes |
| --- | --- |
| `moment-id` | 8 bytes hex, see below |
| `tree-oid` | The tree object for the whole worktree at that instant. Not a change. No parent, no author, no message |
| `cause` | `agent-edit`, `human-edit`, `command`, `save`, `manual` |
| `agent`, `session` | Populated when `attribution.zig` can attribute the capture, empty otherwise. Existing machinery, no new integrations |
| `summary` | Short human string, for example `wrote src/merge.zig` or `3 files` |

Storing a tree rather than a change is the key decision. A tree is already what
`workspace.snapshot` builds before it wraps it in a change. Skipping the change
wrapper means moments do not appear in `gr log`, do not have parents to
maintain, do not need author records, and cannot be confused for commits by any
existing code path. It also means a moment costs one tree object plus whatever
blobs actually changed, which for a single file edit is a handful of chunks.

### Stable identity

`moment-id` is the first 8 bytes of
`BLAKE3("gr-moment-v1" || branch || tree_oid || timestamp_ms)`, rendered as 16
hex characters and displayed as the shortest unambiguous prefix, the same way
change Oids are shortened by `shortHex` today.

Stability property: a moment id names a specific captured state on a specific
branch at a specific instant, and never changes. Undo, redo, rebase, and git
export do not rewrite it, because a moment is not part of the change graph. If
the branch is deleted the moments remain until `gr gc` collects their trees.

Moments are referenced with an `@` prefix everywhere, `@a3f91c`, so nothing has
to guess whether an argument is a change or a moment.

### Capture

Three sources, all optional and all configurable:

1. **The signature poll.** `watch.zig`'s existing 800ms loop, redirected to
   record a moment instead of calling `doSave`. This is the primary source and it
   works for every editor, every agent, and every tool, because it watches the
   filesystem and nothing else.
2. **Command boundaries.** Before any mutating `gr` command, capture a moment so
   `gr rewind` (05) always has a pre-command state.
3. **Agent edit events.** `agentscan.zig` already surfaces edits with timestamps,
   so where it happens to know who wrote a file, the moment records it. This is a
   labeling nicety over existing code, not a dependency. Every source above works
   with it switched off, and no feature may require it.

Cadence, retention, and which sources are live are all config:

| Key | Default | Meaning |
| --- | --- | --- |
| `moments.enabled` | `true` | Master switch |
| `moments.interval_ms` | `800` | Poll cadence, shared with the watcher, not a second loop |
| `moments.sources` | `poll,command,agent` | Which triggers are live |
| `moments.retain` | `14d` | Older moments are eligible for `gr gc` |
| `moments.max` | `10000` | Hard cap per branch, oldest dropped first |

Retention is a real requirement, not a nicety. Unbounded fine grained capture on
a large repo is how this feature becomes a disk usage bug report.

### Relationship to saves

Moments are the unit of observation. A save, for as long as saves exist, is the
unit a human chose. When `gr save` runs, the moments since the previous save are
marked as belonging to that change, which is what lets 07 group its recap. They
are not deleted at save time, they age out by retention.

Under 10 the interesting boundary stops being the save and becomes the pair of
moments that bracket a verified-good stretch of work. Moments have to exist first
either way.

`gr watch` is redesignated: it stops auto-saving and starts recording moments,
which is what it should have been doing. The experimental label comes off. This
is a behavior change to an experimental command and should be called out in the
changelog.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr moments` | List moments on the current branch, newest first, with id, age, cause, summary |
| `gr moments --since <when>` | Filter by time |
| `gr moments --between <a> <b>` | Moments between two changes or moments |
| `gr moments --json` | Machine readable |
| `gr log --moments` | Interleave moments into the change log, indented under their change |
| `gr moment -m "<note>"` | Record one by hand, cause `manual` |
| `gr show @<id>` | The tree at a moment, and the diff from the previous moment |

Sample `gr moments` output:

```
@a3f91c   2m ago   agent-edit   wrote src/merge.zig            claude-code
@8b0d27   2m ago   agent-edit   wrote src/merge.zig            claude-code
@41c8ea   5m ago   agent-edit   wrote src/merge.zig, merge_test.zig
@0f77b1   6m ago   command      before: gr switch feature-x
@d2e5a9  11m ago   human-edit   2 files
```

## Out of scope

- Operation level granularity inside a single file write. A moment is a worktree
  state, not a keystroke stream. Character level history is what a CRDT buys and
  what we are deliberately not building.
- Syncing moments to a peer by default. 06 covers deliberate handoff. Ordinary
  `gr send` does not ship moments unless asked, because they are local scratch.
- Moments as branch heads in git export. They are not commits and do not become
  commits.

## Success criteria

1. On an agent run of at least 50 file writes, `gr moments` lists them with
   correct causes, and at least 80 percent carry an agent attribution.
2. Capture overhead is under 5ms per moment on a repo of 10,000 files, measured,
   because the stat cache index means unchanged files are not re-hashed.
3. A moment id resolves to the same tree across process restarts, undo, redo, and
   a git export and re-import cycle.
4. Store growth for a 50 write run is bounded by the sum of changed chunks, not
   by 50 worktree copies, verified by object count.
5. `gr gc` reclaims moment trees past `moments.retain` and nothing reachable.
6. Turning `moments.enabled` off returns behavior and disk usage to current.

## Risks

| Risk | Mitigation |
| --- | --- |
| Battery and IO cost of continuous capture | One loop, not two. Reuse the existing signature poll and the stat cache index. Ship `moments.enabled` and measure on a laptop before defaulting on |
| Disk growth on repos with large generated files | Retention and cap defaults, plus respecting `.grignore` exactly as saves do |
| Users confuse moments with commits | Distinct sigil `@`, distinct command, never in `gr log` without an explicit flag, never exported to git. Trees not changes, so they are structurally incapable of appearing as commits |
| Poll misses a fast edit-then-revert | Accepted. Agent edit events catch most of it because they are event driven, not polled. Documented rather than pretended away |
