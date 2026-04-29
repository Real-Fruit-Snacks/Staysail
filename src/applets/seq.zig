const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "seq";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: seq [OPTION]... LAST
    \\       seq [OPTION]... FIRST LAST
    \\       seq [OPTION]... FIRST INCREMENT LAST
    \\
    \\Print numbers from FIRST to LAST in steps of INCREMENT.
    \\
    \\  -s, --separator=STRING  use STRING to separate numbers (default: \n)
    \\  -w, --equal-width       equalize width by padding with leading zeros
    \\      --help              display this help and exit
    \\
    \\If FIRST or INCREMENT is omitted, it defaults to 1.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var separator: []const u8 = "\n";
    var equal_width = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-w") or std.mem.eql(u8, a, "--equal-width")) {
            equal_width = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 's'", .{});
                return 2;
            }
            separator = args[i];
        } else if (std.mem.startsWith(u8, a, "--separator=")) {
            separator = a["--separator=".len..];
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try operands.append(ctx.arena, args[i]);
            break;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var first: f64 = 1.0;
    var increment: f64 = 1.0;
    var last: f64 = 1.0;

    switch (operands.items.len) {
        1 => {
            last = parseNum(operands.items[0]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[0]});
                return 1;
            };
        },
        2 => {
            first = parseNum(operands.items[0]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[0]});
                return 1;
            };
            last = parseNum(operands.items[1]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[1]});
                return 1;
            };
        },
        3 => {
            first = parseNum(operands.items[0]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[0]});
                return 1;
            };
            increment = parseNum(operands.items[1]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[1]});
                return 1;
            };
            last = parseNum(operands.items[2]) orelse {
                ctx.err("invalid floating point argument: '{s}'", .{operands.items[2]});
                return 1;
            };
        },
        else => {
            if (operands.items.len == 0) {
                ctx.usage("missing operand", .{});
            } else {
                ctx.usage("extra operand '{s}'", .{operands.items[3]});
            }
            return 2;
        },
    }

    if (increment == 0) {
        ctx.err("invalid Zero increment value: '0'", .{});
        return 1;
    }

    // Compute width for -w mode (string length of formatted first/last/increment).
    var width: usize = 0;
    if (equal_width) {
        var sbuf: [64]u8 = undefined;
        const w_first = (try std.fmt.bufPrint(&sbuf, "{d}", .{first})).len;
        const w_last = (try std.fmt.bufPrint(&sbuf, "{d}", .{last})).len;
        width = @max(w_first, w_last);
    }

    const ascending = increment > 0;
    var n = first;
    var first_emit = true;
    while ((ascending and n <= last) or (!ascending and n >= last)) {
        if (!first_emit) try ctx.stdout.writeAll(separator);
        first_emit = false;
        if (equal_width) {
            try printPadded(ctx.stdout, n, width);
        } else {
            try ctx.stdout.print("{d}", .{n});
        }
        n += increment;
    }
    if (!first_emit) try ctx.stdout.writeByte('\n');
    return 0;
}

fn parseNum(s: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, s) catch null;
}

fn printPadded(w: *std.Io.Writer, n: f64, width: usize) !void {
    var sbuf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&sbuf, "{d}", .{n});
    if (s.len < width) {
        try w.splatByteAll('0', width - s.len);
    }
    try w.writeAll(s);
}
