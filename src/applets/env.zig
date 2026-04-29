const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "env";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: env [OPTION]... [NAME=VALUE]... [COMMAND [ARG]...]
    \\
    \\Print the environment, or run COMMAND with a modified environment.
    \\
    \\  -i, --ignore-environment  start with an empty environment
    \\  -u, --unset=NAME          remove variable NAME from the environment
    \\  -0, --null                end output lines with NUL, not newline
    \\      --help                display this help and exit
    \\
    \\With no COMMAND, prints the current (possibly modified) environment.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var ignore = false;
    var nul_term = false;
    var unset: std.ArrayList([]const u8) = .empty;
    defer unset.deinit(ctx.arena);
    var assignments: std.ArrayList([]const u8) = .empty;
    defer assignments.deinit(ctx.arena);
    var command: ?[]const [:0]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (command != null) break;
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-environment")) {
            ignore = true;
        } else if (std.mem.eql(u8, a, "-0") or std.mem.eql(u8, a, "--null")) {
            nul_term = true;
        } else if (std.mem.eql(u8, a, "-u")) {
            i += 1;
            if (i >= args.len) return 2;
            try unset.append(ctx.arena, args[i]);
        } else if (std.mem.startsWith(u8, a, "--unset=")) {
            try unset.append(ctx.arena, a["--unset=".len..]);
        } else if (std.mem.indexOfScalar(u8, a, '=') != null) {
            try assignments.append(ctx.arena, a);
        } else {
            command = args[i..];
        }
    }

    // Build the resulting environment view (read-only — we just collect for display).
    const sep: u8 = if (nul_term) 0 else '\n';

    if (command == null) {
        if (!ignore) {
            var it = ctx.environ.array_hash_map.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (containsStr(unset.items, k)) continue;
                if (assignmentOverride(assignments.items, k)) continue;
                try ctx.stdout.print("{s}={s}", .{ k, entry.value_ptr.* });
                try ctx.stdout.writeByte(sep);
            }
        }
        for (assignments.items) |a| {
            try ctx.stdout.writeAll(a);
            try ctx.stdout.writeByte(sep);
        }
        return 0;
    }

    // With a command: build a modified environ map, then spawn.
    var new_env = std.process.Environ.Map.init(ctx.gpa);
    defer new_env.deinit();
    if (!ignore) {
        var it = ctx.environ.array_hash_map.iterator();
        while (it.next()) |entry| {
            const k = entry.key_ptr.*;
            if (containsStr(unset.items, k)) continue;
            if (assignmentOverride(assignments.items, k)) continue;
            try new_env.put(k, entry.value_ptr.*);
        }
    }
    for (assignments.items) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            try new_env.put(a[0..eq], a[eq + 1 ..]);
        }
    }

    const result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = command.?,
        .environ_map = &new_env,
    }) catch |e| {
        ctx.err("cannot run '{s}': {s}", .{ command.?[0], @errorName(e) });
        return 127;
    };
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    try ctx.stdout.writeAll(result.stdout);
    try ctx.stderr.writeAll(result.stderr);
    return switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
}

fn containsStr(list: []const []const u8, needle: []const u8) bool {
    for (list) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}

fn assignmentOverride(list: []const []const u8, key: []const u8) bool {
    for (list) |a| {
        if (std.mem.indexOfScalar(u8, a, '=')) |eq| {
            if (std.mem.eql(u8, a[0..eq], key)) return true;
        }
    }
    return false;
}
