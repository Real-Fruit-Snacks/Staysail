//! Static index of every applet in the project. Adding a new applet requires
//! adding both an entry here AND in `build/presets.zig`. The `registry` module
//! filters this set down to whatever the active build preset selected.
//!
//! Each entry must export:
//!   pub const name: []const u8
//!   pub const aliases: []const []const u8
//!   pub const help: []const u8
//!   pub fn run(ctx: *Context, args: []const [:0]const u8) anyerror!u8

pub const awk = @import("awk.zig");
pub const base64 = @import("base64.zig");
pub const basename = @import("basename.zig");
pub const cat = @import("cat.zig");
pub const chmod = @import("chmod.zig");
pub const cmp = @import("cmp.zig");
pub const column = @import("column.zig");
pub const comm = @import("comm.zig");
pub const completions = @import("completions.zig");
pub const cp = @import("cp.zig");
pub const cut = @import("cut.zig");
pub const date = @import("date.zig");
pub const dd = @import("dd.zig");
pub const df = @import("df.zig");
pub const diff = @import("diff.zig");
pub const dig = @import("dig.zig");
pub const dirname = @import("dirname.zig");
pub const du = @import("du.zig");
pub const echo = @import("echo.zig");
pub const env = @import("env.zig");
pub const expand = @import("expand.zig");
pub const @"false" = @import("false.zig");
pub const find = @import("find.zig");
pub const fmt = @import("fmt.zig");
pub const fold = @import("fold.zig");
pub const getopt = @import("getopt.zig");
pub const grep = @import("grep.zig");
pub const groups = @import("groups.zig");
pub const gunzip = @import("gunzip.zig");
pub const gzip = @import("gzip.zig");
pub const head = @import("head.zig");
pub const hexdump = @import("hexdump.zig");
pub const hostname = @import("hostname.zig");
pub const http = @import("http.zig");
pub const id = @import("id.zig");
pub const @"install-aliases" = @import("install-aliases.zig");
pub const join = @import("join.zig");
pub const jq = @import("jq.zig");
pub const ln = @import("ln.zig");
pub const ls = @import("ls.zig");
pub const md5sum = @import("md5sum.zig");
pub const mkdir = @import("mkdir.zig");
pub const mktemp = @import("mktemp.zig");
pub const mv = @import("mv.zig");
pub const nc = @import("nc.zig");
pub const nl = @import("nl.zig");
pub const od = @import("od.zig");
pub const paste = @import("paste.zig");
pub const printf = @import("printf.zig");
pub const pwd = @import("pwd.zig");
pub const realpath = @import("realpath.zig");
pub const rev = @import("rev.zig");
pub const rm = @import("rm.zig");
pub const sed = @import("sed.zig");
pub const seq = @import("seq.zig");
pub const sha1sum = @import("sha1sum.zig");
pub const sha256sum = @import("sha256sum.zig");
pub const sha512sum = @import("sha512sum.zig");
pub const sleep = @import("sleep.zig");
pub const sort = @import("sort.zig");
pub const split = @import("split.zig");
pub const stat = @import("stat.zig");
pub const tac = @import("tac.zig");
pub const tail = @import("tail.zig");
pub const tar = @import("tar.zig");
pub const tee = @import("tee.zig");
pub const timeout = @import("timeout.zig");
pub const touch = @import("touch.zig");
pub const tr = @import("tr.zig");
pub const @"true" = @import("true.zig");
pub const truncate = @import("truncate.zig");
pub const unexpand = @import("unexpand.zig");
pub const update = @import("update.zig");
pub const uname = @import("uname.zig");
pub const uniq = @import("uniq.zig");
pub const uuidgen = @import("uuidgen.zig");
pub const watch = @import("watch.zig");
pub const wc = @import("wc.zig");
pub const which = @import("which.zig");
pub const whoami = @import("whoami.zig");
pub const unzip = @import("unzip.zig");
pub const xargs = @import("xargs.zig");
pub const yes = @import("yes.zig");
pub const zip = @import("zip.zig");
