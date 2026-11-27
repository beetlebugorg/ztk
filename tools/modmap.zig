//! The module map of a Zig source tree (ztcl#537, ztk#304).
//!
//! `modmap` reads each `.zig` file below a source folder and finds each
//! `@import`. An import of a path resolves against the folder of the
//! file. An import of a name is a module of the build. A `module` line of
//! the areas file gives the file of a module name. The tool then prints a
//! report in Markdown:
//!
//! - the size, the test blocks, the imports, and the importers of each
//!   file, with the test files that import it;
//! - the import cycles: the strongly connected components of the graph
//!   (Tarjan), with more than one file, or one file that imports itself;
//! - the layering breaks: an import from a file of area A to a file of
//!   area B, when the `area A` line of the areas file does not list B;
//! - the files that no root of the build reaches (dead files);
//! - the functions with no use (dead functions): a private `fn` whose
//!   name is in its file one time, or a `pub fn` whose name is in the
//!   tree one time. The count is of identifiers outside `//` comments,
//!   so a name in a string, such as an `@field` name, counts as a use;
//! - duplicate helpers: functions in two or more files with the same
//!   body after the removal of space and comments, and the functions
//!   whose names have a word of the `dupwords` line, by word.
//!
//! `--dot FILE` writes the file graph in DOT, one cluster for each area.
//! A red edge is in a cycle, and an orange edge is a layering break.
//! `--area-dot FILE` writes the graph of the areas. `--only a,b` prints
//! only the sections a and b: summary, areas, cycles, layers, unmapped,
//! deadfiles, deadfns, dups, map.
//!
//! The areas file has one rule on each line, and `#` starts a comment:
//!
//!     area NAME DEP...    files of NAME may import files of each DEP
//!                         (`*` is any area); a file may always import
//!                         a file of its own area
//!     PATTERN AREA        files that match PATTERN are in AREA; a
//!                         pattern that ends in `/` is a folder, and `*`
//!                         is any text in one path part; the last match
//!                         wins
//!     module NAME PATH    `@import("NAME")` is the file PATH
//!     root PATH           a root of the build, beside the paths in
//!                         `"src/...zig"` strings of build.zig
//!     dupwords WORD...    words for the helper report
//!
//! The report is not a check: the exit code is 0 unless a file is
//! missing.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const usage =
    \\usage: modmap [--src DIR] [--areas FILE] [--build FILE] [--dot FILE]
    \\              [--area-dot FILE] [--only SECTION,...]
    \\
;

const Fn = struct {
    name: []const u8,
    line: usize,
    is_pub: bool,
    /// The hash of the body after the name, without space and comments.
    body_hash: u64,
    /// The length of that normal form, to skip small bodies.
    body_len: usize,
};

/// One import. `in_test` is true for an import in a `test` block or of
/// a test file. The cycles, the layers, and the area graph skip those.
const Edge = struct { to: usize, line: usize, in_test: bool = false };

const File = struct {
    path: []const u8,
    text: []const u8,
    lines: usize = 0,
    tests: usize = 0,
    area: []const u8 = "unmapped",
    imports: std.ArrayList(Edge) = .empty,
    modules: std.ArrayList([]const u8) = .empty,
    missing: std.ArrayList([]const u8) = .empty,
    importers: std.ArrayList(usize) = .empty,
    fns: std.ArrayList(Fn) = .empty,
    counts: std.StringHashMapUnmanaged(u32) = .empty,
    reached: bool = false,
    scc: usize = 0,
};

const Area = struct {
    name: []const u8,
    deps: std.ArrayList([]const u8) = .empty,
};

const Config = struct {
    areas: std.ArrayList(Area) = .empty,
    patterns: std.ArrayList([2][]const u8) = .empty,
    modules: std.ArrayList([2][]const u8) = .empty,
    roots: std.ArrayList([]const u8) = .empty,
    dupwords: std.ArrayList([]const u8) = .empty,

    fn area(c: *const Config, name: []const u8) ?*const Area {
        for (c.areas.items) |*a| if (std.mem.eql(u8, a.name, name)) return a;
        return null;
    }

    /// True when a file of area `from` may import a file of area `to`.
    fn allowed(c: *const Config, from: []const u8, to: []const u8) bool {
        if (std.mem.eql(u8, from, to)) return true;
        if (std.mem.eql(u8, to, "unmapped") or std.mem.eql(u8, from, "unmapped")) return true;
        const a = c.area(from) orelse return true;
        for (a.deps.items) |d| {
            if (std.mem.eql(u8, d, "*") or std.mem.eql(u8, d, to)) return true;
        }
        return false;
    }
};

