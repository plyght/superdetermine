---
name: superdetermine
description: Drive the superdetermine VCS (`sdt`, alias `gr`) for history surgery — selective commits, amending earlier changes, reordering, squashing, splitting, and updating a dirty branch onto a moved target. Use whenever the repo has a `.sdt` directory or the user says sdt, superdetermine, or guardrail.
---

# superdetermine (`sdt`)

## Mental model — read this first

Six facts. Everything below follows from them.

1. **No staging area.** `sdt save` snapshots the *entire* working tree. It takes no path arguments. There is no `add`, no `-p`, no partial staging.
2. **No stash.** You never need one, and you can never leave one behind.
3. **Nothing is ever unsaved.** The tree is captured continuously as *moments*. A moment is not a commit and never shows in `sdt log`.
4. **States are addressed by describing them.** `@green` `@save` `@2h` `@yesterday` `@a3f91c` `main` `main~2` `<change-hex-prefix>`; `~n` composes with any of them (`@green~2`, `main~3`). When a `.git` sits beside `.sdt`, git refs resolve too (`origin/main`).
5. **`sdt undo` reverses *any* operation**, whole repo, including `absorb`, `merge`, `rewind`, and `save`. `sdt redo` re-applies. Exploration is free — try the thing, look, undo.
6. **`sdt rewind <ref> [-- <paths>]` changes only the worktree.** It never moves a branch. It is your file-level time machine.

### The one core move: shape the tree, then save

Because `save` takes the whole tree, **the working tree *is* the selection UI**. To commit exactly X:

1. Make the tree hold exactly X.
2. `sdt save -m "..."`.
3. Put back whatever you moved out of the way.

That is the entire technique. It gives hunk-level precision with no hunk-level flag.

**Parking rule:** anything that must not enter the commit gets parked **outside the worktree** (`$TMPDIR`), never inside it — an untracked file inside the tree *would* be scooped into the save.

```sh
P=$(mktemp -d)
cp path/to/file "$P"/              # park the dirty version
# ... edit path/to/file down to only what belongs in this commit ...
sdt save -m "..."
cp "$P"/file path/to/file          # unpark; the leftovers are dirty again
rm -rf "$P"
```

To park a *whole* unrelated file: `sdt restore <file>` (back to last save), then unpark after the save.

---

## Recipes

### 1. Selective commit — some hunks in, some hunks stay dirty

Do **not** look for `add -p`. Edit the file instead. You already know both versions.

```sh
sdt status                                   # see the whole dirty set
# park every unrelated dirty file (see parking rule); or: sdt restore <unrelated>
# edit the mixed file so it contains ONLY the hunks that belong in the commit
sdt save -m "add input validation"
# edit the mixed file to re-add the withheld hunk (e.g. the logging line)
# unpark the unrelated files
sdt status                                   # must show exactly the intended leftovers
```

Two file edits, one `sdt save`. Verify with `sdt rewind main -- <file>` in a scratch copy, or just re-read the file.

### 2. Amend into an earlier change

`sdt absorb` folds every *modified* tracked file in the worktree into **the most recent change that touched that file**, rewrites the chain above it, preserves messages, and leaves the tree clean.

```sh
# edit files so each one's edit belongs to the change that last touched it
sdt absorb                                   # "absorbed N file(s) into M change(s)"
sdt log
```

Its limits are hard, so check them before you rely on it:

- Target is **fixed** — always the newest change touching the path. You cannot pick a different one.
- It is **whole-file**. One file cannot feed two different targets.
- **New files are skipped** (only `modified` is absorbed).

If a file's edits must split across two targets, or must land somewhere other than the last change that touched it, **`sdt` has no primitive for it** — see *When sdt cannot do it*.

`sdt undo` fully reverses an absorb, restoring both history and the dirty worktree edit.

### 3. Split a non-top change into several

**`sdt` has no split.** There is no way to move a branch backwards, so a change below the tip cannot be reopened. See *When sdt cannot do it*.

If the change to split is the **tip** and nothing sits above it, you can rebuild it:

```sh
sdt log --json                               # full change ids live here; `sdt log` truncates to 12
sdt undo                                     # reverse the save that made the tip (tree stays dirty)
# then apply recipe 1 once per intended change, saving between each
```

`sdt undo` only walks back through operations you performed in this repo's oplog. If the change predates your session, use the fallback.

### 4. Reorder changes / 5. Squash changes

**`sdt` has neither.** No rebase, no reset, no `--fixup`, no interactive editor. `sdt describe -m "..."` rewords the tip only. See *When sdt cannot do it*.

### 6. Update a dirty branch onto a moved target

`sdt merge` and `sdt pull` produce a **merge**, not a rebase. If the task demands linear history, `sdt` cannot produce it — see *When sdt cannot do it*. If a merge is acceptable:

```sh
P=$(mktemp -d); cp <dirty-tracked-file> "$P"/    # park; untracked files need no parking,
                                                 # merge/rewind never touch them
sdt restore <dirty-tracked-file>                 # merge would otherwise overwrite it
sdt merge main                                   # or: sdt pull origin main
```

