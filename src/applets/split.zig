const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "split";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: split [OPTION]... [FILE [PREFIX]]
    \\
    \\Output pieces of FILE to PREFIXaa, PREFIXab, ...
    \\Default PREFIX is 'x'. With no FILE, or when FILE is -, read standard input.
    \\
    \\  -l, --lines=N      put N lines per output file (default 1000)
    \\  -b, --bytes=N      put N bytes per output file (suffixes K, M, G allowed)
    \\  -a, --suffix-length=N  use suffixes of length N (default 2)
    \\      --help         display this help and exit
    \\
;

const Mode = enum { lines, bytes };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var mode: Mode = .lines;
    var count: u64 = 1000;
    var suffix_len: usize = 2;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-l")) {
            i += 1;
            if (i >= args.len) return 2;
            count = std.fmt.parseInt(u64, args[i], 10) catch 1000;
            mode = .lines;
        } else if (std.mem.startsWith(u8, a, "--lines=")) {
            count = std.fmt.parseInt(u64, a["--lines=".len..], 10) catch 1000;
            mode = .lines;
        } else if (std.mem.eql(u8, a, "-b")) {
            i += 1;
            if (i >= args.len) return 2;
            count = parseSize(args[i]) orelse {
                ctx.err("invalid byte count: '{s}'", .{args[i]});
                return 1;
            };
            mode = .bytes;
        } else if (std.mem.startsWith(u8, a, "--bytes=")) {
            count = parseSize(a["--bytes=".len..]) orelse {
                ctx.err("invalid byte count", .{});
                return 1;
            };
            mode = .bytes;
        } else if (std.mem.eql(u8, a, "-a")) {
            i += 1;
            if (i >= args.len) return 2;
            suffix_len = std.fmt.parseInt(usize, args[i], 10) catch 2;
        } else if (std.mem.startsWith(u8, a, "--suffix-length=")) {
            suffix_len = std.fmt.parseInt(usize, a["--suffix-length=".len..], 10) catch 2;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (count == 0) {
        ctx.err("count must be positive", .{});
        return 1;
    }
    if (suffix_len == 0 or suffix_len > 8) {
        ctx.err("suffix length must be 1..8", .{});
        return 1;
    }

    const path: []const u8 = if (operands.items.len >= 1) operands.items[0] else "-";
    const prefix: []const u8 = if (operands.items.len >= 2) operands.items[1] else "x";

    // Slurp input.
    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.arena);
    if (std.mem.eql(u8, path, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [64 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }

    return emit(ctx, mode, count, suffix_len, prefix, data.items);
}

fn emit(ctx: *Context, mode: Mode, count: u64, suffix_len: usize, prefix: []const u8, data: []const u8) !u8 {
    const cwd = std.Io.Dir.cwd();
    var chunk_idx: u64 = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        const end: usize = switch (mode) {
            .bytes => @min(pos + @as(usize, @intCast(count)), data.len),
            .lines => blk: {
                var lines: u64 = 0;
                var k: usize = pos;
                while (k < data.len and lines < count) {
                    if (data[k] == '\n') lines += 1;
                    k += 1;
                }
                break :blk k;
            },
        };
        const name_buf = try makeName(ctx.arena, prefix, suffix_len, chunk_idx);
        const f = cwd.createFile(ctx.io, name_buf, .{}) catch |e| {
            ctx.err("cannot create '{s}': {s}", .{ name_buf, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var fbuf: [16 * 1024]u8 = undefined;
        var fw: std.Io.File.Writer = .init(f, ctx.io, &fbuf);
        try fw.interface.writeAll(data[pos..end]);
        try fw.interface.flush();
        pos = end;
        chunk_idx += 1;
    }
    return 0;
}

fn makeName(gpa: std.mem.Allocator, prefix: []const u8, suffix_len: usize, idx: u64) ![]const u8 {
    var suffix = try gpa.alloc(u8, suffix_len);
    var n = idx;
    var i: usize = suffix_len;
    while (i > 0) {
        i -= 1;
        suffix[i] = 'a' + @as(u8, @intCast(n % 26));
        n /= 26;
    }
    if (n > 0) return error.SuffixOverflow;
    return std.mem.concat(gpa, u8, &.{ prefix, suffix });
}

fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    const mult: u64 = switch (last) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        '0'...'9' => 1,
        else => return null,
    };
    const num_str = if (mult == 1) s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return n *| mult;
}
