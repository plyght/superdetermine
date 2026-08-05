# 11. Superposition

Status: draft. Phase 4, gated on 10. Depends on: 03, 04, 10. Blocks: nothing.

## Problem

A conflict stops everything. `gr merge` writes conflict markers into the
worktree and the tree is now un-buildable, un-testable, and un-runnable until a
human sits down and resolves it. Conflict markers are syntactically invalid in
every language, which means a conflicted tree cannot be compiled, cannot be
graded by 10, and cannot be handed to an agent.

That was tolerable when merges were rare and deliberate. It is not tolerable when
04 makes forking free and a developer routinely has three agents working three
approaches to the same subsystem. Under that workload a conflict is not an event,
it is the steady state, and a design where the steady state halts the tool is the
wrong design.

## What already exists, honestly

"Conflicts as first-class repository state" is **not new** and this PRD should not
claim it is.

- **Pijul** extends its set of files to include files in a conflicted state, so a
  conflict is a legitimate value the repository can hold rather than a failure.
  Internally these are DAGs of lines rather than ordered lists.
- **Jujutsu** records conflicts inside commits, as an ordered list of tree objects,
  and lets you commit a conflict and resolve it later. It explicitly credits Darcs
  and Pijul for the idea.
- **CRDT systems**, including DeltaDB, converge automatically to a single value
  with no conflict at all, at the cost of that value sometimes being text no
  human would have written.

So three families have already established that a conflict can be a state rather
than an error. What none of them do is the part this PRD is actually about.

In Pijul and in jj, the conflicted value is still **one thing in a broken state**.
Pijul renders conflicted files into the working directory with conflict markings.
jj commits a representation of the conflict rather than markers, which is a real
improvement, but materializing it into a working copy still produces something a
human has to fix before the tree is usable. And in every one of them, deciding
which side wins is a judgment a human makes with no evidence beyond reading both.

Two things are new here, and they are narrow:

1. **Every candidate is a complete, individually valid file.** Not a merged
   artifact with markers, not a DAG rendered into a broken text file. The worktree
   always holds exactly one coherent version of every path, so it always builds,
   always tests, and can always be handed to an agent. Work does not stop.
2. **Candidates carry verdicts.** Because 10 grades arbitrary trees in the
   background using COW clones and a content-addressed memo, gr can grade the
   worktree with candidate A primary and again with candidate B primary, and tell
   you which of the two actually passes. Collapse becomes a decision with
   evidence attached rather than a coin flip between two diffs.

Nobody else can do the second one, not because it is clever, but because it needs
continuous background verification and millisecond worktree materialization
sitting in the same system, and no other VCS has both.

## Design

### Superposition sits on top of merge, not instead of it

This is the most important structural decision and the easiest to get wrong.

`src/merge.zig` already does a real three-way merge. That stays, unchanged, and
runs first. Most merges succeed at line granularity and produce one value, and
those never superpose. **Superposition replaces conflict markers, not merging.**

Only when three-way merge fails for a path does that path enter superposition,
holding the two whole-file candidates that the merge could not reconcile.

Doing this at path granularity is coarser than git's line-level merge, and that
is a deliberate trade rather than an oversight. A candidate has to be a file
someone actually wrote, because the entire value of the model is that every
candidate is independently valid and gradeable. A machine-blended file with two
authors' logic interleaved is neither.

### The worktree holds one value per path

The primary. Chosen by policy, recorded, and never silent:

| `merge.primary` | Behavior |
| --- | --- |
| `ours` | Default. Predictable, matches the mental model of "my tree kept working" |
| `theirs` | The incoming side |
| `greenest` | The candidate with the strongest verdict from 10, falling back to `ours` on a tie or when ungraded |
| `newest` | Most recently authored |

`greenest` is the interesting one and it is deliberately not the default. Making
evidence the automatic tiebreak on day one would train people to trust a signal
before it has earned it.

The chosen primary is recorded as a fact, so "why is this file the way it is"
has an answer later.

### The tree always builds

The property everything else depends on. No conflict markers are ever written to
disk. A repository with fifty superposed paths still compiles, still runs, still
grades, and can still be handed to an agent, because on disk it is just files.

This is what makes conflicts non-blocking in a way that committing a conflict
does not achieve on its own. You can merge, keep working, and collapse next
Tuesday.

### Candidates are visible, loudly

Silent divergence would be the way this feature hurts someone.

```
gr status

  3 paths in superposition
    src/merge.zig       2 candidates   primary: ours
    src/workspace.zig   2 candidates   primary: ours
    src/git.zig         3 candidates   primary: ours  (2 stale)
```

`gr status` always reports superposition, it is never behind a flag, and the
count appears in the same place every time so its absence is meaningful.

```
gr super src/merge.zig

  A  ours    @a3f91c  you            green  full  independent  discriminating
  B  theirs  @8b0d27  claude-code    red    full  build failed
```

### Grading candidates

For a superposed path, gr materializes a COW clone with each candidate as primary
and grades it under 10. Because verdicts are memoized by tree hash, a candidate
already seen in another context is free.

This is the synthesis. A conflict stops being "read both diffs and guess" and
becomes "A passes and is independently tested, B does not build." The decision is
still yours, but it is informed.

Cost control: candidate grading is on demand or at idle, never at every quiet
point, and never for more than `merge.grade_max` candidates per path, default 4.

### Collapse

```
gr collapse src/merge.zig A
gr collapse --greenest
gr collapse --all --greenest
```

Collapse records a fact selecting one candidate and removing the superposition.
It is an operation in the op log, so `gr undo` restores it. Collapsing does not
delete the losing candidate's blob, so the alternative stays addressable and a
collapse can be revisited.

