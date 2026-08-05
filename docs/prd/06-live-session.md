# 06. Live session handoff

Status: draft. Phase 4. Depends on: 01, 03. Blocks: nothing.

## Problem

The unit of collaboration is still the pull request, which means a teammate can
only see finished work. When an agent run is going sideways at minute fifteen,
the useful intervention is at minute fifteen, and there is no way to bring
someone in.

The current best effort is a screen share, or pasting chunks of transcript into
Slack, or waiting until it is committable and opening a PR that has lost every
trace of how it got there.

DeltaDB's answer is real time CRDT collaboration through their service. That is
a good answer if you are willing to run a service and require their client. It
is not an answer we can copy, and it is not the only useful shape.

## Why us

`gr send` and `gr get` already move an entire repo peer to peer with SPAKE2
short authentication strings, encrypted end to end, with LAN peer discovery and a
relay fallback for when direct connection fails. `src/wormhole.zig` and
`src/share.zig` are 2,400 lines of working transport that nobody has to be
convinced to sign up for.

What that transport carries today is objects. Once 01 makes conversations
objects and 03 makes moments addressable, the same transport can carry a live
work session with no new infrastructure.

## What it is

Handoff and observation of work in progress, over the existing wormhole.
Deliberately not real time co-editing.

### Sharing a session in flight

```
gr send --live
```

Prints a spoken code as `gr send` does today, then holds the connection open and
streams new moments and new conversation messages to the peer as they are
captured. The sender keeps working. There is no server, no account, and the
connection is direct or relayed exactly as an ordinary send is.

```
gr join <code> ../review-alice
```

The receiver materializes a workspace at the sender's current moment and then
follows. As the sender's agent works, the receiver's workspace updates. They
see the code and the conversation arriving together, which is the thing that is
actually hard to get any other way.

### What the receiver can do

| Action | Mechanism |
| --- | --- |
| Watch the work arrive | Streamed moments, applied to their workspace |
| Read the conversation as it happens | Streamed messages from 01 |
| Annotate a line | `gr note <file>:<line> "this will break on empty input"` sends a note back over the same channel |
| Fork and try it themselves | `gr work ../my-attempt --at @<moment>` from 04, entirely local |
| Take over | `gr handoff` transfers the session, see below |

Notes are the interesting primitive. A note is a message appended to the shared
conversation with role `human` and an anchor of file, line, and moment id. It
lands in the sender's conversation, so the sender's agent can be told to read
it, and it is durable in the repo afterwards. A review comment that is part of
the history rather than living in a web UI.

### Handoff

```
gr handoff
```

The sender stops capturing and the receiver becomes authoritative. The receiver
gets the full conversation, the moment history, and a materialized worktree, and
can point their own agent at it with the context intact. The sender's copy
becomes read only for the session and stays as a complete record.

This is the honest version of "share the thread". Not two people typing in one
buffer, but a clean transfer of an entire run, including the reasoning, to
someone who can continue it.

### Conflict story

There is no CRDT, so there is one writer at a time. This is stated plainly in
the docs and enforced: the receiver's workspace is read only for tracked files
until handoff. If they want to change something, they fork (04), which is free.

That constraint is a feature for the primary use case. Two agents editing the
same file simultaneously is not something anyone wants; forking, trying both,
and merging with `gr merge` is.

## Command surface

| Command | Behavior |
| --- | --- |
| `gr send --live` | Share the session in flight, streaming moments and messages |
| `gr join <code> <dir>` | Follow a live session into a workspace |
| `gr note <file>:<line> "<text>"` | Annotate, sent back to the sender's conversation |
| `gr notes` | List notes on the current branch |
| `gr handoff` | Transfer authority to the receiver |
| `gr send --live --pause` | Stop streaming without ending the session |

## Out of scope

- Character level co-editing. Different system. Say so plainly rather than
  shipping a worse version of it.
- More than one follower in v1. The transport supports it, the UX questions
  around multiple annotators do not have good answers yet.
- Talking to the sender's agent directly. The receiver can add notes the sender's
  agent can read. Driving someone else's agent process remotely is a much larger
  security surface and is not worth it for v1.
- A web view. There is no server and this feature does not add one.

## Success criteria

1. Two machines on the same LAN establish a live session through discovery, with
   no relay, in under five seconds.
2. A moment captured on the sender appears in the receiver's workspace in under
   two seconds on a LAN.
3. A note added by the receiver appears in the sender's conversation and is
   present in the repo after the session ends.
4. `gr handoff` leaves the receiver able to continue with a working worktree and
   the full conversation, verified by continuing a real agent run after handoff.
5. Session traffic is end to end encrypted with the same properties as `gr send`,
   verified by inspecting relay traffic.
6. Killing the sender mid-session leaves the receiver with a consistent workspace
   at the last complete moment, never a partial tree.

## Risks

| Risk | Mitigation |
| --- | --- |
| Streaming a live session leaks more than a one-shot send | Redaction from 01 applies. Add an explicit summary of what will be shared before the code is printed, and require confirmation |
| NAT traversal fails and the relay becomes a bottleneck | Already solved for `gr send`, same code path, same relay fallback |
| Receiver's workspace drifts out of sync after a network blip | Moments are content addressed and ordered. Resync is fetching the missing moment ids, which is idempotent |
| Scope creep toward a real time editor | The read only constraint on the follower is deliberate and is the line. Fork rather than co-edit |
