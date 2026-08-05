# Agent-native version control: research and feature plan

Status: draft. Owner: guardrail. Date: 2026-08-05.

This directory holds mini PRDs for a family of features that make guardrail a
version control system built for how code actually gets written now: mostly by
agents, in long runs, with the reasoning that produced each edit living in a
chat log that the VCS never sees.

Each feature has its own file. This one covers the research, the positioning,
and the order to build in.

## 1. What prompted this

Zed announced DeltaDB on 2026-06-11 and opened an early access waitlist. Their
pitch, in their words, is "software is made between commits". The four claims on
the landing page:

| DeltaDB claim | What it means |
| --- | --- |
| Rewind to any edit | Captures every operation between commits, each with a stable identity |
| Trace code to conversation | Every change links to the agent conversation that produced it, navigable in both directions |
| Branch at any moment | The worktree is virtualized, so branching is free and any point in history is a valid branch point, including mid-run |
| Share the thread, not the PR | A teammate joins while work is still happening, talks to the agent, annotates in place |

Reported technical shape: a CRDT records fine-grained deltas as they happen and
synchronizes them across machines, so several people and agents can edit the
same files at once. Files stay ordinary files on disk. It interoperates with
git rather than replacing it: git stays for CI and external systems, DeltaDB
owns the live layer before and between commits. Beta was expected within weeks
of the announcement.

Sources are listed at the bottom.

## 2. Why this matters to guardrail

The uncomfortable part is that guardrail already has most of the machinery, and
in several places has had it longer:

| Capability | Where it lives today |
| --- | --- |
| Operation log with whole-repo undo and redo | `src/oplog.zig`, `gr undo` / `gr redo` |
| Continuous capture of the worktree | `src/watch.zig`, 800ms content-signature poll, auto-save |
| Agent and prompt recorded per change | `src/provenance.zig` |
| Human vs agent authorship per file, with confidence | `src/attribution.zig`, surfaced by `gr why` |
| Reading agent session logs without agent cooperation | `src/agentscan.zig`, six adapters |
| Instant copy-on-write worktrees | `src/workspace.zig`, `gr work`, clonefile and reflink |
| Peer to peer encrypted transfer, no host | `src/wormhole.zig`, `src/share.zig`, `gr send` / `gr get` |
| Content addressed store with sub-file dedup | `src/store.zig`, `src/cdc.zig`, BLAKE3 and FastCDC |
| Lossless git interop, both directions | `src/git.zig` |

What is missing is not storage and not capture. It is that the conversation is
never stored, only a 500 byte truncated prompt string is; that captured
operations have no stable identity a human can name; and that nothing can be
navigated from a line of code back to the reasoning.

## 3. The wedge: do not build their system

The temptation is to build a CRDT. That would be the wrong move, and copying it
is both uninteresting and a losing race.

DeltaDB instruments the editor. The deltas come from Zed's own buffers and
Zed's own agent, which is what makes real time multi-writer collaboration
possible. The cost of that design is the boundary of the system: it works for
work done inside their client, with their agent, synchronized through their
service.

guardrail observes instead of instruments. `agentscan.zig` already reads the
session logs that Claude Code, Codex, Gemini CLI, Cline, Roo, Pi, and aider
write to disk anyway, without asking any of them to cooperate. That is a
different and, for our users, more useful boundary:

- Works with whatever agent the user already runs, in whatever editor.
- Works offline, with no account and no server. A peer is just an object store.
- Degrades honestly. Observation gives certainty when a content hash matches and
  says "likely" when it does not, rather than pretending to a precision it does
  not have.

So the principle for everything below:

> Match DeltaDB on what the user can do. Do not match it on how. Where they
> instrument a client, we observe the artifacts every agent already leaves on
> disk. Where they synchronize through a service, we stay local first and move
> bytes peer to peer.

The honest trade to state up front: we cannot do real time character level
co-editing, and we should not claim to. What we can do is capture, identity,
linkage, branching, rewind, and handoff, which is most of the value and all of
the parts that survive without a server.

## 4. Feature map

Nine features. Numbers are file names in this directory, not priority.

