# 07. Recap

Status: draft. Phase 3. Depends on: 03, 10. Blocks: nothing.

## Problem

After a long agent run you have a diff and a vague memory. `gr log` shows the
saves, which for agent work is often one entry covering forty minutes and thirty
files. `gr diff` shows the end state. Neither answers the question you actually
have, which is what happened, in what order, and where it broke.

This is worst exactly when it matters most: reviewing an agent's work before you
put your name on it. The reviewer gets a wall of changed lines with no shape.

## Why us

Once moments are recorded (03) and graded (10), the shape is already in the repo
and nobody had to write it down. A run is a sequence of green stretches and red
stretches, and that alone tells you more than any commit log: where it worked,
where it broke, how long it stayed broken, and what it took to get back.

This is a pure derivation over data the other features produce. No new capture,
no new storage, no integrations.

## What it is

```
gr recap
```

Summarizes the current run as verified spans.

```
gr recap since yesterday
gr recap @a3f91c..HEAD
gr recap last-green..
```

Sample output:

```
recap: 47 moments, 12 files, 2h 14m, 3 green spans, 2 breakages

green  @d2e5a9 → @41c8ea      22m, 9 moments
       src/merge.zig          +34 -12
       src/merge_test.zig     +51 -0

red    @41c8ea → @8b0d27      6m, 4 moments
       broke: merge_test "deleted on both sides"
       fixed by src/merge.zig:214

green  @8b0d27 → @a3f91c      11m, 4 moments
       src/merge.zig          +8 -2

red    @a3f91c → now          1h 25m, 30 moments   ← you are here
       broke: build, src/workspace.zig:88
       last green 1h 25m ago at @a3f91c
```

That last line is the feature. A reviewer, or the developer coming back from
lunch, learns in one glance that the tree has been broken for 85 minutes and
exactly which state to compare against.

### Spans, not intents

The unit is a stretch between two states with the same verdict. Green spans are
work that landed. Red spans are the cost of getting there: how long it was
broken, what broke, and what fixed it.

An earlier draft grouped by "intent", derived from human turns in an agent
transcript. That is cut, along with the whole conversation-provenance idea. A
span is better anyway: it is universal, it needs nothing from any agent, and it
is a fact rather than an inference.

### Thrash

A red span containing moments that write a file, change it again, and end up
matching neither the start nor the end is the agent going down a path and
abandoning it. Recap counts these, reports them as an observation with the
moment ids attached so they are checkable, and never grades them.

The number reviewers most want and never get is the difference between "written
in one shot" and "thrashed for an hour and this is whatever survived".

### Review mode

```
gr recap --review
```

Adds the diff per span. Intended to be read top to bottom before approving agent
work, and to be piped into a PR description by 08. Because 08 renders commits at
green boundaries, the spans in the recap and the commits in the PR are the same
objects.

### Machine readable

`gr recap --json` emits the structure so it can feed a PR body, a changelog, or
another agent. Handing an agent the recap of its own run and asking it to write
the change message is a much better prompt than the diff alone, and it keeps the
model call outside guardrail where it belongs.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr recap` | Recap since the last save |
| `gr recap since <when>` | Time bounded |
| `gr recap <a>..<b>` | Between two changes, moments, or selectors |
| `gr recap last-green..` | Everything since it last worked |
| `gr recap --review` | Include diffs per span |
| `gr recap --json` | Machine readable |

## Out of scope

- Calling a model to summarize. Recap is deterministic and offline. It reports
  what the record says. `gr recap --json` into the user's own agent is one pipe,
  and that keeps guardrail free of an API dependency and an API key.
- Quality judgments. Recap counts thrash, it does not grade it.
- Cross repo or cross branch recaps in v1.

## Success criteria

1. Span boundaries match the verdict transitions in the log exactly.
2. Thrash detection has no false positives on a seeded run with a known number of
   abandoned paths, tested against a fixture.
3. `gr recap` on a run with no verdicts degrades to a moment and file summary,
   and says plainly that nothing was graded.
4. `gr recap --json` schema is stable and documented.
5. Runs in under a second on a 500 moment history.

## Risks

| Risk | Mitigation |
| --- | --- |
| No verdicts, so no spans | Degrade to time and moment clustering, and say clearly that grading was off. Never invent a boundary |
| Spans are ragged because a flaky check flips green and red | 10 already detects a verdict that flips on an identical tree hash. Recap marks a span as flaky rather than reporting a breakage that did not happen |
| Two agents in one repo interleave and the output is unreadable | Group by branch and workspace first. Concurrent agents are increasingly normal and the output has to survive it |
