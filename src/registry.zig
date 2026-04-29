//! Comptime applet registry.
//!
//! Walks `applets/all.zig` at compile time and builds a flat `[]const Applet`
//! filtered by the build option `active_applets` (set from the chosen preset
//! or the `-Dapplets=` override). Excluded applets are not referenced and so
//! get dead-code-eliminated.

const std = @import("std");
const build_options = @import("build_options");
const all = @import("applets/all.zig");
const Context = @import("common/context.zig");

pub const RunFn = *const fn (*Context, []const [:0]const u8) anyerror!u8;

pub const Applet = struct {
    name: []const u8,
    aliases: []const []const u8,
    help: []const u8,
    run: RunFn,
};

pub const APPLETS: []const Applet = blk: {
    @setEvalBranchQuota(100000);
    var list: []const Applet = &.{};
    for (@typeInfo(all).@"struct".decls) |decl| {
        const mod = @field(all, decl.name);
        if (containsName(build_options.active_applets, mod.name)) {
            list = list ++ &[_]Applet{.{
                .name = mod.name,
                .aliases = mod.aliases,
                .help = mod.help,
                .run = mod.run,
            }};
        }
    }
    break :blk list;
};

pub fn find(query: []const u8) ?*const Applet {
    for (APPLETS) |*applet| {
        if (std.mem.eql(u8, applet.name, query)) return applet;
        for (applet.aliases) |alias| {
            if (std.mem.eql(u8, alias, query)) return applet;
        }
    }
    return null;
}

fn containsName(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| if (std.mem.eql(u8, s, needle)) return true;
    return false;
}
