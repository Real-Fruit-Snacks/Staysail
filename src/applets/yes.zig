const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "yes";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: yes [STRING]...
    \\       yes OPTION
    \\
    \\Repeatedly output a line with all specified STRING(s), or 'y'.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 1 and std.mem.eql(u8, args[0], "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }

    // Build the line once. For zero args, the line is "y\n". Otherwise,
    // join the args with single spaces and append a newline.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    if (args.len == 0) {
        try line.append(ctx.arena, 'y');
    } else {
        for (args, 0..) |a, idx| {
            if (idx > 0) try line.append(ctx.arena, ' ');
            try line.appendSlice(ctx.arena, a);
        }
    }
    try line.append(ctx.arena, '\n');

    // Output until stdout fails (the typical termination via SIGPIPE / pipe close).
    while (true) {
        ctx.stdout.writeAll(line.items) catch return 0;
    }
}
