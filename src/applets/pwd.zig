const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "pwd";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: pwd
    \\Print the name of the current working directory.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    _ = args;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = std.process.currentPath(ctx.io, &buf) catch |e| {
        ctx.err("{s}", .{@errorName(e)});
        return 1;
    };
    try ctx.stdout.writeAll(buf[0..len]);
    try ctx.stdout.writeByte('\n');
    return 0;
}
