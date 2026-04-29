const std = @import("std");
const builtin = @import("builtin");
const Context = @import("../common/context.zig");
const build_options = @import("build_options");

pub const name: []const u8 = "update";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: update [OPTION]...
    \\
    \\Self-update from the latest GitHub release.
    \\
    \\  --check          only check for updates; don't download
    \\  --force          re-download even if version matches
    \\  --repo OWNER/NAME   override the GitHub repo (default: Real-Fruit-Snacks/Staysail)
    \\      --help       display this help and exit
    \\
    \\The current binary is replaced atomically; the previous version is kept
    \\next to it as <name>.old.
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    var check_only = false;
    var force = false;
    var repo: []const u8 = "Real-Fruit-Snacks/Staysail";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            try ctx.stdout.writeAll(help);
            return 0;
        } else if (std.mem.eql(u8, a, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            force = true;
        } else if (std.mem.eql(u8, a, "--repo")) {
            i += 1;
            if (i >= args.len) return 2;
            repo = args[i];
        }
    }

    // Query the latest release tag.
    const api_url = try std.fmt.allocPrint(ctx.arena, "https://api.github.com/repos/{s}/releases/latest", .{repo});

    var client: std.http.Client = .{ .allocator = ctx.gpa, .io = ctx.io };
    defer client.deinit();

    const meta_buf = try ctx.arena.alloc(u8, 64 * 1024);
    var meta_writer = std.Io.Writer.fixed(meta_buf);

    const meta_result = client.fetch(.{
        .location = .{ .url = api_url },
        .response_writer = &meta_writer,
        .extra_headers = &.{
            .{ .name = "Accept", .value = "application/vnd.github.v3+json" },
            .{ .name = "User-Agent", .value = "staysail-update" },
        },
    }) catch |e| {
        ctx.err("cannot reach GitHub API: {s}", .{@errorName(e)});
        return 1;
    };
    if (@intFromEnum(meta_result.status) >= 400) {
        ctx.err("GitHub API returned status {d}", .{@intFromEnum(meta_result.status)});
        return 1;
    }

    const tag = extractField(meta_writer.buffered(), "\"tag_name\":\"") orelse {
        ctx.err("could not parse latest release tag from response", .{});
        return 1;
    };

    const current = build_options.version;
    try ctx.stdout.print("current: {s}\nlatest:  {s}\n", .{ current, tag });

    const stripped = if (tag.len > 0 and tag[0] == 'v') tag[1..] else tag;
    if (!force and std.mem.eql(u8, stripped, current)) {
        try ctx.stdout.writeAll("already up to date\n");
        return 0;
    }
    if (check_only) {
        try ctx.stdout.print("update available: {s} -> {s}\n", .{ current, stripped });
        return 0;
    }

    // Pick the asset for our platform.
    const asset_name = try platformAssetName(ctx.arena);
    try ctx.stdout.print("downloading {s} ...\n", .{asset_name});

    const asset_url = try std.fmt.allocPrint(ctx.arena, "https://github.com/{s}/releases/download/{s}/{s}", .{ repo, tag, asset_name });

    // Locate the running binary.
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(ctx.io, &exe_buf) catch |e| {
        ctx.err("cannot determine executable path: {s}", .{@errorName(e)});
        return 1;
    };
    const exe_path = exe_buf[0..exe_len];

    // Download to a sibling .new path.
    const new_path = try std.mem.concat(ctx.arena, u8, &.{ exe_path, ".new" });
    const cwd = std.Io.Dir.cwd();
    const out_file = cwd.createFile(ctx.io, new_path, .{}) catch |e| {
        ctx.err("cannot create '{s}': {s}", .{ new_path, @errorName(e) });
        return 1;
    };
    defer out_file.close(ctx.io);
    var dl_buf: [16 * 1024]u8 = undefined;
    var fw: std.Io.File.Writer = .initStreaming(out_file, ctx.io, &dl_buf);

    const dl_result = client.fetch(.{
        .location = .{ .url = asset_url },
        .response_writer = &fw.interface,
        .extra_headers = &.{
            .{ .name = "User-Agent", .value = "staysail-update" },
        },
    }) catch |e| {
        ctx.err("download failed: {s}", .{@errorName(e)});
        return 1;
    };
    try fw.interface.flush();

    if (@intFromEnum(dl_result.status) >= 400) {
        ctx.err("download status {d} for {s}", .{ @intFromEnum(dl_result.status), asset_url });
        return 1;
    }

    // Move current to .old, replace with .new.
    const old_path = try std.mem.concat(ctx.arena, u8, &.{ exe_path, ".old" });
    cwd.deleteFile(ctx.io, old_path) catch {};
    cwd.rename(exe_path, cwd, old_path, ctx.io) catch |e| {
        ctx.err("cannot move current binary to '{s}': {s}", .{ old_path, @errorName(e) });
        return 1;
    };
    cwd.rename(new_path, cwd, exe_path, ctx.io) catch |e| {
        ctx.err("cannot move new binary into place: {s}", .{@errorName(e)});
        // Try to roll back.
        cwd.rename(old_path, cwd, exe_path, ctx.io) catch {};
        return 1;
    };

    try ctx.stdout.print("updated to {s} ({s} kept as backup)\n", .{ stripped, old_path });
    return 0;
}

fn extractField(json: []const u8, key: []const u8) ?[]const u8 {
    const start_marker = std.mem.indexOf(u8, json, key) orelse return null;
    const value_start = start_marker + key.len;
    const value_end = std.mem.indexOfScalarPos(u8, json, value_start, '"') orelse return null;
    return json[value_start..value_end];
}

fn platformAssetName(arena: std.mem.Allocator) ![]const u8 {
    const os_part = switch (builtin.os.tag) {
        .linux => "linux",
        .windows => "windows",
        .macos => "macos",
        else => "unknown",
    };
    const arch_part = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "arm64",
        else => "unknown",
    };
    const ext = if (builtin.os.tag == .windows) ".exe" else "";
    return std.fmt.allocPrint(arena, "staysail-{s}-{s}{s}", .{ os_part, arch_part, ext });
}
