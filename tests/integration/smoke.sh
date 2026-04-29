#!/usr/bin/env bash
# Phase 1 integration smoke test — runs the built binary through a curated
# set of inputs and asserts each one matches the expected output / exit code.
#
# Usage:   ./tests/integration/smoke.sh [path-to-staysail-binary]
# Default: ./zig-out/bin/staysail (or staysail.exe on Windows / MSYS2)

set -u

BIN="${1:-}"
if [[ -z "$BIN" ]]; then
  for candidate in ./zig-out/bin/staysail ./zig-out/bin/staysail.exe; do
    if [[ -x "$candidate" ]]; then BIN="$candidate"; break; fi
  done
fi
if [[ ! -x "$BIN" ]]; then
  echo "ERROR: staysail binary not found. Run 'zig build' first or pass a path."
  exit 2
fi
# Absolutize so tests can `cd` into temp dirs without losing the binary.
case "$BIN" in
  /*|[A-Za-z]:[\\/]*) ;;
  *) BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")" ;;
esac

pass=0
fail=0
failures=()

# ---------- assertion helpers ----------

assert_eq() {
  # $1 description, $2 expected, $3 actual
  if [[ "$2" == "$3" ]]; then
    pass=$((pass+1))
    printf "  ok   %s\n" "$1"
  else
    fail=$((fail+1))
    failures+=("$1")
    printf "  FAIL %s\n" "$1"
    printf "       expected: %q\n" "$2"
    printf "       actual:   %q\n" "$3"
  fi
}

assert_exit() {
  # $1 description, $2 expected exit code, $3 actual exit code
  if [[ "$2" == "$3" ]]; then
    pass=$((pass+1))
    printf "  ok   %s\n" "$1"
  else
    fail=$((fail+1))
    failures+=("$1")
    printf "  FAIL %s (expected exit %s, got %s)\n" "$1" "$2" "$3"
  fi
}

# ---------- test cases ----------

echo "Running staysail integration smoke tests against $BIN"
echo

echo "[--version]"
out=$("$BIN" --version)
[[ "$out" =~ ^staysail\ [0-9] ]] && assert_eq "--version starts with 'staysail <num>'" "match" "match" \
  || assert_eq "--version starts with 'staysail <num>'" "match" "$out"

echo "[--list]"
out=$("$BIN" --list)
echo "$out" | grep -q "^  cat " && assert_eq "--list mentions cat" "yes" "yes" \
  || assert_eq "--list mentions cat" "yes" "no"
echo "$out" | grep -q "^  echo$" && assert_eq "--list mentions echo" "yes" "yes" \
  || assert_eq "--list mentions echo" "yes" "no"

echo "[true / false]"
"$BIN" true; assert_exit "true exits 0" 0 $?
"$BIN" false; assert_exit "false exits 1" 1 $?

echo "[echo]"
assert_eq "echo joins args with single spaces" "hello world" "$("$BIN" echo hello world)"
assert_eq "echo -n suppresses trailing newline" "noEOL" "$("$BIN" echo -n noEOL)"

echo "[seq]"
assert_eq "seq 1 5 default newline-separated" "$(printf '1\n2\n3\n4\n5')" "$("$BIN" seq 1 5)"
assert_eq "seq -s + uses + separator" "1+2+3" "$("$BIN" seq -s + 1 3)"

echo "[wc on stdin]"
out=$(printf "a\nb\nc\n" | "$BIN" wc -l)
assert_eq "wc -l on 3 lines reports 3" "      3" "$out"

echo "[head -n 2]"
out=$(printf "a\nb\nc\nd\n" | "$BIN" head -n 2)
assert_eq "head -n 2 returns first two lines" "$(printf 'a\nb')" "$out"

echo "[tail -n 2]"
out=$(printf "a\nb\nc\nd\n" | "$BIN" tail -n 2)
assert_eq "tail -n 2 returns last two lines" "$(printf 'c\nd')" "$out"

# Use relative paths to avoid MSYS2/Git-Bash path mangling of leading slashes.
echo "[basename]"
assert_eq "basename strips dir" "file.txt" "$("$BIN" basename a/b/file.txt)"
assert_eq "basename strips suffix" "file" "$("$BIN" basename a/b/file.txt .txt)"

echo "[dirname]"
assert_eq "dirname returns parent" "a/b" "$("$BIN" dirname a/b/file.txt)"
assert_eq "dirname of bare name returns ." "." "$("$BIN" dirname file.txt)"

echo "[pwd]"
out=$("$BIN" pwd)
[[ -n "$out" && -d "$out" ]] && assert_eq "pwd returns an existing directory" "yes" "yes" \
  || assert_eq "pwd returns an existing directory" "yes" "no"

echo "[unknown applet]"
"$BIN" nosuchapplet 2>/dev/null
assert_exit "unknown applet exits 1" 1 $?

echo "[--help on applet]"
out=$("$BIN" cat --help)
echo "$out" | grep -qi "usage" && assert_eq "cat --help mentions Usage" "yes" "yes" \
  || assert_eq "cat --help mentions Usage" "yes" "no"

echo "[multi-call dispatch via copied binary name]"
tmp=$(mktemp -d 2>/dev/null || mktemp -d -t staysail)
ext=""; [[ "$BIN" == *.exe ]] && ext=".exe"
cp "$BIN" "$tmp/cat$ext"
out=$(cd "$tmp" && echo "fromcat" | "./cat$ext")
assert_eq "argv[0]=cat invokes cat applet" "fromcat" "$out"
rm -rf "$tmp"

# ---------- Phase 2 applets ----------

echo "[tac]"
out=$(printf "1\n2\n3\n" | "$BIN" tac)
assert_eq "tac reverses lines" "$(printf '3\n2\n1')" "$out"

echo "[rev]"
assert_eq "rev reverses bytes per line" "olleh" "$(printf 'hello' | "$BIN" rev | tr -d '\n')"

echo "[nl]"
out=$(printf "a\nb\n" | "$BIN" nl)
echo "$out" | grep -q "1.*a" && assert_eq "nl numbers lines" "yes" "yes" || assert_eq "nl numbers lines" "yes" "no"

echo "[paste]"
tmp=$(mktemp -d)
printf "a\nb\n" > "$tmp/p1"; printf "1\n2\n" > "$tmp/p2"
out=$("$BIN" paste "$tmp/p1" "$tmp/p2")
assert_eq "paste tab-joins" "$(printf 'a\t1\nb\t2')" "$out"

echo "[cut -d, -f1]"
out=$(printf "a,b,c\n" | "$BIN" cut -d, -f1)
assert_eq "cut -d, -f1 picks first field" "a" "$out"

echo "[tr a-z A-Z]"
out=$(printf "hello\n" | "$BIN" tr a-z A-Z)
assert_eq "tr ranges" "HELLO" "$out"

echo "[base64 encode + decode round-trip]"
encoded=$(printf "test data\n" | "$BIN" base64 -w 0)
decoded=$(printf "%s" "$encoded" | "$BIN" base64 -d)
assert_eq "base64 round-trip" "$(printf 'test data\n')" "$decoded"

echo "[sort]"
out=$(printf "banana\napple\ncherry\n" | "$BIN" sort)
assert_eq "sort alphabetical" "$(printf 'apple\nbanana\ncherry')" "$out"

echo "[sort -n]"
out=$(printf "10\n2\n1\n" | "$BIN" sort -n)
assert_eq "sort -n numeric" "$(printf '1\n2\n10')" "$out"

echo "[uniq -c]"
out=$(printf "a\na\nb\n" | "$BIN" uniq -c | tr -s ' ')
[[ "$out" == *"2 a"* ]] && assert_eq "uniq -c shows counts" "yes" "yes" || assert_eq "uniq -c shows counts" "yes" "no"

echo "[grep substring]"
out=$(printf "apple\nbanana\ngrape\n" | "$BIN" grep ap)
assert_eq "grep substring matches multiple lines" "$(printf 'apple\ngrape')" "$out"

echo "[grep -v]"
out=$(printf "yes\nno\nyes\n" | "$BIN" grep -v no)
assert_eq "grep -v inverts" "$(printf 'yes\nyes')" "$out"

echo "[xargs]"
out=$(printf "a b c\n" | "$BIN" xargs echo)
[[ "$out" == "a b c" ]] && assert_eq "xargs runs echo" "yes" "yes" || assert_eq "xargs runs echo" "yes" "no"

echo "[printf]"
out=$("$BIN" printf "%s=%d\n" foo 42)
assert_eq "printf format" "foo=42" "$out"

echo "[mkdir + rm]"
mkdir_test=$(mktemp -d)
"$BIN" mkdir "$mkdir_test/newdir"
[[ -d "$mkdir_test/newdir" ]] && assert_eq "mkdir creates directory" "yes" "yes" || assert_eq "mkdir creates directory" "yes" "no"
"$BIN" rm -rf "$mkdir_test/newdir"
[[ ! -e "$mkdir_test/newdir" ]] && assert_eq "rm -rf removes directory" "yes" "yes" || assert_eq "rm -rf removes directory" "yes" "no"
rm -rf "$mkdir_test"

echo "[cp + mv]"
cp_test=$(mktemp -d)
echo "data" > "$cp_test/src.txt"
"$BIN" cp "$cp_test/src.txt" "$cp_test/copy.txt"
assert_eq "cp copies file content" "data" "$(cat "$cp_test/copy.txt")"
"$BIN" mv "$cp_test/copy.txt" "$cp_test/moved.txt"
[[ -f "$cp_test/moved.txt" && ! -f "$cp_test/copy.txt" ]] && assert_eq "mv renames" "yes" "yes" || assert_eq "mv renames" "yes" "no"
rm -rf "$cp_test"

echo "[ls]"
ls_test=$(mktemp -d)
touch "$ls_test/a.txt" "$ls_test/b.txt"
out=$("$BIN" ls "$ls_test" | sort)
assert_eq "ls lists entries" "$(printf 'a.txt\nb.txt')" "$out"
rm -rf "$ls_test"

echo "[stat]"
"$BIN" stat README.md > /dev/null
assert_exit "stat README.md exits 0" 0 $?

# ---------- Phase 3 applets ----------

echo "[md5sum (RFC test vector for 'abc')]"
out=$(printf "abc" | "$BIN" md5sum | cut -d' ' -f1)
assert_eq "md5(abc) = 900150983cd24fb0d6963f7d28e17f72" "900150983cd24fb0d6963f7d28e17f72" "$out"

echo "[sha1sum (FIPS test vector for 'abc')]"
out=$(printf "abc" | "$BIN" sha1sum | cut -d' ' -f1)
assert_eq "sha1(abc) = a9993e364706816aba3e25717850c26c9cd0d89d" "a9993e364706816aba3e25717850c26c9cd0d89d" "$out"

echo "[sha256sum (FIPS test vector for 'abc')]"
out=$(printf "abc" | "$BIN" sha256sum | cut -d' ' -f1)
assert_eq "sha256(abc) matches" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$out"

echo "[uuidgen v4 format]"
out=$("$BIN" uuidgen)
[[ "$out" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$ ]] && assert_eq "uuidgen produces v4" "yes" "yes" || assert_eq "uuidgen produces v4" "yes" "no"

echo "[hostname non-empty]"
out=$("$BIN" hostname)
[[ -n "$out" ]] && assert_eq "hostname non-empty" "yes" "yes" || assert_eq "hostname non-empty" "yes" "no"

echo "[id]"
"$BIN" id > /dev/null
assert_exit "id exits 0" 0 $?

echo "[date +%Y]"
out=$("$BIN" date "+%Y")
[[ "$out" =~ ^20[0-9]{2}$ ]] && assert_eq "date +%Y is 4-digit year" "yes" "yes" || assert_eq "date +%Y is 4-digit year" "yes" "no"

echo "[date -I]"
out=$("$BIN" date -I)
[[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && assert_eq "date -I is YYYY-MM-DD" "yes" "yes" || assert_eq "date -I is YYYY-MM-DD" "yes" "no"

echo "[du -s . non-zero]"
out=$("$BIN" du -s . | cut -f1)
[[ "$out" -gt 0 ]] && assert_eq "du -s reports >0 blocks" "yes" "yes" || assert_eq "du -s reports >0 blocks" "yes" "no"

echo "[dd reads input]"
out=$(printf "hello world\n" | "$BIN" dd bs=5 count=2 status=none)
assert_eq "dd bs=5 count=2 reads 10 bytes" "hello worl" "$out"

echo "[timeout fast command exits 0]"
"$BIN" timeout 2 "$BIN" echo done > /dev/null
assert_exit "timeout 2 echo exits 0" 0 $?

echo "[find -name literal]"
out=$("$BIN" find src/applets -name "all.zig" | head -1)
[[ "$out" == *"all.zig" ]] && assert_eq "find finds all.zig" "yes" "yes" || assert_eq "find finds all.zig" "yes" "no"

echo "[find -name glob]"
n=$("$BIN" find src/applets -name "*.zig" | wc -l)
[[ "$n" -gt 50 ]] && assert_eq "find -name '*.zig' returns many" "yes" "yes" || assert_eq "find -name '*.zig' returns many" "yes" "no"

echo "[sed s/// literal]"
out=$(printf "foo bar\n" | "$BIN" sed "s/foo/BAZ/g")
assert_eq "sed substitutes" "BAZ bar" "$out"

echo "[sed line address]"
out=$(printf "a\nb\nc\n" | "$BIN" sed "2d")
assert_eq "sed 2d deletes line 2" "$(printf 'a\nc')" "$out"

echo "[awk: NR + arithmetic]"
out=$(printf "10\n20\n30\n" | "$BIN" awk "{ print NR, \$1 * 2 }")
[[ "$out" == "$(printf '1 20\n2 40\n3 60')" ]] && assert_eq "awk NR + multiplication" "yes" "yes" || assert_eq "awk NR + multiplication" "yes" "no"

# ---------- Phase 5 (regex + awk + jq + lifecycle) ----------

echo "[grep regex with character class + quantifier]"
out=$(printf "abc\ndef123\nghi\n" | "$BIN" grep "[a-z]+[0-9]+")
assert_eq "grep regex matches def123" "def123" "$out"

echo "[grep regex with anchors]"
out=$(printf "foo\nfoobar\nbarfoo\n" | "$BIN" grep "^foo$")
assert_eq "grep ^foo$ matches only 'foo'" "foo" "$out"

echo "[sed regex substitution]"
out=$(printf "a1b2c3\n" | "$BIN" sed "s/[0-9]/X/g")
assert_eq "sed s/[0-9]/X/g" "aXbXcX" "$out"

echo "[awk variable assignment + sum]"
out=$(printf "10\n20\n30\n" | "$BIN" awk "{ s += \$1 } END { print s }")
assert_eq "awk sum via +=" "60" "$out"

echo "[awk builtin: length, tolower]"
out=$(printf "Hello\n" | "$BIN" awk "{ print length(\$0), tolower(\$0) }")
assert_eq "awk length + tolower" "5 hello" "$out"

echo "[jq array construction]"
out=$(echo '{"a":1,"b":2}' | "$BIN" jq -c "[.a, .b]")
assert_eq "jq [.a, .b] yields [1,2]" "[1,2]" "$out"

echo "[jq object construction (multi-field)]"
out=$(echo '{"name":"alice","age":30}' | "$BIN" jq -c "{n: .name, doubled: (.age * 2)}")
assert_eq "jq object construction" '{"n":"alice","doubled":60}' "$out"

echo "[jq if/then/else]"
out=$(echo '5' | "$BIN" jq "if . > 3 then \"big\" else \"small\" end")
assert_eq "jq if/then/else" '"big"' "$out"

echo "[jq map + add]"
out=$(echo '[1,2,3,4]' | "$BIN" jq "map(. * 2) | add")
assert_eq "jq map + add" "20" "$out"

echo "[jq sort + reverse]"
out=$(echo '[3,1,4,1,5]' | "$BIN" jq -c "sort | reverse")
assert_eq "jq sort+reverse" "[5,4,3,1,1]" "$out"

echo "[jq split + join round-trip]"
out=$(echo '"a,b,c"' | "$BIN" jq "split(\",\") | join(\":\")")
assert_eq "jq split/join" '"a:b:c"' "$out"

echo "[find -or]"
out=$("$BIN" find src/applets -type f -name "all.zig" -o -name "cat.zig" | wc -l)
[[ "$out" -ge 2 ]] && assert_eq "find -or returns >=2 matches" "yes" "yes" || assert_eq "find -or returns >=2 matches" "yes" "no"

echo "[find ! NOT]"
# Strip wc's leading whitespace on BSD (macOS) so the comparison is portable.
n_nonzig=$("$BIN" find src/applets -type f ! -name "*.zig" 2>/dev/null | wc -l | tr -d ' ')
[[ "$n_nonzig" == "0" ]] && assert_eq "find ! filters everything" "yes" "yes" || assert_eq "find ! filters everything" "yes" "no"

echo "[completions bash]"
"$BIN" completions bash > /dev/null
assert_exit "completions bash exits 0" 0 $?

echo "[completions powershell]"
"$BIN" completions powershell > /dev/null
assert_exit "completions powershell exits 0" 0 $?

echo "[install-aliases dry-run]"
"$BIN" install-aliases --dry-run /tmp/sa_dryrun > /dev/null
assert_exit "install-aliases --dry-run exits 0" 0 $?

echo "[update --check (404 expected from missing repo)]"
"$BIN" update --check --repo nonexistent/repo > /dev/null 2>&1
# Either 0 (already up to date) or 1 (network/404). Just verify it doesn't crash.
ec=$?
[[ "$ec" -le 1 ]] && assert_eq "update --check exits cleanly" "yes" "yes" || assert_eq "update --check exits cleanly" "yes" "no"

# ---------- Phase 4 applets ----------

echo "[gzip + gunzip round-trip]"
out=$(echo "the quick brown fox" | "$BIN" gzip | "$BIN" gunzip)
assert_eq "gzip|gunzip preserves data" "the quick brown fox" "$out"

echo "[diff identical]"
echo "abc" > /tmp/sm_d1; echo "abc" > /tmp/sm_d2
"$BIN" diff /tmp/sm_d1 /tmp/sm_d2; assert_exit "diff identical exits 0" 0 $?
rm -f /tmp/sm_d1 /tmp/sm_d2

echo "[diff differing files exits 1]"
echo "abc" > /tmp/sm_d1; echo "def" > /tmp/sm_d2
"$BIN" diff -q /tmp/sm_d1 /tmp/sm_d2 > /dev/null; assert_exit "diff different exits 1" 1 $?
rm -f /tmp/sm_d1 /tmp/sm_d2

echo "[join]"
printf "1 a\n2 b\n" > /tmp/sm_j1
printf "1 X\n2 Y\n" > /tmp/sm_j2
out=$("$BIN" join /tmp/sm_j1 /tmp/sm_j2)
assert_eq "join joins on field 1" "$(printf '1 a X\n2 b Y')" "$out"
rm -f /tmp/sm_j1 /tmp/sm_j2

echo "[tar create+extract round-trip]"
TD=$(mktemp -d)
mkdir "$TD/src"; echo "hello" > "$TD/src/a.txt"
(cd "$TD" && "$BIN" tar -cf archive.tar src) > /dev/null 2>&1
mkdir "$TD/out"
(cd "$TD/out" && "$BIN" tar -xf "$TD/archive.tar") > /dev/null 2>&1
out=$(cat "$TD/out/src/a.txt")
assert_eq "tar round-trip preserves content" "hello" "$out"
rm -rf "$TD"

echo "[tar -czf round-trip]"
TD=$(mktemp -d)
mkdir "$TD/src"; echo "compressed" > "$TD/src/a.txt"
(cd "$TD" && "$BIN" tar -czf archive.tgz src) > /dev/null 2>&1
mkdir "$TD/out"
(cd "$TD/out" && "$BIN" tar -xzf "$TD/archive.tgz") > /dev/null 2>&1
out=$(cat "$TD/out/src/a.txt")
assert_eq "tar -z round-trip preserves content" "compressed" "$out"
rm -rf "$TD"

echo "[zip + unzip round-trip]"
TD=$(mktemp -d)
echo "zipped data" > "$TD/source.txt"
(cd "$TD" && "$BIN" zip archive.zip source.txt) > /dev/null 2>&1
mkdir "$TD/extracted"
"$BIN" unzip "$TD/archive.zip" -d "$TD/extracted" > /dev/null 2>&1
out=$(cat "$TD/extracted/source.txt")
assert_eq "zip|unzip round-trip" "zipped data" "$out"
rm -rf "$TD"

echo "[jq identity]"
out=$(echo '{"x":1}' | "$BIN" jq ".")
[[ "$out" == *'"x": 1'* ]] && assert_eq "jq . echoes input" "yes" "yes" || assert_eq "jq . echoes input" "yes" "no"

echo "[jq field access (raw)]"
out=$(echo '{"name":"alice"}' | "$BIN" jq -r ".name")
assert_eq "jq -r .name unwraps" "alice" "$out"

echo "[jq pipe + select]"
out=$(printf '[{"x":1},{"x":2},{"x":3}]\n' | "$BIN" jq -c ".[] | select(.x > 1)")
[[ "$out" == "$(printf '{"x":2}\n{"x":3}')" ]] && assert_eq "jq select filters" "yes" "yes" || assert_eq "jq select filters" "yes" "no"

echo "[jq keys sorted]"
out=$(echo '{"b":2,"a":1,"c":3}' | "$BIN" jq -c "keys")
assert_eq "jq keys sorts" '["a","b","c"]' "$out"

echo "[chmod (POSIX) accepts numeric mode]"
TD=$(mktemp -d)
echo "x" > "$TD/f"
"$BIN" chmod 644 "$TD/f"; assert_exit "chmod 644 succeeds" 0 $?
rm -rf "$TD"

echo "[ln -s (symbolic link, since hard links need NTFS-and-elevation on Windows)]"
TD=$(mktemp -d)
echo "data" > "$TD/orig"
(cd "$TD" && "$BIN" ln -s orig link) > /dev/null 2>&1
# Don't fail the suite if symlink creation needs perms we lack — just note it.
if [[ -e "$TD/link" ]]; then
    assert_eq "ln -s creates a link entry" "yes" "yes"
else
    echo "  skip ln -s (symlink creation requires permission on this platform)"
fi
rm -rf "$TD"

echo "[find -exec]"
TD=$(mktemp -d)
echo "x" > "$TD/f1"; echo "y" > "$TD/f2"
out=$("$BIN" find "$TD" -type f -exec "$BIN" cat {} ";" 2>/dev/null | sort | tr -d '\r')
[[ "$out" == "$(printf 'x\ny')" ]] && assert_eq "find -exec runs command" "yes" "yes" || assert_eq "find -exec runs command" "yes" "no"
rm -rf "$TD"

# ---------- summary ----------

echo
echo "============================================================"
printf "Results: %d passed, %d failed\n" "$pass" "$fail"
if (( fail > 0 )); then
  echo "Failures:"
  for f in "${failures[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "All integration tests passed."
exit 0
