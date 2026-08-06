const std = @import("std");

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
    \\complete -c sdt -n __fish_use_subcommand -a diff -d 'line-level diff vs the last save'
    \\complete -c sdt -n __fish_use_subcommand -a log -d 'the change history'
    \\complete -c sdt -n __fish_use_subcommand -a desc -d 'name (or rename) the current change'
    \\complete -c sdt -n __fish_use_subcommand -a new -d 'start a new branch and switch to it'
    \\complete -c sdt -n __fish_use_subcommand -a switch -d 'move to another branch'
    \\complete -c sdt -n __fish_use_subcommand -a sw -d 'move to another branch'
    \\complete -c sdt -n __fish_use_subcommand -a branch -d 'list branches'
    \\complete -c sdt -n __fish_use_subcommand -a branches -d 'list branches'
    \\complete -c sdt -n __fish_use_subcommand -a work -d 'instant copy-on-write worktree'
    \\complete -c sdt -n __fish_use_subcommand -a restore -d 'discard local edits to one file'
    \\complete -c sdt -n __fish_use_subcommand -a merge -d 'merge another branch into this one'
    \\complete -c sdt -n __fish_use_subcommand -a provenance -d 'show which agent/prompt produced each change'
    \\complete -c sdt -n __fish_use_subcommand -a why -d 'who last authored a file'
    \\complete -c sdt -n __fish_use_subcommand -a undo -d 'revert the last change-making operation'
    \\complete -c sdt -n __fish_use_subcommand -a redo -d 'reapply what you just undid'
    \\complete -c sdt -n __fish_use_subcommand -a serve -d 'share this repo over TCP'
    \\complete -c sdt -n __fish_use_subcommand -a send -d 'hand this repo to someone'
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
    \\complete -c sdt -n __fish_use_subcommand -a moments -d 'captured states and their verdicts'
    \\complete -c sdt -n __fish_use_subcommand -a grade -d 'run checks in the background'
    \\complete -c sdt -n __fish_use_subcommand -a doctor -d 'what is on, what is degraded, and why'
    \\complete -c sdt -n __fish_use_subcommand -a recap -d 'green and red spans, and what thrashed'
    \\complete -c sdt -n __fish_use_subcommand -a super -d 'paths holding more than one version'
    \\complete -c sdt -n __fish_use_subcommand -a collapse -d 'keep one version of a superposed path'
    \\complete -c sdt -n __fish_use_subcommand -a note -d 'annotate a line'
    \\complete -c sdt -n __fish_use_subcommand -a notes -d 'every annotation recorded here'
    \\complete -c sdt -n __fish_use_subcommand -a watch -d 'auto-save on every file change'
    \\complete -c sdt -n __fish_use_subcommand -a clone -d 'clone a git repo into superdetermine'
    \\complete -c sdt -n __fish_use_subcommand -a import -d "pull a git repo's HEAD into superdetermine"
    \\complete -c sdt -n __fish_use_subcommand -a export -d 'write superdetermine HEAD out as git commits'
    \\complete -c sdt -n __fish_use_subcommand -a sync -d 'mirror superdetermine HEAD into the colocated .git'
    \\complete -c sdt -n __fish_use_subcommand -a push -d 'push to a remote'
    \\complete -c sdt -n __fish_use_subcommand -a pull -d 'pull from a remote'
    \\complete -c sdt -n __fish_use_subcommand -a init -d 'create a superdetermine repo here'
    \\complete -c sdt -n __fish_use_subcommand -a config -d 'get/set config'
    \\complete -c sdt -n __fish_use_subcommand -a update -d 'update sdt to the latest release'
    \\complete -c sdt -n __fish_use_subcommand -a lfs -d 'git-lfs interop (track, ls, fetch, push, env)'
    \\complete -c sdt -n __fish_use_subcommand -a gc -d 'garbage-collect unreachable objects'
    \\complete -c sdt -n __fish_use_subcommand -a blame -d 'per-line authorship of a file'
    \\complete -c sdt -n __fish_use_subcommand -a resolve -d 'resolve merge conflicts'
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
    \\    'diff:line-level diff vs the last save'
    \\    'log:the change history'
    \\    'desc:name (or rename) the current change'
    \\    'new:start a new branch and switch to it'
    \\    'switch:move to another branch'
    \\    'sw:move to another branch'
    \\    'branch:list branches'
    \\    'branches:list branches'
    \\    'work:instant copy-on-write worktree'
    \\    'restore:discard local edits to one file'
    \\    'merge:merge another branch into this one'
    \\    'provenance:show which agent/prompt produced each change'
    \\    'why:who last authored a file'
    \\    'undo:revert the last change-making operation'
    \\    'redo:reapply what you just undid'
    \\    'serve:share this repo over TCP'
    \\    'send:hand this repo to someone'
    \\    'get:pick up a code, link, or bundle'
    \\    'relay:run a meeting point for transfers'
    \\    'fetch:sparse-pull a branch'
    \\    'seal:seal a .env-style file'
    \\    'unseal:write the plaintext files back out'
    \\    'key:manage who can read sealed values'
    \\    'rotate:new repo key, re-wrapped to members'
    \\    'watch:auto-save on every file change'
    \\    'green:rewind to the last state that passed'
    \\    'back:rewind n moments, default 1'
    \\    'rewind:rewind to any @ref'
    \\    'moments:captured states and their verdicts'
    \\    'grade:run checks in the background'
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
    \\    'init:create a superdetermine repo here'
    \\    'config:get/set config'
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
    \\  local commands="ab b back bk bl blame bn br branch branches bundle cfg ci cl clone co collapse comp completions config cp d desc diff doc doctor export f fetch g gc gd grade get gn green help import init k key l lfs log merge mg mo moments n new note notes pl prov provenance ps pull push r rc recap receive recv redo relay res resolve restore rev rewind rot rotate rs rv rw save seal send serve sh share sl snap snapshot snd sp srv st status super sv sw switch sync u undo unseal update us version watch why work wt"
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ $COMP_CWORD -eq 2 && "$prev" == "completions" ]]; then
    \\    COMPREPLY=( $(compgen -W "fish zsh bash" -- "$cur") )
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
