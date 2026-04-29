# Parity tracker

Goal: 84-applet parity with [mainsail](https://github.com/Real-Fruit-Snacks/mainsail).
**Hit at v0.5.0 — 84/84 applets shipped.**

## Phase 1 — Foundation (v0.1.0) — DONE

15 applets: `basename`, `cat` (alias `type`), `dirname`, `echo`, `false`,
`head`, `pwd`, `seq`, `sleep`, `tail`, `true`, `uname`, `wc`, `whoami`, `yes`.

## Phase 2 — Core file & text utilities (v0.2.0) — DONE

36 applets: `tac`, `rev`, `tee`, `nl`, `paste`, `cut`, `tr`, `base64`,
`printf`, `fold`, `fmt`, `expand`, `unexpand`, `cmp`, `comm`, `column`, `od`,
`hexdump`, `split`, `sort`, `uniq`, `grep`, `xargs`, `mkdir`, `touch`,
`mktemp`, `truncate`, `ln`, `which`, `realpath`, `ls`, `cp`, `mv`, `rm`,
`chmod`, `stat`.

## Phase 3 — Hashing, system, processes, find/sed/awk (v0.3.0) — DONE

19 applets: `md5sum`, `sha1sum`, `sha256sum`, `sha512sum`, `env`, `hostname`,
`id`, `groups`, `uuidgen`, `getopt`, `du`, `df`, `dd`, `timeout`, `watch`,
`date`, `find`, `sed`, `awk`.

## Phase 4 — Archives + network + JSON (v0.4.0) — DONE

11 applets: `gzip`, `gunzip`, `tar`, `zip`, `unzip`, `http`, `dig`, `nc`,
`jq`, `diff`, `join`.

## Phase 5 — Lifecycle + polish (v0.5.0 / v1.0.0) — DONE

### Lifecycle applets (3 new)
| Applet            | Status | Notes                                                  |
|-------------------|--------|--------------------------------------------------------|
| `install-aliases` | ✅     | sym/hard link or copy applets into a target directory  |
| `completions`     | ✅     | bash, zsh, fish, powershell                            |
| `update`          | ✅     | self-update from GitHub releases (atomic, keeps `.old`)|

### Quality refinements (no new applets)

#### Regex (Wave S) — used by grep, sed, awk
A small POSIX-flavoured ERE engine in `src/common/regex.zig`. Supports `.`,
`[abc]`/`[^abc]`/ranges, `^`/`$`, `*`/`+`/`?`, `{n,m}`, `()` groups, `|`
alternation, perl-like `\d \w \s` and inverse forms, common escapes. Both
`grep` and `sed -E` now do real regex matching; `awk` `/pattern/` patterns
likewise.

| Applet | Before                  | After                                  |
|--------|-------------------------|----------------------------------------|
| `grep` | substring               | full POSIX ERE + `-F` for literal       |
| `sed`  | literal `s/old/new/`    | regex `s/.../.../[g][i]`               |
| `awk`  | `/lit/` substring match | true regex patterns                    |

#### awk (Wave T) — variables + builtins
`{ s += $1 } END { print s }` now works. New: variable assignment (`=`,
`+=`, `-=`), bare-identifier variable references, builtins `length(s)`,
`substr(s, m[, n])`, `index(s, t)`, `tolower(s)`, `toupper(s)`.

Still missing for full awk: control flow (`if`/`while`/`for`), arrays,
user functions. Tracked for v0.6.0.

#### jq (Wave U) — constructors + if/then + builtins
Added: array construction `[a, b]`, object construction `{k: v}`,
`if cond then a else b end`, and 16 builtins: `map(f)`, `add`, `sort`,
`unique`, `reverse`, `tostring`, `tonumber`, `ascii_downcase`, `ascii_upcase`,
`split(s)`, `join(s)`, `startswith(s)`, `endswith(s)`, `contains(v)`,
`to_entries`, `from_entries`.

Still missing for full jq: variables (`as $x`), function definitions,
`recurse`, `paths`, `walk`, regex builtins. Tracked for v0.6.0.

#### find (Wave R) — expression tree
Now parses `-o`/`-or` (alternation), `-a`/`-and` (explicit conjunction),
`!`/`-not` (negation). Plus `-empty` predicate. Still no parens or
`-prune` — those land in v0.6.0.

#### nc (Wave R) — bidirectional
Now spawns a worker thread that shuffles stdin → remote concurrently with
the main thread shuffling remote → stdout. Falls back to drain-only if
threading fails.

#### chmod, ln, find -exec, env spawn (cleanup carried from earlier)
- `chmod` applies the mode on POSIX (was a validate-only stub).
- `ln` supports hard links (was symlink-only).
- `find -exec ... ;` runs commands per match.
- `env -i ... -u VAR ... CMD` spawns a child with a modified environment.
- `which` no longer panics on MSYS2-style PATH entries on Windows.

**84 / 84 applets** — v1.0.0.

## v0.6.0 wishlist

- `awk` control flow (`if`/`while`/`for`) + arrays + user functions
- `jq` variables (`as $x`), function definitions, `recurse`/`paths`/`walk`,
  regex builtins, more of the 47-builtin set
- `find` parens and `-prune`
- `sed` capture-group backrefs (`\&`, `\1..\9` in replacement)
- `df` real `statvfs`/`GetDiskFreeSpaceExW`
- `dig` Windows fix (workaround for Zig 0.16 `socketOptionAfd` bug)
- `date` localtime
- `zip` deflate-on-write
- `tar` bzip2/xz filters

## Known limitations as of v1.0.0

- **`dig` on Windows**: Zig 0.16 socket-option setup returns `INVALID_PARAMETER`
  on UDP sockets. Linux/macOS work. (Other UDP code in staysail isn't affected
  because nothing else sets non-default socket options.)
- **`yes` on Windows piped to a process that closes early** triggers a Zig
  0.16 `STATUS_PIPE_CLOSING` mis-classification. Output is correct; only
  stderr noise on exit.
- **`awk /regex/` patterns** can be path-mangled by MSYS2/git-bash. Use
  single quotes inside MSYS2, or invoke from PowerShell / cmd / a Linux
  shell.
- **`hostname`/`groups` on Windows** read env vars instead of Win32 syscalls.
- **`zip` writes uncompressed (store) entries.**
- **`date` is UTC only.**
- **`df` is a placeholder header.**

## Notes on intentional divergence

- `staysail` ships under MIT (matches the family); applet behavior may differ
  from GNU coreutils where mainsail's behavior is more pragmatic.
- Networking applets target the practical subset mainsail ships, not full
  curl/dig/nc parity.
- `jq` is "practical subset" — see what's implemented above.
