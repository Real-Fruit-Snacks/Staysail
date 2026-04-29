const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "zip";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: zip ARCHIVE.zip FILE...
    \\
    \\Create a zip archive containing each FILE.
    \\
    \\Phase 4 limitation: writes uncompressed (store) entries only. Deflate
    \\compression on write is on the Phase 5 list.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        try operands.append(ctx.arena, a);
    }
    if (operands.items.len < 2) {
        ctx.usage("expected ARCHIVE and at least one FILE", .{});
        return 2;
    }
    const archive_path = operands.items[0];
    const files = operands.items[1..];

    const cwd = std.Io.Dir.cwd();
    const out = cwd.createFile(ctx.io, archive_path, .{}) catch |e| {
        ctx.err("cannot create '{s}': {s}", .{ archive_path, @errorName(e) });
        return 1;
    };
    defer out.close(ctx.io);
    var ob: [16 * 1024]u8 = undefined;
    var ow: std.Io.File.Writer = .initStreaming(out, ctx.io, &ob);
    const w = &ow.interface;

    var central_dir: std.ArrayList(u8) = .empty;
    defer central_dir.deinit(ctx.arena);

    var num_entries: u16 = 0;
    var central_dir_offset: u32 = 0;
    var bytes_written: u32 = 0;

    for (files) |path| {
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            continue;
        };
        defer f.close(ctx.io);
        const st = f.stat(ctx.io) catch continue;

        // Read file fully.
        var data: std.ArrayList(u8) = .empty;
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
        const crc = std.hash.Crc32.hash(data.items);
        const size: u32 = @intCast(@min(data.items.len, std.math.maxInt(u32)));

        const local_offset = bytes_written;

        // Write local file header.
        try w.writeAll(&std.zip.local_file_header_sig);
        try writeU16(w, 20); // version needed
        try writeU16(w, 0); // flags
        try writeU16(w, @intFromEnum(std.zip.CompressionMethod.store));
        try writeU16(w, 0); // mod time
        try writeU16(w, 0); // mod date
        try writeU32(w, crc);
        try writeU32(w, size); // compressed size
        try writeU32(w, size); // uncompressed size
        try writeU16(w, @intCast(path.len));
        try writeU16(w, 0); // extra
        try w.writeAll(path);
        try w.writeAll(data.items);

        bytes_written += @intCast(@sizeOf(@TypeOf(std.zip.local_file_header_sig)) + 26 + path.len + size);

        // Append a central directory entry.
        try central_dir.appendSlice(ctx.arena, &std.zip.central_file_header_sig);
        try appendU16(ctx.arena, &central_dir, 20); // version made by
        try appendU16(ctx.arena, &central_dir, 20); // version needed
        try appendU16(ctx.arena, &central_dir, 0); // flags
        try appendU16(ctx.arena, &central_dir, @intFromEnum(std.zip.CompressionMethod.store));
        try appendU16(ctx.arena, &central_dir, 0); // mod time
        try appendU16(ctx.arena, &central_dir, 0); // mod date
        try appendU32(ctx.arena, &central_dir, crc);
        try appendU32(ctx.arena, &central_dir, size);
        try appendU32(ctx.arena, &central_dir, size);
        try appendU16(ctx.arena, &central_dir, @intCast(path.len));
        try appendU16(ctx.arena, &central_dir, 0); // extra
        try appendU16(ctx.arena, &central_dir, 0); // comment
        try appendU16(ctx.arena, &central_dir, 0); // disk number
        try appendU16(ctx.arena, &central_dir, 0); // internal attrs
        try appendU32(ctx.arena, &central_dir, 0); // external attrs
        try appendU32(ctx.arena, &central_dir, local_offset);
        try central_dir.appendSlice(ctx.arena, path);
        _ = st;

        num_entries += 1;
    }

    central_dir_offset = bytes_written;
    try w.writeAll(central_dir.items);

    // End-of-central-directory record.
    try w.writeAll(&std.zip.end_record_sig);
    try writeU16(w, 0); // disk
    try writeU16(w, 0); // disk start
    try writeU16(w, num_entries);
    try writeU16(w, num_entries);
    try writeU32(w, @intCast(central_dir.items.len));
    try writeU32(w, central_dir_offset);
    try writeU16(w, 0); // comment

    try ow.interface.flush();
    return 0;
}

fn writeU16(w: *std.Io.Writer, v: u16) !void {
    try w.writeByte(@intCast(v & 0xff));
    try w.writeByte(@intCast((v >> 8) & 0xff));
}

fn writeU32(w: *std.Io.Writer, v: u32) !void {
    try w.writeByte(@intCast(v & 0xff));
    try w.writeByte(@intCast((v >> 8) & 0xff));
    try w.writeByte(@intCast((v >> 16) & 0xff));
    try w.writeByte(@intCast((v >> 24) & 0xff));
}

fn appendU16(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u16) !void {
    try list.append(gpa, @intCast(v & 0xff));
    try list.append(gpa, @intCast((v >> 8) & 0xff));
}

fn appendU32(gpa: std.mem.Allocator, list: *std.ArrayList(u8), v: u32) !void {
    try list.append(gpa, @intCast(v & 0xff));
    try list.append(gpa, @intCast((v >> 8) & 0xff));
    try list.append(gpa, @intCast((v >> 16) & 0xff));
    try list.append(gpa, @intCast((v >> 24) & 0xff));
}
