const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "tar";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: tar [OPTION]... [FILE]...
    \\
    \\Manipulate tar archives.
    \\
    \\Operation:
    \\  -c, --create       create a new archive
    \\  -x, --extract      extract files from an archive
    \\  -t, --list         list the contents of an archive
    \\
    \\Compression:
    \\  -z, --gzip         filter through gzip
    \\
    \\Common:
    \\  -f, --file=FILE    use FILE for the archive (default stdin/stdout)
    \\  -C, --directory=DIR  change to DIR before performing operations
    \\  -v, --verbose      list files processed
    \\      --help         display this help and exit
    \\
    \\Phase 4: bzip2/xz filters and many GNU-isms are deferred.
    \\
;

const Op = enum { create, extract, list };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var op: ?Op = null;
    var use_gzip = false;
    var verbose = false;
    var archive_path: ?[]const u8 = null;
    var chdir: ?[]const u8 = null;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--create")) {
            op = .create;
        } else if (std.mem.eql(u8, a, "--extract")) {
            op = .extract;
        } else if (std.mem.eql(u8, a, "--list")) {
            op = .list;
        } else if (std.mem.eql(u8, a, "--gzip")) {
            use_gzip = true;
        } else if (std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-f")) {
            i += 1;
            if (i >= args.len) return 2;
            archive_path = args[i];
        } else if (std.mem.startsWith(u8, a, "--file=")) {
            archive_path = a["--file=".len..];
        } else if (std.mem.eql(u8, a, "-C")) {
            i += 1;
            if (i >= args.len) return 2;
            chdir = args[i];
        } else if (std.mem.startsWith(u8, a, "--directory=")) {
            chdir = a["--directory=".len..];
        } else if (a.len >= 1 and a[0] == '-') {
            // Bundled short options OR positional letters (BSD form: cvfz).
            const start: usize = if (a.len >= 2 and a[1] == '-') 2 else 1;
            for (a[start..]) |c| switch (c) {
                'c' => op = .create,
                'x' => op = .extract,
                't' => op = .list,
                'z' => use_gzip = true,
                'v' => verbose = true,
                'f' => {
                    // -f consumes the next operand as the archive path.
                    i += 1;
                    if (i >= args.len) {
                        ctx.usage("'f' requires a filename", .{});
                        return 2;
                    }
                    archive_path = args[i];
                },
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (op == null) {
        ctx.usage("must specify -c, -x, or -t", .{});
        return 2;
    }

    return switch (op.?) {
        .extract => doExtract(ctx, archive_path, use_gzip, chdir, verbose),
        .list => doList(ctx, archive_path, use_gzip, verbose),
        .create => doCreate(ctx, archive_path, use_gzip, chdir, operands.items, verbose),
    };
}

fn doExtract(ctx: *Context, archive_path: ?[]const u8, use_gzip: bool, chdir: ?[]const u8, verbose: bool) !u8 {
    _ = verbose;
    var src_buf: [16 * 1024]u8 = undefined;
    var src_fr_storage: std.Io.File.Reader = undefined;
    var src: *std.Io.Reader = undefined;
    var src_file: ?std.Io.File = null;
    defer if (src_file) |f| f.close(ctx.io);

    if (archive_path) |p| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, p, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
        src_file = f;
        src_fr_storage = .init(f, ctx.io, &src_buf);
        src = &src_fr_storage.interface;
    } else {
        src = ctx.stdin;
    }

    var gz_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = undefined;
    if (use_gzip) {
        decomp = std.compress.flate.Decompress.init(src, .gzip, &gz_buf);
        src = &decomp.reader;
    }

    const dest = if (chdir) |d| blk: {
        std.Io.Dir.cwd().createDirPath(ctx.io, d) catch {};
        break :blk std.Io.Dir.cwd().openDir(ctx.io, d, .{}) catch |e| {
            ctx.err("cannot open dir '{s}': {s}", .{ d, @errorName(e) });
            return 1;
        };
    } else std.Io.Dir.cwd();
    defer if (chdir != null) {
        var d = dest;
        d.close(ctx.io);
    };

    std.tar.extract(ctx.io, dest, src, .{}) catch |e| {
        ctx.err("extract failed: {s}", .{@errorName(e)});
        return 1;
    };
    return 0;
}

