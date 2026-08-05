# 08. Git bridge

Status: draft. Phase 4. Depends on: 07, 10. Blocks: nothing.

## Problem

Everything in 03 through 10 lives in `.gr`. The moment work leaves guardrail for
GitHub, which is where review, CI, and the rest of the company are, it flattens
back into a diff and a commit message. The moments, the verdicts, and the shape
of the run stay behind.

That is a hard ceiling on adoption. If using guardrail means the useful context
is invisible to everyone reviewing on GitHub, then it only helps the person
running it, and a tool that only helps the person running it does not spread.

guardrail's stated promise is that adopting it is reversible and it never locks
you in, per the README. That promise has to extend to the new data or the new
data is lock-in by another name.

## Why us

`src/git.zig` is 2,200 lines of working bidirectional interop that already round
trips full history, branches, and tags losslessly, plus LFS pointers. There is a
`sync.git` dual-write mode where every `gr save` also lands a normal git commit.
The bridge exists. It carries trees and commits. It needs to carry the verdict.

Zed's DeltaDB positions git as the thing that stays for CI and external systems
while they own the live layer. We can take that further: because we ride git
rather than sitting beside it, what we produce lands in the place the team
already reviews, and nobody else installs anything.

## What it is

### 1. Every exported commit builds

This is the headline and it falls straight out of 10. Under `flow.cut = green`
(09), a change is cut at a red-to-green transition, so a rendered commit is a
verified state by construction.

Git histories are always *claimed* to have this property and never do. Here it is
not a discipline, a hook, or a CI gate. It is what the boundary *is*. A team that
adopts nothing else about guardrail gets a branch where `git checkout <any
commit> && make test` passes, which is the entire premise of `git bisect` finally
being true.

### 2. Trailers on exported commits

Every commit produced by `gr git export`, `gr push`, or `sync.git` dual-write
gains structured trailers:

```
Gr-Change: 7f3a91c2e4b1...
Gr-Span: a3f91c..8b0d27
Gr-Verified: full=green fast=green
Gr-Check: "zig build test" exit=0 in 4.2s
Gr-Attribution: agent=9 human=3 certain=7 likely=2
```

Trailers are chosen because git already understands them, GitHub renders them,
`git log --format` can select them, and they survive rebase and cherry-pick
better than anything else available. `agentscan.zig` already has an adapter that
reads git trailers, so the format is familiar to this codebase.

`Gr-Verified` is the interesting one. It is a machine-checkable claim, attached to
the commit, that this exact tree passed this exact command. A CI system can read
it and skip work it would otherwise repeat, which turns the local grading budget
from a cost into a saving.

Round tripping: `gr git import` reads these back and reconstructs the spans and
verdicts, so a repo that goes gr, git, GitHub, clone, gr comes back intact. That
is the test that makes this real rather than decorative.

### 3. Recap as a PR body

```
gr push --pr
gr recap --format=markdown
```

`gr recap --json` from 07 rendered as markdown suitable for a pull request
description: verified spans as sections, files touched, how long the tree was
broken and what broke it, thrash noted. The PR stops being a diff with a guessed
summary and becomes the actual shape of the run.

This is the feature a team notices. Everything else is infrastructure; this one
shows up in the review they were going to do anyway.

## Format stability

The trailer keys are a public interface the moment anyone pushes with them. They
get a documented spec in `docs/formats/` with a version marker, and changes
follow a compatibility rule: readers accept every version they have ever emitted.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr git export <dir>` | Now includes trailers |
| `gr git import <dir>` | Now reads trailers back into spans and verdicts |
| `gr recap --format=markdown` | PR ready narrative |
| `gr config git.trailers false` | Opt out, producing byte-identical output to today |

## Out of scope

- A GitHub App, a bot, or anything that posts on the user's behalf. `gr recap
  --format=markdown` produces text. What the user does with it is theirs.
- Exporting moments as commits. Covered in 03's non-goals and still true. Moments
  are trees, not changes, and are structurally incapable of becoming commits.
- Pushing verdicts as a notes ref. An earlier draft exported conversations this
  way. Verdicts are small enough to live in trailers, so the extra ref is not
  worth the operational surface.
- Bidirectional sync of GitHub review comments. Interesting, much larger, and
  needs API credentials guardrail deliberately does not hold.

## Success criteria

1. A repo exported to git, cloned, and imported back into guardrail reconstructs
   every span and verdict with no loss.
2. A team member with plain git and no guardrail sees a normal repo and normal
   commits, and can check out any of them and have the build pass.
3. Trailers survive a rebase and a squash merge, or where they cannot, the
   failure is documented precisely rather than discovered later.
4. With `git.trailers false`, export output is byte identical to what guardrail
   produces today.
5. `gr recap --format=markdown` produces a PR body a human would not rewrite.

## Risks

| Risk | Mitigation |
| --- | --- |
| Squash merges destroy trailers on all but one commit | Known git limitation. Document it, and have `gr recap --format=markdown` be the answer for squash workflows since the PR body survives |
| `Gr-Verified` is trusted by CI and is wrong or forged | It is a hint, never an authority. Document that CI must treat it as a cache key it can independently verify, not as a substitute for running the check |
| Trailer format churn breaks old repos | Versioned spec in `docs/formats/`, readers accept all prior versions, covered by fixture tests |
| Exported metadata reveals more than expected | Trailers carry hashes, verdicts, and counts, never file contents. `.grignore` and sealed values are already excluded upstream |
