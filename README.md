# superdetermine (`sdt`)

A version control system that remembers which states of your code actually worked.

`sdt` grades your code. It runs the project's own check against a state, in a throwaway clone, and records the result. `sdt green` then returns the last state that passed.

For that to be useful, the states have to exist. So `sdt` captures your working tree continuously from `sdt init`. There is no staging area and no stash. You never run `save` to keep your work safe.

`sdt` runs beside git and pushes to GitHub. You can adopt it one step at a time.

## Why

Every version control system records what changed. No version control system records what worked. This is why `git bisect` exists. A commit is too large a unit to answer the question. You must search inside one commit after the failure.

Agents make this worse. A forty-minute agent run makes hundreds of intermediate states. None of these states is a commit. A failure that appears late has more states to blame.

Continuous capture gives you an address for each state. Grading gives you an answer for each state.

`sdt` also removes friction that git keeps. There is no staging area to manage. You do not stash to change branch. A reset does not destroy work. Binary files do not need a separate tool.

## Features

| Feature | What it gives you |
| --- | --- |
| **Verified history** | `sdt` runs your check against a captured state in a clone it then deletes. `sdt green` rewinds to the last state that passed. |
| **Warranted verdicts** | Each green result names who wrote the code and the check. It also names which changed files the check read. |
| **Continuous capture** | Starts at `sdt init`. `sdt` keeps every state of the tree as a *moment*. Each moment costs less than one kilobyte. You never type `save` to stay safe. |
| Content-addressed store (BLAKE3 + FastCDC) | Large files and binaries are first-class, deduped at the chunk level. No LFS. |
| Working copy is always a change | There is no staging area and no stash. `sdt save` names a boundary. It is not how `sdt` keeps your work. |
| Operation log | `sdt undo` and `sdt redo` across the whole repo. Nothing gets lost. |
| Instant copy-on-write worktrees | `sdt work <dir>` spins up a workspace in milliseconds (APFS clonefile, Linux reflink). |
| Stat-cache index | `status` and `save` skip re-hashing unchanged files (mtime/size/inode). |
| Three-way merge + resolve | Conflict markers, then `sdt resolve <file>` / `sdt resolve --abort`. |
| Absorb | `sdt absorb` folds working edits into the changes they belong to. |
| Garbage collection | `sdt gc` reclaims space from unreachable objects (`--dry-run` to preview). |
| Prompt provenance (opt-in) | Record which agent or prompt produced a change, stored in the repo. |
| Per-line blame | `sdt blame <file>` shows per-line authorship, including agent/prompt. |
| Scriptable output | `sdt status --json` and `sdt log --json`; `sdt completions <fish\|zsh\|bash>`. |
| Bidirectional git interop | Import and export full history, branches, and tags. Push and pull to GitHub. |
| Git LFS interop | Pointers resolve to real content on import and clean back to pointers on export, sharing `.git/lfs/objects` with git-lfs. |
| Sparse fetch and serve | Pull only the paths you need. A peer is just an object store, no forced server. |
| Sealed secrets | Commit your `.env` safely. Values are encrypted per-variable into one file; the plaintext is never an object. Team access is a wrapped key, not a service. |
| Encrypted sharing | `sdt send` hands a repo to someone peer to peer, or as a link or file no host can read. |

## How it works

`sdt` captures the working tree as a *moment*. A moment is a content-addressed state with a stable id, a timestamp, and a cause. A moment is not a commit. Moments never appear in `sdt log`. Each moment costs less than one kilobyte. `sdt` stores only what changed from the previous state, and a full keyframe every 200 moments.

`sdt` grades a moment in four steps. It makes a copy-on-write clone of your worktree. It changes the clone to the target state. It runs your check inside the clone. It deletes the clone. `sdt` does not change your worktree, and your terminal does not wait.

`sdt` keys each verdict by content. `sdt` therefore grades a given state one time only.

Capture starts at `sdt init`. You do not turn it on, and you do not run `save` to stay safe:

```sh
sdt init                                  # capture starts here
# ... an agent runs for forty minutes and wrecks something ...
sdt back                                  # it is still there
```

Grading is the part that runs your code, so it stays inert until you say what to run:

```sh
sdt config checks.full "zig build test"
```

