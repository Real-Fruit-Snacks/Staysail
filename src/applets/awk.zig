const std = @import("std");
const Context = @import("../common/context.zig");
const regex = @import("../common/regex.zig");

pub const name: []const u8 = "awk";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: awk [OPTION]... 'PROGRAM' [FILE]...
    \\       awk [OPTION]... -f PROGRAM-FILE [FILE]...
    \\
    \\Pattern-scanning and processing language.
    \\
    \\  -F SEP            input field separator (default: whitespace runs)
    \\  -f FILE           read program from FILE
    \\  -v VAR=VAL        assign VAR before BEGIN
    \\      --help        display this help and exit
    \\
    \\Phase 3 supports a curated subset:
    \\  - patterns: BEGIN, END, /literal substring/, expression (NR == N)
    \\  - actions: { print [items...]; printf "...", args; }
    \\  - fields: $0, $1, ..., $NF
    \\  - variables: NR (line #), NF (field count), FS (input separator),
    \\               OFS (output separator, default " "), ORS (default "\n")
    \\  - operators: ==, !=, <, <=, >, >=, +, -, *, /, %, string concat (juxt)
    \\
    \\Variables: assign with `name = expr`, increment with `+=`, `-=`. Read with
    \\bare `name` in any expression position.
    \\
    \\Builtins: length(s), tolower(s), toupper(s), index(s, t), substr(s, m, n)
    \\
    \\Not yet supported: control flow (if/while/for), user functions, arrays.
    \\Tracked for v0.6.0.
    \\
;

const Pattern = union(enum) {
    none,
    begin,
    end,
    regex_lit: regex.Pattern,
    expr: Expr,
};

const Expr = union(enum) {
    num: f64,
    str: []const u8,
    field_ref: u8, // 0=$0, 1=$1, etc.
    nf,
    nr,
    var_ref: []const u8,
    builtin_call: BuiltinCall,
    binop: *BinOp,
};

const BuiltinCall = struct {
    name: BuiltinName,
    args: []const Expr,
};

const BuiltinName = enum { length, tolower, toupper, index_fn, substr };

const BinOp = struct {
    op: Op,
    left: Expr,
    right: Expr,
};

const Op = enum { eq, ne, lt, le, gt, ge, add, sub, mul, div, mod };

const Stmt = union(enum) {
    print: []const Expr,
    printf: PrintfStmt,
    assign: AssignStmt,
    expr: Expr,
};

const AssignStmt = struct {
    name: []const u8,
    op: AssignOp,
    value: Expr,
};

const AssignOp = enum { eq, add_eq, sub_eq };

const PrintfStmt = struct {
    fmt: []const u8,
    args: []const Expr,
};

const Rule = struct {
    pattern: Pattern,
    action: []const Stmt,
};

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var fs: []const u8 = " \t";
    var program: ?[]const u8 = null;
    var program_file: ?[]const u8 = null;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-F")) {
            i += 1;
            if (i >= args.len) return 2;
            fs = args[i];
        } else if (a.len > 2 and a[0] == '-' and a[1] == 'F') {
            // Attached form: -F:
            fs = a[2..];
        } else if (std.mem.eql(u8, a, "-f")) {
            i += 1;
            if (i >= args.len) return 2;
            program_file = args[i];
        } else if (std.mem.eql(u8, a, "-v")) {
            i += 1;
            // Variable assignments not yet supported; accept and skip.
        } else {
            if (program == null and program_file == null) {
                program = a;
            } else {
                try operands.append(ctx.arena, a);
            }
        }
    }

    var program_text: []const u8 = undefined;
    if (program_file) |pf| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, pf, .{}) catch |e| {
            ctx.err("cannot open program '{s}': {s}", .{ pf, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        var data: std.ArrayList(u8) = .empty;
        fr.interface.appendRemainingUnlimited(ctx.arena, &data) catch {};
        program_text = data.items;
    } else if (program) |p| {
        program_text = p;
    } else {
        ctx.usage("missing program", .{});
        return 2;
    }

    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(ctx.arena);
    parseProgram(ctx, program_text, &rules) catch |e| {
        ctx.err("parse error: {s}", .{@errorName(e)});
        return 1;
    };

    var vars = std.StringHashMap(Value).init(ctx.gpa);
    defer vars.deinit();
    var state: State = .{ .nr = 0, .nf = 0, .fs = fs, .ofs = " ", .ors = "\n", .fields = &.{}, .line = "", .ctx = ctx, .vars = &vars };

    // BEGIN rules.
    for (rules.items) |rule| {
        if (rule.pattern == .begin) try executeAction(&state, rule.action);
    }

    // Process inputs.
    if (operands.items.len == 0) {
        try processReader(&state, ctx.stdin, rules.items);
    } else for (operands.items) |path| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        try processReader(&state, &fr.interface, rules.items);
    }

    // END rules.
    for (rules.items) |rule| {
        if (rule.pattern == .end) try executeAction(&state, rule.action);
    }
    return 0;
}

