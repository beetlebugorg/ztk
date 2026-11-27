//! `ztk bundle`: writes a macOS app, a folder `Name.app`, from any host
//! and for the macOS target of `--target`, or with an output name that
//! has no `.app`, one program file of a target with the app in its slot
//! (`appbin.zig`). The ad hoc signature of the app comes from `codesign`
//! on macOS and from `machosign.zig` on the other hosts.
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
const png = @import("base/png.zig");
const peres = @import("peres.zig");
const Image = @import("render/renderer.zig").Image;
const ztcl = @import("ztcl");
const Capability = ztcl.interp.Capability;
const appbin = @import("appbin.zig");
const machosign = @import("machosign.zig");

pub const usage =
    \\usage: ztk bundle -o Name.app [--target T] [options] main.tcl [file or folder ...]
    \\       ztk bundle -o app [--target T] [--runner FILE] [--allow CAPS] main.tcl [file or folder ...]
    \\  -o FILE           with .app: a macOS app folder (with --target, x86_64-macos or
    \\                    aarch64-macos); without .app: one program file with the app in it
    \\  --target T        the target of one program file: x86_64-linux, aarch64-linux,
    \\                    x86_64-macos, aarch64-macos, x86_64-windows, aarch64-windows
    \\                    (default: this computer)
    \\  --name NAME        the name of the app (default: the name of -o)
    \\  --id ID            the bundle identifier (default: org.ztk.NAME)
    \\  --version V        the version (default: 1.0)
    \\  --icon FILE.png    the icon, square, 1024 pixels or less (a Windows program: a
    \\                    .ico, or a .png of 256 pixels or less)
    \\  --allow CAPS       the capabilities of the app, as for ztk --allow
    \\  --menu-bar-only    no Dock icon (LSUIElement), for an app with a tray
    \\  --runner FILE      the ztk program to copy (default: this program, or for one
    \\                    program file of another target lib/ztk/runtime/T/ next to it)
    \\  --desktop          with one program file of a Linux target: also write NAME.desktop
    \\                    and NAME.png (from --icon, 256 pixels) next to it
    \\  --no-sign          leave the app folder unsigned (default: an ad hoc signature
    \\                    with the JIT entitlement, from codesign on macOS)
    \\  --console          a Windows program with a console window (default: the GUI
    \\                    subsystem, with the console of the terminal that starts it)
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

/// The names in `app/` of the main script and of each other file or
/// folder. The names are relative to the deepest folder that has the
/// folder of the main script and each file and folder, so a path relative
/// to the main script in the source tree is the same path in the app. A
/// folder that is that root gives the name "" (its files go in at the
/// top). A path on another Windows drive gets its last part.
fn layout(io: Io, a: std.mem.Allocator, paths: []const []const u8) ![]const []const u8 {
    const cwd_path = try std.process.currentPathAlloc(io, a);
    const abs = try a.alloc([]const u8, paths.len);
    for (paths, abs) |p, *slot| slot.* = try std.fs.path.resolve(a, &.{ cwd_path, p });
    // The folder of each entry: the parent of a file, a folder itself.
    var root: []const u8 = std.fs.path.dirname(abs[0]) orelse abs[0];
    for (abs[1..]) |p| {
        const dir = if (isDir(io, p)) p else std.fs.path.dirname(p) orelse p;
        root = commonDir(root, dir);
    }
    const names = try a.alloc([]const u8, paths.len);
    for (abs, names, paths) |p, *slot, given| {
        const rel = try std.fs.path.relativeAlloc(a, cwd_path, null, root, p);
        const clean = try std.mem.replaceOwned(u8, a, rel, "\\", "/");
        slot.* = if (clean.len == 0 or safeRelative(clean)) clean else std.fs.path.basename(std.mem.trimEnd(u8, given, "/\\"));
    }
    return names;
}

fn isDir(io: Io, p: []const u8) bool {
    var d = Io.Dir.cwd().openDir(io, p, .{}) catch return false;
    d.close(io);
    return true;
}

/// The longest folder path that is a prefix of `x` and of `y` at a
/// separator. Both paths are absolute and resolved.
fn commonDir(x: []const u8, y: []const u8) []const u8 {
    var end: usize = 0;
    var k: usize = 0;
    while (k < x.len and k < y.len and x[k] == y[k]) : (k += 1) {
        if (std.fs.path.isSep(x[k])) end = k;
    }
    // The whole of the shorter path is a folder when the other path goes on with a separator there.
    if ((k == x.len and (k == y.len or std.fs.path.isSep(y[k]))) or (k == y.len and std.fs.path.isSep(x[k]))) end = k;
    // A root ("/" or "C:\") keeps its separator.
    if (end == 0 or (end == 2 and x.len > 2 and x[1] == ':')) end += 1;
    return x[0..@min(end, x.len)];
}

