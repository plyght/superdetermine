# 10. Verified states

Status: draft. This replaces the intent-boundary model in 09 and is the
centerpiece of the plan. Depends on: 03. Supersedes: 01, 02.

## The claim

A version control system should always know the answer to "when did this last
work," and it should know it without the user ever running a test by hand or
authoring a commit.

Not "what did the author intend," which is what a commit message is for and what
01 and 02 tried to recover from agent transcripts. That was the wrong target.
Nobody reviewing a diff at 4pm cares what the agent said at 11am. They care
whether it builds.

## 1. Why, and why it has not been done

### The closest prior art, and what it does not do

Before the argument, the credit. **git-branchless ships `git test`**, which runs a
command across a revset, executes out of tree, parallelizes, and caches the
result per commit per command. **Jujutsu has `jj run` designed** to do the same
across revisions, citing git-branchless, `hg fix`, and Google's internal Mercurial.

So the idea of running a check against a state and remembering the answer is not
new, and this document previously implied it was. Withdrawn.

Three things separate what follows from `git test`, and they are the reason this
is a different feature rather than a reimplementation:

1. **A revset is a set of commits.** Every intermediate state of an agent run was
   never committed, so it cannot appear in a revset and cannot be graded by any
   commit-shaped tool. Grading states that nobody committed is the whole point.
2. **`git test` runs when invoked.** Grading here is continuous and unprompted,
   which is what the research below actually measured.
3. **For `git test` the cached verdict accelerates a search you started.** Here
   the verdict decides where boundaries are cut, what `@green` resolves to, and
   which superposition candidate wins. It is in the data model, not attached to a
   subcommand.

### The research says continuous testing works

This is not a new idea. Saff and Ernst measured it in 2003. Two findings, both
still the best numbers available:

- Waiting on tests and being held up by them costs **10 to 15 percent of
  development time**.
- Continuous testing, meaning tests run automatically in the background as the
  source is edited, **reduced that wasted time by 92 to 98 percent**.

Their framing was that continuous testing "uses spare CPU resources to
continuously run tests in the background." That was 2003 hardware. We have
considerably more spare CPU now and the idea is still not in any version control
system.

### Why it did not spread

Because in 2003 you could not do the two things that make it cheap, and neither
could anyone until recently:

1. **You could not isolate a run.** Continuous testing had to run in the
   developer's actual working directory, so it fought them for the filesystem,
   the build lock, and the ports. Every implementation since, from Infinitest to
   NCrunch to Wallaby, has had to solve this per language and per runtime, which
   is why they are all per language and per runtime.
2. **You could not remember an answer.** Without content addressing there is no
   key to memoize a verdict against, so every run was from scratch, including
   runs of states you had already tested.

guardrail happens to have solved both, for unrelated reasons, before this idea
came up:

| The blocker | What guardrail already has |
| --- | --- |
| Isolating a test run from the developer's tree | `gr work` makes a copy-on-write worktree in milliseconds via APFS clonefile and Linux reflink |
| Memoizing a verdict against a state | Every tree is a BLAKE3 content hash. A verdict keyed by tree Oid is exact, permanent, and free to look up |
| Knowing what changed without rescanning | The stat-cache index in `src/index.zig` skips re-hashing unchanged files |

So the research question is settled and the engineering blocker is already gone
in this codebase specifically. That is the whole argument for building it here.

### Why it matters much more now than in 2003

Agents changed the shape of the problem. Three measurements:

- DORA's 2024 report found that for every 25 percent increase in an
  organization's AI adoption, delivery **stability fell 7.2 percent** and
  throughput fell 1.5 percent. The 2025 report, with AI adoption up from 76 to 90
  percent of developers, found throughput had turned positive but **the negative
  relationship with stability persisted**.
- 45.2 percent of developers surveyed say debugging AI-generated code takes
  **longer** than debugging human-written code.
- Gradle's build-cost work makes the mechanism explicit: the later a failure
  surfaces, the more changes are candidates for having caused it, so
  **investigation time grows exponentially** with the delay.

Put together: agents produce more code, faster, with far more broken
intermediate states, while the human is out of the loop for the whole run. The
failure surfaces late, at the end of a forty minute run, with hundreds of edits
as candidates. That is the exponential case, and it is now the common case.

