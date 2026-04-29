const std = @import("std");
const Context = @import("../common/context.zig");
const registry = @import("../registry.zig");

pub const name: []const u8 = "completions";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: completions SHELL
    \\
    \\Emit a shell completion script for staysail. Supported SHELLs:
    \\
    \\  bash         pipe into /etc/bash_completion.d/staysail
    \\  zsh          pipe into a directory in $fpath as _staysail
    \\  fish         pipe into ~/.config/fish/completions/staysail.fish
    \\  powershell   source the output in your $PROFILE
    \\
    \\      --help   display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        ctx.usage("missing SHELL argument", .{});
        return 2;
    }
    const shell = args[0];
    if (std.mem.eql(u8, shell, "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }
    if (std.mem.eql(u8, shell, "bash")) return emitBash(ctx);
    if (std.mem.eql(u8, shell, "zsh")) return emitZsh(ctx);
    if (std.mem.eql(u8, shell, "fish")) return emitFish(ctx);
    if (std.mem.eql(u8, shell, "powershell") or std.mem.eql(u8, shell, "pwsh")) return emitPowerShell(ctx);
    ctx.err("unknown shell: '{s}' (use bash, zsh, fish, or powershell)", .{shell});
    return 2;
}

fn emitBash(ctx: *Context) !u8 {
    try ctx.stdout.writeAll(
        \\# bash completion for staysail
        \\_staysail_complete() {
        \\    local cur prev applets
        \\    cur="${COMP_WORDS[COMP_CWORD]}"
        \\    prev="${COMP_WORDS[COMP_CWORD-1]}"
        \\    applets="
    );
    for (registry.APPLETS) |applet| try ctx.stdout.print("{s} ", .{applet.name});
    try ctx.stdout.writeAll(
        \\"
        \\    if [[ "$prev" == "staysail" || "$prev" == "staysail.exe" ]]; then
        \\        COMPREPLY=( $(compgen -W "$applets --list --version --help" -- "$cur") )
        \\        return 0
        \\    fi
        \\    COMPREPLY=( $(compgen -f -- "$cur") )
        \\    return 0
        \\}
        \\complete -F _staysail_complete staysail
        \\complete -F _staysail_complete staysail.exe
        \\
    );
    return 0;
}

fn emitZsh(ctx: *Context) !u8 {
    try ctx.stdout.writeAll(
        \\#compdef staysail
        \\_staysail() {
        \\    local -a applets
        \\    applets=(
    );
    for (registry.APPLETS) |applet| try ctx.stdout.print("\n        '{s}'", .{applet.name});
    try ctx.stdout.writeAll(
        \\
        \\    )
        \\    if (( CURRENT == 2 )); then
        \\        _describe -t commands "applet" applets
        \\    else
        \\        _files
        \\    fi
        \\}
        \\compdef _staysail staysail
        \\
    );
    return 0;
}

fn emitFish(ctx: *Context) !u8 {
    try ctx.stdout.writeAll("# fish completion for staysail\n");
    try ctx.stdout.writeAll("set -l staysail_applets ");
    for (registry.APPLETS) |applet| try ctx.stdout.print("{s} ", .{applet.name});
    try ctx.stdout.writeAll("\ncomplete -c staysail -f -n '__fish_use_subcommand' -a \"$staysail_applets\"\n");
    try ctx.stdout.writeAll("complete -c staysail -f -n '__fish_use_subcommand' -l list -d 'list applets'\n");
    try ctx.stdout.writeAll("complete -c staysail -f -n '__fish_use_subcommand' -l version -d 'print version'\n");
    return 0;
}

fn emitPowerShell(ctx: *Context) !u8 {
    try ctx.stdout.writeAll(
        \\# PowerShell completion for staysail
        \\Register-ArgumentCompleter -Native -CommandName staysail -ScriptBlock {
        \\    param($wordToComplete, $commandAst, $cursorPosition)
        \\    $applets = @(
    );
    var first = true;
    for (registry.APPLETS) |applet| {
        if (!first) try ctx.stdout.writeAll(", ");
        try ctx.stdout.print("'{s}'", .{applet.name});
        first = false;
    }
    try ctx.stdout.writeAll(
        \\)
        \\    $applets | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
        \\        [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
        \\    }
        \\}
        \\
    );
    return 0;
}
