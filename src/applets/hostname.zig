const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "hostname";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: hostname
    \\
    \\Print the system's network hostname.
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
        ctx.usage("setting hostname not supported", .{});
        return 2;
    }

    const env_keys = if (builtin.os.tag == .windows)
        [_][]const u8{"COMPUTERNAME"}
    else
        [_][]const u8{"HOSTNAME"};

    for (env_keys) |k| if (ctx.environ.get(k)) |v| if (v.len > 0) {
        try ctx.stdout.writeAll(v);
        try ctx.stdout.writeByte('\n');
        return 0;
    };

    if (builtin.os.tag == .linux) {
        const HOST_NAME_MAX = 64;
        var hbuf: [HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&hbuf)) |h| {
            try ctx.stdout.writeAll(h);
            try ctx.stdout.writeByte('\n');
            return 0;
        } else |_| {}
    }
    try ctx.stdout.writeAll("unknown\n");
    return 0;
}
