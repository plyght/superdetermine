# 09. Commitless flow

Status: draft. Phase 4, gated on 03 and 10 proving out in real use. Depends on:
03, 10. Blocks: nothing, but changes the default posture of the whole tool.

## The idea

Stop making the user author commits and stop making them push. Work is recorded
as it happens and published as it happens. Commits still exist, but they are
*derived* at the boundary where the outside world needs one, instead of being
the unit you work in.

This is the most interesting thing in DeltaDB's pitch and it is worth taking
seriously rather than treating as marketing. It is also the one that most
changes what guardrail feels like to use.

## Why this is less radical for gr than it sounds

guardrail has already deleted half of the ceremony. From the README: no staging
area, no stash, the working copy is always a change, and `gr save` is one step
with no index to curate. `gr watch` already auto-saves on every change. The op
log already makes any state recoverable, so the usual reason to commit
defensively, which is fear of losing work, is already gone.

What remains of the ceremony is two decisions the user still has to make:

1. **When is this a unit?** Answered today by running `gr save`.
2. **When does anyone else see it?** Answered today by running `gr push`.

Commitless flow automates both, and the argument for why that is safe is that
moments (03) already make the first one recoverable after the fact. You do not
need to decide the boundary in advance if you can draw it later over a complete
record.

## What commits actually buy, and what to do about each

Removing commits entirely is not possible, because several things genuinely
depend on them. Being specific about which is the whole design.

| What a commit provides | Can it be automated | How |
| --- | --- | --- |
| A durable snapshot so work is not lost | Yes, already | Moments (03). Capture is continuous and content addressed |
| A named unit for review | Yes | A verified span from 10 is a better boundary than a manual save, because it is bounded by states that provably worked rather than by whoever remembered to type `gr save` |
| A stable ref for CI to build | Yes | Auto-cut a change at each green boundary. CI gets a real ref, the user never typed anything, and the ref is already known to build |
| A unit for git interop | Yes | Derived at export. `gr git export` already synthesizes commits from changes; it synthesizes them from green boundaries instead |
| A unit to revert | Already better | `gr undo`, `gr revert`, and `gr rewind` (05) all operate without needing the user to have chosen a boundary in advance |
| A point to bisect | Mostly removes the need | A green-to-green span is the smallest interval that provably contains the break, so the bisect is already done. Moments give finer resolution inside a span |

Nothing on that list requires the user to author the boundary. Every one of them
requires a boundary to *exist*, which is a different claim, and one we can
satisfy by cutting boundaries automatically from the record.

## Design

### Capture is continuous

Moments, always on, from 03. No user action. This is the part that has to be
solid before any of the rest ships, which is why this PRD is gated on 03 proving
out in real use rather than just passing tests.

### Boundaries are cut, not authored

A change is created automatically when the tree transitions from red to green,
which is to say when the work starts working again.

```
flow.cut = green           # green | idle | manual
flow.idle_ms = 120000
```

`green` is the default and the interesting one. Every change it cuts is verified
by construction, so a history produced this way has the property that git
histories are always claimed to have and never do: every commit builds.

`idle` cuts after a quiet period regardless of verdict, for projects with no
check configured. `manual` is today's behavior.

An auto-cut change is titled from the files and the span, for example
`merge: 3 files, green after 6m red`. That is a worse sentence than a careful
human would write and a better one than most people actually write at the end of
an hour. `gr describe` already exists to retitle, so correcting it is one command
and is expected to be normal rather than exceptional.

### Publishing is continuous

This is the half that has no precedent in guardrail and is the real new work.

A background sync replicates new objects to configured destinations as they land.
Because the store is content addressed and objects are immutable, replication is
pure object copy with no merge, no rebase, and no conflict. That is a much
simpler problem than git push, and it is simple precisely because of choices
already made in `src/store.zig`.

Destinations, in order of practicality:

1. **A git remote.** The important realization: we do not have to build a server,
   because every team already has an always-on object store, and it is GitHub.
   Continuous publish to a git remote pushes to a shadow ref namespace,
   `refs/gr/moments/<branch>`, which is invisible to normal git users and does not
   touch `refs/heads`. The real branch is updated only at cut boundaries. So a
   teammate on plain git sees clean commits at green boundaries, and a teammate
   on guardrail can fetch the full moment stream.
2. **LAN peers.** Discovery already exists in `src/discovery.zig`. A peer on the
   same network gets the stream directly with no round trip to a remote.
3. **A live session.** 06, for the deliberate handoff case.