/// Runs `ztk bundle`. `args` are the words after `bundle`. Gives the exit code.
pub fn run(io: Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, args: []const [:0]const u8, err: *Io.Writer) !u8 {
    var strip: ztcl.stripbuild.Flags = .{};
    var output: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var id: ?[]const u8 = null;
    var version: []const u8 = "1.0";
    var icon: ?[]const u8 = null;
    var allow: []const u8 = "file,channels";
    var menu_bar_only = false;
    var runner: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var sign = true;
    var console = false;
    var desktop = false;
    var files: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const value: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (try strip.parse(a, args, &i)) continue;
        const slot: ?*?[]const u8 = if (std.mem.eql(u8, arg, "-o")) &output else if (std.mem.eql(u8, arg, "--target")) &target else if (std.mem.eql(u8, arg, "--name")) &name else if (std.mem.eql(u8, arg, "--id")) &id else if (std.mem.eql(u8, arg, "--icon")) &icon else if (std.mem.eql(u8, arg, "--runner")) &runner else null;
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
        } else if (std.mem.eql(u8, arg, "--console")) {
            console = true;
        } else if (std.mem.eql(u8, arg, "--desktop")) {
            desktop = true;
        } else if (arg.len > 1 and arg[0] == '-') {
            return usageError(err, "ztk bundle: unknown flag {s}\n", .{arg});
        } else try files.append(a, arg);
    }
    const out_path = output orelse return usageError(err, "ztk bundle: needs -o Name.app\n", .{});
    if (files.items.len == 0) return usageError(err, "ztk bundle: needs a main script\n", .{});
    if (Capability.parse(allow) == null) return usageError(err, "ztk bundle: unknown capability in \"{s}\"\n", .{allow});
    const is_app = std.mem.endsWith(u8, std.mem.trimEnd(u8, out_path, "/"), ".app");
    if (!is_app) {
        const tg = target orelse ztcl.buildnative.hostTarget();
        if (desktop and !std.mem.endsWith(u8, tg, "-linux")) return usageError(err, "ztk bundle: --desktop is for a Linux target, and the target is {s}\n", .{tg});
        const win: WinOpts = .{ .name = name, .version = version, .icon = icon, .console = console };
        if (strip.on) {
            if ((strip.check or strip.profile) and !std.mem.eql(u8, tg, ztcl.buildnative.hostTarget()))
                return usageError(err, "ztk bundle: --check and --profile run the program, so they need the target of this computer\n", .{});
            runner = try stripRuntime(io, a, env, &strip, tg, runner, allow, files.items, win, err) orelse return 1;
        } else if (strip.check or strip.profile or strip.keep.items.len > 0 or strip.drop.items.len > 0 or strip.trust) {
            return usageError(err, "ztk bundle: --keep, --drop-module, --trust-scan, --check, and --profile need --strip\n", .{});
        }
        const status = try single(io, a, err, out_path, tg, runner, allow, files.items, win);
        if (status != 0 or !desktop) return status;
        return desktopFiles(io, a, err, out_path, name, icon);
    }
    if (strip.on) return usageError(err, "ztk bundle: --strip makes one program file: leave out .app\n", .{});
    if (target) |tg| if (!std.mem.endsWith(u8, tg, "-macos")) {
        return usageError(err, "ztk bundle: a .app folder is for a macOS target. Leave out .app for one program file of {s}.\n", .{tg});
    };
    const base = std.fs.path.basename(std.mem.trimEnd(u8, out_path, "/"));
    const app_name = name orelse (if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base);
    if (app_name.len == 0 or std.mem.indexOfAny(u8, app_name, "/\\") != null) return usageError(err, "ztk bundle: bad name \"{s}\"\n", .{app_name});
    const opts: Options = .{ .name = app_name, .id = id orelse try defaultId(a, app_name), .version = version, .menu_bar_only = menu_bar_only };

    // The program to copy: a macOS ztk.
    const cwd = Io.Dir.cwd();
    const runner_path = if (target) |tg| try runtimePath(io, a, tg, "ztk", runner) else runner orelse try std.process.executablePathAlloc(io, a);
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
    try app.writeFile(io, .{ .sub_path = exe_path, .data = exe, .flags = .{ .permissions = exe_permissions } });

    const names = try layout(io, a, files.items);
    const main_name = names[0];
    try cwd.copyFile(files.items[0], app, try std.fs.path.join(a, &.{ "Contents/Resources/app", main_name }), io, .{ .make_path = true });
    for (files.items[1..], names[1..]) |f, n| {
        try copyTree(io, a, f, app, try std.fs.path.join(a, &.{ "Contents/Resources/app", n }));
    }
    const conf = try std.fmt.allocPrint(a, "main={s}\nallow={s}\n", .{ main_name, allow });
    try app.writeFile(io, .{ .sub_path = "Contents/Resources/ztk.conf", .data = conf });

    if (icon_set) |set| try app.writeFile(io, .{ .sub_path = "Contents/Resources/AppIcon.icns", .data = set });
    try app.writeFile(io, .{ .sub_path = "Contents/Info.plist", .data = try plist(a, opts, icon != null) });
    try app.writeFile(io, .{ .sub_path = "Contents/PkgInfo", .data = "APPL????" });
    // The program has the ad hoc signature of the linker, which expects a
    // signed bundle around it. An ad hoc signature of the whole app seals
    // the resources. macOS signs with codesign. The other hosts sign with
    // `machosign.zig`, which writes the same parts.
    if (!sign) return 0;
    if (@import("builtin").os.tag != .macos) {
        signApp(io, a, app, exe_path, exe, opts.id) catch |e| {
            try err.print("ztk bundle: {s}: the signature: {s}\n", .{ runner_path, @errorName(e) });
            return 1;
        };
        return 0;
    }
    // The entitlement of the JIT, which MAP_JIT needs under a
    // signature with the hardened runtime.
    const ents_path = try std.fmt.allocPrint(a, "{s}.entitlements", .{out_path});
    try cwd.writeFile(io, .{ .sub_path = ents_path, .data = entitlements });
    defer cwd.deleteFile(io, ents_path) catch {};
    const r = std.process.run(a, io, .{ .argv = &.{ "codesign", "--force", "--sign", "-", "--entitlements", ents_path, out_path } }) catch |e| {
        try err.print("ztk bundle: codesign: {s}; the app is not signed\n", .{@errorName(e)});
        return 0;
    };
    if (r.term != .exited or r.term.exited != 0) {
        try err.print("ztk bundle: codesign failed: {s}", .{r.stderr});
        return 1;
    }
    return 0;
}

