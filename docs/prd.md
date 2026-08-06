# guardrail: history that knows what worked

Mini PRD. Status: draft. Date: 2026-08-06.

## The claim

Every version control system ever built records **what changed**. None records
**what worked**. guardrail should be the first that does, continuously, with no
commits, no manual test runs, and no keystrokes.

A commit is a bundle whose contents one human chose. That is why `git bisect`
exists: the bundle is too coarse, so you binary search inside it. Replace the
authored boundary with a **verified** one and most of the ceremony disappears,
including the commit itself.

---

## 1. Why now

**The research is settled and twenty-three years old.** Saff and Ernst, 2003:
waiting on tests costs **10 to 15 percent of development time**, and running them
continuously in the background cut that waste by **92 to 98 percent**.

**It never reached a VCS because two things were expensive.** Isolating a run,
which meant executing in the developer's own working directory and fighting them
for the filesystem and build locks, is why every implementation since
(Infinitest, NCrunch, Wallaby) is per language and per runtime. And remembering
an answer, which needs a content hash to key a verdict against.

**guardrail already solved both, for unrelated reasons.** `gr work` clones a
worktree in milliseconds via clonefile and reflink. Every tree is a BLAKE3 hash.
The blocker was infrastructural and this codebase happens to have removed it.

**And agents made it urgent.** DORA 2024: every 25 percent increase in AI
adoption came with a **7.2 percent drop in delivery stability**; DORA 2025 has
throughput finally positive but that stability relationship persisting. 45.2
percent of developers say debugging AI-generated code takes **longer**. Gradle's
data gives the mechanism: the later a failure surfaces, the more changes are
suspects, so **investigation time grows exponentially**. A forty-minute agent run
with the human out of the loop is exactly that case, and it is now ordinary.

**Skipping most of the work is safe.** Google's TAP: **91.3 percent of test
targets never failed once** in their entire history. Meta: **99.9 percent of
regressions caught running a third of the tests**. Aggressive avoidance is what
the two organizations with the most test-execution data concluded independently.

---

## 2. How it works

Nine pieces. The first two are the product; the rest are consequences.

### A. Moments: continuous capture

The worktree is captured continuously. Every captured state is a **moment**: a
content-addressed tree with a stable id, a timestamp, and a cause. Nothing is
ever unsaved, so there is no point at which code "needs" committing.

Sources: the existing 800ms content-signature poll in `watch.zig` (primary, works
for every editor and tool because it watches the filesystem and nothing else),
before every mutating `gr` command, and optionally `agentscan.zig` attribution as
a labelling nicety that nothing may depend on.

`moment-id` = first 8 bytes of `BLAKE3("gr-moment-v1" || branch || tree || ms)`.
Referenced with an `@` sigil so nothing has to guess whether an argument is a
change or a moment. Moments are trees, not changes, so they never appear in
`gr log` and are structurally incapable of becoming commits.

**Cost is where this dies if we are careless**, and two things in the current code
are exactly the wrong shape:

1. `oplog.zig`'s `record` reads the whole log and rewrites it on every append.
   Invisible at op-log volume, **O(n²)** at moment volume. Needs a real `O_APPEND`
   path. `provenance.zig` and `attribution.zig` have the same latent bug.
2. `object.Tree` is a flat list of every path, roughly **700 KB on a 10k-file
   repo**. Edit one file, write a whole new tree. An hour of capture is
   gigabytes. Needs **incremental trees with keyframes**: store a delta against
   the previous tree, write a full tree every 200. A single-file edit becomes
   ~70 bytes.

Losslessness is a **test, not a promise**: every moment also stores the Oid its
full tree would have had, so reconstruction is verified against a hash across 500+
moments spanning keyframes. Mismatch is a hard error, never best-effort recovery.

Config: `moments.enabled`, `interval_ms` (800), `retain` (14d), `max` (10000),
`keyframe_interval` (200).

### B. Verified states: background grading

Take a moment, clone it into a COW worktree in milliseconds, run the project's own
check inside the clone, throw the clone away. The developer's tree is never
touched and their terminal never blocks. States end up `green`, `red`, or
`ungraded`.

**Tiered, because one check command is wrong.** `checks.fast` (typecheck, lint)
runs at quiet points; `checks.full` (the suite) runs at idle or on demand. A
verdict is a vector, and `@green` always **says which tier it answered from**,
because "last state that typechecked" and "last state that passed the suite" are
different claims. If nothing is configured, gr does nothing. No guessing a build
command from the presence of a `package.json`.

**It is a search, not a sweep.** Grading 500 moments would be 500 runs and absurd.
Nobody wants a verdict on every state; they want two boundaries, where it last
worked and where it broke. So:

| Trigger | When | Cost |
| --- | --- | --- |
| Necessary | Head, when the tree goes quiet | Usually free, skipped when the read-set is unchanged |
| On transition | Head flips green to red, binary search back to the breaking state | ~8 runs for a 150-moment gap |
| Opportunistic | Spare budget only, grade the midpoint of the largest ungraded interval | The most informative single run available |

**~30 runs instead of 500, floor around 5.** The third trigger makes the policy
adaptive rather than tuned: idle machine fills history densely, busy machine does
the floor. Nobody configures it because the configuration is "is there spare
capacity right now."

**Never interpolate.** A state between two green states is `ungraded`, not green.
Code is not monotonic, so binary search may find *a* boundary rather than *the
first* one, but every verdict it reports was measured. The UI says "last known
green" and opportunistic grading sharpens it.

### C. The warrant: why a bare green is not enough

An agent that writes both the code and the test has proved only that it agrees
with itself. A boolean cannot express that. Two bad answers: trust it anyway
(shipping a metric an agent trivially satisfies), or point a model at the diff
(crowded, solved, slow, non-deterministic, needs an API key, not a VCS's job).

So a verdict is a claim plus its warrant, on three deterministic axes:

| Axis | Question | Cost |
| --- | --- | --- |
| **independence** | Did the same actor author the code and the check in this span? | Free. `attribution.zig` already knows |
| **relevance** | Did the check process actually open the changed files? | Free. The read-set below already knows |
| **discrimination** | Would the check have failed on the *previous* tree? | One run, only when check files changed, memoized |

```
@a3f91c   green   full   independent   relevance 5/5   discriminating
@8b0d27   green   full   co-authored   relevance 5/5   vacuous
```

Line two is the failure mode, named deterministically in milliseconds with no
model in the loop.

Discrimination is a cheap approximation of mutation testing: rather than
synthesizing mutants, use the one history handed you, which is also the only
mutant that matters for this change. Grounded in Petrović and Just (ICSE 2021) and
*Practical Mutation Testing at Scale*, both of which exist because coverage does
not correlate with real fault detection and mutants do.

**They label, never gate.** Nothing blocks a push or fails a build. A signal
wired to block becomes a target, and an agent optimized against it stops being
signal. And the honest limit: this says nothing about whether the design is good.
It answers a narrower question well, is the green in front of you worth anything.

### D. Speed: five layers of avoidance

The adoption constraint. Numbers we hold ourselves to:

| Operation | Target | Mechanism |
| --- | --- | --- |
| Record a state | < 5ms at 10k files | Stat-cache index, existing |
| Verdict lookup | < 1ms | Memoized by `(tree Oid, check id, command hash)`. A tree is never graded twice, ever |
| Decide whether to grade | < 10ms | Read-set intersection |
| COW clone for a grade | < 200ms at 10k files | clonefile / reflink, existing |
| Independence + relevance | < 10ms | Set intersection over data already computed |
| CPU, idle developer | 0 percent | Nothing to grade, nothing runs |
| CPU, during an agent run | ≤ `checks.budget`, default 25 percent of one core | Enforced ceiling, not an average |
| **Added latency to any interactive command** | **0** | Out of process, holds no lock the CLI needs |

**Layer 2 deserves its own note**, because it keeps guardrail's character of
observing rather than instrumenting: the first time a check runs, run it under
tracing and record **every file the process actually opened**. That read-set is an
exact, empirical dependency list requiring no language plugin, no build system,
and no per-framework adapter. It works identically for `zig build`, pytest, a
Makefile, a shell script. If nothing in the read-set changed, the old verdict
holds and nothing executes. Same trick ccache uses in direct mode, without asking
anyone to adopt Bazel. Where tracing is unavailable, fall back and say so in
`gr doctor` rather than degrading silently.

Layer 4 is enforced, not advisory: `nice`/`ionice`, a battery floor, suspension
under external load. Saff and Ernst's "spare CPU resources" is a constraint here,
not a slogan.

**If `gr status` ever gets slower with grading on, the feature is wrong and gets
reverted.**

### E. Revspecs: addressing states by describing them

You never place a reference point in advance. The `@` sigil already means "a
moment", so extend it into one small grammar that works everywhere a revision is
accepted:

| Ref | Means |
| --- | --- |
| `@` | Current state |
| `@green` / `@red` | Newest green / red moment |
| `@green~1`, `@~3` | Walk back; `~n` composes with any selector |
| `@2h`, `@30m`, `@yesterday` | By time |
| `@a3f91c`, `@save` | By id, or the last explicit save |

```
gr diff @green            gr work ../try-b --at @green~2
gr recap @green..@        gr show @2h
```

Two bare verbs for the operations frequent enough to deserve them:

```
gr back [n]     # rewind n moments, default 1
gr green        # rewind to the last green state
```

`gr green` is the undo-forty-minutes-of-agent-damage button. Nobody should type a
revspec for that.

### F. Rewind

Restores the worktree to any revspec. Before touching anything it captures the
current state as a moment and records the rewind in the op log, so `gr undo`
reverses it and the state you left is still addressable. **Nothing is destroyed**,
which is what makes rewinding something people reach for rather than fear.

Also: `gr rewind <ref> -- <paths>` for the surgical case, `--dry-run`, and an
interactive picker with no argument.

Under B this is a lookup, not a search: the answer is already known, so it costs
one hash lookup and a tree materialization. Where a stretch is ungraded it falls
back to grading on demand, bounded, reporting what it ran.

### G. Branch at a moment

`gr work ../try-b --at @green~2` materializes a COW workspace at any state without
creating a branch, in under 200ms, sharing every unchanged chunk. `gr new <name>
@<moment>` makes it a branch when you decide the fork was worth keeping.

The point is forking **mid-run**: an agent is 40 minutes in, you want the other
approach it considered at minute 12, and no commit exists there. Materialization
reads from the store, never the live worktree, so there is no race with the
running agent by construction.

Because forks are workspaces and B grades workspaces, two attempts at the same
problem get verdicts without anyone running anything.

### H. Superposition: conflicts that halt nothing

A conflict currently stops everything: markers in the worktree are syntactically
invalid in every language, so the tree cannot compile, cannot be graded, cannot be
handed to an agent. Tolerable when merges are rare events. Not tolerable once
forking is free and a conflict is the steady state.

**Three-way merge runs first and is unchanged.** Superposition replaces conflict
markers, not merging. Only paths `merge.zig` cannot reconcile enter it, holding
several **complete, individually valid** whole-file candidates. The worktree
materializes one primary, so it always builds.

```
gr super src/merge.zig
  A  ours    @a3f91c  you          green  full  independent  discriminating
  B  theirs  @8b0d27  claude-code  red    full  build failed
```

Collapse (`gr collapse <path> A`, `--greenest`, or `--edit` to write neither
candidate) is an op-log entry, so `gr undo` reverses it, and the losing blob is
never deleted. Alternatives are **frozen**, not auto-rebased onto a moving
primary, which is the CRDT rabbit hole, and staleness is reported honestly.

Path granularity is a deliberate trade: a candidate must be a file someone
actually wrote, or it is neither independently valid nor gradeable.

Safety: `gr status` always shows superposed paths, `merge.primary` defaults to
`ours` rather than `greenest`, because making evidence the automatic tiebreak on
day one trains people to trust a signal before it earns it, `gr git export` refuses while
anything is superposed, and `merge.max_superposed` caps accumulation.

`merge.superpose = false` restores today's behavior exactly, and defaults false
for existing repos. Off is a supported configuration, not a compatibility shim:
files quietly holding a second value is a real change to the mental model, and
disliking that is a preference, not a misunderstanding.

### I. Recap, commitless flow, git bridge, freshness

**Recap** (`gr recap`, `gr recap @green..`) reports the run as green and red
spans: what landed, how long the tree was broken, what broke it, and thrash
(moments that write a file, change it again, and match neither end). Deterministic
and offline; `--json` pipes into the user's own agent if they want prose.

**Commitless flow** (`flow.cut = green | idle | manual`) cuts a change
automatically on a red-to-green transition. Every change it cuts is verified by
construction. `flow.publish` replicates objects continuously to a git remote under
`refs/gr/`, because we do not need to build a server, every team already has an
always-on object store and it is GitHub. Off by default; code leaving the machine
without an explicit command is a consent problem and gets an explicit prompt.
`gr save` and `gr push` never go away.

**Git bridge**: commits are *rendered* at green boundaries, so **every commit
guardrail exports builds by construction**, which is the property git histories
are always claimed to have and never do. Trailers (`Gr-Verified: full=green fast=green`,
`Gr-Span`, `Gr-Check`) round trip through `gr git import`. A teammate on plain git
sees an ordinary branch and installs nothing. `Gr-Verified` is a hint CI may treat
as an independently verifiable cache key, never an authority.

**Freshness** solves starting work on a stale base without a daemon. Moments
record the remote refs they were captured against, so staleness is a property of
the work rather than an event to notice. Any `gr` command older than
`remote.freshen_ms` (60s) fires a **refs-only** fetch concurrently with its real
work: one round trip, a few hundred bytes, no objects, no hooks, no daemon.

Then `remote.autopull = always`, which git cannot safely offer: an automatic pull
that conflicts leaves markers in your files and your agent starts editing
`<<<<<<<`. Under superposition it **cannot**, so the pull becomes a label instead
of an emergency. It is an op-log entry, so `gr undo` reverses it completely, which
is what makes doing it unasked acceptable. Refused when `merge.superpose = false`.

### J. Live session handoff, the most speculative piece

`gr send --live` streams moments and verdicts over the existing SPAKE2 wormhole;
`gr join` follows into a workspace; `gr note <file>:<line>` sends an annotation
back; `gr handoff` transfers authority. One writer at a time, enforced, the
follower is read-only and forks instead, which is free. Not co-editing, and the
docs say so. Build last, or not at all if nobody asks for it.

---

## 3. What is actually new

Three separate prior-art passes forced three retractions. What is left is narrow,
and narrow is the point.

| | git | Pijul | jj | git-branchless | DeltaDB | **gr** |
| --- | --- | --- | --- | --- | --- | --- |
| Continuous capture, no explicit save | no | no | working-copy auto-snapshot | no | yes (CRDT) | yes |
| Whole-repo undo of any operation | no | no | op log | yes | yes | shipped |
| Stable id surviving rewrites | no | patch identity | change ids | no | delta ids | moments |
| Conflicts as repository state | no | **yes** | **yes** | no | auto-converged | yes |
| Check across revisions, cached | no | no | `jj run` (designed) | **`git test`** | no | yes |
| Binary search for the break | `git bisect` | no | no | **`git test -b`** | no | yes |
| **Grade states nobody committed** | no | no | no | no | no | **yes** |
| **Grade continuously, unprompted** | no | no | no | no | no | **yes** |
| **Verdicts carry a warrant** | no | no | no | no | no | **yes** |
| **Verdicts shape history** | no | no | no | no | no | **yes** |
| **Conflict candidates are graded** | no | no | no | no | no | **yes** |

Read it honestly. **jj** already auto-snapshots the working copy, keeps an op log,
gives changes stable ids that survive rebasing, and commits conflicts as
first-class objects, crediting Darcs and Pijul for the last. **Pijul** got to
conflicts-as-state first with a sounder theory. **git-branchless ships `git
test`**, which runs a command across a revset, out of tree, parallelized, and
**caches the result per commit per command**, with `-b` for binary search. `jj
run` is designed to do the same, citing git-branchless, `hg fix`, and Google's
internal Mercurial.

So: running a check against a state and remembering the answer is not new. Binary
search over history is not new. Conflicts as state is not new. Earlier drafts of
this document claimed all three; all three are withdrawn.

**Four things survive:**

1. **They grade commits. We grade states nobody committed.** A revset is a set of
   human-authored boundaries. Every intermediate state of an agent run is
   invisible to `git test` because those states were never commits. That is the
   whole between-commits thesis, and it is unreachable from a commit-shaped tool.
2. **They run when invoked. We run continuously.** `git bisect` needs you to mark
   good and bad. Here the endpoints come from continuous capture and the search
   fires on a transition nobody noticed yet.
3. **For them a verdict is a cache. For us it is constitutive.** In
   git-branchless it accelerates a search you started. Here it decides where
   boundaries cut, what `@green` resolves to, and which candidate wins. Data
   model, not an accelerator on a subcommand.
4. **Nobody warrants a verdict.** Independence, relevance, discrimination have no
   counterpart anywhere. Every existing tool reports a bare pass or fail.

---

## 4. Common questions

**Why not just use CI?** CI runs on commits, and every intermediate state of an
agent run was never a commit, which is not a speed problem a faster runner fixes but a
domain problem. CI also runs last, which by Gradle's own data is the worst time. And you
could not afford the CI version anyway: 500 states × 5 runner minutes is thousands
of billable minutes to check one hour of work, versus ~30 runs of a warm build on
spare local CPU. CI's verdict is a **notification**, a red X. This one is a **coordinate**, in that
`gr green` restores the tree. And CI has no warrant.

This is not instead of CI. Clean-room repro, multiple platforms, real
integrations, and the authority to gate a merge all belong to CI, and a verdict from someone's
laptop should never have that authority. They compose, and the
composition makes CI cheaper: boundaries cut at green states mean every commit
reaching CI already passed locally.

The analogy that settles it: **CI is to background grading what a CI compile is to
the type checker in your editor.** Nobody argues red squiggles are redundant
because CI would catch it eventually. Inline type checking did not kill CI builds.

One line: *CI answers "is this mergeable." This answers "when did this last work."*

**Why not just use jj?** Use jj. It is excellent, and this borrows its stable-id
design. But jj records what changed. Ask it when your code last worked and it has
no answer, because no VCS has ever stored one. The four rows above are the gap.

**Green is meaningless when the AI writes the tests too.** Correct, which is why
a bare green is never displayed. See the warrant. An agent-written test that only
its own new code satisfies reads as `co-authored` + `vacuous`, deterministically.

**Will this melt my laptop?** Five layers of avoidance, an enforced CPU ceiling
(25 percent of one core), a battery floor, and search-not-sweep meaning ~30 check
runs per 500-moment run. Zero CPU when nothing changed. `checks.enabled = false`
returns to today exactly.

**Will this fill my disk?** Two real bugs in current code are named and fixed in
§2A. Target is under 1 KB of metadata per moment, verified losslessly against the
full-tree hash, plus retention and caps.

**Do I have to give up git?** No. Everything round trips, `gr git export`
materializes a plain git repo at any time, and rendered commits are ordinary
commits that happen to all build.

**Is this a CRDT?** No, and deliberately. That is a different system and it forces
a synchronization service. We cannot do real-time co-editing and the docs say so.

**What if I hate superposition / commitless flow / grading?** Each is one config
key away from today's behavior, and existing repos default to the conservative
setting. Nothing here is a one-way door.

**Does it need my agent's logs?** No. An earlier draft built two features on
parsing agent transcripts and both were cut. Everything works for any tool that
writes files.

---

## 5. Build order

| Phase | Ship | Gate |
| --- | --- | --- |
| 1 | **A. Moments** | Fix the O(n²) append and the O(repo) tree first. Nothing else is possible |
| 2 | **B, C, D. Verified states** + **E, F. Revspecs and rewind** | The thesis, then the payoff a user feels on day one |
| 3 | **G. Fork at a moment**, **Recap**, **Freshness** | Small once A and B exist |
| 4 | **Commitless flow**, **Superposition**, **Git bridge** | Each gated on B proving out in real use; superposition additionally on forking becoming a real workflow |
| 5 | **J. Live session** | Only if asked for |

Non-goals throughout: a CRDT, a hosted product, any agent integration, guessing a
build command, judging code quality, or replacing git.

---

## 6. Top risks

| Risk | Mitigation |
| --- | --- |
| Grading is too slow or too hot | Numeric budgets in §2D, enforced ceiling. Hard rule: if `gr status` slows down, revert |
| Green read as proof of quality | Never rendered as a bare boolean. `co-authored` and `vacuous` are words the user reads |
| Capture writes enormous files | Both causes named in §2A with fixes and a lossless-reconstruction test |
| Binary search lands on a non-first boundary | Every verdict is measured, never inferred. Reported as "last known green" |
| Someone ships the wrong superposition side | Never silent: always in `gr status`, export refuses, primary is a recorded fact |
| Continuous publish sends code off-machine unasked | Off by default, per remote, explicit prompt. A consent problem, not a technical one |
| The whole model is wrong | Every phase opt-in, one key reverts, existing repos default conservative |

---

## Sources

- Saff and Ernst, [Reducing wasted development time via continuous testing](https://homes.cs.washington.edu/~mernst/pubs/wasted-time-issre2003.pdf), ISSRE 2003
- Memon et al., [Taming Google-Scale Continuous Testing](https://research.google.com/pubs/archive/45861.pdf), ICSE-SEIP 2017
- Machalica et al., [Predictive Test Selection](https://arxiv.org/abs/1810.05286)
- Petrović and Just, [Does mutation testing improve testing practices?](https://homes.cs.washington.edu/~rjust/publ/mutation_testing_practices_icse_2021.pdf), ICSE 2021
- [DORA 2024](https://dora.dev/research/2024/dora-report/) and [DORA 2025](https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report)
- Parnin and Rugaber, [Resumption strategies for interrupted programming tasks](http://www.chrisparnin.me/pdf/parnin-sqj11.pdf)
- Gradle, [Quantifying the Costs of Builds](https://gradle.com/blog/quantifying-the-costs-of-builds/)
- [git-branchless `git test`](https://github.com/arxanas/git-branchless/wiki/Command:-git-test) and [jj run design](https://jj-vcs.github.io/jj/latest/design/run/)
- [Jujutsu conflicts](https://docs.jj-vcs.dev/latest/technical/conflicts/) and [Pijul model](https://pijul.org/model/)
- [Zed's DeltaDB announcement](https://zed.dev/blog/introducing-deltadb)