const State = struct {
    nr: u64,
    nf: u64,
    fs: []const u8,
    ofs: []const u8,
    ors: []const u8,
    fields: []const []const u8,
    line: []const u8,
    ctx: *Context,
    vars: *std.StringHashMap(Value),
};

fn processReader(state: *State, r: *std.Io.Reader, rules: []const Rule) !void {
    var data: std.ArrayList(u8) = .empty;
    r.appendRemainingUnlimited(state.ctx.arena, &data) catch {};
    var it = std.mem.splitScalar(u8, data.items, '\n');
    while (it.next()) |line| {
        if (line.len == 0 and it.peek() == null) break;
        state.nr += 1;
        state.line = line;
        state.fields = try splitFields(state.ctx.arena, line, state.fs);
        state.nf = state.fields.len;

        for (rules) |rule| {
            if (rule.pattern == .begin or rule.pattern == .end) continue;
            const matched = try matchPattern(state, rule.pattern);
            if (matched) try executeAction(state, rule.action);
        }
    }
}

fn splitFields(gpa: std.mem.Allocator, line: []const u8, fs: []const u8) ![]const []const u8 {
    var fields: std.ArrayList([]const u8) = .empty;
    if (fs.len == 1 and (fs[0] == ' ' or fs[0] == '\t')) {
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |f| try fields.append(gpa, f);
    } else if (fs.len == 1) {
        var it = std.mem.splitScalar(u8, line, fs[0]);
        while (it.next()) |f| try fields.append(gpa, f);
    } else {
        // Fall back to whitespace.
        var it = std.mem.tokenizeAny(u8, line, " \t");
        while (it.next()) |f| try fields.append(gpa, f);
    }
    return fields.toOwnedSlice(gpa);
}

fn matchPattern(state: *State, p: Pattern) !bool {
    switch (p) {
        .none => return true,
        .begin, .end => return false,
        .regex_lit => |re| return re.matches(state.line),
        .expr => |e| return evalBool(state, e),
    }
}

fn executeAction(state: *State, action: []const Stmt) !void {
    for (action) |stmt| switch (stmt) {
        .print => |items| {
            if (items.len == 0) {
                try state.ctx.stdout.writeAll(state.line);
            } else for (items, 0..) |it_expr, idx| {
                if (idx > 0) try state.ctx.stdout.writeAll(state.ofs);
                try writeExpr(state, it_expr);
            }
            try state.ctx.stdout.writeAll(state.ors);
        },
        .printf => |pf| {
            try doPrintf(state, pf.fmt, pf.args);
        },
        .assign => |a| {
            const new_v = try evalValue(state, a.value);
            const final_v: Value = switch (a.op) {
                .eq => new_v,
                .add_eq => blk: {
                    const cur: Value = state.vars.get(a.name) orelse .{ .num = 0 };
                    break :blk .{ .num = toNum(cur) + toNum(new_v) };
                },
                .sub_eq => blk: {
                    const cur: Value = state.vars.get(a.name) orelse .{ .num = 0 };
                    break :blk .{ .num = toNum(cur) - toNum(new_v) };
                },
            };
            try state.vars.put(a.name, final_v);
        },
        .expr => |e| {
            // Evaluate for side effects only.
            _ = try evalValue(state, e);
        },
    };
}