`sdt` uses no daemon. On macOS, launchd already runs. Launchd watches the worktree and starts `sdt` only after a file changes. That `sdt` process does its work and stops. Idle CPU use is zero, because no process waits.

`sdt watch` does the same work in a terminal, if you prefer to see it.

Then the payoff:

```sh
sdt green                 # rewind to the last state that actually passed
sdt back 3                # rewind three moments
sdt rewind @2h            # or @green~2, @yesterday, @a3f91c
sdt moments               # what was captured, and what each one did
sdt doctor                # what is on, what is degraded, and why
```

A rewind destroys nothing. `sdt` captures the state that you leave before it rewinds. `sdt undo` reverses the rewind.

**`sdt` never shows a green result alone.** An agent can write both the code and the test. A green result then proves only that the agent agrees with itself. Each verdict therefore carries a warrant on three axes:

1. Independence. Did one actor write both the code and the check? The verdict reads `independent` or `co-authored`.
2. Relevance. Did the check open the files that changed? The verdict reads `relevance 5/5`.
3. Discrimination. Would the check fail on the previous code? The verdict reads `discriminating` or `vacuous`.

`sdt` computes all three axes in milliseconds. It uses no model.

A warrant labels a verdict. It never blocks. `sdt` does not stop a push and does not fail a build. A signal that blocks becomes a target, and an agent then optimizes against it.

A warrant does not tell you if your design is good. It answers one narrow question. It tells you if the green result in front of you has value.

To stop capture, set `moments.enabled = false`. To stop grading, set `checks.enabled = false`. Either setting returns `sdt` to plain version control.

## Git, side by side

superdetermine does not replace git or GitHub, and adopting it is reversible. It sits next to your `.git`, and you decide how far to lean in:

- Keep committing and pushing with git as usual. superdetermine imports and exports full history losslessly, so you are never locked in.
- Or enable dual-write (`sdt config --global sync.git true`) and every `sdt save` also lands a normal git commit, so your team, GitHub, and CI keep working while you drive with sdt.
- Run `sdt export <dir>` to materialize a plain git repo at any time.

If superdetermine turns out not to be for you, your git history is right there, untouched.

## How this differs from DeltaDB

Zed's DeltaDB also records the work between your commits, so the comparison is fair to make.

DeltaDB records what happened. It captures every operation, links it to the conversation that produced it, and replicates that to everyone in a thread. It does not run your check. Zed says so directly: git and CI stay for "running checks", and nothing in DeltaDB knows whether a given state built or passed. Review there means reading the diff.

`sdt` records what worked. The check runs, the verdict is stored against the content, and the warrant tells you whether that green result is worth anything. That is the whole difference.

The other difference is where your code lives. Delta stores your repository contents, your git history, and your uncommitted edits on Zed's servers, and needs an account. `sdt` has no account and no server. Sharing is peer to peer, and the optional relay is one you can run yourself and cannot read what passes through it.

## Quick start

```
sdt init
sdt save -m "message"      # sv   snapshot the working tree (no add, no stash)
sdt status | sdt diff | sdt log     # st | d | l
sdt new feature            # n    branch and switch
sdt work ../agent-copy     # wt   instant worktree
sdt undo   /   sdt redo     # u   /  r
sdt blame file.txt         # per-line authorship + provenance
sdt absorb                 # fold edits into the changes they belong to
sdt gc                     # reclaim unreachable objects
```

Working with git:

```
sdt clone <git-url> [dir]
sdt import <git-repo>   /   sdt export <git-repo>
sdt push [remote] [branch]     # uses your existing git credentials
```

Large files (Git LFS):

```
sdt lfs track "*.psd"      # matching files export to git as LFS pointers
sdt lfs ls | sdt lfs status # what is tracked, and what is cached locally
sdt lfs fetch | sdt lfs push
sdt lfs env                # endpoint, cache location, settings
```

On import, sdt resolves LFS pointers to the real bytes (from `.git/lfs/objects`, else the LFS batch API) and stores them chunked in its own object database, so `sdt diff`, `sdt blame` and `sdt work` all see real files. On export and push it writes the pointers back and uploads any objects the remote is missing. Set `sdt config lfs.smudge false` to keep pointers verbatim instead, `lfs.url` to override the endpoint, and `lfs.upload false` to skip uploads.

## Secrets you can actually commit

`.env` is the file everyone gitignores and then mails around anyway. sdt commits it instead, sealed.

