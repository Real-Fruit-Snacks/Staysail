const std = @import("std");
const Context = @import("../common/context.zig");
const regex = @import("../common/regex.zig");

pub const name: []const u8 = "sed";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: sed [OPTION]... SCRIPT [FILE]...
    \\
    \\A stream editor for filtering and transforming text.
    \\
    \\  -n, --quiet         suppress automatic printing of pattern space
    \\  -e SCRIPT           add SCRIPT to commands to execute
    \\  -i                  edit files in place (no backup)
    \\  -E, -r              use extended regular expressions (default in v0.5.0)
    \\      --help          display this help and exit
    \\
    \\Supported commands:
    \\  s/regex/repl/[g][i] substitute (regex; flags: g=all, i=case-insens.)
    \\  d                   delete the line
    \\  p                   print the line
    \\  q                   quit immediately
    \\  =                   print line number
    \\  N[,M]               address ranges (literal line numbers or /regex/)
    \\
    \\Phase 5: regex via the staysail engine (see grep --help). Backreferences
    \\\\& and \\1..\\9 in the replacement are deferred to v0.6.0.
    \\
;

const Cmd = struct {
    addr_start: ?usize = null, // 1-based; null = match every line
    addr_end: ?usize = null,
    op: enum { sub, delete, print, quit, line_num } = .print,
    sub_re: ?regex.Pattern = null,
    sub_new: []const u8 = "",
    sub_global: bool = false,
    sub_ic: bool = false,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var quiet = false;
    var in_place = false;
    var scripts: std.ArrayList([]const u8) = .empty;
    defer scripts.deinit(ctx.arena);
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "--silent")) {
            quiet = true;
        } else if (std.mem.eql(u8, a, "-i")) {
            in_place = true;
        } else if (std.mem.eql(u8, a, "-e")) {
            i += 1;
            if (i >= args.len) return 2;
            try scripts.append(ctx.arena, args[i]);
        } else {
            if (scripts.items.len == 0) {
                try scripts.append(ctx.arena, a);
            } else {
                try operands.append(ctx.arena, a);
            }
        }
    }

    if (scripts.items.len == 0) {
        ctx.usage("missing script", .{});
        return 2;
    }

    var commands: std.ArrayList(Cmd) = .empty;
    defer commands.deinit(ctx.arena);
    for (scripts.items) |script| {
        try parseScript(ctx, script, &commands);
    }

    var any_error = false;
    if (operands.items.len == 0) {
        try processReader(ctx, ctx.stdin, ctx.stdout, commands.items, quiet);
    } else for (operands.items) |path| {
        if (in_place) {
            try processInPlace(ctx, path, commands.items, quiet);
            continue;
        }
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            any_error = true;
            continue;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        try processReader(ctx, &fr.interface, ctx.stdout, commands.items, quiet);
    }
    return if (any_error) 1 else 0;
}

fn parseScript(ctx: *Context, script: []const u8, out: *std.ArrayList(Cmd)) !void {
    // Split on ';' or newline (top-level only — no nested handling).
    var it = std.mem.splitAny(u8, script, ";\n");
    while (it.next()) |raw| {
        const piece = std.mem.trim(u8, raw, " \t");
        if (piece.len == 0) continue;
        var cmd: Cmd = .{};
        var rest = piece;

        // Optional address (single number, or N,M).
        if (rest.len > 0 and rest[0] >= '0' and rest[0] <= '9') {
            var k: usize = 0;
            while (k < rest.len and rest[k] >= '0' and rest[k] <= '9') k += 1;
            cmd.addr_start = std.fmt.parseInt(usize, rest[0..k], 10) catch null;
            rest = rest[k..];
            if (rest.len > 0 and rest[0] == ',') {
                rest = rest[1..];
                k = 0;
                while (k < rest.len and rest[k] >= '0' and rest[k] <= '9') k += 1;
                cmd.addr_end = std.fmt.parseInt(usize, rest[0..k], 10) catch null;
                rest = rest[k..];
            }
        }

        if (rest.len == 0) continue;
        const op_char = rest[0];
        switch (op_char) {
            's' => {
                if (rest.len < 4) {
                    ctx.err("invalid s command: '{s}'", .{piece});
                    return;
                }
                const sep = rest[1];
                const after = rest[2..];
                const slash1 = std.mem.indexOfScalar(u8, after, sep) orelse {
                    ctx.err("malformed s command", .{});
                    return;
                };
                const old_pat = after[0..slash1];
                const after_old = after[slash1 + 1 ..];
                const slash2 = std.mem.indexOfScalar(u8, after_old, sep) orelse after_old.len;
                const new_pat = after_old[0..slash2];
                const flags = if (slash2 < after_old.len) after_old[slash2 + 1 ..] else "";
                cmd.op = .sub;
                cmd.sub_new = new_pat;
                for (flags) |c| switch (c) {
                    'g' => cmd.sub_global = true,
                    'i', 'I' => cmd.sub_ic = true,
                    else => {},
                };
                cmd.sub_re = regex.compile(ctx.arena, old_pat, .{
                    .case_insensitive = cmd.sub_ic,
                }) catch {
                    ctx.err("invalid regex '{s}'", .{old_pat});
                    return;
                };
            },
            'd' => cmd.op = .delete,
            'p' => cmd.op = .print,
            'q' => cmd.op = .quit,
            '=' => cmd.op = .line_num,
            else => {
                ctx.err("unknown sed command '{c}'", .{op_char});
                continue;
            },
        }
        try out.append(ctx.arena, cmd);
    }
}

