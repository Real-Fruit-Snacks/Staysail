//! A small POSIX-flavoured regex matcher built on backtracking. Supports the
//! Extended Regular Expression (ERE) subset used by `grep -E`, `sed -E`,
//! and `awk`. Compiled once per pattern; matching is O(n*m) worst case.
//!
//! Supported syntax:
//!   .          any byte except newline
//!   x          literal byte
//!   \d \D \w \W \s \S    Perl-like character classes
//!   \n \t \r \\ \/        common escapes
//!   [abc]      character class; ranges with `-`; leading `^` negates
//!   ^  $       anchors (start/end of string; multiline isn't on)
//!   x*  x+  x?  greedy quantifiers
//!   x{n}  x{n,}  x{n,m}    counted repetition
//!   (...)      grouping (no capture-storage yet — used for grouping only)
//!   a|b        alternation
//!
//! Not supported (yet):
//!   capture groups (text), backreferences, lookarounds, named classes
//!   like [:alpha:], lazy `*?`/`+?`/`??`, multiline mode.

const std = @import("std");

pub const Pattern = struct {
    nodes: []Node,
    case_insensitive: bool,
    arena: std.mem.Allocator,

    pub fn matches(self: *const Pattern, haystack: []const u8) bool {
        // Search every position unless the pattern is anchored.
        if (self.nodes.len > 0 and self.nodes[0] == .anchor_start) {
            return matchAt(self.nodes, 1, haystack, 0, self.case_insensitive);
        }
        var i: usize = 0;
        while (i <= haystack.len) : (i += 1) {
            if (matchAt(self.nodes, 0, haystack, i, self.case_insensitive)) return true;
        }
        return false;
    }

    /// Returns the start..end byte range of the first match, or null.
    pub fn find(self: *const Pattern, haystack: []const u8) ?[2]usize {
        if (self.nodes.len > 0 and self.nodes[0] == .anchor_start) {
            const m = matchLenAt(self.nodes, 1, haystack, 0, self.case_insensitive);
            if (m) |len| return .{ 0, len };
            return null;
        }
        var i: usize = 0;
        while (i <= haystack.len) : (i += 1) {
            const m = matchLenAt(self.nodes, 0, haystack, i, self.case_insensitive);
            if (m) |len| return .{ i, i + len };
        }
        return null;
    }
};

pub const CompileError = error{
    UnclosedClass,
    UnclosedGroup,
    InvalidEscape,
    InvalidRepeat,
    DanglingQuantifier,
    OutOfMemory,
};

pub const CompileOptions = struct {
    case_insensitive: bool = false,
    /// Interpret the pattern as a literal string (no metacharacters).
    literal: bool = false,
};

pub fn compile(arena: std.mem.Allocator, pattern: []const u8, opts: CompileOptions) CompileError!Pattern {
    if (opts.literal) {
        var out: std.ArrayList(Node) = .empty;
        for (pattern) |c| try out.append(arena, .{ .lit = c });
        return .{ .nodes = try out.toOwnedSlice(arena), .case_insensitive = opts.case_insensitive, .arena = arena };
    }
    var p: Parser = .{ .src = pattern, .pos = 0, .arena = arena };
    const nodes = try parseAlt(&p);
    return .{ .nodes = nodes, .case_insensitive = opts.case_insensitive, .arena = arena };
}

// ---------- node types ----------

pub const Node = union(enum) {
    lit: u8,
    any,
    class: CharClass,
    anchor_start,
    anchor_end,
    star: Sub,
    plus: Sub,
    question: Sub,
    repeat: Repeat,
    alt: Alt,
    group: Group,

    pub const Sub = struct { nodes: []Node };
    pub const Repeat = struct { nodes: []Node, min: u32, max: u32 };
    pub const Alt = struct { branches: [][]Node };
    pub const Group = struct { nodes: []Node };
};

