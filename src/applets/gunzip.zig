const std = @import("std");
const Context = @import("../common/context.zig");
const gzip = @import("gzip.zig");

pub const name: []const u8 = "gunzip";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: gunzip [OPTION]... [FILE]...
    \\
    \\Decompress gzip-compressed FILEs (or stdin), writing to stdout (-c) or
    \\replacing FILE with the decompressed contents.
    \\
    \\  -c, --stdout      write to stdout, keep input files
    \\  -k, --keep        keep input files when -c is not given
    \\      --help        display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    // Re-use gzip's run() with -d implicitly added.
    var new_args: std.ArrayList([:0]const u8) = .empty;
    defer new_args.deinit(ctx.arena);
    try new_args.append(ctx.arena, "-d");
    for (args) |a| try new_args.append(ctx.arena, a);
    return gzip.run(ctx, new_args.items);
}
