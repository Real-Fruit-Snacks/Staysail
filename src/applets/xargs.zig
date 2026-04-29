const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "xargs";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: xargs [OPTION]... COMMAND [INITIAL-ARGS]...
    \\
    \\Run COMMAND with INITIAL-ARGS plus arguments read from standard input.
    \\
    \\  -n, --max-args=N    use at most N arguments per command line
    \\  -0, --null          input items are NUL-terminated
    \\  -I REPLACE          replace REPLACE in COMMAND with each input line
    \\  -t                  print each command before running it
    \\      --help          display this help and exit
    \\
    \\Default COMMAND is 'echo'.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var max_args: usize = 0; // 0 == all in one go
    var null_sep = false;
    var replace: ?[]const u8 = null;
    var trace = false;
    var cmd_args: std.ArrayList([:0]const u8) = .empty;
    defer cmd_args.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-0") or std.mem.eql(u8, a, "--null")) {
            null_sep = true;
        } else if (std.mem.eql(u8, a, "-t")) {
            trace = true;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) return 2;
            max_args = std.fmt.parseInt(usize, args[i], 10) catch 0;
        } else if (std.mem.startsWith(u8, a, "--max-args=")) {
            max_args = std.fmt.parseInt(usize, a["--max-args=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, a, "-I")) {
            i += 1;
            if (i >= args.len) return 2;
            replace = args[i];
        } else {
            try cmd_args.append(ctx.arena, a);
        }
    }

    if (cmd_args.items.len == 0) try cmd_args.append(ctx.arena, "echo");

    // Read all input.
    var data: std.ArrayList(u8) = .empty;
    ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};

    var items: std.ArrayList([]const u8) = .empty;
    if (null_sep) {
        var start: usize = 0;
        for (data.items, 0..) |b, idx| {
            if (b == 0) {
                try items.append(ctx.arena, data.items[start..idx]);
                start = idx + 1;
            }
        }
        if (start < data.items.len) try items.append(ctx.arena, data.items[start..]);
    } else {
        var it = std.mem.tokenizeAny(u8, data.items, " \t\n\r");
        while (it.next()) |tok| try items.append(ctx.arena, tok);
    }

    if (replace) |rep| {
        // -I: run COMMAND once per input item, substituting replace token.
        for (items.items) |item| {
            try runOne(ctx, cmd_args.items, &.{}, .{ .replace = rep, .item = item, .trace = trace });
        }
        return 0;
    }

    if (max_args == 0) max_args = items.items.len;
    var off: usize = 0;
    while (off < items.items.len) {
        const end = @min(off + max_args, items.items.len);
        try runOne(ctx, cmd_args.items, items.items[off..end], .{ .trace = trace });
        off = end;
    }
    if (items.items.len == 0) {
        // Mirror GNU xargs: with no input and no -r, run command once with no extra args.
        try runOne(ctx, cmd_args.items, &.{}, .{ .trace = trace });
    }
    return 0;
}

const RunOpts = struct {
    replace: ?[]const u8 = null,
    item: ?[]const u8 = null,
    trace: bool = false,
};

fn runOne(ctx: *Context, base_args: []const [:0]const u8, extra: []const []const u8, opts: RunOpts) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.arena);

    if (opts.replace) |rep| {
        for (base_args) |a| {
            if (std.mem.indexOf(u8, a, rep)) |_| {
                const replaced = try std.mem.replaceOwned(u8, ctx.arena, a, rep, opts.item.?);
                try argv.append(ctx.arena, replaced);
            } else {
                try argv.append(ctx.arena, a);
            }
        }
    } else {
        for (base_args) |a| try argv.append(ctx.arena, a);
        for (extra) |a| try argv.append(ctx.arena, a);
    }

    if (opts.trace) {
        try ctx.stderr.writeAll("+");
        for (argv.items) |a| try ctx.stderr.print(" {s}", .{a});
        try ctx.stderr.writeByte('\n');
    }

    // Spawn the child process via std.process.run.
    const result = std.process.run(ctx.gpa, ctx.io, .{
        .argv = argv.items,
    }) catch |e| {
        ctx.err("cannot run '{s}': {s}", .{ argv.items[0], @errorName(e) });
        return;
    };
    defer ctx.gpa.free(result.stdout);
    defer ctx.gpa.free(result.stderr);
    try ctx.stdout.writeAll(result.stdout);
    try ctx.stderr.writeAll(result.stderr);
}
