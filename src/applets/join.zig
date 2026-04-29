const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "join";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: join [OPTION]... FILE1 FILE2
    \\
    \\Join lines of two files on a common field. Both files must be sorted on
    \\the join field. By default the first field is used and the separator is
    \\runs of whitespace.
    \\
    \\  -t CHAR              use CHAR as the input/output field separator
    \\  -1 N                 join on the Nth field of FILE1 (default 1)
    \\  -2 N                 join on the Nth field of FILE2 (default 1)
    \\  -j N                 join on the Nth field of both files
    \\      --help           display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var sep: ?u8 = null;
    var f1_field: usize = 1;
    var f2_field: usize = 1;
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return 2;
            sep = args[i][0];
        } else if (std.mem.eql(u8, a, "-1")) {
            i += 1;
            if (i >= args.len) return 2;
            f1_field = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, a, "-2")) {
            i += 1;
            if (i >= args.len) return 2;
            f2_field = std.fmt.parseInt(usize, args[i], 10) catch 1;
        } else if (std.mem.eql(u8, a, "-j")) {
            i += 1;
            if (i >= args.len) return 2;
            const n = std.fmt.parseInt(usize, args[i], 10) catch 1;
            f1_field = n;
            f2_field = n;
        } else {
            try paths.append(ctx.arena, a);
        }
    }
    if (paths.items.len != 2) {
        ctx.usage("expected exactly 2 file arguments", .{});
        return 2;
    }

    const out_sep: []const u8 = if (sep) |s| &.{s} else " ";

    const a_lines = try slurpLines(ctx, paths.items[0]) orelse return 2;
    const b_lines = try slurpLines(ctx, paths.items[1]) orelse return 2;

    var i_a: usize = 0;
    var i_b: usize = 0;
    while (i_a < a_lines.len and i_b < b_lines.len) {
        const a_fields = try splitFields(ctx.arena, a_lines[i_a], sep);
        const b_fields = try splitFields(ctx.arena, b_lines[i_b], sep);
        const a_key = if (f1_field <= a_fields.len) a_fields[f1_field - 1] else "";
        const b_key = if (f2_field <= b_fields.len) b_fields[f2_field - 1] else "";

        const cmp = std.mem.order(u8, a_key, b_key);
        switch (cmp) {
            .lt => i_a += 1,
            .gt => i_b += 1,
            .eq => {
                try ctx.stdout.writeAll(a_key);
                for (a_fields, 0..) |f, idx| {
                    if (idx + 1 == f1_field) continue;
                    try ctx.stdout.writeAll(out_sep);
                    try ctx.stdout.writeAll(f);
                }
                for (b_fields, 0..) |f, idx| {
                    if (idx + 1 == f2_field) continue;
                    try ctx.stdout.writeAll(out_sep);
                    try ctx.stdout.writeAll(f);
                }
                try ctx.stdout.writeByte('\n');
                i_a += 1;
                i_b += 1;
            },
        }
    }
    return 0;
}

fn splitFields(gpa: std.mem.Allocator, line: []const u8, sep: ?u8) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    if (sep) |s| {
        var it = std.mem.splitScalar(u8, line, s);
        while (it.next()) |f| try fields.append(gpa, f);
    } else {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |f| try fields.append(gpa, f);
    }
    return fields.toOwnedSlice(gpa);
}

fn slurpLines(ctx: *Context, path: []const u8) !?[]const []const u8 {
    var data: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, path, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return null;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| try lines.append(ctx.arena, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return try lines.toOwnedSlice(ctx.arena);
}
