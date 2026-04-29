const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "whoami";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: whoami
    \\
    \\Print the user name associated with the current effective user ID.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        ctx.usage("extra operand '{s}'", .{args[0]});
        return 2;
    }

    const user = userName(ctx) orelse {
        ctx.err("cannot determine user name", .{});
        return 1;
    };
    try ctx.stdout.writeAll(user);
    try ctx.stdout.writeByte('\n');
    return 0;
}

fn userName(ctx: *Context) ?[]const u8 {
    const candidates = if (builtin.os.tag == .windows)
        [_][]const u8{ "USERNAME", "USER" }
    else
        [_][]const u8{ "USER", "LOGNAME", "USERNAME" };

    for (candidates) |key| {
        if (ctx.environ.get(key)) |v| {
            if (v.len > 0) return v;
        }
    }
    return null;
}
