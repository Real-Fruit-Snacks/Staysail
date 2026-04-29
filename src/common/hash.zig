//! Shared implementation for the *sum applets (md5sum, sha1sum, sha256sum,
//! sha512sum). Caller supplies the hash type and the canonical applet name.

const std = @import("std");
const Context = @import("context.zig");

pub fn run(comptime Hash: type, ctx: *Context, args: []const [:0]const u8) !u8 {
    var check = false;
    var binary = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(genericHelp(Hash));
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--check")) {
            check = true;
        } else if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--binary")) {
            binary = true;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--text")) {
            binary = false;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (check) {
        // -c: read sum lines from input(s), verify each.
        return verify(Hash, ctx, operands.items);
    }

    var any_error = false;
    if (operands.items.len == 0) {
        var sum_buf: [Hash.digest_length * 2]u8 = undefined;
        const hex = try hashReader(Hash, ctx, ctx.stdin, &sum_buf);
        try ctx.stdout.print("{s}  -\n", .{hex});
    } else for (operands.items) |path| {
        const cwd = std.Io.Dir.cwd();
        const f = if (std.mem.eql(u8, path, "-")) null else cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("{s}: {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        var sum_buf: [Hash.digest_length * 2]u8 = undefined;
        const hex = blk: {
            if (f == null) {
                break :blk try hashReader(Hash, ctx, ctx.stdin, &sum_buf);
            }
            defer f.?.close(ctx.io);
            var rb: [16 * 1024]u8 = undefined;
            var fr = f.?.reader(ctx.io, &rb);
            break :blk try hashReader(Hash, ctx, &fr.interface, &sum_buf);
        };
        const sep: []const u8 = if (binary) " *" else "  ";
        try ctx.stdout.print("{s}{s}{s}\n", .{ hex, sep, path });
    }
    return if (any_error) 1 else 0;
}

fn hashReader(comptime Hash: type, ctx: *Context, r: *std.Io.Reader, out_hex: []u8) ![]const u8 {
    _ = ctx;
    var h = Hash.init(.{});
    while (true) {
        const peeked = r.peek(16 * 1024) catch |e| switch (e) {
            error.EndOfStream => {
                const buffered = r.buffered();
                if (buffered.len > 0) {
                    h.update(buffered);
                    r.toss(buffered.len);
                }
                break;
            },
            else => return e,
        };
        h.update(peeked);
        r.toss(peeked.len);
    }
    var digest: [Hash.digest_length]u8 = undefined;
    h.final(&digest);
    return std.fmt.bufPrint(out_hex, "{x}", .{&digest});
}

fn verify(comptime Hash: type, ctx: *Context, files: []const [:0]const u8) !u8 {
    var bad: usize = 0;
    var total: usize = 0;

    if (files.len == 0) {
        return verifyReader(Hash, ctx, ctx.stdin, "(stdin)", &total, &bad);
    }
    for (files) |path| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("{s}: {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [8 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        _ = try verifyReader(Hash, ctx, &fr.interface, path, &total, &bad);
    }
    if (bad > 0) {
        try ctx.stderr.print("WARNING: {d} of {d} computed checksum did NOT match\n", .{ bad, total });
        return 1;
    }
    return 0;
}

fn verifyReader(comptime Hash: type, ctx: *Context, r: *std.Io.Reader, label: []const u8, total: *usize, bad: *usize) !u8 {
    _ = label;
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // Format: <hex>  <filename>  (or "*<filename>" for binary)
        const sep = std.mem.indexOf(u8, line, "  ") orelse std.mem.indexOf(u8, line, " *") orelse continue;
        const expected_hex = line[0..sep];
        const file_path = std.mem.trim(u8, line[sep + 2 ..], " \t\r");
        if (file_path.len == 0) continue;
        total.* += 1;

        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, file_path, .{}) catch |e| {
            try ctx.stdout.print("{s}: FAILED open or read ({s})\n", .{ file_path, @errorName(e) });
            bad.* += 1;
            continue;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        var sum_buf: [Hash.digest_length * 2]u8 = undefined;
        const got_hex = try hashReader(Hash, ctx, &fr.interface, &sum_buf);
        if (std.mem.eql(u8, got_hex, expected_hex)) {
            try ctx.stdout.print("{s}: OK\n", .{file_path});
        } else {
            try ctx.stdout.print("{s}: FAILED\n", .{file_path});
            bad.* += 1;
        }
    }
    return 0;
}

fn genericHelp(comptime Hash: type) []const u8 {
    return "Usage: " ++ @typeName(Hash) ++ " [OPTION]... [FILE]...\n\n" ++
        "Print or check checksums.\n\n" ++
        "  -b, --binary      read in binary mode (default for stdin in pipe)\n" ++
        "  -c, --check       read sums from FILE(s) and verify them\n" ++
        "  -t, --text        read in text mode\n" ++
        "      --help        display this help and exit\n";
}
