const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "uname";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: uname [OPTION]...
    \\
    \\Print certain system information. With no OPTION, same as -s.
    \\
    \\  -a, --all                print all information
    \\  -s, --kernel-name        print the kernel name
    \\  -n, --nodename           print the network node hostname
    \\  -m, --machine            print the machine hardware name
    \\  -o, --operating-system   print the operating system
    \\      --help               display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var show_kernel = false;
    var show_node = false;
    var show_machine = false;
    var show_os = false;

    if (args.len == 0) {
        show_kernel = true;
    } else for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            show_kernel = true;
            show_node = true;
            show_machine = true;
            show_os = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--kernel-name")) {
            show_kernel = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--nodename")) {
            show_node = true;
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--machine")) {
            show_machine = true;
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--operating-system")) {
            show_os = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'a' => {
                    show_kernel = true;
                    show_node = true;
                    show_machine = true;
                    show_os = true;
                },
                's' => show_kernel = true,
                'n' => show_node = true,
                'm' => show_machine = true,
                'o' => show_os = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            ctx.usage("extra operand '{s}'", .{a});
            return 2;
        }
    }

    var first = true;
    if (show_kernel) {
        try writeField(ctx, &first, kernelName());
    }
    if (show_node) {
        const h = hostname(ctx) orelse "unknown";
        try writeField(ctx, &first, h);
    }
    if (show_machine) {
        try writeField(ctx, &first, machineName());
    }
    if (show_os) {
        try writeField(ctx, &first, osName());
    }
    try ctx.stdout.writeByte('\n');
    return 0;
}

fn writeField(ctx: *Context, first: *bool, s: []const u8) !void {
    if (!first.*) try ctx.stdout.writeByte(' ');
    try ctx.stdout.writeAll(s);
    first.* = false;
}

fn kernelName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "Linux",
        .windows => "Windows_NT",
        .macos => "Darwin",
        .freebsd => "FreeBSD",
        .netbsd => "NetBSD",
        .openbsd => "OpenBSD",
        .dragonfly => "DragonFly",
        else => @tagName(builtin.os.tag),
    };
}

fn machineName() []const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        .arm => "arm",
        .x86 => "i686",
        .riscv64 => "riscv64",
        else => @tagName(builtin.cpu.arch),
    };
}

fn osName() []const u8 {
    return switch (builtin.os.tag) {
        .linux => "GNU/Linux",
        .windows => "MS/Windows",
        .macos => "Darwin",
        else => @tagName(builtin.os.tag),
    };
}

fn hostname(ctx: *Context) ?[]const u8 {
    // Cross-platform: env var first, syscall fallback on Linux only (Windows
    // posix.gethostname signature varies). Phase 2 can add a proper Win32 path.
    const env_keys = if (builtin.os.tag == .windows)
        [_][]const u8{"COMPUTERNAME"}
    else
        [_][]const u8{"HOSTNAME"};
    for (env_keys) |k| if (ctx.environ.get(k)) |v| if (v.len > 0) return v;

    if (builtin.os.tag == .linux) {
        const HOST_NAME_MAX = 64;
        var hbuf: [HOST_NAME_MAX]u8 = undefined;
        return std.posix.gethostname(&hbuf) catch null;
    }
    return null;
}
