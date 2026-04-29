const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "jq";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: jq [OPTION]... FILTER [FILE]...
    \\
    \\Filter and transform JSON.
    \\
    \\  -r, --raw-output       output strings without quotes
    \\  -c, --compact-output   one JSON value per line, no extra whitespace
    \\  -s, --slurp            read all input into a single array first
    \\  -n, --null-input       use null as input (no stdin/files)
    \\      --help             display this help and exit
    \\
    \\Filter language (Phase 5):
    \\
    \\  .                identity
    \\  .key             field access; .a.b.c chains
    \\  .[idx]           array index (negative wraps from end)
    \\  .[]              iterate object values or array elements
    \\  [exprs]          array construction
    \\  {key: expr,...}  object construction
    \\  filter | filter  pipe
    \\  filter , filter  multiple outputs
    \\  if c then a else b end   conditional
    \\  length, keys, values, type, has(k), select(cond), not
    \\  map(f), add, sort, unique, reverse, tostring, tonumber
    \\  ascii_downcase, ascii_upcase, split(s), join(s)
    \\  startswith(s), endswith(s), contains(v), to_entries, from_entries
    \\  literals: numeric, "string", true, false, null
    \\  ==  !=  <  <=  >  >=  +  -  *  /
    \\
    \\Still missing for full jq parity: variables (`as $x`), function definitions,
    \\recurse, paths, walk, regex builtins. Tracked for v0.6.0.
    \\
;

const Value = union(enum) {
    null,
    bool: bool,
    num: f64,
    str: []const u8,
    arr: []Value,
    obj: []ObjectField,
};

const ObjectField = struct { key: []const u8, val: Value };

// ---------- AST ----------

const Filter = union(enum) {
    identity,
    field: []const u8,
    index: i64,
    iterate,
    pipe: *PipeFilter,
    comma: *CommaFilter,
    select: *Filter,
    has: []const u8,
    length,
    keys,
    values,
    type,
    not,
    literal: Value,
    binop: *BinopFilter,
    arr_construct: []const Filter,
    obj_construct: []const ObjectFieldFilter,
    if_then_else: *IfThenElse,
    builtin: BuiltinCall,
};

const PipeFilter = struct { left: Filter, right: Filter };
const CommaFilter = struct { left: Filter, right: Filter };
const BinopFilter = struct { op: BinOp, left: Filter, right: Filter };
const BinOp = enum { eq, ne, lt, le, gt, ge, add, sub, mul, div };

const ObjectFieldFilter = struct { key: []const u8, value: Filter };
const IfThenElse = struct { cond: Filter, then_: Filter, else_: Filter };

const BuiltinName = enum {
    map,
    add,
    sort,
    unique,
    reverse,
    tostring,
    tonumber,
    ascii_downcase,
    ascii_upcase,
    split,
    join,
    startswith,
    endswith,
    contains,
    to_entries,
    from_entries,
};

const BuiltinCall = struct {
    name: BuiltinName,
    args: []const Filter,
};

// ---------- entry ----------

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var raw = false;
    var compact = false;
    var slurp = false;
    var null_input = false;
    var program: ?[]const u8 = null;
    var operands: std.ArrayList([:0]const u8) = .empty;
    defer operands.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-r") or std.mem.eql(u8, a, "--raw-output")) {
            raw = true;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--compact-output")) {
            compact = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--slurp")) {
            slurp = true;
        } else if (std.mem.eql(u8, a, "-n") or std.mem.eql(u8, a, "--null-input")) {
            null_input = true;
        } else {
            if (program == null) program = a else try operands.append(ctx.arena, a);
        }
    }
    if (program == null) {
        ctx.usage("missing filter", .{});
        return 2;
    }

    var parser: Parser = .{ .src = program.?, .pos = 0, .arena = ctx.arena };
    const filter = parseFilter(&parser) catch |e| {
        ctx.err("parse error: {s}", .{@errorName(e)});
        return 1;
    };

    var input_data: std.ArrayList(u8) = .empty;
    if (null_input) {
        try evalAndPrint(ctx, &filter, .null, raw, compact);
        return 0;
    }
    if (operands.items.len == 0) {
        ctx.stdin.appendRemainingUnlimited(ctx.arena, &input_data) catch {};
    } else for (operands.items) |path| {
        const cwd = std.Io.Dir.cwd();
        const f = cwd.openFile(ctx.io, path, .{}) catch |e| {
            ctx.err("cannot open '{s}': {s}", .{ path, @errorName(e) });
            return 1;
        };
        defer f.close(ctx.io);
        var rb: [16 * 1024]u8 = undefined;
        var fr = f.reader(ctx.io, &rb);
        fr.interface.appendRemainingUnlimited(ctx.arena, &input_data) catch {};
    }

    if (slurp) {
        var arr: std.ArrayList(Value) = .empty;
        var jp: JsonParser = .{ .src = input_data.items, .pos = 0, .arena = ctx.arena };
        skipWs(&jp);
        while (jp.pos < jp.src.len) {
            const v = parseJson(&jp) catch |e| {
                ctx.err("invalid json: {s}", .{@errorName(e)});
                return 1;
            };
            try arr.append(ctx.arena, v);
            skipWs(&jp);
        }
        const slurped: Value = .{ .arr = try arr.toOwnedSlice(ctx.arena) };
        try evalAndPrint(ctx, &filter, slurped, raw, compact);
    } else {
        var jp: JsonParser = .{ .src = input_data.items, .pos = 0, .arena = ctx.arena };
        skipWs(&jp);
        while (jp.pos < jp.src.len) {
            const v = parseJson(&jp) catch |e| {
                ctx.err("invalid json: {s}", .{@errorName(e)});
                return 1;
            };
            try evalAndPrint(ctx, &filter, v, raw, compact);
            skipWs(&jp);
        }
    }
    return 0;
}