fn writeExpr(state: *State, e: Expr) !void {
    const v = try evalValue(state, e);
    switch (v) {
        .num => |n| {
            if (n == @floor(n) and @abs(n) < 1e15) {
                try state.ctx.stdout.print("{d}", .{@as(i64, @intFromFloat(n))});
            } else {
                try state.ctx.stdout.print("{d}", .{n});
            }
        },
        .str => |s| try state.ctx.stdout.writeAll(s),
    }
}

const Value = union(enum) {
    num: f64,
    str: []const u8,
};

fn evalValue(state: *State, e: Expr) anyerror!Value {
    return switch (e) {
        .num => |n| .{ .num = n },
        .str => |s| .{ .str = s },
        .field_ref => |idx| blk: {
            if (idx == 0) break :blk .{ .str = state.line };
            const i: usize = idx;
            if (i - 1 < state.fields.len) break :blk .{ .str = state.fields[i - 1] };
            break :blk .{ .str = "" };
        },
        .nf => .{ .num = @floatFromInt(state.nf) },
        .nr => .{ .num = @floatFromInt(state.nr) },
        .var_ref => |n| state.vars.get(n) orelse .{ .num = 0 },
        .builtin_call => |bc| try callBuiltin(state, bc),
        .binop => |b| try evalBinop(state, b),
    };
}

fn callBuiltin(state: *State, bc: BuiltinCall) !Value {
    return switch (bc.name) {
        .length => blk: {
            if (bc.args.len == 0) break :blk .{ .num = @floatFromInt(state.line.len) };
            const v = try evalValue(state, bc.args[0]);
            const len: usize = switch (v) {
                .str => |s| s.len,
                .num => |n| (std.fmt.allocPrint(state.ctx.arena, "{d}", .{n}) catch return .{ .num = 0 }).len,
            };
            break :blk .{ .num = @floatFromInt(len) };
        },
        .tolower => blk: {
            if (bc.args.len == 0) break :blk .{ .str = "" };
            const v = try evalValue(state, bc.args[0]);
            const s = switch (v) {
                .str => |x| x,
                .num => |n| std.fmt.allocPrint(state.ctx.arena, "{d}", .{n}) catch "",
            };
            const out = state.ctx.arena.dupe(u8, s) catch return .{ .str = "" };
            for (out, 0..) |_, i| out[i] = std.ascii.toLower(out[i]);
            break :blk .{ .str = out };
        },
        .toupper => blk: {
            if (bc.args.len == 0) break :blk .{ .str = "" };
            const v = try evalValue(state, bc.args[0]);
            const s = switch (v) {
                .str => |x| x,
                .num => |n| std.fmt.allocPrint(state.ctx.arena, "{d}", .{n}) catch "",
            };
            const out = state.ctx.arena.dupe(u8, s) catch return .{ .str = "" };
            for (out, 0..) |_, i| out[i] = std.ascii.toUpper(out[i]);
            break :blk .{ .str = out };
        },
        .index_fn => blk: {
            if (bc.args.len < 2) break :blk .{ .num = 0 };
            const sv = try evalValue(state, bc.args[0]);
            const tv = try evalValue(state, bc.args[1]);
            const s = if (sv == .str) sv.str else "";
            const t = if (tv == .str) tv.str else "";
            if (t.len == 0) break :blk .{ .num = 0 };
            const idx = std.mem.indexOf(u8, s, t) orelse {
                break :blk .{ .num = 0 };
            };
            break :blk .{ .num = @floatFromInt(idx + 1) }; // 1-based
        },
        .substr => blk: {
            if (bc.args.len < 2) break :blk .{ .str = "" };
            const sv = try evalValue(state, bc.args[0]);
            const s = if (sv == .str) sv.str else "";
            const start_v = try evalValue(state, bc.args[1]);
            var start: i64 = @intFromFloat(toNum(start_v));
            if (start < 1) start = 1;
            const start_idx: usize = @intCast(start - 1);
            if (start_idx >= s.len) break :blk .{ .str = "" };
            const end_idx: usize = if (bc.args.len >= 3) blk2: {
                const len_v = try evalValue(state, bc.args[2]);
                const len_i: i64 = @intFromFloat(toNum(len_v));
                if (len_i <= 0) break :blk2 start_idx;
                break :blk2 @min(start_idx + @as(usize, @intCast(len_i)), s.len);
            } else s.len;
            break :blk .{ .str = s[start_idx..end_idx] };
        },
    };
}

