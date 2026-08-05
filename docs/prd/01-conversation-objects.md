# 01. Conversation objects

Status: draft. Phase 1, foundation. Depends on: nothing. Blocks: 02, 06, 07, 08.

## Problem

The conversation that produced a change is the single most valuable artifact in
an agent run, and guardrail throws almost all of it away.

`src/agentscan.zig` parses full agent transcripts today. It walks Claude Code's
`~/.claude/projects/**/*.jsonl`, Pi's session files, Codex, Gemini CLI, Cline,
and aider, and it reads every message in every session. Then it discards
everything except a path, a timestamp, an optional content hash, and
`last_prompt`, truncated to 500 bytes by `prompt_cap`.

So today a user can ask "who wrote this file" and get "claude-code (certain),
prompt: refactor the token parser to handle...". They cannot ask what the agent
was told before that, what it tried first, what it reported back, or what the
human said when they corrected it. That context exists on disk, we already read
past it, and the moment the user clears their agent history it is gone forever.

Meanwhile the repo is the one thing that gets backed up, pushed, and shared.

## Why us

Nobody else can do this without the agent's cooperation. Zed can link
conversations to code because Zed owns the agent. We can do it for any agent
that writes a session log, which is all of them, because we already parse those
logs for attribution. The incremental cost is storage and a schema, not a
partnership.

## What it is

A new content-addressed object kind, `conversation`, plus a per-message index,
so a conversation is a durable object in the repo with the same properties as a
tree or a change: hashed, deduped, chunked, garbage collected, transferable.

### Object model

`src/object.zig` gains one kind:

```zig
pub const Kind = enum(u8) {
    blob = 'B',
    tree = 'T',
    change = 'C',
    conversation = 'V',   // new
};
```

A `Conversation` is an ordered list of messages plus session identity:

| Field | Type | Notes |
| --- | --- | --- |
| `agent` | string | `claude-code`, `codex`, `pi`, ... matches `agentscan` adapter names |
| `session` | string | The agent's own session id, may be empty |
| `started_ms`, `ended_ms` | i64 | Bounds of the messages included |
| `messages` | list of `MessageRef` | Ordered, append only |

A `MessageRef` is:

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `MessageId`, 16 bytes | Stable identity, see below |
| `parent` | `MessageId` | Zero for the first message. Preserves branching threads |
| `role` | enum | `user`, `assistant`, `tool_result`, `system` |
| `timestamp_ms` | i64 | |
| `body` | Oid | A `blob`, so message text chunks through FastCDC like any content |
| `tool_calls` | list of `ToolCall` | Name, and the paths it touched, and post-edit content hash when recoverable |

Message bodies being blobs is the important choice. A long conversation that
gets re-imported after five more turns stores five new chunks, not a second copy
of the whole thing. It also means an enormous pasted file in a chat message
dedupes against the file itself already in the store.

### Stable message identity

`MessageId` is `BLAKE3("gr-msg-v1" || agent || session || provider_uuid)`
truncated to 16 bytes, when the transcript carries a provider message uuid.
Claude Code's JSONL does, in the `uuid` and `parentUuid` fields, which is also
where `parent` comes from.

When the transcript has no uuid, the fallback is
`BLAKE3("gr-msg-v1" || agent || session || timestamp_ms || role || body_oid)`.
This is stable for a given message but will change if the agent rewrites its own
history, which is the honest behavior: the message did change.

Message ids are the anchor every other feature points at. 02 resolves a line to
a message id. 07 groups by them. 08 writes them into git trailers.

### Ingestion

`agentscan.zig` grows a second entry point alongside `scan`:

```zig
pub fn scanConversations(alloc, io, repo_abs_path, since_ms) ![]Conversation
```

The adapters already walk the files and parse the JSON. The change is that each
adapter's file callback keeps the whole message stream instead of collapsing it
to `last_prompt`. Adapter signatures change once, in one place, and the six
existing parsers keep their format knowledge.

