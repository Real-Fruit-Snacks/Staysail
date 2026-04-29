const std = @import("std");
const presets = @import("build/presets.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const preset_name = b.option(
        []const u8,
        "preset",
        "Applet preset: full, slim, minimal (default: full)",
    ) orelse "full";

    const applets_csv = b.option(
        []const u8,
        "applets",
        "Comma-separated applet names (overrides --preset)",
    );

    const version = b.option(
        []const u8,
        "version",
        "Version string baked into the binary",
    ) orelse "0.0.0";

    const active_applets: []const []const u8 = if (applets_csv) |csv|
        parseCsv(b.allocator, csv)
    else
        presets.byName(preset_name) orelse {
            std.debug.print("error: unknown preset '{s}'. Valid: full, slim, minimal\n", .{preset_name});
            std.process.exit(1);
        };

    const effective_preset_name: []const u8 = if (applets_csv != null) "custom" else preset_name;

    const build_options = b.addOptions();
    build_options.addOption([]const []const u8, "active_applets", active_applets);
    build_options.addOption([]const u8, "preset_name", effective_preset_name);
    build_options.addOption([]const u8, "version", version);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", build_options);

    const exe = b.addExecutable(.{
        .name = "staysail",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    // `zig build run -- <args>` for ad-hoc invocations.
    const run_step = b.step("run", "Run staysail");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs unit tests embedded in source files.
    const test_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .root_module = exe_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // `zig build check` is a fast typecheck without producing an artifact.
    const check_step = b.step("check", "Typecheck without producing a binary");
    const check_exe = b.addExecutable(.{
        .name = "staysail-check",
        .root_module = exe_module,
    });
    check_step.dependOn(&check_exe.step);
}

fn parseCsv(allocator: std.mem.Allocator, csv: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        list.append(allocator, allocator.dupe(u8, trimmed) catch @panic("OOM")) catch @panic("OOM");
    }
    return list.toOwnedSlice(allocator) catch @panic("OOM");
}
