# 12. Freshness

Status: draft. Phase 3. Depends on: 03. Better with: 11. Blocks: nothing.

## Problem

You start working without pulling. Or an agent does, because it was told to pull
first and did not, or pulled at the start of a run that then went on for forty
minutes while the remote moved underneath it.

By the time anyone notices, the work is built on a stale base. The good case is a
merge. The bad case is an agent that spent thirty minutes reimplementing
something a teammate already pushed, or rewriting a file around an API that
changed.

Putting "pull first" in an agent's instructions does not fix it, because
instructions are advisory and the failure is silent. Nothing tells you the base
moved.

## Constraint

No daemon. A background process that polls a remote is a thing to install,
supervise, debug, and explain, and it is a poor trade for a check that takes one
round trip.

## What it is

Two mechanisms. The first makes staleness visible for free; the second acts on
it, and is only safe because of 11.

### 1. Every moment records the base it was taken against

A moment (03) already stores a tree, a timestamp, and a cause. It also records
the remote ref values known at capture time. That is a handful of bytes.

Now staleness is a property of a state rather than an event someone has to
notice. `gr status`, `gr recap`, and `gr log` can all say "this work is built on
a base that is 14 commits behind" without anything having polled anything,
because the comparison is against whatever the last known remote value is.

This alone fixes the silent part of the problem. The work carries its own
staleness.

### 2. `gr` freshens itself, amortized across the commands you already run

Every `gr` invocation is already a process doing IO. If the last remote check is
older than `remote.freshen_ms`, default 60 seconds, the command fires a
**refs-only** fetch concurrently with its real work.

Refs-only matters. It is one round trip and a few hundred bytes; it does not
fetch objects. On a typical connection it completes well inside the time a
command spends on its own work, so it adds no measurable latency. The result
lands in `.gr/remotes/<name>/refs` with a timestamp, and is used by *this*
command if it arrives in time and by the next one if it does not.

No daemon, no hooks to install, no shell integration. The freshness check rides
along with whatever the user or the agent was doing anyway.

Coverage is the honest question: this only fires when someone runs a `gr`
command. In practice an agent session runs many, and a human runs `gr status`
constantly. For the case where genuinely nothing runs, mechanism 1 still catches
it the moment anything does, and the staleness is attached to the moments in
between so the record is accurate after the fact.

### 3. Pulling automatically, which is only safe here

```
remote.autopull = off | ff | always
```

| Value | Behavior |
| --- | --- |
| `off` | Default. Report staleness, change nothing |
| `ff` | Pull when it is a fast-forward and the worktree has no conflicting edits |
| `always` | Pull whenever the remote has moved |

`always` is the interesting one and it is a thing git cannot safely offer.

In git, an automatic pull that conflicts leaves conflict markers in your files.
Your tree stops building, your agent starts editing a file full of `<<<<<<<`,
and the automation has actively made things worse. That is why nobody ships
autopull.

Under superposition (11), a conflicting pull **cannot** do that. Three-way merge
runs first and handles what it can; whatever it cannot reconcile becomes
candidates on those paths, the worktree keeps one complete valid file per path,
and the tree still compiles, still grades, and can still be handed to an agent.
The conflict becomes a labelled state to resolve later rather than an emergency
that halts work.

So the ordering is: `always` requires `merge.superpose` to be on, and gr refuses
the combination `remote.autopull = always` with `merge.superpose = false` rather
than quietly doing something dangerous.

`ff` is available without superposition, because a fast-forward cannot conflict
by definition.

### What the user sees

```
gr status

  base: 14 behind origin/main, last checked 8s ago
    → gr pull, or set remote.autopull
```

And with autopull on, after it acts:

```
  pulled 14 from origin/main
  2 paths in superposition   src/merge.zig, src/git.zig
```

Never silent. An automatic pull is an operation in the op log, so `gr undo`
reverses it completely, which is the property that makes it acceptable to do
without asking.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr status` | Reports base staleness and when it was last checked |
| `gr fresh` | Force a refs-only check now |
| `gr config remote.freshen_ms <n>` | Cadence, or 0 to disable |
| `gr config remote.autopull <off\|ff\|always>` | What to do about it |
| `gr undo` | Existing, now also undoes an automatic pull |

## Out of scope

- A background daemon or a scheduled poller. Explicitly ruled out.
- Installing git hooks or shell prompt integration. Install burden for something
  that should be free.
- Fetching objects speculatively. Refs only. Prefetching a large repo's objects
  on a timer is exactly the kind of surprise bandwidth use that gets a tool
  uninstalled.
- Pulling in a repo with no configured remote, or with more than one, without an
  explicit choice. Ambiguity means report and stop.

## Success criteria

1. A refs-only check adds under 20ms of measurable latency to `gr status` on a
   normal connection, and zero when it is served from cache.
2. With the network unreachable, every command behaves exactly as it does today,
   with no hang and no error, reporting only that freshness is unknown.
3. Staleness recorded on a moment is correct after the fact, verified on a run
   where the remote moved mid-session.
4. `remote.autopull = always` with a conflicting remote change leaves a worktree
   that still compiles and still grades green or red for real reasons, never
   because of markers.
5. `gr undo` after an automatic pull restores the exact prior state.
6. `remote.freshen_ms = 0` returns behavior and network traffic to today's.

## Risks

| Risk | Mitigation |
| --- | --- |
| Unexpected network traffic from a tool that used to be offline | Refs only, rate limited by `remote.freshen_ms`, disabled with one key, and stated plainly in the docs. Never fetches objects |
| An automatic pull surprises someone mid-task | It is an op log entry, so `gr undo` is complete and one word. `ff` is the safe default to recommend, and `off` is the actual default |
| A slow or hanging remote blocks a command | The fetch is concurrent and non-blocking, with a hard timeout. A command never waits on it, and a late result is simply used next time |
| Autopull plus superposition accumulates candidates silently | `gr status` always reports superposed paths, and 11's cap applies. Above the cap, autopull stops and says why |
| Credentials prompt during a background freshen | Never prompt from a freshen. If the remote needs interactive auth, mark freshness unknown and move on |
