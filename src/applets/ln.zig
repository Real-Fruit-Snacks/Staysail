const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "ln";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: ln [OPTION]... TARGET LINK_NAME
    \\       ln [OPTION]... TARGET                 (link in current dir)
    \\
    \\Create a link to TARGET with name LINK_NAME (or basename of TARGET).
    \\
    \\  -s, --symbolic   make symbolic links instead of hard links
    \\  -f, --force      remove existing destination files
    \\      --help       display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var symbolic = false;
    var force = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--symbolic")) {
            symbolic = true;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                's' => symbolic = true,
                'f' => force = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len < 1 or operands.items.len > 2) {
        ctx.usage("expected 1 or 2 file arguments", .{});
        return 2;
    }

    const target = operands.items[0];
    const link_name = if (operands.items.len == 2) operands.items[1] else std.fs.path.basename(target);

    const cwd = std.Io.Dir.cwd();

    if (force) {
        cwd.deleteFile(ctx.io, link_name) catch {};
    }

    if (symbolic) {
        cwd.symLink(ctx.io, target, link_name, .{}) catch |e| {
            ctx.err("failed to create symbolic link '{s}': {s}", .{ link_name, @errorName(e) });
            return 1;
        };
    } else {
        cwd.hardLink(target, cwd, link_name, ctx.io, .{}) catch |e| {
            ctx.err("failed to create hard link '{s}': {s}", .{ link_name, @errorName(e) });
            return 1;
        };
    }
    return 0;
}
