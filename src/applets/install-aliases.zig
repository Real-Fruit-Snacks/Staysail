const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");
const registry = @import("../registry.zig");

pub const name: []const u8 = "install-aliases";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: install-aliases [OPTION]... TARGET-DIR
    \\
    \\Create a symlink (or hard link, or copy on Windows) for every applet in
    \\TARGET-DIR pointing at the running staysail binary. After this runs,
    \\you can invoke each applet by its name (e.g. `cat README.md`) without
    \\the `staysail` prefix.
    \\
    \\  -f, --force      replace existing files in TARGET-DIR
    \\  -n, --dry-run    print what would be created, don't actually create
    \\  -v, --verbose    log each link as it's created
    \\      --copy       copy the binary instead of linking
    \\      --hard       use hard links instead of symbolic
    \\      --help       display this help and exit
    \\
;

const LinkMode = enum { sym, hard, copy };

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var force = false;
    var dry_run = false;
    var verbose = false;
    var mode: LinkMode = if (builtin.os.tag == .windows) .copy else .sym;
    var target_dir: ?[]const u8 = null;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "--copy")) {
            mode = .copy;
        } else if (std.mem.eql(u8, a, "--hard")) {
            mode = .hard;
        } else {
            target_dir = a;
        }
    }

    if (target_dir == null) {
        ctx.usage("missing TARGET-DIR", .{});
        return 2;
    }

    // Locate the running staysail binary.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(ctx.io, &exe_buf) catch |e| {
        ctx.err("cannot determine executable path: {s}", .{@errorName(e)});
        return 1;
    };
    const exe_path = exe_buf[0..exe_len];

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(ctx.io, target_dir.?) catch {};

    var any_error = false;
    var created: usize = 0;
    for (registry.APPLETS) |applet| {
        const link_basename = if (builtin.os.tag == .windows)
            try std.mem.concat(ctx.arena, u8, &.{ applet.name, ".exe" })
        else
            try ctx.arena.dupe(u8, applet.name);
        const link_path = try std.fs.path.join(ctx.arena, &.{ target_dir.?, link_basename });

        if (dry_run) {
            try ctx.stdout.print("would link {s} -> {s}\n", .{ link_path, exe_path });
            continue;
        }

        if (force) cwd.deleteFile(ctx.io, link_path) catch {};

        const result: anyerror!void = switch (mode) {
            .sym => cwd.symLink(ctx.io, exe_path, link_path, .{}),
            .hard => cwd.hardLink(exe_path, cwd, link_path, ctx.io, .{}),
            .copy => cwd.copyFile(exe_path, cwd, link_path, ctx.io, .{}),
        };
        result catch |e| switch (e) {
            error.PathAlreadyExists => {
                if (verbose) try ctx.stderr.print("skip (exists): {s}\n", .{link_path});
                continue;
            },
            else => {
                ctx.err("cannot link {s}: {s}", .{ link_path, @errorName(e) });
                any_error = true;
                continue;
            },
        };
        created += 1;
        if (verbose) try ctx.stdout.print("{s}\n", .{link_path});
    }

    if (!verbose and !dry_run) try ctx.stdout.print("created {d} aliases in {s}\n", .{ created, target_dir.? });
    return if (any_error) 1 else 0;
}