/// Signs the app in `app` with `machosign`: writes
/// `Contents/_CodeSignature/CodeResources` and the signed program.
fn signApp(io: Io, a: std.mem.Allocator, app: Io.Dir, exe_path: []const u8, exe: []const u8, id: []const u8) !void {
    var res: std.ArrayList(machosign.Resource) = .empty;
    var contents = try app.openDir(io, "Contents", .{ .iterate = true });
    defer contents.close(io);
    var walker = try contents.walk(a);
    defer walker.deinit();
    const exe_rel = exe_path["Contents/".len..];
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const rel = try std.mem.replaceOwned(u8, a, entry.path, "\\", "/");
        if (std.mem.eql(u8, rel, exe_rel) or std.mem.eql(u8, rel, "Info.plist") or std.mem.eql(u8, rel, "PkgInfo")) continue;
        if (std.mem.startsWith(u8, rel, "_CodeSignature/")) continue;
        try res.append(a, .{ .path = rel, .data = try contents.readFileAlloc(io, entry.path, a, .limited(512 << 20)) });
    }
    const code_res = try machosign.codeResources(a, res.items);
    try app.createDirPath(io, "Contents/_CodeSignature");
    try app.writeFile(io, .{ .sub_path = "Contents/_CodeSignature/CodeResources", .data = code_res });
    const info = try app.readFileAlloc(io, "Contents/Info.plist", a, .limited(1 << 20));
    const signed = try machosign.sign(a, exe, .{ .ident = id, .info_plist = info, .code_resources = code_res, .entitlements = &.{"com.apple.security.cs.allow-jit"} });
    try app.writeFile(io, .{ .sub_path = exe_path, .data = signed, .flags = .{ .permissions = exe_permissions } });
}

/// The entitlements plist of an app.
const entitlements =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\    <key>com.apple.security.cs.allow-jit</key>
    \\    <true/>
    \\</dict>
    \\</plist>
    \\
;

/// The mode of the program in the app. Windows has no mode bits, so a
/// bundle from Windows gets its mode on the Mac, from the archive or from
/// `chmod +x`.
const exe_permissions: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o755);

