# Contributing to staysail

Thanks for considering a contribution. This guide covers the most common
case — **adding a new applet**.

## Prerequisites

- Zig **0.16.0** or newer (`zig version`).
- Git.

## Project conventions

- One file per applet, named after the applet (`src/applets/cat.zig`).
- Names match POSIX where possible; Windows-native aliases (e.g., `type` for
  `cat`) go in the `aliases` field.
- `--help` output follows GNU coreutils style (one-line `Usage:`, blank line,
  then per-flag descriptions).
- Exit codes: `0` success, `1` runtime error, `2` usage error.
- No global mutable state. Each applet's `run` is reentrant and uses the
  passed-in `Context`.

## Adding an applet — walkthrough

We'll add a fictional `rev` (reverses each line) as an example.

### 1. Create `src/applets/rev.zig`

```zig
const std = @import("std");
const Context = @import("../common/context.zig");

pub const name: []const u8 = "rev";
pub const aliases: []const []const u8 = &.{};
pub const help: []const u8 =
    \\Usage: rev [FILE]...
    \\
    \\Reverse the order of characters in each line of FILE(s).
    \\With no FILE, or when FILE is -, read standard input.
    \\
    \\      --help     display this help and exit
    \\
;

pub fn run(ctx: *Context, args: []const [:0]const u8) !u8 {
    // ... your implementation ...
    _ = args;
    _ = ctx;
    return 0;
}

test "rev: reverses a line" {
    // Arrange: build a Context with fixed buffers
    // Act: call run with synthesized args
    // Assert: check the captured stdout
}
```

### 2. Register it in `src/applets/all.zig`

Add the line in **alphabetical order**:

```zig
pub const rev = @import("rev.zig");
```

### 3. Add it to the relevant presets in `build/presets.zig`

`full` always gets every applet. Decide whether `slim` and/or `minimal`
should include it.

```zig
pub const full = [_][]const u8{
    // ... existing ...
    "rev",
    // ... existing ...
};
```

### 4. Add a unit test (in `rev.zig`)

```zig
test "rev: reverses ascii characters in a line" {
    var stdout_buf: [256]u8 = undefined;
    var stderr_buf: [128]u8 = undefined;
    var stdin_buf: [128]u8 = undefined;
    var stdout_w: std.Io.Writer = .fixed(&stdout_buf);
    var stderr_w: std.Io.Writer = .fixed(&stderr_buf);
    var stdin_r: std.Io.Reader = .fixed("hello\n");
    _ = stdin_buf;

    var ctx: Context = .{
        .io = undefined,
        .arena = std.testing.allocator,
        .gpa = std.testing.allocator,
        .stdout = &stdout_w,
        .stderr = &stderr_w,
        .stdin = &stdin_r,
        .environ = undefined,
        .invoked_as = "rev",
    };

    _ = try run(&ctx, &.{});
    try std.testing.expectEqualStrings("olleh\n", stdout_w.buffered());
}
```

### 5. Add an integration test in `tests/integration/rev.zig`

(See an existing one for the harness pattern.)

### 6. Update `docs/PARITY.md`

Move `rev` from the "todo" list to "done."

### 7. Validate

```bash
zig build                # builds with the full preset
zig build test           # runs unit + integration tests
zig fmt --check src/     # formatting check
zig build -Dtarget=x86_64-linux-musl  # cross-compile sanity
```

### 8. Open a PR

Title: `Add <name> applet`. Body: link the GNU coreutils manual page (or
mainsail's implementation) you're matching against. Note any flags you
intentionally chose not to support.

## Style

- `zig fmt` is enforced.
- Prefer `[]const u8` for non-owned strings, `[:0]const u8` for argv
  elements specifically (they come from the OS as null-terminated).
- Prefer `ctx.arena` for transient allocations within an applet — no need to
  free.
- Prefer `ctx.gpa` only when you need leak-tracking (rare for short-lived CLIs).
- Use `ctx.err(...)` and `ctx.usage(...)` rather than printing to stderr
  directly — that way the prefix and trailing newline are consistent.

## Build options reference

| Option                       | Meaning                                                |
|------------------------------|--------------------------------------------------------|
| `-Dpreset=full`              | All applets (default)                                  |
| `-Dpreset=slim`              | POSIX core only                                        |
| `-Dpreset=minimal`           | Scripting essentials                                   |
| `-Dapplets=ls,cat,grep`      | Custom applet set (overrides preset)                   |
| `-Doptimize=ReleaseSmall`    | Smallest binary (recommended for releases)             |
| `-Doptimize=ReleaseFast`     | Fastest binary                                         |
| `-Doptimize=Debug`           | Debug symbols (default)                                |
| `-Dtarget=<triple>`          | Cross-compile target                                   |
| `-Dversion=<string>`         | Version string baked into the binary                   |

## Reporting bugs

File an issue with:
- Output of `staysail --version`
- OS / arch
- Exact command + expected vs actual output
- Stack trace if a panic