The tool that would help does not exist. Git will happily tell you what
changed. Nothing will tell you when it last worked.

### Why the boundary should be verified rather than authored

A commit is a bundle whose contents one person chose, which is why bisect exists:
the bundle is too big and you have to binary search inside it. A green-to-green
span is the smallest interval that provably contains the break. It is derived,
not authored, so it costs zero keystrokes, and it is the correct unit for revert,
review, and ship.

And it removes an interruption rather than adding one. Parnin and Rugaber found
that in 10,000 recorded sessions from 86 programmers, **only 10 percent resume
programming within a minute of an interruption**, and interrupted tasks take
roughly twice as long. Stopping to run the suite and waiting is a self-inflicted
interruption, several times an hour.

### Why skipping most of the work is safe

The instinct is that continuous grading means running everything constantly. The
data says the opposite is both possible and standard practice at scale:

- Google's TAP analysis found **91.3 percent of test targets passed at least once
  and never failed even once** across their whole execution history, and only
  **1.23 percent ever caught a breakage**. Almost all test execution is waste.
- Meta's predictive test selection catches **more than 99.9 percent of
  regressions while running about a third of the tests** related to a change.

So aggressive avoidance is not a corner we are cutting to make the feature
viable. It is what the two organizations with the most test-execution data on
earth both concluded independently.

## 2. What it is

Every state in the log carries a verdict. Verdicts are produced by a background
grader that never touches the developer's worktree.

```
gr green                  # the common case: put the tree back where it worked
gr diff @green            # what have I done since it worked
gr work ../b --at @green~2
gr log --verdicts         # history, graded
```

`@green` is part of one revspec grammar specified in [05](05-rewind.md), which
composes across every command that takes a revision. There is no `last-green`
string and no `--to-last-good` flag.

### Tiered checks

A single `checks.cmd` is wrong, because a 90 second test suite cannot run at
every quiet point and a 200ms typecheck can. So a verdict is a vector, not a
boolean:

| Tier | Config | Typical | Cadence |
| --- | --- | --- | --- |
| `fast` | `checks.fast` | compile, typecheck, lint | Every quiet point |
| `full` | `checks.full` | the test suite | Idle, or on demand, or before a boundary is rendered to git |

A state is `green` at a tier, `red` at a tier, or `ungraded`. `@green` resolves
against the strongest tier that has an answer and **says which tier it used**, because "last state that typechecked" and "last state that passed the
suite" are different claims and conflating them would be dishonest.

If the user configures nothing, gr does nothing. No inference of build commands
from the presence of a `package.json`, because guessing wrong here means running
an arbitrary command the user did not ask for.

### Green is not enough, and a boolean cannot say why

The obvious objection, and the correct one: an agent writes the code, writes the
test, the test passes. Green means the agent agreed with itself. A tree can
compile cleanly, pass a suite, and still be bad work.

There are two bad answers to this. One is to trust the boolean anyway, which
means shipping a metric the agent can trivially satisfy. The other is to point a
model at the diff and ask if it is good, which is a solved and crowded problem,
costs an API key, is not fast, is not deterministic, and is not a version control
system's job.

The middle ground is to stop treating a verdict as a boolean and start treating
it as **a claim with a provenance**. Three properties, all computed
deterministically, none requiring a model, and two of them free because we are
already computing the inputs for other reasons.

#### Independence: who wrote the check

`src/attribution.zig` already records, per file, whether a human or an agent
authored it, with confidence. So for any verdict we can ask whether the code and
the check that blessed it were authored by the same actor within the same span.

| Independence | Meaning |
| --- | --- |
| `independent` | Source changed, check files did not, and the check is human-authored. The strongest green available |
| `co-authored` | The same agent touched both the source and the check in this span. Self-certification, and the user should see the word |
| `unattributed` | No attribution data. Say so rather than assuming either way |

This costs nothing. The data is already in the repo and the join is a set
intersection.

#### Relevance: did the check touch what changed

Layer 2 below records the exact set of files a check reads while it runs. That
same read-set answers a question coverage tools normally charge a lot for: **did
anything the check executed actually read the file you changed?**

If the check ran green but never opened `src/merge.zig`, then green says nothing
whatsoever about the change to `src/merge.zig`. That is a common and completely
invisible failure today, and here it falls out of a mechanism we are building
anyway.

