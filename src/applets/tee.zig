const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "tee";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: tee [OPTION]... [FILE]...
    \\
    \\Copy standard input to each FILE, and also to standard output.
    \\
    \\  -a, --append   append to the given FILEs, do not overwrite
    \\  -i, --ignore-interrupts  (accepted for compatibility; no effect)
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var append = false;
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--append")) {
            append = true;
        } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-interrupts")) {
            // no-op
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try paths.append(ctx.arena, args[i]);
            break;
        } else {
            try paths.append(ctx.arena, a);
        }
    }

    const cwd = std.Io.Dir.cwd();
    var files: std.ArrayList(std.Io.File) = .empty;
    var writers: std.ArrayList(*std.Io.File.Writer) = .empty;
    defer {
        for (files.items) |f| f.close(ctx.io);
        files.deinit(ctx.arena);
        writers.deinit(ctx.arena);
    }

    var bufs: std.ArrayList([8 * 1024]u8) = .empty;
    defer bufs.deinit(ctx.arena);
    try bufs.ensureTotalCapacity(ctx.arena, paths.items.len);
    var fws: std.ArrayList(std.Io.File.Writer) = .empty;
    defer fws.deinit(ctx.arena);
    try fws.ensureTotalCapacity(ctx.arena, paths.items.len);

    var any_error = false;
    for (paths.items) |p| {
        const f = if (append)
            cwd.openFile(ctx.io, p, .{ .mode = .read_write }) catch |e| switch (e) {
                error.FileNotFound => cwd.createFile(ctx.io, p, .{}) catch |ce| {
                    ctx.err("cannot create '{s}': {s}", .{ p, @errorName(ce) });
                    any_error = true;
                    continue;
                },
                else => {
                    ctx.err("cannot open '{s}': {s}", .{ p, @errorName(e) });
                    any_error = true;
                    continue;
                },
            }
        else
            cwd.createFile(ctx.io, p, .{}) catch |e| {
                ctx.err("cannot create '{s}': {s}", .{ p, @errorName(e) });
                any_error = true;
                continue;
            };
        try files.append(ctx.arena, f);
        bufs.appendAssumeCapacity(undefined);
        const buf_ptr: *[8 * 1024]u8 = &bufs.items[bufs.items.len - 1];
        fws.appendAssumeCapacity(.initStreaming(f, ctx.io, buf_ptr));
        try writers.append(ctx.arena, &fws.items[fws.items.len - 1]);
    }

    // Stream stdin to stdout AND each output file.
    while (true) {
        const slice = ctx.stdin.peek(8 * 1024) catch |e| switch (e) {
            error.EndOfStream => {
                const buffered = ctx.stdin.buffered();
                if (buffered.len == 0) break;
                try ctx.stdout.writeAll(buffered);
                for (writers.items) |w| try w.interface.writeAll(buffered);
                ctx.stdin.toss(buffered.len);
                break;
            },
            else => return e,
        };
        if (slice.len == 0) break;
        try ctx.stdout.writeAll(slice);
        for (writers.items) |w| try w.interface.writeAll(slice);
        ctx.stdin.toss(slice.len);
    }

    for (writers.items) |w| w.interface.flush() catch {};
    return if (any_error) 1 else 0;
}
