//! Build-time applet sets. Edit `full` when adding a new applet.
//! `slim` and `minimal` are curated subsets.

pub fn byName(name: []const u8) ?[]const []const u8 {
    const eql = @import("std").mem.eql;
    if (eql(u8, name, "full")) return &full;
    if (eql(u8, name, "slim")) return &slim;
    if (eql(u8, name, "minimal")) return &minimal;
    return null;
}

/// Every applet shipped in the project. When you add an applet file under
/// `src/applets/<name>.zig`, append its name here AND register it in
/// `src/applets/all.zig`.
pub const full = [_][]const u8{
    "awk",
    "base64",
    "basename",
    "cat",
    "chmod",
    "cmp",
    "column",
    "comm",
    "completions",
    "cp",
    "cut",
    "date",
    "dd",
    "df",
    "diff",
    "dig",
    "dirname",
    "du",
    "echo",
    "env",
    "expand",
    "false",
    "find",
    "fmt",
    "fold",
    "getopt",
    "grep",
    "groups",
    "gunzip",
    "gzip",
    "head",
    "hexdump",
    "hostname",
    "http",
    "id",
    "install-aliases",
    "join",
    "jq",
    "ln",
    "ls",
    "md5sum",
    "mkdir",
    "mktemp",
    "mv",
    "nc",
    "nl",
    "od",
    "paste",
    "printf",
    "pwd",
    "realpath",
    "rev",
    "rm",
    "sed",
    "seq",
    "sha1sum",
    "sha256sum",
    "sha512sum",
    "sleep",
    "sort",
    "split",
    "stat",
    "tac",
    "tail",
    "tar",
    "tee",
    "timeout",
    "touch",
    "tr",
    "true",
    "truncate",
    "unexpand",
    "update",
    "uname",
    "uniq",
    "uuidgen",
    "watch",
    "wc",
    "which",
    "whoami",
    "unzip",
    "xargs",
    "yes",
    "zip",
};

/// POSIX coreutils only — same as full for now (no extras yet).
pub const slim = full;

/// Scripting essentials.
pub const minimal = [_][]const u8{
    "cat",
    "cut",
    "echo",
    "false",
    "head",
    "printf",
    "tail",
    "tr",
    "true",
    "wc",
    "yes",
};