Reported as a fraction: `relevance 2/5 changed files exercised`.

#### Discrimination: would the check have failed before

The strongest signal and the only one that costs a run. A test that passes on the
code from *before* your change is not testing your change.

gr can check this and almost nothing else can, because gr has every prior state
content-addressed and can materialize one into a COW clone in milliseconds. When
a span adds or modifies check files, run the new check against the previous
tree:

- Check fails on the old tree, passes on the new one: it **discriminates**. It is
  a real test of this change.
- Check passes on both: it is **vacuous** with respect to this change. It may
  still be a fine test of something else, but it did not earn the green you are
  about to trust.

This is a cheap approximation of mutation testing that skips the expensive part.
Instead of synthesizing mutants, use the mutant history already gave you. One
extra run, only when check files changed, memoized by tree hash like everything
else so it never repeats.

The research supports the substitution. Mutation analysis is the standard for
evaluating whether a test suite is actually any good, because seeded faults are
empirically coupled to real ones, while **coverage is not**: a line can be
executed with no assertion checking its behavior, and the suite still reports
green. Google's mutation testing work, deployed across their codebase, exists
precisely because coverage was not telling them what they needed. Full mutation
testing is far too slow to run continuously. Discrimination against the previous
tree is one mutant, chosen for free, and it is exactly the mutant that matters
for the change in front of you.

For the failure mode that prompted this, an agent writing a test that only its
own new code satisfies and that never fails on anything, `vacuous` plus
`co-authored` names it exactly, deterministically, in milliseconds.

#### What this produces

A verdict reads as a claim and its warrant:

```
@a3f91c   green   full     independent   relevance 5/5   discriminating
@8b0d27   green   full     co-authored   relevance 5/5   vacuous
@41c8ea   green   fast     unattributed  relevance 0/3   n/a
```

The second line is the case the user was worried about, surfaced as text, with no
model involved.

#### It labels, it does not block

Nothing here refuses an operation, fails a build, or gates a push. It is a
routing signal: it tells a reviewer with forty minutes of agent output in front
of them **where to spend their attention**, which is the actual scarce resource.
Turning any of this into a gate would make it a metric, and a metric an agent is
optimized against stops being a signal.

And the honest boundary: this says nothing about whether the design is good, the
abstraction is right, or the code is worth keeping. It cannot and it should not
pretend to. It answers a narrower question well, which is whether the green in
front of you is worth anything.

## 3. Making it fast

This is the part that decides whether anyone uses it. The design is five layers
of avoidance, in order of how much work they save.

### Layer 0: capture is already cheap

Recording a state costs a `stat` per file plus a hash of only what changed,
because `src/index.zig` caches by mtime, size, and inode. Budget: **under 5ms on
a 10,000 file repo**. This is existing code and existing behavior, not new cost.

### Layer 1: memoize the verdict against the tree hash

A verdict is keyed by `(tree Oid, check id, check command hash)`. The same tree
never gets graded twice, ever, across restarts, branches, workspaces, rewinds, or
machines.

This is worth far more under agents than it would have been in 2003, because
agents thrash. Write, run, revert, rewrite, revert again. Every state an agent
returns to is a state we have already graded, and it costs one hash lookup. A
rewind to `@green` followed by a re-run of the check is free by construction.

Budget: **under 1ms**, one hash and one file read.

### Layer 2: skip on read-set, and learn the read-set by watching

The strongest layer, and the one that keeps guardrail's character of observing
rather than instrumenting.

The first time a check runs, run it under tracing and record **every file the
check process actually read**. That read-set is an exact, empirical dependency
list. It requires no language plugin, no build system integration, and no
per-framework adapter, and it works for a Zig build, a pytest run, a Makefile,
and a shell script equally.

On the next state: if no file in the recorded read-set changed, the previous
verdict still holds. Do not run anything.

For an agent editing one file in a large repo, this means the overwhelming
majority of states are answered without executing a single command. It is the
same mechanism ccache uses in direct mode and that Bazel gets from sandboxing,
obtained without asking the user to adopt a build system.

