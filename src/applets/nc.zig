const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "nc";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: nc [OPTION]... HOST PORT       (connect mode)
    \\       nc -l [-p] PORT                (listen mode)
    \\       nc -z HOST PORT[-PORT]         (port-scan mode)
    \\
    \\TCP netcat: connect to or listen on TCP ports.
    \\
    \\  -l, --listen      listen for an incoming connection
    \\  -p PORT           with -l, listen on PORT
    \\  -z                scan: just check if port(s) are open, don't transfer
    \\      --help        display this help and exit
    \\
    \\In connect mode, stdin is sent to the remote and the remote's data is
    \\written to stdout, then the process exits when either side closes.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var listen = false;
    var scan = false;
    var listen_port: ?u16 = null;
    var positional: std.ArrayList([]const u8) = .empty;
    defer positional.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-l") or std.mem.eql(u8, a, "--listen")) {
            listen = true;
        } else if (std.mem.eql(u8, a, "-z")) {
            scan = true;
        } else if (std.mem.eql(u8, a, "-p")) {
            i += 1;
            if (i >= args.len) return 2;
            listen_port = std.fmt.parseInt(u16, args[i], 10) catch null;
        } else {
            try positional.append(ctx.arena, a);
        }
    }

    if (listen) {
        const port = if (listen_port) |p| p else if (positional.items.len >= 1)
            std.fmt.parseInt(u16, positional.items[0], 10) catch {
                ctx.err("invalid port", .{});
                return 2;
            }
        else {
            ctx.usage("listen mode requires a port", .{});
            return 2;
        };

        const ip = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
        var server = ip.listen(ctx.io, .{}) catch |e| {
            ctx.err("listen failed: {s}", .{@errorName(e)});
            return 1;
        };
        defer server.deinit(ctx.io);
        try ctx.stderr.print("listening on 0.0.0.0:{d}\n", .{port});

        const stream = server.accept(ctx.io) catch |e| {
            ctx.err("accept failed: {s}", .{@errorName(e)});
            return 1;
        };
        defer stream.close(ctx.io);
        return shuffle(ctx, stream);
    }

    if (positional.items.len < 2) {
        ctx.usage("connect mode requires HOST and PORT", .{});
        return 2;
    }

    const host = positional.items[0];
    const port_str = positional.items[1];

    if (scan) {
        // Single-port scan only for Phase 4.
        const port = std.fmt.parseInt(u16, port_str, 10) catch {
            ctx.err("invalid port: '{s}'", .{port_str});
            return 2;
        };
        const ip = std.Io.net.IpAddress.parseIp4(host, port) catch |e| {
            ctx.err("invalid host '{s}': {s} (Phase 4 only supports literal IPv4)", .{ host, @errorName(e) });
            return 1;
        };
        const stream = std.Io.net.IpAddress.connect(&ip, ctx.io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            try ctx.stderr.print("port {d}: closed ({s})\n", .{ port, @errorName(e) });
            return 1;
        };
        defer stream.close(ctx.io);
        try ctx.stderr.print("port {d}: open\n", .{port});
        return 0;
    }

    const port = std.fmt.parseInt(u16, port_str, 10) catch {
        ctx.err("invalid port: '{s}'", .{port_str});
        return 2;
    };
    const ip = std.Io.net.IpAddress.parseIp4(host, port) catch |e| {
        ctx.err("invalid host '{s}': {s} (Phase 4 only supports literal IPv4)", .{ host, @errorName(e) });
        return 1;
    };
    const stream = std.Io.net.IpAddress.connect(&ip, ctx.io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
        ctx.err("connect failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer stream.close(ctx.io);
    return shuffle(ctx, stream);
}

fn shuffle(ctx: *Context, stream: std.Io.net.Stream) !u8 {
    // Bidirectional: a worker thread shuttles stdin → remote while the main
    // thread shuttles remote → stdout. Whoever sees EOF first signals done.
    const Pump = struct {
        ctx: *Context,
        stream: std.Io.net.Stream,
        done: *std.atomic.Value(bool),

        fn stdinToRemote(self: *@This()) void {
            var write_buf: [16 * 1024]u8 = undefined;
            var stream_writer: std.Io.net.Stream.Writer = .init(self.stream, self.ctx.io, &write_buf);
            while (!self.done.load(.acquire)) {
                const peeked = self.ctx.stdin.peek(16 * 1024) catch |e| switch (e) {
                    error.EndOfStream => break,
                    else => break,
                };
                if (peeked.len == 0) break;
                stream_writer.interface.writeAll(peeked) catch break;
                stream_writer.interface.flush() catch break;
                self.ctx.stdin.toss(peeked.len);
            }
            self.done.store(true, .release);
        }
    };

    var done: std.atomic.Value(bool) = .init(false);
    var pump: Pump = .{ .ctx = ctx, .stream = stream, .done = &done };
    const t = std.Thread.spawn(.{}, Pump.stdinToRemote, .{&pump}) catch {
        // Fall back to drain-only if threading fails.
        return drainRemote(ctx, stream);
    };
    defer t.detach();

    var read_buf: [16 * 1024]u8 = undefined;
    var stream_reader: std.Io.net.Stream.Reader = .init(stream, ctx.io, &read_buf);
    while (!done.load(.acquire)) {
        const peeked = stream_reader.interface.peek(read_buf.len) catch |e| switch (e) {
            error.EndOfStream => break,
            else => {
                ctx.err("read failed: {s}", .{@errorName(e)});
                done.store(true, .release);
                return 1;
            },
        };
        if (peeked.len == 0) break;
        try ctx.stdout.writeAll(peeked);
        stream_reader.interface.toss(peeked.len);
    }
    done.store(true, .release);
    return 0;
}

fn drainRemote(ctx: *Context, stream: std.Io.net.Stream) !u8 {
    var read_buf: [16 * 1024]u8 = undefined;
    var stream_reader: std.Io.net.Stream.Reader = .init(stream, ctx.io, &read_buf);
    while (true) {
        const peeked = stream_reader.interface.peek(read_buf.len) catch |e| switch (e) {
            error.EndOfStream => break,
            else => return 1,
        };
        if (peeked.len == 0) break;
        try ctx.stdout.writeAll(peeked);
        stream_reader.interface.toss(peeked.len);
    }
    return 0;
}
