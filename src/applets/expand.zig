const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "expand";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: expand [OPTION]... [FILE]...
    \\
    \\Convert tabs in each FILE to spaces, writing to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -i, --initial      do not convert tabs after non-blanks
    \\  -t, --tabs=N       tab stops every N characters (default 8)
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var initial = false;
    var tab: usize = 8;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--initial")) {
            initial = true;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 't'", .{});
                return 2;
            }
            tab = std.fmt.parseInt(usize, args[i], 10) catch 8;
        } else if (std.mem.startsWith(u8, a, "--tabs=")) {
            tab = std.fmt.parseInt(usize, a["--tabs=".len..], 10) catch 8;
        } else {
            try operands.append(ctx.arena, a);
        }
    }
    if (tab == 0) tab = 8;

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, tab, initial);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, tab, initial);
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
        try processReader(ctx, &fr.interface, tab, initial);
    }
    return if (any_error) 1 else 0;
}

fn processReader(ctx: *Context, r: *std.Io.Reader, tab: usize, initial: bool) !void {
    var col: usize = 0;
    var seen_non_blank = false;
    while (true) {
        const buf = r.peek(1) catch |e| switch (e) {
            error.EndOfStream => return,
            else => return e,
        };
        const c = buf[0];
        r.toss(1);
        switch (c) {
            '\t' => {
                if (initial and seen_non_blank) {
                    try ctx.stdout.writeByte('\t');
                    col += 1;
                } else {
                    const next_stop = ((col / tab) + 1) * tab;
                    const pad = next_stop - col;
                    try ctx.stdout.splatByteAll(' ', pad);
                    col = next_stop;
                }
            },
            '\n' => {
                try ctx.stdout.writeByte('\n');
                col = 0;
                seen_non_blank = false;
            },
            0x08 => {
                try ctx.stdout.writeByte(0x08);
                if (col > 0) col -= 1;
                seen_non_blank = true;
            },
            else => {
                try ctx.stdout.writeByte(c);
                col += 1;
                if (c != ' ') seen_non_blank = true;
            },
        }
    }
}