pub const CharClass = struct {
    bits: [32]u8 = .{0} ** 32,
    negated: bool = false,

    pub fn add(self: *CharClass, c: u8) void {
        self.bits[c / 8] |= @as(u8, 1) << @as(u3, @intCast(c % 8));
    }

    pub fn addRange(self: *CharClass, lo: u8, hi: u8) void {
        var c: u16 = lo;
        while (c <= hi) : (c += 1) self.add(@intCast(c));
    }

    pub fn contains(self: *const CharClass, c: u8) bool {
        const has = (self.bits[c / 8] >> @as(u3, @intCast(c % 8))) & 1 != 0;
        return if (self.negated) !has else has;
    }
};

// ---------- compiler ----------

const Parser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
};

fn parseAlt(p: *Parser) CompileError![]Node {
    const first = try parseConcat(p);
    if (p.pos >= p.src.len or p.src[p.pos] != '|') {
        return first;
    }
    var branches: std.ArrayList([]Node) = .empty;
    try branches.append(p.arena, first);
    while (p.pos < p.src.len and p.src[p.pos] == '|') {
        p.pos += 1;
        const next = try parseConcat(p);
        try branches.append(p.arena, next);
    }
    var single: std.ArrayList(Node) = .empty;
    try single.append(p.arena, .{ .alt = .{ .branches = try branches.toOwnedSlice(p.arena) } });
    return try single.toOwnedSlice(p.arena);
}

fn parseConcat(p: *Parser) CompileError![]Node {
    var nodes: std.ArrayList(Node) = .empty;
    while (p.pos < p.src.len) {
        const c = p.src[p.pos];
        if (c == '|' or c == ')') break;
        const node = try parseAtom(p);
        // Apply quantifier if present.
        if (p.pos < p.src.len) {
            const q = p.src[p.pos];
            if (q == '*' or q == '+' or q == '?') {
                p.pos += 1;
                var sub: std.ArrayList(Node) = .empty;
                try sub.append(p.arena, node);
                const sub_slice = try sub.toOwnedSlice(p.arena);
                const wrapped: Node = switch (q) {
                    '*' => .{ .star = .{ .nodes = sub_slice } },
                    '+' => .{ .plus = .{ .nodes = sub_slice } },
                    '?' => .{ .question = .{ .nodes = sub_slice } },
                    else => unreachable,
                };
                try nodes.append(p.arena, wrapped);
                continue;
            }
            if (q == '{') {
                p.pos += 1;
                const min, const max = try parseRepeatRange(p);
                if (p.pos >= p.src.len or p.src[p.pos] != '}') return error.InvalidRepeat;
                p.pos += 1;
                var sub: std.ArrayList(Node) = .empty;
                try sub.append(p.arena, node);
                try nodes.append(p.arena, .{ .repeat = .{ .nodes = try sub.toOwnedSlice(p.arena), .min = min, .max = max } });
                continue;
            }
        }
        try nodes.append(p.arena, node);
    }
    return nodes.toOwnedSlice(p.arena);
}

fn parseRepeatRange(p: *Parser) CompileError!struct { u32, u32 } {
    const min = try readUint(p);
    var max = min;
    if (p.pos < p.src.len and p.src[p.pos] == ',') {
        p.pos += 1;
        if (p.pos < p.src.len and p.src[p.pos] == '}') {
            max = std.math.maxInt(u32);
        } else {
            max = try readUint(p);
        }
    }
    return .{ min, max };
}

fn readUint(p: *Parser) CompileError!u32 {
    var n: u32 = 0;
    var any = false;
    while (p.pos < p.src.len and p.src[p.pos] >= '0' and p.src[p.pos] <= '9') {
        n = n * 10 + (p.src[p.pos] - '0');
        p.pos += 1;
        any = true;
    }
    if (!any) return error.InvalidRepeat;
    return n;
}

fn parseAtom(p: *Parser) CompileError!Node {
    const c = p.src[p.pos];
    if (c == '(') {
        p.pos += 1;
        const inner = try parseAlt(p);
        if (p.pos >= p.src.len or p.src[p.pos] != ')') return error.UnclosedGroup;
        p.pos += 1;
        return .{ .group = .{ .nodes = inner } };
    }
    if (c == '[') {
        return parseClass(p);
    }
    if (c == '.') {
        p.pos += 1;
        return .any;
    }
    if (c == '^') {
        p.pos += 1;
        return .anchor_start;
    }
    if (c == '$') {
        p.pos += 1;
        return .anchor_end;
    }
    if (c == '\\') {
        return parseEscape(p);
    }
    if (c == '*' or c == '+' or c == '?' or c == '{' or c == '|' or c == ')') {
        return error.DanglingQuantifier;
    }
    p.pos += 1;
    return .{ .lit = c };
}