/// Reads the files of an app for `appbin`, each below its name from
/// `layout`.
fn collect(io: Io, a: std.mem.Allocator, paths: []const []const u8) ![]appbin.File {
    const cwd = Io.Dir.cwd();
    var out: std.ArrayList(appbin.File) = .empty;
    const names = try layout(io, a, paths);
    for (paths, names) |p, name| {
        var dir = cwd.openDir(io, p, .{ .iterate = true }) catch |e| switch (e) {
            error.NotDir => {
                try out.append(a, .{ .name = name, .data = try cwd.readFileAlloc(io, p, a, .limited(256 << 20)) });
                continue;
            },
            else => return e,
        };
        defer dir.close(io);
        var walker = try dir.walk(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const rel = try std.mem.replaceOwned(u8, a, entry.path, "\\", "/");
            const full = if (name.len == 0) rel else try std.fmt.allocPrint(a, "{s}/{s}", .{ name, rel });
            try out.append(a, .{ .name = full, .data = try dir.readFileAlloc(io, entry.path, a, .limited(256 << 20)) });
        }
    }
    return out.items;
}

const strip_tool: ztcl.stripbuild.Tool = .{
    .name = "ztk bundle",
    .src_env = "ZTK_SRC",
    .manifest = "ztk-strip.txt",
    .program = "ztk",
    .ztk = true,
    .extra = &@import("features.zig").table,
};

/// The binaries of `--check` and `--profile`.
const TestCtx = struct {
    io: Io,
    a: std.mem.Allocator,
    target: []const u8,
    runner: ?[]const u8,
    allow: []const u8,
    win: WinOpts,
    err: *Io.Writer,

    fn build(c: TestCtx, runtime: ?[]const u8, entries: []const ztcl.wasmbundle.Entry, path: []const u8) anyerror!bool {
        var files: std.ArrayList(appbin.File) = .empty;
        // The first script runs: the main script of the app.
        for (entries) |e| if (e.kind == .script) try files.append(c.a, .{ .name = e.name, .data = e.data });
        for (entries) |e| if (e.kind != .script) try files.append(c.a, .{ .name = e.name, .data = e.data });
        var discard: Io.Writer.Allocating = .init(c.a);
        const code = try singleFiles(c.io, c.a, &discard.writer, path, c.target, runtime orelse c.runner, c.allow, files.items, c.win);
        if (code != 0) try c.err.writeAll(discard.written());
        return code == 0;
    }
};

/// Builds the stripped ztk program of `target` (`docs/strip.md`) and
/// gives its path, or null after a message.
fn stripRuntime(io: Io, a: std.mem.Allocator, env: *const std.process.Environ.Map, strip: *ztcl.stripbuild.Flags, target: []const u8, runner: ?[]const u8, allow: []const u8, paths: []const []const u8, win: WinOpts, err: *Io.Writer) !?[]const u8 {
    const files = try collect(io, a, paths);
    var entries: std.ArrayList(ztcl.wasmbundle.Entry) = .empty;
    for (files, 0..) |f, k| try entries.append(a, .{ .kind = if (k == 0) .script else .file, .name = f.name, .data = f.data });
    const bn = ztcl.buildnative;
    var file: []const u8 = "ztk";
    for (bn.targets) |tg| if (std.mem.eql(u8, tg.name, target)) {
        if (std.mem.endsWith(u8, tg.file, ".exe")) file = "ztk.exe";
    };
    const full = try runtimePath(io, a, target, file, runner);
    const ctx: TestCtx = .{ .io = io, .a = a, .target = target, .runner = runner, .allow = allow, .win = win, .err = err };
    const r = try ztcl.stripbuild.run(strip_tool, io, a, env, strip, .{ .target = target, .wasm = false, .allow = allow, .jit = true, .full_runtime = full }, entries.items, ctx, TestCtx.build, err) orelse return null;
    return r.runtime;
}

/// The ztk program of `target`: `runner`, else
/// `lib/ztk/runtime/TARGET/FILE` next to this program, else this program
/// for the target of this computer.
fn runtimePath(io: Io, a: std.mem.Allocator, target: []const u8, file: []const u8, runner: ?[]const u8) ![]const u8 {
    if (runner) |r| return r;
    const shipped = try std.fs.path.join(a, &.{ try std.process.executableDirPathAlloc(io, a), "..", "lib", "ztk", "runtime", target, file });
    if (Io.Dir.cwd().access(io, shipped, .{})) |_| return shipped else |_| {}
    if (std.mem.eql(u8, target, ztcl.buildnative.hostTarget())) return std.process.executablePathAlloc(io, a);
    return shipped;
}

