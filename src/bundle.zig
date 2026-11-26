//! `ztk bundle`: writes a macOS app, a folder `Name.app`, from any host.
//!
//!   Name.app/Contents/Info.plist
//!   Name.app/Contents/MacOS/Name           a copy of a macOS ztk program
//!   Name.app/Contents/Resources/ztk.conf   the main script and the capabilities
//!   Name.app/Contents/Resources/app/       the scripts and the files
//!   Name.app/Contents/Resources/AppIcon.icns
//!
//! The program in the bundle is ztk itself. At the start, ztk looks for
//! `../Resources/ztk.conf` next to its folder when that folder is
//! `Something.app/Contents/MacOS`. With the file, ztk runs the main script
//! of the bundle with the capabilities of the file, the folder `app` as
//! its root, and each word of the command line as an argument of the
//! script, so a flag cannot add a capability.
//!
//! The icon set comes from one PNG, scaled to each size of an `.icns`
//! file up to the size of the PNG. Each image of the set is a PNG.
//! `--menu-bar-only` sets `LSUIElement`: the app has no Dock icon and no
//! menu bar of its own, for an app that lives in a tray.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const png = @import("png.zig");
const Image = @import("render/renderer.zig").Image;
const Capability = @import("ztcl").interp.Capability;

pub const usage =
    \\usage: ztk bundle -o Name.app [options] main.tcl [file or folder ...]
    \\  --name NAME        the name of the app (default: the name of -o)
    \\  --id ID            the bundle identifier (default: org.ztk.NAME)
    \\  --version V        the version (default: 1.0)
    \\  --icon FILE.png    the icon, square, 1024 pixels or less
    \\  --allow CAPS       the capabilities of the app, as for ztk --allow
    \\  --menu-bar-only    no Dock icon (LSUIElement), for an app with a tray
    \\  --runner FILE      the macOS ztk program to copy (default: this program)
    \\  --no-sign          on macOS, leave the app unsigned (default: an ad hoc signature)
    \\
;

pub const Options = struct {
    name: []const u8,
    id: []const u8,
    version: []const u8 = "1.0",
    menu_bar_only: bool = false,
};

/// The start of a program in a bundle: the main script and the root.
pub const Start = struct {
    main: []const u8,
    root: []const u8,
    allow: u32,
};

/// The start of the bundle that has this program, or null when the
/// program is not in a bundle with a `ztk.conf`.
pub fn start(io: Io, arena: std.mem.Allocator) ?Start {
    const dir = std.process.executableDirPathAlloc(io, arena) catch return null;
    if (!std.mem.endsWith(u8, dir, ".app/Contents/MacOS")) return null;
    const res = std.fs.path.join(arena, &.{ dir, "..", "Resources" }) catch return null;
    const conf_path = std.fs.path.join(arena, &.{ res, "ztk.conf" }) catch return null;
    const text = Io.Dir.cwd().readFileAlloc(io, conf_path, arena, .limited(1 << 16)) catch return null;
    const conf = parseConf(text) orelse return null;
    const root = std.fs.path.join(arena, &.{ res, "app" }) catch return null;
    return .{
        .main = std.fs.path.join(arena, &.{ root, conf.main }) catch return null,
        .root = root,
        .allow = conf.allow,
    };
}

const Conf = struct { main: []const u8, allow: u32 };

/// Reads `main=` and `allow=` lines. Null without a main script, with an
/// unknown capability, or with a main path that leaves the folder.
fn parseConf(text: []const u8) ?Conf {
    var main: ?[]const u8 = null;
    var allow: u32 = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "main")) main = value;
        if (std.mem.eql(u8, key, "allow") and value.len > 0) allow = Capability.parse(value) orelse return null;
    }
    const m = main orelse return null;
    if (!safeRelative(m)) return null;
    return .{ .main = m, .allow = allow };
}

/// A relative path with no `..` part.
fn safeRelative(p: []const u8) bool {
    if (p.len == 0 or std.fs.path.isAbsolute(p)) return false;
    var parts = std.mem.tokenizeAny(u8, p, "/\\");
    while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

// ---- Info.plist ----

fn xmlText(w: *Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(c),
    };
}

