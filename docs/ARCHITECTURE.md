# Architecture

`staysail` is intentionally small. The whole project fits in your head: an
entry point, a registry, a per-applet contract, and a build-time filter.

## The four-layer flow

```
                     argv from OS
                          │
                          ▼
              ┌───────────────────────┐
   1. ENTRY   │      src/main.zig     │   pub fn main(init: Init) !void
              │   parse argv[0]       │
              │   strip .exe suffix   │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
 2. DISPATCH  │     src/main.zig      │
              │  registry.find(name)  │   multi-call: argv[0] basename
              │  global flags first   │   subcommand: argv[1]
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
 3. REGISTRY  │   src/registry.zig    │   APPLETS: []const Applet
              │  comptime-built       │   filtered by build_options
              │  from applets/all.zig │
              └───────────┬───────────┘
                          │
                          ▼
              ┌───────────────────────┐
   4. APPLET  │  src/applets/*.zig    │   pub fn run(ctx, args) !u8
              │  receives Context     │
              │  returns exit code    │
              └───────────────────────┘
```

## The applet contract

Every file under `src/applets/` exports four public symbols:

```zig
pub const name: []const u8 = "cat";
pub const aliases: []const []const u8 = &.{"type"};  // optional alternate names
pub const help: []const u8 =
    \\Usage: cat [OPTION]... [FILE]...
    \\Concatenate FILE(s) to standard output.
;

pub fn run(ctx: *Context, args: []const [:0]const u8) anyerror!u8 {
    // ...
    return 0;  // 0 success, 1 runtime error, 2 usage error
}
```

That's it. No registration call, no init function, no ceremony.

## The Context struct

`src/common/context.zig` bundles everything an applet needs:

| Field          | What it is                                                   |
|----------------|--------------------------------------------------------------|
| `io`           | `std.Io` instance — pass to file ops, sleep, networking      |
| `arena`        | Process-lifetime allocator (no need to free)                 |
| `gpa`          | General-purpose allocator (free what you allocate)           |
| `stdout`       | Buffered `*Io.Writer` — pre-flushed by the dispatcher        |
| `stderr`       | Buffered `*Io.Writer`                                        |
| `stdin`        | Buffered `*Io.Reader`                                        |
| `environ`      | `*const Environ.Map` — read-only env access                  |
| `invoked_as`   | Name we were called as (for error messages)                  |

It also has two convenience methods:

- `ctx.err(fmt, args)` — print `<applet>: <message>\n` to stderr
- `ctx.usage(fmt, args)` — same, plus a `Try '<applet> --help'` hint

## The comptime registry

`src/registry.zig` walks `src/applets/all.zig` at compile time:

```zig
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
```

Two consequences:
1. **Zero runtime registration cost.** The applet table is a `comptime`
   constant.
2. **Excluded applets are dead code.** If `awk` isn't in the active preset,
   the linker drops the entire `awk.zig` module from the binary.

## Build-time filtering

`build.zig` reads two options:

- `-Dpreset=full|slim|minimal` selects a curated applet list from
  `build/presets.zig`.
- `-Dapplets=cat,echo,grep` overrides the preset with a custom list.

Whichever wins is passed to the registry via `addOptions` →
`@import("build_options").active_applets: []const []const u8`.

## Dispatch order

`src/main.zig`:

1. Set up buffered stdio (streaming mode — required for pipes on Windows).
2. Inspect `argv[0]` basename. If it matches an applet name/alias and is not
   `staysail`, **multi-call** dispatch.
3. Otherwise:
   - `staysail` alone with no args → print usage.
   - `staysail --version` → print version, exit.
   - `staysail --list` → print all applets, exit.
   - `staysail --help` → print usage, exit.
   - `staysail <applet>` → look up applet, dispatch.
   - `staysail <applet> --help` → print applet's help, exit.
   - Unknown applet → error and exit 1.

## Why this shape

- **One file per applet** matches every sibling project (jib/topsail/moonraker)
  and is the natural unit for code review and contribution.
- **Comptime registry** is Zig's idiomatic alternative to dynamic registration.
  We pay zero runtime cost and gain dead-code elimination.
- **Static `all.zig`** rather than build-time codegen keeps the architecture
  simple. Adding an applet is a one-line edit in two files (`all.zig` and
  `presets.zig`). If/when Phase 4 brings 80+ applets, we may auto-discover
  `src/applets/*.zig` from `build.zig`.
- **The `Context` is a struct, not a global.** Tests can construct one with
  fixed buffers and run an applet against it. See `src/applets/echo.zig` for
  an example.

## Adding a new applet

See [`CONTRIBUTING.md`](CONTRIBUTING.md). In short:

1. Create `src/applets/<name>.zig` with the four-symbol contract.
2. Add `pub const <name> = @import("<name>.zig");` to `src/applets/all.zig`.
3. Add `"<name>"` to `full` (and possibly `slim`/`minimal`) in
   `build/presets.zig`.
4. Add a unit test in the same `<name>.zig` file.
5. Add an integration test in `tests/integration/<name>.zig`.
6. Update `docs/PARITY.md`.
