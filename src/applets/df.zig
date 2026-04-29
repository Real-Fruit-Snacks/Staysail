const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "df";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: df [OPTION]... [FILE]...
    \\
    \\Show information about the file system on which each FILE resides,
    \\or all file systems by default.
    \\
    \\  -h, --human-readable   print sizes in powers of 1024 (e.g., 1023M)
    \\  -k                     print sizes in 1K blocks (default)
    \\      --help             display this help and exit
    \\
    \\Note: this is a stub for Phase 3. Full statvfs/GetDiskFreeSpaceExW wiring
    \\is on the Phase 4 list. For now, prints a placeholder showing the path.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--human-readable")) {
            // Accepted; output is currently a placeholder either way.
        } else if (std.mem.eql(u8, a, "-k")) {
            // Default. Accepted.
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len == 0) try operands.append(ctx.arena, ".");

    try ctx.stdout.writeAll("Filesystem     1K-blocks     Used Available Use% Mounted on\n");
    for (operands.items) |path| {
        try ctx.stdout.print("(unknown)        (n/a)    (n/a)    (n/a)  --% {s}\n", .{path});
    }
    if (builtin.os.tag == .windows) {
        try ctx.stderr.writeAll("df: full disk-usage reporting not yet wired (Phase 4)\n");
    } else {
        try ctx.stderr.writeAll("df: full statvfs reporting not yet wired (Phase 4)\n");
    }
    return 0;
}
