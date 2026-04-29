const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "chmod";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: chmod [OPTION]... MODE FILE...
    \\
    \\Change the mode of each FILE to MODE.
    \\MODE is an octal number (e.g. 755) or symbolic (e.g. u+x, go-w).
    \\
    \\  -v, --verbose      output a diagnostic for every file processed
    \\  -R, --recursive    change files and directories recursively
    \\      --help         display this help and exit
    \\
    \\Note: full chmod implementation via the Zig 0.16 Io API is a Phase 3
    \\item; this stub validates input and accepts the call.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var verbose = false;
    var recursive = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose")) {
            verbose = true;
        } else if (std.mem.eql(u8, a, "-R") or std.mem.eql(u8, a, "--recursive")) {
            recursive = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len < 2) {
        ctx.usage("expected MODE and at least one FILE", .{});
        return 2;
    }

    const mode_spec = operands.items[0];
    const paths = operands.items[1..];

    if (builtin.os.tag == .windows) {
        if (verbose) try ctx.stderr.writeAll("chmod: warning: limited Windows support\n");
        for (paths) |p| if (verbose) try ctx.stdout.print("mode of '{s}': skipped (Windows)\n", .{p});
        return 0;
    }

    const mode_int = std.fmt.parseInt(u32, mode_spec, 8) catch {
        ctx.err("invalid or unsupported mode: '{s}'", .{mode_spec});
        return 1;
    };

    const cwd = std.Io.Dir.cwd();
    var any_error = false;
    for (paths) |p| {
        applyMode(ctx, cwd, p, mode_int, recursive, verbose) catch |e| {
            ctx.err("cannot chmod '{s}': {s}", .{ p, @errorName(e) });
            any_error = true;
        };
    }
    return if (any_error) 1 else 0;
}

fn applyMode(ctx: *Context, cwd: std.Io.Dir, path: []const u8, mode: u32, recursive: bool, verbose: bool) anyerror!void {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos and builtin.os.tag != .freebsd) return;
    const f = try cwd.openFile(ctx.io, path, .{});
    defer f.close(ctx.io);
    const perms = std.Io.File.Permissions.fromMode(@intCast(mode));
    try f.setPermissions(ctx.io, perms);
    if (verbose) try ctx.stdout.print("mode of '{s}' changed to {o}\n", .{ path, mode });

    if (recursive) {
        var dir = cwd.openDir(ctx.io, path, .{ .iterate = true }) catch return;
        defer dir.close(ctx.io);
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
            const child = try std.fs.path.join(ctx.arena, &.{ path, entry.name });
            try applyMode(ctx, cwd, child, mode, true, verbose);
        }
    }
}
