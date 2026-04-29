const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "http";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: http [METHOD] URL [OPTIONS]
    \\
    \\Make an HTTP(S) request and write the response body to stdout.
    \\
    \\METHOD is one of: GET (default), POST, PUT, DELETE, HEAD, PATCH.
    \\
    \\Options:
    \\  -H, --header NAME:VALUE   add a custom header (repeatable)
    \\  -d, --data BODY           request body literal (or @file)
    \\  -j, --json BODY           request body, set Content-Type to application/json
    \\  -X METHOD                 alternate way to set HTTP method
    \\  -s, --silent              suppress diagnostics on stderr
    \\  -i, --include             include response status + headers in output
    \\      --fail                exit non-zero on HTTP >=400
    \\      --help                display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var url: ?[]const u8 = null;
    var method: ?std.http.Method = null;
    var headers: std.ArrayList(std.http.Header) = .empty;
    defer headers.deinit(ctx.arena);
    var body: ?[]const u8 = null;
    var include = false;
    var silent = false;
    var fail = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-H") or std.mem.eql(u8, a, "--header")) {
            i += 1;
            if (i >= args.len) return 2;
            try parseHeader(ctx, args[i], &headers);
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--data")) {
            i += 1;
            if (i >= args.len) return 2;
            body = try resolveBody(ctx, args[i]);
            if (method == null) method = .POST;
        } else if (std.mem.eql(u8, a, "-j") or std.mem.eql(u8, a, "--json")) {
            i += 1;
            if (i >= args.len) return 2;
            body = try resolveBody(ctx, args[i]);
            if (method == null) method = .POST;
            try headers.append(ctx.arena, .{ .name = "Content-Type", .value = "application/json" });
        } else if (std.mem.eql(u8, a, "-X")) {
            i += 1;
            if (i >= args.len) return 2;
            method = parseMethod(args[i]) orelse {
                ctx.err("invalid method: '{s}'", .{args[i]});
                return 2;
            };
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--include")) {
            include = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--silent")) {
            silent = true;
        } else if (std.mem.eql(u8, a, "--fail")) {
            fail = true;
        } else if (parseMethod(a)) |m| {
            // Bare METHOD as positional.
            method = m;
        } else if (url == null) {
            url = a;
        }
    }

    if (url == null) {
        ctx.usage("missing URL", .{});
        return 2;
    }

    var client: std.http.Client = .{
        .allocator = ctx.gpa,
        .io = ctx.io,
    };
    defer client.deinit();

    // Capture body to an in-memory writer so we can either include headers or
    // pipe it raw to stdout.
    var body_out: std.ArrayList(u8) = .empty;
    defer body_out.deinit(ctx.arena);

    // Use a fixed writer onto an arena slice for the body; expand if needed.
    const initial_buf = try ctx.arena.alloc(u8, 256 * 1024);
    var body_writer = std.Io.Writer.fixed(initial_buf);

    const result = client.fetch(.{
        .location = .{ .url = url.? },
        .method = method,
        .payload = body,
        .extra_headers = headers.items,
        .response_writer = &body_writer,
    }) catch |e| {
        if (!silent) ctx.err("request failed: {s}", .{@errorName(e)});
        return 1;
    };

    const status_code: u10 = @intFromEnum(result.status);
    if (include) {
        try ctx.stdout.print("HTTP/1.1 {d} {s}\n\n", .{ status_code, @tagName(result.status) });
    }
    try ctx.stdout.writeAll(body_writer.buffered());

    if (fail and status_code >= 400) {
        return 1;
    }
    return 0;
}

fn parseHeader(ctx: *Context, h: []const u8, out: *std.ArrayList(std.http.Header)) !void {
    const colon = std.mem.indexOfScalar(u8, h, ':') orelse return;
    const n = std.mem.trim(u8, h[0..colon], " \t");
    const v = std.mem.trim(u8, h[colon + 1 ..], " \t");
    try out.append(ctx.arena, .{
        .name = try ctx.arena.dupe(u8, n),
        .value = try ctx.arena.dupe(u8, v),
    });
}

fn resolveBody(ctx: *Context, spec: []const u8) ![]const u8 {
    if (spec.len > 0 and spec[0] == '@') {
        const path = spec[1..];
        const cwd = std.Io.Dir.cwd();
        const f = try cwd.openFile(ctx.io, path, .{});
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        var buf: std.ArrayList(u8) = .empty;
        fr.interface.appendRemainingUnlimited(ctx.arena, &buf) catch {};
        return buf.items;
    }
    return spec;
}

fn parseMethod(s: []const u8) ?std.http.Method {
    inline for (.{ "GET", "POST", "PUT", "DELETE", "HEAD", "PATCH", "OPTIONS" }) |m| {
        if (std.mem.eql(u8, s, m)) return @field(std.http.Method, m);
    }
    return null;
}
