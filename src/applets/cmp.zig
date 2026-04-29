const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "cmp";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: cmp [OPTION]... FILE1 [FILE2]
    \\
    \\Compare two files byte by byte.
    \\If FILE2 is omitted (or '-'), read standard input.
    \\
    \\Exit status: 0 = identical, 1 = differ, 2 = trouble.
    \\
    \\  -l, --verbose      output byte numbers and differing byte values
    \\  -s, --silent       suppress all output; only return exit status
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var verbose = false;
    var silent = false;
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--silent") or std.mem.eql(u8, a, "--quiet")) {
            silent = true;
        } else {
            try paths.append(ctx.arena, a);
        }
    }

    if (paths.items.len < 1 or paths.items.len > 2) {
        ctx.usage("expected 1 or 2 file arguments", .{});
        return 2;
    }

    const path1 = paths.items[0];
    const path2: []const u8 = if (paths.items.len == 2) paths.items[1] else "-";

    const data1 = try slurp(ctx, path1) orelse return 2;
    const data2 = try slurp(ctx, path2) orelse return 2;

    var byte_no: u64 = 1;
    var line_no: u64 = 1;
    var differ = false;
    const min_len = @min(data1.len, data2.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        if (data1[i] != data2[i]) {
            differ = true;
            if (verbose) {
                try ctx.stdout.print("{d:>5} {o:>3} {o:>3}\n", .{
                    byte_no,
                    @as(u32, data1[i]),
                    @as(u32, data2[i]),
                });
            } else {
                if (!silent) {
                    try ctx.stderr.print("{s} {s} differ: byte {d}, line {d}\n", .{
                        path1, path2, byte_no, line_no,
                    });
                }
                return 1;
            }
        }
        if (data1[i] == '\n') line_no += 1;
        byte_no += 1;
    }
    if (data1.len != data2.len) {
        if (!silent and !verbose) {
            const longer_name = if (data1.len > data2.len) path1 else path2;
            const shorter_name = if (data1.len > data2.len) path2 else path1;
            try ctx.stderr.print("cmp: EOF on {s} after byte {d}, in line {d}\n", .{
                shorter_name, byte_no - 1, line_no,
            });
            _ = longer_name;
        }
        return 1;
    }
    return if (differ) 1 else 0;
}

fn slurp(ctx: *Context, path: []const u8) !?[]const u8 {
    var data: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, path, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return null;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }
    return data.items;
}
