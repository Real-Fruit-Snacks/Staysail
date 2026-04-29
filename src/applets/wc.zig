const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "wc";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: wc [OPTION]... [FILE]...
    \\
    \\Print newline, word, and byte counts for each FILE, and a total line
    \\if more than one FILE is specified. With no FILE, or when FILE is -,
    \\read standard input.
    \\
    \\  -c, --bytes        print the byte counts
    \\  -l, --lines        print the newline counts
    \\  -w, --words        print the word counts
    \\      --help         display this help and exit
    \\
    \\If no count flag is given, lines + words + bytes are all printed.
    \\
;

const Counts = struct {
    lines: u64 = 0,
    words: u64 = 0,
    bytes: u64 = 0,
};

const Show = struct {
    lines: bool,
    words: bool,
    bytes: bool,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var show_l = false;
    var show_w = false;
    var show_c = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try operands.append(ctx.arena, args[i]);
            break;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'l' => show_l = true,
                'w' => show_w = true,
                'c' => show_c = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else if (std.mem.eql(u8, a, "--lines")) {
            show_l = true;
        } else if (std.mem.eql(u8, a, "--words")) {
            show_w = true;
        } else if (std.mem.eql(u8, a, "--bytes")) {
            show_c = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    const show: Show = if (!show_l and !show_w and !show_c)
        .{ .lines = true, .words = true, .bytes = true }
    else
        .{ .lines = show_l, .words = show_w, .bytes = show_c };

    var total: Counts = .{};
    var any_error = false;
    const multiple = operands.items.len > 1;

    if (operands.items.len == 0) {
        const c = try countReader(ctx, ctx.stdin);
        try emit(ctx, show, c, null);
    } else {
        for (operands.items) |path| {
            const c = if (std.mem.eql(u8, path, "-"))
                try countReader(ctx, ctx.stdin)
            else blk: {
                const cwd = std.Io.Dir.cwd();
                const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
                    ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
                    any_error = true;
                    break :blk Counts{};
                };
                defer f.close(ctx.io);
                var rb: [16 * 1024]u8 = undefined;
                var fr = f.reader(ctx.io, &rb);
                break :blk try countReader(ctx, &fr.interface);
            };
            try emit(ctx, show, c, path);
            total.lines += c.lines;
            total.words += c.words;
            total.bytes += c.bytes;
        }
        if (multiple) try emit(ctx, show, total, "total");
    }
    return if (any_error) 1 else 0;
}

fn countReader(ctx: *Context, r: *std.Io.Reader) !Counts {
    _ = ctx;
    var c: Counts = .{};
    var in_word = false;
    while (true) {
        const peeked = r.peek(1) catch |e| switch (e) {
            error.EndOfStream => return c,
            else => return e,
        };
        const byte = peeked[0];
        r.toss(1);
        c.bytes += 1;
        if (byte == '\n') c.lines += 1;
        if (isSpace(byte)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            c.words += 1;
        }
    }
}

fn isSpace(b: u8) bool {
    return switch (b) {
        ' ', '\t', '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

fn emit(ctx: *Context, show: Show, c: Counts, path: ?[]const u8) !void {
    var first = true;
    if (show.lines) {
        try ctx.stdout.print("{d:>7}", .{c.lines});
        first = false;
    }
    if (show.words) {
        if (!first) try ctx.stdout.writeByte(' ');
        try ctx.stdout.print("{d:>7}", .{c.words});
        first = false;
    }
    if (show.bytes) {
        if (!first) try ctx.stdout.writeByte(' ');
        try ctx.stdout.print("{d:>7}", .{c.bytes});
        first = false;
    }
    if (path) |p| try ctx.stdout.print(" {s}", .{p});
    try ctx.stdout.writeByte('\n');
}