fn plistKey(w: *Io.Writer, k: []const u8, v: []const u8) !void {
    try w.print("\t<key>{s}</key>\n\t<string>", .{k});
    try xmlText(w, v);
    try w.writeAll("</string>\n");
}

pub fn plist(gpa: std.mem.Allocator, o: Options, has_icon: bool) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\
    );
    try plistKey(w, "CFBundleName", o.name);
    try plistKey(w, "CFBundleDisplayName", o.name);
    try plistKey(w, "CFBundleIdentifier", o.id);
    try plistKey(w, "CFBundleExecutable", o.name);
    try plistKey(w, "CFBundlePackageType", "APPL");
    try plistKey(w, "CFBundleShortVersionString", o.version);
    try plistKey(w, "CFBundleVersion", o.version);
    try plistKey(w, "CFBundleInfoDictionaryVersion", "6.0");
    try plistKey(w, "LSMinimumSystemVersion", "13.0");
    try plistKey(w, "NSPrincipalClass", "NSApplication");
    if (has_icon) try plistKey(w, "CFBundleIconFile", "AppIcon");
    try w.writeAll("\t<key>NSHighResolutionCapable</key>\n\t<true/>\n");
    if (o.menu_bar_only) try w.writeAll("\t<key>LSUIElement</key>\n\t<true/>\n");
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

// ---- The icon set ----

/// The kinds of an `.icns` file and their sizes in pixels.
const icon_kinds = [_]struct { *const [4]u8, u32 }{
    .{ "icp4", 16 },  .{ "icp5", 32 },  .{ "ic11", 32 },   .{ "icp6", 64 },
    .{ "ic12", 64 },  .{ "ic07", 128 }, .{ "ic08", 256 },  .{ "ic13", 256 },
    .{ "ic09", 512 }, .{ "ic14", 512 }, .{ "ic10", 1024 },
};

/// An `.icns` file of PNG images from one PNG, for each size up to the
/// size of the source.
pub fn icns(gpa: std.mem.Allocator, png_bytes: []const u8) ![]u8 {
    const src = try png.decode(gpa, png_bytes);
    defer gpa.free(src.pixels);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "icns\x00\x00\x00\x00");
    const big = @max(src.width, src.height);
    for (icon_kinds) |k| {
        if (k[1] > big and k[1] != 16) continue;
        const img = try scale(gpa, src, k[1]);
        defer gpa.free(img.pixels);
        const data = try png.encode(gpa, img);
        defer gpa.free(data);
        try out.appendSlice(gpa, k[0]);
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(data.len + 8), .big);
        try out.appendSlice(gpa, &len);
        try out.appendSlice(gpa, data);
    }
    std.mem.writeInt(u32, out.items[4..8], @intCast(out.items.len), .big);
    return out.toOwnedSlice(gpa);
}