fn evalAndPrint(ctx: *Context, filter: *const Filter, input: Value, raw: bool, compact: bool) !void {
    var out: std.ArrayList(Value) = .empty;
    defer out.deinit(ctx.arena);
    try evalFilter(ctx, filter, input, &out);
    for (out.items) |v| {
        try writeJson(ctx.stdout, v, raw, compact, 0);
        try ctx.stdout.writeByte('\n');
    }
}

// ---------- evaluator ----------

fn evalFilter(ctx: *Context, filter: *const Filter, input: Value, out: *std.ArrayList(Value)) anyerror!void {
    switch (filter.*) {
        .identity => try out.append(ctx.arena, input),
        .field => |k| try out.append(ctx.arena, fieldOf(input, k)),
        .index => |i| try out.append(ctx.arena, indexOf(input, i)),
        .iterate => switch (input) {
            .arr => |xs| for (xs) |x| try out.append(ctx.arena, x),
            .obj => |fs| for (fs) |f| try out.append(ctx.arena, f.val),
            else => {},
        },
        .pipe => |pf| {
            var mid: std.ArrayList(Value) = .empty;
            defer mid.deinit(ctx.arena);
            try evalFilter(ctx, &pf.left, input, &mid);
            for (mid.items) |v| try evalFilter(ctx, &pf.right, v, out);
        },
        .comma => |cf| {
            try evalFilter(ctx, &cf.left, input, out);
            try evalFilter(ctx, &cf.right, input, out);
        },
        .select => |inner| {
            var mid: std.ArrayList(Value) = .empty;
            defer mid.deinit(ctx.arena);
            try evalFilter(ctx, inner, input, &mid);
            for (mid.items) |v| if (truthy(v)) try out.append(ctx.arena, input);
        },
        .has => |k| {
            const got = switch (input) {
                .obj => |fs| blk: {
                    for (fs) |f| if (std.mem.eql(u8, f.key, k)) break :blk true;
                    break :blk false;
                },
                else => false,
            };
            try out.append(ctx.arena, .{ .bool = got });
        },
        .length => try out.append(ctx.arena, .{ .num = @floatFromInt(lengthOf(input)) }),
        .keys => {
            var key_strs: std.ArrayList([]const u8) = .empty;
            switch (input) {
                .obj => |fs| for (fs) |f| try key_strs.append(ctx.arena, f.key),
                else => {},
            }
            std.mem.sort([]const u8, key_strs.items, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.lessThan(u8, a, b);
                }
            }.lt);
            var arr: std.ArrayList(Value) = .empty;
            for (key_strs.items) |k| try arr.append(ctx.arena, .{ .str = k });
            try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
        },
        .values => {
            var arr: std.ArrayList(Value) = .empty;
            switch (input) {
                .obj => |fs| for (fs) |f| try arr.append(ctx.arena, f.val),
                .arr => |xs| for (xs) |x| try arr.append(ctx.arena, x),
                else => {},
            }
            try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
        },
        .type => try out.append(ctx.arena, .{ .str = typeName(input) }),
        .not => try out.append(ctx.arena, .{ .bool = !truthy(input) }),
        .literal => |v| try out.append(ctx.arena, v),
        .binop => |b| {
            var lv: std.ArrayList(Value) = .empty;
            defer lv.deinit(ctx.arena);
            try evalFilter(ctx, &b.left, input, &lv);
            var rv: std.ArrayList(Value) = .empty;
            defer rv.deinit(ctx.arena);
            try evalFilter(ctx, &b.right, input, &rv);
            for (lv.items) |l| for (rv.items) |r| try out.append(ctx.arena, applyBinop(b.op, l, r));
        },
        .arr_construct => |fs| {
            var arr: std.ArrayList(Value) = .empty;
            for (fs) |f| try evalFilter(ctx, &f, input, &arr);
            try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
        },
        .obj_construct => |fs| {
            var obj_fields: std.ArrayList(ObjectField) = .empty;
            for (fs) |of| {
                var single: std.ArrayList(Value) = .empty;
                defer single.deinit(ctx.arena);
                try evalFilter(ctx, &of.value, input, &single);
                const v = if (single.items.len > 0) single.items[0] else Value.null;
                try obj_fields.append(ctx.arena, .{ .key = of.key, .val = v });
            }
            try out.append(ctx.arena, .{ .obj = try obj_fields.toOwnedSlice(ctx.arena) });
        },
        .if_then_else => |ite| {
            var cond_vals: std.ArrayList(Value) = .empty;
            defer cond_vals.deinit(ctx.arena);
            try evalFilter(ctx, &ite.cond, input, &cond_vals);
            const cond_true = cond_vals.items.len > 0 and truthy(cond_vals.items[0]);
            if (cond_true) {
                try evalFilter(ctx, &ite.then_, input, out);
            } else {
                try evalFilter(ctx, &ite.else_, input, out);
            }
        },
        .builtin => |bc| try evalBuiltin(ctx, bc, input, out),
    }
}