On conflict, `sdt` writes markers into the files and stops nothing else:

```sh
sdt status                                       # lists every unresolved path
# edit each file — resolve each one on its own merits:
#   file A: keep BOTH sides   file B: keep the branch's value, drop main's
sdt resolve <file>                               # per file; refuses while markers remain
sdt resolve                                      # with no args: what is still unresolved
sdt save -m "merge main"
cp "$P"/<file> <dirty-tracked-file>; rm -rf "$P" # unpark the leftover
sdt status                                       # exactly the intended leftovers, no conflicts
```

`sdt resolve --abort` restores the pre-merge tree. `sdt undo` also reverses the whole merge.

Guardrail: if a check is configured (`sdt config checks.full "<cmd>"`), `sdt grade` grades the resolved state and `sdt green` rewinds to the last state that actually passed — use it to confirm your two resolutions did not break the build before you save.

---

## When `sdt` cannot do it

`sdt` has **no rebase, no reset, no cherry-pick, no squash, no reorder, no split, and no content amend**. Its only history rewriter is `absorb`. Do not invent flags for these — none exist, and `sdt` will exit non-zero on an unknown command rather than doing something surprising.

When the task needs one of them and the environment allows git writes, do the rewrite in the colocated git repo, then bring it back:

```sh
git rebase -i ...            # or git reset --soft, git commit --fixup, etc.
sdt import .                 # re-imports full history + branches; sdt now matches git
sdt status                   # confirm the worktree and leftovers are as intended
```

Do the rewrite **git-side, not sdt-side**. `sdt sync` / `sdt push` graft sdt's chain onto the existing git tip rather than replacing it, so a history rewritten inside `sdt` and then mirrored appears in git as duplicated commits.

If git writes are not permitted in your environment, say plainly that `sdt` has no primitive for the operation. Do not fake it with `sdt revert`, which appends a *new* change holding an old tree and does not rewrite anything.

---

## Do not

- **Do not go looking for `sdt add`, `sdt stash`, `sdt rebase`, `sdt reset`, `sdt commit --amend`, `sdt save <path>`, or `sdt save -p`.** None exist. `save` is whole-tree; the tree is the selection.
- **Do not run `sdt save` on a mixed tree** and hope. It scoops in every dirty and untracked file. Park first, then save.
- **Do not park inside the worktree.** `.tmp/`, `backup/`, `*.orig` next to the file — all get saved. Park in `$(mktemp -d)`.
- **Do not `sdt merge` / `sdt pull` with dirty tracked files.** They check out the merged tree over your edits. Park them first (untracked files are safe — checkout only touches paths in the trees).
- **Do not leave conflict markers.** `sdt resolve <file>` refuses while markers remain — run it for every path and confirm `sdt status` reports no merge in progress.
- **Do not leave an operation in progress.** Finish with `sdt resolve` per file, or `sdt resolve --abort`.
- **Do not delete or overwrite the user's work to make a command succeed.** Nothing here needs it: `sdt undo` reverses any operation, `sdt back` / `sdt rewind @<ref>` recover any earlier state, and `sdt moments` lists what was captured.
- **Do not report success unread.** Finish every task with `sdt status` and `sdt log` and check them against what was asked.

## Command reference (verified)

| Command | What it does |
| --- | --- |
| `sdt save -m "msg"` | snapshot the whole tree as a change |
| `sdt status [--json]` | dirty set, conflicts, superposed paths |
| `sdt diff` | line diff vs last save |
| `sdt log [--json]` | change history (`--json` carries full ids; plain output truncates to 12 hex) |
| `sdt describe -m "msg"` | reword the tip change, in place |
| `sdt restore <file>` | one file back to the last save |
| `sdt rewind <ref> [--dry-run] [-- <paths>]` | worktree only; flags go **before** `--` |
| `sdt back [n]` / `sdt green` | rewind n moments / to the last state that passed |
| `sdt undo` / `sdt redo` | reverse / replay the last operation, whole repo |
| `sdt absorb` | fold whole-file edits into the change that last touched each file |
| `sdt merge <branch>` · `sdt resolve <file>` · `sdt resolve --abort` | three-way merge and conflict flow |
| `sdt pull [remote] [branch]` | fast-forward, else merge |
| `sdt new <name>` · `sdt switch <name>` | branch (switch auto-saves first) |
| `sdt work <dir> [--at <ref>]` | instant copy-on-write worktree at any state — safe place to inspect |
| `sdt moments [-n N]` · `sdt grade` · `sdt recap` · `sdt doctor` | captured states, verdicts, and what is on |
| `sdt import <repo>` · `sdt export <repo>` · `sdt sync <dir>` | git interop |
| `sdt revert [<full-hex>]` | **new** change restoring an old tree (not a rewrite) |

Every command has a short alias (`sv st d l rs rw bk u gn ab mg res`). `sdt help` prints the full table.
