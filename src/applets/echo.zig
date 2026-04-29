const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "echo";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: echo [SHORT-OPTION]... [STRING]...
    \\
    \\Echo the STRING(s) to standard output.
    \\
    \\  -n             do not output the trailing newline
    \\  -e             enable interpretation of backslash escapes
    \\  -E             disable interpretation of backslash escapes (default)
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var trailing_newline = true;
    var interpret_escapes = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }

        // Recognize -n, -e, -E (and bundled forms like -nE). Anything that
        // doesn't parse as a flag terminates option parsing — POSIX echo treats
        // it as a literal string.
        var all_known = true;
        for (arg[1..]) |c| switch (c) {
            'n', 'e', 'E' => {},
            else => {
                all_known = false;
                break;
            },
        };
        if (!all_known) break;

        for (arg[1..]) |c| switch (c) {
            'n' => trailing_newline = false,
            'e' => interpret_escapes = true,
            'E' => interpret_escapes = false,
            else => unreachable,
        };
    }

    const operands = args[i..];
    for (operands, 0..) |s, idx| {
        if (idx > 0) try ctx.stdout.writeByte(' ');
        if (interpret_escapes) {
            try writeWithEscapes(ctx.stdout, s);
        } else {
            try ctx.stdout.writeAll(s);
        }
    }
    if (trailing_newline) try ctx.stdout.writeByte('\n');
    return 0;
}

fn writeWithEscapes(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c != '\\' or i + 1 >= s.len) {
            try w.writeByte(c);
            continue;
        }
        i += 1;
        switch (s[i]) {
            'n' => try w.writeByte('\n'),
            't' => try w.writeByte('\t'),
            'r' => try w.writeByte('\r'),
            '\\' => try w.writeByte('\\'),
            'a' => try w.writeByte(0x07),
            'b' => try w.writeByte(0x08),
            'f' => try w.writeByte(0x0C),
            'v' => try w.writeByte(0x0B),
            '0' => try w.writeByte(0x00),
            else => {
                try w.writeByte('\\');
                try w.writeByte(s[i]);
            },
        }
    }
}

test "echo: basic argument joining is space-separated with trailing newline" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var ctx_buf: [16]u8 = undefined;
    var rb: [0]u8 = undefined;
    var r: std.Io.Reader = .fixed(&rb);
    var stderr_w: std.Io.Writer = .fixed(&ctx_buf);

    var ctx: Context = .{
        .io = undefined,
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .stdout = &w,
        .stderr = &stderr_w,
        .stdin = &r,
        .invoked_as = "echo",
    };

    const args = [_][:0]const u8{ "hello", "world" };
    _ = try run(&ctx, &args);
    try std.testing.expectEqualStrings("hello world\n", w.buffered());
}