fn evalBuiltin(ctx: *Context, bc: BuiltinCall, input: Value, out: *std.ArrayList(Value)) anyerror!void {
    switch (bc.name) {
        .map => {
            if (bc.args.len == 0) return;
            const f = bc.args[0];
            const items: []const Value = switch (input) {
                .arr => |xs| xs,
                else => return,
            };
            var arr: std.ArrayList(Value) = .empty;
            for (items) |x| try evalFilter(ctx, &f, x, &arr);
            try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
        },
        .add => switch (input) {
            .arr => |xs| {
                if (xs.len == 0) {
                    try out.append(ctx.arena, .null);
                    return;
                }
                var acc = xs[0];
                for (xs[1..]) |x| acc = addValues(acc, x);
                try out.append(ctx.arena, acc);
            },
            else => try out.append(ctx.arena, .null),
        },
        .sort => switch (input) {
            .arr => |xs| {
                const dup = try ctx.arena.dupe(Value, xs);
                std.mem.sort(Value, dup, {}, valueLessThan);
                try out.append(ctx.arena, .{ .arr = dup });
            },
            else => try out.append(ctx.arena, input),
        },
        .unique => switch (input) {
            .arr => |xs| {
                const dup = try ctx.arena.dupe(Value, xs);
                std.mem.sort(Value, dup, {}, valueLessThan);
                var keep: std.ArrayList(Value) = .empty;
                for (dup, 0..) |x, i| {
                    if (i == 0 or !valueEq(dup[i - 1], x)) try keep.append(ctx.arena, x);
                }
                try out.append(ctx.arena, .{ .arr = try keep.toOwnedSlice(ctx.arena) });
            },
            else => try out.append(ctx.arena, input),
        },
        .reverse => switch (input) {
            .arr => |xs| {
                const dup = try ctx.arena.dupe(Value, xs);
                std.mem.reverse(Value, dup);
                try out.append(ctx.arena, .{ .arr = dup });
            },
            .str => |s| {
                const dup = try ctx.arena.dupe(u8, s);
                std.mem.reverse(u8, dup);
                try out.append(ctx.arena, .{ .str = dup });
            },
            else => try out.append(ctx.arena, input),
        },
        .tostring => switch (input) {
            .str => try out.append(ctx.arena, input),
            .num => |n| {
                const s = if (n == @floor(n) and @abs(n) < 1e15)
                    try std.fmt.allocPrint(ctx.arena, "{d}", .{@as(i64, @intFromFloat(n))})
                else
                    try std.fmt.allocPrint(ctx.arena, "{d}", .{n});
                try out.append(ctx.arena, .{ .str = s });
            },
            .bool => |b| try out.append(ctx.arena, .{ .str = if (b) "true" else "false" }),
            .null => try out.append(ctx.arena, .{ .str = "null" }),
            else => try out.append(ctx.arena, .{ .str = "(complex)" }),
        },
        .tonumber => try out.append(ctx.arena, .{ .num = numOf(input) }),
        .ascii_downcase => switch (input) {
            .str => |s| {
                const dup = try ctx.arena.dupe(u8, s);
                for (dup, 0..) |_, i| dup[i] = std.ascii.toLower(dup[i]);
                try out.append(ctx.arena, .{ .str = dup });
            },
            else => try out.append(ctx.arena, input),
        },
        .ascii_upcase => switch (input) {
            .str => |s| {
                const dup = try ctx.arena.dupe(u8, s);
                for (dup, 0..) |_, i| dup[i] = std.ascii.toUpper(dup[i]);
                try out.append(ctx.arena, .{ .str = dup });
            },
            else => try out.append(ctx.arena, input),
        },
        .split => {
            if (bc.args.len == 0) return;
            var sep_vals: std.ArrayList(Value) = .empty;
            defer sep_vals.deinit(ctx.arena);
            try evalFilter(ctx, &bc.args[0], input, &sep_vals);
            const sep = if (sep_vals.items.len > 0 and sep_vals.items[0] == .str) sep_vals.items[0].str else "";
            const s = if (input == .str) input.str else "";
            var arr: std.ArrayList(Value) = .empty;
            if (sep.len == 0) {
                for (s) |c| {
                    const dup = try ctx.arena.alloc(u8, 1);
                    dup[0] = c;
                    try arr.append(ctx.arena, .{ .str = dup });
                }
            } else {
                var it = std.mem.splitSequence(u8, s, sep);
                while (it.next()) |part| try arr.append(ctx.arena, .{ .str = part });
            }
            try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
        },
        .join => {
            if (bc.args.len == 0) return;
            var sep_vals: std.ArrayList(Value) = .empty;
            defer sep_vals.deinit(ctx.arena);
            try evalFilter(ctx, &bc.args[0], input, &sep_vals);
            const sep = if (sep_vals.items.len > 0 and sep_vals.items[0] == .str) sep_vals.items[0].str else "";
            switch (input) {
                .arr => |xs| {
                    var buf: std.ArrayList(u8) = .empty;
                    for (xs, 0..) |x, i| {
                        if (i > 0) try buf.appendSlice(ctx.arena, sep);
                        switch (x) {
                            .str => |s| try buf.appendSlice(ctx.arena, s),
                            .num => |n| {
                                const numstr = try std.fmt.allocPrint(ctx.arena, "{d}", .{n});
                                try buf.appendSlice(ctx.arena, numstr);
                            },
                            else => {},
                        }
                    }
                    try out.append(ctx.arena, .{ .str = try buf.toOwnedSlice(ctx.arena) });
                },
                else => try out.append(ctx.arena, input),
            }
        },
        .startswith => {
            if (bc.args.len == 0) return;
            var pv: std.ArrayList(Value) = .empty;
            defer pv.deinit(ctx.arena);
            try evalFilter(ctx, &bc.args[0], input, &pv);
            const pat = if (pv.items.len > 0 and pv.items[0] == .str) pv.items[0].str else "";
            const s = if (input == .str) input.str else "";
            try out.append(ctx.arena, .{ .bool = std.mem.startsWith(u8, s, pat) });
        },
        .endswith => {
            if (bc.args.len == 0) return;
            var pv: std.ArrayList(Value) = .empty;
            defer pv.deinit(ctx.arena);
            try evalFilter(ctx, &bc.args[0], input, &pv);
            const pat = if (pv.items.len > 0 and pv.items[0] == .str) pv.items[0].str else "";
            const s = if (input == .str) input.str else "";
            try out.append(ctx.arena, .{ .bool = std.mem.endsWith(u8, s, pat) });
        },
        .contains => {
            if (bc.args.len == 0) return;
            var pv: std.ArrayList(Value) = .empty;
            defer pv.deinit(ctx.arena);
            try evalFilter(ctx, &bc.args[0], input, &pv);
            const v = if (pv.items.len > 0) pv.items[0] else Value.null;
            const result = switch (input) {
                .str => switch (v) {
                    .str => |s| std.mem.indexOf(u8, input.str, s) != null,
                    else => false,
                },
                else => false,
            };
            try out.append(ctx.arena, .{ .bool = result });
        },
        .to_entries => switch (input) {
            .obj => |fs| {
                var arr: std.ArrayList(Value) = .empty;
                for (fs) |f| {
                    var entry: [2]ObjectField = .{
                        .{ .key = "key", .val = .{ .str = f.key } },
                        .{ .key = "value", .val = f.val },
                    };
                    const dup = try ctx.arena.dupe(ObjectField, &entry);
                    try arr.append(ctx.arena, .{ .obj = dup });
                }
                try out.append(ctx.arena, .{ .arr = try arr.toOwnedSlice(ctx.arena) });
            },
            else => try out.append(ctx.arena, .{ .arr = &.{} }),
        },
        .from_entries => switch (input) {
            .arr => |xs| {
                var fs: std.ArrayList(ObjectField) = .empty;
                for (xs) |x| {
                    if (x != .obj) continue;
                    var k: []const u8 = "";
                    var v: Value = .null;
                    for (x.obj) |f| {
                        if (std.mem.eql(u8, f.key, "key") or std.mem.eql(u8, f.key, "k") or std.mem.eql(u8, f.key, "name")) {
                            if (f.val == .str) k = f.val.str;
                        } else if (std.mem.eql(u8, f.key, "value") or std.mem.eql(u8, f.key, "v")) {
                            v = f.val;
                        }
                    }
                    try fs.append(ctx.arena, .{ .key = k, .val = v });
                }
                try out.append(ctx.arena, .{ .obj = try fs.toOwnedSlice(ctx.arena) });
            },
            else => try out.append(ctx.arena, input),
        },
    }
}