/// Matches `path` with `pat`. `*` matches any text in one path part.
fn globMatch(pat: []const u8, path: []const u8) bool {
    if (pat.len == 0) return path.len == 0;
    if (pat[0] == '*') {
        var i: usize = 0;
        while (true) : (i += 1) {
            if (globMatch(pat[1..], path[i..])) return true;
            if (i >= path.len or path[i] == '/') return false;
        }
    }
    if (path.len == 0 or pat[0] != path[0]) return false;
    return globMatch(pat[1..], path[1..]);
}

fn patternMatch(pat: []const u8, path: []const u8) bool {
    if (pat.len > 0 and pat[pat.len - 1] == '/') return std.mem.startsWith(u8, path, pat);
    return globMatch(pat, path);
}

fn parseConfig(a: Allocator, text: []const u8) !Config {
    var c: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = if (std.mem.indexOfScalar(u8, raw, '#')) |h| raw[0..h] else raw;
        var it = std.mem.tokenizeAny(u8, line, " \t\r");
        const first = it.next() orelse continue;
        if (std.mem.eql(u8, first, "area")) {
            var ar: Area = .{ .name = it.next() orelse continue };
            while (it.next()) |d| try ar.deps.append(a, d);
            try c.areas.append(a, ar);
        } else if (std.mem.eql(u8, first, "module")) {
            const name = it.next() orelse continue;
            const path = it.next() orelse continue;
            try c.modules.append(a, .{ name, path });
        } else if (std.mem.eql(u8, first, "root")) {
            while (it.next()) |r| try c.roots.append(a, r);
        } else if (std.mem.eql(u8, first, "dupwords")) {
            while (it.next()) |w| try c.dupwords.append(a, w);
        } else {
            const ar = it.next() orelse continue;
            try c.patterns.append(a, .{ first, ar });
        }
    }
    return c;
}

/// Joins `dir` and `rel` and removes `.` and `..` parts.
fn normalJoin(a: Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var all = try std.mem.concat(a, u8, &.{ dir, "/", rel });
    _ = &all;
    var it = std.mem.splitScalar(u8, all, '/');
    while (it.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".")) continue;
        if (std.mem.eql(u8, p, "..")) {
            if (parts.items.len > 0 and !std.mem.eql(u8, parts.items[parts.items.len - 1], "..")) {
                _ = parts.pop();
            } else try parts.append(a, p);
            continue;
        }
        try parts.append(a, p);
    }
    return std.mem.join(a, "/", parts.items);
}

fn isIdentStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isIdent(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

/// Counts the identifiers of `text` outside `//` comments.
fn countIdents(a: Allocator, text: []const u8, counts: *std.StringHashMapUnmanaged(u32)) !void {
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            continue;
        }
        if (isIdentStart(ch) and (i == 0 or !isIdent(text[i - 1]))) {
            const start = i;
            while (i < text.len and isIdent(text[i])) i += 1;
            const gop = try counts.getOrPut(a, text[start..i]);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
            continue;
        }
        i += 1;
    }
}

/// The index after the `}` that closes the `{` at `open`. Strings,
/// characters, comments, and multiline strings do not count.
fn matchBrace(text: []const u8, open: usize) usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) {
        const ch = text[i];
        switch (ch) {
            '/' => if (i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') i += 1;
                continue;
            },
            '\\' => if (i + 1 < text.len and text[i + 1] == '\\') {
                while (i < text.len and text[i] != '\n') i += 1;
                continue;
            },
            '"', '\'' => {
                i += 1;
                while (i < text.len and text[i] != ch and text[i] != '\n') {
                    if (text[i] == '\\') i += 1;
                    i += 1;
                }
            },
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return text.len;
}

/// The hash and the length of `body` without space and `//` comments.
fn bodyHash(body: []const u8) struct { u64, usize } {
    var h = std.hash.Wyhash.init(0);
    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        const ch = body[i];
        if (ch == '/' and i + 1 < body.len and body[i + 1] == '/') {
            while (i < body.len and body[i] != '\n') i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(ch)) continue;
        h.update(body[i .. i + 1]);
        n += 1;
    }
    return .{ h.final(), n };
}