```
flow.publish = off | remote | peers | both
flow.publish_interval_ms = 5000
```

Off by default on first release. Continuous publish is the setting with the
largest blast radius in this whole plan, because it means code leaves the machine
without an explicit command, and that has to be an informed choice with a clear
prompt, not a default someone discovers later.

### What the user does instead

| Before | After |
| --- | --- |
| `gr save -m "fix merge"` | Nothing. The tree going green cuts it |
| `gr push` | Nothing. Objects are already there |
| `gr status` to see what is uncommitted | `gr status` shows the live position in the stream and what has been published |
| Open a PR to show someone | `gr send --live`, or the branch is already visible |
| `git log` to see what happened | `gr recap` |

`gr save` and `gr push` do not go away. They stay as the explicit override for
when you want a boundary right now, and they are what `flow.cut = manual`
restores. Nothing here is a one way door.

## Migration path

Three stages, each shippable alone, each reversible with one config key. This
matters because guardrail's core promise is that adopting it is reversible, and
a flow change is the easiest place to accidentally break that promise.

**Stage 1: opt in, capture only.** `flow.cut = green`, publish off. The user
stops typing `gr save`. Everything else is unchanged, git interop is unchanged,
and turning it off returns to exactly today's behavior. This is small and mostly
falls out of 03 and 10.

**Stage 2: opt in publishing.** `flow.publish = remote`. Shadow refs, background
replication, and a `gr status` that reports publish state. The bulk of the new
engineering is here, in a new `src/flow.zig` plus additions to `src/git.zig` for
the shadow ref namespace.

**Stage 3: default for new repos.** Only after stages 1 and 2 have been in real
use long enough to trust, and only with a first run prompt that states plainly
what continuous publish means. Existing repos keep their setting and are never
migrated silently.

There is a real chance stage 3 never happens and that is an acceptable outcome.
The value is in stages 1 and 2 being available, not in forcing them on anyone.

## Why this is not a copy of theirs

They get continuous flow from a CRDT synchronizing through their service, which
is what lets several people edit the same file at once. We get it from immutable
content addressed objects replicated to a store that already exists, which is
much less machinery and yields single writer semantics.

The trade is explicit. They can do real time co-editing and need a service. We
cannot co-edit and need nothing, and our stream lands in the git remote the team
already has, visible to people who never install guardrail. For a tool whose
pitch is that adopting it is reversible, that is the right side of the trade.

## Out of scope

- Removing `gr save` and `gr push`. They stay, permanently, as the explicit path.
- Continuous publish as a default in v1. See stage 3.
- Automatic conflict resolution across concurrent writers. Single writer per
  branch, same as 06. Forking is free and merging is `gr merge`.
- Publishing to a remote the user has not explicitly configured for it.

## Success criteria

1. A full agent run with `flow.cut = green` produces changes at the same
   boundaries a careful human would have chosen, evaluated by hand on ten real
   runs, and every resulting change passes its check when rebuilt from scratch.
2. A teammate using only git sees a normal branch with clean commits and no
   shadow refs in their default fetch.
3. Continuous publish keeps a remote within `flow.publish_interval_ms` of local
   state over a one hour run, measured.
4. Killing the process mid-publish never leaves a remote with a partial tree,
   because objects are pushed before refs, always.
5. Setting `flow.cut = manual` and `flow.publish = off` reproduces today's
   behavior exactly, verified by test.
6. Bandwidth for a one hour run is measured and reported, because continuous
   publish on a metered connection is a real concern.

## Risks

| Risk | Mitigation |
| --- | --- |
| Code leaves the machine without an explicit command | Off by default, explicit opt in with a plain statement of what it means, per remote. `gr status` always shows publish state. This is the biggest risk in this document and it is a consent problem, not a technical one |
| Auto-cut boundaries are bad and history becomes noise | `flow.cut` is configurable, `gr describe` retitles, and squashing a range stays available. Also, the fallback of `manual` is always one key away |
| Shadow refs confuse teams or bloat the remote | Namespaced under `refs/gr/`, excluded from default fetch, and covered by retention so the moment stream on the remote ages out like the local one |
| Secrets published continuously before anyone notices | Sealed values are already never plaintext objects, `.grignore` is respected, and 01's redaction applies. Publish additionally refuses to start in a repo with unsealed `.env` present unless forced |
| The whole model is wrong and users hate it | It is opt in through stages 1 and 2, and one config key reverts. That is the point of the staging |