```
sdt key new                # k new  your keypair, once per machine
sdt seal .env              # sl     .env becomes uncommittable from here on
sdt save -m "add config"
```

Your `.env` stays exactly where it is, in plaintext, for your app to read. It just stops being committable. The sealed copy lives in `.grsealed`, the one file sdt adds:

```
version 1
seal .env
| DATABASE_URL=gr1:csEGYiVIFSnnLn4Q2oJv2TyekUkzChccyeVXlXtF3QQ8TrpS...
| STRIPE_KEY=gr1:HJh0CycJJ4ssQq3epof75ooeomALvzNQPGUo_5gAK3M6FNWS3U...
wrap nico gr1lPATx... <the repo key, locked to nico>
```

One committed file holds both the sealed values and who can open them. There is no second `.env` to keep track of.

Each value gets its own key derived from the variable's name and path, and the nonce comes from the plaintext, so an unchanged value re-seals to identical bytes and only real edits show up in a diff. The name and path are authenticated, so moving a `STRIPE_KEY` ciphertext onto the `DATABASE_URL` line fails to decrypt rather than quietly returning the wrong secret. What this reveals, in full: your variable names, how many there are, each value's length, and whether a value repeats at that same name. Nothing else.

Adding a teammate is a pull request, not an account:

```
sdt key show                       # they run this, send you the string
sdt key add dana gr1lPATx6VZ...    # you run this, then commit .grsealed
sdt unseal                         # they run this, and have .env
```

The repo key is wrapped separately to each member with X25519 **and** ML-KEM-768, so an attacker has to break both, so values committed today stay sealed against a future quantum computer. `sdt rotate` issues a new key and re-wraps it. It also tells you the part software cannot do: someone you removed still holds the old key and every commit they already cloned, so rotate the underlying credentials too.

## Sharing without a service

Two commands: `sdt send` gives a repo away, `sdt get` picks one up. With no flags, `send` is peer to peer over your local network.

```
sdt send                          -> 43-hydrant-hostel
sdt get 43-hydrant-hostel
```

The sender announces only a two digit slot number on the network. The words never leave either machine, so there is nothing on the wire to capture. Same wifi is all it needs: no relay, no account, no IP handed out, nothing uploaded.

When you are not on the same network, pick how it should travel:

```
sdt send --file repo.grb          one sealed file, no network at all
sdt send --link ./out             static files you upload anywhere
sdt send --relay host:port        across the internet, via a meeting point
```

`sdt get` takes whatever came out of any of those: a code, a URL, or a file.

Every object is encrypted under a fresh key and stored under a blinded name. The key lives after the `#`, which by the URL spec is never sent in a request, so the host serves bytes it cannot read and its terms of service stop being a security question. Object contents are verified against their own hashes on arrival, so a hostile host cannot substitute anything either.

With `--file`, send the file and the key over different channels. Either alone is useless.

The key is never transmitted. Both sides derive it from the spoken code by PAKE (SPAKE2 over Ristretto255), so a relay watching the whole exchange gets nothing it can attack offline. that is exactly what makes three words safe here where three words in a URL would not be. A wrong guess costs an online attempt, and a code burns after five. Run a relay yourself with `sdt relay` (`sdt rv`); `sdt serve --link <dir>` hosts a `--link` export over HTTP.

The two layers compose the way you would want: share a repo and the recipient gets `.grsealed`, still sealed, because they were given the share key and not the repo key. Code shared, secrets not, without remembering to scrub anything. Granting the secrets is a separate, deliberate `sdt key add`.

Git interop deliberately has no share layer: GitHub sees your code so review works, and only your values stay sealed.

Every command has a short alias: `sdt st`, `sdt d`, `sdt sv`, `sdt sl`, `sdt rv`. Run `sdt help` for the full table. Output is colored when stdout is a terminal and respects `NO_COLOR`.

## Install

Grab a binary from [Releases](https://github.com/plyght/superdetermine/releases), or update in place:

```
sdt update             # latest stable
sdt update --nightly   # latest nightly build
```

Binaries are statically linked, so no system libgit2 is required.

## Build from source

Requires Zig 0.16.

```
zig build           # produces zig-out/bin/sdt
zig build test
```

## Status

Early and opinionated. Interfaces may still change.

## License

Apache-2.0. See [LICENSE](LICENSE).
