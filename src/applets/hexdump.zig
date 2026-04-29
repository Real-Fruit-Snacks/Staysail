const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "hexdump";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: hexdump [OPTION]... [FILE]...
    \\
    \\Display file contents in hexadecimal, decimal, octal, or ascii.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -C    canonical hex+ASCII display (default)
    \\  -c    one-byte character display
    \\  -b    one-byte octal display
    \\  -d    two-byte decimal display
    \\  -x    two-byte hex display
    \\  -n N  interpret only N bytes of input
    \\        --help     display this help and exit
    \\
;

const Fmt = enum { canonical, char, oct, dec, hex };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var fmt: Fmt = .canonical;
    var n_bytes: ?u64 = null;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-C")) {
            fmt = .canonical;
        } else if (std.mem.eql(u8, a, "-c")) {
            fmt = .char;
        } else if (std.mem.eql(u8, a, "-b")) {
            fmt = .oct;
        } else if (std.mem.eql(u8, a, "-d")) {
            fmt = .dec;
        } else if (std.mem.eql(u8, a, "-x")) {
            fmt = .hex;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) return 2;
            n_bytes = std.fmt.parseInt(u64, args[i], 10) catch null;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.arena);
    if (operands.items.len == 0) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
            continue;
        }
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }

    var slice: []const u8 = data.items;
    if (n_bytes) |n| if (n < slice.len) {
        slice = slice[0..@intCast(n)];
    };

    return emit(ctx, fmt, slice);
}

fn emit(ctx: *Context, fmt: Fmt, data: []const u8) !u8 {
    const w = ctx.stdout;
    switch (fmt) {
        .canonical => {
            var off: usize = 0;
            while (off < data.len) {
                try w.print("{x:0>8}  ", .{off});
                const end = @min(off + 16, data.len);
                // hex columns
                var j: usize = 0;
                while (j < 16) : (j += 1) {
                    if (off + j < end) {
                        try w.print("{x:0>2} ", .{@as(u32, data[off + j])});
                    } else {
                        try w.writeAll("   ");
                    }
                    if (j == 7) try w.writeByte(' ');
                }
                try w.writeAll(" |");
                for (data[off..end]) |b| {
                    if (b >= 0x20 and b < 0x7f) {
                        try w.writeByte(b);
                    } else {
                        try w.writeByte('.');
                    }
                }
                try w.writeAll("|\n");
                off = end;
            }
            try w.print("{x:0>8}\n", .{data.len});
        },
        .char => try emitWords(ctx, data, 1, "  {c}"),
        .oct => try emitWords(ctx, data, 1, "{o:0>3}"),
        .dec => try emitWords(ctx, data, 2, "{d:>5}"),
        .hex => try emitWords(ctx, data, 2, "{x:0>4}"),
    }
    return 0;
}

fn emitWords(ctx: *Context, data: []const u8, word_size: usize, comptime per_word_fmt: []const u8) !void {
    _ = per_word_fmt;
    var off: usize = 0;
    while (off < data.len) {
        try ctx.stdout.print("{o:0>7}", .{off});
        const end = @min(off + 16, data.len);
        var j: usize = 0;
        while (j + word_size <= end - off) : (j += word_size) {
            try ctx.stdout.writeByte(' ');
            if (word_size == 1) {
                try ctx.stdout.print("{x:0>2}", .{@as(u32, data[off + j])});
            } else {
                const lo: u32 = data[off + j];
                const hi: u32 = data[off + j + 1];
                try ctx.stdout.print("{x:0>4}", .{(hi << 8) | lo});
            }
        }
        try ctx.stdout.writeByte('\n');
        off = end;
    }
    try ctx.stdout.print("{o:0>7}\n", .{data.len});
}
