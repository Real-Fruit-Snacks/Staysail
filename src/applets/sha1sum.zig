const std = @import("std");
const Context = @import("../common/context.zig");
const hash_helper = @import("../common/hash.zig");

pub const name: []const u8 = "sha1sum";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: sha1sum [OPTION]... [FILE]...
    \\
    \\Print or check SHA-1 (160-bit) checksums.
    \\
    \\  -b, --binary       read in binary mode
    \\  -c, --check        read SHA-1 sums from FILE(s) and check them
    \\  -t, --text         read in text mode
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    return hash_helper.run(std.crypto.hash.Sha1, ctx, args);
}
