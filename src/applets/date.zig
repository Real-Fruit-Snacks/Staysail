const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "date";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: date [OPTION]... [+FORMAT]
    \\
    \\Display the current time in the given FORMAT, or in a default form.
    \\
    \\  -u, --utc           print Coordinated Universal Time (UTC)
    \\  -R, --rfc-email     output in RFC 5322 format
    \\  -I[fmt], --iso-8601[=fmt]   output in ISO-8601 format (date|hours|minutes|seconds)
    \\      --help          display this help and exit
    \\
    \\FORMAT controls the output. Supported:
    \\  %Y year (4 digits)        %m month (01..12)         %d day (01..31)
    \\  %H hour (00..23)          %M minute (00..59)        %S second (00..60)
    \\  %j day of year (001..366) %s seconds since epoch    %% literal %
    \\  %F same as %Y-%m-%d       %T same as %H:%M:%S       %n newline %t tab
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var format: ?[]const u8 = null;
    var iso_kind: ?[]const u8 = null;
    var rfc_email = false;

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--utc") or std.mem.eql(u8, a, "--universal")) {
            // Always UTC for now; flag accepted.
        } else if (std.mem.eql(u8, a, "-R") or std.mem.eql(u8, a, "--rfc-email")) {
            rfc_email = true;
        } else if (std.mem.eql(u8, a, "-I")) {
            iso_kind = "date";
        } else if (std.mem.startsWith(u8, a, "-I")) {
            iso_kind = a[2..];
        } else if (std.mem.startsWith(u8, a, "--iso-8601")) {
            iso_kind = if (std.mem.indexOfScalar(u8, a, '=')) |eq| a[eq + 1 ..] else "date";
        } else if (a.len > 0 and a[0] == '+') {
            format = a[1..];
        } else {
            ctx.usage("unknown argument: '{s}'", .{a});
            return 2;
        }
    }

    // Get the current epoch seconds. For UTC vs local we don't have OS
    // timezone APIs in 0.16 in a portable way, so output is always UTC.
    const ts = std.Io.Clock.real.now(ctx.io);
    const epoch_s_signed: i64 = @intCast(@divFloor(ts.nanoseconds, std.time.ns_per_s));
    if (epoch_s_signed < 0) {
        try ctx.stdout.writeAll("(pre-epoch)\n");
        return 0;
    }
    const epoch_s: u64 = @intCast(epoch_s_signed);
    const t = decompose(epoch_s);

    if (rfc_email) {
        try emitRfc(ctx, t);
        return 0;
    }
    if (iso_kind) |k| {
        try emitIso(ctx, t, k);
        return 0;
    }
    if (format) |f| {
        try emitFormat(ctx, t, f, epoch_s);
        try ctx.stdout.writeByte('\n');
        return 0;
    }

    // Default: like `date -u`.
    try ctx.stdout.print("{s} {s} {d:>2} {d:0>2}:{d:0>2}:{d:0>2} UTC {d}\n", .{
        weekdayShort(t.weekday),
        monthShort(t.month),
        t.day,
        t.hour,
        t.minute,
        t.second,
        t.year,
    });
    return 0;
}

const Time = struct {
    year: u32,
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8,
    minute: u8,
    second: u8,
    weekday: u8, // 0=Sun..6=Sat
    yday: u16, // 1..366
};

fn decompose(epoch_s: u64) Time {
    const SECS_PER_DAY: u64 = 86400;
    var days = epoch_s / SECS_PER_DAY;
    var rem = epoch_s % SECS_PER_DAY;
    const hour: u8 = @intCast(rem / 3600);
    rem %= 3600;
    const minute: u8 = @intCast(rem / 60);
    const second: u8 = @intCast(rem % 60);

    // 1970-01-01 was a Thursday → weekday 4.
    const weekday: u8 = @intCast((days + 4) % 7);

    var year: u32 = 1970;
    while (true) {
        const ydays: u32 = if (isLeap(year)) 366 else 365;
        if (days < ydays) break;
        days -= ydays;
        year += 1;
    }
    const yday: u16 = @intCast(days + 1);

    const days_in_month = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u8 = 1;
    var d: u32 = @intCast(days);
    while (month <= 12) : (month += 1) {
        const dm: u32 = days_in_month[month - 1] + @as(u32, @intFromBool(month == 2 and isLeap(year)));
        if (d < dm) break;
        d -= dm;
    }
    const day: u8 = @intCast(d + 1);

    return .{
        .year = year,
        .month = month,
        .day = day,
        .hour = hour,
        .minute = minute,
        .second = second,
        .weekday = weekday,
        .yday = yday,
    };
}

fn isLeap(y: u32) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn weekdayShort(w: u8) []const u8 {
    const names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    return names[w % 7];
}

fn monthShort(m: u8) []const u8 {
    const names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    if (m < 1 or m > 12) return "???";
    return names[m - 1];
}

fn emitRfc(ctx: *Context, t: Time) !void {
    try ctx.stdout.print("{s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000\n", .{
        weekdayShort(t.weekday), t.day, monthShort(t.month), t.year, t.hour, t.minute, t.second,
    });
}

fn emitIso(ctx: *Context, t: Time, kind: []const u8) !void {
    if (std.mem.eql(u8, kind, "date") or kind.len == 0) {
        try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}\n", .{ t.year, t.month, t.day });
    } else if (std.mem.eql(u8, kind, "hours")) {
        try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}+00:00\n", .{ t.year, t.month, t.day, t.hour });
    } else if (std.mem.eql(u8, kind, "minutes")) {
        try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}+00:00\n", .{ t.year, t.month, t.day, t.hour, t.minute });
    } else if (std.mem.eql(u8, kind, "seconds")) {
        try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}+00:00\n", .{ t.year, t.month, t.day, t.hour, t.minute, t.second });
    } else {
        try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}\n", .{ t.year, t.month, t.day });
    }
}

fn emitFormat(ctx: *Context, t: Time, fmt: []const u8, epoch_s: u64) !void {
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        const c = fmt[i];
        if (c != '%') {
            try ctx.stdout.writeByte(c);
            continue;
        }
        if (i + 1 >= fmt.len) {
            try ctx.stdout.writeByte('%');
            continue;
        }
        i += 1;
        switch (fmt[i]) {
            'Y' => try ctx.stdout.print("{d}", .{t.year}),
            'm' => try ctx.stdout.print("{d:0>2}", .{t.month}),
            'd' => try ctx.stdout.print("{d:0>2}", .{t.day}),
            'H' => try ctx.stdout.print("{d:0>2}", .{t.hour}),
            'M' => try ctx.stdout.print("{d:0>2}", .{t.minute}),
            'S' => try ctx.stdout.print("{d:0>2}", .{t.second}),
            'j' => try ctx.stdout.print("{d:0>3}", .{t.yday}),
            's' => try ctx.stdout.print("{d}", .{epoch_s}),
            'F' => try ctx.stdout.print("{d}-{d:0>2}-{d:0>2}", .{ t.year, t.month, t.day }),
            'T' => try ctx.stdout.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ t.hour, t.minute, t.second }),
            'a' => try ctx.stdout.writeAll(weekdayShort(t.weekday)),
            'b' => try ctx.stdout.writeAll(monthShort(t.month)),
            'n' => try ctx.stdout.writeByte('\n'),
            't' => try ctx.stdout.writeByte('\t'),
            '%' => try ctx.stdout.writeByte('%'),
            else => |ch| {
                try ctx.stdout.writeByte('%');
                try ctx.stdout.writeByte(ch);
            },
        }
    }
}
