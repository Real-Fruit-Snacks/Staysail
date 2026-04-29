const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "fold";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: fold [OPTION]... [FILE]...
    \\
    \\Wrap input lines in each FILE, writing to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -b, --bytes        count bytes rather than columns
    \\  -s, --spaces       break at spaces
    \\  -w, --width=WIDTH  use WIDTH columns instead of 80
    \\      --help         display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var bytes_mode = false;
    var space_break = false;
    var width: usize = 80;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--bytes")) {
            bytes_mode = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--spaces")) {
            space_break = true;
        } else if (std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'w'", .{});
                return 2;
            }
            width = std.fmt.parseInt(usize, args[i], 10) catch {
                ctx.err("invalid width: '{s}'", .{args[i]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, a, "--width=")) {
            width = std.fmt.parseInt(usize, a["--width=".len..], 10) catch {
                ctx.err("invalid width", .{});
                return 1;
            };
        } else if (a.len >= 2 and a[0] == '-' and isDigit(a[1])) {
            // Legacy: -<N>
            width = std.fmt.parseInt(usize, a[1..], 10) catch {
                ctx.err("invalid width: '{s}'", .{a});
                return 1;
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (width == 0) {
        ctx.err("invalid number of columns: '0'", .{});
        return 1;
    }

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, width, bytes_mode, space_break);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, width, bytes_mode, space_break);
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
        try processReader(ctx, &fr.interface, width, bytes_mode, space_break);
    }
    return if (any_error) 1 else 0;
}

fn processReader(ctx: *Context, r: *std.Io.Reader, width: usize, bytes_mode: bool, space_break: bool) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    while (true) {
        line.clearRetainingCapacity();
        const more = readLine(r, ctx.arena, &line) catch |e| switch (e) {
            error.EndOfStream => false,
            else => return e,
        };
        try emitWrapped(ctx, line.items, width, bytes_mode, space_break);
        if (!more) {
            if (line.items.len > 0) try ctx.stdout.writeByte('\n');
            return;
        }
        try ctx.stdout.writeByte('\n');
    }
}

fn emitWrapped(ctx: *Context, line: []const u8, width: usize, bytes_mode: bool, space_break: bool) !void {
    _ = bytes_mode; // For Phase 2, we treat bytes/columns identically (no UTF-8 width).
    var pos: usize = 0;
    while (line.len - pos > width) {
        var cut: usize = pos + width;
        if (space_break) {
            // Find the last space within [pos, cut].
            var k = cut;
            while (k > pos) : (k -= 1) {
                if (line[k - 1] == ' ' or line[k - 1] == '\t') {
                    cut = k;
                    break;
                }
            }
        }
        try ctx.stdout.writeAll(line[pos..cut]);
        try ctx.stdout.writeByte('\n');
        pos = cut;
    }
    try ctx.stdout.writeAll(line[pos..]);
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

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
