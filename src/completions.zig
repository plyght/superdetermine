const std = @import("std");
const settings = @import("settings.zig");

/// Every setting name, space separated, so the shells offer the same words the
/// CLI accepts and the two cannot drift.
const setting_names = blk: {
    var out: []const u8 = "";
    for (settings.table, 0..) |item, i| {
        out = out ++ (if (i == 0) "" else " ") ++ item.name;
    }
    break :blk out;
};

pub const Shell = enum { fish, zsh, bash };

pub fn parse(name: []const u8) ?Shell {
    if (std.mem.eql(u8, name, "fish")) return .fish;
    if (std.mem.eql(u8, name, "zsh")) return .zsh;
    if (std.mem.eql(u8, name, "bash")) return .bash;
    return null;
}

pub fn script(shell: Shell) []const u8 {
    return switch (shell) {
        .fish => fish_script,
        .zsh => zsh_script,
        .bash => bash_script,
    };
}

pub fn run(name: []const u8, out: *std.Io.Writer) !void {
    const shell = parse(name) orelse {
        try out.writeAll("sdt: unknown shell (supported: fish, zsh, bash)\n");
        return error.UnknownShell;
    };
    try out.writeAll(script(shell));
}

const fish_script =
    \\# fish completions for sdt (superdetermine)
    \\# install: sdt completions fish > ~/.config/fish/completions/sdt.fish
    \\complete -c sdt -f
    \\complete -c sdt -n __fish_use_subcommand -a save -d 'checkpoint the working tree'
    \\complete -c sdt -n __fish_use_subcommand -a snapshot -d 'checkpoint the working tree'
    \\complete -c sdt -n __fish_use_subcommand -a snap -d 'checkpoint the working tree'
    \\complete -c sdt -n __fish_use_subcommand -a status -d 'what changed since the last save'
    \\complete -c sdt -n __fish_use_subcommand -a st -d 'what changed since the last save'
    \\complete -c sdt -n __fish_use_subcommand -a diff -d 'line-level diff vs the last save, or between states'
    \\complete -c sdt -n __fish_use_subcommand -a show -d 'what one change or moment contains'
    \\complete -c sdt -n __fish_use_subcommand -a cat -d "one file's content as of any state"
    \\complete -c sdt -n __fish_use_subcommand -a log -d 'the change history'
    \\complete -c sdt -n __fish_use_subcommand -a desc -d 'name (or rename) the current change'
    \\complete -c sdt -n __fish_use_subcommand -a new -d 'start a new branch and switch to it'
    \\complete -c sdt -n __fish_use_subcommand -a switch -d 'move to another branch'
    \\complete -c sdt -n __fish_use_subcommand -a sw -d 'move to another branch'
    \\complete -c sdt -n __fish_use_subcommand -a branch -d 'list branches'
    \\complete -c sdt -n __fish_use_subcommand -a branches -d 'list branches'
    \\complete -c sdt -n __fish_use_subcommand -a work -d 'instant copy-on-write worktree'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -a list -d 'every worktree, its branch, and what is unsaved'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -a status -d 'one worktree in detail, or all of them'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -a merge -d "bring a worktree's saved changes back here"
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -a remove -d 'set a worktree aside (refuses unsaved edits)'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -a restore -d 'put a removed worktree back'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -l at -d 'fork from a moment instead of the live tree' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -l all -d 'include removed worktrees'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -l force -d 'remove even with unsaved edits'
    \\complete -c sdt -n '__fish_seen_subcommand_from work wt' -l json -d 'machine-readable output'
    \\complete -c sdt -n __fish_use_subcommand -a restore -d 'put one file back, from the last save or any state'
    \\complete -c sdt -n __fish_use_subcommand -a merge -d 'merge another branch into this one'
    \\complete -c sdt -n __fish_use_subcommand -a absorb -d 'fold edits into the changes they belong to'
    \\complete -c sdt -n __fish_use_subcommand -a point -d "move this branch's tip to any ref"
    \\complete -c sdt -n __fish_use_subcommand -a rebase -d 'replay this branch onto a new base'
    \\complete -c sdt -n __fish_use_subcommand -a stack -d 'this stack, base to tip, with each branch grade'
    \\complete -c sdt -n __fish_use_subcommand -a sk -d 'this stack, base to tip, with each branch grade'
    \\complete -c sdt -n '__fish_seen_subcommand_from stack sk' -a 'add remove rebase merge squash' -d 'stack command'
    \\complete -c sdt -n '__fish_seen_subcommand_from stack sk' -l on -d 'the parent to stack a branch on' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from stack sk' -l into -d 'the base branch to merge the stack into' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from stack sk' -s m -d 'message for the collapsed level' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from stack sk' -l json -d 'machine-readable output'
    \\complete -c sdt -n __fish_use_subcommand -a amend -d 'fold working edits into a named change'
    \\complete -c sdt -n __fish_use_subcommand -a squash -d 'collapse adjacent changes into one'
    \\complete -c sdt -n __fish_use_subcommand -a split -d 'split one change in two, by path or hunk'
    \\complete -c sdt -n __fish_use_subcommand -a drop -d 'remove a change, keep its edits in the tree'
    \\complete -c sdt -n __fish_use_subcommand -a reorder -d 'reorder the last changes, 1 = oldest'
    \\complete -c sdt -n __fish_use_subcommand -a take -d 'copy a change from another branch onto this one'
    \\complete -c sdt -n __fish_use_subcommand -a move -d 'move a change onto another branch'
    \\complete -c sdt -n '__fish_seen_subcommand_from squash sq' -s m -d 'message for the collapsed change' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from squash sq' -l at -d 'end the span at this ref' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from split spl' -s m -d 'message for the extracted change' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from split spl' -l hunk -d 'take hunks of one file: <path>:<n[,n][,a-b]>' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from amend am absorb ab' -l at -d 'the change to fold the edits into' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from amend am absorb ab' -l hunk -d 'fold hunks of one file: <path>:<n[,n][,a-b]>' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from describe desc' -s m -d 'the message' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from describe desc' -l at -d 'rename this change, not the tip' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from branch b br branches' -s d -d 'delete a branch' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from branch b br branches' -s D -d 'delete a branch, unmerged history included' -r
    \\complete -c sdt -n __fish_use_subcommand -a provenance -d 'show which agent/prompt produced each change'
    \\complete -c sdt -n __fish_use_subcommand -a why -d 'who last authored a file'
    \\complete -c sdt -n __fish_use_subcommand -a undo -d 'revert the last change-making operation'
    \\complete -c sdt -n __fish_use_subcommand -a redo -d 'reapply what you just undid'
    \\complete -c sdt -n __fish_use_subcommand -a serve -d 'share this repo over TCP'
    \\complete -c sdt -n __fish_use_subcommand -a send -d 'hand this repo, or one state, to someone'
    \\complete -c sdt -n __fish_use_subcommand -a get -d 'pick up a code, link, or bundle'
    \\complete -c sdt -n __fish_use_subcommand -a relay -d 'run a meeting point for transfers'
    \\complete -c sdt -n __fish_use_subcommand -a fetch -d 'sparse-pull a branch'
    \\complete -c sdt -n __fish_use_subcommand -a seal -d 'seal a .env-style file'
    \\complete -c sdt -n __fish_use_subcommand -a unseal -d 'write the plaintext files back out'
    \\complete -c sdt -n __fish_use_subcommand -a key -d 'manage who can read sealed values'
    \\complete -c sdt -n __fish_use_subcommand -a rotate -d 'new repo key, re-wrapped to members'
    \\complete -c sdt -n __fish_use_subcommand -a green -d 'rewind to the last state that passed'
    \\complete -c sdt -n __fish_use_subcommand -a back -d 'rewind n moments, default 1'
    \\complete -c sdt -n __fish_use_subcommand -a rewind -d 'rewind to any @ref'
    \\complete -c sdt -n __fish_use_subcommand -a moments -d 'captured states, their age and their verdicts'
    \\complete -c sdt -n __fish_use_subcommand -a grade -d 'run checks now, or grade a git ref'
    \\complete -c sdt -n '__fish_seen_subcommand_from grade gd' -l repo -d 'grade a ref in another git repo' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from grade gd' -l fast -d 'use the fast tier'
    \\complete -c sdt -n '__fish_seen_subcommand_from grade gd' -l full -d 'use the full tier'
    \\complete -c sdt -n '__fish_seen_subcommand_from grade gd' -l json -d 'machine-readable output'
    \\complete -c sdt -n __fish_use_subcommand -a probe -d 'run a command against a state in a clone; a range bisects'
    \\complete -c sdt -n __fish_use_subcommand -a pb -d 'run a command against a state in a clone; a range bisects'
    \\complete -c sdt -n '__fish_seen_subcommand_from probe pb' -l json -d 'machine-readable output'
    \\complete -c sdt -n '__fish_seen_subcommand_from probe pb' -l rerun -d 'run even when the verdict cache already answers'
    \\complete -c sdt -n '__fish_seen_subcommand_from probe pb' -s j -l jobs -d 'clones to run at once when bisecting' -r
    \\complete -c sdt -n __fish_use_subcommand -a doctor -d 'what is on, what is degraded, and why'
    \\complete -c sdt -n __fish_use_subcommand -a recap -d 'green and red spans, and what thrashed'
    \\complete -c sdt -n __fish_use_subcommand -a super -d 'paths holding more than one version'
    \\complete -c sdt -n __fish_use_subcommand -a collapse -d 'keep one version of a superposed path'
    \\complete -c sdt -n __fish_use_subcommand -a note -d 'annotate a line'
    \\complete -c sdt -n __fish_use_subcommand -a notes -d 'every annotation recorded here'
    \\complete -c sdt -n __fish_use_subcommand -a watch -d 'auto-save on every file change'
    \\complete -c sdt -n __fish_use_subcommand -a hook -d 'tell a coding agent whether its work passed'
    \\complete -c sdt -n '__fish_seen_subcommand_from hook' -a install -d 'print the settings block to install'
    \\complete -c sdt -n '__fish_seen_subcommand_from hook' -l write -r -d 'write the settings block to a path'
    \\complete -c sdt -n __fish_use_subcommand -a clone -d 'clone a git repo into superdetermine'
    \\complete -c sdt -n __fish_use_subcommand -a import -d "pull a git repo's HEAD into superdetermine"
    \\complete -c sdt -n __fish_use_subcommand -a export -d 'write superdetermine HEAD out as git commits'
    \\complete -c sdt -n __fish_use_subcommand -a sync -d 'mirror superdetermine HEAD into the colocated .git'
    \\complete -c sdt -n __fish_use_subcommand -a push -d 'push to a remote'
    \\complete -c sdt -n __fish_use_subcommand -a pull -d 'pull from a remote'
    \\complete -c sdt -n __fish_use_subcommand -a attest -d 'post the warrant as a GitHub commit status'
    \\complete -c sdt -n '__fish_seen_subcommand_from attest at' -l remote -d 'which remote names the repository' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from attest at' -l dry-run -d 'show what would be posted, send nothing'
    \\complete -c sdt -n '__fish_seen_subcommand_from attest at' -l fast -d 'use the fast tier'
    \\complete -c sdt -n '__fish_seen_subcommand_from attest at' -l full -d 'use the full tier'
    \\complete -c sdt -n '__fish_seen_subcommand_from attest at' -l json -d 'machine-readable output'
    \\complete -c sdt -n __fish_use_subcommand -a init -d 'create a superdetermine repo here'
    \\complete -c sdt -n __fish_use_subcommand -a setup -d 'answer three questions and be configured'
    \\complete -c sdt -n __fish_use_subcommand -a config -d 'every setting, by name'
    \\complete -c sdt -n '__fish_seen_subcommand_from config cfg' -l global -d 'for every repo on this machine'
    \\complete -c sdt -n '__fish_seen_subcommand_from config cfg' -l unset -d 'put it back to its default'
