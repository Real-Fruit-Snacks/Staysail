const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "paste";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: paste [OPTION]... [FILE]...
    \\
    \\Write lines from each FILE separated by TAB to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -d, --delimiters=LIST   reuse characters from LIST instead of TAB
    \\  -s, --serial            paste one file at a time (lines from one file
    \\                          on a single line)
    \\      --help              display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var delimiters: []const u8 = "\t";
    var serial = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--serial")) {
            serial = true;
        } else if (std.mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'd'", .{});
                return 2;
            }
            delimiters = args[i];
        } else if (std.mem.startsWith(u8, a, "--delimiters=")) {
            delimiters = a["--delimiters=".len..];
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try operands.append(ctx.arena, args[i]);
            break;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (delimiters.len == 0) delimiters = "\t";

    if (operands.items.len == 0) {
        // With no files, just pass stdin through.
        _ = try ctx.stdin.streamRemaining(ctx.stdout);
        return 0;
    }

    if (serial) {
        for (operands.items) |path| try pasteSerial(ctx, path, delimiters);
        return 0;
    }
    return pasteParallel(ctx, operands.items, delimiters);
}

fn pasteSerial(ctx: *Context, path: []const u8, delimiters: []const u8) !void {
    const lines = try readAllLines(ctx, path);
    defer freeLines(ctx.arena, lines);
    for (lines, 0..) |line, idx| {
        if (idx > 0) try ctx.stdout.writeByte(delimiters[(idx - 1) % delimiters.len]);
        try ctx.stdout.writeAll(line);
    }
    try ctx.stdout.writeByte('\n');
}

fn pasteParallel(ctx: *Context, paths: []const [:0]const u8, delimiters: []const u8) !u8 {
    // Slurp every file into a list of lines. Stream-style merge would be
    // nicer but this is fine for Phase 2.
    const all_lines = try ctx.arena.alloc([]const []const u8, paths.len);
    for (paths, 0..) |p, j| all_lines[j] = try readAllLines(ctx, p);

    var max_lines: usize = 0;
    for (all_lines) |lines| if (lines.len > max_lines) {
        max_lines = lines.len;
    };

    var row: usize = 0;
    while (row < max_lines) : (row += 1) {
        for (all_lines, 0..) |lines, col| {
            if (col > 0) try ctx.stdout.writeByte(delimiters[(col - 1) % delimiters.len]);
            if (row < lines.len) try ctx.stdout.writeAll(lines[row]);
        }
        try ctx.stdout.writeByte('\n');
    }
    return 0;
}

fn readAllLines(ctx: *Context, path: []const u8) ![]const []const u8 {
    var data: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, path, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(ctx.io, path, .{});
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| try lines.append(ctx.arena, line);
    // Drop the empty trailing element from a final newline.
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) {
        _ = lines.pop();
    }
    return try lines.toOwnedSlice(ctx.arena);
}

fn freeLines(_: std.mem.Allocator, _: []const []const u8) void {
    // arena-allocated; nothing to do
}
