const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "fmt";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: fmt [OPTION]... [FILE]...
    \\
    \\Reformat each paragraph in the FILE(s), writing to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -w, --width=WIDTH  maximum line width (default 75)
    \\      --help         display this help and exit
    \\
    \\Paragraphs are separated by blank lines.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var width: usize = 75;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'w'", .{});
                return 2;
            }
            width = std.fmt.parseInt(usize, args[i], 10) catch 75;
        } else if (std.mem.startsWith(u8, a, "--width=")) {
            width = std.fmt.parseInt(usize, a["--width=".len..], 10) catch 75;
        } else if (a.len >= 2 and a[0] == '-' and a[1] >= '0' and a[1] <= '9') {
            width = std.fmt.parseInt(usize, a[1..], 10) catch 75;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, width);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, width);
            continue;
        }
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer f.close(ctx.io);
        var rb: [8 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        try processReader(ctx, &fr.interface, width);
    }
    return if (any_error) 1 else 0;
}

fn processReader(ctx: *Context, r: *std.Io.Reader, width: usize) !void {
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.arena);
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};

    var paragraph: std.ArrayList(u8) = .empty;
    defer paragraph.deinit(ctx.arena);

    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            // Paragraph break.
            if (paragraph.items.len > 0) {
                try emitWrapped(ctx, paragraph.items, width);
                paragraph.clearRetainingCapacity();
            }
            try ctx.stdout.writeByte('\n');
            continue;
        }
        if (paragraph.items.len > 0) try paragraph.append(ctx.arena, ' ');
        try paragraph.appendSlice(ctx.arena, trimmed);
    }
    if (paragraph.items.len > 0) try emitWrapped(ctx, paragraph.items, width);
}

fn emitWrapped(ctx: *Context, text: []const u8, width: usize) !void {
    var col: usize = 0;
    var first_word_in_line = true;
    var word_it = std.mem.tokenizeAny(u8, text, " \t");
    while (word_it.next()) |word| {
        const sep_len: usize = if (first_word_in_line) 0 else 1;
        if (!first_word_in_line and col + sep_len + word.len > width) {
            try ctx.stdout.writeByte('\n');
            col = 0;
            first_word_in_line = true;
        }
        if (!first_word_in_line) {
            try ctx.stdout.writeByte(' ');
            col += 1;
        }
        try ctx.stdout.writeAll(word);
        col += word.len;
        first_word_in_line = false;
    }
    try ctx.stdout.writeByte('\n');
}