const RawImport = struct { []const u8, usize, bool };

/// Reads the test blocks, the imports, and the functions of `f`.
fn scanFile(a: Allocator, f: *File, raw_imports: *std.ArrayList(RawImport)) !void {
    var line_no: usize = 0;
    var test_end: usize = 0;
    var pos: usize = 0;
    while (pos < f.text.len or (pos == f.text.len and line_no == 0)) {
        const end = std.mem.indexOfScalarPos(u8, f.text, pos, '\n') orelse f.text.len;
        const line = f.text[pos..end];
        line_no += 1;
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "//") and !std.mem.startsWith(u8, t, "\\\\")) {
            if (std.mem.startsWith(u8, t, "test \"") or std.mem.startsWith(u8, t, "test {") or
                (std.mem.startsWith(u8, t, "test ") and std.mem.endsWith(u8, t, "{")))
            {
                f.tests += 1;
                if (std.mem.indexOfScalarPos(u8, f.text, pos, '{')) |o| test_end = @max(test_end, matchBrace(f.text, o));
            }
            var k: usize = 0;
            while (std.mem.indexOfPos(u8, line, k, "@import(\"")) |at| {
                const s = at + 9;
                const q = std.mem.indexOfScalarPos(u8, line, s, '"') orelse break;
                try raw_imports.append(a, .{ line[s..q], line_no, pos < test_end });
                k = q;
            }
            try scanFn(a, f, t, pos + (line.len - std.mem.trimStart(u8, line, " \t").len), line_no);
        }
        if (end == f.text.len) break;
        pos = end + 1;
    }
    f.lines = line_no;
    try countIdents(a, f.text, &f.counts);
}

fn scanFn(a: Allocator, f: *File, t: []const u8, at: usize, line_no: usize) !void {
    var rest = t;
    var is_pub = false;
    if (std.mem.startsWith(u8, rest, "pub ")) {
        is_pub = true;
        rest = rest[4..];
    }
    for ([_][]const u8{ "export ", "extern " }) |w| if (std.mem.startsWith(u8, rest, w)) return;
    for ([_][]const u8{ "inline ", "noinline " }) |w| if (std.mem.startsWith(u8, rest, w)) {
        rest = rest[w.len..];
    };
    if (!std.mem.startsWith(u8, rest, "fn ")) return;
    rest = rest[3..];
    var n: usize = 0;
    while (n < rest.len and isIdent(rest[n])) n += 1;
    if (n == 0 or n >= rest.len or rest[n] != '(') return;
    const name = rest[0..n];
    // The body starts at the first `{` after the closing `)` of the
    // parameters, at parenthesis depth 0.
    const name_at = at + (t.len - rest.len) + n;
    var i = name_at;
    var paren: usize = 0;
    var open: ?usize = null;
    while (i < f.text.len) : (i += 1) {
        switch (f.text[i]) {
            '(' => paren += 1,
            ')' => paren -|= 1,
            ';' => if (paren == 0) break,
            '{' => if (paren == 0) {
                open = i;
                break;
            },
            else => {},
        }
    }
    var hash: u64 = 0;
    var len: usize = 0;
    if (open) |o| {
        const close = matchBrace(f.text, o);
        hash, len = bodyHash(f.text[name_at..close]);
    }
    try f.fns.append(a, .{ .name = name, .line = line_no, .is_pub = is_pub, .body_hash = hash, .body_len = len });
}

