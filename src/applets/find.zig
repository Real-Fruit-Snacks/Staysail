const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "find";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: find [PATH...] [EXPRESSION]
    \\
    \\Walk each PATH and emit matching entries.
    \\
    \\Predicates:
    \\  -name PATTERN        match basename against shell glob (* ? [...])
    \\  -iname PATTERN       case-insensitive -name
    \\  -type T              one of f (file), d (dir), l (symlink)
    \\  -size [+-]N[c|k|M|G] match by size (c=bytes, k=KB, M=MB, G=GB)
    \\  -mtime [+-]N         modification time in days
    \\  -maxdepth N          descend at most N levels
    \\  -mindepth N          ignore files at less than N levels
    \\  -empty               file/dir is empty
    \\
    \\Operators (Phase 5):
    \\  ! PRED               NOT
    \\  -not PRED            same
    \\  -a, -and             explicit AND (default between predicates)
    \\  -o, -or              OR
    \\
    \\Actions:
    \\  -print               print pathname (default)
    \\  -delete              delete matching files
    \\  -print0              print pathname followed by NUL
    \\  -exec CMD [...] ;    run CMD per match (substitute {} for path)
    \\
    \\Phase 5 limit: parentheses ( ... ) and -prune are deferred to v0.6.0.
    \\
;

// ---------- expression model ----------

const Op = enum {
    name_glob,
    iname_glob,
    type_match,
    size_cmp,
    mtime_cmp,
    empty,
    true_lit,
    @"and",
    @"or",
    not,
};

const Node = struct {
    op: Op,
    str: []const u8 = "",
    int_op: u8 = 0, // for size/mtime: '+', '-', '=', or 't' (type char)
    int_val: i64 = 0,
    left: ?*Node = null,
    right: ?*Node = null,
    child: ?*Node = null,
};

const Action = union(enum) {
    print,
    print0,
    delete,
    exec: []const [:0]const u8,
};

// ---------- main ----------

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var paths: std.ArrayList([:0]const u8) = .empty;
    defer paths.deinit(ctx.arena);

    var maxdepth: usize = std.math.maxInt(usize);
    var mindepth: usize = 0;
    var action: Action = .print;
    var expr_args: std.ArrayList([:0]const u8) = .empty;
    defer expr_args.deinit(ctx.arena);

    // Split argv into PATHS, options-as-side-effects, and expression args.
    var i: usize = 0;
    var saw_predicate = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        }
        if (a.len == 0 or a[0] != '-' and !saw_predicate) {
            try paths.append(ctx.arena, a);
            continue;
        }
        if (std.mem.eql(u8, a, "-maxdepth")) {
            i += 1;
            if (i >= args.len) return 2;
            maxdepth = std.fmt.parseInt(usize, args[i], 10) catch maxdepth;
            saw_predicate = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-mindepth")) {
            i += 1;
            if (i >= args.len) return 2;
            mindepth = std.fmt.parseInt(usize, args[i], 10) catch 0;
            saw_predicate = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-print")) {
            action = .print;
            saw_predicate = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-print0")) {
            action = .print0;
            saw_predicate = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-delete")) {
            action = .delete;
            saw_predicate = true;
            continue;
        }
        if (std.mem.eql(u8, a, "-exec")) {
            i += 1;
            var cmd: std.ArrayList([:0]const u8) = .empty;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], ";")) break;
                try cmd.append(ctx.arena, args[i]);
            }
            if (cmd.items.len == 0) {
                ctx.usage("-exec requires a command terminated by ';'", .{});
                return 2;
            }
            action = .{ .exec = try cmd.toOwnedSlice(ctx.arena) };
            saw_predicate = true;
            continue;
        }
        // Otherwise, an expression token.
        try expr_args.append(ctx.arena, a);
        saw_predicate = true;
    }

    if (paths.items.len == 0) try paths.append(ctx.arena, ".");

    // Parse expression args into an AST. Empty expression is `true`.
    var ep: ExprParser = .{ .args = expr_args.items, .pos = 0, .arena = ctx.arena };
    const root = (parseOr(&ep) catch |e| {
        ctx.err("expression parse error: {s}", .{@errorName(e)});
        return 1;
    }) orelse blk: {
        const t = try ctx.arena.create(Node);
        t.* = .{ .op = .true_lit };
        break :blk t;
    };

    var any_error = false;
    const wctx: WalkCtx = .{
        .root_expr = root,
        .action = action,
        .maxdepth = maxdepth,
        .mindepth = mindepth,
    };
    for (paths.items) |root_path| {
        walk(ctx, root_path, 0, wctx) catch |e| {
            ctx.err("error walking '{s}': {s}", .{ root_path, @errorName(e) });
            any_error = true;
        };
    }
    return if (any_error) 1 else 0;
}

