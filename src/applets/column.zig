const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "column";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: column [OPTION]... [FILE]...
    \\
    \\Format input into multiple columns aligned in rows or as a table.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -t, --table          create a table from whitespace-separated fields
    \\  -s, --separator=STR  in -t mode, split on each char of STR (default: \\t and space)
    \\  -o, --output-separator=STR  output separator for -t (default: two spaces)
    \\      --help           display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var table = false;
    var sep_chars: []const u8 = " \t";
    var output_sep: []const u8 = "  ";
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-t") or std.mem.eql(u8, a, "--table")) {
            table = true;
        } else if (std.mem.eql(u8, a, "-s")) {
            i += 1;
            if (i >= args.len) return 2;
            sep_chars = args[i];
        } else if (std.mem.startsWith(u8, a, "--separator=")) {
            sep_chars = a["--separator=".len..];
        } else if (std.mem.eql(u8, a, "-o")) {
            i += 1;
            if (i >= args.len) return 2;
            output_sep = args[i];
        } else if (std.mem.startsWith(u8, a, "--output-separator=")) {
            output_sep = a["--output-separator=".len..];
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(ctx.arena);
    if (operands.items.len == 0) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
            continue;
        }
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }

    if (!table) {
        // Without -t we just emit input verbatim. Phase 3 may add filling/columnar layout.
        try ctx.stdout.writeAll(data.items);
        return 0;
    }

    // Parse rows + columns.
    var rows: std.ArrayList([]const []const u8) = .empty;
    defer rows.deinit(ctx.arena);

    var line_it = std.mem.splitScalar(u8, data.items, '\n');
    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        var fields: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, line, sep_chars);
        while (it.next()) |f| try fields.append(ctx.arena, f);
        try rows.append(ctx.arena, try fields.toOwnedSlice(ctx.arena));
    }

    // Column widths.
    var col_widths: std.ArrayList(usize) = .empty;
    defer col_widths.deinit(ctx.arena);
    for (rows.items) |row| {
        for (row, 0..) |field, idx| {
            if (idx >= col_widths.items.len) try col_widths.append(ctx.arena, 0);
            if (field.len > col_widths.items[idx]) col_widths.items[idx] = field.len;
        }
    }

    // Emit.
    for (rows.items) |row| {
        for (row, 0..) |field, idx| {
            if (idx > 0) try ctx.stdout.writeAll(output_sep);
            try ctx.stdout.writeAll(field);
            if (idx + 1 < row.len) {
                const pad = col_widths.items[idx] - field.len;
                try ctx.stdout.splatByteAll(' ', pad);
            }
        }
        try ctx.stdout.writeByte('\n');
    }
    return 0;
}