| # | Feature | Command surface | Answers |
| --- | --- | --- | --- |
| [01](01-conversation-objects.md) | Conversation objects | (none, foundation) | Store the conversation in the repo, content addressed, per message identity |
| [02](02-trace.md) | Bidirectional trace | `gr trace` | From a line, find the message. From a message, find the code |
| [03](03-moments.md) | Moments | `gr moments`, `gr log --moments` | Every operation between saves, each with a stable, nameable id |
| [04](04-branch-at-a-moment.md) | Branch at a moment | `gr new @<moment>`, `gr work --at` | Any point in history is a branch point, including mid-run |
| [05](05-rewind.md) | Rewind | `gr rewind <moment>` | Put the worktree back to any moment, reversibly |
| [06](06-live-session.md) | Live session handoff | `gr send --live`, `gr join` | A teammate picks up work in flight, with the thread |
| [07](07-recap.md) | Recap | `gr recap` | What happened in this run, grouped by intent rather than by commit |
| [08](08-git-bridge.md) | Conversation bridge to git | `gr git export`, `gr push` | The thread survives the trip to GitHub |
| [09](09-commitless-flow.md) | Commitless flow | `flow.*` config | Stop authoring commits and pushes. Boundaries get cut from the record instead |

Dependency order:

```
01 conversation objects
 ├── 02 trace
 ├── 07 recap
 └── 08 git bridge
03 moments
 ├── 04 branch at a moment
 └── 05 rewind
01 + 03 ──> 06 live session handoff
03 + 07 ──> 09 commitless flow
```

01 and 03 are independent of each other and are the two foundations. Build both
first. 02 is the feature that demonstrates the whole thesis, so it should ship
immediately after 01.

## 5. Sequencing

| Phase | Contents | Rationale |
| --- | --- | --- |
| 1 | 01, 03 | Foundations. Nothing else is possible without stored conversations and identified moments |
| 2 | 02, 05 | The two features a user can feel on day one. `trace` proves the linkage, `rewind` pays off the capture |
| 3 | 04, 07, then 09 | Leverage on phase 1 and 2. 04 and 07 are small once the foundations exist. 09 is gated on 03 proving out in real use, not just passing tests |
| 4 | 06, 08 | Distribution. 06 needs the wormhole to carry two new object kinds, 08 needs a stable trailer format |

## 6. Non-goals

- A CRDT, or real time multi-writer editing of the same buffer. Different
  system, different guarantees, and it forces a synchronization service.
- A hosted product, an account system, or a web UI. guardrail is a CLI and a
  local store. Sharing stays peer to peer.
- Asking agents to cooperate. Every adapter stays passive. The moment we require
  an agent to call us, we inherit their release cycle and lose the ones that
  will not.
- Replacing git. Everything here has to survive `gr git export` and round trip.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Transcript formats drift and adapters silently rot | Adapter conformance tests with checked in fixtures per agent, and a `gr doctor` that reports which adapters found data |
| Conversations contain secrets pasted into chat | Conversation objects go through the same `.grignore` and seal path as content, plus explicit redaction rules. See 01 |
| Storing full transcripts bloats the repo | Chunk conversations through FastCDC like any other content, and let `gr gc` reclaim them. Measure before shipping. See 01 |
| Linkage precision oversold | Confidence is a first class field everywhere it is displayed, as `attribution.zig` already does. Never render a guess as a fact |
| Moment capture burns battery or IO | Reuse the existing signature poll rather than adding a second watcher, and make cadence configurable. See 03 |

## Sources

- [Software Is Made Between Commits, Zed's blog](https://zed.dev/blog/introducing-deltadb)
- [DeltaDB early access](https://zed.dev/deltadb)
- [Zed's DeltaDB versions every operation, not every commit, Agent Wars](https://www.agent-wars.com/news/2026-06-13-zed-deltadb)
- [Zed Opens DeltaDB Waitlist, TechTimes](https://www.techtimes.com/articles/318322/20260613/zed-opens-deltadb-waitlist-crdt-version-control-records-every-edit-not-just-commits.htm)
- [Zed's DeltaDB Rebuilds Version Control Around AI Agent Conversations, AlphaSignal](https://alphasignal.ai/news/zed-s-deltadb-rebuilds-version-control-around-ai-agent-conversations)
- [Zed announces DeltaDB, GIGAZINE](https://gigazine.net/gsc_news/en/20260612-zed-deltadb/)
- [Beyond the Commit: AI-Ready Version Control, datatip](https://www.datatip.eu/beyond-the-commit-building-version-control-for-the-era-of-ai-agents/)
- [jj evolog manual](https://man.archlinux.org/man/extra/jujutsu/jj-evolog.1.en)
- [Jujutsu docs, tutorial and bird's eye view](https://docs.jj-vcs.dev/latest/tutorial/)
