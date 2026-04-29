//! Entry point and dispatcher.
//!
//! Two dispatch modes:
//!   1. Multi-call: `argv[0]` basename matches an applet name/alias.
//!   2. Subcommand: `argv[1]` names the applet, args follow.
//!
//! Global flags (subcommand mode only): --list, --version, --help.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const registry = @import("registry.zig");
const Context = @import("common/context.zig");

const STDIO_BUF = 16 * 1024;
const STDERR_BUF = 4 * 1024;

pub fn main(init: std.process.Init) !void {
    const code = dispatch(init) catch |e| {
        var sbuf: [512]u8 = undefined;
        var sw: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &sbuf);
        sw.interface.print("staysail: fatal: {s}\n", .{@errorName(e)}) catch {};
        sw.interface.flush() catch {};
        std.process.exit(1);
    };
    if (code != 0) std.process.exit(code);
}

fn dispatch(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var stdout_buf: [STDIO_BUF]u8 = undefined;
    var stderr_buf: [STDERR_BUF]u8 = undefined;
    var stdin_buf: [STDIO_BUF]u8 = undefined;

    // Stdio is always streaming (pipes/terminals don't support positional I/O).
    var stdout_fw: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &stdout_buf);
    var stderr_fw: std.Io.File.Writer = .initStreaming(.stderr(), init.io, &stderr_buf);
    var stdin_fr: std.Io.File.Reader = .initStreaming(.stdin(), init.io, &stdin_buf);

    defer {
        stdout_fw.interface.flush() catch {};
        stderr_fw.interface.flush() catch {};
    }

    if (argv.len == 0) {
        try writeUsage(&stderr_fw.interface);
        return 1;
    }

    const argv0 = std.fs.path.basename(argv[0]);
    const argv0_stripped = stripExeSuffix(argv0);

    // Multi-call mode: argv[0] basename matches an applet.
    if (!std.mem.eql(u8, argv0_stripped, "staysail")) {
        if (registry.find(argv0_stripped)) |applet| {
            return runApplet(init, arena, applet, argv0_stripped, argv[1..], &stdout_fw, &stderr_fw, &stdin_fr);
        }
    }

    // Subcommand mode (or global flag).
    if (argv.len < 2) {
        try writeUsage(&stdout_fw.interface);
        return 0;
    }

    const sub = argv[1];
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h")) {
        try writeUsage(&stdout_fw.interface);
        return 0;
    }
    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-V")) {
        try stdout_fw.interface.print("staysail {s}\n", .{build_options.version});
        return 0;
    }
    if (std.mem.eql(u8, sub, "--list")) {
        return listApplets(&stdout_fw.interface);
    }

    if (registry.find(sub)) |applet| {
        if (argv.len >= 3 and std.mem.eql(u8, argv[2], "--help")) {
            try stdout_fw.interface.writeAll(applet.help);
            return 0;
        }
        return runApplet(init, arena, applet, sub, argv[2..], &stdout_fw, &stderr_fw, &stdin_fr);
    }

    try stderr_fw.interface.print("staysail: unknown applet '{s}'\n", .{sub});
    try stderr_fw.interface.print("Try 'staysail --list' for available applets.\n", .{});
    return 1;
}

fn runApplet(
    init: std.process.Init,
    arena: std.mem.Allocator,
    applet: *const registry.Applet,
    invoked_as: []const u8,
    args: []const [:0]const u8,
    stdout_fw: *std.Io.File.Writer,
    stderr_fw: *std.Io.File.Writer,
    stdin_fr: *std.Io.File.Reader,
) !u8 {
    var ctx: Context = .{
        .io = init.io,
        .arena = arena,
        .gpa = init.gpa,
        .stdout = &stdout_fw.interface,
        .stderr = &stderr_fw.interface,
        .stdin = &stdin_fr.interface,
        .environ = init.environ_map,
        .invoked_as = invoked_as,
    };
    return applet.run(&ctx, args);
}

fn listApplets(w: *std.Io.Writer) !u8 {
    try w.print("staysail {s} \xe2\x80\x94 preset: {s}, applets: {d}\n\n", .{
        build_options.version,
        build_options.preset_name,
        registry.APPLETS.len,
    });
    for (registry.APPLETS) |applet| {
        try w.print("  {s}", .{applet.name});
        if (applet.aliases.len > 0) {
            try w.writeAll(" (aliases: ");
            for (applet.aliases, 0..) |alias, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll(alias);
            }
            try w.writeByte(')');
        }
        try w.writeByte('\n');
    }
    return 0;
}

fn writeUsage(w: *std.Io.Writer) !void {
    try w.print(
        \\staysail {s} - multi-call binary, {d} applets ({s} preset)
        \\
        \\Usage: staysail <applet> [args...]
        \\       staysail --list                 list available applets
        \\       staysail --version              print version
        \\       staysail --help                 show this help
        \\       staysail <applet> --help        show applet help
        \\
        \\When invoked via a name matching an applet (e.g. via symlink or hardlink),
        \\that applet runs directly. Example:
        \\       ln -s staysail cat && ./cat README.md
        \\
        \\
    , .{
        build_options.version,
        registry.APPLETS.len,
        build_options.preset_name,
    });
}

fn stripExeSuffix(s: []const u8) []const u8 {
    if (builtin.os.tag == .windows and s.len > 4) {
        const tail = s[s.len - 4 ..];
        var lower: [4]u8 = undefined;
        for (tail, 0..) |c, i| lower[i] = std.ascii.toLower(c);
        if (std.mem.eql(u8, &lower, ".exe")) return s[0 .. s.len - 4];
    }
    return s;
}