fn processReader(ctx: *Context, r: *std.Io.Reader, w: *std.Io.Writer, commands: []const Cmd, quiet: bool) !void {
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(ctx.arena, &data) catch {};
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line_orig| {
        if (line_orig.len == 0 and it.peek() == null) break;
        line_no += 1;
        var line: []const u8 = line_orig;
        var deleted = false;
        var quit = false;
        var explicitly_printed = false;

        for (commands) |cmd| {
            if (!addressMatches(cmd, line_no)) continue;
            switch (cmd.op) {
                .sub => {
                    if (cmd.sub_re) |*re| {
                        line = applySubRe(ctx, line, re, cmd.sub_new, cmd.sub_global);
                    }
                },
                .delete => {
                    deleted = true;
                    break;
                },
                .print => {
                    try w.writeAll(line);
                    try w.writeByte('\n');
                    explicitly_printed = true;
                },
                .quit => {
                    quit = true;
                },
                .line_num => {
                    try w.print("{d}\n", .{line_no});
                },
            }
            if (quit) break;
        }

        if (!deleted and !quiet) {
            if (!explicitly_printed) {
                try w.writeAll(line);
                try w.writeByte('\n');
            }
        }
        if (quit) return;
    }
}

fn addressMatches(cmd: Cmd, line_no: usize) bool {
    if (cmd.addr_start == null) return true;
    const start = cmd.addr_start.?;
    const end = cmd.addr_end orelse start;
    return line_no >= start and line_no <= end;
}

fn applySubRe(ctx: *Context, line: []const u8, re: *const regex.Pattern, new: []const u8, global: bool) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) {
        const slice = line[i..];
        const m = re.find(slice);
        if (m == null) break;
        const start = m.?[0];
        const end = m.?[1];
        // Append everything before the match.
        out.appendSlice(ctx.arena, slice[0..start]) catch return line;
        out.appendSlice(ctx.arena, new) catch return line;
        if (end == start) {
            // Avoid infinite loop on zero-length matches.
            if (i + start < line.len) {
                out.append(ctx.arena, line[i + start]) catch return line;
                i = i + start + 1;
            } else break;
        } else {
            i += end;
        }
        if (!global) break;
    }
    out.appendSlice(ctx.arena, line[i..]) catch return line;
    return out.toOwnedSlice(ctx.arena) catch line;
}

fn processInPlace(ctx: *Context, path: []const u8, commands: []const Cmd, quiet: bool) !void {
    const cwd = std.Io.Dir.cwd();

    var input_buf: std.ArrayList(u8) = .empty;
    {
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &input_buf) catch {};
    }

    // Capture output in a fixed buffer (4× input size is generous for most
    // sed scripts; truly explosive expansions are rejected via OutOfMemory).
    const out_buf = try ctx.arena.alloc(u8, input_buf.items.len * 4 + 1024);
    var out_writer = std.Io.Writer.fixed(out_buf);
    var src = std.Io.Reader.fixed(input_buf.items);
    try processReader(ctx, &src, &out_writer, commands, quiet);

    const new_data = out_writer.buffered();
    const out_file = cwd.createFile(ctx.io, path, .{}) catch |e| {
        ctx.err("cannot rewrite '{s}': {s}", .{ path, @errorName(e) });
        return;
    };
    defer out_file.close(ctx.io);
    var wb: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(out_file, ctx.io, &wb);
    try fw.interface.writeAll(new_data);
    try fw.interface.flush();
}
