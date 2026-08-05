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
gr at last-green              # resolve to the newest verified-good state
gr at green-before-red        # the last good state before the current breakage
gr diff last-green            # what have I done since it worked
gr rewind last-green          # put the tree back there
gr log --verdicts             # history, graded
```

### Tiered checks

A single `checks.cmd` is wrong, because a 90 second test suite cannot run at
every quiet point and a 200ms typecheck can. So a verdict is a vector, not a
boolean:

| Tier | Config | Typical | Cadence |
| --- | --- | --- | --- |
| `fast` | `checks.fast` | compile, typecheck, lint | Every quiet point |
| `full` | `checks.full` | the test suite | Idle, or on demand, or before a boundary is rendered to git |

A state is `green` at a tier, `red` at a tier, or `ungraded`. `gr at last-green`
resolves against the strongest tier that has an answer and **says which tier it
used**, because "last state that typechecked" and "last state that passed the
suite" are different claims and conflating them would be dishonest.

If the user configures nothing, gr does nothing. No inference of build commands
from the presence of a `package.json`, because guessing wrong here means running
an arbitrary command the user did not ask for.

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
rewind to `last-green` followed by a re-run of the check is free by construction.

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

### Layer 3: debounce, coalesce, supersede

- Grade at **quiet points**, not at every state. A quiet point is
  `checks.quiet_ms` of no writes, default 400ms for fast and 3000ms for full.
- If a new state arrives while a grade is running, that grade is now grading
  history. **Kill it** unless it is past `checks.finish_threshold` of its
  historical duration, in which case let it finish, because a nearly done run is
  a memo entry worth having.
- Never queue more than one pending grade per tier. A queue means you are grading
  states nobody will ever ask about.

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
| Verdict lookup | < 1ms | One BLAKE3 and one read |
| Decide whether a grade is needed | < 10ms | Read-set intersection against changed paths |
| COW clone for a grade | < 200ms at 10k files | clonefile / reflink, existing `gr work` |
| Steady-state CPU with an idle developer | 0 percent | Nothing to grade means nothing runs |
| Steady-state CPU during an agent run | <= `checks.budget`, default 25 percent of one core | Enforced ceiling, not an average |
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
- Running checks on a remote or in CI. Local, spare capacity, that is it.
- Automatically reverting on red. Deciding to throw away work stays human.

## 6. Success criteria

1. On an agent run of 50+ edits with a check of ~2 seconds, the total CPU spent
   grading is under 10 percent of the run's wall clock, measured.
2. Read-set skipping avoids execution for at least 80 percent of captured states
   on a repo where the agent is editing one subsystem.
3. Memo hit rate above 30 percent on a real agent run, because agents revisit
   states. Measured and reported, since this is the number the whole design bets
   on.
4. `gr at last-green` is correct on a seeded repo with a known break, at both
   tiers, and names the tier it answered from.
5. `gr status` latency is unchanged with grading on, within noise.
6. Killing the grader mid-run leaves no partial state and no lost verdicts.
7. With `checks.enabled = false`, CPU, disk, and latency are identical to today.

## 7. Risks

| Risk | Mitigation |
| --- | --- |
| A slow or flaky suite makes continuous grading useless | Tiering. `checks.fast` carries the interactive experience, `checks.full` runs at idle. A flaky check poisons the memo, so a verdict records the check's exit code and duration, and `gr doctor` flags checks whose verdict flips on an identical tree hash, which is the definition of flaky and worth surfacing anyway |
| Read-set tracing is unavailable or blocked by a hardened environment | Detect and fall back to layer 3, report it in `gr doctor`. Never pretend to a precision we do not have |
| A check with side effects runs constantly, hitting a network or a database | The COW clone is isolated for the filesystem but not for the network. Off by default, and the first-run prompt states plainly that the command will be executed repeatedly |
| Laptop heat and battery | Layer 4 is enforced, not advisory, and the battery floor defaults on |
| The memo grows without bound | A verdict is a few dozen bytes keyed by a hash, and the read-set is chunked and deduped in the existing store. `gr gc` collects verdicts for unreachable trees |

## Sources

- Saff and Ernst, [Reducing wasted development time via continuous testing](https://homes.cs.washington.edu/~mernst/pubs/wasted-time-issre2003.pdf), ISSRE 2003
- Saff and Ernst, [Continuous Testing in Eclipse](https://www.sciencedirect.com/science/article/pii/S1571066104051941)
- Memon et al., [Taming Google-Scale Continuous Testing](https://research.google.com/pubs/archive/45861.pdf), ICSE-SEIP 2017
- Machalica et al., [Predictive Test Selection](https://arxiv.org/abs/1810.05286), and the [engineering write-up](https://engineering.fb.com/2018/11/21/developer-tools/predictive-test-selection/)
- [DORA Accelerate State of DevOps 2024](https://dora.dev/research/2024/dora-report/) and the [2025 report](https://cloud.google.com/blog/products/ai-machine-learning/announcing-the-2025-dora-report)
- Parnin and Rugaber, [Resumption strategies for interrupted programming tasks](http://www.chrisparnin.me/pdf/parnin-sqj11.pdf)
- Gradle, [Quantifying the Costs of Builds](https://gradle.com/blog/quantifying-the-costs-of-builds/)
- [Industry survey on debugging AI-generated code](https://syn-cause.com/blog/debug-time-increased)
