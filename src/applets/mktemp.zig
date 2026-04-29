const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "mktemp";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: mktemp [OPTION]... [TEMPLATE]
    \\
    \\Create a unique temporary file or directory and print its name.
    \\TEMPLATE must contain at least three consecutive 'X's. Default template
    \\is "tmp.XXXXXXXXXX".
    \\
    \\  -d, --directory      create a directory, not a file
    \\  -p, --tmpdir=DIR     interpret TEMPLATE relative to DIR (default: $TMPDIR or /tmp)
    \\  -u, --dry-run        just emit the name, don't actually create it
    \\      --help           display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var directory = false;
    var dry_run = false;
    var tmpdir: ?[]const u8 = null;
    var template: []const u8 = "tmp.XXXXXXXXXX";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--directory")) {
            directory = true;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) return 2;
            tmpdir = args[i];
        } else if (std.mem.startsWith(u8, a, "--tmpdir=")) {
            tmpdir = a["--tmpdir=".len..];
        } else {
            template = a;
        }
    }

    if (std.mem.indexOf(u8, template, "XXX") == null) {
        ctx.err("template '{s}' must contain at least 3 consecutive X's", .{template});
        return 1;
    }

    const dir = tmpdir orelse defaultTmpdir(ctx);
    const cwd = std.Io.Dir.cwd();

    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        const filled = try fillTemplate(ctx, template);
        const full_path = if (std.fs.path.isAbsolute(template))
            try ctx.arena.dupe(u8, filled)
        else
            try std.fs.path.join(ctx.arena, &.{ dir, filled });

        if (dry_run) {
            try ctx.stdout.writeAll(full_path);
            try ctx.stdout.writeByte('\n');
            return 0;
        }

        if (directory) {
            cwd.createDir(ctx.io, full_path, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => {
                    ctx.err("cannot create directory: {s}", .{@errorName(e)});
                    return 1;
                },
            };
        } else {
            const f = cwd.createFile(ctx.io, full_path, .{ .exclusive = true }) catch |e| switch (e) {
                error.PathAlreadyExists => continue,
                else => {
                    ctx.err("cannot create file: {s}", .{@errorName(e)});
                    return 1;
                },
            };
            f.close(ctx.io);
        }
        try ctx.stdout.writeAll(full_path);
        try ctx.stdout.writeByte('\n');
        return 0;
    }
    ctx.err("could not create unique name after 100 tries", .{});
    return 1;
}

fn defaultTmpdir(ctx: *Context) []const u8 {
    if (ctx.environ.get("TMPDIR")) |t| if (t.len > 0) return t;
    if (ctx.environ.get("TEMP")) |t| if (t.len > 0) return t;
    if (ctx.environ.get("TMP")) |t| if (t.len > 0) return t;
    return "/tmp";
}

fn fillTemplate(ctx: *Context, template: []const u8) ![]u8 {
    const out = try ctx.arena.dupe(u8, template);
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    var rand_buf: [64]u8 = undefined;
    ctx.io.random(&rand_buf);
    var ri: usize = 0;
    for (out, 0..) |c, idx| {
        if (c == 'X') {
            out[idx] = alphabet[rand_buf[ri % rand_buf.len] % alphabet.len];
            ri += 1;
        }
    }
    return out;
}