fn evalBinop(state: *State, b: *BinOp) anyerror!Value {
    const lv = try evalValue(state, b.left);
    const rv = try evalValue(state, b.right);
    return switch (b.op) {
        .add => .{ .num = toNum(lv) + toNum(rv) },
        .sub => .{ .num = toNum(lv) - toNum(rv) },
        .mul => .{ .num = toNum(lv) * toNum(rv) },
        .div => .{ .num = if (toNum(rv) == 0) 0 else toNum(lv) / toNum(rv) },
        .mod => .{ .num = @mod(toNum(lv), if (toNum(rv) == 0) 1 else toNum(rv)) },
        .eq => .{ .num = if (cmpEq(lv, rv)) 1 else 0 },
        .ne => .{ .num = if (!cmpEq(lv, rv)) 1 else 0 },
        .lt => .{ .num = if (cmpLt(lv, rv)) 1 else 0 },
        .le => .{ .num = if (cmpLt(lv, rv) or cmpEq(lv, rv)) 1 else 0 },
        .gt => .{ .num = if (cmpLt(rv, lv)) 1 else 0 },
        .ge => .{ .num = if (cmpLt(rv, lv) or cmpEq(lv, rv)) 1 else 0 },
    };
}

fn toNum(v: Value) f64 {
    return switch (v) {
        .num => |n| n,
        .str => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch 0,
    };
}

fn cmpEq(a: Value, b: Value) bool {
    if (a == .num or b == .num) return toNum(a) == toNum(b);
    return std.mem.eql(u8, a.str, b.str);
}

fn cmpLt(a: Value, b: Value) bool {
    if (a == .num or b == .num) return toNum(a) < toNum(b);
    return std.mem.lessThan(u8, a.str, b.str);
}

fn evalBool(state: *State, e: Expr) !bool {
    const v = try evalValue(state, e);
    return switch (v) {
        .num => |n| n != 0,
        .str => |s| s.len > 0,
    };
}

fn doPrintf(state: *State, fmt: []const u8, args: []const Expr) !void {
    var arg_idx: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                's' => {
                    if (arg_idx < args.len) {
                        const v = try evalValue(state, args[arg_idx]);
                        switch (v) {
                            .str => |s| try state.ctx.stdout.writeAll(s),
                            .num => |n| try state.ctx.stdout.print("{d}", .{n}),
                        }
                        arg_idx += 1;
                    }
                },
                'd', 'i' => {
                    if (arg_idx < args.len) {
                        const v = try evalValue(state, args[arg_idx]);
                        try state.ctx.stdout.print("{d}", .{@as(i64, @intFromFloat(toNum(v)))});
                        arg_idx += 1;
                    }
                },
                'f', 'g' => {
                    if (arg_idx < args.len) {
                        const v = try evalValue(state, args[arg_idx]);
                        try state.ctx.stdout.print("{d}", .{toNum(v)});
                        arg_idx += 1;
                    }
                },
                '%' => try state.ctx.stdout.writeByte('%'),
                else => |c| {
                    try state.ctx.stdout.writeByte('%');
                    try state.ctx.stdout.writeByte(c);
                },
            }
            i += 1;
        } else if (fmt[i] == '\\' and i + 1 < fmt.len) {
            i += 1;
            switch (fmt[i]) {
                'n' => try state.ctx.stdout.writeByte('\n'),
                't' => try state.ctx.stdout.writeByte('\t'),
                '\\' => try state.ctx.stdout.writeByte('\\'),
                else => try state.ctx.stdout.writeByte(fmt[i]),
            }
            i += 1;
        } else {
            try state.ctx.stdout.writeByte(fmt[i]);
            i += 1;
        }
    }
}

