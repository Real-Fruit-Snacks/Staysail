const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "dirname";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: dirname [OPTION] NAME...
    \\
    \\Output each NAME with its last non-slash component and trailing slashes
    \\removed; if NAME contains no slashes, output '.' (meaning the current
    \\directory).
    \\
    \\  -z, --zero     end each output line with NUL, not newline
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var zero = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-z") or std.mem.eql(u8, a, "--zero")) {
            zero = true;
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
    for (operands.items) |path| {
        const dir = std.fs.path.dirname(path) orelse ".";
        const out = if (dir.len == 0) "." else dir;
        try ctx.stdout.writeAll(out);
        try ctx.stdout.writeByte(sep);
    }
    return 0;
}