fn valueLessThan(_: void, a: Value, b: Value) bool {
    return valueLt(a, b);
}

fn fieldOf(v: Value, key: []const u8) Value {
    return switch (v) {
        .obj => |fs| blk: {
            for (fs) |f| if (std.mem.eql(u8, f.key, key)) break :blk f.val;
            break :blk .null;
        },
        else => .null,
    };
}

fn indexOf(v: Value, i: i64) Value {
    return switch (v) {
        .arr => |xs| blk: {
            const len: i64 = @intCast(xs.len);
            const idx = if (i < 0) len + i else i;
            if (idx < 0 or idx >= len) break :blk .null;
            break :blk xs[@intCast(idx)];
        },
        else => .null,
    };
}

fn lengthOf(v: Value) usize {
    return switch (v) {
        .null => 0,
        .bool => 0,
        .num => 0,
        .str => |s| s.len,
        .arr => |xs| xs.len,
        .obj => |fs| fs.len,
    };
}

fn truthy(v: Value) bool {
    return switch (v) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

fn typeName(v: Value) []const u8 {
    return switch (v) {
        .null => "null",
        .bool => "boolean",
        .num => "number",
        .str => "string",
        .arr => "array",
        .obj => "object",
    };
}

fn applyBinop(op: BinOp, a: Value, b: Value) Value {
    return switch (op) {
        .eq => .{ .bool = valueEq(a, b) },
        .ne => .{ .bool = !valueEq(a, b) },
        .lt => .{ .bool = valueLt(a, b) },
        .le => .{ .bool = valueLt(a, b) or valueEq(a, b) },
        .gt => .{ .bool = valueLt(b, a) },
        .ge => .{ .bool = valueLt(b, a) or valueEq(a, b) },
        .add => addValues(a, b),
        .sub => .{ .num = numOf(a) - numOf(b) },
        .mul => .{ .num = numOf(a) * numOf(b) },
        .div => .{ .num = if (numOf(b) == 0) 0 else numOf(a) / numOf(b) },
    };
}

fn valueEq(a: Value, b: Value) bool {
    if (@intFromEnum(a) != @intFromEnum(b)) {
        if (a == .num or b == .num) return numOf(a) == numOf(b);
        return false;
    }
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .num => |x| x == b.num,
        .str => |x| std.mem.eql(u8, x, b.str),
        .arr, .obj => false, // structural eq deferred
    };
}

