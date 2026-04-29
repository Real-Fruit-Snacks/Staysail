const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "comm";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: comm [OPTION]... FILE1 FILE2
    \\
    \\Compare sorted FILE1 and FILE2 line by line.
    \\Output three columns: lines unique to FILE1, lines unique to FILE2,
    \\and lines common to both. Use - for stdin.
    \\
    \\  -1            suppress column 1 (lines unique to FILE1)
    \\  -2            suppress column 2 (lines unique to FILE2)
    \\  -3            suppress column 3 (lines common to both)
    \\      --help    display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var suppress: [3]bool = .{ false, false, false };
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-1")) {
            suppress[0] = true;
        } else if (std.mem.eql(u8, a, "-2")) {
            suppress[1] = true;
        } else if (std.mem.eql(u8, a, "-3")) {
            suppress[2] = true;
        } else {
            try paths.append(ctx.arena, a);
        }
    }
    if (paths.items.len != 2) {
        ctx.usage("expected exactly 2 file arguments", .{});
        return 2;
    }

    const lines1 = try slurpLines(ctx, paths.items[0]);
    const lines2 = try slurpLines(ctx, paths.items[1]);

    // Tabs for column separation.
    var prefix1: []const u8 = "";
    var prefix2: []const u8 = "";
    var prefix3: []const u8 = "";
    if (!suppress[0]) {
        prefix1 = "";
        if (!suppress[1]) prefix2 = "\t";
        if (!suppress[1] and !suppress[2]) prefix3 = "\t\t" else if (!suppress[2]) prefix3 = "\t";
    } else {
        if (!suppress[1]) prefix2 = "";
        if (!suppress[1] and !suppress[2]) prefix3 = "\t" else if (!suppress[2]) prefix3 = "";
    }

    var i: usize = 0;
    var j: usize = 0;
    while (i < lines1.len and j < lines2.len) {
        const cmp = std.mem.order(u8, lines1[i], lines2[j]);
        switch (cmp) {
            .lt => {
                if (!suppress[0]) try ctx.stdout.print("{s}{s}\n", .{ prefix1, lines1[i] });
                i += 1;
            },
            .gt => {
                if (!suppress[1]) try ctx.stdout.print("{s}{s}\n", .{ prefix2, lines2[j] });
                j += 1;
            },
            .eq => {
                if (!suppress[2]) try ctx.stdout.print("{s}{s}\n", .{ prefix3, lines1[i] });
                i += 1;
                j += 1;
            },
        }
    }
    while (i < lines1.len) : (i += 1) {
        if (!suppress[0]) try ctx.stdout.print("{s}{s}\n", .{ prefix1, lines1[i] });
    }
    while (j < lines2.len) : (j += 1) {
        if (!suppress[1]) try ctx.stdout.print("{s}{s}\n", .{ prefix2, lines2[j] });
    }
    return 0;
}

fn slurpLines(ctx: *Context, path: []const u8) ![]const []const u8 {
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
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return lines.toOwnedSlice(ctx.arena);
}
