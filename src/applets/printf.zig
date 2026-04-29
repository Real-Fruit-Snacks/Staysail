const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "printf";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: printf FORMAT [ARGUMENT]...
    \\
    \\Write the ARGUMENTs to standard output under control of FORMAT.
    \\
    \\Supported conversions: %s %d %i %u %x %X %o %c %% %b
    \\Supported escapes:     \\\\ \\a \\b \\f \\n \\r \\t \\v \\0
    \\
    \\If there are more arguments than format specifiers, the FORMAT is reused.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }
    if (std.mem.eql(u8, args[0], "--help")) {
        try ctx.stdout.writeAll(help);
        return 0;
    }
    const fmt = args[0];
    const operands = args[1..];

    if (operands.len == 0) {
        _ = try formatOnce(ctx, fmt, operands);
        return 0;
    }

    var idx: usize = 0;
    while (idx < operands.len) {
        const consumed = try formatOnce(ctx, fmt, operands[idx..]);
        if (consumed == 0) break; // no specifiers consumed any args; avoid infinite loop
        idx += consumed;
    }
    return 0;
}

/// Returns the number of operands consumed.
fn formatOnce(ctx: *Context, fmt: []const u8, operands: []const [:0]const u8) !usize {
    var op_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        const c = fmt[i];
        if (c == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                '\\' => try ctx.stdout.writeByte('\\'),
                'a' => try ctx.stdout.writeByte(0x07),
                'b' => try ctx.stdout.writeByte(0x08),
                'f' => try ctx.stdout.writeByte(0x0C),
                'n' => try ctx.stdout.writeByte('\n'),
                'r' => try ctx.stdout.writeByte('\r'),
                't' => try ctx.stdout.writeByte('\t'),
                'v' => try ctx.stdout.writeByte(0x0B),
                '0' => try ctx.stdout.writeByte(0x00),
                else => {
                    try ctx.stdout.writeByte('\\');
                    try ctx.stdout.writeByte(fmt[i]);
                },
            }
            i += 1;
            continue;
        }
        if (c == '%' and i + 1 < fmt.len) {
            // Find the conversion character. Consume optional flags/width/precision.
            i += 1;
            const start = i;
            while (i < fmt.len) : (i += 1) {
                const cc = fmt[i];
                if (cc == 's' or cc == 'd' or cc == 'i' or cc == 'u' or
                    cc == 'x' or cc == 'X' or cc == 'o' or cc == 'c' or
                    cc == '%' or cc == 'b') break;
            }
            if (i >= fmt.len) {
                // Bare trailing %
                try ctx.stdout.writeByte('%');
                try ctx.stdout.writeAll(fmt[start..]);
                return op_idx;
            }
            const conv = fmt[i];
            const flags = fmt[start..i];
            i += 1;

            switch (conv) {
                '%' => try ctx.stdout.writeByte('%'),
                's' => {
                    const v = if (op_idx < operands.len) operands[op_idx] else "";
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.writeAll(v);
                    _ = flags;
                },
                'd', 'i' => {
                    const v: i64 = if (op_idx < operands.len)
                        (std.fmt.parseInt(i64, operands[op_idx], 10) catch 0)
                    else
                        0;
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.print("{d}", .{v});
                },
                'u' => {
                    const v: u64 = if (op_idx < operands.len)
                        (std.fmt.parseInt(u64, operands[op_idx], 10) catch 0)
                    else
                        0;
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.print("{d}", .{v});
                },
                'x' => {
                    const v: u64 = if (op_idx < operands.len)
                        (std.fmt.parseInt(u64, operands[op_idx], 0) catch 0)
                    else
                        0;
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.print("{x}", .{v});
                },
                'X' => {
                    const v: u64 = if (op_idx < operands.len)
                        (std.fmt.parseInt(u64, operands[op_idx], 0) catch 0)
                    else
                        0;
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.print("{X}", .{v});
                },
                'o' => {
                    const v: u64 = if (op_idx < operands.len)
                        (std.fmt.parseInt(u64, operands[op_idx], 0) catch 0)
                    else
                        0;
                    if (op_idx < operands.len) op_idx += 1;
                    try ctx.stdout.print("{o}", .{v});
                },
                'c' => {
                    if (op_idx < operands.len and operands[op_idx].len > 0) {
                        try ctx.stdout.writeByte(operands[op_idx][0]);
                    }
                    if (op_idx < operands.len) op_idx += 1;
                },
                'b' => {
                    // Like %s but with backslash interpretation.
                    const v = if (op_idx < operands.len) operands[op_idx] else "";
                    if (op_idx < operands.len) op_idx += 1;
                    try writeWithEscapes(ctx.stdout, v);
                },
                else => unreachable,
            }
            continue;
        }
        try ctx.stdout.writeByte(c);
        i += 1;
    }
    return op_idx;
}

fn writeWithEscapes(w: *std.Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            switch (s[i]) {
                '\\' => try w.writeByte('\\'),
                'a' => try w.writeByte(0x07),
                'b' => try w.writeByte(0x08),
                'f' => try w.writeByte(0x0C),
                'n' => try w.writeByte('\n'),
                'r' => try w.writeByte('\r'),
                't' => try w.writeByte('\t'),
                'v' => try w.writeByte(0x0B),
                else => {
                    try w.writeByte('\\');
                    try w.writeByte(s[i]);
                },
            }
        } else {
            try w.writeByte(s[i]);
        }
    }
}
