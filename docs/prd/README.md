# Verified history: research and feature plan

Status: draft. Owner: guardrail. Date: 2026-08-05.

guardrail should always know when the code last worked, and should know it
without anyone running a test by hand or authoring a commit.

That is the whole thesis. Everything in this directory is either the mechanism
for it or a consequence of it. Start with **[10, verified states](10-verified-states.md)**,
which carries the argument and the research; the rest are supporting pieces.

## 1. How we got here

Zed announced DeltaDB on 2026-06-11 and opened an early access waitlist, pitching
"software is made between commits". Four claims: rewind to any edit, trace code
to the agent conversation that produced it, branch at any moment including
mid-run, and share the thread rather than the PR. Mechanism is a CRDT recording
fine-grained deltas, synced through their service, driven by their editor and
their agent.

The first version of this plan chased all four. That was a mistake in one
specific way: it took their framing that **the conversation is the intent
record**, and built two features on recovering intent from agent transcripts. Six
adapters parsing undocumented JSONL, missing every SQLite-backed agent, to
recover what is usually a one-line prompt. Those are cut. See 10, section 4.

What survives is better, because it is universal. Nothing below requires an agent
to cooperate, or to be recognized, or to exist at all.

## 2. The thesis

A commit is a bundle whose contents one human chose. That is why `git bisect`
exists: the bundle is too coarse, so you binary search inside it.

Replace the authored boundary with a **verified** one. Record every state
continuously, grade states in the background by running the project's own check
in a throwaway copy-on-write clone, and the natural unit of history becomes the
span between two states that passed. Derived, not authored. Zero keystrokes.
Smallest interval that provably contains a break.

The research says this works and has said so since 2003. The reason it never
reached a VCS is that isolating a test run and memoizing its verdict were both
expensive, and guardrail already solved both for unrelated reasons: millisecond
COW worktrees, and a BLAKE3 content-addressed store that gives every tree a key
to memoize against. Full argument and citations in 10.

## 3. What guardrail already has

| Capability | Where |
| --- | --- |
| Operation log, whole-repo undo and redo | `src/oplog.zig` |
| Continuous worktree capture | `src/watch.zig`, 800ms content-signature poll |
| Instant copy-on-write worktrees | `src/workspace.zig`, clonefile and reflink |
| Stat-cache index, no re-hashing unchanged files | `src/index.zig` |
| Content addressed store, sub-file dedup | `src/store.zig`, `src/cdc.zig` |
| Lossless bidirectional git interop | `src/git.zig` |
| Peer to peer encrypted transfer, no host | `src/wormhole.zig`, `src/share.zig` |
| Human vs agent authorship per file | `src/attribution.zig`, `gr why`, `gr blame` |

The storage layer is right. The UX layer on top of it, `save` and `push` and a
git-shaped change graph, is what these PRDs replace.

## 4. Feature map

| # | Feature | Command surface | Answers |
| --- | --- | --- | --- |
| [10](10-verified-states.md) | **Verified states** | `gr at last-green` | When did this last work. The centerpiece |
| [03](03-moments.md) | Moments | `gr moments` | Every state between saves, each with a stable id |
| [04](04-branch-at-a-moment.md) | Branch at a moment | `gr new @<id>`, `gr work --at` | Fork mid-run, free, over existing COW worktrees |
| [05](05-rewind.md) | Rewind | `gr rewind` | Put the tree back to any state, undoably |
| [09](09-commitless-flow.md) | Commitless flow | `flow.*` | Boundaries get cut from the record, not authored |
| [07](07-recap.md) | Recap | `gr recap` | What happened, per verified span |
| [08](08-git-bridge.md) | Git bridge | `gr git export`, `gr push` | Rendered commits that build by construction |
| [06](06-live-session.md) | Live session handoff | `gr send --live` | Hand a run in flight to a teammate |

Dependency order:

```
03 moments
 ├── 10 verified states  ← read this first
 │    ├── 09 commitless flow
 │    ├── 07 recap
 │    └── 08 git bridge
 ├── 04 branch at a moment
 ├── 05 rewind
 └── 06 live session handoff
```

## 5. Sequencing

| Phase | Contents | Rationale |
| --- | --- | --- |
| 1 | 03 | The only foundation. Continuous capture with stable ids |
| 2 | 10, then 05 | The thesis, then the payoff a user feels immediately |
| 3 | 04, 07 | Small once 03 and 10 exist |
| 4 | 09, 08 | 09 is gated on 10 proving out in real use. 08 needs a stable trailer format |
| 5 | 06 | Distribution. Needs the wormhole to carry a new object kind |

## 6. Non-goals

- A CRDT, or real time multi-writer editing. Different system, and it forces a
  synchronization service.
- A hosted product, an account, or a web UI. A CLI and a local store. Sharing
  stays peer to peer.
- Requiring any agent to cooperate, or parsing any agent's logs to make a feature
  work. This is the lesson from the cut features.
- Guessing a project's build or test command. Configured or off.
- Replacing git. Everything has to survive `gr git export` and round trip.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Continuous grading is too slow or too hot to live with | Five layers of avoidance and an enforced CPU ceiling, all specified with numeric budgets in 10, section 3. If `gr status` gets slower, the feature is wrong |
| Continuous capture burns disk | Retention and caps in 03, and the store dedups at chunk level |
| Users confuse moments with commits | Distinct sigil, distinct command, structurally incapable of appearing in `gr log` or in git |
| Continuous publish sends code off the machine without a command | Opt in, per remote, with an explicit prompt. This is a consent problem, not a technical one. See 09 |

## Sources

Research citations for the thesis are in [10](10-verified-states.md). Background
on what prompted this:

- [Software Is Made Between Commits, Zed's blog](https://zed.dev/blog/introducing-deltadb)
- [DeltaDB early access](https://zed.dev/deltadb)
- [Zed's DeltaDB versions every operation, not every commit, Agent Wars](https://www.agent-wars.com/news/2026-06-13-zed-deltadb)
- [Zed Opens DeltaDB Waitlist, TechTimes](https://www.techtimes.com/articles/318322/20260613/zed-opens-deltadb-waitlist-crdt-version-control-records-every-edit-not-just-commits.htm)
- [jj evolog manual](https://man.archlinux.org/man/extra/jujutsu/jj-evolog.1.en), for the stable-id design
