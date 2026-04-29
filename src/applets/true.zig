const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "true";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: true
    \\Exit with status code 0.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    _ = ctx;
    _ = args;
    return 0;
}