fn parseEscape(p: *Parser) CompileError!Node {
    p.pos += 1;
    if (p.pos >= p.src.len) return error.InvalidEscape;
    const e = p.src[p.pos];
    p.pos += 1;
    return switch (e) {
        'n' => .{ .lit = '\n' },
        't' => .{ .lit = '\t' },
        'r' => .{ .lit = '\r' },
        '\\' => .{ .lit = '\\' },
        '/' => .{ .lit = '/' },
        '.' => .{ .lit = '.' },
        '*' => .{ .lit = '*' },
        '+' => .{ .lit = '+' },
        '?' => .{ .lit = '?' },
        '|' => .{ .lit = '|' },
        '(' => .{ .lit = '(' },
        ')' => .{ .lit = ')' },
        '[' => .{ .lit = '[' },
        ']' => .{ .lit = ']' },
        '{' => .{ .lit = '{' },
        '}' => .{ .lit = '}' },
        '^' => .{ .lit = '^' },
        '$' => .{ .lit = '$' },
        ' ' => .{ .lit = ' ' },
        '"' => .{ .lit = '"' },
        '\'' => .{ .lit = '\'' },
        'd' => buildClass(p, "0123456789", false),
        'D' => buildClass(p, "0123456789", true),
        'w' => buildClass(p, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_", false),
        'W' => buildClass(p, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_", true),
        's' => buildClass(p, " \t\r\n\x0B\x0C", false),
        'S' => buildClass(p, " \t\r\n\x0B\x0C", true),
        else => .{ .lit = e },
    };
}

fn buildClass(_: *Parser, chars: []const u8, neg: bool) Node {
    var class: CharClass = .{ .negated = neg };
    for (chars) |c| class.add(c);
    return .{ .class = class };
}

fn parseClass(p: *Parser) CompileError!Node {
    p.pos += 1; // consume `[`
    var class: CharClass = .{};
    if (p.pos < p.src.len and p.src[p.pos] == '^') {
        class.negated = true;
        p.pos += 1;
    }
    var first = true;
    while (p.pos < p.src.len) {
        const c = p.src[p.pos];
        if (c == ']' and !first) {
            p.pos += 1;
            return .{ .class = class };
        }
        first = false;
        var lo: u8 = c;
        if (c == '\\' and p.pos + 1 < p.src.len) {
            p.pos += 1;
            const esc = p.src[p.pos];
            lo = switch (esc) {
                'n' => '\n',
                't' => '\t',
                'r' => '\r',
                else => esc,
            };
        }
        p.pos += 1;
        if (p.pos + 1 < p.src.len and p.src[p.pos] == '-' and p.src[p.pos + 1] != ']') {
            p.pos += 1;
            var hi = p.src[p.pos];
            if (hi == '\\' and p.pos + 1 < p.src.len) {
                p.pos += 1;
                hi = p.src[p.pos];
            }
            p.pos += 1;
            class.addRange(lo, hi);
        } else {
            class.add(lo);
        }
    }
    return error.UnclosedClass;
}

// ---------- matcher (backtracking) ----------

fn matchAt(nodes: []const Node, ni: usize, hay: []const u8, hi: usize, ic: bool) bool {
    return matchLenAt(nodes, ni, hay, hi, ic) != null;
}

/// Returns the length of the match in haystack from `hi`, or null.
fn matchLenAt(nodes: []const Node, ni: usize, hay: []const u8, hi: usize, ic: bool) ?usize {
    if (ni >= nodes.len) return hi - hi; // 0 length
    const node = nodes[ni];
    switch (node) {
        .lit => |c| {
            if (hi >= hay.len) return null;
            if (!charEq(hay[hi], c, ic)) return null;
            const sub = matchLenAt(nodes, ni + 1, hay, hi + 1, ic) orelse return null;
            return 1 + sub;
        },
        .any => {
            if (hi >= hay.len or hay[hi] == '\n') return null;
            const sub = matchLenAt(nodes, ni + 1, hay, hi + 1, ic) orelse return null;
            return 1 + sub;
        },
        .class => |class| {
            if (hi >= hay.len) return null;
            if (!classMatch(class, hay[hi], ic)) return null;
            const sub = matchLenAt(nodes, ni + 1, hay, hi + 1, ic) orelse return null;
            return 1 + sub;
        },
        .anchor_start => {
            if (hi != 0) return null;
            return matchLenAt(nodes, ni + 1, hay, hi, ic);
        },
        .anchor_end => {
            if (hi != hay.len) return null;
            return matchLenAt(nodes, ni + 1, hay, hi, ic);
        },
        .star => |s| return matchRepeat(s.nodes, 0, std.math.maxInt(u32), nodes, ni + 1, hay, hi, ic),
        .plus => |s| return matchRepeat(s.nodes, 1, std.math.maxInt(u32), nodes, ni + 1, hay, hi, ic),
        .question => |s| return matchRepeat(s.nodes, 0, 1, nodes, ni + 1, hay, hi, ic),
        .repeat => |r| return matchRepeat(r.nodes, r.min, r.max, nodes, ni + 1, hay, hi, ic),
        .alt => |alt| {
            for (alt.branches) |branch| {
                if (matchLenAt(branch, 0, hay, hi, ic)) |len| {
                    const sub = matchLenAt(nodes, ni + 1, hay, hi + len, ic) orelse continue;
                    return len + sub;
                }
            }
            return null;
        },
        .group => |g| {
            if (matchLenAt(g.nodes, 0, hay, hi, ic)) |len| {
                const sub = matchLenAt(nodes, ni + 1, hay, hi + len, ic) orelse return null;
                return len + sub;
            }
            return null;
        },
    }
}

fn matchRepeat(sub: []const Node, min: u32, max: u32, rest: []const Node, ri: usize, hay: []const u8, hi: usize, ic: bool) ?usize {
    // Greedy: match as many as possible, then back off.
    var positions: [64]usize = undefined;
    var positions_len: usize = 0;
    positions[positions_len] = hi;
    positions_len += 1;
    var pos = hi;
    var n: u32 = 0;
    while (n < max and positions_len < positions.len) : (n += 1) {
        const sub_len = matchLenAt(sub, 0, hay, pos, ic) orelse break;
        if (sub_len == 0) break; // avoid infinite loop on zero-width
        pos += sub_len;
        positions[positions_len] = pos;
        positions_len += 1;
    }
    // Try positions from longest match down to min.
    while (positions_len > 0) {
        const last_pos = positions[positions_len - 1];
        const matched_count: u32 = @intCast(positions_len - 1);
        if (matched_count >= min) {
            if (matchLenAt(rest, ri, hay, last_pos, ic)) |sub_len| {
                return last_pos - hi + sub_len;
            }
        }
        positions_len -= 1;
    }
    return null;
}

fn charEq(a: u8, b: u8, ic: bool) bool {
    if (!ic) return a == b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn classMatch(class: CharClass, c: u8, ic: bool) bool {
    if (!ic) return class.contains(c);
    return class.contains(std.ascii.toLower(c)) or class.contains(std.ascii.toUpper(c));
}

// ---------- tests ----------

test "regex: literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), "abc", .{});
    try std.testing.expect(re.matches("xabcx"));
    try std.testing.expect(!re.matches("abx"));
}

test "regex: any + class + alt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), "[abc]+|x.y", .{});
    try std.testing.expect(re.matches("zzaaa"));
    try std.testing.expect(re.matches("xqy"));
    try std.testing.expect(!re.matches("nope"));
}

test "regex: anchors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), "^foo", .{});
    try std.testing.expect(re.matches("foo bar"));
    try std.testing.expect(!re.matches("bar foo"));
}

test "regex: case insensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const re = try compile(arena.allocator(), "hello", .{ .case_insensitive = true });
    try std.testing.expect(re.matches("HELLO"));
    try std.testing.expect(re.matches("HellO"));
}
