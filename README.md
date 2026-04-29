<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-light.svg">
  <img alt="staysail" src="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-dark.svg" width="560">
</picture>

![Zig](https://img.shields.io/badge/language-Zig-f7a41d.svg)
![Platform](https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-lightgrey)
![Arch](https://img.shields.io/badge/arch-x86__64%20%7C%20ARM64-blue)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Applets](https://img.shields.io/badge/applets-84-brightgreen.svg)

A BusyBox-style multi-call binary in Zig — **84 Unix utilities**, one ~1 MB statically-linked executable, native on Linux, macOS, and Windows.

[Download Latest](https://github.com/Real-Fruit-Snacks/Staysail/releases/latest)
&nbsp;·&nbsp;
[GitHub Pages](https://real-fruit-snacks.github.io/staysail/)
&nbsp;·&nbsp;
[Changelog](CHANGELOG.md)
&nbsp;·&nbsp;
[Sibling: mainsail (Python)](https://github.com/Real-Fruit-Snacks/mainsail)

</div>

---

## A sail-themed quintet

Same idea — BusyBox-style single-binary shell toolkits — five different languages, five different size/portability tradeoffs.

| Tool                                                              | What it does                                                                                                                  | Language |
|-------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|----------|
| [**Rill**](https://github.com/Real-Fruit-Snacks/rill)             | Pure x86_64 NASM — 41 utilities, **~34 KB** static ELF, direct syscalls, no libc                                              | ASM      |
| [**Moonraker**](https://github.com/Real-Fruit-Snacks/moonraker)   | Lua via `luastatic` — 81 utilities, **~1.2 MB** static executable with embedded Lua VM                                        | Lua      |
| **Staysail** (this project)                                       | Zig via `zig build` — **84 utilities**, **~1 MB** statically-linked executable, smallest realistic native build               | Zig      |
| [**Jib**](https://github.com/Real-Fruit-Snacks/jib)               | Rust via Cargo — 73 utilities + `jq`/`http`/`dig`, **~2.4 MB** avg (1.4 MB slim → 3.7 MB full) across 11 platform builds      | Rust     |
| [**Topsail**](https://github.com/Real-Fruit-Snacks/topsail)       | Single-file Go binary — 84 utilities, **~3.4 MB** per platform, plus `.deb` / `.rpm` / `.apk` packages                        | Go       |
| [**Mainsail**](https://github.com/Real-Fruit-Snacks/mainsail)     | Python via Nuitka — 84 utilities, **~5.5 MB** native bundle (or ~110 KB `.pyz` with system Python)                            | Python   |

`staysail` slots between `moonraker` (~1.2 MB) and `jib` (~2.4 MB) on size, and is the smallest *fully native, no-runtime* binary in the family.

---

## Quick start

**From a release** — no Zig required:

```bash
# Linux (glibc — Ubuntu, Debian, RHEL, …)
curl -LO https://github.com/Real-Fruit-Snacks/Staysail/releases/latest/download/staysail-linux-x64
chmod +x staysail-linux-x64
./staysail-linux-x64 --version
```

**From source** — Zig 0.16+:

```bash
git clone https://github.com/Real-Fruit-Snacks/Staysail
cd staysail
zig build -Doptimize=ReleaseSmall
./zig-out/bin/staysail --list
```

**Wire up multi-call dispatch** so each applet runs by its own name:

```bash
ln -s staysail cat       # symlink (Unix)
copy staysail.exe cat.exe  :: copy (Windows)
./cat README.md          # dispatches to the cat applet
```

Or have staysail do it for every applet at once:

```bash
staysail install-aliases ~/.local/bin
```

---

## Pre-built binaries

Every release tag (`v0.x.x`) ships **8 native binaries** built and verified by GitHub Actions:

| Target                            | Artifact                          |
|-----------------------------------|-----------------------------------|
| Linux x86_64 (glibc 2.35+)        | `staysail-linux-x64`              |
| Linux x86_64 musl (Alpine, distroless) | `staysail-linux-x64-musl`    |
| Linux ARM64 (glibc 2.39+)         | `staysail-linux-arm64`            |
| Linux ARM64 musl                  | `staysail-linux-arm64-musl`       |
| Windows x86_64                    | `staysail-windows-x64.exe`        |
| Windows ARM64                     | `staysail-windows-arm64.exe`      |
| macOS x86_64 (Intel)              | `staysail-macos-x64`              |
| macOS ARM64 (Apple Silicon)       | `staysail-macos-arm64`            |

`staysail` cross-compiles every target from a single host — `zig build -Dtarget=x86_64-linux-musl` does it from Windows or macOS just as well as from Linux. There are no per-platform CI runners required.

### Build your own

Pick exactly the applets you need:

```bash
zig build -Dpreset=full                         # 84 applets (default)
zig build -Dpreset=slim                         # POSIX core
zig build -Dpreset=minimal                      # ~10 scripting essentials
zig build -Dapplets=ls,cat,grep,sed,awk         # hand-picked
zig build -Doptimize=ReleaseSmall               # smallest binary
```

Excluded applets are **not compiled at all** — the comptime registry only references the applets in the active set, so the linker never sees the others. A `--applets=cat,echo,grep` build is well under 100 KB.

---

## Features

### One static binary, eighty-four utilities

Every common POSIX tool you'd reach for in a shell pipeline — plus `jq` for JSON, `http` for HTTP(S) (TLS via Zig's stdlib), `dig` for DNS, `nc` for TCP, archives (`tar` / `gzip` / `zip`), hashing (`md5sum` / `sha1sum` / `sha256sum` / `sha512sum`), and the BusyBox parity gap-fillers. Dispatch via `staysail <applet>` or symlink/copy to call the applet directly.

```bash
staysail ls -la                              # GNU-style flags
staysail cat file.txt | staysail grep -C 2 pattern
staysail find . -name '*.zig' -size +1k -mtime -7
staysail seq 100 | staysail sort -rn | staysail head -5
```

### Truly static, everywhere

`zig build -Dtarget=x86_64-linux-musl` produces a self-contained binary that runs unchanged on glibc, musl/Alpine, distroless, and scratch base images. No interpreter, no shared libs, no runtime dependencies — Zig links the C stdlib statically when targeting musl.

```dockerfile
FROM gcr.io/distroless/static
COPY staysail /usr/local/bin/
ENTRYPOINT ["/usr/local/bin/staysail"]
```

### Cross-compilation as a feature

A single `zig build -Dtarget=...` invocation produces a binary for any of the 8 release targets. No per-OS CI runners, no toolchain-installation rituals. The same Windows host that built the native build above produces the Linux ARM64 musl binary in one command.

```bash
zig build -Dtarget=aarch64-linux-musl  -Doptimize=ReleaseSmall
zig build -Dtarget=x86_64-windows-gnu  -Doptimize=ReleaseSmall
zig build -Dtarget=aarch64-macos       -Doptimize=ReleaseSmall
```

This directly fills the gaps Mainsail's README documents — **no fully-static glibc binary, no `linux-arm64-musl`, no `macos-x64`** — at zero extra effort.

### Real applets, not stubs

Each applet implements common POSIX flags and edge cases.

- `find` — expression tree with `-exec`, `-name` (glob), `-iname`, `-type`, `-size`, `-mtime`, `-maxdepth`, `-mindepth`, `-empty`, `!`/`-not`, `-a`/`-and`, `-o`/`-or`, `-print`, `-print0`, `-delete`
- `sed` — `s/regex/repl/[g][i]`, `d`, `p`, `q`, `=`, line addresses, `-n`, `-i`, `-e`, full POSIX ERE
- `awk` — BEGIN/END, regex patterns, expression patterns, `print`/`printf`, fields (`$0`..`$NF`), `NR`/`NF`/`FS`/`OFS`/`ORS`, comparison/arithmetic ops, variable assignment (`s += $1`), builtins `length`/`substr`/`index`/`tolower`/`toupper`
- `grep` — full POSIX ERE via the in-tree regex engine, plus `-F`/`-i`/`-v`/`-n`/`-c`/`-H`/`-h`
- `jq` — practical subset: `.`, `.field`, `.[idx]`, `.[]`, pipes, comma, `[exprs]` array construction, `{key: expr}` object construction, `if cond then a else b end`, comparisons, arithmetic, `select`, `length`, `keys`, `values`, `type`, `has`, `not`, `map`, `add`, `sort`, `unique`, `reverse`, `tostring`, `tonumber`, `ascii_downcase`/`upcase`, `split`/`join`, `startswith`/`endswith`/`contains`, `to_entries`/`from_entries`. Raw (`-r`), compact (`-c`), slurp (`-s`)
- `http` — curl-style: GET/POST/PUT/DELETE/HEAD/PATCH, `-H` headers, `-d` body, `-j` JSON, `-i` include headers, `--fail`. TLS supported via Zig stdlib
- `dig` — direct UDP DNS queries: A, AAAA, MX, TXT, CNAME, NS, PTR; `+short`; reverse via `-x` (Linux/macOS — see *Known limitations*)
- `nc` — TCP connect + listen + scan; bidirectional `stdin → remote / remote → stdout` shuffle on a worker thread
- `tar` — create / extract / list with gzip filter; BSD short-form (`cvfz`) and long-form flags both work
- `sort` — `-r`, `-n`, `-u`, `-f`, `-t`, `-k`

```bash
staysail find . -name '*.tmp' -delete
staysail sed -e 's/^foo/bar/' -e '/^#/d' config.txt
staysail awk '{ s += $1 } END { print s/NR }' data.csv
staysail jq '.users | map(select(.age > 30)) | sort_by(.name)' users.json
staysail http -H 'Authorization: Bearer $TOK' https://api.example.com/me
staysail dig MX gmail.com +short
staysail tar -czf src.tar.gz src/ --exclude='*_test.zig'
```

### Cross-platform integrity

Same SHA-256 of `"abc"` (`ba7816bf…015ad`) on every supported platform. `tar` archives are interchangeable. Same `jq` output on every host. Comptime applet registry guarantees the dispatch table is identical regardless of build target.

---

## Supported applets

| Category                      | Applets                                                                                                                                                                                                                          |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| **Foundation**                | `cat` (alias `type`) · `echo` · `true` · `false` · `yes` · `printf` · `pwd` · `basename` · `dirname` · `mkdir` · `touch` · `mv` · `cp` (alias `copy`) · `rm` (alias `del`)                                                       |
| **POSIX text**                | `head` · `tail` · `wc` · `tee` · `tac` · `rev` · `tr` · `cut` · `sort` · `uniq` · `seq` · `sleep` · `expand` · `unexpand` · `nl` · `paste` · `fold` · `split` · `comm` · `join` · `column`                                       |
| **Heavy text**                | `grep` (POSIX ERE) · `sed` (POSIX ERE) · `awk` (BEGIN/END/regex/builtins) · `find` (full predicate tree)                                                                                                                          |
| **Filesystem**                | `ls` (alias `dir`) · `stat` · `du` · `df` · `chmod` · `which` · `xargs` · `realpath` · `truncate` · `mktemp` · `ln` · `dd`                                                                                                       |
| **Hashing & encoding**        | `md5sum` · `sha1sum` · `sha256sum` · `sha512sum` · `base64` · `od` · `hexdump`                                                                                                                                                   |
| **Archives & compression**    | `tar` · `gzip` · `gunzip` · `zip` · `unzip`                                                                                                                                                                                       |
| **Network & JSON**            | `http` (HTTPS via TLS) · `dig` (UDP DNS) · `nc` (TCP) · `jq`                                                                                                                                                                     |
| **System & process**          | `uname` · `whoami` · `hostname` · `id` · `groups` · `env` · `date` · `uuidgen` · `getopt` · `timeout` · `watch` · `cmp` · `diff` · `fmt`                                                                                          |
| **Lifecycle**                 | `install-aliases` (symlink / hardlink / copy applets into a target dir) · `completions` (bash / zsh / fish / powershell) · `update` (atomic self-update from GitHub releases)                                                     |

84 registered names. Run `staysail --list` for the full set, or `staysail <applet> --help` for per-applet usage.

<details>
<summary><strong>Documented divergences from POSIX / mainsail</strong></summary>

Captured in detail in [`docs/PARITY.md`](docs/PARITY.md):

- **`awk`** has no control flow (`if`/`while`/`for`), no arrays, no user-defined functions yet — tracked for v1.1.0.
- **`jq`** is a practical subset — pipe / comma / constructors / 16 builtins / if-then-else. Variables, function definitions, `recurse`, `paths`, regex builtins are tracked for v1.1.0.
- **`find`** has no parens or `-prune` yet (operator-tree handles `-and`/`-or`/`!`/implicit-AND).
- **`sed`** does not yet support `\&` / `\1`-`\9` capture-group backrefs in the replacement.
- **`zip`** writes uncompressed (store) entries; reading deflate-compressed zips works.
- **`df`** is a placeholder header (real `statvfs`/`GetDiskFreeSpaceExW` is on the v1.1.0 list).
- **`date`** is UTC only.
- **`dig`** on **Windows** hits a Zig 0.16 stdlib bug in `socketOptionAfd` and returns `INVALID_PARAMETER`. Linux and macOS work; the fix is upstream.
- **`yes`** on **Windows** piped to a process that closes early triggers a Zig 0.16 misclassification of `STATUS_PIPE_CLOSING`. Output is correct; only the exit-time stderr noise is wrong.

Every divergence is intentional and documented; none change the exit codes for the supported flag set.

</details>

---

## Architecture

`staysail` boils down to four moving parts:

```
src/main.zig                 process entry; standardOptions / Init; calls dispatch
   │
   ▼
src/registry.zig             argv[0] basename match; multi-call vs subcommand mode
   │                         (comptime-built applet table from build_options)
   ▼
src/applets/all.zig          static index — one `pub const NAME = @import(...)`
   │                         per applet shipped in the active build
   ▼
src/applets/<name>.zig       one file per applet; exports name, aliases, help, run
```

**Four-layer flow:**

1. **Entry** — `src/main.zig` receives Zig 0.16's `std.process.Init`, sets up streaming stdio, hands off to `dispatch`. Same path whether invoked directly, via `staysail <applet>`, or through a symlink.
2. **Dispatch** — strips `.exe` from `argv[0]` basename, looks the result up in the comptime registry. Unknown invocations fall through to `staysail <applet> [args]` subcommand mode. `--help` is intercepted long-form only — `-h` stays free for applet flags like `df -h`.
3. **Registry** — `src/registry.zig` walks `applets/all.zig` at compile time, filters by the build option `active_applets`, and produces a flat `[]const Applet` lookup table. Excluded applets are not referenced and so get dead-code-eliminated.
4. **Applets** — one file per applet under `src/applets/`, each exporting `name`, `aliases`, `help`, and `run(ctx, args) !u8`. Stdio reads/writes go through a `Context` struct so tests construct one with `.fixed(...)` writers.

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the full applet contract, dispatch flow, cross-platform shims, and the divergence list.

---

## Development

### Setting up

```bash
git clone https://github.com/Real-Fruit-Snacks/Staysail
cd staysail
zig build test                      # unit tests (~10ms)
bash tests/integration/smoke.sh     # 87 integration assertions
```

You need **Zig 0.16.0** (`zig version`). On Windows: `winget install zig.zig`.

### Adding an applet

```bash
$EDITOR src/applets/myapplet.zig    # implement the four-symbol contract
$EDITOR src/applets/all.zig         # one new pub const = @import(...)
$EDITOR build/presets.zig           # add to "full" / "slim" / "minimal"
zig build && zig build test
```

The smallest correct applet is ~15 lines. Step-by-step in [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

### Cross-compiling everything

```bash
for tgt in x86_64-linux-{gnu,musl} aarch64-linux-{gnu,musl} \
           x86_64-windows-gnu aarch64-windows-gnu \
           x86_64-macos aarch64-macos; do
  zig build -Dtarget=$tgt -Doptimize=ReleaseSmall
done
```

All eight build cleanly from any host. No toolchain installation required.

---

## Why a Zig port of mainsail?

[mainsail](https://github.com/Real-Fruit-Snacks/mainsail) is the Python reference implementation — easy to embed your own Python build, easy to read, easy to extend. Its README documents three things it can't do: **no fully-static Linux binary, no `linux-arm64-musl`, no `macos-x64`** (because of GitHub Actions runner availability and Python's dynamic-extension constraints).

`staysail` exists to fill those gaps:

- **Fully-static everywhere.** `zig build -Dtarget=x86_64-linux-musl` produces a self-contained binary that runs in `gcr.io/distroless/static`, on Alpine, anywhere with a kernel.
- **Cross-compile from one host.** Every supported target — including `aarch64-linux-musl` and `x86_64-macos` — built from the same machine in one command.
- **Smaller.** ~1 MB native vs Mainsail's ~5.5 MB Nuitka bundle. No interpreter, no PYZ runtime cost, no Python.
- **Faster startup.** No interpreter cold-start. Pipelines that spawn 1000 instances feel native.

The two share the same applet roster, the same flag conventions, and the same exit codes. Pick `mainsail` when you want a single Python file you can `chmod +x` on any box that has CPython. Pick `staysail` when you want one binary that runs anywhere.

---

## Contributing

See [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) for the full guide. Adding an applet is a one-file change plus two registry entries.

---

## License

[MIT](LICENSE).

`staysail` is the Zig sibling in the same family as [mainsail](https://github.com/Real-Fruit-Snacks/mainsail), [topsail](https://github.com/Real-Fruit-Snacks/topsail), [jib](https://github.com/Real-Fruit-Snacks/jib), [moonraker](https://github.com/Real-Fruit-Snacks/moonraker), and [rill](https://github.com/Real-Fruit-Snacks/rill). Same applet contract, same dispatch UX, different runtime story. Part of the Real-Fruit-Snacks sail-themed toolkit.
