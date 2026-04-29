const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "tac";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: tac [OPTION]... [FILE]...
    \\
    \\Write each FILE to standard output, last line first.
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
        try emitReader(ctx, ctx.stdin);
    } else {
        for (operands.items) |path| {
            if (std.mem.eql(u8, path, "-")) {
                try emitReader(ctx, ctx.stdin);
                continue;
            }
            const cwd = std.Io.Dir.cwd();
            const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
                ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
            defer f.close(ctx.io);
            var rb: [16 * 1024]u8 = undefined;
            var fr = f.reader(ctx.io, &rb);
            try emitReader(ctx, &fr.interface);
        }
    }
    return if (any_error) 1 else 0;
}

fn emitReader(ctx: *Context, r: *std.Io.Reader) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.arena);
    r.appendRemainingUnlimited(ctx.arena, &buf) catch {};

    const data = buf.items;
    if (data.len == 0) return;

    // Strip one trailing newline so we don't double-emit the final separator.
    const data_end: usize = if (data[data.len - 1] == '\n') data.len - 1 else data.len;

    var end: usize = data_end;
    var i: usize = data_end;
    while (i > 0) {
        i -= 1;
        if (data[i] == '\n') {
            try ctx.stdout.writeAll(data[i + 1 .. end]);
            try ctx.stdout.writeByte('\n');
            end = i;
        }
    }
    if (end > 0) {
        try ctx.stdout.writeAll(data[0..end]);
        try ctx.stdout.writeByte('\n');
    }
}
