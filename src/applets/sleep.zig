const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "sleep";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: sleep NUMBER[SUFFIX]...
    \\
    \\Pause for NUMBER seconds. SUFFIX may be 's' for seconds (default),
    \\'m' for minutes, 'h' for hours, or 'd' for days.
    \\Given multiple arguments, sleep for the sum of their values.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    if (args.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }

    var total_ns: u64 = 0;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        const ns = parseDuration(a) orelse {
            ctx.err("invalid time interval '{s}'", .{a});
            return 1;
        };
        total_ns +|= ns;
    }

    const ns: i96 = if (total_ns > std.math.maxInt(i96)) std.math.maxInt(i96) else @intCast(total_ns);
    const dur: std.Io.Duration = .fromNanoseconds(ns);
    ctx.io.sleep(dur, .boot) catch |e| switch (e) {
        error.Canceled => return 130,
    };
    return 0;
}

fn parseDuration(s: []const u8) ?u64 {
    if (s.len == 0) return null;

    const last = s[s.len - 1];
    const multiplier_ns: u64 = switch (last) {
        's' => std.time.ns_per_s,
        'm' => 60 * std.time.ns_per_s,
        'h' => 60 * 60 * std.time.ns_per_s,
        'd' => 24 * 60 * 60 * std.time.ns_per_s,
        '0'...'9', '.' => std.time.ns_per_s,
        else => return null,
    };

    const numeric = if (last >= '0' and last <= '9') s else s[0 .. s.len - 1];
    if (numeric.len == 0) return null;

    // Try integer first, fall back to float for fractional values.
    if (std.fmt.parseInt(u64, numeric, 10)) |i| {
        return i *| multiplier_ns;
    } else |_| {
        const f = std.fmt.parseFloat(f64, numeric) catch return null;
        if (f < 0) return null;
        const ns_f = f * @as(f64, @floatFromInt(multiplier_ns));
        if (ns_f >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) {
            return std.math.maxInt(u64);
        }
        return @intFromFloat(ns_f);
    }
}