// ----- parser -----

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    ctx: *Context,
};

fn parseProgram(ctx: *Context, src: []const u8, out: *std.ArrayList(Rule)) !void {
    var p: Parser = .{ .src = src, .pos = 0, .arena = ctx.arena, .ctx = ctx };
    while (true) {
        skipSpaces(&p);
        if (p.pos >= p.src.len) break;
        const rule = try parseRule(&p);
        try out.append(ctx.arena, rule);
        skipSpaces(&p);
        // Skip optional ';' or newline between rules.
        while (p.pos < p.src.len and (p.src[p.pos] == ';' or p.src[p.pos] == '\n')) p.pos += 1;
    }
}

fn parseRule(p: *Parser) !Rule {
    const pat = try parsePattern(p);
    skipSpaces(p);
    var action: []const Stmt = &.{};
    if (p.pos < p.src.len and p.src[p.pos] == '{') {
        p.pos += 1;
        action = try parseAction(p);
        skipSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == '}') p.pos += 1;
    } else {
        // No action → default print.
        var stmts: std.ArrayList(Stmt) = .empty;
        try stmts.append(p.arena, .{ .print = &.{} });
        action = try stmts.toOwnedSlice(p.arena);
    }
    return .{ .pattern = pat, .action = action };
}

fn parsePattern(p: *Parser) !Pattern {
    skipSpaces(p);
    if (p.pos >= p.src.len) return .none;
    if (p.src[p.pos] == '{') return .none;

    if (matchKeyword(p, "BEGIN")) return .begin;
    if (matchKeyword(p, "END")) return .end;

    if (p.src[p.pos] == '/') {
        p.pos += 1;
        const start = p.pos;
        while (p.pos < p.src.len and p.src[p.pos] != '/') p.pos += 1;
        const lit = p.src[start..p.pos];
        if (p.pos < p.src.len) p.pos += 1;
        const re = regex.compile(p.arena, lit, .{}) catch {
            return error.InvalidRegex;
        };
        return .{ .regex_lit = re };
    }

    // Try expression pattern.
    const e = try parseExpr(p);
    return .{ .expr = e };
}

fn parseAction(p: *Parser) ![]const Stmt {
    var stmts: std.ArrayList(Stmt) = .empty;
    while (true) {
        skipSpaces(p);
        if (p.pos >= p.src.len or p.src[p.pos] == '}') break;
        if (p.src[p.pos] == ';' or p.src[p.pos] == '\n') {
            p.pos += 1;
            continue;
        }
        const stmt = try parseStmt(p);
        try stmts.append(p.arena, stmt);
    }
    return stmts.toOwnedSlice(p.arena);
}

