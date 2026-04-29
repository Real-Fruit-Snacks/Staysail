const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "basename";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: basename NAME [SUFFIX]
    \\       basename OPTION... NAME...
    \\
    \\Print NAME with any leading directory components removed.
    \\If specified, also remove a trailing SUFFIX.
    \\
    \\  -a, --multiple       support multiple arguments and treat each as a NAME
    \\  -s, --suffix=SUFFIX  remove a trailing SUFFIX
    \\  -z, --zero           end each output line with NUL, not newline
    \\      --help           display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var multiple = false;
    var suffix: ?[]const u8 = null;
    var zero = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "--multiple")) {
            multiple = true;
        } else if (std.mem.eql(u8, a, "-z") or std.mem.eql(u8, a, "--zero")) {
            zero = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) {
                ctx.usage("option requires an argument -- 's'", .{});
                return 2;
            }
            suffix = args[i];
            multiple = true;
        } else if (std.mem.startsWith(u8, a, "--suffix=")) {
            suffix = a["--suffix=".len..];
            multiple = true;
        } else if (std.mem.eql(u8, a, "--")) {
            i += 1;
            while (i < args.len) : (i += 1) try operands.append(ctx.arena, args[i]);
            break;
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }

    const sep: u8 = if (zero) 0 else '\n';

    if (!multiple and operands.items.len == 2) {
        const eff_suffix = operands.items[1];
        try emit(ctx, operands.items[0], eff_suffix, sep);
        return 0;
    }
    if (!multiple and operands.items.len > 2) {
        ctx.usage("extra operand '{s}'", .{operands.items[2]});
        return 2;
    }

    for (operands.items) |op| try emit(ctx, op, suffix orelse "", sep);
    return 0;
}

fn emit(ctx: *Context, path: []const u8, suffix: []const u8, sep: u8) !void {
    var base = std.fs.path.basename(path);
    if (suffix.len > 0 and base.len > suffix.len and std.mem.endsWith(u8, base, suffix)) {
        base = base[0 .. base.len - suffix.len];
    }
    try ctx.stdout.writeAll(base);
    try ctx.stdout.writeByte(sep);
}