/// Writes one program file: a copy of the ztk program of `target` with
/// the app in its slot (`appbin.zig`).
/// The numbers of a version such as `1.2.3`, with 0 for the parts that
/// it does not have.
fn versionParts(v: []const u8) [4]u16 {
    var out: [4]u16 = .{ 0, 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    var k: usize = 0;
    while (it.next()) |p| : (k += 1) {
        if (k == 4) break;
        out[k] = std.fmt.parseInt(u16, p, 10) catch 0;
    }
    return out;
}

/// The ztk program of Windows with the resources of the app: the icon of
/// `--icon` (`.ico`, or a `.png` of 256 pixels or less), the manifest of
/// `peres.defaultManifest`, and the version of `--name` and `--version`.
/// The subsystem is GUI unless `--console`, so the app opens no console
/// window, and the program attaches to the console of a terminal that
/// starts it.
fn windowsProgram(io: Io, a: std.mem.Allocator, runtime: []const u8, out_path: []const u8, win: WinOpts) ![]u8 {
    const base = std.fs.path.stem(out_path);
    const name = win.name orelse base;
    const ver = versionParts(win.version);
    var icons: []const peres.Icon = &.{};
    if (win.icon) |p| {
        const bytes = try Io.Dir.cwd().readFileAlloc(io, p, a, .limited(16 << 20));
        icons = if (std.ascii.endsWithIgnoreCase(p, ".ico")) try peres.iconsFromIco(a, bytes) else &.{try peres.iconFromPng(bytes)};
    }
    const exe_name = std.fs.path.basename(out_path);
    const out = try peres.add(a, runtime, .{
        .icons = icons,
        .manifest = try peres.defaultManifest(a, name, ver),
        .version = .{ .file = ver, .product = ver, .product_name = name, .description = name, .internal_name = base, .original_filename = exe_name },
    });
    try peres.setSubsystem(out, !win.console);
    return out;
}
/// The resources of a Windows program of `single`.
const WinOpts = struct { name: ?[]const u8, version: []const u8, icon: ?[]const u8, console: bool };

fn single(io: Io, a: std.mem.Allocator, err: *Io.Writer, out_path: []const u8, target: []const u8, runner: ?[]const u8, allow: []const u8, paths: []const []const u8, win: WinOpts) !u8 {
    return singleFiles(io, a, err, out_path, target, runner, allow, try collect(io, a, paths), win);
}

fn singleFiles(io: Io, a: std.mem.Allocator, err: *Io.Writer, out_path: []const u8, target: []const u8, runner: ?[]const u8, allow: []const u8, files: []const appbin.File, win: WinOpts) !u8 {
    const bn = ztcl.buildnative;
    var file: ?[]const u8 = null;
    for (bn.targets) |tg| if (std.mem.eql(u8, tg.name, target)) {
        file = if (std.mem.endsWith(u8, tg.file, ".exe")) "ztk.exe" else "ztk";
    };
    if (file == null) return usageError(err, "ztk bundle: unknown target \"{s}\"\n", .{target});
    const cwd = Io.Dir.cwd();
    const rt_path = try runtimePath(io, a, target, file.?, runner);
    const runtime = cwd.readFileAlloc(io, rt_path, a, .limited(512 << 20)) catch |e| {
        try err.print("ztk bundle: the ztk program of {s}: {s}: {s}. Give it with --runner.\n", .{ target, rt_path, @errorName(e) });
        return 1;
    };
    // A Windows program gets its icon, its manifest, and its version as
    // resources, and the GUI subsystem unless --console, before the app
    // goes in its slot.
    const program = if (std.mem.eql(u8, file.?, "ztk.exe")) windowsProgram(io, a, runtime, out_path, win) catch |e| {
        try err.print("ztk bundle: the resources of {s}: {s}\n", .{ out_path, @errorName(e) });
        return 1;
    } else runtime;
    const bin = appbin.build(a, program, files, allow, null, std.fs.path.basename(out_path)) catch |e| {
        try err.print("ztk bundle: {s}: {s}\n", .{ rt_path, appbin.describe(e) });
        return 1;
    };
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = bin, .flags = .{ .permissions = exe_permissions } });
    try err.print("{s}: {d} bytes ({s} runtime: {d} bytes)\n", .{ out_path, bin.len, target, runtime.len });
    return 0;
}