/// A square image of `size` pixels: the source fits in it with its shape,
/// in the middle, with the mean of the source pixels under each target
/// pixel. The colors are weighted by alpha.
pub fn scale(gpa: std.mem.Allocator, src: Image, size: u32) !Image {
    const px = try gpa.alloc(u8, @as(usize, size) * size * 4);
    @memset(px, 0);
    const big: f64 = @floatFromInt(@max(src.width, src.height));
    const f: f64 = big / @as(f64, @floatFromInt(size));
    // The offset of the source in a square of side `big`.
    const ox = (big - @as(f64, @floatFromInt(src.width))) / 2;
    const oy = (big - @as(f64, @floatFromInt(src.height))) / 2;
    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const x0 = @as(f64, @floatFromInt(x)) * f - ox;
            const y0 = @as(f64, @floatFromInt(y)) * f - oy;
            var acc: [4]f64 = @splat(0);
            var n: f64 = 0;
            const sx0: i64 = @intFromFloat(@floor(x0));
            const sy0: i64 = @intFromFloat(@floor(y0));
            const sx1: i64 = @max(sx0 + 1, @as(i64, @intFromFloat(@ceil(x0 + f))));
            const sy1: i64 = @max(sy0 + 1, @as(i64, @intFromFloat(@ceil(y0 + f))));
            var sy = sy0;
            while (sy < sy1) : (sy += 1) {
                var sx = sx0;
                while (sx < sx1) : (sx += 1) {
                    n += 1;
                    if (sx < 0 or sy < 0 or sx >= src.width or sy >= src.height) continue;
                    const i: usize = (@as(usize, @intCast(sy)) * src.width + @as(usize, @intCast(sx))) * 4;
                    const a: f64 = @floatFromInt(src.pixels[i + 3]);
                    for (0..3) |c| acc[c] += @as(f64, @floatFromInt(src.pixels[i + c])) * a;
                    acc[3] += a;
                }
            }
            const o: usize = (@as(usize, y) * size + x) * 4;
            if (acc[3] > 0) {
                for (0..3) |c| px[o + c] = @intFromFloat(@round(acc[c] / acc[3]));
                px[o + 3] = @intFromFloat(@round(acc[3] / n));
            }
        }
    }
    return .{ .width = size, .height = size, .pixels = px };
}

// ---- The command ----

fn isMachO(bytes: []const u8) bool {
    if (bytes.len < 4) return false;
    const m = std.mem.readInt(u32, bytes[0..4], .little);
    // MH_MAGIC_64, and FAT_MAGIC as the file stores it (big-endian).
    return m == 0xfeedfacf or m == 0xbebafeca;
}

/// The default bundle identifier: org.ztk. and the letters and digits of
/// the name in lower case.
fn defaultId(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, "org.ztk.");
    for (name) |c| if (std.ascii.isAlphanumeric(c)) try out.append(a, std.ascii.toLower(c));
    if (out.items.len == 8) try out.appendSlice(a, "app");
    return out.toOwnedSlice(a);
}

fn copyTree(io: Io, a: std.mem.Allocator, src: []const u8, dest_root: Io.Dir, dest: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var dir = cwd.openDir(io, src, .{ .iterate = true }) catch |e| switch (e) {
        error.NotDir => {
            try cwd.copyFile(src, dest_root, dest, io, .{ .make_path = true });
            return;
        },
        else => return e,
    };
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const to = try std.fs.path.join(a, &.{ dest, entry.path });
        try dir.copyFile(entry.path, dest_root, to, io, .{ .make_path = true });
    }
}

/// The path of an embedded file in `app/`: the path as given when it is
/// relative and stays in the folder, else its last part.
fn embedPath(p: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, p, "/");
    if (safeRelative(trimmed)) return trimmed;
    return std.fs.path.basename(trimmed);
}

