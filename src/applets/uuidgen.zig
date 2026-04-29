const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "uuidgen";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: uuidgen
    \\
    \\Generate a random UUID v4 and print it to stdout.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len > 0 and std.mem.eql(u8, args[0], "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }

    var bytes: [16]u8 = undefined;
    ctx.io.random(&bytes);

    // Set version 4 (random) and variant 10x.
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;

    try ctx.stdout.print(
        "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}\n",
        .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        },
    );
    return 0;
}
