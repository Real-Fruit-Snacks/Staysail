//! Per-invocation context handed to every applet's `run` function.
//!
//! Bundles the I/O instance, allocators, and pre-initialized stdio writers/readers
//! so applets don't have to set them up individually. Stdout/stderr are buffered;
//! `dispatch` (in `main.zig`) flushes them after the applet returns.

const std = @import("std");

const Context = @This();

io: std.Io,
arena: std.mem.Allocator,
gpa: std.mem.Allocator,

stdout: *std.Io.Writer,
stderr: *std.Io.Writer,
stdin: *std.Io.Reader,

/// Read-only view of process environment. Use `ctx.environ.get(key)`.
environ: *const std.process.Environ.Map,

/// Name we were invoked as, after `.exe` stripping. Useful for error messages
/// (so `cat: can't open foo` works whether dispatched via multi-call or `staysail cat`).
invoked_as: []const u8,

/// Print a formatted error to stderr prefixed with the applet name.
/// Always returns; never panics. Intended use: `ctx.err("can't open {s}: {s}", .{path, @errorName(e)});`
pub fn err(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    ctx.stderr.print("{s}: ", .{ctx.invoked_as}) catch {};
    ctx.stderr.print(fmt, args) catch {};
    ctx.stderr.writeByte('\n') catch {};
}

/// Print a usage error to stderr (exit code 2 by convention).
pub fn usage(ctx: *Context, comptime fmt: []const u8, args: anytype) void {
    ctx.err(fmt, args);
    ctx.stderr.print("Try '{s} --help' for more information.\n", .{ctx.invoked_as}) catch {};
}