/// Runs `ztk bundle`. `args` are the words after `bundle`. Gives the exit code.
pub fn run(io: Io, a: std.mem.Allocator, args: []const [:0]const u8, err: *Io.Writer) !u8 {
    var output: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var version: []const u8 = "1.0";
    var icon: ?[]const u8 = null;
    var allow: []const u8 = "file,channels";
    var menu_bar_only = false;
    var runner: ?[]const u8 = null;
    var sign = @import("builtin").os.tag == .macos;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        const slot: ?*?[]const u8 = if (std.mem.eql(u8, arg, "-o")) &output else if (std.mem.eql(u8, arg, "--name")) &name else if (std.mem.eql(u8, arg, "--id")) &id else if (std.mem.eql(u8, arg, "--icon")) &icon else if (std.mem.eql(u8, arg, "--runner")) &runner else null;
        if (slot) |s| {
            s.* = value orelse return usageError(err, "ztk bundle: {s} needs a value\n", .{arg});
            i += 1;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "--allow")) {
            const v = value orelse return usageError(err, "ztk bundle: {s} needs a value\n", .{arg});
            if (arg[2] == 'v') version = v else allow = v;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--menu-bar-only")) {
            menu_bar_only = true;
        } else if (std.mem.eql(u8, arg, "--no-sign")) {
            sign = false;
        } else if (arg.len > 1 and arg[0] == '-') {
            return usageError(err, "ztk bundle: unknown flag {s}\n", .{arg});
        } else try files.append(a, arg);
    }
    const out_path = output orelse return usageError(err, "ztk bundle: needs -o Name.app\n", .{});
    if (files.items.len == 0) return usageError(err, "ztk bundle: needs a main script\n", .{});
    if (Capability.parse(allow) == null) return usageError(err, "ztk bundle: unknown capability in \"{s}\"\n", .{allow});
    const base = std.fs.path.basename(std.mem.trimEnd(u8, out_path, "/"));
    const app_name = name orelse (if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base);
    if (app_name.len == 0 or std.mem.indexOfAny(u8, app_name, "/\\") != null) return usageError(err, "ztk bundle: bad name \"{s}\"\n", .{app_name});
    const opts: Options = .{ .name = app_name, .id = id orelse try defaultId(a, app_name), .version = version, .menu_bar_only = menu_bar_only };

    // The program to copy: a macOS ztk.
    const runner_path = runner orelse try std.process.executablePathAlloc(io, a);
    const cwd = Io.Dir.cwd();
    const exe = cwd.readFileAlloc(io, runner_path, a, .limited(512 << 20)) catch |e| {
        try err.print("ztk bundle: {s}: {s}\n", .{ runner_path, @errorName(e) });
        return 1;
    };
    if (!isMachO(exe)) {
        try err.print("ztk bundle: {s} is no macOS program. Give a macOS ztk with --runner.\n", .{runner_path});
        return 1;
    }

    // The icon set, before the first write, so a bad icon leaves no half app.
    var icon_set: ?[]const u8 = null;
    if (icon) |p| {
        const bytes = cwd.readFileAlloc(io, p, a, .limited(64 << 20)) catch |e| {
            try err.print("ztk bundle: {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        icon_set = icns(a, bytes) catch |e| {
            try err.print("ztk bundle: {s}: {s}: the icon is an 8-bit RGBA PNG\n", .{ p, @errorName(e) });
            return 1;
        };
    }

    try cwd.createDirPath(io, out_path);
    var app = try cwd.openDir(io, out_path, .{});
    defer app.close(io);
    try app.createDirPath(io, "Contents/MacOS");
    try app.createDirPath(io, "Contents/Resources/app");
    const exe_path = try std.fs.path.join(a, &.{ "Contents/MacOS", app_name });
    try app.writeFile(io, .{ .sub_path = exe_path, .data = exe, .flags = .{ .permissions = .fromMode(0o755) } });

    const main_name = std.fs.path.basename(files.items[0]);
    try cwd.copyFile(files.items[0], app, try std.fs.path.join(a, &.{ "Contents/Resources/app", main_name }), io, .{});
    for (files.items[1..]) |f| {
        try copyTree(io, a, f, app, try std.fs.path.join(a, &.{ "Contents/Resources/app", embedPath(f) }));
    }
    const conf = try std.fmt.allocPrint(a, "main={s}\nallow={s}\n", .{ main_name, allow });
    try app.writeFile(io, .{ .sub_path = "Contents/Resources/ztk.conf", .data = conf });

    if (icon_set) |set| try app.writeFile(io, .{ .sub_path = "Contents/Resources/AppIcon.icns", .data = set });
    try app.writeFile(io, .{ .sub_path = "Contents/Info.plist", .data = try plist(a, opts, icon != null) });
    try app.writeFile(io, .{ .sub_path = "Contents/PkgInfo", .data = "APPL????" });
    // The program has the ad hoc signature of the linker, which expects a
    // signed bundle around it. On macOS, an ad hoc signature of the whole
    // app seals the resources. A host with no codesign leaves the app as
    // it is: docs/macos-app.md has the steps for a signature.
    if (sign) {
        const r = std.process.run(a, io, .{ .argv = &.{ "codesign", "--force", "--sign", "-", out_path } }) catch |e| {
            try err.print("ztk bundle: codesign: {s}; the app is not signed\n", .{@errorName(e)});
            return 0;
        };
        if (r.term != .exited or r.term.exited != 0) {
            try err.print("ztk bundle: codesign failed: {s}", .{r.stderr});
            return 1;
        }
    }
    return 0;
}