fn parseStmt(p: *Parser) !Stmt {
    if (matchKeyword(p, "print")) {
        skipSpaces(p);
        var args: std.ArrayList(Expr) = .empty;
        if (p.pos < p.src.len and p.src[p.pos] != ';' and p.src[p.pos] != '}' and p.src[p.pos] != '\n') {
            const e = try parseExpr(p);
            try args.append(p.arena, e);
            while (true) {
                skipSpaces(p);
                if (p.pos >= p.src.len or p.src[p.pos] != ',') break;
                p.pos += 1;
                const next_e = try parseExpr(p);
                try args.append(p.arena, next_e);
            }
        }
        return .{ .print = try args.toOwnedSlice(p.arena) };
    }
    if (matchKeyword(p, "printf")) {
        skipSpaces(p);
        const fmt_e = try parseExpr(p);
        const fmt_str = switch (fmt_e) {
            .str => |s| s,
            else => return error.PrintfFmtMustBeString,
        };
        var args: std.ArrayList(Expr) = .empty;
        while (true) {
            skipSpaces(p);
            if (p.pos >= p.src.len or p.src[p.pos] != ',') break;
            p.pos += 1;
            const a = try parseExpr(p);
            try args.append(p.arena, a);
        }
        return .{ .printf = .{ .fmt = fmt_str, .args = try args.toOwnedSlice(p.arena) } };
    }
    // Assignment or bare expression.
    skipSpaces(p);
    if (p.pos < p.src.len and isIdentStart(p.src[p.pos])) {
        const ident_start = p.pos;
        var k: usize = p.pos;
        while (k < p.src.len and isIdentCont(p.src[k])) k += 1;
        const ident = p.src[ident_start..k];
        // Don't treat builtins/keywords as assign targets — those parse as expressions.
        if (!isReservedIdent(ident)) {
            const save = p.pos;
            p.pos = k;
            skipSpaces(p);
            if (p.pos < p.src.len) {
                const op: ?AssignOp = if (p.src[p.pos] == '=') .eq else if (p.pos + 1 < p.src.len and p.src[p.pos] == '+' and p.src[p.pos + 1] == '=') .add_eq else if (p.pos + 1 < p.src.len and p.src[p.pos] == '-' and p.src[p.pos + 1] == '=') .sub_eq else null;
                if (op != null) {
                    p.pos += if (op == .eq) @as(usize, 1) else 2;
                    const rhs = try parseExpr(p);
                    return .{ .assign = .{ .name = ident, .op = op.?, .value = rhs } };
                }
            }
            p.pos = save;
        }
    }
    // Fall back to a bare expression statement.
    const e = parseExpr(p) catch return error.UnknownStatement;
    return .{ .expr = e };
}

fn isReservedIdent(s: []const u8) bool {
    const reserved = [_][]const u8{ "BEGIN", "END", "print", "printf", "NF", "NR", "if", "else", "while", "for", "do", "function", "return", "length", "tolower", "toupper", "index", "substr" };
    for (reserved) |r| if (std.mem.eql(u8, s, r)) return true;
    return false;
}

fn parseExpr(p: *Parser) anyerror!Expr {
    return parseCmp(p);
}

fn parseCmp(p: *Parser) !Expr {
    var left = try parseAdd(p);
    skipSpaces(p);
    while (p.pos < p.src.len) {
        const op: ?Op = if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "==")) .eq else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "!=")) .ne else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "<=")) .le else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], ">=")) .ge else if (p.src[p.pos] == '<') .lt else if (p.src[p.pos] == '>') .gt else null;
        if (op == null) break;
        p.pos += if (op == .eq or op == .ne or op == .le or op == .ge) @as(usize, 2) else 1;
        const right = try parseAdd(p);
        const b = try p.arena.create(BinOp);
        b.* = .{ .op = op.?, .left = left, .right = right };
        left = .{ .binop = b };
        skipSpaces(p);
    }
    return left;
}

fn parseAdd(p: *Parser) !Expr {
    var left = try parseMul(p);
    skipSpaces(p);
    while (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) {
        const op: Op = if (p.src[p.pos] == '+') .add else .sub;
        p.pos += 1;
        const right = try parseMul(p);
        const b = try p.arena.create(BinOp);
        b.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binop = b };
        skipSpaces(p);
    }
    return left;
}

fn parseMul(p: *Parser) !Expr {
    var left = try parsePrimary(p);
    skipSpaces(p);
    while (p.pos < p.src.len and (p.src[p.pos] == '*' or p.src[p.pos] == '/' or p.src[p.pos] == '%')) {
        const op: Op = switch (p.src[p.pos]) {
            '*' => .mul,
            '/' => .div,
            '%' => .mod,
            else => unreachable,
        };
        p.pos += 1;
        const right = try parsePrimary(p);
        const b = try p.arena.create(BinOp);
        b.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binop = b };
        skipSpaces(p);
    }
    return left;
}

