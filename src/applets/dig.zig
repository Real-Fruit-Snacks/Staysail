const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "dig";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: dig [@SERVER] [+short] [-x ADDR] NAME [TYPE]
    \\
    \\Query DNS records for NAME (or do reverse lookup with -x).
    \\Supported TYPEs: A (default), AAAA, MX, TXT, CNAME, NS, SOA, PTR.
    \\
    \\  @SERVER          query SERVER (default 1.1.1.1)
    \\  +short           short output: just the data
    \\  -x ADDR          reverse lookup an IP
    \\      --help       display this help and exit
    \\
;

const QType = enum(u16) {
    a = 1,
    ns = 2,
    cname = 5,
    soa = 6,
    ptr = 12,
    mx = 15,
    txt = 16,
    aaaa = 28,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var server: []const u8 = "1.1.1.1";
    var short = false;
    var reverse_addr: ?[]const u8 = null;
    var name_arg: ?[]const u8 = null;
    var qtype: QType = .a;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (a.len > 1 and a[0] == '@') {
            server = a[1..];
        } else if (std.mem.eql(u8, a, "+short")) {
            short = true;
        } else if (std.mem.eql(u8, a, "-x")) {
            i += 1;
            if (i >= args.len) return 2;
            reverse_addr = args[i];
        } else if (parseQType(a)) |t| {
            qtype = t;
        } else if (name_arg == null) {
            name_arg = a;
        }
    }

    if (reverse_addr) |addr| {
        // Build reverse-lookup name: 1.2.3.4 → 4.3.2.1.in-addr.arpa
        const reversed = try reverseIPv4(ctx.arena, addr);
        name_arg = reversed;
        qtype = .ptr;
    }

    if (name_arg == null) {
        ctx.usage("missing query NAME", .{});
        return 2;
    }

    return query(ctx, server, name_arg.?, qtype, short);
}

fn parseQType(s: []const u8) ?QType {
    if (std.ascii.eqlIgnoreCase(s, "A")) return .a;
    if (std.ascii.eqlIgnoreCase(s, "AAAA")) return .aaaa;
    if (std.ascii.eqlIgnoreCase(s, "MX")) return .mx;
    if (std.ascii.eqlIgnoreCase(s, "TXT")) return .txt;
    if (std.ascii.eqlIgnoreCase(s, "CNAME")) return .cname;
    if (std.ascii.eqlIgnoreCase(s, "NS")) return .ns;
    if (std.ascii.eqlIgnoreCase(s, "SOA")) return .soa;
    if (std.ascii.eqlIgnoreCase(s, "PTR")) return .ptr;
    return null;
}

fn reverseIPv4(arena: std.mem.Allocator, addr: []const u8) ![]const u8 {
    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, addr, '.');
    while (it.next()) |p| {
        if (n >= 4) return error.BadIPv4;
        parts[n] = p;
        n += 1;
    }
    if (n != 4) return error.BadIPv4;
    return std.fmt.allocPrint(arena, "{s}.{s}.{s}.{s}.in-addr.arpa", .{ parts[3], parts[2], parts[1], parts[0] });
}

fn query(ctx: *Context, server: []const u8, qname: []const u8, qtype: QType, short: bool) !u8 {
    // Build a DNS query packet.
    var pkt: std.ArrayList(u8) = .empty;
    defer pkt.deinit(ctx.arena);

    // Header (12 bytes): random ID, recursion desired, 1 question.
    var id_bytes: [2]u8 = undefined;
    ctx.io.random(&id_bytes);
    try pkt.appendSlice(ctx.arena, &id_bytes);
    try pkt.appendSlice(ctx.arena, &[_]u8{ 0x01, 0x00 }); // flags: RD
    try pkt.appendSlice(ctx.arena, &[_]u8{ 0x00, 0x01 }); // QDCOUNT=1
    try pkt.appendSlice(ctx.arena, &[_]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 });

    // Encode question name as labels.
    var label_it = std.mem.splitScalar(u8, qname, '.');
    while (label_it.next()) |label| {
        if (label.len == 0) continue;
        if (label.len > 63) return 2;
        try pkt.append(ctx.arena, @intCast(label.len));
        try pkt.appendSlice(ctx.arena, label);
    }
    try pkt.append(ctx.arena, 0);
    // QTYPE / QCLASS=IN
    const qt: u16 = @intFromEnum(qtype);
    try pkt.append(ctx.arena, @intCast(qt >> 8));
    try pkt.append(ctx.arena, @intCast(qt & 0xff));
    try pkt.appendSlice(ctx.arena, &[_]u8{ 0x00, 0x01 });

    // Connect via UDP and send.
    const ip = std.Io.net.IpAddress.parseIp4(server, 53) catch |e| {
        ctx.err("invalid server address '{s}': {s}", .{ server, @errorName(e) });
        return 1;
    };

    const stream = std.Io.net.IpAddress.connect(&ip, ctx.io, .{ .mode = .dgram, .protocol = .udp }) catch |e| {
        ctx.err("UDP connect failed: {s}", .{@errorName(e)});
        return 1;
    };
    defer stream.close(ctx.io);

    var write_buf: [1024]u8 = undefined;
    var stream_writer: std.Io.net.Stream.Writer = .init(stream, ctx.io, &write_buf);
    stream_writer.interface.writeAll(pkt.items) catch |e| {
        ctx.err("send failed: {s}", .{@errorName(e)});
        return 1;
    };
    stream_writer.interface.flush() catch {};

    var read_buf: [4096]u8 = undefined;
    var stream_reader: std.Io.net.Stream.Reader = .init(stream, ctx.io, &read_buf);
    var resp: std.ArrayList(u8) = .empty;
    defer resp.deinit(ctx.arena);
    // UDP DNS responses fit in one packet; just read what's available.
    const peeked = stream_reader.interface.peek(4096) catch |e| switch (e) {
        error.EndOfStream => stream_reader.interface.buffered(),
        else => {
            ctx.err("recv failed: {s}", .{@errorName(e)});
            return 1;
        },
    };
    try resp.appendSlice(ctx.arena, peeked);
    if (resp.items.len == 0) {
        ctx.err("no response from server", .{});
        return 1;
    }
    return parseResponse(ctx, resp.items, qname, qtype, short);
}

