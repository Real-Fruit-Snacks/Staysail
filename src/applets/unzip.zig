const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "unzip";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: unzip [OPTION]... ARCHIVE.zip [-d DIR]
    \\
    \\Extract files from a zip archive.
    \\
    \\  -d, --extract-dir=DIR   extract into DIR (default current directory)
    \\  -l, --list              list contents only (don't extract)
    \\      --help              display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var dest_dir: ?[]const u8 = null;
    var list_only = false;
    var archive: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-d")) {
            i += 1;
            if (i >= args.len) return 2;
            dest_dir = args[i];
        } else if (std.mem.startsWith(u8, a, "--extract-dir=")) {
            dest_dir = a["--extract-dir=".len..];
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--list")) {
            list_only = true;
        } else {
            if (archive == null) archive = a;
        }
    }

    if (archive == null) {
        ctx.usage("missing archive", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    const f = cwd.openFile(ctx.io, archive.?, .{}) catch |e| {
        ctx.err("cannot open '{s}': {s}", .{ archive.?, @errorName(e) });
        return 1;
    };
    defer f.close(ctx.io);
    var rb: [16 * 1024]u8 = undefined;
    var fr = f.reader(ctx.io, &rb);

    if (list_only) {
        var iter = std.zip.Iterator.init(&fr) catch |e| {
            ctx.err("cannot read zip iterator: {s}", .{@errorName(e)});
            return 1;
        };
        var name_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (iter.next() catch null) |entry| {
            try entry.extract(&fr, .{ .verify_checksums = false }, &name_buf, undefined);
            try ctx.stdout.print("{s}\n", .{name_buf[0..entry.filename_len]});
        }
        return 0;
    }

    const dest = if (dest_dir) |d| blk: {
        cwd.createDirPath(ctx.io, d) catch {};
        break :blk cwd.openDir(ctx.io, d, .{}) catch |e| {
            ctx.err("cannot open dir '{s}': {s}", .{ d, @errorName(e) });
            return 1;
        };
    } else cwd;
    defer if (dest_dir != null) {
        var d = dest;
        d.close(ctx.io);
    };

    std.zip.extract(dest, &fr, .{}) catch |e| {
        ctx.err("extract failed: {s}", .{@errorName(e)});
        return 1;
    };
    return 0;
}