fn parsePrimary(p: *Parser) !Expr {
    skipSpaces(p);
    if (p.pos >= p.src.len) return error.UnexpectedEof;
    const c = p.src[p.pos];

    if (c == '"') {
        p.pos += 1;
        const start = p.pos;
        while (p.pos < p.src.len and p.src[p.pos] != '"') p.pos += 1;
        const s = p.src[start..p.pos];
        if (p.pos < p.src.len) p.pos += 1;
        return .{ .str = s };
    }
    if (c == '$') {
        p.pos += 1;
        // Simple: $N where N is a digit.
        if (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') {
            const idx: u8 = p.src[p.pos] - '0';
            p.pos += 1;
            return .{ .field_ref = idx };
        }
        return .{ .field_ref = 0 };
    }
    if (c >= '0' and c <= '9' or c == '-' or c == '.') {
        const start = p.pos;
        if (c == '-') p.pos += 1;
        while (p.pos < p.src.len and (p.src[p.pos] >= '0' and p.src[p.pos] <= '9' or p.src[p.pos] == '.')) p.pos += 1;
        const n = std.fmt.parseFloat(f64, p.src[start..p.pos]) catch 0;
        return .{ .num = n };
    }
    if (c == '(') {
        p.pos += 1;
        const e = try parseExpr(p);
        skipSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
        return e;
    }
    if (matchKeyword(p, "NF")) return .nf;
    if (matchKeyword(p, "NR")) return .nr;

    // Builtin function call?
    inline for (.{ "length", "tolower", "toupper", "index", "substr" }) |bn_str| {
        if (matchKeyword(p, bn_str)) {
            skipSpaces(p);
            var args: std.ArrayList(Expr) = .empty;
            if (p.pos < p.src.len and p.src[p.pos] == '(') {
                p.pos += 1;
                skipSpaces(p);
                if (p.pos < p.src.len and p.src[p.pos] != ')') {
                    const a = try parseExpr(p);
                    try args.append(p.arena, a);
                    while (true) {
                        skipSpaces(p);
                        if (p.pos >= p.src.len or p.src[p.pos] != ',') break;
                        p.pos += 1;
                        const a2 = try parseExpr(p);
                        try args.append(p.arena, a2);
                    }
                }
                skipSpaces(p);
                if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
            }
            const bn: BuiltinName = if (std.mem.eql(u8, bn_str, "length")) .length else if (std.mem.eql(u8, bn_str, "tolower")) .tolower else if (std.mem.eql(u8, bn_str, "toupper")) .toupper else if (std.mem.eql(u8, bn_str, "index")) .index_fn else .substr;
            return .{ .builtin_call = .{ .name = bn, .args = try args.toOwnedSlice(p.arena) } };
        }
    }

    // Bare identifier → variable reference.
    if (isIdentStart(c)) {
        const start = p.pos;
        while (p.pos < p.src.len and isIdentCont(p.src[p.pos])) p.pos += 1;
        return .{ .var_ref = p.src[start..p.pos] };
    }

    return error.UnexpectedToken;
}

fn skipSpaces(p: *Parser) void {
    while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t')) p.pos += 1;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn matchKeyword(p: *Parser, kw: []const u8) bool {
    if (p.pos + kw.len > p.src.len) return false;
    if (!std.mem.eql(u8, p.src[p.pos .. p.pos + kw.len], kw)) return false;
    // Make sure it's not a prefix of a longer identifier.
    if (p.pos + kw.len < p.src.len) {
        const next = p.src[p.pos + kw.len];
        if ((next >= 'a' and next <= 'z') or (next >= 'A' and next <= 'Z') or (next >= '0' and next <= '9') or next == '_') return false;
    }
    p.pos += kw.len;
    return true;
}
