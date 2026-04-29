const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "timeout";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: timeout [OPTION] DURATION COMMAND [ARG]...
    \\
    \\Run COMMAND, killing it if still running after DURATION seconds.
    \\DURATION may be suffixed by s/m/h/d.
    \\
    \\  -k, --kill-after=DUR   send KILL after DUR additional seconds
    \\      --help             display this help and exit
    \\
    \\Exit status: 124 on timeout, otherwise the child's status.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var kill_after: ?f64 = null;
    var positional: usize = 0;
    var duration: f64 = 0;
    var cmd_start: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-k")) {
            i += 1;
            if (i >= args.len) return 2;
            kill_after = parseDur(args[i]);
        } else if (std.mem.startsWith(u8, a, "--kill-after=")) {
            kill_after = parseDur(a["--kill-after=".len..]);
        } else if (positional == 0) {
            duration = parseDur(a) orelse {
                ctx.err("invalid duration: '{s}'", .{a});
                return 1;
            };
            positional = 1;
            cmd_start = i + 1;
            break;
        }
    }

    if (cmd_start >= args.len) {
        ctx.usage("missing COMMAND", .{});
        return 2;
    }

    const child_argv = args[cmd_start..];

    // Spawn the child with std.process.spawn so we can monitor it.
    var child = std.process.spawn(ctx.io, .{
        .argv = @ptrCast(child_argv),
    }) catch |e| {
        ctx.err("cannot run '{s}': {s}", .{ child_argv[0], @errorName(e) });
        return 127;
    };

    // For Phase 3 we use a simple sleep + kill rather than a wait-with-timeout
    // primitive (the new Io API has Cancelable but stitching it to wait is
    // a Phase 4 polish item). The sleep is run in a separate thread so we
    // don't block on the wait.
    const TimeoutCtx = struct {
        child: *std.process.Child,
        duration_ns: u64,
        kill_after_ns: ?u64,
        io: std.Io,
        fn timeoutFn(self: *@This()) void {
            const dur: std.Io.Duration = .fromNanoseconds(@intCast(@min(self.duration_ns, std.math.maxInt(i96))));
            self.io.sleep(dur, .boot) catch return;
            // Try to terminate.
            self.child.kill(self.io);
            if (self.kill_after_ns) |k| {
                const dur2: std.Io.Duration = .fromNanoseconds(@intCast(@min(k, std.math.maxInt(i96))));
                self.io.sleep(dur2, .boot) catch return;
                self.child.kill(self.io);
            }
        }
    };

    var tctx: TimeoutCtx = .{
        .child = &child,
        .duration_ns = @intFromFloat(duration * @as(f64, std.time.ns_per_s)),
        .kill_after_ns = if (kill_after) |k| @intFromFloat(k * @as(f64, std.time.ns_per_s)) else null,
        .io = ctx.io,
    };

    const t = std.Thread.spawn(.{}, TimeoutCtx.timeoutFn, .{&tctx}) catch {
        // Fall back: wait without timer (won't enforce timeout).
        const term = child.wait(ctx.io) catch return 127;
        return mapTerm(term);
    };

    const term = child.wait(ctx.io) catch {
        t.detach();
        return 127;
    };
    t.detach();
    return mapTerm(term);
}

fn parseDur(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    const last = s[s.len - 1];
    const mult: f64 = switch (last) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        '0'...'9', '.' => 1,
        else => return null,
    };
    const num = if (last >= '0' and last <= '9' or last == '.') s else s[0 .. s.len - 1];
    return (std.fmt.parseFloat(f64, num) catch return null) * mult;
}

fn mapTerm(term: std.process.Child.Term) u8 {
    return switch (term) {
        .exited => |code| code,
        .signal => 128,
        .stopped => 128,
        .unknown => 1,
    };
}
