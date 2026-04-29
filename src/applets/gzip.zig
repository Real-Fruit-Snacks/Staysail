const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "gzip";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: gzip [OPTION]... [FILE]...
    \\
    \\Compress FILEs (or stdin) using the gzip format.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -c, --stdout      write to stdout, keep input files
    \\  -d, --decompress  decompress instead (same as gunzip)
    \\  -k, --keep        keep input files when -c is not given
    \\      --help        display this help and exit
    \\
    \\Without -c, FILEs are replaced with FILE.gz (and the originals removed
    \\unless -k is given).
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var to_stdout = false;
    var decompress = false;
    var keep = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--stdout")) {
            to_stdout = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--decompress")) {
            decompress = true;
        } else if (std.mem.eql(u8, a, "-k") or std.mem.eql(u8, a, "--keep")) {
            keep = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'c' => to_stdout = true,
                'd' => decompress = true,
                'k' => keep = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var any_error = false;
    if (operands.items.len == 0) {
        // stdin → stdout always.
        if (decompress) {
            try decompressReaderToWriter(ctx, ctx.stdin, ctx.stdout);
        } else {
            try compressReaderToWriter(ctx, ctx.stdin, ctx.stdout);
        }
        return 0;
    }

    const cwd = std.Io.Dir.cwd();
    for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-") or to_stdout) {
            // Read input → write to stdout.
            const f = if (std.mem.eql(u8, path, "-")) null else cwd.openFile(ctx.io, path, .{}) catch |e| {
                ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
            if (f == null) {
                if (decompress) try decompressReaderToWriter(ctx, ctx.stdin, ctx.stdout) else try compressReaderToWriter(ctx, ctx.stdin, ctx.stdout);
            } else {
                defer f.?.close(ctx.io);
                var rb: [16 * 1024]u8 = undefined;
                var fr = f.?.reader(ctx.io, &rb);
                if (decompress) try decompressReaderToWriter(ctx, &fr.interface, ctx.stdout) else try compressReaderToWriter(ctx, &fr.interface, ctx.stdout);
            }
            continue;
        }

        // In-place mode: read FILE, write FILE.gz (or strip .gz on -d).
        const out_path = if (decompress) blk: {
            if (std.mem.endsWith(u8, path, ".gz")) {
                break :blk path[0 .. path.len - 3];
            }
            ctx.err("'{s}' does not end in .gz; use -c to write stdout", .{path});
            any_error = true;
            continue;
        } else try std.mem.concat(ctx.arena, u8, &.{ path, ".gz" });

        const inf = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer inf.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = inf.reader(ctx.io, &rb);

        const outf = cwd.createFile(ctx.io, out_path, .{}) catch |e| {
            ctx.err("cannot create '{s}': {s}", .{ out_path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer outf.close(ctx.io);
        var wb: [16 * 1024]u8 = undefined;
        var fw: std.Io.File.Writer = .initStreaming(outf, ctx.io, &wb);

        if (decompress) {
            decompressReaderToWriter(ctx, &fr.interface, &fw.interface) catch |e| {
                ctx.err("decompress '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
        } else {
            compressReaderToWriter(ctx, &fr.interface, &fw.interface) catch |e| {
                ctx.err("compress '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            };
        }
        try fw.interface.flush();

        if (!keep) cwd.deleteFile(ctx.io, path) catch {};
    }
    return if (any_error) 1 else 0;
}

fn compressReaderToWriter(ctx: *Context, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    _ = ctx;
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor = try std.compress.flate.Compress.init(w, &window, .gzip, .default);
    _ = try r.streamRemaining(&compressor.writer);
    try compressor.finish();
}

fn decompressReaderToWriter(ctx: *Context, r: *std.Io.Reader, w: *std.Io.Writer) !void {
    _ = ctx;
    var dec_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp = std.compress.flate.Decompress.init(r, .gzip, &dec_buf);
    _ = try decomp.reader.streamRemaining(w);
}
