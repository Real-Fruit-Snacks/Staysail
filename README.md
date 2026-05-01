<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-light.svg">
  <img alt="Staysail" src="https://raw.githubusercontent.com/Real-Fruit-Snacks/Staysail/main/docs/assets/logo-dark.svg" width="100%">
</picture>

> [!IMPORTANT]
> **A BusyBox-style multi-call binary in Zig** — 84 Unix utilities, one ~1 MB statically-linked executable, native on Linux, macOS, and Windows. Cross-compile every target from a single host with one `zig build` invocation.

> *The smallest fully native, no-runtime binary in the sail-themed family — slots between `moonraker` (~1.2 MB) and `jib` (~2.4 MB).*

---

## §1 / Premise

[mainsail](https://github.com/Real-Fruit-Snacks/mainsail) is the Python reference implementation of this applet roster — easy to embed, easy to read, easy to extend. Its README documents three things it can't do: **no fully-static Linux binary, no `linux-arm64-musl`, no `macos-x64`** — limited by GitHub Actions runner availability and Python's dynamic-extension constraints.

Staysail exists to fill those gaps. `zig build -Dtarget=x86_64-linux-musl` produces a self-contained binary that runs in `gcr.io/distroless/static`, on Alpine, anywhere with a kernel. Every other supported target — including `aarch64-linux-musl` and `x86_64-macos` — builds from the same machine in one command.

Same applet roster as mainsail. Same flag conventions. Same exit codes. Different runtime story.

---

## §2 / Specs

| KEY      | VALUE                                                                       |
|----------|-----------------------------------------------------------------------------|
| BINARY   | One **~1 MB static executable** — no interpreter, no shared libs, no deps  |
| APPLETS  | **84 POSIX utilities** — text, files, hashing, archives, network, JSON      |
| TARGETS  | **8 native builds** — Linux glibc/musl · Windows · macOS · x86_64 + ARM64   |
| BUILDS   | Cross-compile every target from one host · `-Dpreset=full/slim/minimal`     |
| TESTS    | `zig build test` (~10ms unit) · 87 integration assertions in bats           |
| STACK    | Zig **0.16+** · `std.process.Init` · comptime applet registry               |

Full applet contract in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Per-applet divergences in [`docs/PARITY.md`](docs/PARITY.md).

---

## §3 / Quickstart

```bash
# From a release — no Zig required
curl -LO https://github.com/Real-Fruit-Snacks/Staysail/releases/latest/download/staysail-linux-x64
chmod +x staysail-linux-x64
./staysail-linux-x64 --list

# From source — Zig 0.16+
git clone https://github.com/Real-Fruit-Snacks/Staysail && cd Staysail
zig build -Doptimize=ReleaseSmall
./zig-out/bin/staysail --list
```

```bash
# Wire up multi-call dispatch so each applet runs by its own name
ln -s staysail cat                         # Unix
copy staysail.exe cat.exe                  :: Windows
./cat README.md                            # dispatches to the cat applet

# Or have staysail do it for every applet at once
staysail install-aliases ~/.local/bin
```

```bash
# Pick exactly the applets you need
zig build -Dpreset=full                    # 84 applets (default)
zig build -Dpreset=slim                    # POSIX core
zig build -Dpreset=minimal                 # ~10 scripting essentials
zig build -Dapplets=ls,cat,grep,sed,awk    # hand-picked
```

Excluded applets are **not compiled at all** — the comptime registry only references the active set, so the linker never sees the others. A `--applets=cat,echo,grep` build is well under 100 KB.

---

## §4 / Reference

```
APPLET CATEGORIES                                       # 84 total

  FOUNDATION    cat echo true false yes printf pwd basename dirname
                mkdir touch mv cp rm
  TEXT          head tail wc tee tac rev tr cut sort uniq seq sleep
                expand unexpand nl paste fold split comm join column
  HEAVY TEXT    grep (POSIX ERE) · sed (POSIX ERE) · awk · find
  FILESYSTEM    ls stat du df chmod which xargs realpath truncate mktemp ln dd
  HASH/ENCODE   md5sum sha1sum sha256sum sha512sum base64 od hexdump
  ARCHIVES      tar gzip gunzip zip unzip
  NETWORK/JSON  http (HTTPS via TLS) · dig (UDP DNS) · nc (TCP) · jq
  SYSTEM        uname whoami hostname id groups env date uuidgen getopt
                timeout watch cmp diff fmt
  LIFECYCLE     install-aliases · completions · update

DISPATCH

  staysail <applet> [args]                 # subcommand form
  ln -s staysail <applet>                  # multi-call: argv[0] basename
                                           # both dispatch identically

CROSS-COMPILE TARGETS                                   # zig build -Dtarget=...
  x86_64-linux-gnu                         glibc 2.35+
  x86_64-linux-musl                        Alpine · distroless · scratch
  aarch64-linux-gnu                        glibc 2.39+
  aarch64-linux-musl                       Alpine ARM64
  x86_64-windows-gnu                       Windows Intel
  aarch64-windows-gnu                      Windows ARM64
  x86_64-macos                             Intel Mac
  aarch64-macos                            Apple Silicon

BUILD VARIABLES                                         # zig build -D...
  preset=full|slim|minimal                 Bundle preset (default: full)
  applets=<list>                           Hand-pick (overrides preset)
  optimize=Debug|ReleaseSafe|ReleaseSmall  Default: Debug
  target=<triple>                          Cross-compile target

NOTABLE FLAG SUPPORT
  find          -exec · -name (glob) · -iname · -type · -size · -mtime
                -maxdepth · -mindepth · -empty · ! · -a · -o · -delete
  sed           s/regex/repl/[g][i] · d · p · q · = · line addresses · -n · -i · -e
  awk           BEGIN/END · regex · expressions · $0..$NF · NR/NF/FS/OFS/ORS
                length · substr · index · tolower · toupper
  jq            16 builtins · pipes · comma · constructors · if-then-else
                -r raw · -c compact · -s slurp
  http          GET/POST/PUT/DELETE/HEAD/PATCH · -H · -d · -j JSON · --fail · TLS
  tar           create / extract / list · gzip filter · BSD short + long form
```

---

## §5 / Authorization

Staysail is a userland Unix utility binary — no privileged operations, no exploitation surface. Same applet contract as `mainsail`, `topsail`, `jib`, `moonraker`, `rill`. Pick `mainsail` if you want a single Python file. Pick `staysail` if you want one binary that runs anywhere.

Documented divergences from POSIX and per-applet caveats live in [`docs/PARITY.md`](docs/PARITY.md). Vulnerabilities go through [private security advisories](https://github.com/Real-Fruit-Snacks/Staysail/security/advisories/new), never public issues.

---

[License: MIT](LICENSE) · Part of [Real-Fruit-Snacks](https://github.com/Real-Fruit-Snacks) — building offensive security tools, one wave at a time. Sibling: [mainsail](https://github.com/Real-Fruit-Snacks/mainsail) (Python) · [topsail](https://github.com/Real-Fruit-Snacks/topsail) (Go) · [jib](https://github.com/Real-Fruit-Snacks/jib) (Rust) · [moonraker](https://github.com/Real-Fruit-Snacks/moonraker) (Lua) · [rill](https://github.com/Real-Fruit-Snacks/rill) (NASM).
