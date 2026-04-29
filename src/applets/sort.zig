const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "sort";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: sort [OPTION]... [FILE]...
    \\
    \\Sort lines from each FILE to standard output.
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\  -r, --reverse        reverse the result of comparisons
    \\  -n, --numeric-sort   compare according to string numerical value
    \\  -u, --unique         output only the first of an equal run
    \\  -f, --ignore-case    fold lowercase to uppercase characters
    \\  -t, --field-separator=SEP  use SEP instead of run of blanks
    \\  -k, --key=POS        sort via a key starting at POS (1-based)
    \\      --help           display this help and exit
    \\
;

const Options = struct {
    reverse: bool = false,
    numeric: bool = false,
    unique: bool = false,
    ignore_case: bool = false,
    sep: ?u8 = null,
    key: ?usize = null,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var opts: Options = .{};
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--reverse")) {
            opts.reverse = true;
        } else if (std.mem.eql(u8, a, "--numeric-sort")) {
            opts.numeric = true;
        } else if (std.mem.eql(u8, a, "--unique")) {
            opts.unique = true;
        } else if (std.mem.eql(u8, a, "--ignore-case")) {
            opts.ignore_case = true;
        } else if (std.mem.eql(u8, a, "-t")) {
            i += 1;
            if (i >= args.len or args[i].len == 0) return 2;
            opts.sep = args[i][0];
        } else if (std.mem.startsWith(u8, a, "--field-separator=")) {
            const v = a["--field-separator=".len..];
            if (v.len > 0) opts.sep = v[0];
        } else if (std.mem.eql(u8, a, "-k")) {
            i += 1;
            if (i >= args.len) return 2;
            opts.key = std.fmt.parseInt(usize, std.mem.sliceTo(args[i], ','), 10) catch null;
        } else if (std.mem.startsWith(u8, a, "--key=")) {
            opts.key = std.fmt.parseInt(usize, std.mem.sliceTo(a["--key=".len..], ','), 10) catch null;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'r' => opts.reverse = true,
                'n' => opts.numeric = true,
                'u' => opts.unique = true,
                'f' => opts.ignore_case = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.arena);

    if (operands.items.len == 0) {
        try slurpInto(ctx, ctx.stdin, &lines);
    } else for (operands.items) |path| {
        if (std.mem.eql(u8, path, "-")) {
            try slurpInto(ctx, ctx.stdin, &lines);
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
        try slurpInto(ctx, &fr.interface, &lines);
    }

    const SortCtx = struct {
        opts: Options,
        fn lessThan(s: @This(), a: []const u8, b: []const u8) bool {
            const ka = keyOf(a, s.opts);
            const kb = keyOf(b, s.opts);
            const result = if (s.opts.numeric)
                numericLess(ka, kb)
            else if (s.opts.ignore_case)
                caseInsensitiveLess(ka, kb)
            else
                std.mem.lessThan(u8, ka, kb);
            return if (s.opts.reverse) !result and !std.mem.eql(u8, ka, kb) else result;
        }
    };
    std.mem.sort([]const u8, lines.items, SortCtx{ .opts = opts }, SortCtx.lessThan);

    var prev: ?[]const u8 = null;
    for (lines.items) |line| {
        if (opts.unique) {
            if (prev) |p| if (std.mem.eql(u8, p, line)) continue;
            prev = line;
        }
        try ctx.stdout.writeAll(line);
        try ctx.stdout.writeByte('\n');
    }
    return 0;
}

fn slurpInto(ctx: *Context, r: *std.Io.Reader, out: *std.ArrayList([]const u8)) !void {
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};
    const owned = try data.toOwnedSlice(ctx.arena);
    var it = std.mem.splitScalar(u8, owned, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and out.items.len > 0) continue; // skip the trailing empty after last \n
        try out.append(ctx.arena, line);
    }
}

fn keyOf(line: []const u8, opts: Options) []const u8 {
    const k = opts.key orelse return line;
    if (k == 0) return line;
    if (opts.sep) |sep| {
        var idx: usize = 0;
        var pos: usize = 0;
        var field: usize = 1;
        while (pos < line.len) : (pos += 1) {
            if (line[pos] == sep) {
                if (field == k) return line[idx..pos];
                idx = pos + 1;
                field += 1;
            }
        }
        if (field == k) return line[idx..];
        return line;
    }
    // Default whitespace separator — first non-blank field.
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var idx: usize = 0;
    while (it.next()) |f| : (idx += 1) {
        if (idx + 1 == k) return f;
    }
    return line;
}

fn numericLess(a: []const u8, b: []const u8) bool {
    const an = std.fmt.parseFloat(f64, std.mem.trim(u8, a, " \t")) catch 0;
    const bn = std.fmt.parseFloat(f64, std.mem.trim(u8, b, " \t")) catch 0;
    return an < bn;
}

fn caseInsensitiveLess(a: []const u8, b: []const u8) bool {
    const min_len = @min(a.len, b.len);
    var i: usize = 0;
    while (i < min_len) : (i += 1) {
        const ca = std.ascii.toLower(a[i]);
        const cb = std.ascii.toLower(b[i]);
        if (ca < cb) return true;
        if (ca > cb) return false;
    }
    return a.len < b.len;
}