/// Tarjan's algorithm for the strongly connected components.
const Tarjan = struct {
    files: []File,
    index: []i64,
    low: []usize,
    on: []bool,
    stack: std.ArrayList(usize) = .empty,
    next: usize = 0,
    count: usize = 0,
    a: Allocator,

    fn visit(t: *Tarjan, v: usize) !void {
        t.index[v] = @intCast(t.next);
        t.low[v] = t.next;
        t.next += 1;
        try t.stack.append(t.a, v);
        t.on[v] = true;
        for (t.files[v].imports.items) |e| {
            if (e.in_test) continue;
            const w = e.to;
            if (t.index[w] < 0) {
                try t.visit(w);
                t.low[v] = @min(t.low[v], t.low[w]);
            } else if (t.on[w]) {
                t.low[v] = @min(t.low[v], @as(usize, @intCast(t.index[w])));
            }
        }
        if (t.low[v] == @as(usize, @intCast(t.index[v]))) {
            t.count += 1;
            while (true) {
                const w = t.stack.pop().?;
                t.on[w] = false;
                t.files[w].scc = t.count;
                if (w == v) break;
            }
        }
    }
};

fn isTestFile(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    return std.mem.endsWith(u8, base, "_tests.zig") or std.mem.endsWith(u8, base, "_test.zig") or
        std.mem.eql(u8, base, "tests.zig") or std.mem.indexOf(u8, path, "/tests/") != null;
}

/// True when the imports of `files[from]` reach `to_path` only from a
/// test block or from a test file.
fn testEdge(files: []const File, from: usize, to_path: []const u8) bool {
    if (isTestFile(files[from].path)) return true;
    for (files[from].imports.items) |e| {
        if (std.mem.eql(u8, files[e.to].path, to_path)) return e.in_test;
    }
    return false;
}

