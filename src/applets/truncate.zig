const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "truncate";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: truncate -s SIZE FILE...
    \\
    \\Shrink or extend the size of each FILE to the specified SIZE.
    \\A FILE that does not exist is created.
    \\
    \\  -s, --size=SIZE   set or adjust file size by SIZE bytes
    \\                    SIZE may be suffixed by K, M, G (bytes)
    \\                    SIZE may be prefixed by + or - to adjust relative
    \\  -c, --no-create   do not create files
    \\      --help        display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var size_spec: ?[]const u8 = null;
    var no_create = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 's'", .{});
                return 2;
            }
            size_spec = args[i];
        } else if (std.mem.startsWith(u8, a, "--size=")) {
            size_spec = a["--size=".len..];
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--no-create")) {
            no_create = true;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (size_spec == null) {
        ctx.usage("you must specify -s SIZE", .{});
        return 2;
    }
    if (operands.items.len == 0) {
        ctx.usage("missing file operand", .{});
        return 2;
    }

    const adj = parseSizeSpec(size_spec.?) orelse {
        ctx.err("invalid size: '{s}'", .{size_spec.?});
        return 1;
    };

    const cwd = std.Io.Dir.cwd();
    var any_error = false;

    for (operands.items) |path| {
        const open_result = cwd.openFile(ctx.io, path, .{ .mode = .read_write });
        const f: std.Io.File = open_result catch |e| switch (e) {
            error.FileNotFound => blk: {
                if (no_create) continue;
                break :blk cwd.createFile(ctx.io, path, .{ .read = true }) catch |ce| {
                    ctx.err("cannot create '{s}': {s}", .{ path, @errorName(ce) });
                    any_error = true;
                    continue;
                };
            },
            else => {
                ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            },
        };
        defer f.close(ctx.io);

        const new_len: u64 = switch (adj.op) {
            .absolute => adj.value,
            .add => blk: {
                const cur = f.length(ctx.io) catch 0;
                break :blk cur +| adj.value;
            },
            .sub => blk: {
                const cur = f.length(ctx.io) catch 0;
                break :blk if (cur > adj.value) cur - adj.value else 0;
            },
        };
        f.setLength(ctx.io, new_len) catch |e| {
            ctx.err("cannot truncate '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
        };
    }
    return if (any_error) 1 else 0;
}

const Adjustment = struct {
    op: enum { absolute, add, sub },
    value: u64,
};

fn parseSizeSpec(s: []const u8) ?Adjustment {
    if (s.len == 0) return null;
    var op: @TypeOf(@as(Adjustment, undefined).op) = .absolute;
    var rest = s;
    if (rest[0] == '+') {
        op = .add;
        rest = rest[1..];
    } else if (rest[0] == '-') {
        op = .sub;
        rest = rest[1..];
    }
    if (rest.len == 0) return null;
    const last = rest[rest.len - 1];
    const mult: u64 = switch (last) {
        'K', 'k' => 1024,
        'M', 'm' => 1024 * 1024,
        'G', 'g' => 1024 * 1024 * 1024,
        '0'...'9' => 1,
        else => return null,
    };
    const num_str = if (mult == 1) rest else rest[0 .. rest.len - 1];
    const n = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return .{ .op = op, .value = n *| mult };
}
