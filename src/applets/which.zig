const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "which";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: which [OPTION]... COMMAND...
    \\
    \\For each COMMAND, print the path of the first match in PATH.
    \\
    \\  -a, --all      print all matches in PATH (not just the first)
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var all = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--all")) {
            all = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }
    if (operands.items.len == 0) {
        ctx.usage("missing command operand", .{});
        return 2;
    }

    const path_var = ctx.environ.get("PATH") orelse {
        ctx.err("PATH not set", .{});
        return 1;
    };
    const path_sep: u8 = if (builtin.os.tag == .windows) ';' else ':';

    // Windows uses PATHEXT for executable extensions.
    const pathext: []const u8 = if (builtin.os.tag == .windows)
        ctx.environ.get("PATHEXT") orelse ".COM;.EXE;.BAT;.CMD"
    else
        "";

    const cwd = std.Io.Dir.cwd();
    var any_missing = false;

    for (operands.items) |cmd| {
        var found = false;
        var dir_it = std.mem.splitScalar(u8, path_var, path_sep);
        while (dir_it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = try std.fs.path.join(ctx.arena, &.{ dir, cmd });
            if (try checkExecutable(ctx, cwd, candidate)) {
                try ctx.stdout.writeAll(candidate);
                try ctx.stdout.writeByte('\n');
                found = true;
                if (!all) break;
            }
            if (builtin.os.tag == .windows) {
                var ext_it = std.mem.splitScalar(u8, pathext, ';');
                while (ext_it.next()) |ext| {
                    if (ext.len == 0) continue;
                    const with_ext = try std.mem.concat(ctx.arena, u8, &.{ candidate, ext });
                    if (try checkExecutable(ctx, cwd, with_ext)) {
                        try ctx.stdout.writeAll(with_ext);
                        try ctx.stdout.writeByte('\n');
                        found = true;
                        if (!all) break;
                    }
                }
                if (found and !all) break;
            }
        }
        if (!found) {
            any_missing = true;
            ctx.err("no {s} in ({s})", .{ cmd, path_var });
        }
    }
    return if (any_missing) 1 else 0;
}

fn checkExecutable(ctx: *Context, cwd: std.Io.Dir, path: []const u8) !bool {
    // Windows guard: skip paths Zig 0.16 would treat as invalid syscalls.
    // MSYS2/git-bash-style /c/... entries break Zig's path validator and panic.
    if (builtin.os.tag == .windows) {
        if (path.len >= 3 and path[0] == '/' and path[2] == '/' and
            ((path[1] >= 'a' and path[1] <= 'z') or (path[1] >= 'A' and path[1] <= 'Z')))
        {
            return false;
        }
    }
    cwd.access(ctx.io, path, .{ .read = true }) catch return false;
    return true;
}
