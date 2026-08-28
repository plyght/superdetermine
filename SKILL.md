---
name: superdetermine
description: Drive the superdetermine VCS (`sdt`, alias `gr`) for history surgery — selective commits, amending earlier changes, reordering, squashing, splitting, and updating a dirty branch onto a moved target. Use whenever the repo has a `.sdt` directory or the user says sdt, superdetermine, or guardrail.
---

# superdetermine (`sdt`)

## Mental model — read this first

1. **No staging area.** `sdt save` snapshots the *entire* working tree. It takes no path arguments. There is no `add`, no `-p`, no partial staging.
2. **No stash.** You never need one, and you can never leave one behind.
3. **The tree is captured continuously as *moments*.** A moment is not a change and never shows in `sdt log`. Capture is a poll (default 800ms), so a fast sequence of edits can fall between two moments — moments are a safety net, not a guarantee.
4. **States are addressed by describing them.** `@green` `@2h` `@yesterday` `<change-hex-prefix>` `<branch>` `<branch>~n`. See *Revspecs that actually resolve* — several forms people assume work do not.
5. **`sdt undo` reverses history operations**, not worktree destruction. It does not restore edits that a command discarded (see *Commands that destroy uncommitted work*).
6. **`sdt rewind <ref> [-- <paths>]` changes only the worktree.** It never moves a branch. It is your file-level time machine.

### The one core move: shape the tree, then save

Because `save` takes the whole tree, **the working tree *is* the selection UI**. To commit exactly X:

1. Make the tree hold exactly X.
2. `sdt save -m "..."`.
3. Put back whatever you moved out of the way.

**Parking rule:** anything that must not enter the commit gets parked **outside the worktree** (`$(mktemp -d)`), never inside it — an untracked file inside the tree *would* be scooped into the save. Park untracked files with `mv` (a `cp` leaves the original in the tree and it will be committed).

---

## Working in a repo that also has `.git`

The colocated `.git` is not kept in step for you. Get this right first or nothing else counts.

### 1. At setup, hide `.sdt` from git

```sh
printf '.sdt/\n' >> .git/info/exclude
```

Without this, `git status` reports `?? .sdt/` forever and anything that requires a clean worktree fails. `sdt init` does not do this itself.

### 2. Import the existing git history before you touch anything

```sh
sdt init            # only if there is no .sdt yet
sdt import .        # full history, all branches and tags, preserving git commit ids
```

`sdt import .` is also how you pick up git-side movement later: if someone else advances `main` while you work, re-run `sdt import .` or sdt's `main` stays at the old tip.

### 3. Publish to git at the end, in this order

```sh
sdt export . --force     # writes EVERY sdt branch to refs/heads/*, replacing what git had
sdt sync . --force       # resets git's index to the new HEAD
```

- **`sdt export . --force` is the only thing that makes an sdt-side rewrite visible to git.** Reorder, squash, split, rebase and point all happen purely in `.sdt`; `git log` shows the *old* history until you export.
- **`sdt sync <dir>` picks the branch from git's HEAD, not from sdt's HEAD.** If sdt is on `feature` and git's HEAD is on `main`, a sync writes sdt's chain onto **`main`** — which on any benchmark or review is protected-history damage. Never run `sync` first. Run `export --force` (it sets git HEAD to the sdt branch), then `sync . --force`.
- Without the `sync` afterwards the git index is left stale and `git status` shows spurious staged changes.
- The background auto-mirror (`sdt config git-sync on`) has the same wrong-branch behaviour on a plain save, and after any history rewrite it refuses outright with *"refusing to move X in .git: N commits there are not in superdetermine"*. Treat every one of those messages as "git is not updated yet"; the explicit `export --force` at the end is what fixes it.
- `export` writes **all** sdt branches. Any scratch branch you made shows up in git, and **`sdt` has no branch delete** — so do not create scratch branches you cannot afford to leave behind.

---

## Commands that destroy uncommitted work

Verified by running them:

| Command | What it does to a dirty tree |
| --- | --- |
| `sdt new <name>` | **Silently discards every modification to tracked files.** No warning, no autosave. `sdt undo` does *not* bring them back. Untracked files survive. |
| `sdt switch <name>` | Auto-saves the dirty tree (including untracked files) as a change on the branch you are leaving, then checks out. |
| `sdt point` / `sdt squash` / `sdt split` | Auto-save the dirty tree first, same as `switch`. If the resulting change then becomes unreachable, that work is effectively gone. |
| `sdt merge` / `sdt pull` | Check the merged tree out over your edits. |

**Rule: get the tree clean before any branch or history command.** Park what you need (`mv` untracked out, `cp` tracked out), let the command run, then unpark.

---

## Revspecs that actually resolve

Tested:

| Form | Resolves? |
| --- | --- |
| `<branch>` , `<branch>~n` (`amend-series~2`) | yes |
| bare change hex prefix (`32cfe3250de7`) | yes |
| `@green`, `@2h`, `@<moment-hex>` | yes |
| `@~1` | **no** — "nothing matches" |
| `@save~1` | **no** |

