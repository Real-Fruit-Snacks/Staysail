const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "base64";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: base64 [OPTION]... [FILE]
    \\
    \\Base64-encode or -decode FILE, or standard input, to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -d, --decode      decode data
    \\  -w, --wrap=COLS   wrap encoded lines after COLS character (default 76).
    \\                    Use 0 to disable line wrapping.
    \\      --help        display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var decode = false;
    var wrap: usize = 76;
    var path: ?[:0]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--decode")) {
            decode = true;
        } else if (std.mem.eql(u8, a, "-w")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 'w'", .{});
                return 2;
            }
            wrap = std.fmt.parseInt(usize, args[i], 10) catch {
                ctx.err("invalid wrap value: '{s}'", .{args[i]});
                return 1;
            };
        } else if (std.mem.startsWith(u8, a, "--wrap=")) {
            wrap = std.fmt.parseInt(usize, a["--wrap=".len..], 10) catch {
                ctx.err("invalid wrap value", .{});
                return 1;
            };
        } else {
            path = a;
        }
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.arena);
    if (path == null or std.mem.eql(u8, path.?, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path.?, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path.?, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }

    const enc = std.base64.standard;
    if (decode) {
        // Strip whitespace before decoding.
        var clean: std.ArrayList(u8) = .empty;
        defer clean.deinit(ctx.arena);
        for (data.items) |b| switch (b) {
            ' ', '\t', '\n', '\r' => {},
            else => try clean.append(ctx.arena, b),
        };
        const decoder = enc.Decoder;
        const len = decoder.calcSizeForSlice(clean.items) catch {
            ctx.err("invalid input", .{});
            return 1;
        };
        const out = try ctx.arena.alloc(u8, len);
        decoder.decode(out, clean.items) catch {
            ctx.err("invalid input", .{});
            return 1;
        };
        try ctx.stdout.writeAll(out);
    } else {
        const encoder = enc.Encoder;
        const out_len = encoder.calcSize(data.items.len);
        const out = try ctx.arena.alloc(u8, out_len);
        const encoded = encoder.encode(out, data.items);
        if (wrap == 0) {
            try ctx.stdout.writeAll(encoded);
            try ctx.stdout.writeByte('\n');
        } else {
            var off: usize = 0;
            while (off < encoded.len) {
                const chunk_end = @min(off + wrap, encoded.len);
                try ctx.stdout.writeAll(encoded[off..chunk_end]);
                try ctx.stdout.writeByte('\n');
                off = chunk_end;
            }
        }
    }
    return 0;
}