Collapse can also be a genuine merge: `gr collapse src/merge.zig --edit` opens the
file, and whatever you write becomes the collapsed value. That is the escape
hatch for the case where the right answer is neither candidate, which is common
and must not be awkward.

### Staleness

An alternative candidate is **frozen at its content**. If you keep editing the
primary, the alternative does not follow.

That is a deliberate refusal. Continuously rebasing an alternative onto a moving
primary is the CRDT problem wearing a different hat, and doing it badly is worse
than not doing it. What gr does instead is report the drift honestly:

```
B  theirs  @8b0d27  stale: primary has moved 12 moments since this candidate
```

A stale candidate is still valid and still collapsible. It is just old, and the
user is told so rather than being allowed to assume otherwise.

### More than two candidates

Falls out with no extra machinery. Three forks from 04, three attempts at the
same file, three candidates, each gradeable. This is the workflow superposition
is actually for: fan out agents on one problem, let them all finish, and collapse
to whichever one demonstrably works.

### Git interop requires collapse

Git has no representation for a path with two values, so the boundary is hard and
explicit:

```
gr git export ../out
  error: 3 paths in superposition, git cannot represent this
    src/merge.zig, src/workspace.zig, src/git.zig
  collapse them first, or: gr git export ../out --collapse=greenest
```

Export refuses by default rather than silently picking. `--collapse=greenest` is
available for the user who has decided they trust it, and it records what it did.

This keeps guardrail's promise that adopting it is reversible. A superposed repo
is always one command away from a normal git repo.

### Storage

A candidate is a blob that is already in the store, because it came from a tree
that is already in the store. The only new data is a small table in
`.gr/superposition`, one line per superposed path per candidate, in the same
append-only escaped format as the rest of the sidecars. The cost is effectively
zero.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr merge <branch>` | Unchanged, except conflicts superpose instead of writing markers |
| `gr status` | Always reports superposed paths and their primary |
| `gr super` | List all superposed paths |
| `gr super <path>` | Candidates for a path with verdicts |
| `gr diff --candidates <path>` | Diff the candidates against each other |
| `gr use <path> <id>` | Change the primary without collapsing |
| `gr collapse <path> <id>` | Collapse to a candidate |
| `gr collapse <path> --edit` | Collapse to hand-written content |
| `gr collapse --all --greenest` | Collapse everything by evidence |
| `gr undo` | Existing, now also undoes a collapse |

`gr resolve`, which exists today, becomes an alias for the interactive collapse
flow so nothing a user already knows breaks.

## Out of scope

- Line-level or character-level merging beyond what `merge.zig` already does.
  That is a CRDT and it is a different system, per the plan's standing non-goal.
- Automatically collapsing without being asked. `greenest` is opt in, per command
  or per config, and always reports what it chose.
- Rebasing alternatives onto a moving primary. See staleness.
- Superposition of anything other than file content. Not directory structure, not
  renames, not modes. Those conflict rarely and the complexity is not repaid.
- Propagating a collapse decision to future merges, the way Pijul's
  resolve-once-and-for-all works and `git rerere` approximates. Genuinely useful,
  meaningfully harder, and a follow-up rather than v1.

## Success criteria

1. A merge that conflicts on three paths leaves a worktree that compiles and
   passes the check for the primary side, with no markers on disk.
2. `gr super <path>` reports a verdict for each candidate, and the verdicts are
   correct against a seeded repo where one side is known broken.
3. Collapsing and then `gr undo` returns to the superposed state exactly.
4. `gr git export` refuses while any path is superposed, and succeeds after
   collapse, producing a repo byte-identical to a conventionally merged one.
5. Grading N candidates costs at most N check runs, and zero when the candidate
   trees have been graded before, verified by the memo hit counter.
6. `gr status` never omits a superposed path.
7. A repository carried through merge, superposition, collapse, export, and
   re-import is identical to one that took the conventional path.

## Risks

| Risk | Mitigation |
| --- | --- |
| Someone ships the wrong side without noticing | Never silent. `gr status` always reports it, export refuses by default, and the primary choice is a recorded fact. This is the failure mode that would discredit the feature and it gets the most defense |
| Superpositions accumulate until the repo is incomprehensible | A cap via `merge.max_superposed`, default 50, above which `gr merge` refuses and says so. Plus `gr status` nagging, which is the point of it always being visible |
| `greenest` is read as "correct" | It is evidence, not a verdict on design, and the wording says so everywhere it appears. It is not the default precisely so that it has to be chosen deliberately |
| Both candidates build and pass, and the conflict is semantic | Grading cannot catch this and must not pretend to. Report both green and let the human decide, which is exactly where every other VCS starts anyway. We are strictly better off, not omniscient |
| Path granularity loses work when both sides changed different parts of a file | Three-way merge runs first and handles that case, so superposition only sees what genuinely could not be reconciled. Where a user wants a blend, `--edit` is one command |
| Grading candidates doubles the check load during a merge | On demand or at idle only, capped per path, and memoized. A merge does not trigger a grading storm |
| The feature is novel-sounding but nobody needs it | Honest risk. It is gated behind 04 and 10 landing and being used, and if parallel agent forks do not become a real workflow, this should not be built |

## Sources

- [Pijul model](https://pijul.org/model/) and [manual](https://pijul.org/manual/why_pijul.html), for conflicts as repository state
- [Jujutsu conflicts, technical docs](https://docs.jj-vcs.dev/latest/technical/conflicts/), for committed conflicts and the Darcs and Pijul lineage
- [Jujutsu git comparison](https://docs.jj-vcs.dev/latest/git-comparison/)