And the trap that ends most rewrite plans:

> **Once a change is unreachable from any branch, `sdt rewind <hex>` cannot find it.**

So if you are about to `sdt point` a branch backwards and you will need the old trees afterwards, **snapshot them into a park directory first** (`sdt rewind <ref>` then `cp -R` the worktree, once per change). A scratch branch would also hold them, but it cannot be deleted afterwards and `export` will publish it to git.

---

## Recipes (each one verified end to end)

### 1. Selective commit on a new branch — some hunks in, some stay dirty

Do not look for `add -p`. Edit the file instead.

```sh
P=$(mktemp -d)
cp -R <every dirty tracked file> "$P"/      # sdt new will discard these
mv <untracked dirs/files> "$P"/             # or they get scooped into the save
sdt new my-branch                           # tree is now back at the last change
cp "$P"/<files that belong in the commit> .  # restore only those
# edit any mixed file down to just the hunks that belong in the commit
sdt save -m "add input validation"
cp "$P"/<leftover files> . ; mv "$P"/<untracked> . ; rm -rf "$P"
sdt export . --force && sdt sync . --force
```

4 sdt commands.

### 2. Amend several dirty hunks into several different earlier changes

`sdt absorb` folds every *modified tracked* file into **the change that last touched that file**. That target is fixed and whole-file, so absorb only solves this when each file's edits belong to exactly one change and that change is the newest one touching it (see recipe 6 for the case where it fits perfectly).

When one file's edits must split across two earlier changes, **`sdt` has no amend primitive** — rebuild the branch:

```sh
P=$(mktemp -d); mkdir "$P"/dirty
cp -R <dirty tracked files> "$P"/dirty/ ; mv <untracked> "$P"/
# 1. snapshot every original change's tree BEFORE rewriting, or you lose them
i=1; for r in br~4 br~3 br~2 br~1 br; do
  sdt rewind $r; mkdir -p "$P"/t$i && cp -R <tracked paths> "$P"/t$i/; i=$((i+1)); done
# 2. cut the branch back to its base
sdt point main
# 3. replay: restore each snapshot, apply the amendments that belong at or below it, save
i=1; for m in "msg1" "msg2" "msg3" "msg4" "msg5"; do
  rm -rf <tracked paths>; cp -R "$P"/t$i/. .
  # apply amendment group A if i>=1, B if i>=3, C if i>=5 ...
  sdt save -m "$m"; i=$((i+1)); done
# 4. put the leftovers back as uncommitted work
cp "$P"/dirty/<leftover files> . ; mv "$P"/<untracked> . ; rm -rf "$P"
sdt export . --force && sdt sync . --force
```

13 sdt commands for a five-change branch. Each `save` is a whole-tree snapshot, so the diff between consecutive saves is exactly the difference you built — that is what makes the rebuild reliable.

### 3. Split a non-top change

`sdt split` **does** work on a change below the tip, by path or by hunk:

```sh
sdt split <ref> -m "extracted message" -- README.md docs/lead-workflow.md
sdt split <ref> -m "extracted message" --hunk src/lead.ts:1,2 --hunk tests/lead.test.ts:1
```

- **`-m` must come before `--`.** Anything after `--` is read as a path, so `split ... -- paths -m "msg"` silently loses the message.
- The **extracted** part becomes the *lower* change and gets `-m`; the remainder stays above it **keeping the original message**.
- Paths and `--hunk` cannot be mixed in one call.
- `sdt describe` rewords **only the tip**, so you cannot rename that remainder. There is no non-tip reword.

Because of that, a split into three or more named changes — or any split where some of the content must end up *uncommitted* rather than in a change — is not reachable with `split` alone. Use the recipe-2 rebuild instead:

```sh
P=$(mktemp -d); cp -R <all tracked paths> "$P"/     # tree already holds the final content
sdt point br~2                                       # cut back to just below the change to split
<edit>; sdt save -m "refactor validation helpers"
<edit>; sdt save -m "tune lead scoring"
<restore doc files from $P>; sdt save -m "document lead workflow"
<restore the files of the change that must stay on top>; sdt save -m "add handler routing metadata"
<restore the files that must stay uncommitted>; rm -rf "$P"
sdt export . --force && sdt sync . --force
```

7 sdt commands.

### 4. Reorder changes

```sh
sdt reorder 1 4 5 2 3 6      # 1 is the OLDEST of the span; this lists the new order by old index
sdt export . --force && sdt sync . --force
```

3 sdt commands. Contents, messages and authorship survive; the worktree stays clean.

### 5. Squash adjacent changes, including below the tip

`sdt squash [n]` collapses the last `n` changes. The undocumented **`--at <ref>`** ends the span at any change, so non-tip groups work:

```sh
sdt squash 3 -m "add retry support"                       # the top three
sdt squash 2 --at squash-series~2 -m "add parser pipeline" # two ending at that ref
sdt export . --force && sdt sync . --force
```

4 sdt commands. Do the **topmost** group first: `~n` selectors are recomputed after each rewrite.

### 6. Update a dirty branch onto a moved target, with conflicts

