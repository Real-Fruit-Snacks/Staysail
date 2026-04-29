const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "realpath";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: realpath [OPTION]... FILE...
    \\
    \\Print the resolved absolute path for each FILE.
    \\
    \\  -e, --canonicalize-existing  all components must exist (default)
    \\  -m, --canonicalize-missing   no components need exist
    \\  -q, --quiet                  suppress most error messages
    \\      --help                   display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var allow_missing = false;
    var quiet = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-e") or std.mem.eql(u8, a, "--canonicalize-existing")) {
            allow_missing = false;
        } else if (std.mem.eql(u8, a, "-m") or std.mem.eql(u8, a, "--canonicalize-missing")) {
            allow_missing = true;
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--quiet")) {
            quiet = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }
    if (operands.items.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }

    const cwd = std.Io.Dir.cwd();
    var any_error = false;

    for (operands.items) |path| {
        const resolved = resolvePath(ctx, cwd, path, allow_missing) catch |e| {
            if (!quiet) ctx.err("{s}: {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        try ctx.stdout.writeAll(resolved);
        try ctx.stdout.writeByte('\n');
    }
    return if (any_error) 1 else 0;
}

fn resolvePath(ctx: *Context, cwd: std.Io.Dir, path: []const u8, allow_missing: bool) ![]const u8 {
    // If absolute, just normalize. If relative, prepend cwd.
    var pieces: std.ArrayList([]const u8) = .empty;
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (!std.fs.path.isAbsolute(path)) {
        const cwd_path_len = std.process.currentPath(ctx.io, &cwd_buf) catch {
            return error.CannotGetCwd;
        };
        try pieces.append(ctx.arena, cwd_buf[0..cwd_path_len]);
    }
    try pieces.append(ctx.arena, path);
    const joined = try std.fs.path.resolve(ctx.arena, pieces.items);

    if (!allow_missing) {
        cwd.access(ctx.io, joined, .{ .read = true }) catch |e| return e;
    }
    return joined;
}