fn doList(ctx: *Context, archive_path: ?[]const u8, use_gzip: bool, verbose: bool) !u8 {
    _ = verbose;
    var src_buf: [16 * 1024]u8 = undefined;
    var src_fr_storage: std.Io.File.Reader = undefined;
    var src: *std.Io.Reader = undefined;
    var src_file: ?std.Io.File = null;
    defer if (src_file) |f| f.close(ctx.io);

    if (archive_path) |p| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, p, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
        src_file = f;
        src_fr_storage = .init(f, ctx.io, &src_buf);
        src = &src_fr_storage.interface;
    } else {
        src = ctx.stdin;
    }

    var gz_buf: [std.compress.flate.max_window_len]u8 = undefined;
    var decomp: std.compress.flate.Decompress = undefined;
    if (use_gzip) {
        decomp = std.compress.flate.Decompress.init(src, .gzip, &gz_buf);
        src = &decomp.reader;
    }

    var fname_buf: [std.fs.max_path_bytes]u8 = undefined;
    var lname_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(src, .{
        .file_name_buffer = &fname_buf,
        .link_name_buffer = &lname_buf,
    });
    while (true) {
        const entry = it.next() catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                ctx.err("tar list: {s}", .{@errorName(e)});
                return 1;
            },
        } orelse break;
        try ctx.stdout.print("{s}\n", .{entry.name});
    }
    return 0;
}

fn doCreate(ctx: *Context, archive_path: ?[]const u8, use_gzip: bool, chdir: ?[]const u8, paths: []const [:0]const u8, verbose: bool) !u8 {
    if (paths.len == 0) {
        ctx.usage("must specify files to archive", .{});
        return 2;
    }

    var dst_buf: [16 * 1024]u8 = undefined;
    var dst_fw_storage: std.Io.File.Writer = undefined;
    var dst: *std.Io.Writer = undefined;
    var dst_file: ?std.Io.File = null;
    defer if (dst_file) |f| f.close(ctx.io);

    if (archive_path) |p| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.createFile(ctx.io, p, .{}) catch |e| {
            ctx.err("cannot create '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
        dst_file = f;
        dst_fw_storage = .initStreaming(f, ctx.io, &dst_buf);
        dst = &dst_fw_storage.interface;
    } else {
        dst = ctx.stdout;
    }
    defer if (dst_file != null) dst_fw_storage.interface.flush() catch {};

    var gz_window: [std.compress.flate.max_window_len]u8 = undefined;
    var compressor: std.compress.flate.Compress = undefined;
    if (use_gzip) {
        compressor = try std.compress.flate.Compress.init(dst, &gz_window, .gzip, .default);
        dst = &compressor.writer;
    }

    var tw = std.tar.Writer{ .underlying_writer = dst };

    const cwd = std.Io.Dir.cwd();
    const work_dir = if (chdir) |d| cwd.openDir(ctx.io, d, .{ .iterate = true }) catch |e| {
        ctx.err("cannot chdir to '{s}': {s}", .{ d, @errorName(e) });
        return 1;
    } else cwd;
    defer if (chdir != null) {
        var wd = work_dir;
        wd.close(ctx.io);
    };

    for (paths) |p| {
        if (verbose) try ctx.stderr.print("{s}\n", .{p});
        addPath(ctx, work_dir, &tw, p) catch |e| {
            ctx.err("archive '{s}': {s}", .{ p, @errorName(e) });
            return 1;
        };
    }
    try tw.finishPedantically();
    if (use_gzip) try compressor.finish();
    return 0;
}

fn addPath(ctx: *Context, dir: std.Io.Dir, tw: *std.tar.Writer, path: []const u8) anyerror!void {
    // Try as a directory first; on Windows openFile may succeed for dirs but
    // the resulting reader can't be sized.
    if (dir.openDir(ctx.io, path, .{ .iterate = true })) |dir_open| {
        var subdir = dir_open;
        defer subdir.close(ctx.io);
        try tw.writeDir(path, .{});
        var it = subdir.iterate();
        while (try it.next(ctx.io)) |entry| {
            const child = try std.fs.path.join(ctx.arena, &.{ path, entry.name });
            try addPath(ctx, dir, tw, child);
        }
        return;
    } else |_| {}

    // It's a file.
    const file = try dir.openFile(ctx.io, path, .{});
    defer file.close(ctx.io);
    var rb: [16 * 1024]u8 = undefined;
    var fr = file.reader(ctx.io, &rb);
    try tw.writeFile(path, &fr, 0);
}