fn valueLt(a: Value, b: Value) bool {
    if (a == .num and b == .num) return a.num < b.num;
    if (a == .str and b == .str) return std.mem.lessThan(u8, a.str, b.str);
    return false;
}

fn numOf(v: Value) f64 {
    return switch (v) {
        .num => |n| n,
        .bool => |b| if (b) 1 else 0,
        .str => |s| std.fmt.parseFloat(f64, s) catch 0,
        else => 0,
    };
}

fn addValues(a: Value, b: Value) Value {
    if (a == .num and b == .num) return .{ .num = a.num + b.num };
    return .{ .num = numOf(a) + numOf(b) };
}

// ---------- writers ----------

fn writeJson(w: *std.Io.Writer, v: Value, raw: bool, compact: bool, depth: usize) !void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .num => |n| {
            if (n == @floor(n) and @abs(n) < 1e15) {
                try w.print("{d}", .{@as(i64, @intFromFloat(n))});
            } else {
                try w.print("{d}", .{n});
            }
        },
        .str => |s| if (raw and depth == 0) {
            try w.writeAll(s);
        } else try writeJsonString(w, s),
        .arr => |xs| {
            try w.writeByte('[');
            for (xs, 0..) |x, i| {
                if (i > 0) {
                    try w.writeByte(',');
                    if (!compact) try w.writeByte(' ');
                }
                try writeJson(w, x, raw, compact, depth + 1);
            }
            try w.writeByte(']');
        },
        .obj => |fs| {
            try w.writeByte('{');
            for (fs, 0..) |f, i| {
                if (i > 0) {
                    try w.writeByte(',');
                    if (!compact) try w.writeByte(' ');
                }
                try writeJsonString(w, f.key);
                try w.writeByte(':');
                if (!compact) try w.writeByte(' ');
                try writeJson(w, f.val, raw, compact, depth + 1);
            }
            try w.writeByte('}');
        },
    }
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) {
            try w.print("\\u{x:0>4}", .{c});
        } else {
            try w.writeByte(c);
        },
    };
    try w.writeByte('"');
}

// ---------- filter parser ----------

const Parser = struct { src: []const u8, pos: usize, arena: std.mem.Allocator };

fn parseFilter(p: *Parser) anyerror!Filter {
    return parsePipe(p);
}

fn parsePipe(p: *Parser) anyerror!Filter {
    var left = try parseComma(p);
    skipPSpaces(p);
    while (p.pos < p.src.len and p.src[p.pos] == '|') {
        p.pos += 1;
        skipPSpaces(p);
        const right = try parseComma(p);
        const node = try p.arena.create(PipeFilter);
        node.* = .{ .left = left, .right = right };
        left = .{ .pipe = node };
        skipPSpaces(p);
    }
    return left;
}

fn parseComma(p: *Parser) anyerror!Filter {
    var left = try parseBinopRel(p);
    skipPSpaces(p);
    while (p.pos < p.src.len and p.src[p.pos] == ',') {
        p.pos += 1;
        skipPSpaces(p);
        const right = try parseBinopRel(p);
        const node = try p.arena.create(CommaFilter);
        node.* = .{ .left = left, .right = right };
        left = .{ .comma = node };
        skipPSpaces(p);
    }
    return left;
}

fn parseBinopRel(p: *Parser) anyerror!Filter {
    var left = try parseBinopAdd(p);
    skipPSpaces(p);
    while (p.pos < p.src.len) {
        const op: ?BinOp = if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "==")) .eq else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "!=")) .ne else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], "<=")) .le else if (p.pos + 1 < p.src.len and std.mem.eql(u8, p.src[p.pos .. p.pos + 2], ">=")) .ge else if (p.src[p.pos] == '<') .lt else if (p.src[p.pos] == '>') .gt else null;
        if (op == null) break;
        p.pos += if (op == .eq or op == .ne or op == .le or op == .ge) @as(usize, 2) else 1;
        skipPSpaces(p);
        const right = try parseBinopAdd(p);
        const node = try p.arena.create(BinopFilter);
        node.* = .{ .op = op.?, .left = left, .right = right };
        left = .{ .binop = node };
        skipPSpaces(p);
    }
    return left;
}

fn parseBinopAdd(p: *Parser) anyerror!Filter {
    var left = try parseBinopMul(p);
    skipPSpaces(p);
    while (p.pos < p.src.len and (p.src[p.pos] == '+' or p.src[p.pos] == '-')) {
        const op: BinOp = if (p.src[p.pos] == '+') .add else .sub;
        p.pos += 1;
        skipPSpaces(p);
        const right = try parseBinopMul(p);
        const node = try p.arena.create(BinopFilter);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binop = node };
        skipPSpaces(p);
    }
    return left;
}

fn parseBinopMul(p: *Parser) anyerror!Filter {
    var left = try parsePrimary(p);
    skipPSpaces(p);
    while (p.pos < p.src.len and (p.src[p.pos] == '*' or p.src[p.pos] == '/')) {
        const op: BinOp = if (p.src[p.pos] == '*') .mul else .div;
        p.pos += 1;
        skipPSpaces(p);
        const right = try parsePrimary(p);
        const node = try p.arena.create(BinopFilter);
        node.* = .{ .op = op, .left = left, .right = right };
        left = .{ .binop = node };
        skipPSpaces(p);
    }
    return left;
}

