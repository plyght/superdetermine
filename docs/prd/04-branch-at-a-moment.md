# 04. Branch at a moment

Status: draft. Phase 3. Depends on: 03. Blocks: nothing.

## Problem

Right now a branch point has to be a change. If an agent is 40 minutes into a
run and you want to try the other approach it considered at minute 12, your
options are to wait for it to finish, or to interrupt it and lose the run.

The specific situation this is for: an agent is working, you are watching, and
you see it commit to an approach you are not sure about. You want to fork the
world at that instant, put a second agent on the alternative, and compare. Under
git that requires a commit that does not exist. Under guardrail, `gr work`
already makes the worktree part nearly free, but there is still nothing to
branch from.

## Why us

Two thirds of this is already built.

`gr work <dir>` creates a copy-on-write workspace using APFS clonefile or Linux
reflink, in milliseconds. The store is content addressed, so a second workspace
at a nearby state shares every unchanged chunk. Moments (03) supply the missing
third: a nameable, materializable state at any instant, including mid-run.

DeltaDB gets this from worktree virtualization, which is a heavier mechanism
that also buys them mounting and real time sync. We get the same user facing
capability from cheap COW plus content addressing, without a virtual filesystem.

## What it is

Extend every place that takes a starting point to also take a moment reference.

### Branch from a moment

```
gr new fix-the-other-way @a3f91c
```

Creates a branch whose first change is a snapshot of the moment's tree. The
moment stays a moment. The branch records its origin moment id in
`.gr/refs/origins/<branch>` so `gr log` and `gr recap` (07) can say where it came
from.

The moment's tree becomes a real change here, because a branch head must be a
change for merge, export, and push to work. That is the one place a moment gets
promoted, and it is explicit and user initiated.

### Workspace at a moment

```
gr work ../try-b --at @a3f91c
```

Materializes a COW workspace at that state without creating a branch. This is
the mid-run case: the primary worktree keeps going, and the fork is a directory
you can point a second agent at. No branch bookkeeping until you decide the fork
was worth keeping.

### Fork the run, not just the tree

```
gr work ../try-b --at @a3f91c --with-conversation
```

Additionally writes the conversation up to that moment's message id (01) into
the new workspace as `.gr/session-context.md`, so the second agent can be started
with the same context the first one had at that instant. This is the piece that
makes it a fork of the *work* rather than a fork of the *files*, and it is the
part that is hard for anyone who does not store conversations.

Explicitly not: resuming the agent's own internal session state. We cannot do
that and should not claim to. We hand the new agent a transcript, which is what a
human would do.

### Compare forks

```
gr diff @a3f91c ../try-b
gr diff ../try-a ../try-b
```

Diff learns to take moments and workspace paths as endpoints, so comparing two
parallel agent attempts is one command instead of a manual dance.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr new <name> @<moment>` | Branch from a moment |
| `gr work <dir> --at @<moment>` | COW workspace at a moment, no branch |
| `gr work <dir> --at @<moment> --with-conversation` | Same, plus transcript context |
| `gr diff @<a> @<b>` | Diff two moments |
| `gr diff <workspace> <workspace>` | Diff two workspaces |
| `gr branch --origins` | Show which moment each branch forked from |

Moment references are accepted anywhere a change reference is, with the `@`
sigil disambiguating. `gr restore`, `gr revert`, and `gr merge` all take them.

## Out of scope

- A virtual filesystem or FUSE mount. COW copies are fast enough and do not
  require a kernel module or a daemon.
- Automatically running a second agent. We create the workspace and the context
  file. Launching the agent is the user's business, and every agent has a
  different invocation.
- Merging two forks automatically. `gr merge` already exists and already does
  three way merge with `gr resolve`. Forks merge like anything else.

## Success criteria

1. `gr work ../x --at @<moment>` completes in under 200ms on a repo of 10,000
   files on APFS and on a reflink capable Linux filesystem.
2. Disk usage of a second workspace at a nearby moment is within a few percent of
   the changed bytes, verified with `du`, not the size of the tree.
3. Branching from a moment mid-run does not disturb the running agent's worktree,
   verified by running an agent and forking under it.
4. `--with-conversation` produces a transcript that a fresh agent can be started
   from, tested by hand with at least two different agents.
5. A branch created from a moment exports to git cleanly and round trips.

## Risks

| Risk | Mitigation |
| --- | --- |
| Filesystem does not support reflink or clonefile | `gr work` already handles this. Fall back to a plain copy and say so, as it does today |
| Forking mid-run races the agent writing files | The moment's tree is already in the store, so materialization reads from the store and never from the live worktree. No race by construction |
| Moment aged out by retention before someone branches from it | `gr new` from a moment pins it, and the retention sweep skips pinned moments. Also warn when branching from a moment near expiry |
| Users expect the forked agent to remember | Documentation is explicit that this is a transcript handoff, not session resumption. The command name says `--with-conversation`, not `--resume` |
