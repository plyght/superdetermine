# 02. Bidirectional trace

Status: draft. Phase 2. Depends on: 01. Blocks: nothing.

## Problem

`gr why <file>` answers "who last authored this file" with an agent name, a
confidence, a session id, and a truncated prompt. That is one hop, at file
granularity, in one direction, and it stops at the prompt.

The question a developer actually has, standing in front of a line they do not
understand, is "why is this like this". The answer is a conversation: what was
asked, what the agent proposed, what it tried, what the human pushed back on.
Once 01 stores that conversation, the remaining work is navigation.

The reverse direction has no answer at all today. Given a message in a
conversation, there is no way to ask what code it produced. That is the
direction a reviewer needs: read the thread, jump to the diff each turn caused.

## Why us

`src/blame.zig` already computes per line origin, resolving each line to the
change that introduced it, and already joins that against `provenance.zig`. The
line to change mapping is done. What is missing is change to message, which 01
supplies. This feature is mostly a join and a presentation layer over machinery
that exists.

## What it is

One command, `gr trace`, that walks the graph in whichever direction the
argument points.

```
line of code ──> change ──> conversation ──> message ──> surrounding thread
message ──> tool calls ──> paths + content hashes ──> change ──> diff
```

### Code to conversation

```
gr trace src/merge.zig:214
```

Resolves the line to its origin change via `blame.zig`, resolves the change to
overlapping conversations via the `.gr/convlog` index from 01, then narrows to
the specific message whose tool calls touched that path, preferring an exact
post-edit content hash match over a path and time match. Output:

```
src/merge.zig:214
  ↳ change 7f3a91c2  "handle deleted-on-both in three-way merge"
  ↳ claude-code, session 019a...  (certain)

  ── 2 messages before ──────────────────────────────
  you        the merge blows up when both sides delete the same file
  assistant  Looking at mergeFile, the deleted/deleted case falls through
             to the content compare, which dereferences a null blob...

  ── the message that wrote this line ───────────────
  assistant  I'll treat deleted-on-both as a resolved deletion rather than
             a conflict, matching git's behavior.
             ↳ Edit src/merge.zig
  ── 1 message after ────────────────────────────────
  you        good, but keep the conflict if the modes differ
```

Context window size is `--context N`, defaulting to 2 on each side. `--full`
prints the whole conversation with the anchor message marked.

### Conversation to code

```
gr trace @019a3f2c            # a message id
gr trace --session 019a...    # every message in a session that touched code
```

Prints each message with the paths it touched and the change it landed in, and
with `--diff`, the actual diff attributable to that message.

The subtlety: a message's tool calls are not a change. An agent may edit a file
six times across four messages before a single `gr save`. So a message maps to a
change plus a set of paths, and the diff shown is the diff of those paths within
that change. That is an approximation and it is labeled as one. With moments
(03) the approximation gets much tighter, because a moment can be captured
between two messages, and `gr trace --diff` prefers moment boundaries when they
exist. This is the main reason 03 is a phase 1 foundation rather than a nice to
have.

### Confidence, always

Every trace result carries the confidence that `attribution.zig` already
computes:

| Confidence | Meaning | Rendering |
| --- | --- | --- |
| `certain` | Post-edit content BLAKE3 matched the stored content | Shown plainly |
| `likely` | Path and timing matched, content could not be confirmed | Suffixed `(likely)` |
| none | No agent event matched, attributed to the human | `↳ human` |

A trace that cannot find a conversation says so and stops. It does not fall back
to the nearest conversation in time, because a confident wrong answer here is
worse than no answer.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr trace <file>:<line>` | Code to conversation |
| `gr trace <file>` | Code to conversation for the file's last change |
| `gr trace @<message-id>` | Message to code |
| `gr trace --session <id>` | Every code touching message in a session |
| `gr trace ... --context N` | Messages of surrounding thread, default 2 |
| `gr trace ... --full` | Whole conversation |
| `gr trace ... --diff` | Include the diff attributable to each message |
| `gr trace ... --json` | Machine readable |

`gr why` stays, unchanged, as the fast one line answer. `gr trace` is the deep
one. `gr blame` gains a `--trace` flag that appends the message id to each line
so the two compose.

## Out of scope

- Sub-line attribution. A message maps to a path and a change, not to a
  character range. Chasing that needs the operation stream a CRDT gives you and
  we deliberately do not have.
- Ranking or searching conversations. `gr trace` navigates, it does not search.
  Search over conversations is a later feature and probably wants an index.

## Success criteria

1. On this repo, `gr trace` on a line written by an agent returns the correct
   message, verified by hand against the source transcript, for at least 20
   sampled lines.
2. A line written by a human returns `human` and does not invent a conversation.
3. `gr trace @<id> --diff` output for a message equals the diff of the paths that
   message touched within its change.
4. Every result renders its confidence. No result renders a `likely` as a fact.
5. `gr trace --json` round trips through `jq` with stable field names.

## Risks

| Risk | Mitigation |
| --- | --- |
| Many messages touch the same path in one change, so the anchor is ambiguous | Prefer content hash match. When several remain, show all candidates rather than picking, and say why they are ambiguous |
| Output is a wall of text for long assistant messages | Wrap and elide message bodies past N lines with an explicit `[+N lines, --full to expand]` marker |
| Performance on a large history | Blame is already the expensive part and is unchanged. The convlog join is a linear scan over an append only file, and gets an index only if measurement says it needs one |
