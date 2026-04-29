const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "cut";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: cut OPTION... [FILE]...
    \\
    \\Print selected parts of lines from each FILE to standard output.
    \\
    \\  -b, --bytes=LIST       select only these bytes
    \\  -c, --characters=LIST  select only these characters (treated as bytes)
    \\  -d, --delimiter=DELIM  use DELIM instead of TAB for field delimiter
    \\  -f, --fields=LIST      select only these fields
    \\  -s, --only-delimited   do not print lines not containing delimiters
    \\      --help             display this help and exit
    \\
    \\LIST is a comma-separated list of ranges: N, N-M, N-, -M.
    \\
;

const Mode = enum { bytes, fields };

const Range = struct { start: usize, end: usize }; // 1-based, inclusive; end=0 means "to end of line"

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var mode: ?Mode = null;
    var list_str: ?[]const u8 = null;
    var delim: u8 = '\t';
    var only_delimited = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (a.len >= 2 and a[0] == '-' and (a[1] == 'b' or a[1] == 'c' or a[1] == 'f' or a[1] == 'd')) {
            // Short option with optional attached value: -dDELIM, -f1,3, -dD.
            const flag = a[1];
            const attached = a[2..];
            const value: []const u8 = if (attached.len > 0) attached else blk: {
                i += 1;
                if (i >= args.len) {
                    ctx.usage("option requires an argument -- '{c}'", .{flag});
                    return 2;
                }
                break :blk args[i];
            };
            switch (flag) {
                'b', 'c' => {
                    mode = .bytes;
                    list_str = value;
                },
                'f' => {
                    mode = .fields;
                    list_str = value;
                },
                'd' => {
                    if (value.len == 0) {
                        ctx.usage("delimiter must not be empty", .{});
                        return 2;
                    }
                    delim = value[0];
                },
                else => unreachable,
            }
        } else if (std.mem.startsWith(u8, a, "--bytes=") or std.mem.startsWith(u8, a, "--characters=")) {
            mode = .bytes;
            const eq = std.mem.indexOfScalar(u8, a, '=').?;
            list_str = a[eq + 1 ..];
        } else if (std.mem.startsWith(u8, a, "--fields=")) {
            mode = .fields;
            list_str = a["--fields=".len..];
        } else if (std.mem.startsWith(u8, a, "--delimiter=")) {
            const v = a["--delimiter=".len..];
            if (v.len == 0) {
                ctx.usage("delimiter must not be empty", .{});
                return 2;
            }
            delim = v[0];
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--only-delimited")) {
            only_delimited = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (mode == null or list_str == null) {
        ctx.usage("you must specify -b, -c, or -f", .{});
        return 2;
    }

    const ranges = parseRanges(ctx.arena, list_str.?) catch {
        ctx.err("invalid range list: '{s}'", .{list_str.?});
        return 1;
    };

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, mode.?, ranges, delim, only_delimited);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try processReader(ctx, ctx.stdin, mode.?, ranges, delim, only_delimited);
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
        try processReader(ctx, &fr.interface, mode.?, ranges, delim, only_delimited);
    }
    return if (any_error) 1 else 0;
}

fn processReader(
    ctx: *Context,
    r: *std.Io.Reader,
    mode: Mode,
    ranges: []const Range,
    delim: u8,
    only_delimited: bool,
) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(ctx.arena);
    while (true) {
        line.clearRetainingCapacity();
        const more = readLine(r, ctx.arena, &line) catch |e| switch (e) {
            error.EndOfStream => false,
            else => return e,
        };
        try emit(ctx, mode, ranges, delim, only_delimited, line.items);
        if (!more) {
            if (line.items.len > 0) try ctx.stdout.writeByte('\n');
            return;
        }
        try ctx.stdout.writeByte('\n');
    }
}

fn emit(
    ctx: *Context,
    mode: Mode,
    ranges: []const Range,
    delim: u8,
    only_delimited: bool,
    line: []const u8,
) !void {
    switch (mode) {
        .bytes => {
            for (ranges) |r| {
                const start = if (r.start == 0) 0 else r.start - 1;
                const end = if (r.end == 0) line.len else @min(r.end, line.len);
                if (start < line.len and start < end) try ctx.stdout.writeAll(line[start..end]);
            }
        },
        .fields => {
            // Split on delim.
            var fields: std.ArrayList([]const u8) = .empty;
            defer fields.deinit(ctx.arena);
            var it = std.mem.splitScalar(u8, line, delim);
            while (it.next()) |f| try fields.append(ctx.arena, f);
            if (fields.items.len <= 1) {
                if (only_delimited) return;
                try ctx.stdout.writeAll(line);
                return;
            }
            var first = true;
            for (ranges) |r| {
                const start = if (r.start == 0) 1 else r.start;
                const end = if (r.end == 0) fields.items.len else @min(r.end, fields.items.len);
                var fi = start;
                while (fi <= end) : (fi += 1) {
                    if (!first) try ctx.stdout.writeByte(delim);
                    first = false;
                    try ctx.stdout.writeAll(fields.items[fi - 1]);
                }
            }
        },
    }
}

fn parseRanges(gpa: std.mem.Allocator, list: []const u8) ![]Range {
    var out: std.ArrayList(Range) = .empty;
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) continue;
        var r: Range = .{ .start = 1, .end = 0 };
        if (std.mem.indexOfScalar(u8, part, '-')) |dash| {
            const a = part[0..dash];
            const b = part[dash + 1 ..];
            r.start = if (a.len == 0) 1 else try std.fmt.parseInt(usize, a, 10);
            r.end = if (b.len == 0) 0 else try std.fmt.parseInt(usize, b, 10);
        } else {
            const n = try std.fmt.parseInt(usize, part, 10);
            r.start = n;
            r.end = n;
        }
        try out.append(gpa, r);
    }
    return out.toOwnedSlice(gpa);
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