fn parsePrimary(p: *Parser) anyerror!Filter {
    skipPSpaces(p);
    if (p.pos >= p.src.len) return .identity;

    // Array construction: [exprs]
    if (p.src[p.pos] == '[') {
        p.pos += 1;
        var items: std.ArrayList(Filter) = .empty;
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] != ']') {
            const e = try parseFilter(p);
            try items.append(p.arena, e);
            while (true) {
                skipPSpaces(p);
                if (p.pos >= p.src.len or p.src[p.pos] != ',') break;
                p.pos += 1;
                const next = try parseFilter(p);
                try items.append(p.arena, next);
            }
        }
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == ']') p.pos += 1;
        return .{ .arr_construct = try items.toOwnedSlice(p.arena) };
    }

    // Object construction: {key: expr, ...}
    if (p.src[p.pos] == '{') {
        p.pos += 1;
        var fields: std.ArrayList(ObjectFieldFilter) = .empty;
        skipPSpaces(p);
        while (p.pos < p.src.len and p.src[p.pos] != '}') {
            var key: []const u8 = "";
            if (p.src[p.pos] == '"') {
                p.pos += 1;
                const ks = p.pos;
                while (p.pos < p.src.len and p.src[p.pos] != '"') p.pos += 1;
                key = p.src[ks..p.pos];
                if (p.pos < p.src.len) p.pos += 1;
            } else if (isIdentStart(p.src[p.pos])) {
                const ks = p.pos;
                while (p.pos < p.src.len and isIdentCont(p.src[p.pos])) p.pos += 1;
                key = p.src[ks..p.pos];
            }
            skipPSpaces(p);
            var value_filter: Filter = .{ .field = key }; // shorthand: { foo } = { foo: .foo }
            if (p.pos < p.src.len and p.src[p.pos] == ':') {
                p.pos += 1;
                // Use comma-free parser so the next ',' delimits fields, not
                // the comma-operator value.
                value_filter = try parsePipeNoComma(p);
            }
            try fields.append(p.arena, .{ .key = key, .value = value_filter });
            skipPSpaces(p);
            if (p.pos < p.src.len and p.src[p.pos] == ',') {
                p.pos += 1;
                skipPSpaces(p);
                continue;
            }
            break;
        }
        if (p.pos < p.src.len and p.src[p.pos] == '}') p.pos += 1;
        return .{ .obj_construct = try fields.toOwnedSlice(p.arena) };
    }

    if (matchKw(p, "if")) return parseIfThenElse(p);

    if (matchKw(p, "length")) return .length;
    if (matchKw(p, "keys")) return .keys;
    if (matchKw(p, "values")) return .values;
    if (matchKw(p, "type")) return .type;
    if (matchKw(p, "not")) return .not;
    if (matchKw(p, "true")) return .{ .literal = .{ .bool = true } };
    if (matchKw(p, "false")) return .{ .literal = .{ .bool = false } };
    if (matchKw(p, "null")) return .{ .literal = .null };

    // Builtin function calls.
    if (matchKw(p, "map")) return parseBuiltinCall(p, .map);
    if (matchKw(p, "add")) return .{ .builtin = .{ .name = .add, .args = &.{} } };
    if (matchKw(p, "sort")) return .{ .builtin = .{ .name = .sort, .args = &.{} } };
    if (matchKw(p, "unique")) return .{ .builtin = .{ .name = .unique, .args = &.{} } };
    if (matchKw(p, "reverse")) return .{ .builtin = .{ .name = .reverse, .args = &.{} } };
    if (matchKw(p, "tostring")) return .{ .builtin = .{ .name = .tostring, .args = &.{} } };
    if (matchKw(p, "tonumber")) return .{ .builtin = .{ .name = .tonumber, .args = &.{} } };
    if (matchKw(p, "ascii_downcase")) return .{ .builtin = .{ .name = .ascii_downcase, .args = &.{} } };
    if (matchKw(p, "ascii_upcase")) return .{ .builtin = .{ .name = .ascii_upcase, .args = &.{} } };
    if (matchKw(p, "split")) return parseBuiltinCall(p, .split);
    if (matchKw(p, "join")) return parseBuiltinCall(p, .join);
    if (matchKw(p, "startswith")) return parseBuiltinCall(p, .startswith);
    if (matchKw(p, "endswith")) return parseBuiltinCall(p, .endswith);
    if (matchKw(p, "contains")) return parseBuiltinCall(p, .contains);
    if (matchKw(p, "to_entries")) return .{ .builtin = .{ .name = .to_entries, .args = &.{} } };
    if (matchKw(p, "from_entries")) return .{ .builtin = .{ .name = .from_entries, .args = &.{} } };

    if (matchKw(p, "select")) {
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == '(') {
            p.pos += 1;
            const inner = try parseFilter(p);
            skipPSpaces(p);
            if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
            const node = try p.arena.create(Filter);
            node.* = inner;
            return .{ .select = node };
        }
        return .identity;
    }
    if (matchKw(p, "has")) {
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == '(') {
            p.pos += 1;
            skipPSpaces(p);
            // Expect a string literal.
            if (p.pos < p.src.len and p.src[p.pos] == '"') {
                p.pos += 1;
                const start = p.pos;
                while (p.pos < p.src.len and p.src[p.pos] != '"') p.pos += 1;
                const k = p.src[start..p.pos];
                if (p.pos < p.src.len) p.pos += 1;
                skipPSpaces(p);
                if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
                return .{ .has = k };
            }
        }
        return .identity;
    }

    const c = p.src[p.pos];
    if (c == '.') {
        p.pos += 1;
        return parsePathTail(p);
    }
    if (c == '"') {
        p.pos += 1;
        const start = p.pos;
        while (p.pos < p.src.len and p.src[p.pos] != '"') p.pos += 1;
        const s = p.src[start..p.pos];
        if (p.pos < p.src.len) p.pos += 1;
        return .{ .literal = .{ .str = s } };
    }
    if (c >= '0' and c <= '9' or c == '-') {
        const start = p.pos;
        if (c == '-') p.pos += 1;
        while (p.pos < p.src.len and (p.src[p.pos] >= '0' and p.src[p.pos] <= '9' or p.src[p.pos] == '.')) p.pos += 1;
        const n = std.fmt.parseFloat(f64, p.src[start..p.pos]) catch 0;
        return .{ .literal = .{ .num = n } };
    }
    if (c == '(') {
        p.pos += 1;
        const inner = try parseFilter(p);
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
        return inner;
    }
    return .identity;
}

