const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "touch";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: touch [OPTION]... FILE...
    \\
    \\Update the access and modification times of each FILE to the current time.
    \\A FILE that does not exist is created empty (unless -c).
    \\
    \\  -c, --no-create   do not create any files
    \\      --help        display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var no_create = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--no-create")) {
            no_create = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len == 0) {
        ctx.usage("missing file operand", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    var any_error = false;

    for (operands.items) |path| {
        // Try to open existing file. If missing and !no_create, create empty.
        const open_result = cwd.openFile(ctx.io, path, .{ .mode = .read_write });
        if (open_result) |f| {
            f.setTimestampsNow(ctx.io) catch |e| {
                ctx.err("cannot touch '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
            };
            f.close(ctx.io);
        } else |err| switch (err) {
            error.FileNotFound => {
                if (no_create) continue;
                const f = cwd.createFile(ctx.io, path, .{}) catch |ce| {
                    ctx.err("cannot touch '{s}': {s}", .{ path, @errorName(ce) });
                    any_error = true;
                    continue;
                };
                f.close(ctx.io);
            },
            else => {
                ctx.err("cannot touch '{s}': {s}", .{ path, @errorName(err) });
                any_error = true;
            },
        }
    }
    return if (any_error) 1 else 0;
}
