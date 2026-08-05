# History that knows what worked

Status: draft. Owner: guardrail. Date: 2026-08-05.

## The one sentence

Every version control system ever built records **what changed**. None of them
records **what worked**. guardrail should be the first that does, continuously,
with no commits, no test runs, and no keystrokes from the user.

## 1. The idea, end to end

Six moves. Each one is small; the composition is the product.

**1. Stop asking the user when to save.** Record the worktree continuously.
Every captured state is a **moment**: a content-addressed tree with a stable id,
costing one `stat` per file and a hash of only what changed. Nothing is ever
unsaved, so there is no moment at which code "needs to be" committed. `03`

**2. Grade states in the background.** Take a moment, clone it into a
copy-on-write worktree in milliseconds, run the project's own check inside the
clone, throw the clone away. The developer's tree is never touched and their
terminal is never blocked.

Crucially this is a **search, not a sweep**. Grading all 500 moments of a run
would be 500 check runs and absurd, but nobody wants a verdict on every state.
They want two boundaries: where it last worked, and where exactly it broke. So
grade the head when the tree goes quiet, binary search backwards when it flips
green to red, and spend any leftover budget on the midpoint of the largest
ungraded gap. About **30 runs instead of 500**, with a floor near 5, and the
extra spent only when the machine is idle anyway. A state between two green
states is `ungraded`, never green: verdicts are measured, never interpolated. `10`

**3. Never trust a bare green.** An agent that writes both the code and the test
has proved only that it agrees with itself. So a verdict is a claim plus its
warrant, along three deterministic axes with no model anywhere:

- **independence**, did the same actor author the code and the check in this
  span? `attribution.zig` already knows. Free.
- **relevance**, did the check process actually open the files that changed? The
  read-set tracing from the speed work already knows. Free.
- **discrimination**, would the check have failed on the *previous* tree? If it
  passes on both, it is vacuous with respect to this change. One extra run, only
  when check files changed, memoized forever.

They label, never gate. A signal wired to block becomes a target. `10`

**4. Let the boundary fall out.** Once states carry verdicts, the unit of history
writes itself: the **span between two states that passed**. Derived, not
authored. Zero keystrokes. It is also the smallest interval that provably
contains a break, which is `git bisect`'s job, done in advance and for free. `09`

**5. Address states by describing them, not by bookmarking them.** You never
place a reference point in advance; you say what you want and one small revspec
grammar resolves it. `@green` is the newest green state, `@green~1` the one
before, `@2h` two hours ago, `@a3f91c` an explicit id, and it composes everywhere
a revision is taken: `gr diff @green`, `gr work ../b --at @green~2`,
`gr recap @green..@`. The two most common operations get bare verbs, `gr back`
and `gr green`, because nobody should type a revspec to undo the last forty
minutes. `05`

**6. Stop letting conflicts halt anything.** Three-way merge runs first and
handles most of it. What it cannot reconcile enters **superposition**: the path
holds several complete, individually valid candidates, the worktree materializes
one, and the tree keeps building. Each candidate can be graded, so collapsing is
a decision with evidence rather than a coin flip. `11`

And the outside world never notices. Commits are **rendered** from the log at
green boundaries when something external needs one, so a teammate on plain git
sees an ordinary branch, reviews an ordinary PR, and installs nothing. Because
boundaries are green by construction, every commit guardrail exports builds. `08`

## 2. What is actually new

Being precise here matters, because most of the parts are not new and claiming
otherwise would be easy to falsify.