fn usageError(err: *Io.Writer, comptime fmt: []const u8, args: anytype) !u8 {
    try err.print(fmt, args);
    try err.writeAll(usage);
    return 2;
}

const t = std.testing;

test "bundle: the conf file gives the main script and the capabilities" {
    const c = parseConf("main=demo.tcl\nallow=file,channels\n").?;
    try t.expectEqualStrings("demo.tcl", c.main);
    try t.expectEqual(Capability.parse("file,channels").?, c.allow);
    try t.expect(parseConf("allow=file\n") == null);
    try t.expect(parseConf("main=../x.tcl\n") == null);
    try t.expect(parseConf("main=/etc/x.tcl\n") == null);
    try t.expect(parseConf("main=a.tcl\nallow=root\n") == null);
    try t.expectEqual(@as(u32, 0), parseConf("main=a.tcl\r\n").?.allow);
}

test "bundle: Info.plist has the keys of the app" {
    const text = try plist(t.allocator, .{ .name = "A & B", .id = "org.ztk.ab", .menu_bar_only = true }, true);
    defer t.allocator.free(text);
    try t.expect(std.mem.indexOf(u8, text, "<string>A &amp; B</string>") != null);
    try t.expect(std.mem.indexOf(u8, text, "<key>LSUIElement</key>\n\t<true/>") != null);
    try t.expect(std.mem.indexOf(u8, text, "<key>CFBundleIconFile</key>\n\t<string>AppIcon</string>") != null);
    const plain = try plist(t.allocator, .{ .name = "A", .id = "x" }, false);
    defer t.allocator.free(plain);
    try t.expect(std.mem.indexOf(u8, plain, "LSUIElement") == null);
}

test "bundle: a scaled icon keeps its color and its shape" {
    // A 4 by 2 red bar: in a square of 2, the bar fills the middle row band.
    var px: [4 * 2 * 4]u8 = undefined;
    var k: usize = 0;
    while (k < px.len) : (k += 4) px[k..][0..4].* = .{ 255, 0, 0, 255 };
    const img = try scale(t.allocator, .{ .width = 4, .height = 2, .pixels = &px }, 4);
    defer t.allocator.free(img.pixels);
    // The top row is empty, the middle rows are red.
    try t.expectEqual(@as(u8, 0), img.pixels[3]);
    const mid = (1 * 4 + 1) * 4;
    try t.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, img.pixels[mid .. mid + 4]);
}

test "bundle: an icns file has a PNG for each size up to the source" {
    var px: [32 * 32 * 4]u8 = @splat(200);
    const src = try png.encode(t.allocator, .{ .width = 32, .height = 32, .pixels = &px });
    defer t.allocator.free(src);
    const set = try icns(t.allocator, src);
    defer t.allocator.free(set);
    try t.expectEqualStrings("icns", set[0..4]);
    try t.expectEqual(@as(u32, @intCast(set.len)), std.mem.readInt(u32, set[4..8], .big));
    // icp4 (16), icp5 (32), ic11 (32): three entries.
    var n: usize = 0;
    var at: usize = 8;
    while (at < set.len) : (n += 1) at += std.mem.readInt(u32, set[at + 4 ..][0..4], .big);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("icp4", set[8..12]);
}

test "bundle: names and paths" {
    const id = try defaultId(t.allocator, "My App 2");
    defer t.allocator.free(id);
    try t.expectEqualStrings("org.ztk.myapp2", id);
    try t.expectEqualStrings("lib/x.tcl", embedPath("lib/x.tcl"));
    try t.expectEqualStrings("x.tcl", embedPath("/tmp/x.tcl"));
    try t.expectEqualStrings("lib", embedPath("../lib/"));
    try t.expect(isMachO(&.{ 0xcf, 0xfa, 0xed, 0xfe }));
    try t.expect(!isMachO("\x7fELF"));
}
