const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "diff";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: diff [OPTION]... FILE1 FILE2
    \\
    \\Compare FILE1 and FILE2 line by line. Output uses unified diff style
    \\with -u (default) or "normal" diff style without -u.
    \\
    \\  -u, --unified[=N]   output N lines of context (default 3, alias for -u3)
    \\  -q, --brief         report only when files differ
    \\  -s, --report-identical-files  report when files are identical
    \\      --help          display this help and exit
    \\
    \\Exit status: 0 = identical, 1 = differ, 2 = trouble.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var brief = false;
    var report_identical = false;
    var unified = true;
    var context_lines: usize = 3;
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-u") or std.mem.eql(u8, a, "--unified")) {
            unified = true;
        } else if (std.mem.startsWith(u8, a, "-u") and a.len > 2) {
            unified = true;
            context_lines = std.fmt.parseInt(usize, a[2..], 10) catch 3;
        } else if (std.mem.startsWith(u8, a, "--unified=")) {
            unified = true;
            context_lines = std.fmt.parseInt(usize, a["--unified=".len..], 10) catch 3;
        } else if (std.mem.eql(u8, a, "-q") or std.mem.eql(u8, a, "--brief")) {
            brief = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--report-identical-files")) {
            report_identical = true;
        } else {
            try paths.append(ctx.arena, a);
        }
    }
    if (paths.items.len != 2) {
        ctx.usage("expected exactly 2 file arguments", .{});
        return 2;
    }

    const a_lines = try slurpLines(ctx, paths.items[0]) orelse return 2;
    const b_lines = try slurpLines(ctx, paths.items[1]) orelse return 2;

    if (linesEqual(a_lines, b_lines)) {
        if (report_identical) try ctx.stdout.print("Files {s} and {s} are identical\n", .{ paths.items[0], paths.items[1] });
        return 0;
    }
    if (brief) {
        try ctx.stdout.print("Files {s} and {s} differ\n", .{ paths.items[0], paths.items[1] });
        return 1;
    }

    if (unified) {
        try emitUnified(ctx, paths.items[0], paths.items[1], a_lines, b_lines, context_lines);
    } else {
        try emitNormal(ctx, a_lines, b_lines);
    }
    return 1;
}

fn slurpLines(ctx: *Context, path: []const u8) !?[]const []const u8 {
    var data: std.ArrayList(u8) = .empty;
    if (std.mem.eql(u8, path, "-")) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &data) catch {};
    } else {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return null;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
    }
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| try lines.append(ctx.arena, line);
    if (lines.items.len > 0 and lines.items[lines.items.len - 1].len == 0) _ = lines.pop();
    return try lines.toOwnedSlice(ctx.arena);
}

fn linesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (!std.mem.eql(u8, x, y)) return false;
    return true;
}

const Op = enum { equal, insert, delete };
const Edit = struct { op: Op, a_idx: usize, b_idx: usize };

fn computeDiff(arena: std.mem.Allocator, a: []const []const u8, b: []const []const u8) ![]const Edit {
    // Myers-ish via classic LCS DP. O(NM) memory; fine for Phase 4.
    const n = a.len;
    const m = b.len;
    const dp = try arena.alloc(usize, (n + 1) * (m + 1));
    for (dp) |*v| v.* = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var j: usize = 0;
        while (j < m) : (j += 1) {
            if (std.mem.eql(u8, a[i], b[j])) {
                dp[(i + 1) * (m + 1) + (j + 1)] = dp[i * (m + 1) + j] + 1;
            } else {
                dp[(i + 1) * (m + 1) + (j + 1)] = @max(dp[i * (m + 1) + (j + 1)], dp[(i + 1) * (m + 1) + j]);
            }
        }
    }
    var edits: std.ArrayList(Edit) = .empty;
    var ii = n;
    var jj = m;
    while (ii > 0 or jj > 0) {
        if (ii > 0 and jj > 0 and std.mem.eql(u8, a[ii - 1], b[jj - 1])) {
            try edits.append(arena, .{ .op = .equal, .a_idx = ii - 1, .b_idx = jj - 1 });
            ii -= 1;
            jj -= 1;
        } else if (jj > 0 and (ii == 0 or dp[ii * (m + 1) + (jj - 1)] >= dp[(ii - 1) * (m + 1) + jj])) {
            try edits.append(arena, .{ .op = .insert, .a_idx = ii, .b_idx = jj - 1 });
            jj -= 1;
        } else {
            try edits.append(arena, .{ .op = .delete, .a_idx = ii - 1, .b_idx = jj });
            ii -= 1;
        }
    }
    std.mem.reverse(Edit, edits.items);
    return edits.toOwnedSlice(arena);
}

fn emitUnified(ctx: *Context, path_a: []const u8, path_b: []const u8, a: []const []const u8, b: []const []const u8, ctx_lines: usize) !void {
    const edits = try computeDiff(ctx.arena, a, b);

    try ctx.stdout.print("--- {s}\n+++ {s}\n", .{ path_a, path_b });

    // Group consecutive non-equal edits with surrounding context.
    var i: usize = 0;
    while (i < edits.len) {
        if (edits[i].op == .equal) {
            i += 1;
            continue;
        }
        // Find end of this hunk (non-equal run).
        var hunk_end = i;
        while (hunk_end < edits.len and !isContextBoundary(edits, hunk_end, ctx_lines)) hunk_end += 1;

        // Include leading context.
        const start = if (i >= ctx_lines) i - ctx_lines else 0;
        const end = @min(hunk_end + ctx_lines, edits.len);

        // Compute hunk header line numbers.
        var a_start: usize = std.math.maxInt(usize);
        var a_count: usize = 0;
        var b_start: usize = std.math.maxInt(usize);
        var b_count: usize = 0;
        for (edits[start..end]) |e| {
            if (e.op != .insert) {
                if (a_start == std.math.maxInt(usize)) a_start = e.a_idx;
                a_count += 1;
            }
            if (e.op != .delete) {
                if (b_start == std.math.maxInt(usize)) b_start = e.b_idx;
                b_count += 1;
            }
        }
        if (a_start == std.math.maxInt(usize)) a_start = 0;
        if (b_start == std.math.maxInt(usize)) b_start = 0;
        try ctx.stdout.print("@@ -{d},{d} +{d},{d} @@\n", .{ a_start + 1, a_count, b_start + 1, b_count });

        for (edits[start..end]) |e| switch (e.op) {
            .equal => try ctx.stdout.print(" {s}\n", .{a[e.a_idx]}),
            .delete => try ctx.stdout.print("-{s}\n", .{a[e.a_idx]}),
            .insert => try ctx.stdout.print("+{s}\n", .{b[e.b_idx]}),
        };

        i = end;
    }
}

fn isContextBoundary(edits: []const Edit, i: usize, ctx_lines: usize) bool {
    // Boundary if next ctx_lines edits are all .equal.
    if (edits[i].op != .equal) return false;
    var k: usize = 0;
    while (k < ctx_lines and i + k < edits.len) : (k += 1) {
        if (edits[i + k].op != .equal) return false;
    }
    return true;
}

fn emitNormal(ctx: *Context, a: []const []const u8, b: []const []const u8) !void {
    const edits = try computeDiff(ctx.arena, a, b);
    for (edits) |e| switch (e.op) {
        .equal => {},
        .delete => try ctx.stdout.print("< {s}\n", .{a[e.a_idx]}),
        .insert => try ctx.stdout.print("> {s}\n", .{b[e.b_idx]}),
    };
}