| | git | Pijul | jj | git-branchless | DeltaDB | **gr, proposed** |
| --- | --- | --- | --- | --- | --- | --- |
| Continuous capture, no explicit save | no | no | working copy auto-snapshot | no | yes, CRDT ops | yes |
| Whole-repo undo of any operation | no | no | op log | yes | yes | already shipped |
| Stable id that survives rewriting | no | patch identity | change ids | no | delta ids | moments |
| Conflicts as repository state | no | **yes** | **yes** | no | auto-converged | yes |
| Run a check across revisions, cached | no | no | `jj run`, designed | **`git test`, shipped** | no | yes |
| Binary search for the breaking revision | `git bisect` | no | no | **`git test -b`, shipped** | no | yes |
| **Grade states nobody committed** | no | no | no | no | no | **yes** |
| **Grade continuously, unprompted** | no | no | no | no | no | **yes** |
| **Verdicts carry a warrant** | no | no | no | no | no | **yes** |
| **Verdicts shape history** | no | no | no | no | no | **yes** |
| **Conflict candidates are graded** | no | no | no | no | no | **yes** |

Read the columns honestly, because a first draft of this table was wrong.

Jujutsu already auto-snapshots the working copy, keeps an operation log, gives
changes stable ids that survive rebasing, and commits conflicts as first-class
objects, crediting Darcs and Pijul for the last one. Pijul got to
conflicts-as-state first, with a sounder theory.

And **git-branchless already ships `git test`**, which runs a command across a
revset, executes out of tree, parallelizes, and **caches the result per commit
per command**. Jujutsu has `jj run` designed to do the same, citing git-branchless,
`hg fix`, and Google's internal Mercurial as prior art. So "run a check against a
state and remember the answer" is not new, and an earlier version of this
document claimed it was. That claim is withdrawn.

What survives is narrower and, unlike the withdrawn version, actually holds:

1. **They grade commits. We grade states nobody committed.** A revset is a set of
   boundaries a human authored. Every intermediate state of a forty-minute agent
   run is invisible to `git test`, because those states were never commits. That
   is the entire "between commits" thesis and it is not reachable from a
   commit-shaped tool.
2. **They run when you ask. We run continuously.** `git test` is a command you
   invoke, usually to search a stack you already have, and `git bisect` needs you
   to mark a good and a bad end. Grading here is unprompted: the endpoints come
   from continuous capture, the search fires on a transition nobody noticed yet,
   and the answer already exists at the moment you want it. Binary search over
   history is old; having it run itself, over states that were never committed,
   is not.
3. **For them a verdict is a cache. For us it is constitutive.** In git-branchless
   the cached result speeds up a search you initiated. Here the verdict decides
   where commit boundaries get cut (09), what `@green` resolves to (05), and which
   superposition candidate wins (11). It is part of the data model, not an
   accelerator bolted to a subcommand.
4. **Nobody warrants the verdict.** Independence, relevance, and discrimination
   have no counterpart anywhere. Every existing tool reports a bare pass or fail.

Everything else in this plan is the machinery that makes those four things
affordable.

### Why it has not been done

Not because nobody thought of continuous testing. Saff and Ernst measured it in
2003: waiting on tests costs **10 to 15 percent of development time**, and
running them continuously in the background cut that waste by **92 to 98
percent**. That result has sat there for twenty-three years.

It never reached a VCS because two things were expensive:

1. **Isolating a run.** Continuous testing had to execute in the developer's own
   working directory, fighting them for the filesystem, the build lock, the
   ports. Every implementation since, Infinitest through NCrunch through Wallaby,
   solved this per language and per runtime, which is why they are all per
   language and per runtime.
2. **Remembering an answer.** With no content addressing there is no key to
   memoize a verdict against, so every run started from scratch, including runs
   of states already tested.

guardrail solved both years ago for unrelated reasons: `gr work` clones a
worktree in milliseconds via clonefile and reflink, and every tree is a BLAKE3
hash. The research was settled and the blocker was infrastructural, and this
codebase happens to have removed it.

### Why it matters more now than it did then

- DORA 2024: every 25 percent increase in AI adoption came with a **7.2 percent
  drop in delivery stability**. DORA 2025, with adoption at 90 percent of
  developers, found throughput finally positive but the **negative relationship
  with stability persisting**.
