# 08. Conversation bridge to git

Status: draft. Phase 4. Depends on: 01, 07. Blocks: nothing.

## Problem

Everything in 01 through 07 lives in `.gr`. The moment work leaves guardrail for
GitHub, which is where review, CI, and the rest of the company are, it flattens
back into a diff and a commit message. The conversation, the moments, and the
recap stay behind.

That is a hard ceiling on adoption. If using guardrail means the good context is
invisible to everyone reviewing on GitHub, then it only helps the person running
it, and a tool that only helps the person running it does not spread.

guardrail's stated promise is that adopting it is reversible and it never locks
you in, per the README. That promise has to extend to the new data or the new
data is a lock-in by another name.

## Why us

`src/git.zig` is 2,200 lines of working bidirectional interop that already round
trips full history, branches, and tags losslessly, plus LFS pointers. There is a
`sync.git` dual-write mode where every `gr save` also lands a normal git commit.
The bridge exists. It carries trees and commits. It needs to also carry the
conversation link.

Zed's DeltaDB positions git as the thing that stays for CI and external systems
while they own the live layer. We can take that further: because we ride git
rather than sitting beside it, the artifacts we produce can land in the place
the team already reviews.

## What it is

Three mechanisms, in increasing order of ambition.

### 1. Trailers on exported commits

Every commit produced by `gr git export`, `gr push`, or `sync.git` dual-write
gains structured trailers:

```
Gr-Change: 7f3a91c2e4b1...
Gr-Agent: claude-code
Gr-Session: 019a3f2c-...
Gr-Message: a1b2c3d4e5f60718
Gr-Attribution: agent=9 human=3 certain=7 likely=2
```

Trailers are chosen because git already understands them, GitHub renders them,
`git log --format` can select them, and they survive rebase and cherry-pick
better than anything else available. `agentscan.zig` already has an adapter that
reads git trailers for aider, so the format is familiar to this codebase.

Round tripping: `gr git import` reads these back and reconstructs the links, so
a repo that goes gr, git, GitHub, clone, gr comes back with its provenance. That
is the test that makes this real rather than decorative.

### 2. Conversations as git notes

The trailer is a pointer. The conversation itself exports as a git note under
`refs/notes/gr-conversations`, attached to the commit, containing the messages
in a documented plain text format.

Notes are the right home: they do not alter commit hashes, they are optional to
fetch, they push and pull with an explicit refspec, and a team that does not
want them simply never fetches them. A clone without the notes ref is a normal
repo. `gr git import` picks them up when present and reconstructs conversation
objects from them.

This is what makes the data portable rather than trapped. Someone who abandons
guardrail entirely still has their conversations, in their git repo, readable
with `git notes show`.

### 3. Recap as a PR body

```
gr push --pr
gr recap --format=markdown
```

`gr recap --json` from 07 rendered as markdown suitable for a pull request
description: intents as sections, files touched, false starts noted, and links
back to the conversation where the notes ref is available. The PR stops being a
diff with a guessed summary and becomes the actual narrative of the run.

This is the feature that a team notices. Everything else is infrastructure; this
one shows up in the review they were going to do anyway.

## Format stability

The trailer keys and the note format are a public interface the moment anyone
pushes with them. They get a documented spec in `docs/formats/` with a version
marker, and changes follow a compatibility rule: readers accept every version
they have ever emitted.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr git export <dir>` | Now includes trailers, and notes when `git.notes` is on |
| `gr git import <dir>` | Now reads trailers and notes back into conversations |
| `gr push [--notes]` | Push the notes ref alongside the branch |
| `gr pull [--notes]` | Fetch it |
| `gr recap --format=markdown` | PR ready narrative |
| `gr config git.notes true` | Opt in to note export, default off |

## Out of scope

- A GitHub App, a bot, or anything that posts on the user's behalf. `gr recap
  --format=markdown` produces text. What the user does with it is theirs.
- Bidirectional sync of GitHub review comments into conversations. Interesting,
  much larger, and needs API credentials guardrail deliberately does not hold.
- Exporting moments as commits. Covered in 03's non-goals and still true.

## Success criteria

1. A repo exported to git, cloned, and imported back into guardrail reconstructs
   every conversation link with no loss, verified by comparing `gr trace` output
   on both sides.
2. A team member with plain git and no guardrail sees a normal repo, normal
   commits, and can read the conversation with `git notes show`.
3. Trailers survive a rebase and a squash merge, or where they cannot, the
   failure is documented precisely rather than discovered later.
4. Notes are strictly opt in and a repo without them is byte identical to what
   guardrail exports today.
5. `gr recap --format=markdown` produces a PR body a human would not rewrite.

## Risks

| Risk | Mitigation |
| --- | --- |
| Squash merges destroy trailers on all but one commit | Known git limitation. Document it, and have `gr recap --format=markdown` be the answer for squash workflows since the PR body survives |
| Notes refs are unfamiliar and teams break them | Off by default, explicit refspec, and a `gr doctor` check that reports whether the remote has the notes ref |
| Exported conversations leak content in a repo with wider access than expected | Redaction from 01 applies at import so it is already redacted at rest. Additionally, a confirmation on the first push with notes enabled that states plainly what is about to become visible |
| Trailer format churn breaks old repos | Versioned spec in `docs/formats/`, readers accept all prior versions, covered by fixture tests |
