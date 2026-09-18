# 2026-08-31 — sdt gaps hit during a long multi-agent session

Context: large working tree (~40 modified files), six parallel subagents editing
disjoint directories, plus a git-interop repo on `master`.

All six are fixed as of 2026-09-01. Each section says what it now does.

## 1. No way to restore one file from a moment (highest impact)

`sdt restore <file>` only discards local edits back to the last *save*. There is
no `--at <ref>`. So when a file's only good content lived in a moment and not in
a save, there was no supported way to get it back short of rewinding the whole
worktree, which would have discarded five other agents' concurrent work.

Concretely: `git checkout -- spec/conformance/f11-interop.json` reverted an
uncommitted file to HEAD and destroyed ~5 new conformance fixtures. Moments had
captured the good content. I could not extract it.

Wanted: `sdt restore <file> --at @ref`, and ideally `sdt cat @ref:<path>`.

Fixed. `sdt restore <file>... --at <ref> [--dry-run]` puts named paths back to
what any state held and touches nothing else. It refuses before writing if a
named path is not in that state, because restoring a file the state never held
would mean deleting it. `sdt cat <ref>:<path>` writes one file's content to
stdout without moving the tree; `<ref> <path>` and `<path> --at <ref>` also
work.

## 2. No way to inspect what a change contains

`sdt diff --at <ref>` and `sdt diff <ref>` both print "no changes" when the
working tree is clean — they appear to diff the tree against the ref rather than
showing the ref's own contents. There is no `sdt show <ref>`. After a `split`,
I could not verify which of the two resulting changes held which files, and had
to fall back on `git show --stat`.

Wanted: `sdt show <ref>` (contents of that change), and `sdt diff <a>..<b>`.

Fixed. `sdt show <ref>` diffs a change or moment against the state one step
before it, so it says what that ref introduced whatever the working tree holds.
`sdt diff <a>..<b>` compares two states. `sdt diff <ref>` compares the working
tree against one: it used to be parsed and then dropped, which is why a clean
tree printed "no changes" and looked like the ref held nothing.

## 3. `split -- <paths>` did not separate in the exported git history

Sequence: `sdt save -m ...` with 44 modified files, then
`sdt split -- eval/real`. sdt reported "2 change(s) rewritten" and `sdt log`
showed two changes, but `git log` showed a single commit containing everything,
including the `eval/real` paths I was trying to peel off. The intent was to keep
someone else's unrelated in-progress edits out of my commit; the split silently
did not achieve that in the git view.

Fixed. History rewrites now mirror into the colocated `.git` the way a save
does. A rewrite cannot use the save-time graft, which would leave `git log`
showing the pre-split commit followed by commits undoing half of it, so it
rebuilds the git chain from sdt truth instead. That is only allowed when every
commit on the git branch is one sdt exported and git's tip is a change the
branch no longer holds. If git holds a commit sdt never had, `.git` is left
alone and the commit is named on screen.

## 4. `undo` of a save leaves git ahead of sdt, and the next save is refused

After `sdt undo` (twice, to reverse a split and then a save), sdt's log no longer
had the change but `git log` still had the commit. The next `sdt save` refused:

    refusing to move master in .git: 1 commit there is not in superdetermine
      3a7f6ce9520d  library surface, analyzer soundness, and recorded omissions
      hint: `sdt pull` brings them in; `sdt sync . --force` drops them on purpose

`sdt pull` recovered it, but it auto-saved first and created an empty
`wip (auto-saved before pull)` change that then had to be dropped. If `undo`
reverses a save, it seems like it should also reverse the git-side commit, or say
up front that it will not.

Fixed. `sdt undo` and `sdt redo` mirror through the same path as a rewrite, so
undoing a split or a save moves git with it and the next save is not refused.
Undoing back to an unborn branch says so in one line instead of leaving the two
silently out of step.

## 5. `sdt work <dir>` fails with an unactionable error

    $ sdt work /private/tmp/.../scratchpad/recover
    could not create worktree: CloneFailed

No reason, no errno, no path context. I was trying to make a throwaway COW
worktree to rewind into and copy one file out of — the workaround for gap 1.
Target parent directory existed and was writable; source repo is on APFS.

Fixed. The failure now names the syscall, both paths and the errno, e.g.
`clonefile(/a -> /b/wt): NOENT`. `EXDEV` and `EOPNOTSUPP` are no longer failures
at all: a destination on another filesystem falls back to a plain recursive
copy, losing only the sharing.

## 6. `moments` output is hard to act on

Every row reads `@<hash>  ungraded  poll` with no timestamp and no summary, so
there is no way to pick the moment from "just before I broke this" without
dry-running each one. `sdt rewind <ref> --dry-run` per moment works but is
O(n) subprocess calls, and it lists only files differing from the *current* tree,
which is not the same question as "what did this moment hold".

Wanted: a timestamp column, and ideally a `--path <file>` filter showing only
moments where that file's content changed.

Fixed. Every row carries an age in the units the revspecs use, so a row reads
straight across into `sdt rewind @2h`. `sdt moments --path <file>` keeps only
the moments where that file's content actually moved, which is the question you
have when you are trying to get one file back.