- 45.2 percent of developers say debugging AI-generated code takes **longer** than
  debugging human-written code.
- Gradle's build data supplies the mechanism: the later a failure surfaces, the
  more changes are candidates, so **investigation time grows exponentially**.

A forty-minute agent run with the human out of the loop is that exponential case,
and it is now the ordinary case. Meanwhile Google's TAP analysis found **91.3
percent of test targets never failed once** in their entire history, and Meta
catches **99.9 percent of regressions running a third of the tests**, which is the
license to skip aggressively that makes continuous grading affordable at all.

Full citations in [10](10-verified-states.md).

## 3. How it comes together

```
                        ┌─────────────────────────────┐
   you and your agents  │  the worktree, ordinary files│
        edit files ────▶│  never touched by guardrail  │
                        └──────────────┬──────────────┘
                                       │ 800ms signature poll
                                       ▼
   03  ┌────────────────────────────────────────────────┐
       │ moments: content-addressed trees, stable ids   │
       └───────────┬────────────────────────┬───────────┘
                   │                        │
                   ▼                        ▼
   10  ┌──────────────────────┐   04 ┌──────────────────┐
       │ grade in a COW clone │      │ fork at any point│
       │ verdict + warrant    │      │ mid-run, free    │
       └───────┬──────────────┘      └────────┬─────────┘
               │                              │
      ┌────────┼──────────────┬───────────────┤
      ▼        ▼              ▼               ▼
  05 rewind  09 cut at    07 recap        11 superposition
  gr green    green       green/red spans  graded candidates
              boundaries
                   │
                   ▼
   08  ┌────────────────────────────────────────────────┐
       │ render commits at green boundaries → git       │
       │ every exported commit builds by construction   │
       └────────────────────────────────────────────────┘
```

`03` is the only true foundation. `10` is the thesis. Everything below the fork
is a consequence, and `08` is how it reaches people who never install guardrail.

## 4. Features

| # | Feature | Surface | Answers |
| --- | --- | --- | --- |
| [10](10-verified-states.md) | **Verified states** | `gr green`, `@green` | When did this last work, and is that green worth anything |
| [03](03-moments.md) | Moments | `gr moments` | Every state between saves, stable ids |
| [05](05-rewind.md) | Rewind and revspecs | `gr back`, `gr green` | Put the tree back anywhere, undoably. Owns the `@` grammar |
| [04](04-branch-at-a-moment.md) | Branch at a moment | `gr work --at` | Fork mid-run, free |
| [07](07-recap.md) | Recap | `gr recap` | What happened, per verified span |
| [09](09-commitless-flow.md) | Commitless flow | `flow.*` | Boundaries cut from the record |
| [11](11-superposition.md) | Superposition | `gr super`, `gr collapse` | Conflicts that do not halt anything |
| [08](08-git-bridge.md) | Git bridge | `gr git export` | Rendered commits that build |
| [12](12-freshness.md) | Freshness | `gr status`, `remote.autopull` | Never start work on a stale base, with no daemon |
| [06](06-live-session.md) | Live session handoff | `gr send --live` | Hand a run in flight to a teammate |

Sequencing:

| Phase | Contents | Rationale |
| --- | --- | --- |
| 1 | 03 | The only foundation |
| 2 | 10, then 05 | The thesis, then the payoff a user feels on day one |
| 3 | 04, 07, 12 | Small once 03 and 10 exist. 12 needs only 03 and pays off immediately |
| 4 | 09, 11, 08 | Each gated on 10 proving out in real use. 11 additionally on 04 forks becoming a real workflow |
| 5 | 06 | Distribution |

## 5. What guardrail already has

