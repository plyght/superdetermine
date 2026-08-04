# guardrail (`gr`)

A fast, independent version control system. Content-addressed storage with sub-file dedup, whole-repo undo, and instant copy-on-write worktrees. It runs beside git and pushes to GitHub, so you can adopt it gradually without giving anything up.

## Why

git is excellent, but much of its friction is incidental: a staging area to manage, stashing just to switch branches, resets that feel dangerous, whole-file handling for binaries, and heavyweight worktrees. guardrail keeps a familiar flow and removes that friction while staying compatible with the git world you already use.

## Features

| Feature | What it gives you |
| --- | --- |
| Content-addressed store (BLAKE3 + FastCDC) | Large files and binaries are first-class, deduped at the chunk level. No LFS. |
| Working copy is always a change | No staging, no stash. Edit, then `gr save`. |
| Operation log | `gr undo` and `gr redo` across the whole repo. Nothing gets lost. |
| Instant copy-on-write worktrees | `gr work <dir>` spins up a workspace in milliseconds (APFS clonefile, Linux reflink). |
| Stat-cache index | `status` and `save` skip re-hashing unchanged files (mtime/size/inode). |
| Three-way merge + resolve | Conflict markers, then `gr resolve <file>` / `gr resolve --abort`. |
| Absorb | `gr absorb` folds working edits into the changes they belong to. |
| Garbage collection | `gr gc` reclaims space from unreachable objects (`--dry-run` to preview). |
| Prompt provenance (opt-in) | Record which agent or prompt produced a change, stored in the repo. |
| Per-line blame | `gr blame <file>` shows per-line authorship, including agent/prompt. |
| Scriptable output | `gr status --json` and `gr log --json`; `gr completions <fish\|zsh\|bash>`. |
| Bidirectional git interop | Import and export full history, branches, and tags. Push and pull to GitHub. |
| Git LFS interop | Pointers resolve to real content on import and clean back to pointers on export, sharing `.git/lfs/objects` with git-lfs. |
| Sparse fetch and serve | Pull only the paths you need. A peer is just an object store, no forced server. |
| Sealed secrets | Commit `.env`. Values are encrypted per-variable; the plaintext is never an object. Team access is a wrapped key, not a service. |
| Encrypted sharing | `gr send` hands a repo to someone peer to peer, or as a link or file no host can read. |

## Git, side by side

guardrail does not replace git or GitHub, and adopting it is reversible. It sits next to your `.git`, and you decide how far to lean in:

- Keep committing and pushing with git as usual. guardrail imports and exports full history losslessly, so you are never locked in.
- Or enable dual-write (`gr config --global sync.git true`) and every `gr save` also lands a normal git commit, so your team, GitHub, and CI keep working while you drive with gr.
- Run `gr export <dir>` to materialize a plain git repo at any time.

If gr turns out not to be for you, your git history is right there, untouched.

## Quick start

```
gr init
gr save -m "message"      # sv   snapshot the working tree (no add, no stash)
gr status | gr diff | gr log     # st | d | l
gr new feature            # n    branch and switch
gr work ../agent-copy     # wt   instant worktree
gr undo   /   gr redo     # u   /  r
gr blame file.txt         # per-line authorship + provenance
gr absorb                 # fold edits into the changes they belong to
gr gc                     # reclaim unreachable objects
```

Working with git:

```
gr clone <git-url> <dir>
gr import <git-repo>   /   gr export <git-repo>
gr push [remote] [branch]     # uses your existing git credentials
```

Large files (Git LFS):

```
gr lfs track "*.psd"      # matching files export to git as LFS pointers
gr lfs ls | gr lfs status # what is tracked, and what is cached locally
gr lfs fetch | gr lfs push
gr lfs env                # endpoint, cache location, settings
```

On import, gr resolves LFS pointers to the real bytes (from `.git/lfs/objects`, else the LFS batch API) and stores them chunked in its own object database, so `gr diff`, `gr blame` and `gr work` all see real files. On export and push it writes the pointers back and uploads any objects the remote is missing. Set `gr config lfs.smudge false` to keep pointers verbatim instead, `lfs.url` to override the endpoint, and `lfs.upload false` to skip uploads.