`sdt rebase <ref>` produces linear history (unlike `sdt merge` / `sdt pull`, which produce a merge commit).

```sh
P=$(mktemp -d); cp <dirty tracked file> "$P"/ ; mv <untracked> "$P"/
sdt restore <dirty tracked file>     # rebase must start clean
sdt import .                         # pick up git-side movement of main
sdt rebase main
# rebase writes <<<<<<< ours / >>>>>>> theirs markers into the files AND into the
# rebased changes, and then reports the tree as clean. Fix every marker by hand.
sdt absorb                           # routes each fixed file into the change that last touched it
cp "$P"/<file> . ; mv "$P"/<untracked> . ; rm -rf "$P"
sdt export . --force && sdt sync . --force
```

6 sdt commands. `absorb` is the right finisher here precisely because each conflicted file belongs to exactly one change: the conflict in `src/notify.ts` came from the change that last touched `src/notify.ts`. If two conflicts landed in the *same* file from two different changes, absorb cannot help and you are back to recipe 2.

**After a rebase, do not trust `sdt status`.** It reports `clean, nothing to save` while conflict markers sit in the tree, because the markers are part of the saved (conflicted) change. Grep for `<<<<<<<` yourself. `sdt super` reports nothing for these — it is for superposed paths, not rebase conflicts.

---

## What `sdt` still has no primitive for

- **Amending content into a chosen earlier change.** `absorb` picks the target for you and is whole-file.
- **Rewording a change that is not the tip.**
- **Dropping a change from the middle of a branch** while keeping its content in the worktree.
- **Deleting a branch.**
- **Splitting into three or more named parts in one pass.**

Every one of these is reachable by the recipe-2 rebuild (`park → point → replay with saves`), at a cost of roughly two commands per change.

---

## Do not

- **Do not run `sdt new` on a dirty tree.** It discards tracked edits and `undo` will not bring them back. Park first.
- **Do not go looking for `sdt add`, `sdt stash`, `sdt reset`, `sdt commit --amend`, `sdt save <path>`, `sdt save -p`, or `sdt branch -d`.** None exist. `sdt branch -d <name>` prints the branch list and deletes nothing.
- **Do not park inside the worktree.** `.tmp/`, `backup/`, `*.orig` next to the file — all get saved. Park in `$(mktemp -d)`.
- **Do not `sdt merge` / `sdt pull` when the task wants linear history.** Use `sdt rebase`.
- **Do not finish without `sdt export . --force && sdt sync . --force`.** Anyone reading `git log` sees the pre-rewrite history until you do, and a bare `sdt sync` can write your work onto the wrong branch.
- **Do not report success unread.** Finish with `sdt status`, `sdt log`, and — because they can disagree — `git log --oneline --decorate --all` and `git status --porcelain`.

## Command reference (verified)

| Command | What it does |
| --- | --- |
| `sdt save -m "msg"` | snapshot the whole tree as a change |
| `sdt status [--json]` | dirty set; **says "clean" during an unresolved rebase conflict** |
| `sdt log [--json]` | change history (`--json` carries full ids; plain output truncates to 12) |
| `sdt describe -m "msg"` | reword **the tip only** |
| `sdt restore <file>` | one file back to the last save |
| `sdt rewind <ref> [--dry-run] [-- <paths>]` | worktree only; flags go **before** `--`; only reaches changes still reachable from a branch |
| `sdt new <name>` | branch off here — **discards dirty tracked edits** |
| `sdt switch <name>` | move branch, auto-saving the dirty tree first |
| `sdt point <ref>` | move this branch's tip anywhere; auto-saves first |
| `sdt rebase <ref>` | linear replay; conflict markers land in the changes |
| `sdt squash [n] [--at <ref>] [-m msg]` | collapse n adjacent changes ending at `--at` (default: the tip) |
| `sdt split <ref> [-m msg] -- <paths>` / `--hunk <path>:1,3` | two-way split, non-tip allowed; `-m` before `--`; names the lower half only |
| `sdt reorder <order...>` | reorder the last changes, 1 = oldest |
| `sdt absorb` | fold whole-file edits into the change that last touched each file |
| `sdt merge <branch>` · `sdt resolve <file>` · `sdt resolve --abort` | three-way merge and conflict flow |
| `sdt undo` / `sdt redo` | reverse / replay the last history operation — **not** discarded worktree edits |
| `sdt moments [-n N]` · `sdt back [n]` · `sdt green` | polled captures; `sdt rewind @<moment>` is what actually restores one |
| `sdt import <repo>` | pull git history in (idempotent; re-run to pick up git-side movement) |
| `sdt export <repo> --force` | write **all** sdt branches out to git, replacing what was there |
| `sdt sync <dir> --force` | mirror sdt HEAD onto **git HEAD's** branch and reset git's index |
| `sdt work <dir> [--at <ref>]` | instant copy-on-write worktree at any state — safe place to inspect |
| `sdt revert [<full-hex>]` | **new** change restoring an old tree (not a rewrite) |

Every command has a short alias (`sv st d l rs rw bk u gn ab mg res`). `sdt help` prints the full table.