Ingestion is incremental and idempotent. A conversation object for a session is
rewritten on each import, but because messages are content addressed and ids are
stable, the store only grows by the new messages. Re-importing an unchanged
session writes nothing.

Trigger points:

- `gr save`, right where `attribution.autoAttribute` is called today in
  `doSave` in `src/main.zig`. Same information, captured at the same instant.
- The watcher in `src/watch.zig`, on the same cadence as moment capture (03).
- `gr conv import` for a manual or backfill run.

Storage is `.gr/conversations/<session-oid>` pointing at the conversation object,
with the objects themselves in the normal object store. The index that maps a
change Oid to the conversations that overlap it lives in `.gr/convlog`, in the
same append only escaped line format `provenance.zig` and `attribution.zig`
already use, for consistency and because it round trips through the existing
sharing code without new framing.

### Redaction and secrets

Conversations contain whatever the human pasted, which is a real risk that
content files do not have to the same degree, because nobody thinks of chat as
storage.

Rules, all applied at import time before anything is written:

1. Any file path matched by `.grignore` has its tool call arguments and results
   stripped to the path alone. If a file is not worth storing, its contents are
   not worth storing because an agent read them aloud.
2. Values in a sealed `.env` are searched for verbatim in message bodies and
   replaced with `[sealed: KEY]`. `src/seal.zig` already knows the values.
3. A `conv.redact` config key takes a list of regexes applied to bodies, off by
   default.
4. `gr conv redact <message-id>` replaces a body blob with a tombstone after the
   fact. The message id survives so links do not dangle, the body does not.

Point 4 matters because the repo is pushed. A user needs a way to unsay
something without breaking every trace that points at it.

### Size

The measurement to make before this ships: a week of real Claude Code sessions
on this repo, imported, compared against the object store size. The expectation
is that transcripts are small next to source and that chunk dedup makes repeated
context nearly free, but it is an expectation and not yet a number. If a session
costs more than a few hundred kilobytes after dedup, `conv.retain` gets a
default other than "everything".

`gr gc` learns to treat a conversation as reachable if any change it links to is
reachable, and to drop it otherwise.

## Command surface

This feature is mostly invisible. It adds one command group for control:

| Command | Behavior |
| --- | --- |
| `gr conv` | List conversations in the repo, newest first, with agent, message count, time range |
| `gr conv show <id>` | Print one conversation, roles and bodies |
| `gr conv import [--since <when>]` | Force an ingestion pass |
| `gr conv redact <message-id>` | Tombstone a message body |
| `gr conv --json` | Machine readable, as `status` and `log` already do |

## Out of scope

- Rendering conversations nicely. `gr conv show` is plain text. A pager, syntax
  highlighting of code blocks, and a TUI are later work.
- Editing or annotating conversations. That is 06.
- The SQLite backed agents that `agentscan.zig` already documents as unsupported,
  namely Cursor, opencode, and Copilot. Adding a dependency free SQLite reader is
  its own project, and the comment in the adapter table stays accurate.

## Success criteria

1. On a repo where Claude Code has been used, `gr conv` lists real sessions with
   correct message counts, verified against the source JSONL.
2. Importing the same session twice writes zero new objects on the second run.
3. A conversation survives `gr send` and `gr get` intact.
4. `gr gc` reclaims a conversation whose changes are all unreachable, and never
   reclaims one whose change is still referenced.
5. Message bodies containing a sealed secret value are stored redacted.
6. Store growth from a week of sessions is measured and documented.

## Risks

| Risk | Mitigation |
| --- | --- |
| Adapter refactor breaks existing attribution | `scan` keeps its exact current signature and becomes a thin projection over the richer parse. Attribution behavior is covered by tests before the refactor |
| Transcript formats change under us | Checked in fixtures per adapter, one conformance test each. `gr doctor` reports which adapters found data so a silent rot is visible |
| A single session with a huge pasted payload bloats a repo | FastCDC chunking plus a per-message body cap that stores an elision marker past a configurable size |
| Privacy surprise when a repo is shared | Redaction runs at import, not at share time, so a secret is never written in the first place. Document loudly in the README |
