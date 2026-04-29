const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "cat";
pub const aliases: []const []const u8 = &.{"type"}; // Windows alias
pub const help: []const u8 =
    \\Usage: cat [OPTION]... [FILE]...
    \\
    \\Concatenate FILE(s) to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -n, --number     number all output lines
    \\  -b, --number-nonblank
    \\                   number nonempty output lines (overrides -n)
    \\  -E, --show-ends  display $ at end of each line
    \\  -s, --squeeze-blank
    \\                   suppress repeated empty output lines
    \\      --help       display this help and exit
    \\
;

const Options = struct {
    number: bool = false,
    number_nonblank: bool = false,
    show_ends: bool = false,
    squeeze_blank: bool = false,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var opts: Options = .{};
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
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-' and !(a.len == 1)) {
            // Short flags, possibly bundled.
            for (a[1..]) |c| switch (c) {
                'n' => opts.number = true,
                'b' => opts.number_nonblank = true,
                'E' => opts.show_ends = true,
                's' => opts.squeeze_blank = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else if (std.mem.eql(u8, a, "--number")) {
            opts.number = true;
        } else if (std.mem.eql(u8, a, "--number-nonblank")) {
            opts.number_nonblank = true;
        } else if (std.mem.eql(u8, a, "--show-ends")) {
            opts.show_ends = true;
        } else if (std.mem.eql(u8, a, "--squeeze-blank")) {
            opts.squeeze_blank = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    // -b overrides -n (per POSIX/coreutils).
    if (opts.number_nonblank) opts.number = false;

    var line_no: usize = 0;
    var prev_blank = false;
    var any_error = false;

    if (operands.items.len == 0) {
        try copy(ctx, ctx.stdin, &opts, &line_no, &prev_blank);
    } else {
        for (operands.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try copy(ctx, ctx.stdin, &opts, &line_no, &prev_blank);
                continue;
            }
            const cwd = std.Io.Dir.cwd();
            const file = cwd.openFile(ctx.io, path, .{}) catch |e| {
                ctx.err("{s}: {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
            defer file.close(ctx.io);
            var read_buf: [8 * 1024]u8 = undefined;
            var fr = file.reader(ctx.io, &read_buf);
            try copy(ctx, &fr.interface, &opts, &line_no, &prev_blank);
        }
    }
    return if (any_error) 1 else 0;
}

fn copy(
    ctx: *Context,
    r: *std.Io.Reader,
    opts: *const Options,
    line_no: *usize,
    prev_blank: *bool,
) !void {
    const transform = opts.number or opts.number_nonblank or opts.show_ends or opts.squeeze_blank;
    if (!transform) {
        // Fast path: stream raw bytes through. streamRemaining returns when
        // the source signals EOS internally.
        _ = try r.streamRemaining(ctx.stdout);
        return;
    }

    // Slow path: line-oriented transformation.
    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(ctx.arena);

    while (true) {
        line_buf.clearRetainingCapacity();
        readLine(r, ctx.arena, &line_buf) catch |e| switch (e) {
            error.EndOfStream => {
                if (line_buf.items.len == 0) return;
                // Trailing line without newline: emit without one.
                try emitLine(ctx, opts, line_no, prev_blank, line_buf.items, false);
                return;
            },
            else => return e,
        };
        try emitLine(ctx, opts, line_no, prev_blank, line_buf.items, true);
    }
}

fn readLine(r: *std.Io.Reader, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    while (true) {
        const buf = r.peek(1) catch |e| switch (e) {
            error.EndOfStream => return error.EndOfStream,
            else => return e,
        };
        const c = buf[0];
        r.toss(1);
        if (c == '\n') return;
        try out.append(gpa, c);
    }
}

fn emitLine(
    ctx: *Context,
    opts: *const Options,
    line_no: *usize,
    prev_blank: *bool,
    line: []const u8,
    has_newline: bool,
) !void {
    const is_blank = line.len == 0;
    if (opts.squeeze_blank and is_blank and prev_blank.*) return;
    prev_blank.* = is_blank;

    const should_number = (opts.number) or (opts.number_nonblank and !is_blank);
    if (should_number) {
        line_no.* += 1;
        try ctx.stdout.print("{d:6}\t", .{line_no.*});
    }
    try ctx.stdout.writeAll(line);
    if (opts.show_ends) try ctx.stdout.writeByte('$');
    if (has_newline) try ctx.stdout.writeByte('\n');
}