Implementation: `ptrace` or an `LD_PRELOAD` shim on Linux, and the same trick via
`DYLD_INSERT_LIBRARIES` on macOS. Where tracing is unavailable or refused, fall
back to layer 3 alone and say so in `gr doctor`, rather than silently degrading.

### Layer 3: grade the transition, not the timeline

The layer that decides how much work there is at all, and the one where the naive
design is badly wrong.

Grading every captured state is a **sweep**: 500 moments in a run means 500 check
runs, which is absurd and would make the feature unusable. But sweeping was never
necessary, because the thing anyone actually wants is not a verdict on every
state. It is two answers:

- Where is the newest green state, so `@green` resolves correctly.
- Where exactly did it break, so the red span in `gr recap` is accurate.

Both are **boundaries**, and finding a boundary is a search, not a sweep. If the
state 500 moments ago was green and the current one is red, the transition is
findable in about nine runs instead of five hundred.

Prior art, credited: `git test --search binary` in git-branchless already bisects
over a revset with caching and speculative parallel jobs, `git bisect run`
automates the same thing on demand, and nightly suites that launch a bisect on
regression are long-standing practice. Binary search over history is not the new
part. What is new is the **trigger and the domain**: it fires automatically,
nobody invokes it, the endpoints come from continuous capture rather than from a
human marking good and bad, and it searches states that were never committed and
therefore cannot appear in any revset.

Three trigger classes, in order of obligation:

**1. Necessary: grade the head, at rest.** When the tree goes quiet, meaning
`checks.quiet_ms` with no writes, grade the current state. This is the only
mandatory grade and it answers "does it work right now."

Even this is usually free. If nothing in the check's recorded read-set changed
since the last grade, layer 2 carries the previous verdict forward and nothing
runs. For an agent editing one subsystem, most quiet points cost nothing.

**2. On transition: localize by binary search.** When the head flips from green to
red, the interesting question becomes which state broke it. Search between the
last known green and now, halving each time, memoizing every result.

For a gap of 150 moments that is about 8 runs, and it produces something no other
tool has at all: the exact state that broke the build, found automatically,
without anyone noticing the breakage or invoking anything.

**3. Opportunistic: fill the largest gap.** With budget left over and the machine
otherwise idle, grade the **midpoint of the largest ungraded interval**. That is
the single run with the most information in it, because it halves the biggest
unknown. Repeat while there is spare capacity.

This is what makes the policy adaptive rather than fixed. On an idle machine the
history fills in densely and you get a lot of testing, which is the point. On a
busy machine it does the floor only: keep `@green` correct, localize breakages,
nothing else. The user never has to tune this, because the tuning is
"is there spare capacity right now."

**Never interpolate.** A state between two green states is `ungraded`, not green.
Verdicts are facts about states that were actually run, never inferences from
neighbours. That rule is what makes the search safe to be incomplete: code is not
monotonic, it can go red then green then red inside one run, so binary search may
land on *a* boundary rather than *the first* one. Every answer it gives is still
literally true, because it was measured. So the UI says **"last known green"**,
refinement sharpens it over time, and nothing ever claims more than it ran.

**What it costs.** A 500 moment run with three breakages:

| Policy | Check runs |
| --- | --- |
| Sweep every moment | 500 |
| Necessary only | ~15 idle points, most skipped by read-set, so ~5 |
| Plus localization | 3 breakages x ~8 = 24 |
| Plus opportunistic, within budget | whatever fits |

Roughly **30 runs instead of 500**, with the floor being about 5, and the extra
spent only when the machine has nothing better to do.

**Debounce and supersede**, which still apply on top:

- If a new state arrives while a grade is running, that grade is now grading
  history. **Kill it** unless it is past `checks.finish_threshold` of its
  historical duration, in which case let it finish, because a nearly done run is
  a memo entry worth having.
- Never queue more than one pending grade per tier. A queue means you are grading
  states nobody will ever ask about.
- `gr green` when the answer is unknown runs the search on demand, bounded and
  with visible progress, rather than reporting nothing.

### Layer 4: stay out of the way

- The grader runs at low priority: `nice` and `ionice` on Linux, the equivalent
  QoS class on macOS.
- Hard ceiling via `checks.budget`, a fraction of one core, default 25 percent.
- Suspended on battery below `checks.battery_floor`, default 30 percent, and
  suspended entirely when the machine is under external load above a threshold.