++ "\ncomplete -c sdt -n '__fish_seen_subcommand_from config cfg' -a '" ++ setting_names ++ "'\n" ++
    \\complete -c sdt -n __fish_use_subcommand -a update -d 'update sdt to the latest release'
    \\complete -c sdt -n __fish_use_subcommand -a lfs -d 'git-lfs interop (track, ls, fetch, push, env)'
    \\complete -c sdt -n __fish_use_subcommand -a gc -d 'garbage-collect unreachable objects'
    \\complete -c sdt -n __fish_use_subcommand -a blame -d 'per-line authorship of a file'
    \\complete -c sdt -n __fish_use_subcommand -a resolve -d 'resolve merge conflicts'
    \\complete -c sdt -n '__fish_seen_subcommand_from resolve res' -l abort -d 'abandon the merge, restore the tree'
    \\complete -c sdt -n '__fish_seen_subcommand_from resolve res' -l list -d 'every recorded resolution'
    \\complete -c sdt -n '__fish_seen_subcommand_from resolve res' -l forget -d 'drop a recorded resolution by id' -r
    \\complete -c sdt -n '__fish_seen_subcommand_from resolve res' -l json -d 'machine-readable output'
    \\complete -c sdt -n __fish_use_subcommand -a completions -d 'print shell completion script'
    \\complete -c sdt -n __fish_use_subcommand -a version -d 'print version'
    \\complete -c sdt -n __fish_use_subcommand -a help -d 'show help'
    \\complete -c sdt -n '__fish_seen_subcommand_from completions' -a 'fish zsh bash'
    \\
