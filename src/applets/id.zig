const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "id";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: id [OPTION]... [USER]
    \\
    \\Print user and group information for USER (default: current user).
    \\
    \\  -u, --user       print only the effective user ID
    \\  -g, --group      print only the effective group ID
    \\  -n, --name       print a name instead of a number, with -u/-g
    \\      --help       display this help and exit
    \\
    \\Note: on Windows, only the user name is reported (no numeric IDs).
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var only_user = false;
    var only_group = false;
    var as_name = false;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--user")) {
            only_user = true;
        } else if (std.mem.eql(u8, a, "-g") or std.mem.eql(u8, a, "--group")) {
            only_group = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--name")) {
            as_name = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'u' => only_user = true,
                'g' => only_group = true,
                'n' => as_name = true,
                else => {},
            };
        }
    }

    const username = currentUsername(ctx) orelse "unknown";

    // Real uid/gid only on Linux (Zig 0.16 limited POSIX surface).
    const uid: ?u32 = if (builtin.os.tag == .linux) std.os.linux.getuid() else null;
    const gid: ?u32 = if (builtin.os.tag == .linux) std.os.linux.getgid() else null;

    if (only_user) {
        if (as_name or uid == null) try ctx.stdout.print("{s}\n", .{username}) else try ctx.stdout.print("{d}\n", .{uid.?});
        return 0;
    }
    if (only_group) {
        if (gid) |g| try ctx.stdout.print("{d}\n", .{g}) else try ctx.stdout.writeAll("0\n");
        return 0;
    }
    if (uid) |u| {
        try ctx.stdout.print("uid={d}({s}) gid={d}\n", .{ u, username, gid.? });
    } else {
        try ctx.stdout.print("uid=0({s}) gid=0(unknown) groups=0(unknown)\n", .{username});
    }
    return 0;
}

fn currentUsername(ctx: *Context) ?[]const u8 {
    const candidates = if (builtin.os.tag == .windows)
        [_][]const u8{ "USERNAME", "USER" }
    else
        [_][]const u8{ "USER", "LOGNAME", "USERNAME" };
    for (candidates) |k| if (ctx.environ.get(k)) |v| if (v.len > 0) return v;
    return null;
}