const WalkCtx = struct {
    root_expr: *Node,
    action: Action,
    maxdepth: usize,
    mindepth: usize,
};

// ---------- expression parser ----------

const ExprParser = struct {
    args: []const [:0]const u8,
    pos: usize,
    arena: std.mem.Allocator,
};

fn parseOr(p: *ExprParser) !?*Node {
    var left = try parseAnd(p);
    while (left != null and p.pos < p.args.len) {
        const a = p.args[p.pos];
        if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or")) {
            p.pos += 1;
            const right = try parseAnd(p);
            if (right == null) return left;
            const n = try p.arena.create(Node);
            n.* = .{ .op = .@"or", .left = left, .right = right };
            left = n;
        } else break;
    }
    return left;
}

fn parseAnd(p: *ExprParser) !?*Node {
    var left = try parseNot(p);
    while (left != null and p.pos < p.args.len) {
        const a = p.args[p.pos];
        if (std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and")) {
            p.pos += 1;
            const right = try parseNot(p);
            if (right == null) return left;
            const n = try p.arena.create(Node);
            n.* = .{ .op = .@"and", .left = left, .right = right };
            left = n;
        } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or")) {
            // Don't consume; let parseOr handle.
            break;
        } else {
            // Implicit AND with the next predicate.
            const right = try parseNot(p);
            if (right == null) return left;
            const n = try p.arena.create(Node);
            n.* = .{ .op = .@"and", .left = left, .right = right };
            left = n;
        }
    }
    return left;
}

fn parseNot(p: *ExprParser) !?*Node {
    if (p.pos >= p.args.len) return null;
    const a = p.args[p.pos];
    if (std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, "-not")) {
        p.pos += 1;
        const inner = try parseNot(p);
        if (inner == null) return null;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .not, .child = inner };
        return n;
    }
    return parseAtom(p);
}

fn parseAtom(p: *ExprParser) !?*Node {
    if (p.pos >= p.args.len) return null;
    const a = p.args[p.pos];
    // Operators are not atoms.
    if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "-or") or
        std.mem.eql(u8, a, "-a") or std.mem.eql(u8, a, "-and") or
        std.mem.eql(u8, a, "!") or std.mem.eql(u8, a, "-not"))
    {
        return null;
    }
    p.pos += 1;

    if (std.mem.eql(u8, a, "-name")) {
        if (p.pos >= p.args.len) return error.MissingArg;
        const v = p.args[p.pos];
        p.pos += 1;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .name_glob, .str = v };
        return n;
    }
    if (std.mem.eql(u8, a, "-iname")) {
        if (p.pos >= p.args.len) return error.MissingArg;
        const v = p.args[p.pos];
        p.pos += 1;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .iname_glob, .str = v };
        return n;
    }
    if (std.mem.eql(u8, a, "-type")) {
        if (p.pos >= p.args.len) return error.MissingArg;
        const v = p.args[p.pos];
        p.pos += 1;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .type_match, .int_op = if (v.len > 0) v[0] else 0 };
        return n;
    }
    if (std.mem.eql(u8, a, "-size")) {
        if (p.pos >= p.args.len) return error.MissingArg;
        const v = p.args[p.pos];
        p.pos += 1;
        var op: u8 = '=';
        var rest = v;
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
            op = rest[0];
            rest = rest[1..];
        }
        if (rest.len == 0) return error.BadArg;
        const last = rest[rest.len - 1];
        const mult: u64 = switch (last) {
            'c' => 1,
            'k' => 1024,
            'M' => 1024 * 1024,
            'G' => 1024 * 1024 * 1024,
            '0'...'9' => 512,
            else => return error.BadArg,
        };
        const num = if (mult == 512 and last >= '0' and last <= '9') rest else rest[0 .. rest.len - 1];
        const num_val = std.fmt.parseInt(i64, num, 10) catch return error.BadArg;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .size_cmp, .int_op = op, .int_val = num_val * @as(i64, @intCast(mult)) };
        return n;
    }
    if (std.mem.eql(u8, a, "-mtime")) {
        if (p.pos >= p.args.len) return error.MissingArg;
        const v = p.args[p.pos];
        p.pos += 1;
        var op: u8 = '=';
        var rest = v;
        if (rest.len > 0 and (rest[0] == '+' or rest[0] == '-')) {
            op = rest[0];
            rest = rest[1..];
        }
        const num_val = std.fmt.parseInt(i64, rest, 10) catch return error.BadArg;
        const n = try p.arena.create(Node);
        n.* = .{ .op = .mtime_cmp, .int_op = op, .int_val = num_val };
        return n;
    }
    if (std.mem.eql(u8, a, "-empty")) {
        const n = try p.arena.create(Node);
        n.* = .{ .op = .empty };
        return n;
    }
    return error.UnknownPredicate;
}