;

const zsh_script =
    \\#compdef sdt
    \\# zsh completions for sdt (superdetermine)
    \\# install: place this file as _gr on your $fpath, then run compinit
    \\_sdt() {
    \\  local -a commands
    \\  commands=(
    \\    'save:checkpoint the working tree'
    \\    'snapshot:checkpoint the working tree'
    \\    'snap:checkpoint the working tree'
    \\    'status:what changed since the last save'
    \\    'st:what changed since the last save'
    \\    'diff:line-level diff vs the last save, or between states'
    \\    'show:what one change or moment contains'
    \\    'cat:one file content as of any state'
    \\    'log:the change history'
    \\    'desc:name (or rename) the current change'
    \\    'new:start a new branch and switch to it'
    \\    'switch:move to another branch'
    \\    'sw:move to another branch'
    \\    'branch:list branches'
    \\    'branches:list branches'
    \\    'work:instant copy-on-write worktree'
    \\    'restore:put one file back, from the last save or any state'
    \\    'merge:merge another branch into this one'
    \\    'absorb:fold edits into the changes they belong to'
    \\    'point:move this branch tip to any ref'
    \\    'rebase:replay this branch onto a new base'
    \\    'stack:this stack, base to tip, with each branch grade'
    \\    'sk:this stack, base to tip, with each branch grade'
    \\    'amend:fold working edits into a named change'
    \\    'squash:collapse adjacent changes into one'
    \\    'split:split one change in two, by path or hunk'
    \\    'drop:remove a change, keep its edits in the tree'
    \\    'reorder:reorder the last changes, 1 = oldest'
    \\    'take:copy a change from another branch onto this one'
    \\    'move:move a change onto another branch'
    \\    'provenance:show which agent/prompt produced each change'
    \\    'why:who last authored a file'
    \\    'undo:revert the last change-making operation'
    \\    'redo:reapply what you just undid'
    \\    'serve:share this repo over TCP'
    \\    'send:hand this repo, or one state, to someone'
    \\    'get:pick up a code, link, or bundle'
    \\    'relay:run a meeting point for transfers'
    \\    'fetch:sparse-pull a branch'
    \\    'seal:seal a .env-style file'
    \\    'unseal:write the plaintext files back out'
    \\    'key:manage who can read sealed values'
    \\    'rotate:new repo key, re-wrapped to members'
    \\    'watch:auto-save on every file change'
    \\    'hook:tell a coding agent whether its work passed'
    \\    'green:rewind to the last state that passed'
    \\    'back:rewind n moments, default 1'
    \\    'rewind:rewind to any @ref'
    \\    'moments:captured states, their age and their verdicts'
    \\    'grade:run checks now, or grade a git ref'
    \\    'probe:run a command against a state in a clone; a range bisects'
    \\    'pb:run a command against a state in a clone; a range bisects'
    \\    'doctor:what is on, what is degraded, and why'
    \\    'recap:green and red spans, and what thrashed'
    \\    'super:paths holding more than one version'
    \\    'collapse:keep one version of a superposed path'
    \\    'note:annotate a line'
    \\    'notes:every annotation recorded here'
    \\    'clone:clone a git repo into superdetermine'
    \\    'import:pull a git repo HEAD into superdetermine'
    \\    'export:write superdetermine HEAD out as git commits'
    \\    'sync:mirror superdetermine HEAD into the colocated .git'
    \\    'push:push to a remote'
    \\    'pull:pull from a remote'
    \\    'attest:post the warrant as a GitHub commit status'
    \\    'at:post the warrant as a GitHub commit status'
    \\    'init:create a superdetermine repo here'
    \\    'setup:answer three questions and be configured'
    \\    'config:every setting, by name'
    \\    'update:update sdt to the latest release'
    \\    'lfs:git-lfs interop (track, ls, fetch, push, env)'
    \\    'gc:garbage-collect unreachable objects'
    \\    'blame:per-line authorship of a file'
    \\    'resolve:resolve merge conflicts'
    \\    'completions:print shell completion script'
    \\    'version:print version'
    \\    'help:show help'
    \\  )
    \\  if (( CURRENT == 2 )); then
    \\    _describe -t commands 'sdt command' commands
    \\  elif (( CURRENT == 3 )) && [[ ${words[2]} == completions ]]; then
    \\    compadd fish zsh bash
++ "\n  elif (( CURRENT == 3 )) && [[ ${words[2]} == (config|cfg) ]]; then\n    compadd " ++ setting_names ++ "\n" ++
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (grade|gd) ]]; then
    \\    compadd -- --repo --fast --full --json
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (probe|pb) ]]; then
    \\    compadd -- --json --rerun -j --jobs --
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (attest|at) ]]; then
    \\    compadd -- --remote --dry-run --fast --full --json
    \\  elif (( CURRENT == 3 )) && [[ ${words[2]} == (stack|sk) ]]; then
    \\    compadd add remove rebase merge squash --json
    \\  elif (( CURRENT >= 4 )) && [[ ${words[2]} == (stack|sk) ]]; then
    \\    compadd -- --on --into -m
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (resolve|res) ]]; then
    \\    compadd -- --abort --list --forget --json
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (squash|sq) ]]; then
    \\    compadd -- -m --at
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (split|spl) ]]; then
    \\    compadd -- -m --hunk --
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (amend|am|absorb|ab) ]]; then
    \\    compadd -- --at --hunk --
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (describe|desc) ]]; then
    \\    compadd -- -m --at
    \\  elif (( CURRENT >= 3 )) && [[ ${words[2]} == (branch|b|br|branches) ]]; then
    \\    compadd -- -d -D
    \\  elif (( CURRENT == 3 )) && [[ ${words[2]} == (work|wt) ]]; then
    \\    compadd list status merge remove restore -- --at
    \\  elif (( CURRENT >= 4 )) && [[ ${words[2]} == (work|wt) ]]; then
    \\    compadd -- --all --force --json
    \\  fi
    \\}
    \\_gr "$@"
    \\