fn parsePathTail(p: *Parser) anyerror!Filter {
    // After leading `.`, parse zero or more `.field` / `[idx]` / `[]`.
    var current: Filter = .identity;
    while (p.pos < p.src.len) {
        const c = p.src[p.pos];
        if (c == '[') {
            p.pos += 1;
            skipPSpaces(p);
            if (p.pos < p.src.len and p.src[p.pos] == ']') {
                p.pos += 1;
                current = chain(p, current, .iterate);
                continue;
            }
            // Number index.
            const start = p.pos;
            if (p.pos < p.src.len and p.src[p.pos] == '-') p.pos += 1;
            while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') p.pos += 1;
            const idx = std.fmt.parseInt(i64, p.src[start..p.pos], 10) catch 0;
            skipPSpaces(p);
            if (p.pos < p.src.len and p.src[p.pos] == ']') p.pos += 1;
            current = chain(p, current, .{ .index = idx });
            continue;
        }
        if (c == '.') {
            p.pos += 1;
            // Either another field name or terminator.
            if (p.pos >= p.src.len or !isIdentStart(p.src[p.pos])) return current;
        }
        if (isIdentStart(c) or (current == .identity and isIdentStart(c))) {
            const start = p.pos;
            while (p.pos < p.src.len and isIdentCont(p.src[p.pos])) p.pos += 1;
            const name_str = p.src[start..p.pos];
            if (name_str.len == 0) return current;
            current = chain(p, current, .{ .field = name_str });
            continue;
        }
        break;
    }
    return current;
}

fn chain(p: *Parser, current: Filter, next: Filter) Filter {
    if (current == .identity) return next;
    const node = p.arena.create(PipeFilter) catch return current;
    node.* = .{ .left = current, .right = next };
    return .{ .pipe = node };
}

fn skipPSpaces(p: *Parser) void {
    while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t' or p.src[p.pos] == '\n')) p.pos += 1;
}

fn matchKw(p: *Parser, kw: []const u8) bool {
    if (p.pos + kw.len > p.src.len) return false;
    if (!std.mem.eql(u8, p.src[p.pos .. p.pos + kw.len], kw)) return false;
    if (p.pos + kw.len < p.src.len and isIdentCont(p.src[p.pos + kw.len])) return false;
    p.pos += kw.len;
    return true;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn parseBuiltinCall(p: *Parser, builtin_name: BuiltinName) anyerror!Filter {
    skipPSpaces(p);
    var args: std.ArrayList(Filter) = .empty;
    if (p.pos < p.src.len and p.src[p.pos] == '(') {
        p.pos += 1;
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] != ')') {
            const a = try parseFilter(p);
            try args.append(p.arena, a);
            while (true) {
                skipPSpaces(p);
                if (p.pos >= p.src.len or p.src[p.pos] != ';') break;
                p.pos += 1;
                const a2 = try parseFilter(p);
                try args.append(p.arena, a2);
            }
        }
        skipPSpaces(p);
        if (p.pos < p.src.len and p.src[p.pos] == ')') p.pos += 1;
    }
    return .{ .builtin = .{ .name = builtin_name, .args = try args.toOwnedSlice(p.arena) } };
}

fn parsePipeNoComma(p: *Parser) anyerror!Filter {
    var left = try parseBinopRel(p);
    skipPSpaces(p);
    while (p.pos < p.src.len and p.src[p.pos] == '|') {
        p.pos += 1;
        skipPSpaces(p);
        const right = try parseBinopRel(p);
        const node = try p.arena.create(PipeFilter);
        node.* = .{ .left = left, .right = right };
        left = .{ .pipe = node };
        skipPSpaces(p);
    }
    return left;
}

fn parseIfThenElse(p: *Parser) anyerror!Filter {
    skipPSpaces(p);
    const cond = try parseFilter(p);
    skipPSpaces(p);
    if (!matchKw(p, "then")) return error.MissingThen;
    const then_branch = try parseFilter(p);
    skipPSpaces(p);
    var else_branch: Filter = .identity;
    if (matchKw(p, "else")) {
        else_branch = try parseFilter(p);
        skipPSpaces(p);
    }
    _ = matchKw(p, "end");
    const node = try p.arena.create(IfThenElse);
    node.* = .{ .cond = cond, .then_ = then_branch, .else_ = else_branch };
    return .{ .if_then_else = node };
}

// ---------- JSON parser ----------

const JsonParser = struct { src: []const u8, pos: usize, arena: std.mem.Allocator };

