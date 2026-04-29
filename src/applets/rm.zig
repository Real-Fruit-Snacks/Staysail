const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "rm";
pub const aliases: []const []const u8 = if (builtin.os.tag == .windows) &.{"del"} else &.{};
pub const help: []const u8 =
    \\Usage: rm [OPTION]... FILE...
    \\
    \\Remove (unlink) the FILE(s).
    \\
    \\  -r, -R, --recursive   remove directories and their contents recursively
    \\  -f, --force           ignore nonexistent files; never prompt
    \\  -v, --verbose         explain what is being done
    \\  -d, --dir             remove empty directories
    \\      --help            display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var recursive = false;
    var force = false;
    var verbose = false;
    var allow_empty_dir = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--recursive")) {
            recursive = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--dir")) {
            allow_empty_dir = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'r', 'R' => recursive = true,
                'f' => force = true,
                'v' => verbose = true,
                'd' => allow_empty_dir = true,
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
        if (force) return 0;
        ctx.usage("missing operand", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    var any_error = false;
    for (operands.items) |path| {
        if (recursive) {
            cwd.deleteTree(ctx.io, path) catch |e| {
                if (force and e == error.FileNotFound) continue;
                ctx.err("cannot remove '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
            if (verbose) try ctx.stdout.print("removed '{s}'\n", .{path});
            continue;
        }

        cwd.deleteFile(ctx.io, path) catch |e| switch (e) {
            error.IsDir => {
                if (allow_empty_dir) {
                    cwd.deleteDir(ctx.io, path) catch |de| {
                        if (force and de == error.FileNotFound) continue;
                        ctx.err("cannot remove '{s}': {s}", .{ path, @errorName(de) });
                        any_error = true;
                        continue;
                    };
                    if (verbose) try ctx.stdout.print("removed directory '{s}'\n", .{path});
                } else {
                    ctx.err("cannot remove '{s}': Is a directory (use -r)", .{path});
                    any_error = true;
                }
                continue;
            },
            error.FileNotFound => {
                if (!force) {
                    ctx.err("cannot remove '{s}': No such file or directory", .{path});
                    any_error = true;
                }
                continue;
            },
            else => {
                ctx.err("cannot remove '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            },
        };
        if (verbose) try ctx.stdout.print("removed '{s}'\n", .{path});
    }
    return if (any_error) 1 else 0;
}