## Secrets you can actually commit

`.env` is the file everyone gitignores and then mails around anyway. gr commits it instead, sealed.

```
gr key new                # k new  your keypair, once per machine
gr seal .env              # sl     writes .env.sealed; .env becomes uncommittable
gr save -m "add config"
```

`.env.sealed` is a normal tracked file that diffs cleanly:

```
DATABASE_URL=gr1:csEGYiVIFSnnLn4Q2oJv2TyekUkzChccyeVXlXtF3QQ8TrpS...
STRIPE_KEY=gr1:HJh0CycJJ4ssQq3epof75ooeomALvzNQPGUo_5gAK3M6FNWS3U...
```

Each value gets its own key derived from the variable's name and path, and the nonce comes from the plaintext, so an unchanged value re-seals to identical bytes and only real edits show up in a diff. The name and path are authenticated, so moving a `STRIPE_KEY` ciphertext onto the `DATABASE_URL` line fails to decrypt rather than quietly returning the wrong secret. What this reveals, in full: your variable names, how many there are, each value's length, and whether a value repeats at that same name. Nothing else.

Adding a teammate is a pull request, not an account:

```
gr key show                       # they run this, send you the string
gr key add dana gr1lPATx6VZ...    # you run this, then commit .grsealed
gr unseal                         # they run this, and have .env
```

The repo key is wrapped separately to each member with X25519 **and** ML-KEM-768, so an attacker has to break both, so values committed today stay sealed against a future quantum computer. `gr rotate` issues a new key and re-wraps it. It also tells you the part software cannot do: someone you removed still holds the old key and every commit they already cloned, so rotate the underlying credentials too.

## Sharing without a service

Two commands: `gr send` gives a repo away, `gr get` picks one up. With no flags, `send` is peer to peer over your local network.

```
gr send                          -> 43-hydrant-hostel
gr get 43-hydrant-hostel
```

The sender announces only a two digit slot number on the network. The words never leave either machine, so there is nothing on the wire to capture. Same wifi is all it needs: no relay, no account, no IP handed out, nothing uploaded.

When you are not on the same network, pick how it should travel:

```
gr send --file repo.grb          one sealed file, no network at all
gr send --link ./out             static files you upload anywhere
gr send --relay host:port        across the internet, via a meeting point
```

`gr get` takes whatever came out of any of those: a code, a URL, or a file.

Every object is encrypted under a fresh key and stored under a blinded name. The key lives after the `#`, which by the URL spec is never sent in a request, so the host serves bytes it cannot read and its terms of service stop being a security question. Object contents are verified against their own hashes on arrival, so a hostile host cannot substitute anything either.

With `--file`, send the file and the key over different channels. Either alone is useless.

The key is never transmitted. Both sides derive it from the spoken code by PAKE (SPAKE2 over Ristretto255), so a relay watching the whole exchange gets nothing it can attack offline. that is exactly what makes three words safe here where three words in a URL would not be. A wrong guess costs an online attempt, and a code burns after five. Run a relay yourself with `gr relay` (`gr rv`); `gr serve --link <dir>` hosts a `--link` export over HTTP.

The two layers compose the way you would want: share a repo and the recipient gets `.env.sealed`, still sealed, because they were given the share key and not the repo key. Code shared, secrets not, without remembering to scrub anything. Granting the secrets is a separate, deliberate `gr key add`.

Git interop deliberately has no share layer: GitHub sees your code so review works, and only your values stay sealed.

Every command has a short alias: `gr st`, `gr d`, `gr sv`, `gr sl`, `gr rv`. Run `gr help` for the full table. Output is colored when stdout is a terminal and respects `NO_COLOR`.

## Install

Grab a binary from [Releases](https://github.com/plyght/guardrail/releases), or update in place:

```
gr update             # latest stable
gr update --nightly   # latest nightly build
```

Binaries are statically linked, so no system libgit2 is required.

## Build from source

Requires Zig 0.16.

```
zig build           # produces zig-out/bin/gr
zig build test
```

## Status

Early and opinionated. Interfaces may still change.
