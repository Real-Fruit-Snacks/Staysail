const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "nl";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: nl [OPTION]... [FILE]...
    \\
    \\Write each FILE to standard output, with line numbers added.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -b, --body-numbering=STYLE   a (number all) or t (number nonempty, default)
    \\  -s, --number-separator=STR   add STR after the line number (default \\t)
    \\  -w, --number-width=WIDTH     line number field width (default 6)
    \\      --help                   display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var number_all = false;
    var separator: []const u8 = "\t";
    var width: usize = 6;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.startsWith(u8, a, "-b")) {
            const val = if (a.len > 2) a[2..] else if (i + 1 < args.len) blk: {
                i += 1;
                break :blk args[i][0..];
            } else {
                ctx.usage("option requires an argument -- 'b'", .{});
                return 2;
            };
            if (val.len > 0 and val[0] == 'a') number_all = true;
        } else if (std.mem.startsWith(u8, a, "--body-numbering=")) {
            const val = a["--body-numbering=".len..];
            if (val.len > 0 and val[0] == 'a') number_all = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 's'", .{});
                return 2;
            }
            separator = args[i];
        } else if (std.mem.startsWith(u8, a, "--number-separator=")) {
            separator = a["--number-separator=".len..];
        } else if (std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'w'", .{});
                return 2;
            }
            width = std.fmt.parseInt(usize, args[i], 10) catch 6;
        } else if (std.mem.startsWith(u8, a, "--number-width=")) {
            width = std.fmt.parseInt(usize, a["--number-width=".len..], 10) catch 6;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var line_no: usize = 0;
    var any_error = false;

    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, number_all, separator, width, &line_no);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, number_all, separator, width, &line_no);
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
        try processReader(ctx, &fr.interface, number_all, separator, width, &line_no);
    }
    return if (any_error) 1 else 0;
}

fn processReader(
    ctx: *Context,
    r: *std.Io.Reader,
    number_all: bool,
    separator: []const u8,
    width: usize,
    line_no: *usize,
) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    while (true) {
        line.clearRetainingCapacity();
        const had_more = readLine(r, ctx.arena, &line) catch |e| switch (e) {
            error.EndOfStream => false,
            else => return e,
        };
        // EOS with no trailing data — don't emit a phantom blank line.
        if (!had_more and line.items.len == 0) return;

        const empty = line.items.len == 0;
        if (number_all or !empty) {
            line_no.* += 1;
            try printNumber(ctx.stdout, line_no.*, width);
            try ctx.stdout.writeAll(separator);
        } else {
            // GNU nl prints a blank field (spaces) before unnumbered lines.
            var k: usize = 0;
            while (k < width) : (k += 1) try ctx.stdout.writeByte(' ');
        }
        try ctx.stdout.writeAll(line.items);
        try ctx.stdout.writeByte('\n');
        if (!had_more) return;
    }
}

fn printNumber(w: *std.Io.Writer, n: usize, width: usize) !void {
    var sbuf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&sbuf, "{d}", .{n});
    if (s.len < width) try w.splatByteAll(' ', width - s.len);
    try w.writeAll(s);
}

fn readLine(r: *std.Io.Reader, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !bool {
    while (true) {
        const buf = r.peek(1) catch |e| switch (e) {
            error.EndOfStream => return error.EndOfStream,
            else => return e,
        };
        const c = buf[0];
        r.toss(1);
        if (c == '\n') return true;
        try out.append(gpa, c);
    }
}
