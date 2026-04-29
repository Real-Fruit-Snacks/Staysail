const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "cp";
pub const aliases: []const []const u8 = if (builtin.os.tag == .windows) &.{"copy"} else &.{};
pub const help: []const u8 =
    \\Usage: cp [OPTION]... SOURCE... DEST
    \\
    \\Copy SOURCE to DEST, or multiple SOURCEs to a directory DEST.
    \\
    \\  -r, -R, --recursive   copy directories recursively
    \\  -f, --force           remove existing destination files if needed
    \\  -v, --verbose         explain what is being done
    \\  -n, --no-clobber      do not overwrite an existing file
    \\      --help            display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var recursive = false;
    var force = false;
    var verbose = false;
    var no_clobber = false;
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
        } else if (std.mem.eql(u8, a, "--no-clobber")) {
            no_clobber = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'r', 'R' => recursive = true,
                'f' => force = true,
                'v' => verbose = true,
                'n' => no_clobber = true,
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

        copyOne(ctx, src, final_dest, recursive, force, no_clobber, verbose) catch |e| {
            ctx.err("cannot copy '{s}' to '{s}': {s}", .{ src, final_dest, @errorName(e) });
            any_error = true;
        };
    }
    return if (any_error) 1 else 0;
}

fn copyOne(ctx: *Context, src: []const u8, dest: []const u8, recursive: bool, force: bool, no_clobber: bool, verbose: bool) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    if (isDir(ctx, cwd, src)) {
        if (!recursive) return error.IsADirectory;
        try copyTree(ctx, src, dest, force, no_clobber, verbose);
        return;
    }
    if (no_clobber) {
        if (cwd.access(ctx.io, dest, .{ .read = true })) |_| return else |_| {}
    }
    if (force) cwd.deleteFile(ctx.io, dest) catch {};
    try cwd.copyFile(src, cwd, dest, ctx.io, .{});
    if (verbose) try ctx.stdout.print("'{s}' -> '{s}'\n", .{ src, dest });
}

fn copyTree(ctx: *Context, src: []const u8, dest: []const u8, force: bool, no_clobber: bool, verbose: bool) anyerror!void {
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(ctx.io, dest, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    var src_dir = try cwd.openDir(ctx.io, src, .{ .iterate = true });
    defer src_dir.close(ctx.io);
    var it = src_dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        const child_src = try std.fs.path.join(ctx.arena, &.{ src, entry.name });
        const child_dest = try std.fs.path.join(ctx.arena, &.{ dest, entry.name });
        try copyOne(ctx, child_src, child_dest, true, force, no_clobber, verbose);
    }
}

fn isDir(ctx: *Context, cwd: std.Io.Dir, path: []const u8) bool {
    var d = cwd.openDir(ctx.io, path, .{}) catch return false;
    d.close(ctx.io);
    return true;
}
