const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "ls";
pub const aliases: []const []const u8 = if (builtin.os.tag == .windows) &.{"dir"} else &.{};
pub const help: []const u8 =
    \\Usage: ls [OPTION]... [FILE]...
    \\
    \\List information about the FILEs (the current directory by default).
    \\
    \\  -a, --all          do not ignore entries starting with .
    \\  -A, --almost-all   like -a, but don't show . and ..
    \\  -l                 use a long listing format
    \\  -h                 with -l, print sizes in human-readable form (KB, MB)
    \\  -F                 append indicator (one of */=>@|) to entries
    \\  -1                 list one file per line
    \\  -r, --reverse      reverse order while sorting
    \\  -S                 sort by file size, largest first
    \\  -t                 sort by modification time, newest first
    \\      --help         display this help and exit
    \\
;

const Mode = enum { columns, long, one_per_line };
const Sort = enum { name, size, mtime };

const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
    size: u64,
    mtime_ns: i128,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var show_hidden = false;
    var show_dot_dotdot = false;
    var mode: Mode = .one_per_line;
    var human = false;
    var indicator = false;
    var sort: Sort = .name;
    var reverse = false;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--all")) {
            show_hidden = true;
            show_dot_dotdot = true;
        } else if (std.mem.eql(u8, a, "--almost-all")) {
            show_hidden = true;
        } else if (std.mem.eql(u8, a, "--reverse")) {
            reverse = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'a' => {
                    show_hidden = true;
                    show_dot_dotdot = true;
                },
                'A' => show_hidden = true,
                'l' => mode = .long,
                'h' => human = true,
                'F' => indicator = true,
                '1' => mode = .one_per_line,
                'r' => reverse = true,
                'S' => sort = .size,
                't' => sort = .mtime,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try operands.append(ctx.arena, a);
        }
    }

    if (operands.items.len == 0) try operands.append(ctx.arena, ".");

    var any_error = false;
    const cwd = std.Io.Dir.cwd();
    const multiple = operands.items.len > 1;

    for (operands.items, 0..) |path, idx| {
        if (multiple) {
            if (idx > 0) try ctx.stdout.writeByte('\n');
            try ctx.stdout.print("{s}:\n", .{path});
        }

        // Try to open as a directory; fall back to single-file display.
        var dir = cwd.openDir(ctx.io, path, .{ .iterate = true }) catch |e| switch (e) {
            error.NotDir => {
                // Single file listing.
                const file = cwd.openFile(ctx.io, path, .{}) catch |fe| {
                    ctx.err("cannot access '{s}': {s}", .{ path, @errorName(fe) });
                    any_error = true;
                    continue;
                };
                defer file.close(ctx.io);
                const st = file.stat(ctx.io) catch |se| {
                    ctx.err("cannot stat '{s}': {s}", .{ path, @errorName(se) });
                    any_error = true;
                    continue;
                };
                var single = [_]Entry{.{ .name = path, .kind = st.kind, .size = st.size, .mtime_ns = st.mtime.nanoseconds }};
                try emit(ctx, &single, mode, human, indicator);
                continue;
            },
            else => {
                ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
                any_error = true;
                continue;
            },
        };
        defer dir.close(ctx.io);

        var entries: std.ArrayList(Entry) = .empty;
        var it = dir.iterate();
        while (try it.next(ctx.io)) |entry| {
            if (!show_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
            if (!show_dot_dotdot and (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, ".."))) continue;
            const owned = try ctx.arena.dupe(u8, entry.name);
            // Stat each entry for size/mtime if needed (long, sort).
            var size: u64 = 0;
            var mtime_ns: i128 = 0;
            if (mode == .long or sort != .name) {
                if (dir.openFile(ctx.io, owned, .{})) |f| {
                    defer f.close(ctx.io);
                    if (f.stat(ctx.io)) |st| {
                        size = st.size;
                        mtime_ns = st.mtime.nanoseconds;
                    } else |_| {}
                } else |_| {}
            }
            try entries.append(ctx.arena, .{
                .name = owned,
                .kind = entry.kind,
                .size = size,
                .mtime_ns = mtime_ns,
            });
        }

        // Sort.
        const SortCtx = struct {
            sort: Sort,
            reverse: bool,
            fn lessThan(s: @This(), a: Entry, b: Entry) bool {
                const result = switch (s.sort) {
                    .name => std.mem.lessThan(u8, a.name, b.name),
                    .size => a.size > b.size, // largest first
                    .mtime => a.mtime_ns > b.mtime_ns, // newest first
                };
                return if (s.reverse) !result else result;
            }
        };
        std.mem.sort(Entry, entries.items, SortCtx{ .sort = sort, .reverse = reverse }, SortCtx.lessThan);

        try emit(ctx, entries.items, mode, human, indicator);
    }
    return if (any_error) 1 else 0;
}

fn emit(ctx: *Context, entries: []const Entry, mode: Mode, human: bool, indicator: bool) !void {
    switch (mode) {
        .one_per_line, .columns => {
            for (entries) |e| {
                try ctx.stdout.writeAll(e.name);
                if (indicator) try writeIndicator(ctx.stdout, e.kind);
                try ctx.stdout.writeByte('\n');
            }
        },
        .long => {
            for (entries) |e| {
                try ctx.stdout.print("{c}{s} ", .{ kindChar(e.kind), "rwxrwxrwx" });
                if (human) {
                    try writeHuman(ctx.stdout, e.size);
                } else {
                    try ctx.stdout.print("{d:>10}", .{e.size});
                }
                try ctx.stdout.print(" {s}", .{e.name});
                if (indicator) try writeIndicator(ctx.stdout, e.kind);
                try ctx.stdout.writeByte('\n');
            }
        },
    }
}

fn kindChar(k: std.Io.File.Kind) u8 {
    return switch (k) {
        .directory => 'd',
        .sym_link => 'l',
        .character_device => 'c',
        .block_device => 'b',
        .named_pipe => 'p',
        .unix_domain_socket => 's',
        else => '-',
    };
}

fn writeIndicator(w: *std.Io.Writer, k: std.Io.File.Kind) !void {
    const c: ?u8 = switch (k) {
        .directory => '/',
        .sym_link => '@',
        .named_pipe => '|',
        .unix_domain_socket => '=',
        else => null,
    };
    if (c) |ch| try w.writeByte(ch);
}

fn writeHuman(w: *std.Io.Writer, n: u64) !void {
    const units = [_][]const u8{ "B", "K", "M", "G", "T" };
    var v: f64 = @floatFromInt(n);
    var i: usize = 0;
    while (v >= 1024.0 and i + 1 < units.len) : (i += 1) v /= 1024.0;
    if (i == 0) {
        try w.print("{d:>5}", .{n});
    } else {
        try w.print("{d:>4.1}{s}", .{ v, units[i] });
    }
}
