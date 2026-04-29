const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "mv";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: mv [OPTION]... SOURCE... DEST
    \\
    \\Rename SOURCE to DEST, or move SOURCE(s) to DIRECTORY.
    \\
    \\  -f, --force        do not prompt before overwriting
    \\  -n, --no-clobber   do not overwrite an existing file
    \\  -v, --verbose      explain what is being done
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var force = false;
    var no_clobber = false;
    var verbose = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--no-clobber")) {
            no_clobber = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'f' => force = true,
                'n' => no_clobber = true,
                'v' => verbose = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len < 2) {
        ctx.usage("missing operand (need SOURCE and DEST)", .{});
        return 2;
    }

    const dest = operands.items[operands.items.len - 1];
    const sources = operands.items[0 .. operands.items.len - 1];

    const cwd = std.Io.Dir.cwd();
    const dest_is_dir = isDir(ctx, cwd, dest);

    if (sources.len > 1 and !dest_is_dir) {
        ctx.err("target '{s}' is not a directory", .{dest});
        return 1;
    }

    var any_error = false;
    for (sources) |src| {
        const final_dest = if (dest_is_dir) blk: {
            const base = std.fs.path.basename(src);
            break :blk try std.fs.path.join(ctx.arena, &.{ dest, base });
        } else dest;

        if (no_clobber) {
            if (cwd.access(ctx.io, final_dest, .{ .read = true })) |_| continue else |_| {}
        }
        if (force) cwd.deleteFile(ctx.io, final_dest) catch {};

        cwd.rename(src, cwd, final_dest, ctx.io) catch |e| {
            ctx.err("cannot move '{s}' to '{s}': {s}", .{ src, final_dest, @errorName(e) });
            any_error = true;
            continue;
        };
        if (verbose) try ctx.stdout.print("'{s}' -> '{s}'\n", .{ src, final_dest });
    }
    return if (any_error) 1 else 0;
}

fn isDir(ctx: *Context, cwd: std.Io.Dir, path: []const u8) bool {
    var d = cwd.openDir(ctx.io, path, .{}) catch return false;
    d.close(ctx.io);
    return true;
}
