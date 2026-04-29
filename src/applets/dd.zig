const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "dd";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: dd [OPERAND]...
    \\
    \\Copy a file, converting and formatting according to the operands.
    \\
    \\  if=FILE          read from FILE instead of stdin
    \\  of=FILE          write to FILE instead of stdout
    \\  bs=BYTES         read and write up to BYTES bytes at a time
    \\  count=N          copy only N input blocks
    \\  skip=N           skip N ibs-sized blocks at start of input
    \\  seek=N           skip N obs-sized blocks at start of output
    \\  status=LEVEL     'none' suppresses transfer stats
    \\  --help           display this help and exit
    \\
    \\BYTES may have a multiplier suffix: c=1, k=1024, M=1024^2, G=1024^3.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var bs: u64 = 512;
    var count: ?u64 = null;
    var skip: u64 = 0;
    var seek: u64 = 0;
    var status_quiet = false;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        if (std.mem.startsWith(u8, a, "if=")) input_path = a["if=".len..] else if (std.mem.startsWith(u8, a, "of=")) output_path = a["of=".len..] else if (std.mem.startsWith(u8, a, "bs=")) {
            bs = parseSize(a["bs=".len..]) orelse {
                ctx.err("invalid bs: '{s}'", .{a["bs=".len..]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, a, "count=")) {
            count = parseSize(a["count=".len..]);
        } else if (std.mem.startsWith(u8, a, "skip=")) {
            skip = parseSize(a["skip=".len..]) orelse 0;
        } else if (std.mem.startsWith(u8, a, "seek=")) {
            seek = parseSize(a["seek=".len..]) orelse 0;
        } else if (std.mem.startsWith(u8, a, "status=")) {
            status_quiet = std.mem.eql(u8, a["status=".len..], "none");
        } else {
            ctx.usage("unknown operand: '{s}'", .{a});
            return 2;
        }
    }

    if (bs == 0) {
        ctx.err("bs cannot be 0", .{});
        return 1;
    }

    const cwd = std.Io.Dir.cwd();

    // Source.
    var src_buf: [16 * 1024]u8 = undefined;
    var src_fr_storage: std.Io.File.Reader = undefined;
    var src_reader: *std.Io.Reader = undefined;
    var src_file: ?std.Io.File = null;
    defer if (src_file) |f| f.close(ctx.io);

    if (input_path) |p| {
        const f = cwd.openFile(ctx.io, p, .{}) catch |e| {
            ctx.err("cannot open input '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
        src_file = f;
        src_fr_storage = .init(f, ctx.io, &src_buf);
        src_reader = &src_fr_storage.interface;
    } else {
        src_reader = ctx.stdin;
    }

    // Dest.
    var dst_buf: [16 * 1024]u8 = undefined;
    var dst_fw_storage: std.Io.File.Writer = undefined;
    var dst_writer: *std.Io.Writer = undefined;
    var dst_file: ?std.Io.File = null;
    defer if (dst_file) |f| f.close(ctx.io);

    if (output_path) |p| {
        const f = cwd.createFile(ctx.io, p, .{}) catch |e| {
            ctx.err("cannot create output '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
        dst_file = f;
        dst_fw_storage = .initStreaming(f, ctx.io, &dst_buf);
        dst_writer = &dst_fw_storage.interface;
    } else {
        dst_writer = ctx.stdout;
    }
    defer if (dst_file != null) dst_fw_storage.interface.flush() catch {};

    // Skip input bytes.
    if (skip > 0) {
        const to_skip = skip * bs;
        _ = src_reader.discard(.limited(to_skip)) catch {};
    }

    // Skip output bytes (write zeros).
    if (seek > 0) {
        const zeros = [_]u8{0} ** 4096;
        var remaining = seek * bs;
        while (remaining > 0) {
            const chunk = @min(remaining, zeros.len);
            try dst_writer.writeAll(zeros[0..chunk]);
            remaining -= chunk;
        }
    }

    var blocks_copied: u64 = 0;
    var bytes_copied: u64 = 0;
    const chunk_size = @min(bs, 64 * 1024);

    while (true) {
        if (count) |c| if (blocks_copied >= c) break;
        const want: usize = @intCast(chunk_size);
        const buf = src_reader.peek(want) catch |e| switch (e) {
            error.EndOfStream => {
                const buffered = src_reader.buffered();
                if (buffered.len == 0) break;
                try dst_writer.writeAll(buffered);
                bytes_copied += buffered.len;
                src_reader.toss(buffered.len);
                break;
            },
            else => return e,
        };
        try dst_writer.writeAll(buf);
        bytes_copied += buf.len;
        src_reader.toss(buf.len);
        blocks_copied += 1;
    }

    if (!status_quiet) {
        try ctx.stderr.print("{d} bytes copied ({d} blocks)\n", .{ bytes_copied, blocks_copied });
    }
    return 0;
}

fn parseSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    const mult: u64 = switch (last) {
        'c' => 1,
        'k', 'K' => 1024,
        'M' => 1024 * 1024,
        'G' => 1024 * 1024 * 1024,
        '0'...'9' => 1,
        else => return null,
    };
    const num = if (mult == 1 and last >= '0' and last <= '9') s else s[0 .. s.len - 1];
    const n = std.fmt.parseInt(u64, num, 10) catch return null;
    return n *| mult;
}