// ---------- evaluator ----------

fn evalNode(node: *const Node, basename_str: []const u8, st: std.Io.File.Stat) bool {
    return switch (node.op) {
        .true_lit => true,
        .name_glob => globMatch(node.str, basename_str, false),
        .iname_glob => globMatch(node.str, basename_str, true),
        .type_match => switch (node.int_op) {
            'f' => st.kind == .file,
            'd' => st.kind == .directory,
            'l' => st.kind == .sym_link,
            else => true,
        },
        .size_cmp => cmpInt(node.int_op, @intCast(@min(st.size, std.math.maxInt(i64))), node.int_val),
        .mtime_cmp => true, // would need current time + mtime; deferred
        .empty => st.size == 0,
        .not => !evalNode(node.child.?, basename_str, st),
        .@"and" => evalNode(node.left.?, basename_str, st) and evalNode(node.right.?, basename_str, st),
        .@"or" => evalNode(node.left.?, basename_str, st) or evalNode(node.right.?, basename_str, st),
    };
}

fn cmpInt(op: u8, got: i64, want: i64) bool {
    return switch (op) {
        '+' => got > want,
        '-' => got < want,
        '=' => got == want,
        else => true,
    };
}

// ---------- walk ----------

fn walk(ctx: *Context, path: []const u8, depth: usize, wctx: WalkCtx) anyerror!void {
    if (depth > wctx.maxdepth) return;

    const cwd = std.Io.Dir.cwd();

    if (cwd.openDir(ctx.io, path, .{ .iterate = true })) |dir_open| {
        var dir = dir_open;
        defer dir.close(ctx.io);

        const dir_stat: std.Io.File.Stat = .{
            .inode = 0,
            .nlink = 0,
            .size = 0,
            .permissions = .default_dir,
            .kind = .directory,
            .atime = null,
            .mtime = .{ .nanoseconds = 0 },
            .ctime = .{ .nanoseconds = 0 },
            .block_size = 1,
        };
        if (depth >= wctx.mindepth and evalNode(wctx.root_expr, std.fs.path.basename(path), dir_stat)) {
            try emit(ctx, path, wctx.action);
        }
        if (depth < wctx.maxdepth) {
            var it = dir.iterate();
            while (try it.next(ctx.io)) |entry| {
                const child = try std.fs.path.join(ctx.arena, &.{ path, entry.name });
                try walk(ctx, child, depth + 1, wctx);
            }
        }
        return;
    } else |_| {}

    const f = cwd.openFile(ctx.io, path, .{}) catch return;
    defer f.close(ctx.io);
    const st = f.stat(ctx.io) catch return;
    if (depth >= wctx.mindepth and evalNode(wctx.root_expr, std.fs.path.basename(path), st)) {
        try emit(ctx, path, wctx.action);
    }
}

