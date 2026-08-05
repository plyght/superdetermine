# 05. Rewind

Status: draft. Phase 2. Depends on: 03. Blocks: nothing.

## Problem

`gr undo` reverts the last operation. Operations are saves, imports, and merges.
If an agent has been running for twenty minutes without a save, `gr undo` takes
you back past the entire run, and there is nothing between "where I am" and
"before all of this".

The common failure it does not cover: an agent made 60 edits, the first 40 were
right, and somewhere around edit 41 it went wrong. The user wants edit 40's
state back. Under git the answer is that the state never existed. Under
guardrail today the answer is the same. Moments (03) make those states exist, and
this feature makes them reachable.

## Why us

`gr undo` and `gr redo` already exist and already work at whole-repo scope
through `oplog.zig`, which is more than git offers. Rewind is the same idea at
finer resolution, and the important part is that it inherits the op log's safety
property: rewinding is itself an operation, so it is undoable.

## What it is

```
gr rewind @a3f91c
```

Restores the worktree to the moment's tree. Before touching anything, it
captures the current state as a moment with cause `command`, and records the
rewind in `.gr/oplog` as a new op kind. So:

- `gr undo` after a rewind puts you back where you were.
- The state you rewound away from is still addressable as a moment, so you can
  rewind forward again by id.
- Nothing is destroyed. This is the whole point, and it is what makes rewinding
  something a user will actually reach for rather than fear.

### Interactive selection

```
gr rewind
```

With no argument, prints the recent moments with their causes and summaries and
asks which one. Not a full TUI, a numbered list and a prompt, in the style of
`gr resolve`.

```
gr green
```

Rewinds to the most recent moment with a green verdict. Under [10](10-verified-states.md)
this is a lookup, not a search: states are graded continuously in the background,
so the answer is already known and rewinding to it costs one hash lookup and a
tree materialization.

Where a stretch of moments is ungraded, for instance because grading was off or
the machine was on battery, it falls back to walking backwards and grading on
demand, bounded by `--max 20`, reporting what it ran and how far it went.

This is the single most useful shape of the feature for agent work, because the
question is rarely "which moment" and almost always "the last one that built".
`gr green`, `gr rewind @green`, and `gr at @green` all resolve the same state.

### Scoped rewind

```
gr rewind @a3f91c -- src/merge.zig
```

Restores only the given paths from that moment, leaving everything else alone.
This is the surgical case: the agent's work was mostly good, one file went bad.

### Safety

| Situation | Behavior |
| --- | --- |
| Uncommitted changes present | Captured as a moment first, always. Never silently discarded |
| Rewinding across a branch switch | Refused. Moments are per branch and the id carries the branch. Explicit error naming the branch |
| Moment's tree missing from the store, garbage collected | Explicit error with the retention setting that caused it |
| Rewind while `gr watch` is running | Watcher suppresses capture during the rewind and records one moment after, so a rewind does not generate a storm |

## Addressing: one grammar, no quoted strings

An earlier draft of this used `gr rewind last-green`, with `--to-last-good` as an
alternative spelling. That is bad UX: a bare word that looks like a branch name,
a long flag that means the same thing, and no consistency with anything else.

The `@` sigil already means "a moment". Extend it into one small revspec grammar
that works everywhere a revision is accepted, so there is exactly one thing to
learn:

| Ref | Means |
| --- | --- |
| `@` | The current state |
| `@green` | The newest green moment |
| `@red` | The newest red moment |
| `@green~1` | The green moment before that one. `~n` walks back in any selector |
| `@~3` | Three moments back |
| `@2h`, `@30m`, `@yesterday` | By time |
| `@a3f91c` | By id |
| `@save` | The last explicit save |

It composes with every command that takes a revision, which is the point:

```
gr diff @green            # what have I done since it worked
gr rewind @green          # put it back
gr work ../try-b --at @green~2
gr recap @green..@        # what happened since
gr show @2h
```

Two verbs exist for the operations frequent enough to deserve one, because
nobody should type a revspec to do the most common thing:

```
gr back        # rewind one moment. gr back 3 for three
gr green       # rewind to the last green state
```

`gr green` with no arguments is the "undo the last 40 minutes of agent damage"
button, and it should be short enough to type without thinking.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr green` | Rewind to the newest green state. The common case, one word |
| `gr back [n]` | Rewind n moments, default 1 |
| `gr rewind <ref>` | Restore the worktree to any revspec above |
| `gr rewind` | Interactive picker over recent moments |
| `gr rewind <ref> -- <paths>` | Restore only those paths |
| `gr rewind --dry-run` | Show the diff that would be applied, change nothing |
| `gr undo` | Already exists, now also undoes a rewind |

The revspec grammar is specified here because rewind is where it is felt most,
but it belongs to the whole tool. `gr diff`, `gr show`, `gr work --at`,
`gr recap`, and `gr new` all take it.

## Out of scope

- Rewinding verdicts. A verdict is a fact about a tree hash and stays true
  forever. Rewinding to a green state does not re-run anything, because the
  memo in 10 already holds the answer.
- Automatic rewind on a failing check. Deciding to throw away work is a human
  decision, and an automatic version of this would be a very effective way to
  lose work.
- Rewinding another workspace from this one. Each workspace rewinds itself.

## Success criteria

1. Rewinding to a moment reproduces that worktree byte for byte, verified by
   comparing a fresh content signature against the moment's tree.
2. `gr undo` immediately after a rewind restores the pre-rewind state exactly.
3. `--dry-run` output equals the diff actually applied without it.
4. `gr green` on a run with a known breaking edit finds the last building moment,
   tested against a seeded repo.
7. Every revspec form resolves identically across `rewind`, `diff`, `show`,
   `work --at`, and `recap`, verified by a table-driven test. One grammar means
   one implementation
5. Rewinding with uncommitted changes never loses them, verified by finding them
   in `gr moments` afterwards.
6. A scoped rewind touches only the named paths, verified by mtimes and status.

## Risks

| Risk | Mitigation |
| --- | --- |
| A user rewinds and loses work they had not saved | Structurally prevented. Pre-rewind capture is unconditional and happens before any write |
| `gr green` has to grade on demand and takes minutes | Only in the ungraded fallback. Bounded by `--max`, prints progress per attempt, ctrl-c safe. With 10 running normally this path is never taken |
| Rewind and the running agent fight over the worktree | Warn loudly when an agent session has written within the last few seconds. This is a user coordination problem and the honest answer is to tell them, not to lock |
| Path scoped rewind leaves the tree in a state that does not build | That is inherent to the operation and is what `--dry-run` is for |