fn parseResponse(ctx: *Context, data: []const u8, qname: []const u8, qtype: QType, short: bool) !u8 {
    if (data.len < 12) return 1;
    const ancount = (@as(u16, data[6]) << 8) | data[7];
    const qdcount = (@as(u16, data[4]) << 8) | data[5];

    if (!short) try ctx.stdout.print(";; ANSWER {d} record(s) for {s} {s}\n", .{ ancount, qname, @tagName(qtype) });

    var pos: usize = 12;
    // Skip questions.
    var qi: usize = 0;
    while (qi < qdcount) : (qi += 1) {
        pos = skipName(data, pos);
        pos += 4; // qtype + qclass
    }
    var ai: usize = 0;
    while (ai < ancount) : (ai += 1) {
        if (pos + 10 > data.len) break;
        const rname_end = skipName(data, pos);
        if (rname_end + 10 > data.len) break;
        const rtype = (@as(u16, data[rname_end]) << 8) | data[rname_end + 1];
        const rdlen = (@as(u16, data[rname_end + 8]) << 8) | data[rname_end + 9];
        const rdata_start = rname_end + 10;
        if (rdata_start + rdlen > data.len) break;
        try printRecord(ctx, data, rdata_start, rdlen, rtype, short);
        pos = rdata_start + rdlen;
    }
    return 0;
}

fn skipName(data: []const u8, start: usize) usize {
    var pos = start;
    while (pos < data.len) {
        const len = data[pos];
        if (len == 0) {
            return pos + 1;
        }
        if ((len & 0xC0) == 0xC0) {
            return pos + 2; // pointer
        }
        pos += 1 + len;
    }
    return pos;
}

fn printRecord(ctx: *Context, data: []const u8, start: usize, len: u16, rtype: u16, short: bool) !void {
    switch (rtype) {
        1 => { // A
            if (len != 4) return;
            try ctx.stdout.print("{s}{d}.{d}.{d}.{d}\n", .{ if (short) "" else "A\t", data[start], data[start + 1], data[start + 2], data[start + 3] });
        },
        28 => { // AAAA
            if (len != 16) return;
            try ctx.stdout.writeAll(if (short) "" else "AAAA\t");
            var i: usize = 0;
            while (i < 16) : (i += 2) {
                if (i > 0) try ctx.stdout.writeByte(':');
                try ctx.stdout.print("{x:0>2}{x:0>2}", .{ data[start + i], data[start + i + 1] });
            }
            try ctx.stdout.writeByte('\n');
        },
        16 => { // TXT
            // First byte is length of the string.
            if (len < 1) return;
            const tlen = data[start];
            if (start + 1 + tlen > data.len) return;
            try ctx.stdout.print("{s}\"{s}\"\n", .{ if (short) "" else "TXT\t", data[start + 1 .. start + 1 + tlen] });
        },
        15 => { // MX
            if (len < 2) return;
            const pref = (@as(u16, data[start]) << 8) | data[start + 1];
            try ctx.stdout.print("{s}{d} ", .{ if (short) "" else "MX\t", pref });
            try printName(ctx, data, start + 2);
            try ctx.stdout.writeByte('\n');
        },
        2, 5, 12 => { // NS / CNAME / PTR
            const label: []const u8 = switch (rtype) {
                2 => "NS\t",
                5 => "CNAME\t",
                12 => "PTR\t",
                else => "\t",
            };
            try ctx.stdout.writeAll(if (short) "" else label);
            try printName(ctx, data, start);
            try ctx.stdout.writeByte('\n');
        },
        else => {
            if (!short) try ctx.stdout.print("(type {d}, {d} bytes)\n", .{ rtype, len });
        },
    }
}

fn printName(ctx: *Context, data: []const u8, start: usize) !void {
    var pos = start;
    var first = true;
    while (pos < data.len) {
        const len = data[pos];
        if (len == 0) return;
        if ((len & 0xC0) == 0xC0) {
            if (pos + 1 >= data.len) return;
            const ptr = ((@as(usize, len) & 0x3F) << 8) | data[pos + 1];
            try printName(ctx, data, ptr);
            return;
        }
        if (!first) try ctx.stdout.writeByte('.');
        first = false;
        if (pos + 1 + len > data.len) return;
        try ctx.stdout.writeAll(data[pos + 1 .. pos + 1 + len]);
        pos += 1 + len;
    }
}