fn lessStr(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

const ignored_pub = [_][]const u8{ "main", "panic", "format", "hash", "eql", "lessThan", "jsonStringify", "jsonParse", "jsonParseFromValue" };

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(a);

    var src: []const u8 = "src";
    var areas_path: []const u8 = "tools/modmap.areas";
    var build_path: []const u8 = "build.zig";
    var dot_path: ?[]const u8 = null;
    var area_dot_path: ?[]const u8 = null;
    var only: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (i + 1 >= args.len) {
            try std.Io.File.stderr().writeStreamingAll(io, usage);
            std.process.exit(2);
        }
        i += 1;
        if (std.mem.eql(u8, arg, "--src")) src = args[i] else if (std.mem.eql(u8, arg, "--areas")) areas_path = args[i] else if (std.mem.eql(u8, arg, "--build")) build_path = args[i] else if (std.mem.eql(u8, arg, "--dot")) dot_path = args[i] else if (std.mem.eql(u8, arg, "--area-dot")) area_dot_path = args[i] else if (std.mem.eql(u8, arg, "--only")) only = args[i] else {
            try std.Io.File.stderr().writeStreamingAll(io, usage);
            std.process.exit(2);
        }
    }
    const cwd = Io.Dir.cwd();
    const cfg_text = try cwd.readFileAlloc(io, areas_path, a, .limited(1 << 20));
    const cfg = try parseConfig(a, cfg_text);
    const build_text = cwd.readFileAlloc(io, build_path, a, .limited(16 << 20)) catch "";

    // The files, sorted by path.
    var paths: std.ArrayList([]const u8) = .empty;
    {
        var dir = try cwd.openDir(io, src, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".zig")) continue;
            try paths.append(a, try std.mem.concat(a, u8, &.{ src, "/", e.path }));
        }
    }
    std.mem.sort([]const u8, paths.items, {}, lessStr);
    const files = try a.alloc(File, paths.items.len);
    var by_path: std.StringHashMapUnmanaged(usize) = .empty;
    for (paths.items, 0..) |p, n| {
        files[n] = .{ .path = p, .text = try cwd.readFileAlloc(io, p, a, .limited(64 << 20)) };
        try by_path.put(a, p, n);
        for (cfg.patterns.items) |pa| {
            if (patternMatch(pa[0], p)) files[n].area = pa[1];
        }
    }

    // The imports and the global identifier counts.
    var global: std.StringHashMapUnmanaged(u32) = .empty;
    for (files, 0..) |*f, n| {
        var raw: std.ArrayList(RawImport) = .empty;
        try scanFile(a, f, &raw);
        var it = f.counts.iterator();
        while (it.next()) |kv| {
            const gop = try global.getOrPut(a, kv.key_ptr.*);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += kv.value_ptr.*;
        }
        for (raw.items) |r| {
            const name, const line, const in_test = r;
            var target: ?[]const u8 = null;
            if (std.mem.endsWith(u8, name, ".zig")) {
                target = try normalJoin(a, std.fs.path.dirname(f.path) orelse ".", name);
            } else {
                for (cfg.modules.items) |m| if (std.mem.eql(u8, m[0], name)) {
                    target = m[1];
                };
            }
            if (target) |tp| {
                if (by_path.get(tp)) |to| {
                    var dup = false;
                    for (f.imports.items) |e| dup = dup or e.to == to;
                    if (!dup) {
                        try f.imports.append(a, .{ .to = to, .line = line, .in_test = in_test or isTestFile(tp) or isTestFile(f.path) });
                        try files[to].importers.append(a, n);
                    }
                } else try f.missing.append(a, name);
            } else if (!std.mem.eql(u8, name, "std") and !std.mem.eql(u8, name, "builtin") and !std.mem.eql(u8, name, "root")) {
                var dup = false;
                for (f.modules.items) |m| dup = dup or std.mem.eql(u8, m, name);
                if (!dup) try f.modules.append(a, name);
            }
        }
    }

    // The files that a root of the build reaches.
    var queue: std.ArrayList(usize) = .empty;
    {
        var k: usize = 0;
        const needle = try std.mem.concat(a, u8, &.{ "\"", src, "/" });
        while (std.mem.indexOfPos(u8, build_text, k, needle)) |at| {
            const q = std.mem.indexOfScalarPos(u8, build_text, at + 1, '"') orelse break;
            if (by_path.get(build_text[at + 1 .. q])) |n| try queue.append(a, n);
            k = q + 1;
        }
        for (cfg.roots.items) |r| if (by_path.get(r)) |n| try queue.append(a, n);
        var h: usize = 0;
        while (h < queue.items.len) : (h += 1) {
            const n = queue.items[h];
            if (files[n].reached) continue;
            files[n].reached = true;
            for (files[n].imports.items) |e| try queue.append(a, e.to);
        }
    }

    // The cycles.
    var tj: Tarjan = .{
        .files = files,
        .index = try a.alloc(i64, files.len),
        .low = try a.alloc(usize, files.len),
        .on = try a.alloc(bool, files.len),
        .a = a,
    };
    @memset(tj.index, -1);
    @memset(tj.on, false);
    for (0..files.len) |n| if (tj.index[n] < 0) try tj.visit(n);
    const scc_size = try a.alloc(usize, tj.count + 1);
    @memset(scc_size, 0);
    for (files) |f| scc_size[f.scc] += 1;

    const inCycle = struct {
        fn f(fs: []const File, sizes: []const usize, from: usize, to: usize) bool {
            if (from == to) return true;
            return fs[from].scc == fs[to].scc and sizes[fs[from].scc] > 1;
        }
    }.f;

    var out: std.ArrayList(u8) = .empty;
    const want = struct {
        fn f(o: ?[]const u8, name: []const u8) bool {
            const list = o orelse return true;
            var it = std.mem.splitScalar(u8, list, ',');
            while (it.next()) |s| if (std.mem.eql(u8, s, name)) return true;
            return false;
        }
    }.f;

    // The area names, in the order of the areas file, then the others.
    var area_names: std.ArrayList([]const u8) = .empty;
    for (cfg.areas.items) |ar| try area_names.append(a, ar.name);
    for (files) |f| {
        var seen = false;
        for (area_names.items) |n| seen = seen or std.mem.eql(u8, n, f.area);
        if (!seen) try area_names.append(a, f.area);
    }
    const areaIndex = struct {
        fn f(names: []const []const u8, name: []const u8) usize {
            for (names, 0..) |n, k| if (std.mem.eql(u8, n, name)) return k;
            unreachable;
        }
    }.f;
    const na = area_names.items.len;
    const area_edges = try a.alloc(usize, na * na);
    @memset(area_edges, 0);
    var total_lines: usize = 0;
    var total_tests: usize = 0;
    var total_edges: usize = 0;
    var breaks: usize = 0;
    var cycle_edges: usize = 0;
    for (files, 0..) |f, n| {
        total_lines += f.lines;
        total_tests += f.tests;
        for (f.imports.items) |e| {
            total_edges += 1;
            if (e.in_test) continue;
            const t = files[e.to];
            if (inCycle(files, scc_size, n, e.to)) cycle_edges += 1;
            if (!cfg.allowed(f.area, t.area)) breaks += 1;
            area_edges[areaIndex(area_names.items, f.area) * na + areaIndex(area_names.items, t.area)] += 1;
        }
    }
    var cycles: usize = 0;
    for (scc_size[1..]) |s| if (s > 1) {
        cycles += 1;
    };

    try out.print(a, "# Module map of `{s}/`\n\n", .{src});
    if (want(only, "summary")) {
        var unreached: usize = 0;
        for (files) |f| if (!f.reached) {
            unreached += 1;
        };
        try out.print(a, "## Summary\n\n| Item | Count |\n|---|---|\n", .{});
        try out.print(a, "| Files | {d} |\n| Lines | {d} |\n| Test blocks | {d} |\n| Imports between files (test imports too) | {d} |\n", .{ files.len, total_lines, total_tests, total_edges });
        try out.print(a, "| Cycles (components of 2 or more files) | {d} |\n| Imports in a cycle | {d} |\n| Layering breaks | {d} |\n| Files that no build root reaches | {d} |\n\n", .{ cycles, cycle_edges, breaks, unreached });
        try out.print(a, "Files above 2000 lines:\n\n", .{});
        for (files) |f| if (f.lines > 2000) try out.print(a, "- `{s}`: {d} lines\n", .{ f.path, f.lines });
        try out.print(a, "\n", .{});
    }
    if (want(only, "areas")) {
        try out.print(a, "## Areas\n\n| Area | Files | Lines | Test blocks | Imports (area: count) |\n|---|---|---|---|---|\n", .{});
        for (area_names.items, 0..) |an, k| {
            var nf: usize = 0;
            var nl: usize = 0;
            var nt: usize = 0;
            for (files) |f| if (std.mem.eql(u8, f.area, an)) {
                nf += 1;
                nl += f.lines;
                nt += f.tests;
            };
            if (nf == 0) continue;
            try out.print(a, "| {s} | {d} | {d} | {d} | ", .{ an, nf, nl, nt });
            var first = true;
            for (area_names.items, 0..) |bn, m| {
                const c = area_edges[k * na + m];
                if (c == 0 or m == k) continue;
                const mark = if (cfg.allowed(an, bn)) "" else " (break)";
                try out.print(a, "{s}{s}: {d}{s}", .{ if (first) "" else ", ", bn, c, mark });
                first = false;
            }
            try out.print(a, " |\n", .{});
        }
        try out.print(a, "\n", .{});
    }
    if (want(only, "cycles")) {
        try out.print(a, "## Cycles\n\nEach list is one strongly connected component: each file reaches each other file of the list through imports.\n\n", .{});
        var k: usize = 1;
        while (k <= tj.count) : (k += 1) {
            if (scc_size[k] < 2) continue;
            try out.print(a, "- {d} files:", .{scc_size[k]});
            for (files) |f| if (f.scc == k) try out.print(a, " `{s}`", .{f.path});
            try out.print(a, "\n", .{});
        }
        for (files, 0..) |f, n| for (f.imports.items) |e| if (e.to == n and !e.in_test) try out.print(a, "- `{s}` imports itself at line {d}\n", .{ f.path, e.line });
        try out.print(a, "\n", .{});
    }
    if (want(only, "layers")) {
        try out.print(a, "## Layering breaks\n\n", .{});
        for (files) |f| for (f.imports.items) |e| {
            const t = files[e.to];
            if (!e.in_test and !cfg.allowed(f.area, t.area))
                try out.print(a, "- `{s}:{d}` ({s}) imports `{s}` ({s})\n", .{ f.path, e.line, f.area, t.path, t.area });
        };
        try out.print(a, "\n", .{});
    }
    if (want(only, "unmapped")) {
        try out.print(a, "## Files with no area\n\n", .{});
        for (files) |f| if (std.mem.eql(u8, f.area, "unmapped")) try out.print(a, "- `{s}`\n", .{f.path});
        try out.print(a, "\n## Imports of a missing file\n\n", .{});
        for (files) |f| for (f.missing.items) |m| try out.print(a, "- `{s}` imports `{s}`\n", .{ f.path, m });
        try out.print(a, "\n", .{});
    }
    if (want(only, "deadfiles")) {
        try out.print(a, "## Files that no build root reaches\n\nThe roots are the `\"{s}/...zig\"` strings of `{s}` and the `root` lines of `{s}`.\n\n", .{ src, build_path, areas_path });
        for (files) |f| if (!f.reached) try out.print(a, "- `{s}` ({d} lines, imported by {d} files)\n", .{ f.path, f.lines, f.importers.items.len });
        try out.print(a, "\n", .{});
    }
    if (want(only, "deadfns")) {
        try out.print(a, "## Functions with no use\n\nPrivate functions whose name is in their file one time:\n\n", .{});
        for (files) |f| for (f.fns.items) |fun| {
            if (!fun.is_pub and (f.counts.get(fun.name) orelse 0) <= 1)
                try out.print(a, "- `{s}:{d}` `{s}`\n", .{ f.path, fun.line, fun.name });
        };
        try out.print(a, "\nPublic functions whose name is in the tree one time (an embedder or a build file can still use them):\n\n", .{});
        for (files) |f| for (f.fns.items) |fun| {
            var skip = false;
            for (ignored_pub) |ig| skip = skip or std.mem.eql(u8, ig, fun.name);
            if (fun.is_pub and !skip and (global.get(fun.name) orelse 0) <= 1)
                try out.print(a, "- `{s}:{d}` `{s}`\n", .{ f.path, fun.line, fun.name });
        };
        try out.print(a, "\n", .{});
    }
    if (want(only, "dups")) {
        try out.print(a, "## Duplicate bodies\n\nFunctions in two or more files with the same text after the name, without space and comments (60 characters or more):\n\n", .{});
        var groups: std.AutoHashMapUnmanaged(u64, std.ArrayList([3][]const u8)) = .empty;
        var order: std.ArrayList(u64) = .empty;
        for (files) |f| for (f.fns.items) |fun| {
            if (fun.body_len < 60) continue;
            const gop = try groups.getOrPut(a, fun.body_hash);
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
                try order.append(a, fun.body_hash);
            }
            try gop.value_ptr.append(a, .{ f.path, try std.fmt.allocPrint(a, "{d}", .{fun.line}), fun.name });
        };
        for (order.items) |h| {
            const g = groups.get(h).?;
            var other = false;
            for (g.items) |x| other = other or !std.mem.eql(u8, x[0], g.items[0][0]);
            if (!other) continue;
            try out.print(a, "-", .{});
            for (g.items) |x| try out.print(a, " `{s}:{s}` `{s}`", .{ x[0], x[1], x[2] });
            try out.print(a, "\n", .{});
        }
        try out.print(a, "\n## Helpers by word\n\nFunctions whose lowercase name has the word, when two or more files have one:\n\n", .{});
        for (cfg.dupwords.items) |w| {
            var hits: std.ArrayList(u8) = .empty;
            var nfiles: usize = 0;
            var last: []const u8 = "";
            for (files) |f| for (f.fns.items) |fun| {
                const low = try std.ascii.allocLowerString(a, fun.name);
                if (std.mem.indexOf(u8, low, w) == null) continue;
                if (!std.mem.eql(u8, last, f.path)) nfiles += 1;
                last = f.path;
                try hits.print(a, " `{s}:{d}` `{s}`", .{ f.path, fun.line, fun.name });
            };
            if (nfiles >= 2) try out.print(a, "- {s} ({d} files):{s}\n", .{ w, nfiles, hits.items });
        }
        try out.print(a, "\n", .{});
    }
    if (want(only, "map")) {
        try out.print(a, "## Files\n\n", .{});
        for (files) |f| {
            try out.print(a, "### `{s}`\n\n{d} lines, {d} test blocks, area {s}", .{ f.path, f.lines, f.tests, f.area });
            if (!f.reached) try out.print(a, ", no build root reaches it", .{});
            try out.print(a, ".\n\n- Imports:", .{});
            for (f.imports.items) |e| try out.print(a, " `{s}`", .{files[e.to].path});
            for (f.modules.items) |m| try out.print(a, " module `{s}`", .{m});
            try out.print(a, "\n- Imported by:", .{});
            for (f.importers.items) |n| if (!testEdge(files, n, f.path)) try out.print(a, " `{s}`", .{files[n].path});
            try out.print(a, "\n- Tested by:", .{});
            if (f.tests > 0) try out.print(a, " its own {d} test blocks", .{f.tests});
            for (f.importers.items) |n| if (testEdge(files, n, f.path)) try out.print(a, " `{s}`", .{files[n].path});
            try out.print(a, "\n\n", .{});
        }
    }
    try std.Io.File.stdout().writeStreamingAll(io, out.items);

    if (dot_path) |dp| {
        var d: std.ArrayList(u8) = .empty;
        try d.print(a, "digraph modmap {{\n  rankdir=LR;\n  node [shape=box, fontsize=10];\n", .{});
        for (area_names.items, 0..) |an, k| {
            try d.print(a, "  subgraph cluster_{d} {{\n    label=\"{s}\";\n", .{ k, an });
            for (files, 0..) |f, n| if (std.mem.eql(u8, f.area, an)) try d.print(a, "    n{d} [label=\"{s}\\n{d}\"];\n", .{ n, f.path[src.len + 1 ..], f.lines });
            try d.print(a, "  }}\n", .{});
        }
        for (files, 0..) |f, n| for (f.imports.items) |e| {
            const attr = if (e.in_test) " [style=dashed, color=gray]" else if (inCycle(files, scc_size, n, e.to)) " [color=red]" else if (!cfg.allowed(f.area, files[e.to].area)) " [color=orange, penwidth=2]" else "";
            try d.print(a, "  n{d} -> n{d}{s};\n", .{ n, e.to, attr });
        };
        try d.print(a, "}}\n", .{});
        try cwd.writeFile(io, .{ .sub_path = dp, .data = d.items });
    }
    if (area_dot_path) |dp| {
        var d: std.ArrayList(u8) = .empty;
        try d.print(a, "digraph areas {{\n  node [shape=box];\n", .{});
        for (area_names.items, 0..) |an, k| for (area_names.items, 0..) |bn, m| {
            const c = area_edges[k * na + m];
            if (c == 0 or k == m) continue;
            const attr = if (cfg.allowed(an, bn)) "" else ", color=orange, penwidth=2";
            try d.print(a, "  \"{s}\" -> \"{s}\" [label=\"{d}\"{s}];\n", .{ an, bn, c, attr });
        };
        try d.print(a, "}}\n", .{});
        try cwd.writeFile(io, .{ .sub_path = dp, .data = d.items });
    }
}

