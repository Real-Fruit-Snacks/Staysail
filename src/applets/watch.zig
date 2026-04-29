const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "watch";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: watch [OPTION]... COMMAND [ARG]...
    \\
    \\Repeatedly run COMMAND, displaying its output. Press Ctrl-C to stop.
    \\
    \\  -n, --interval=SECS   wait SECS seconds between updates (default 2)
    \\  -t, --no-title        suppress the header
    \\  -d, --differences     (accepted; no highlighting yet)
    \\      --help            display this help and exit
    \\
    \\Note: Phase 3 watch uses a simple "clear + run" loop. ANSI screen
    \\manipulation is in Phase 4.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var interval_s: f64 = 2.0;
    var no_title = false;
    var cmd_start: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-n")) {
            i += 1;
            if (i >= args.len) return 2;
            interval_s = std.fmt.parseFloat(f64, args[i]) catch 2.0;
        } else if (std.mem.startsWith(u8, a, "--interval=")) {
            interval_s = std.fmt.parseFloat(f64, a["--interval=".len..]) catch 2.0;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--no-title")) {
            no_title = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--differences")) {
            // Accepted; no diff highlighting in Phase 3.
        } else {
            cmd_start = i;
            break;
        }
    }

    if (cmd_start >= args.len) {
        ctx.usage("missing COMMAND", .{});
        return 2;
    }

    const child_argv = args[cmd_start..];
    const interval_ns: i96 = @intFromFloat(interval_s * @as(f64, std.time.ns_per_s));
    const dur: std.Io.Duration = .fromNanoseconds(interval_ns);

    // Loop forever. The user kills with Ctrl-C; we don't currently install a
    // signal handler so the loop relies on default SIGINT/CTRL_C behaviour.
    while (true) {
        // Clear with form-feed; not a real screen clear but avoids the ANSI
        // escape complexity for Phase 3.
        try ctx.stdout.writeByte(0x0C);

        if (!no_title) {
            try ctx.stdout.print("Every {d}s:", .{interval_s});
            for (child_argv) |a| try ctx.stdout.print(" {s}", .{a});
            try ctx.stdout.writeAll("\n\n");
        }

        // Run the command, capture, write to stdout.
        const result = std.process.run(ctx.gpa, ctx.io, .{
            .argv = @ptrCast(child_argv),
        }) catch |e| {
            ctx.err("cannot run command: {s}", .{@errorName(e)});
            return 127;
        };
        defer ctx.gpa.free(result.stdout);
        defer ctx.gpa.free(result.stderr);
        try ctx.stdout.writeAll(result.stdout);
        if (result.stderr.len > 0) try ctx.stderr.writeAll(result.stderr);
        try ctx.stdout.flush();

        ctx.io.sleep(dur, .boot) catch return 130;
    }
}
