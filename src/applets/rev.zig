const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "rev";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: rev [FILE]...
    \\
    \\Reverse the order of bytes in each line of FILE(s).
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        try operands.append(ctx.arena, a);
    }

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin);
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
        try processReader(ctx, &fr.interface);
    }
    return if (any_error) 1 else 0;
}

fn processReader(ctx: *Context, r: *std.Io.Reader) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    while (true) {
        line.clearRetainingCapacity();
        const had_more = readLine(r, ctx.arena, &line) catch |e| switch (e) {
            error.EndOfStream => false,
            else => return e,
        };
        if (line.items.len > 0) {
            std.mem.reverse(u8, line.items);
            try ctx.stdout.writeAll(line.items);
        }
        if (!had_more) return;
        try ctx.stdout.writeByte('\n');
    }
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