test "patterns match a folder, a glob in one part, and a full path" {
    try std.testing.expect(patternMatch("src/vm/", "src/vm/nat/nat.zig"));
    try std.testing.expect(!patternMatch("src/vm/", "src/vm.zig"));
    try std.testing.expect(patternMatch("src/sys*.zig", "src/sys_wasi3.zig"));
    try std.testing.expect(!patternMatch("src/*_tests.zig", "src/vm/a_tests.zig"));
    try std.testing.expect(patternMatch("src/*/*_tests.zig", "src/vm/a_tests.zig"));
    try std.testing.expect(patternMatch("src/vm.zig", "src/vm.zig"));
}

test "an import path joins the folder of the file and drops . and .." {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("src/value.zig", try normalJoin(a, "src/vm/nat", "../../value.zig"));
    try std.testing.expectEqualStrings("src/vm/queue.zig", try normalJoin(a, "src/vm", "./queue.zig"));
}

test "a body hash drops space and comments, and a brace in a string does not count" {
    const x = bodyHash("(a: u8) u8 {\n    // one\n    return a + 1;\n}");
    const y = bodyHash("(a: u8) u8 { return a + 1; }");
    try std.testing.expectEqual(x[0], y[0]);
    const text = "{ const s = \"}\"; }";
    try std.testing.expectEqual(text.len, matchBrace(text, 0));
}

test "the areas file gives the rules of the layers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const cfg = try parseConfig(arena.allocator(), "area core\narea cmds core # comment\narea api *\nsrc/x.zig core\n");
    try std.testing.expect(cfg.allowed("cmds", "core"));
    try std.testing.expect(!cfg.allowed("core", "cmds"));
    try std.testing.expect(cfg.allowed("api", "cmds"));
    try std.testing.expect(cfg.allowed("core", "core"));
    try std.testing.expectEqual(@as(usize, 1), cfg.patterns.items.len);
}
