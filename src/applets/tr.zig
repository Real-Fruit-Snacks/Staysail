const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "tr";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: tr [OPTION]... SET1 [SET2]
    \\
    \\Translate, squeeze, or delete characters from standard input,
    \\writing to standard output.
    \\
    \\  -c, --complement   use the complement of SET1
    \\  -d, --delete       delete characters in SET1, do not translate
    \\  -s, --squeeze-repeats  replace each input sequence of a repeated
    \\                         character that is listed in SET1 with a single
    \\                         occurrence of that character
    \\      --help         display this help and exit
    \\
    \\Supported escape sequences in SETs:
    \\  \\\\  backslash    \\a  alert    \\b  backspace
    \\  \\f  form feed    \\n  newline  \\r  carriage return
    \\  \\t  horizontal tab  \\v  vertical tab
    \\  \\NNN character with octal value NNN (1 to 3 octal digits)
    \\  CHAR1-CHAR2   all characters from CHAR1 to CHAR2 in ascending order
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var complement = false;
    var delete = false;
    var squeeze = false;
    var sets: std.ArrayList([:0]const u8) = .empty;
    defer sets.deinit(ctx.arena);

    for (args) |a| {
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "-c") or std.mem.eql(u8, a, "--complement")) {
            complement = true;
        } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--delete")) {
            delete = true;
        } else if (std.mem.eql(u8, a, "-s") or std.mem.eql(u8, a, "--squeeze-repeats")) {
            squeeze = true;
        } else if (a.len >= 2 and a[0] == '-' and a[1] != '-') {
            for (a[1..]) |c| switch (c) {
                'c' => complement = true,
                'd' => delete = true,
                's' => squeeze = true,
                else => {
                    ctx.usage("invalid option -- '{c}'", .{c});
                    return 2;
                },
            };
        } else {
            try sets.append(ctx.arena, a);
        }
    }

    if (sets.items.len == 0) {
        ctx.usage("missing operand", .{});
        return 2;
    }
    if (!delete and sets.items.len < 2 and !squeeze) {
        ctx.usage("missing SET2 (translation requires both)", .{});
        return 2;
    }

    const set1 = try expandSet(ctx.arena, sets.items[0]);
    var set2: []u8 = &.{};
    if (sets.items.len >= 2) set2 = try expandSet(ctx.arena, sets.items[1]);

    // Build a 256-entry mapping table or a deletion bitset.
    var translate: [256]u8 = undefined;
    for (&translate, 0..) |*t, idx| t.* = @intCast(idx);
    var in_set1: [256]bool = .{false} ** 256;
    for (set1) |b| in_set1[b] = true;
    if (complement) {
        for (&in_set1) |*v| v.* = !v.*;
    }

    if (!delete and set2.len > 0) {
        // Map set1[i] -> set2[i], or set1[i] -> set2[last] if set1 is longer.
        const last2 = set2[set2.len - 1];
        for (set1, 0..) |s, idx| {
            const target = if (idx < set2.len) set2[idx] else last2;
            translate[s] = target;
        }
    }

    var prev: ?u8 = null;
    while (true) {
        const buf = ctx.stdin.peek(1) catch |e| switch (e) {
            error.EndOfStream => return 0,
            else => return e,
        };
        const c = buf[0];
        ctx.stdin.toss(1);

        if (delete and in_set1[c]) continue;

        const out_byte = if (delete) c else translate[c];

        if (squeeze and prev != null and prev.? == out_byte and isInSqueezeSet(complement, in_set1, set1, set2, delete, c, out_byte)) {
            continue;
        }
        try ctx.stdout.writeByte(out_byte);
        prev = out_byte;
    }
}

fn isInSqueezeSet(complement: bool, in_set1: [256]bool, set1: []const u8, set2: []const u8, delete: bool, c: u8, out_byte: u8) bool {
    _ = complement;
    _ = set1;
    _ = c;
    if (delete) return in_set1[out_byte];
    if (set2.len == 0) return in_set1[out_byte];
    // Squeeze applies to chars in SET2 when translating, in SET1 otherwise.
    for (set2) |b| if (b == out_byte) return true;
    return false;
}

fn expandSet(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const c = try parseChar(s, &i);
        // Range support: CHAR1-CHAR2.
        if (i < s.len and s[i] == '-' and i + 1 < s.len) {
            i += 1; // consume '-'
            const c2 = try parseChar(s, &i);
            if (c2 < c) return error.InvalidRange;
            var b: u8 = c;
            while (true) : (b += 1) {
                try out.append(gpa, b);
                if (b == c2) break;
            }
        } else {
            try out.append(gpa, c);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn parseChar(s: []const u8, i: *usize) !u8 {
    const c = s[i.*];
    if (c != '\\') {
        i.* += 1;
        return c;
    }
    if (i.* + 1 >= s.len) {
        i.* += 1;
        return '\\';
    }
    const esc = s[i.* + 1];
    switch (esc) {
        '\\' => {
            i.* += 2;
            return '\\';
        },
        'a' => {
            i.* += 2;
            return 0x07;
        },
        'b' => {
            i.* += 2;
            return 0x08;
        },
        'f' => {
            i.* += 2;
            return 0x0C;
        },
        'n' => {
            i.* += 2;
            return '\n';
        },
        'r' => {
            i.* += 2;
            return '\r';
        },
        't' => {
            i.* += 2;
            return '\t';
        },
        'v' => {
            i.* += 2;
            return 0x0B;
        },
        '0'...'7' => {
            // Octal: 1-3 digits.
            i.* += 1;
            var val: u32 = 0;
            var n: usize = 0;
            while (n < 3 and i.* < s.len and s[i.*] >= '0' and s[i.*] <= '7') : (n += 1) {
                val = val * 8 + (s[i.*] - '0');
                i.* += 1;
            }
            if (val > 255) return error.OctalTooLarge;
            return @intCast(val);
        },
        else => {
            i.* += 2;
            return esc;
        },
    }
}
