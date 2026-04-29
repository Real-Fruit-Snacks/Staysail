const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "od";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: od [OPTION]... [FILE]...
    \\
    \\Write an unambiguous representation, octal bytes by default,
    \\of FILE to standard output. With no FILE, read standard input.
    \\
    \\  -A, --address-radix=RADIX  output format for byte offsets (d, o, x, n)
    \\  -t, --format=TYPE          output format (e.g. o1, x1, d1, c, a)
    \\  -c                         shortcut for -t c (named char + ascii)
    \\  -x                         shortcut for -t x2
    \\      --help                 display this help and exit
    \\
;

const AddrRadix = enum { d, o, x, n };
const Fmt = enum { oct1, hex1, dec1, hex2, char };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var addr: AddrRadix = .o;
    var fmt: Fmt = .oct1;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-A")) {
            i += 1;
            if (i >= args.len) return 2;
            addr = parseAddr(args[i]) orelse {
                ctx.err("invalid address radix: '{s}'", .{args[i]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, a, "--address-radix=")) {
            addr = parseAddr(a["--address-radix=".len..]) orelse {
                ctx.err("invalid address radix", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len) return 2;
            fmt = parseFmt(args[i]) orelse {
                ctx.err("invalid format: '{s}'", .{args[i]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, a, "--format=")) {
            fmt = parseFmt(a["--format=".len..]) orelse {
                ctx.err("invalid format", .{});
                return 1;
            };
        } else if (std.mem.eql(u8, a, "-c")) {
            fmt = .char;
        } else if (std.mem.eql(u8, a, "-x")) {
            fmt = .hex2;
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

    return emit(ctx, addr, fmt, data.items);
}

fn parseAddr(s: []const u8) ?AddrRadix {
    if (s.len == 0) return null;
    return switch (s[0]) {
        'd' => .d,
        'o' => .o,
        'x' => .x,
        'n' => .n,
        else => null,
    };
}

fn parseFmt(s: []const u8) ?Fmt {
    if (std.mem.eql(u8, s, "o1")) return .oct1;
    if (std.mem.eql(u8, s, "x1")) return .hex1;
    if (std.mem.eql(u8, s, "d1")) return .dec1;
    if (std.mem.eql(u8, s, "x2")) return .hex2;
    if (std.mem.eql(u8, s, "c")) return .char;
    if (std.mem.eql(u8, s, "x")) return .hex1;
    if (std.mem.eql(u8, s, "o")) return .oct1;
    if (std.mem.eql(u8, s, "d")) return .dec1;
    return null;
}

fn emit(ctx: *Context, addr: AddrRadix, fmt: Fmt, data: []const u8) !u8 {
    const bytes_per_line: usize = 16;
    var off: usize = 0;
    while (off < data.len) {
        try writeAddr(ctx.stdout, addr, off);
        const end = @min(off + bytes_per_line, data.len);
        for (data[off..end]) |b| {
            try ctx.stdout.writeByte(' ');
            switch (fmt) {
                .oct1 => try ctx.stdout.print("{o:0>3}", .{@as(u32, b)}),
                .hex1 => try ctx.stdout.print("{x:0>2}", .{@as(u32, b)}),
                .dec1 => try ctx.stdout.print("{d:>3}", .{@as(u32, b)}),
                .hex2 => try ctx.stdout.print("{x:0>2}", .{@as(u32, b)}),
                .char => try writeNamedChar(ctx.stdout, b),
            }
        }
        try ctx.stdout.writeByte('\n');
        off = end;
    }
    if (addr != .n) {
        try writeAddr(ctx.stdout, addr, data.len);
        try ctx.stdout.writeByte('\n');
    }
    return 0;
}

fn writeAddr(w: *std.Io.Writer, addr: AddrRadix, off: usize) !void {
    switch (addr) {
        .d => try w.print("{d:0>7}", .{off}),
        .o => try w.print("{o:0>7}", .{off}),
        .x => try w.print("{x:0>6}", .{off}),
        .n => {},
    }
}

fn writeNamedChar(w: *std.Io.Writer, b: u8) !void {
    const name_str: ?[]const u8 = switch (b) {
        0 => "\\0",
        0x07 => " \\a",
        0x08 => " \\b",
        0x09 => " \\t",
        0x0A => " \\n",
        0x0B => " \\v",
        0x0C => " \\f",
        0x0D => " \\r",
        else => null,
    };
    if (name_str) |s| {
        try w.writeAll(s);
        return;
    }
    if (b >= 0x20 and b < 0x7f) {
        try w.print("  {c}", .{b});
    } else {
        try w.print("{o:0>3}", .{@as(u32, b)});
    }
}