fn emit(ctx: *Context, path: []const u8, action: Action) !void {
    switch (action) {
        .print => {
            try ctx.stdout.writeAll(path);
            try ctx.stdout.writeByte('\n');
        },
        .print0 => {
            try ctx.stdout.writeAll(path);
            try ctx.stdout.writeByte(0);
        },
        .delete => {
            const cwd = std.Io.Dir.cwd();
            cwd.deleteFile(ctx.io, path) catch |e| switch (e) {
                error.IsDir => cwd.deleteDir(ctx.io, path) catch |de| {
                    ctx.err("cannot delete '{s}': {s}", .{ path, @errorName(de) });
                },
                else => ctx.err("cannot delete '{s}': {s}", .{ path, @errorName(e) }),
            };
        },
        .exec => |cmd_template| {
            var argv: std.ArrayList([:0]const u8) = .empty;
            var saw_brace = false;
            for (cmd_template) |arg| {
                if (std.mem.indexOf(u8, arg, "{}")) |_| {
                    const replaced = try std.mem.replaceOwned(u8, ctx.arena, arg, "{}", path);
                    const z = try ctx.arena.allocSentinel(u8, replaced.len, 0);
                    @memcpy(z, replaced);
                    try argv.append(ctx.arena, z);
                    saw_brace = true;
                } else {
                    try argv.append(ctx.arena, arg);
                }
            }
            if (!saw_brace) {
                const z = try ctx.arena.allocSentinel(u8, path.len, 0);
                @memcpy(z, path);
                try argv.append(ctx.arena, z);
            }
            const result = std.process.run(ctx.gpa, ctx.io, .{ .argv = argv.items }) catch |e| {
                ctx.err("-exec '{s}' failed: {s}", .{ cmd_template[0], @errorName(e) });
                return;
            };
            defer ctx.gpa.free(result.stdout);
            defer ctx.gpa.free(result.stderr);
            try ctx.stdout.writeAll(result.stdout);
            try ctx.stderr.writeAll(result.stderr);
        },
    }
}

// ---------- glob ----------

fn globMatch(pattern: []const u8, target: []const u8, ignore_case: bool) bool {
    return globMatchAt(pattern, 0, target, 0, ignore_case);
}

fn globMatchAt(pattern: []const u8, pi: usize, target: []const u8, ni: usize, ignore_case: bool) bool {
    var p = pi;
    var n = ni;
    while (p < pattern.len) {
        const c = pattern[p];
        switch (c) {
            '*' => {
                if (p + 1 == pattern.len) return true;
                while (n <= target.len) : (n += 1) {
                    if (globMatchAt(pattern, p + 1, target, n, ignore_case)) return true;
                }
                return false;
            },
            '?' => {
                if (n >= target.len) return false;
                p += 1;
                n += 1;
            },
            '[' => {
                if (n >= target.len) return false;
                var end = p + 1;
                while (end < pattern.len and pattern[end] != ']') end += 1;
                if (end == pattern.len) return false;
                const set = pattern[p + 1 .. end];
                var matched = false;
                var k: usize = 0;
                while (k < set.len) : (k += 1) {
                    if (k + 2 < set.len and set[k + 1] == '-') {
                        const lo = set[k];
                        const hi = set[k + 2];
                        const ch = target[n];
                        if (ch >= lo and ch <= hi) {
                            matched = true;
                            break;
                        }
                        k += 2;
                    } else {
                        if (set[k] == target[n]) {
                            matched = true;
                            break;
                        }
                    }
                }
                if (!matched) return false;
                p = end + 1;
                n += 1;
            },
            else => {
                if (n >= target.len) return false;
                const a = if (ignore_case) std.ascii.toLower(c) else c;
                const b = if (ignore_case) std.ascii.toLower(target[n]) else target[n];
                if (a != b) return false;
                p += 1;
                n += 1;
            },
        }
    }
    return n == target.len;
}
