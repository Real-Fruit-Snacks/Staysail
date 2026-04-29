const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "unexpand";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: unexpand [OPTION]... [FILE]...
    \\
    \\Convert blanks in each FILE to tabs, writing to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -a, --all          convert all blanks, not just initial blanks
    \\  -t, --tabs=N       tab stops every N characters (default 8)
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var all = false;
    var tab: usize = 8;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len) return 2;
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
        try processReader(ctx, ctx.stdin, tab, all);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, tab, all);
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
        try processReader(ctx, &fr.interface, tab, all);
    }
    return if (any_error) 1 else 0;
}

fn processReader(ctx: *Context, r: *std.Io.Reader, tab: usize, all: bool) !void {
    // Buffer one line at a time so we can rewrite leading (or all) runs of
    // spaces into tabs.
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    while (true) {
        line.clearRetainingCapacity();
        const had_more = readLine(r, ctx.arena, &line) catch |e| switch (e) {
            error.EndOfStream => false,
            else => return e,
        };
        try emit(ctx, line.items, tab, all);
        if (!had_more) {
            if (line.items.len > 0) try ctx.stdout.writeByte('\n');
            return;
        }
        try ctx.stdout.writeByte('\n');
    }
}

fn emit(ctx: *Context, line: []const u8, tab: usize, all: bool) !void {
    var col: usize = 0;
    var i: usize = 0;
    var in_initial_blanks = true;
    while (i < line.len) {
        const c = line[i];
        if (c == ' ' and (all or in_initial_blanks)) {
            // Try to coalesce a run of spaces into tabs at every tab stop.
            const next_stop = ((col / tab) + 1) * tab;
            const need = next_stop - col;
            if (i + need <= line.len and allSpaces(line[i .. i + need])) {
                try ctx.stdout.writeByte('\t');
                col = next_stop;
                i += need;
                continue;
            }
            // Otherwise pass through the rest of the spaces verbatim.
            while (i < line.len and line[i] == ' ') {
                try ctx.stdout.writeByte(' ');
                col += 1;
                i += 1;
            }
            continue;
        }
        if (c != ' ' and c != '\t') in_initial_blanks = false;
        if (c == '\t') {
            try ctx.stdout.writeByte('\t');
            col = ((col / tab) + 1) * tab;
            i += 1;
            continue;
        }
        try ctx.stdout.writeByte(c);
        col += 1;
        i += 1;
    }
}

fn allSpaces(s: []const u8) bool {
    for (s) |b| if (b != ' ') return false;
    return true;
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
