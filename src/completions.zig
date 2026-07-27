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
        try out.writeAll("gr: unknown shell (supported: fish, zsh, bash)\n");
        return error.UnknownShell;
    };
    try out.writeAll(script(shell));
}

const fish_script =
    \\# fish completions for gr (guardrail)
    \\# install: gr completions fish > ~/.config/fish/completions/gr.fish
    \\complete -c gr -f
    \\complete -c gr -n __fish_use_subcommand -a save -d 'checkpoint the working tree'
    \\complete -c gr -n __fish_use_subcommand -a snapshot -d 'checkpoint the working tree'
    \\complete -c gr -n __fish_use_subcommand -a snap -d 'checkpoint the working tree'
    \\complete -c gr -n __fish_use_subcommand -a status -d 'what changed since the last save'
    \\complete -c gr -n __fish_use_subcommand -a st -d 'what changed since the last save'
    \\complete -c gr -n __fish_use_subcommand -a diff -d 'line-level diff vs the last save'
    \\complete -c gr -n __fish_use_subcommand -a log -d 'the change history'
    \\complete -c gr -n __fish_use_subcommand -a desc -d 'name (or rename) the current change'
    \\complete -c gr -n __fish_use_subcommand -a new -d 'start a new branch and switch to it'
    \\complete -c gr -n __fish_use_subcommand -a switch -d 'move to another branch'
    \\complete -c gr -n __fish_use_subcommand -a sw -d 'move to another branch'
    \\complete -c gr -n __fish_use_subcommand -a branch -d 'list branches'
    \\complete -c gr -n __fish_use_subcommand -a branches -d 'list branches'
    \\complete -c gr -n __fish_use_subcommand -a work -d 'instant copy-on-write worktree'
    \\complete -c gr -n __fish_use_subcommand -a restore -d 'discard local edits to one file'
    \\complete -c gr -n __fish_use_subcommand -a merge -d 'merge another branch into this one'
    \\complete -c gr -n __fish_use_subcommand -a provenance -d 'show which agent/prompt produced each change'
    \\complete -c gr -n __fish_use_subcommand -a why -d 'who last authored a file'
    \\complete -c gr -n __fish_use_subcommand -a undo -d 'revert the last change-making operation'
    \\complete -c gr -n __fish_use_subcommand -a redo -d 'reapply what you just undid'
    \\complete -c gr -n __fish_use_subcommand -a serve -d 'share this repo over TCP'
    \\complete -c gr -n __fish_use_subcommand -a fetch -d 'sparse-pull a branch'
    \\complete -c gr -n __fish_use_subcommand -a watch -d 'auto-save on every file change'
    \\complete -c gr -n __fish_use_subcommand -a clone -d 'clone a git repo into guardrail'
    \\complete -c gr -n __fish_use_subcommand -a import -d "pull a git repo's HEAD into guardrail"
    \\complete -c gr -n __fish_use_subcommand -a export -d 'write guardrail HEAD out as git commits'
    \\complete -c gr -n __fish_use_subcommand -a sync -d 'mirror guardrail HEAD into the colocated .git'
    \\complete -c gr -n __fish_use_subcommand -a push -d 'push to a remote'
    \\complete -c gr -n __fish_use_subcommand -a pull -d 'pull from a remote'
    \\complete -c gr -n __fish_use_subcommand -a init -d 'create a guardrail repo here'
    \\complete -c gr -n __fish_use_subcommand -a config -d 'get/set config'
    \\complete -c gr -n __fish_use_subcommand -a update -d 'update gr to the latest release'
    \\complete -c gr -n __fish_use_subcommand -a lfs -d 'git-lfs interop (track, ls, fetch, push, env)'
    \\complete -c gr -n __fish_use_subcommand -a gc -d 'garbage-collect unreachable objects'
    \\complete -c gr -n __fish_use_subcommand -a blame -d 'per-line authorship of a file'
    \\complete -c gr -n __fish_use_subcommand -a resolve -d 'resolve merge conflicts'
    \\complete -c gr -n __fish_use_subcommand -a completions -d 'print shell completion script'
    \\complete -c gr -n __fish_use_subcommand -a version -d 'print version'
    \\complete -c gr -n __fish_use_subcommand -a help -d 'show help'
    \\complete -c gr -n '__fish_seen_subcommand_from completions' -a 'fish zsh bash'
    \\
;

const zsh_script =
    \\#compdef gr
    \\# zsh completions for gr (guardrail)
    \\# install: place this file as _gr on your $fpath, then run compinit
    \\_gr() {
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
    \\    'fetch:sparse-pull a branch'
    \\    'watch:auto-save on every file change'
    \\    'clone:clone a git repo into guardrail'
    \\    'import:pull a git repo HEAD into guardrail'
    \\    'export:write guardrail HEAD out as git commits'
    \\    'sync:mirror guardrail HEAD into the colocated .git'
    \\    'push:push to a remote'
    \\    'pull:pull from a remote'
    \\    'init:create a guardrail repo here'
    \\    'config:get/set config'
    \\    'update:update gr to the latest release'
    \\    'lfs:git-lfs interop (track, ls, fetch, push, env)'
    \\    'gc:garbage-collect unreachable objects'
    \\    'blame:per-line authorship of a file'
    \\    'resolve:resolve merge conflicts'
    \\    'completions:print shell completion script'
    \\    'version:print version'
    \\    'help:show help'
    \\  )
    \\  if (( CURRENT == 2 )); then
    \\    _describe -t commands 'gr command' commands
    \\  elif (( CURRENT == 3 )) && [[ ${words[2]} == completions ]]; then
    \\    compadd fish zsh bash
    \\  fi
    \\}
    \\_gr "$@"
    \\
;

const bash_script =
    \\# bash completions for gr (guardrail)
    \\# install: source this file from your ~/.bashrc
    \\_gr() {
    \\  local cur prev
    \\  cur="${COMP_WORDS[COMP_CWORD]}"
    \\  prev="${COMP_WORDS[COMP_CWORD-1]}"
    \\  local commands="save snapshot snap status st diff log desc new switch sw branch branches work restore merge provenance why undo redo serve fetch watch clone import export sync push pull init config update gc blame resolve lfs completions version help"
    \\  if [[ $COMP_CWORD -eq 1 ]]; then
    \\    COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
    \\    return 0
    \\  fi
    \\  if [[ $COMP_CWORD -eq 2 && "$prev" == "completions" ]]; then
    \\    COMPREPLY=( $(compgen -W "fish zsh bash" -- "$cur") )
    \\    return 0
    \\  fi
    \\}
    \\complete -F _gr gr
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