fn parseJson(jp: *JsonParser) anyerror!Value {
    skipWs(jp);
    if (jp.pos >= jp.src.len) return error.UnexpectedEof;
    const c = jp.src[jp.pos];
    if (c == 'n') {
        if (matchLit(jp, "null")) return .null;
        return error.BadJson;
    }
    if (c == 't') {
        if (matchLit(jp, "true")) return .{ .bool = true };
        return error.BadJson;
    }
    if (c == 'f') {
        if (matchLit(jp, "false")) return .{ .bool = false };
        return error.BadJson;
    }
    if (c == '"') return parseJsonString(jp);
    if (c == '[') return parseJsonArr(jp);
    if (c == '{') return parseJsonObj(jp);
    if (c == '-' or (c >= '0' and c <= '9')) return parseJsonNum(jp);
    return error.BadJson;
}

fn parseJsonString(jp: *JsonParser) !Value {
    jp.pos += 1;
    var out: std.ArrayList(u8) = .empty;
    while (jp.pos < jp.src.len) {
        const c = jp.src[jp.pos];
        if (c == '"') {
            jp.pos += 1;
            return .{ .str = try out.toOwnedSlice(jp.arena) };
        }
        if (c == '\\' and jp.pos + 1 < jp.src.len) {
            jp.pos += 1;
            const esc = jp.src[jp.pos];
            jp.pos += 1;
            switch (esc) {
                '"' => try out.append(jp.arena, '"'),
                '\\' => try out.append(jp.arena, '\\'),
                '/' => try out.append(jp.arena, '/'),
                'n' => try out.append(jp.arena, '\n'),
                't' => try out.append(jp.arena, '\t'),
                'r' => try out.append(jp.arena, '\r'),
                'b' => try out.append(jp.arena, 0x08),
                'f' => try out.append(jp.arena, 0x0C),
                else => try out.append(jp.arena, esc),
            }
        } else {
            try out.append(jp.arena, c);
            jp.pos += 1;
        }
    }
    return error.UnterminatedString;
}

fn parseJsonNum(jp: *JsonParser) !Value {
    const start = jp.pos;
    if (jp.src[jp.pos] == '-') jp.pos += 1;
    while (jp.pos < jp.src.len and (jp.src[jp.pos] >= '0' and jp.src[jp.pos] <= '9' or jp.src[jp.pos] == '.' or jp.src[jp.pos] == 'e' or jp.src[jp.pos] == 'E' or jp.src[jp.pos] == '+' or jp.src[jp.pos] == '-')) jp.pos += 1;
    const n = std.fmt.parseFloat(f64, jp.src[start..jp.pos]) catch 0;
    return .{ .num = n };
}

fn parseJsonArr(jp: *JsonParser) anyerror!Value {
    jp.pos += 1;
    var arr: std.ArrayList(Value) = .empty;
    skipWs(jp);
    if (jp.pos < jp.src.len and jp.src[jp.pos] == ']') {
        jp.pos += 1;
        return .{ .arr = try arr.toOwnedSlice(jp.arena) };
    }
    while (jp.pos < jp.src.len) {
        const v = try parseJson(jp);
        try arr.append(jp.arena, v);
        skipWs(jp);
        if (jp.pos < jp.src.len and jp.src[jp.pos] == ',') {
            jp.pos += 1;
            skipWs(jp);
            continue;
        }
        if (jp.pos < jp.src.len and jp.src[jp.pos] == ']') {
            jp.pos += 1;
            return .{ .arr = try arr.toOwnedSlice(jp.arena) };
        }
        return error.BadJson;
    }
    return error.BadJson;
}

fn parseJsonObj(jp: *JsonParser) anyerror!Value {
    jp.pos += 1;
    var obj: std.ArrayList(ObjectField) = .empty;
    skipWs(jp);
    if (jp.pos < jp.src.len and jp.src[jp.pos] == '}') {
        jp.pos += 1;
        return .{ .obj = try obj.toOwnedSlice(jp.arena) };
    }
    while (jp.pos < jp.src.len) {
        skipWs(jp);
        if (jp.pos >= jp.src.len or jp.src[jp.pos] != '"') return error.BadJson;
        const key_v = try parseJsonString(jp);
        skipWs(jp);
        if (jp.pos >= jp.src.len or jp.src[jp.pos] != ':') return error.BadJson;
        jp.pos += 1;
        const v = try parseJson(jp);
        try obj.append(jp.arena, .{ .key = key_v.str, .val = v });
        skipWs(jp);
        if (jp.pos < jp.src.len and jp.src[jp.pos] == ',') {
            jp.pos += 1;
            skipWs(jp);
            continue;
        }
        if (jp.pos < jp.src.len and jp.src[jp.pos] == '}') {
            jp.pos += 1;
            return .{ .obj = try obj.toOwnedSlice(jp.arena) };
        }
        return error.BadJson;
    }
    return error.BadJson;
}

fn skipWs(jp: *JsonParser) void {
    while (jp.pos < jp.src.len and (jp.src[jp.pos] == ' ' or jp.src[jp.pos] == '\t' or jp.src[jp.pos] == '\n' or jp.src[jp.pos] == '\r')) jp.pos += 1;
}

fn matchLit(jp: *JsonParser, kw: []const u8) bool {
    if (jp.pos + kw.len > jp.src.len) return false;
    if (!std.mem.eql(u8, jp.src[jp.pos .. jp.pos + kw.len], kw)) return false;
    jp.pos += kw.len;
    return true;
}
