const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "tail";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: tail [OPTION]... [FILE]...
    \\
    \\Print the last 10 lines of each FILE to standard output.
    \\With more than one FILE, precede each with a header giving the file name.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -n, --lines=K   output the last K lines (default 10)
    \\  -c, --bytes=K   output the last K bytes of each file
    \\  -q, --quiet     never print headers giving file names
    \\  -v, --verbose   always print headers giving file names
    \\      --help      display this help and exit
    \\
;

const Mode = enum { lines, bytes };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var mode: Mode = .lines;
    var count: u64 = 10;
    var quiet = false;
    var verbose = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try operands.append(ctx.arena, args[i]);
            break;
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'n'", .{});
                return 2;
            }
            count = std.fmt.parseInt(u64, args[i], 10) catch {
                ctx.err("invalid number of lines: '{s}'", .{args[i]});
                return 1;
            };
            mode = .lines;
        } else if (std.mem.startsWith(u8, a, "--lines=")) {
            const v = a["--lines=".len..];
            count = std.fmt.parseInt(u64, v, 10) catch {
                ctx.err("invalid number of lines: '{s}'", .{v});
                return 1;
            };
            mode = .lines;
        } else if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'c'", .{});
                return 2;
            }
            count = std.fmt.parseInt(u64, args[i], 10) catch {
                ctx.err("invalid number of bytes: '{s}'", .{args[i]});
                return 1;
            };
            mode = .bytes;
        } else if (std.mem.startsWith(u8, a, "--bytes=")) {
            const v = a["--bytes=".len..];
            count = std.fmt.parseInt(u64, v, 10) catch {
                ctx.err("invalid number of bytes: '{s}'", .{v});
                return 1;
            };
            mode = .bytes;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    const print_headers = (operands.items.len > 1 or verbose) and !quiet;
    var any_error = false;

    if (operands.items.len == 0) {
        try emitFromReader(ctx, ctx.stdin, mode, count);
    } else {
        for (operands.items, 0..) |path, idx| {
            if (print_headers) {
                if (idx > 0) try ctx.stdout.writeByte('\n');
                try ctx.stdout.print("==> {s} <==\n", .{path});
            }
            if (std.mem.eql(u8, path, "-")) {
                try emitFromReader(ctx, ctx.stdin, mode, count);
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
            try emitFromReader(ctx, &fr.interface, mode, count);
        }
    }
    return if (any_error) 1 else 0;
}

fn emitFromReader(ctx: *Context, r: *std.Io.Reader, mode: Mode, count: u64) !void {
    // Slurp the whole stream into memory. Acceptable for Phase 1 — large-file
    // tail is a Phase 2 optimization (seek-from-end for files, ring buffer for
    // streams).
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.arena);
    r.appendRemainingUnlimited(ctx.arena, &buf) catch {};

    const data = buf.items;
    if (data.len == 0) return;

    switch (mode) {
        .bytes => {
            const start = if (count >= data.len) 0 else data.len - @as(usize, @intCast(count));
            try ctx.stdout.writeAll(data[start..]);
        },
        .lines => {
            // Walk back from the end, counting newlines (excluding any
            // trailing one). When we've seen `count` non-trailing newlines,
            // the start of the next line is one past that index.
            const skip_trailing = data[data.len - 1] == '\n';
            var i: usize = if (skip_trailing) data.len - 1 else data.len;
            var newlines_seen: u64 = 0;
            var start: usize = 0;
            while (i > 0) {
                i -= 1;
                if (data[i] == '\n') {
                    newlines_seen += 1;
                    if (newlines_seen == count) {
                        start = i + 1;
                        break;
                    }
                }
            }
            try ctx.stdout.writeAll(data[start..]);
        },
    }
}
