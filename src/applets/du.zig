const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "du";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: du [OPTION]... [FILE]...
    \\
    \\Summarize disk usage of each FILE, recursively for directories.
    \\
    \\  -a, --all          show file sizes too, not just directory totals
    \\  -h, --human-readable  print sizes in human-readable form
    \\  -s, --summarize    display only a total for each argument
    \\  -k                 sizes in 1024-byte blocks (default)
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var show_all = false;
    var human = false;
    var summarize = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--all")) {
            show_all = true;
        } else if (std.mem.eql(u8, a, "--human-readable")) {
            human = true;
        } else if (std.mem.eql(u8, a, "--summarize")) {
            summarize = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'a' => show_all = true,
                'h' => human = true,
                's' => summarize = true,
                'k' => {},
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len == 0) try operands.append(ctx.arena, ".");

    const cwd = std.Io.Dir.cwd();
    var any_error = false;
    for (operands.items) |path| {
        const total = walk(ctx, cwd, path, show_all, summarize, human) catch |e| {
            ctx.err("cannot access '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        if (summarize) try emit(ctx, total, path, human);
    }
    return if (any_error) 1 else 0;
}

fn walk(ctx: *Context, cwd: std.Io.Dir, path: []const u8, show_all: bool, summarize: bool, human: bool) anyerror!u64 {
    // Try as a directory first.
    var dir = cwd.openDir(ctx.io, path, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            // It's a file: stat it and report.
            const f = try cwd.openFile(ctx.io, path, .{});
            defer f.close(ctx.io);
            const st = try f.stat(ctx.io);
            const blocks = blocksOf(st.size);
            if (show_all and !summarize) try emit(ctx, blocks, path, human);
            return blocks;
        },
        else => return e,
    };
    defer dir.close(ctx.io);

    var total: u64 = 0;
    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        const child_path = try std.fs.path.join(ctx.arena, &.{ path, entry.name });
        const child_size = walk(ctx, cwd, child_path, show_all, summarize, human) catch |e| {
            ctx.err("cannot access '{s}': {s}", .{ child_path, @errorName(e) });
            continue;
        };
        total += child_size;
    }

    if (!summarize) try emit(ctx, total, path, human);
    return total;
}

fn blocksOf(size: u64) u64 {
    return (size + 1023) / 1024;
}

fn emit(ctx: *Context, blocks: u64, path: []const u8, human: bool) !void {
    if (human) {
        try writeHuman(ctx.stdout, blocks * 1024);
    } else {
        try ctx.stdout.print("{d}", .{blocks});
    }
    try ctx.stdout.print("\t{s}\n", .{path});
}

fn writeHuman(w: *std.Io.Writer, n: u64) !void {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    if (i == 0) {
        try w.print("{d}", .{n});
    } else {
        try w.print("{d:.1}{s}", .{ v, units[i] });
    }
}
