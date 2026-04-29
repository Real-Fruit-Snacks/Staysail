const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "stat";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: stat [OPTION]... FILE...
    \\
    \\Display file or file system status.
    \\
    \\  -t, --terse        print the information in terse form
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var terse = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--terse")) {
            terse = true;
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
        const file = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot stat '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer file.close(ctx.io);
        const st = file.stat(ctx.io) catch |e| {
            ctx.err("cannot stat '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };

        if (terse) {
            try ctx.stdout.print("{s} {d} {d} {s}\n", .{ path, st.size, st.nlink, kindName(st.kind) });
        } else {
            try ctx.stdout.print(
                \\  File: {s}
                \\  Size: {d:<10}    Type: {s}
                \\Inode: {d:<10}    Links: {d}
                \\Modify: {d}.{d:0>9}
                \\
            ,
                .{
                    path,
                    st.size,
                    kindName(st.kind),
                    @as(u64, @intCast(st.inode)),
                    @as(u64, @intCast(st.nlink)),
                    @divFloor(st.mtime.nanoseconds, std.time.ns_per_s),
                    @mod(st.mtime.nanoseconds, std.time.ns_per_s),
                },
            );
        }
    }
    return if (any_error) 1 else 0;
}

fn kindName(k: std.Io.File.Kind) []const u8 {
    return switch (k) {
        .file => "regular file",
        .directory => "directory",
        .sym_link => "symbolic link",
        .character_device => "character device",
        .block_device => "block device",
        .named_pipe => "fifo",
        .unix_domain_socket => "socket",
        else => "unknown",
    };
}
