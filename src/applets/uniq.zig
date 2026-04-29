const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "uniq";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: uniq [OPTION]... [INPUT [OUTPUT]]
    \\
    \\Filter adjacent matching lines from INPUT (or standard input),
    \\writing to OUTPUT (or standard output).
    \\
    \\  -c, --count        prefix lines by the number of occurrences
    \\  -d, --repeated     only print duplicate lines, one per group
    \\  -u, --unique       only print unique lines
    \\  -i, --ignore-case  ignore differences in case when comparing
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var count = false;
    var only_dup = false;
    var only_uniq = false;
    var ignore_case = false;
    var input_path: ?[:0]const u8 = null;
    var output_path: ?[:0]const u8 = null;

    var positional: usize = 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--count")) {
            count = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--repeated")) {
            only_dup = true;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--unique")) {
            only_uniq = true;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
            ignore_case = true;
        } else {
            if (positional == 0) input_path = a else output_path = a;
            positional += 1;
        }
    }

    var lines: std.ArrayList([]const u8) = .empty;
    if (input_path == null or std.mem.eql(u8, input_path.?, "-")) {
        try slurpLines(ctx, ctx.stdin, &lines);
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, input_path.?, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ input_path.?, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        try slurpLines(ctx, &fr.interface, &lines);
    }

    // Output writer: file or stdout.
    var output_buf: [16 * 1024]u8 = undefined;
    var out_fw: ?std.Io.File.Writer = null;
    var out_writer: *std.Io.Writer = ctx.stdout;
    var out_file: ?std.Io.File = null;
    defer if (out_file) |of| of.close(ctx.io);
    if (output_path) |op| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(ctx.io, op, .{}) catch |e| {
            ctx.err("cannot create '{s}': {s}", .{ op, @errorName(e) });
            return 1;
        };
        out_file = f;
        out_fw = .init(f, ctx.io, &output_buf);
        out_writer = &out_fw.?.interface;
    }
    defer if (out_fw) |*fw| fw.interface.flush() catch {};

    var i: usize = 0;
    while (i < lines.items.len) {
        var j: usize = i + 1;
        while (j < lines.items.len and linesEqual(lines.items[i], lines.items[j], ignore_case)) {
            j += 1;
        }
        const group_count = j - i;
        const should_print = if (only_dup) group_count > 1 else if (only_uniq) group_count == 1 else true;
        if (should_print) {
            if (count) try out_writer.print("{d:>7} ", .{group_count});
            try out_writer.writeAll(lines.items[i]);
            try out_writer.writeByte('\n');
        }
        i = j;
    }
    return 0;
}

fn linesEqual(a: []const u8, b: []const u8, ignore_case: bool) bool {
    if (!ignore_case) return std.mem.eql(u8, a, b);
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) : (i += 1) {
        if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[i])) return false;
    }
    return true;
}

fn slurpLines(ctx: *Context, r: *std.Io.Reader, out: *std.ArrayList([]const u8)) !void {
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};
    const owned = try data.toOwnedSlice(ctx.arena);
    var it = std.mem.splitScalar(u8, owned, '\n');
    while (it.next()) |line| try out.append(ctx.arena, line);
    if (out.items.len > 0 and out.items[out.items.len - 1].len == 0) _ = out.pop();
}
