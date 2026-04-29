const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "groups";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: groups [USERNAME]...
    \\
    \\Print group memberships for the given user(s) (default: current user).
    \\
    \\      --help     display this help and exit
    \\
    \\Note: on Windows, prints just the user name; group enumeration is a Phase 4 item.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }

    if (builtin.os.tag == .linux) {
        const gid = std.os.linux.getgid();
        try ctx.stdout.print("{d}\n", .{gid});
        return 0;
    }

    // Non-Linux fallback: print username (matches BusyBox-on-Windows behaviour).
    const u = currentUsername(ctx) orelse "unknown";
    try ctx.stdout.writeAll(u);
    try ctx.stdout.writeByte('\n');
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