/// The desktop entry of a program file. The file name, `Icon`, and
/// `StartupWMClass` are the name of the program, which is the app id of
/// its Wayland toplevel. `Exec` has no folder: the program goes in a
/// folder of PATH.
pub fn desktopEntry(gpa: std.mem.Allocator, program: []const u8, name: []const u8, has_icon: bool) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.print("[Desktop Entry]\nType=Application\nName={s}\nExec={s}\nTerminal=false\nCategories=Utility;\nStartupWMClass={s}\n", .{ name, program, program });
    if (has_icon) try w.print("Icon={s}\n", .{program});
    return out.toOwnedSlice();
}

/// Writes NAME.desktop and, with an icon, NAME.png next to a program file.
fn desktopFiles(io: Io, a: std.mem.Allocator, err: *Io.Writer, out_path: []const u8, name: ?[]const u8, icon: ?[]const u8) !u8 {
    const cwd = Io.Dir.cwd();
    const program = std.fs.path.basename(out_path);
    const dir = std.fs.path.dirname(out_path) orelse ".";
    if (icon) |p| {
        const bytes = cwd.readFileAlloc(io, p, a, .limited(64 << 20)) catch |e| {
            try err.print("ztk bundle: {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        const src = png.decode(a, bytes) catch |e| {
            try err.print("ztk bundle: {s}: not a PNG file: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        const img = try scale(a, src, @min(256, @max(src.width, src.height)));
        const icon_path = try std.fmt.allocPrint(a, "{s}/{s}.png", .{ dir, program });
        try cwd.writeFile(io, .{ .sub_path = icon_path, .data = try png.encode(a, img) });
        try err.print("{s}: {d} pixels\n", .{ icon_path, img.width });
    }
    const entry_path = try std.fmt.allocPrint(a, "{s}/{s}.desktop", .{ dir, program });
    try cwd.writeFile(io, .{ .sub_path = entry_path, .data = try desktopEntry(a, program, name orelse program, icon != null) });
    try err.print("{s}\n", .{entry_path});
    return 0;
}

test "bundle: the desktop entry of a program" {
    const e = try desktopEntry(std.testing.allocator, "notes", "My Notes", true);
    defer std.testing.allocator.free(e);
    try std.testing.expectEqualStrings("[Desktop Entry]\nType=Application\nName=My Notes\nExec=notes\nTerminal=false\nCategories=Utility;\nStartupWMClass=notes\nIcon=notes\n", e);
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
    try t.expectEqualStrings("/a/b", commonDir("/a/b/c", "/a/b/d"));
    try t.expectEqualStrings("/a", commonDir("/a/bc", "/a/bd"));
    try t.expectEqualStrings("/a/b", commonDir("/a/b", "/a/b/c"));
    try t.expectEqualStrings("/a/b", commonDir("/a/b/c", "/a/b"));
    try t.expectEqualStrings("/", commonDir("/x", "/y"));
    try t.expect(isMachO(&.{ 0xcf, 0xfa, 0xed, 0xfe }));
    try t.expect(!isMachO("\x7fELF"));
}

test "bundle: each file keeps its path relative to the main script" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const io = t.io;
    try tmp.dir.createDirPath(io, "a/css");
    try tmp.dir.createDirPath(io, "b");
    for ([_][]const u8{ "a/main.tcl", "a/x.css", "a/css/y.css", "b/z.tcl" }) |p| try tmp.dir.writeFile(io, .{ .sub_path = p, .data = "" });
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    const p = struct {
        fn f(al: std.mem.Allocator, root: []const u8, rel: []const u8) []const u8 {
            return std.fs.path.join(al, &.{ root, rel }) catch unreachable;
        }
    }.f;
    const one = try layout(io, a, &.{ p(a, base, "a/main.tcl"), p(a, base, "a/x.css"), p(a, base, "a/css") });
    try t.expectEqualStrings("main.tcl", one[0]);
    try t.expectEqualStrings("x.css", one[1]);
    try t.expectEqualStrings("css", one[2]);
    const two = try layout(io, a, &.{ p(a, base, "a/main.tcl"), p(a, base, "b/z.tcl") });
    try t.expectEqualStrings("a/main.tcl", two[0]);
    try t.expectEqualStrings("b/z.tcl", two[1]);
    // The folder of the main script as a folder argument: its files go in at the top.
    const three = try layout(io, a, &.{ p(a, base, "a/main.tcl"), p(a, base, "a") });
    try t.expectEqualStrings("", three[1]);
}

test {
    _ = machosign;
}
