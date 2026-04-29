const std = @import("std");
const Context = @import("../common/context.zig");
const regex = @import("../common/regex.zig");

pub const name: []const u8 = "grep";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: grep [OPTION]... PATTERN [FILE]...
    \\
    \\Search for PATTERN in each FILE. With no FILE, read standard input.
    \\
    \\  -i, --ignore-case      ignore case distinctions
    \\  -v, --invert-match     select non-matching lines
    \\  -n, --line-number      prefix each line with its line number
    \\  -c, --count            print only a count of matching lines per file
    \\  -H, --with-filename    print file name with matches
    \\  -h, --no-filename      suppress file name on output
    \\  -F, --fixed-strings    interpret PATTERN as fixed strings (no regex)
    \\  -E, --extended-regexp  interpret PATTERN as POSIX ERE (default)
    \\      --help             display this help and exit
    \\
    \\Phase 5 ships ERE: . [..] ^ $ * + ? {n,m} (..) | \\d \\w \\s and friends.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var ignore_case = false;
    var invert = false;
    var line_no = false;
    var count_only = false;
    var with_filename: ?bool = null;
    var fixed = false;
    var pattern: ?[]const u8 = null;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--ignore-case")) {
            ignore_case = true;
        } else if (std.mem.eql(u8, a, "--invert-match")) {
            invert = true;
        } else if (std.mem.eql(u8, a, "--line-number")) {
            line_no = true;
        } else if (std.mem.eql(u8, a, "--count")) {
            count_only = true;
        } else if (std.mem.eql(u8, a, "--with-filename")) {
            with_filename = true;
        } else if (std.mem.eql(u8, a, "--no-filename")) {
            with_filename = false;
        } else if (std.mem.eql(u8, a, "--fixed-strings")) {
            fixed = true;
        } else if (std.mem.eql(u8, a, "--extended-regexp")) {
            fixed = false;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'i' => ignore_case = true,
                'v' => invert = true,
                'n' => line_no = true,
                'c' => count_only = true,
                'H' => with_filename = true,
                'h' => with_filename = false,
                'F' => fixed = true,
                'E' => fixed = false,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            if (pattern == null) {
                pattern = a;
            } else {
                try operands.append(ctx.arena, a);
            }
        }
    }

    if (pattern == null) {
        ctx.usage("missing pattern", .{});
        return 2;
    }

    if (with_filename == null) with_filename = operands.items.len > 1;

    const re = regex.compile(ctx.arena, pattern.?, .{
        .case_insensitive = ignore_case,
        .literal = fixed,
    }) catch |e| {
        ctx.err("invalid pattern '{s}': {s}", .{ pattern.?, @errorName(e) });
        return 2;
    };

    var any_match = false;
    var any_error = false;
    if (operands.items.len == 0) {
        const matched = try search(ctx, &re, ctx.stdin, null, invert, line_no, count_only, false);
        if (matched) any_match = true;
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            const matched = try search(ctx, &re, ctx.stdin, "(standard input)", invert, line_no, count_only, with_filename.?);
            if (matched) any_match = true;
            continue;
        }
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("{s}: {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        const matched = try search(ctx, &re, &fr.interface, path, invert, line_no, count_only, with_filename.?);
        if (matched) any_match = true;
    }
    if (any_error) return 2;
    return if (any_match) 0 else 1;
}

fn search(
    ctx: *Context,
    re: *const regex.Pattern,
    r: *std.Io.Reader,
    path: ?[]const u8,
    invert: bool,
    line_no: bool,
    count_only: bool,
    with_filename: bool,
) !bool {
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};

    var ln: usize = 0;
    var match_count: usize = 0;
    var any_match = false;
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        ln += 1;
        const is_match = re.matches(line);
        const want = if (invert) !is_match else is_match;
        if (!want) continue;
        any_match = true;
        match_count += 1;
        if (count_only) continue;
        if (with_filename and path != null) try ctx.stdout.print("{s}:", .{path.?});
        if (line_no) try ctx.stdout.print("{d}:", .{ln});
        try ctx.stdout.writeAll(line);
        try ctx.stdout.writeByte('\n');
    }
    if (count_only) {
        if (with_filename and path != null) try ctx.stdout.print("{s}:", .{path.?});
        try ctx.stdout.print("{d}\n", .{match_count});
    }
    return any_match;
}