| Capability | Where |
| --- | --- |
| Instant copy-on-write worktrees | `src/workspace.zig`, clonefile and reflink |
| Content addressed store, sub-file dedup | `src/store.zig`, `src/cdc.zig`, BLAKE3 and FastCDC |
| Operation log, whole-repo undo and redo | `src/oplog.zig` |
| Continuous worktree capture | `src/watch.zig`, 800ms content-signature poll |
| Stat-cache index, unchanged files never re-hashed | `src/index.zig` |
| Three-way merge and resolve | `src/merge.zig` |
| Lossless bidirectional git interop | `src/git.zig`, 2,200 lines |
| Human vs agent authorship per file, with confidence | `src/attribution.zig` |
| Peer to peer encrypted transfer, no host | `src/wormhole.zig`, `src/share.zig` |

The storage layer is already right, which is the entire reason this plan is
buildable. What gets replaced is the UX layer on top of it: `save`, `push`, and a
change graph shaped like git's.

## 6. What was cut, and why

The first draft of this plan chased DeltaDB's framing that **the conversation is
the intent record**, and proposed storing agent transcripts as first-class objects
with bidirectional code-to-message tracing. Six adapters parsing undocumented
JSONL, blind to every SQLite-backed agent, to recover what is usually a one-line
prompt.

Cut, both features. Nobody reviewing a diff cares what the agent said three hours
earlier, and a design that needs six brittle integrations to work is not a design.
What replaced it needs nothing from any agent and works for any tool that writes
files.

## 7. Non-goals

- A CRDT, or real-time multi-writer editing of one buffer. Different system, and
  it forces a synchronization service.
- A hosted product, an account, or a web UI. A CLI and a local store.
- Requiring any agent to cooperate, or parsing any agent's logs for a feature to
  function. This is the lesson from section 6.
- Guessing a project's build or test command. Configured, or the feature is off.
- Any judgment about whether code is well designed. Not computable without a
  model, and pointing a model at a diff is a crowded, solved problem that is not a
  version control system's job.
- Replacing git. Everything has to survive `gr git export` and round trip.

## 8. Top risks

| Risk | Mitigation |
| --- | --- |
| Continuous grading is too slow or too hot to live with | Five layers of avoidance with numeric budgets in [10](10-verified-states.md) section 3, and an enforced CPU ceiling. Hard rule: if `gr status` gets slower, the feature is wrong |
| Green is read as proof of quality | Verdicts never render as a bare boolean. `co-authored` and `vacuous` are words the user reads, not flags they go looking for |
| Someone ships the wrong side of a superposition | Never silent. Always in `gr status`, export refuses by default, primary choice is a recorded fact |
| Continuous publish sends code off the machine without a command | Opt in, per remote, explicit prompt. A consent problem, not a technical one. See [09](09-commitless-flow.md) |
| Continuous capture writes enormous files | Two real problems in the current code, a quadratic append in `oplog.zig` and a full O(repo) tree per capture, are named and fixed in [03](03-moments.md) with incremental trees and keyframes. Target is under 1 KB of metadata per moment, verified losslessly against the full-tree hash |
| The whole model is wrong and nobody wants it | Every phase is opt in and one config key reverts to today's behavior. That is what the staging in 09 is for |

## Sources

Full research citations live in [10](10-verified-states.md) and
[11](11-superposition.md). Background on what prompted this:

- [Software Is Made Between Commits, Zed's blog](https://zed.dev/blog/introducing-deltadb)
- [DeltaDB early access](https://zed.dev/deltadb)
- [Zed's DeltaDB versions every operation, not every commit, Agent Wars](https://www.agent-wars.com/news/2026-06-13-zed-deltadb)
- [Jujutsu conflicts and git comparison](https://docs.jj-vcs.dev/latest/technical/conflicts/)
- [Jujutsu operation log](https://docs.jj-vcs.dev/latest/operation-log/) and [working copy](https://docs.jj-vcs.dev/latest/working-copy/)
- [jj run, design doc](https://jj-vcs.github.io/jj/latest/design/run/)
- [git-branchless `git test`](https://github.com/arxanas/git-branchless/wiki/Command:-git-test), the closest prior art to background grading
- [Pijul model](https://pijul.org/model/)
