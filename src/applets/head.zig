const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "head";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: head [OPTION]... [FILE]...
    \\
    \\Print the first 10 lines of each FILE to standard output.
    \\With more than one FILE, precede each with a header giving the file name.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -n, --lines=K   print the first K lines instead of the first 10
    \\  -c, --bytes=K   print the first K bytes of each file
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
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "--silent")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'n'", .{});
                return 2;
            }
            count = parseCount(args[i]) orelse {
                ctx.err("invalid number of lines: '{s}'", .{args[i]});
                return 1;
            };
            mode = .lines;
        } else if (std.mem.startsWith(u8, a, "--lines=")) {
            count = parseCount(a["--lines=".len..]) orelse {
                ctx.err("invalid number of lines: '{s}'", .{a["--lines=".len..]});
                return 1;
            };
            mode = .lines;
        } else if (std.mem.eql(u8, a, "-c")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'c'", .{});
                return 2;
            }
            count = parseCount(args[i]) orelse {
                ctx.err("invalid number of bytes: '{s}'", .{args[i]});
                return 1;
            };
            mode = .bytes;
        } else if (std.mem.startsWith(u8, a, "--bytes=")) {
            count = parseCount(a["--bytes=".len..]) orelse {
                ctx.err("invalid number of bytes: '{s}'", .{a["--bytes=".len..]});
                return 1;
            };
            mode = .bytes;
        } else if (a.len >= 2 and a[0] == '-' and isDigit(a[1])) {
            // Legacy form: -<N> means -n <N>.
            count = parseCount(a[1..]) orelse {
                ctx.err("invalid number: '{s}'", .{a});
                return 1;
            };
            mode = .lines;
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
    switch (mode) {
        .bytes => {
            var remaining = count;
            while (remaining > 0) {
                const chunk = r.peek(1) catch |e| switch (e) {
                    error.EndOfStream => return,
                    else => return e,
                };
                _ = chunk;
                const want: usize = @intCast(@min(remaining, 4096));
                const got = r.peek(want) catch |e| switch (e) {
                    error.EndOfStream => blk: {
                        const buffered = r.buffered();
                        if (buffered.len == 0) return;
                        try ctx.stdout.writeAll(buffered);
                        r.toss(buffered.len);
                        break :blk null;
                    },
                    else => return e,
                };
                if (got == null) return;
                const slice = got.?;
                try ctx.stdout.writeAll(slice);
                r.toss(slice.len);
                remaining -|= slice.len;
            }
        },
        .lines => {
            var remaining = count;
            while (remaining > 0) {
                const c = r.peek(1) catch |e| switch (e) {
                    error.EndOfStream => return,
                    else => return e,
                };
                const byte = c[0];
                try ctx.stdout.writeByte(byte);
                r.toss(1);
                if (byte == '\n') remaining -= 1;
            }
        },
    }
}

fn parseCount(s: []const u8) ?u64 {
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
