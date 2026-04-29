# Changelog

All notable changes to staysail are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] — Lifecycle, regex, awk/jq extensions

### Added (3 new applets, 84 total — full mainsail parity)

- **`install-aliases`**: sym/hard link (or copy) every applet into a target
  directory so `cat`, `ls`, etc. dispatch to staysail directly.
- **`completions`**: emit shell completion scripts for bash, zsh, fish,
  PowerShell.
- **`update`**: self-update from GitHub releases. Atomic replace; keeps the
  previous binary as `<exe>.old`.

### Added (no new applets — quality)

- **Regex engine** (`src/common/regex.zig`): POSIX-flavoured ERE with `.`,
  character classes, anchors, quantifiers (`*`/`+`/`?`/`{n,m}`), alternation,
  groups, perl-like `\d \w \s`. Wired into `grep`, `sed`, `awk`.
- **`awk` extensions**: variable assignment (`=`, `+=`, `-=`), bare-identifier
  variable references, builtins `length`, `substr`, `index`, `tolower`,
  `toupper`. The classic `{ s += $1 } END { print s }` now works.
- **`jq` extensions**: array construction `[...]`, object construction
  `{k: v}`, `if cond then a else b end`, and 16 builtins: `map`, `add`,
  `sort`, `unique`, `reverse`, `tostring`, `tonumber`, `ascii_downcase`,
  `ascii_upcase`, `split`, `join`, `startswith`, `endswith`, `contains`,
  `to_entries`, `from_entries`.
- **`find` expression tree**: `-o`/`-or`, `-a`/`-and`, `!`/`-not`, `-empty`.
- **`nc` bidirectional**: stdin → remote runs in a worker thread alongside
  the main remote → stdout pump.

### Changed (cleanups)

- `chmod` actually applies the mode on POSIX (was validate-only).
- `ln` supports hard links (was symlink-only).
- `find -exec ... ;` runs commands per match.
- `env -i ... -u VAR ... CMD` spawns a child with a modified environment.
- `which` no longer panics on MSYS2-style PATH entries.

### Notes

- `dig` remains broken on Windows (Zig 0.16 stdlib bug in
  `socketOptionAfd`). Linux/macOS work.
- See [`docs/PARITY.md`](docs/PARITY.md) for the full v0.6.0 wishlist.

## [0.4.0] — Archives, network, JSON

11 new applets, 81 total: `gzip`, `gunzip`, `tar`, `zip`, `unzip`, `http`,
`dig`, `nc`, `jq` (subset), `diff`, `join`.

## [0.3.0] — Hashing, system, processes, find/sed/awk

19 new applets, 70 total: `md5sum`, `sha1sum`, `sha256sum`, `sha512sum`,
`env`, `hostname`, `id`, `groups`, `uuidgen`, `getopt`, `du`, `df`, `dd`,
`timeout`, `watch`, `date`, `find`, `sed`, `awk`.

## [0.2.0] — Core file & text utilities

36 new applets, 51 total: `tac`, `rev`, `tee`, `nl`, `paste`, `cut`, `tr`,
`base64`, `printf`, `fold`, `fmt`, `expand`, `unexpand`, `cmp`, `comm`,
`column`, `od`, `hexdump`, `split`, `sort`, `uniq`, `grep`, `xargs`, `mkdir`,
`touch`, `mktemp`, `truncate`, `ln`, `which`, `realpath`, `ls`, `cp`, `mv`,
`rm`, `chmod`, `stat`.

## [0.1.0] — Foundation

15 applets: `cat`, `echo`, `true`, `false`, `yes`, `pwd`, `basename`,
`dirname`, `wc`, `head`, `tail`, `sleep`, `uname`, `whoami`, `seq`. Build
system, comptime applet registry, multi-call dispatch, three presets, custom
applet sets, integration tests, CI + release workflows.

[Unreleased]: https://github.com/Real-Fruit-Snacks/staysail/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Real-Fruit-Snacks/staysail/releases/tag/v1.0.0
[0.4.0]: https://github.com/Real-Fruit-Snacks/staysail/releases/tag/v0.4.0
[0.3.0]: https://github.com/Real-Fruit-Snacks/staysail/releases/tag/v0.3.0
[0.2.0]: https://github.com/Real-Fruit-Snacks/staysail/releases/tag/v0.2.0
[0.1.0]: https://github.com/Real-Fruit-Snacks/staysail/releases/tag/v0.1.0
