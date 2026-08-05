# 07. Recap

Status: draft. Phase 3. Depends on: 01, 03. Blocks: nothing.

## Problem

After a long agent run you have a diff and a vague memory. `gr log` shows the
saves, which for agent work is often one entry covering forty minutes and
thirty files. `gr diff` shows the end state. Neither answers the question you
actually have, which is what happened and in what order and why.

This is worst exactly when it matters most: reviewing an agent's work before you
stand behind it. The reviewer's job is to reconstruct intent, and the tooling
gives them a wall of changed lines with no narrative.

## Why us

Once conversations are stored (01) and moments are recorded with message
attribution (03), the narrative is already in the repo. The run had a structure:
the human asked for something, the agent did a sequence of edits, the human
corrected it, the agent did more. Recap reads that structure back out.

This is a pure derivation over data the other features produce. No new capture,
no new storage.

## What it is

```
gr recap
```

Summarizes the current run, grouped by human intent rather than by commit.

```
gr recap since yesterday
gr recap @a3f91c..HEAD
gr recap --session 019a3f2c
```

Sample output:

```
recap: 3 intents, 47 moments, 12 files, 2h 14m

1. "the merge blows up when both sides delete the same file"    38m, 9 moments
   src/merge.zig          +34 -12
   src/merge_test.zig     +51 -0
   ↳ 2 false starts, reverted at @8b0d27
   ↳ claude-code, session 019a...

2. "keep the conflict if the modes differ"                       11m, 4 moments
   src/merge.zig          +8 -2
   ↳ claude-code

3. "run the tests and fix whatever breaks"                     1h 25m, 34 moments
   src/merge.zig          +2 -19
   src/workspace.zig      +7 -7
   src/git.zig            +1 -1
   ↳ 6 false starts
   ↳ tests referenced: merge/deleted-both, merge/mode-conflict
```

### What "intent" means

A group is bounded by a human message in the conversation. Everything from one
human turn until the next is one intent: the ask, and everything the agent did
in response. This is a better unit than a commit for agent work, because a
commit is whenever someone remembered to run `gr save`, while a human turn is
an actual decision point.

### False starts

A false start is a stretch of moments whose net contribution to the final tree
is zero or was later reverted. Detected by comparing each moment's tree against
the final state per path: a file that was written, changed again, and ended up
matching neither is a path the agent went down and abandoned.

This is the number reviewers most want and never get. It is the difference
between "the agent wrote this in one shot" and "the agent thrashed for an hour
and the result is whatever survived".

### Review mode

```
gr recap --review
```

Adds, per intent, the diff and the specific agent messages that produced it,
which is 02 applied over a range. Intended to be read top to bottom before
approving agent work, and to be piped into a PR description by 08.

### Machine readable

`gr recap --json` emits the structure so it can feed a PR body, a changelog, or
another agent. A common use is handing an agent the recap of its own run and
asking it to write the change message, which is a better prompt than the diff
alone.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr recap` | Recap since the last save |
| `gr recap since <when>` | Time bounded |
| `gr recap <a>..<b>` | Between two changes or moments |
| `gr recap --session <id>` | One agent session |
| `gr recap --review` | Include diffs and the messages that produced them |
| `gr recap --json` | Machine readable |

## Out of scope

- Calling a model to summarize. Recap is deterministic and offline. It reports
  what the record says. If a user wants prose, `gr recap --json` into their agent
  is one pipe, and that keeps guardrail free of an API dependency and an API key.
- Quality judgments about the agent's work. Recap counts false starts, it does
  not grade them.
- Cross repo or cross branch recaps in v1.

## Success criteria

1. On a real agent run, intents match the human turns in the transcript exactly.
2. False start detection has no false positives on a seeded run with a known
   number of abandoned paths, tested against a fixture.
3. `gr recap` on a run with no conversation data degrades to a moment and file
   summary rather than failing.
4. `gr recap --json` schema is stable and documented.
5. Runs in under a second on a 500 moment history.

## Risks

| Risk | Mitigation |
| --- | --- |
| No conversation data, so no intents | Degrade to time and moment clustering, and say clearly that intents are unavailable |
| Interleaved sessions from two agents in one repo | Group by session first, then intent, and label. Concurrent agents are increasingly normal and the output has to stay readable |
| False start heuristic is wrong in a way that embarrasses a review | Report it as an observation with the moment ids attached so it is checkable, never as a verdict |