;

const bash_script =
    \\# bash completions for sdt (superdetermine)
    \\# install: source this file from your ~/.bashrc
    \\_sdt() {
    \\  local cur prev
    \\  cur="${COMP_WORDS[COMP_CWORD]}"
    \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\  local commands="ab absorb am amend at attest b back bk bl blame bn br branch branches bundle cat cfg ci cl clone co collapse comp completions config cp d desc diff doc doctor dr drop export f fetch g gc gd get gn grade green help hook import init k key l lfs log merge mg mo moments move mv n new note notes pb pl point probe prov provenance ps pt pull push r rb rc rebase recap receive recv redo relay reorder res resolve restore rev rewind ro rot rotate rs rv rw save seal send serve setup sh share show sk sl snap snapshot snd sp spl split sq squash srv st stack status super sv sw switch sync take tk u undo unseal update us version watch why work wt"
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ $COMP_CWORD -eq 2 && "$prev" == "completions" ]]; then
    \\    COMPREPLY=( $(compgen -W "fish zsh bash" -- "$cur") )
    \\    return 0
    \\  fi
++ "\n  if [[ \"${COMP_WORDS[1]}\" == \"config\" || \"${COMP_WORDS[1]}\" == \"cfg\" ]]; then\n    COMPREPLY=( $(compgen -W \"" ++ setting_names ++ " --global --unset\" -- \"$cur\") )\n    return 0\n  fi\n" ++
    \\  if [[ "${COMP_WORDS[1]}" == "grade" || "${COMP_WORDS[1]}" == "gd" ]]; then
    \\    COMPREPLY=( $(compgen -W "--repo --fast --full --json" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "probe" || "${COMP_WORDS[1]}" == "pb" ]]; then
    \\    COMPREPLY=( $(compgen -W "--json --rerun -j --jobs --" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "attest" || "${COMP_WORDS[1]}" == "at" ]]; then
    \\    COMPREPLY=( $(compgen -W "--remote --dry-run --fast --full --json" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "stack" || "${COMP_WORDS[1]}" == "sk" ]]; then
    \\    if [[ $COMP_CWORD -eq 2 ]]; then
    \\      COMPREPLY=( $(compgen -W "add remove rebase merge squash --json" -- "$cur") )
    \\    else
    \\      COMPREPLY=( $(compgen -W "--on --into -m" -- "$cur") )
    \\    fi
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "resolve" || "${COMP_WORDS[1]}" == "res" ]]; then
    \\    COMPREPLY=( $(compgen -W "--abort --list --forget --json" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "squash" || "${COMP_WORDS[1]}" == "sq" ]]; then
    \\    COMPREPLY=( $(compgen -W "-m --at" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "split" || "${COMP_WORDS[1]}" == "spl" ]]; then
    \\    COMPREPLY=( $(compgen -W "-m --hunk --" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "amend" || "${COMP_WORDS[1]}" == "am" || "${COMP_WORDS[1]}" == "absorb" || "${COMP_WORDS[1]}" == "ab" ]]; then
    \\    COMPREPLY=( $(compgen -W "--at --hunk --" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "describe" || "${COMP_WORDS[1]}" == "desc" ]]; then
    \\    COMPREPLY=( $(compgen -W "-m --at" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "branch" || "${COMP_WORDS[1]}" == "b" || "${COMP_WORDS[1]}" == "br" ]]; then
    \\    COMPREPLY=( $(compgen -W "-d -D" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ "${COMP_WORDS[1]}" == "work" || "${COMP_WORDS[1]}" == "wt" ]]; then
    \\    if [[ $COMP_CWORD -eq 2 ]]; then
    \\      COMPREPLY=( $(compgen -W "list status merge remove restore --at" -- "$cur") )
    \\    else
    \\      COMPREPLY=( $(compgen -W "--all --force --json" -- "$cur") )
    \\    fi
    \\    return 0
    \\  fi
    \\}
    \\complete -F _sdt sdt
    \\
;

test "parse maps known shells" {
    try std.testing.expectEqual(Shell.fish, parse("fish").?);
    try std.testing.expectEqual(Shell.zsh, parse("zsh").?);
    try std.testing.expectEqual(Shell.bash, parse("bash").?);
    try std.testing.expectEqual(@as(?Shell, null), parse("nope"));
}

test "script contents" {
    try std.testing.expect(std.mem.indexOf(u8, script(.fish), "save") != null);
    try std.testing.expect(script(.bash).len > 0);
}

test "every shell completes take, move, and the work subcommands" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash }) |shell| {
        const text = script(shell);
        try std.testing.expect(std.mem.indexOf(u8, text, "take") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "move") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "list status merge remove restore") != null or
            std.mem.indexOf(u8, text, "-a restore") != null);
    }
}

test "every shell completes stack and resolve" {
    inline for (.{ Shell.fish, Shell.zsh, Shell.bash }) |shell| {
        try std.testing.expect(std.mem.indexOf(u8, script(shell), "stack") != null);
        try std.testing.expect(std.mem.indexOf(u8, script(shell), "forget") != null);
        try std.testing.expect(std.mem.indexOf(u8, script(shell), "rebase merge squash") != null);
    }
}