- Runs in a COW clone under a scratch directory, never in the user's tree. No
  contention for build locks, ports, or output directories.

Saff and Ernst's phrase was "spare CPU resources." That is a real constraint,
not a slogan, and it is enforced rather than hoped for.

### Layer 5: bound the blast radius

- One background process, lazily started, single static binary, no daemon to
  install and no runtime dependency.
- Killing it at any moment costs nothing. The log is already on disk and grading
  is a pure memoized side effect, so there is no partial state to recover.
- `checks.enabled = false` returns the tool to exactly its current behavior and
  its current cost.

### The budget, stated as numbers to hold ourselves to

| Operation | Target | Why it is achievable |
| --- | --- | --- |
| Record a state | < 5ms at 10k files | Stat-cache index, existing |
| Independence and relevance | < 10ms | Set intersection over attribution and the read-set, both already computed |
| Discrimination | One extra check run | Only when check files changed in the span, memoized so it never repeats |
| Verdict lookup | < 1ms | One BLAKE3 and one read |
| Decide whether a grade is needed | < 10ms | Read-set intersection against changed paths |
| COW clone for a grade | < 200ms at 10k files | clonefile / reflink, existing `gr work` |
| Steady-state CPU with an idle developer | 0 percent | Nothing to grade means nothing runs |
| Steady-state CPU during an agent run | <= `checks.budget`, default 25 percent of one core | Enforced ceiling, not an average |
| Check runs per 500 moment agent run | ~30, floor ~5 | Search the transitions, never sweep the timeline. Layer 3 |
| Added latency to any interactive `gr` command | 0 | The grader is out of process and never holds a lock the CLI needs |

The last row is the one that matters most for adoption. If `gr status` ever gets
slower because grading is on, the feature is wrong and should be reverted.

## 4. What this replaces

| Was | Now |
| --- | --- |
| 01 conversation objects | Cut. Six brittle adapters to recover a one-line prompt |
| 02 trace | Cut. Follows 01 |
| 09's intent boundaries, cut at human turns in a transcript | Verified boundaries, cut at green-to-green spans. Universal, no agent integration |
| 07 recap grouped by intent | Recap grouped by verified span, with the red stretches in between shown as what they were |
| 08's conversation notes in git | Dropped. The trailers and rendered-commit half stay, and every rendered commit is green by construction |

`provenance.zig`, `attribution.zig`, `gr why`, and `gr blame` are untouched and
keep working. We are not building a system on top of them.

## 5. Out of scope

- Guessing the user's check command. Configure it or the feature is off.
- Per-test granularity in v1. Grading is per check, whole suite. Per-test needs
  the runner's cooperation and is per language, which is exactly the trap that
  killed 01.
- Full mutation testing. Discrimination is one mutant, taken from history for
  free. Synthesizing mutants is orders of magnitude more expensive and belongs in
  a dedicated tool, not in a VCS's background budget.
- Any judgment about design, architecture, or whether the code is worth keeping.
  Not computable without a model, and pointing a model at a diff is a crowded
  solved problem that is not this tool's job.
- Gating. Nothing here blocks a push, fails a build, or refuses an operation. The
  moment a signal becomes a gate, it becomes a target, and an agent optimized
  against it stops producing signal.
- Running checks on a remote or in CI. Local, spare capacity, that is it.
- Automatically reverting on red. Deciding to throw away work stays human.

## 6. Success criteria

1. On an agent run of 50+ edits with a check of ~2 seconds, the total CPU spent
   grading is under 10 percent of the run's wall clock, measured.
2. Read-set skipping avoids execution for at least 80 percent of captured states
   on a repo where the agent is editing one subsystem.
8. A 500 moment run with three breakages costs under 40 check runs at default
   budget, and `@green` is correct throughout, measured against a sweep of the
   same run as ground truth.
9. No state is ever reported green or red without a recorded run that produced
   that verdict. Verified by asserting every non-`ungraded` verdict has a
   corresponding execution record.
3. Memo hit rate above 30 percent on a real agent run, because agents revisit
   states. Measured and reported, since this is the number the whole design bets
   on.
4. `@green` is correct on a seeded repo with a known break, at both tiers, and
   names the tier it answered from.
