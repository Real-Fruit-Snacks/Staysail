const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "mkdir";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: mkdir [OPTION]... DIRECTORY...
    \\
    \\Create the DIRECTORY(ies), if they do not already exist.
    \\
    \\  -p, --parents     no error if existing, make parent directories as needed
    \\  -v, --verbose     print a message for each created directory
    \\      --help        display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var parents = false;
    var verbose = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-p") or std.mem.eql(u8, a, "--parents")) {
            parents = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'p' => parents = true,
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

    if (operands.items.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    var any_error = false;
    for (operands.items) |path| {
        const result = if (parents)
            cwd.createDirPath(ctx.io, path)
        else
            cwd.createDir(ctx.io, path, .default_dir);
        result catch |e| switch (e) {
            error.PathAlreadyExists => {
                if (!parents) {
                    ctx.err("cannot create directory '{s}': File exists", .{path});
                    any_error = true;
                }
            },
            else => {
                ctx.err("cannot create directory '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
            },
        };
        if (verbose) try ctx.stdout.print("mkdir: created directory '{s}'\n", .{path});
    }
    return if (any_error) 1 else 0;
}
