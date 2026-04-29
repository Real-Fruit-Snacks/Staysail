const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "getopt";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: getopt OPTSTRING PARAMETERS...
    \\
    \\Parse PARAMETERS according to OPTSTRING and print the rearranged
    \\command line. OPTSTRING is a string of option characters; characters
    \\followed by a colon take an argument.
    \\
    \\      --help     display this help and exit
    \\
    \\Phase 3 supports the short-option form only. Long-option support comes
    \\in Phase 4.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        ctx.usage("missing OPTSTRING", .{});
        return 2;
    }
    if (std.mem.eql(u8, args[0], "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }

    const optstring = args[0];
    const params = args[1..];

    var any_error = false;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(ctx.arena);

    var i: usize = 0;
    while (i < params.len) : (i += 1) {
        const p = params[i];
        if (p.len < 2 or p[0] != '-' or std.mem.eql(u8, p, "--")) {
            // End of options.
            if (std.mem.eql(u8, p, "--")) i += 1;
            while (i < params.len) : (i += 1) try positional.append(ctx.arena, params[i]);
            break;
        }
        // Parse short flags in this arg.
        var j: usize = 1;
        while (j < p.len) : (j += 1) {
            const c = p[j];
            const idx = std.mem.indexOfScalar(u8, optstring, c) orelse {
                try ctx.stderr.print("getopt: invalid option -- '{c}'\n", .{c});
                any_error = true;
                continue;
            };
            const wants_arg = idx + 1 < optstring.len and optstring[idx + 1] == ':';
            try ctx.stdout.print(" -{c}", .{c});
            if (wants_arg) {
                if (j + 1 < p.len) {
                    try ctx.stdout.print(" '{s}'", .{p[j + 1 ..]});
                    break;
                }
                i += 1;
                if (i >= params.len) {
                    try ctx.stderr.print("getopt: option requires an argument -- '{c}'\n", .{c});
                    any_error = true;
                    break;
                }
                try ctx.stdout.print(" '{s}'", .{params[i]});
                break;
            }
        }
    }

    try ctx.stdout.writeAll(" --");
    for (positional.items) |p| try ctx.stdout.print(" '{s}'", .{p});
    try ctx.stdout.writeByte('\n');
    return if (any_error) 1 else 0;
}