5. On a seeded repo where an agent writes both the code and a test that passes on
   the pre-change tree, the verdict reports `co-authored` and `vacuous`. This is
   the case the whole trust model exists for and it gets a fixture.
6. A green verdict from a check that never opened the changed file reports
   `relevance 0/N` rather than a bare green.
5. `gr status` latency is unchanged with grading on, within noise.
6. Killing the grader mid-run leaves no partial state and no lost verdicts.
7. With `checks.enabled = false`, CPU, disk, and latency are identical to today.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| Green is treated as proof of quality when it is only proof of agreement | Verdicts are never rendered as a bare boolean. Independence, relevance, and discrimination print alongside, and `co-authored` is a word the user reads rather than a flag they have to go looking for |
| Trust dimensions get gamed once people know about them | They label rather than gate, so there is no threshold to optimize against. If any of them is later wired to block something, that decision should be revisited against this row |
| Discrimination is wrong for tests that legitimately pass on old code | Correct and expected. A regression guard added alongside unrelated work is vacuous *with respect to that change* and the wording says so. It is a statement about this span, not a judgment of the test |
| Binary search lands on the wrong boundary because code is not monotonic | Every verdict is measured, never inferred, so a wrong *boundary* still consists of true *verdicts*. Reported as "last known green" and refined opportunistically. The alternative, interpolating, would be fast and dishonest |
| Opportunistic grading is perceived as the tool burning CPU for no reason | It only runs inside `checks.budget` on an otherwise idle machine, and `gr status` can show what it is doing. Setting the budget to zero leaves only the necessary floor |
| A slow or flaky suite makes continuous grading useless | Tiering. `checks.fast` carries the interactive experience, `checks.full` runs at idle. A flaky check poisons the memo, so a verdict records the check's exit code and duration, and `gr doctor` flags checks whose verdict flips on an identical tree hash, which is the definition of flaky and worth surfacing anyway |
| Read-set tracing is unavailable or blocked by a hardened environment | Detect and fall back to layer 3, report it in `gr doctor`. Never pretend to a precision we do not have |
| A check with side effects runs constantly, hitting a network or a database | The COW clone is isolated for the filesystem but not for the network. Off by default, and the first-run prompt states plainly that the command will be executed repeatedly |
| Laptop heat and battery | Layer 4 is enforced, not advisory, and the battery floor defaults on |
| The memo grows without bound | A verdict is a few dozen bytes keyed by a hash, and the read-set is chunked and deduped in the existing store. `gr gc` collects verdicts for unreachable trees |

## Sources

- Saff and Ernst, [Reducing wasted development time via continuous testing](https://homes.cs.washington.edu/~mernst/pubs/wasted-time-issre2003.pdf), ISSRE 2003
- Saff and Ernst, [Continuous Testing in Eclipse](https://www.sciencedirect.com/science/article/pii/S1571066104051941)
- Petrović and Just, [Does mutation testing improve testing practices?](https://homes.cs.washington.edu/~rjust/publ/mutation_testing_practices_icse_2021.pdf), ICSE 2021, Google's deployment
- [Practical Mutation Testing at Scale](https://arxiv.org/pdf/2102.11378)
- Memon et al., [Taming Google-Scale Continuous Testing](https://research.google.com/pubs/archive/45861.pdf), ICSE-SEIP 2017
- Machalica et al., [Predictive Test Selection](https://arxiv.org/abs/1810.05286), and the [engineering write-up](https://engineering.fb.com/2018/11/21/developer-tools/predictive-test-selection/)
- [DORA Accelerate State of DevOps 2024](https://dora.dev/research/2024/dora-report/) and the [2025 report](https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report)
- Parnin and Rugaber, [Resumption strategies for interrupted programming tasks](http://www.chrisparnin.me/pdf/parnin-sqj11.pdf)
- Gradle, [Quantifying the Costs of Builds](https://gradle.com/blog/quantifying-the-costs-of-builds/)
- [git-branchless `git test`](https://github.com/arxanas/git-branchless/wiki/Command:-git-test), the closest prior art
- [jj run, design doc](https://jj-vcs.github.io/jj/latest/design/run/)
- [Industry survey on debugging AI-generated code](https://syn-cause.com/blog/debug-time-increased)
