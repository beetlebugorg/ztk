//! The stand-in `image` command: photo images only. `image create photo`
//! makes an RGBA image from a PNG file (`-file`), from base64 PNG data
//! (`-data`), or blank with `-width` and `-height`. Each image has a
//! command with `blank`, `cget`, `configure`, `get`, `put`, and `write`
//! is left out. The canvas draws an image as one box quad for each run of
//! equal pixels in a row, so the renderers need no image kind. Each
//! change counts up `generation`, and the widgets that draw images paint
//! again.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const png = @import("png.zig");
const geom = @import("geom.zig");
const App = @import("app.zig").App;
const Value = ztcl.Value;

pub const Photo = struct {
    name: []u8,
    width: u32 = 0,
    height: u32 = 0,
    /// RGBA, rows from the top. Owned.
    pixels: []u8 = &.{},
    /// The sizes that the script set, or 0.
    set_w: u32 = 0,
    set_h: u32 = 0,
    file: []u8 = &.{},
    data: []u8 = &.{},
    /// Counts up at each change of the pixels.
    version: u32 = 0,
    /// A number of this photo alone, so the image page of the atlas never
    /// gives it the place of a photo that was deleted.
    serial: u32 = 0,
    /// A bitmap image keeps its options, and its pixels are made from them.
    bitmap: ?*Bitmap = null,

    fn deinit(p: *Photo, gpa: std.mem.Allocator) void {
        if (p.bitmap) |b| {
            for (&b.opts) |o| gpa.free(o);
            gpa.destroy(b);
        }
        gpa.free(p.name);
        gpa.free(p.pixels);
        gpa.free(p.file);
        gpa.free(p.data);
    }

    /// Changes the size and keeps the pixels that fit. New pixels are clear.
    fn resize(p: *Photo, gpa: std.mem.Allocator, w: u32, h: u32) !void {
        if (w == p.width and h == p.height) return;
        const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
        @memset(px, 0);
        const cw = @min(w, p.width);
        for (0..@min(h, p.height)) |y| {
            @memcpy(px[y * w * 4 ..][0 .. cw * 4], p.pixels[y * p.width * 4 ..][0 .. cw * 4]);
        }
        gpa.free(p.pixels);
        p.pixels = px;
        p.width = w;
        p.height = h;
    }
};

/// The options of a bitmap image, in the order of `bitmap_opts`.
pub const Bitmap = struct {
    opts: [6][]u8 = .{ &.{}, &.{}, &.{}, &.{}, &.{}, &.{} },
};

const bitmap_opts = [_][]const u8{ "-background", "-data", "-file", "-foreground", "-maskdata", "-maskfile" };

/// The bits of an XBM text: width, height, and one bit for each pixel,
/// rows from the top, the low bit first in each byte.
const Xbm = struct { w: u32, h: u32, bits: []const u8 };

fn parseXbm(a: std.mem.Allocator, text: []const u8) ?Xbm {
    var w: ?u32 = null;
    var h: ?u32 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "#define")) continue;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = words.next();
        const name = words.next() orelse continue;
        const num = std.fmt.parseInt(u32, words.next() orelse continue, 0) catch continue;
        if (std.mem.endsWith(u8, name, "_width")) w = num;
        if (std.mem.endsWith(u8, name, "_height")) h = num;
    }
    const wd = w orelse return null;
    const ht = h orelse return null;
    if (wd == 0 or ht == 0 or wd > 4096 or ht > 4096) return null;
    const brace = std.mem.indexOfScalar(u8, text, '{') orelse return null;
    const n = (wd + 7) / 8 * ht;
    const bits = a.alloc(u8, n) catch return null;
    var k: usize = 0;
    var toks = std.mem.tokenizeAny(u8, text[brace + 1 ..], " \t\r\n,};");
    while (toks.next()) |t| {
        if (k == n) break;
        bits[k] = @truncate(std.fmt.parseInt(u16, t, 0) catch return null);
        k += 1;
    }
    if (k != n) return null;
    return .{ .w = wd, .h = ht, .bits = bits };
}

fn xbmBit(x: Xbm, col: usize, row: usize) bool {
    const stride = (x.w + 7) / 8;
    return (x.bits[row * stride + col / 8] >> @intCast(col % 8)) & 1 != 0;
}

/// Makes the pixels of a bitmap image from its options: a set bit has
/// the foreground, a clear bit has the background or no color, and a
/// clear bit of the mask has no color.
fn renderBitmap(app: *App, it: *ztcl.Interp, p: *Photo) ztcl.Error!void {
    const b = p.bitmap.?;
    const a = it.alloc();
    const src = try bitmapText(it, b.opts[1], b.opts[2]);
    const mask_src = try bitmapText(it, b.opts[4], b.opts[5]);
    var xbm: Xbm = .{ .w = 0, .h = 0, .bits = &.{} };
    if (src.len > 0) xbm = parseXbm(a, src) orelse return it.fail("format error in bitmap data", .{});
    var mask: ?Xbm = null;
    if (mask_src.len > 0) {
        mask = parseXbm(a, mask_src) orelse return it.fail("format error in bitmap data", .{});
        if (mask.?.w != xbm.w or mask.?.h != xbm.h) return it.fail("bitmap and mask have different sizes", .{});
    }
    const fg = if (b.opts[3].len > 0) (geom.Color.parseTk(b.opts[3]) orelse return it.fail("unknown color name \"{s}\"", .{b.opts[3]})) else geom.Color{ .r = 0, .g = 0, .b = 0 };
    const bg: ?geom.Color = if (b.opts[0].len > 0) (geom.Color.parseTk(b.opts[0]) orelse return it.fail("unknown color name \"{s}\"", .{b.opts[0]})) else null;
    const px = try app.gpa.alloc(u8, @as(usize, xbm.w) * xbm.h * 4);
    for (0..xbm.h) |row| for (0..xbm.w) |col| {
        const o = (row * xbm.w + col) * 4;
        const on = xbmBit(xbm, col, row);
        const shown = if (mask) |m| xbmBit(m, col, row) else true;
        const c: ?geom.Color = if (!shown) null else if (on) fg else bg;
        if (c) |cc| {
            px[o] = cc.r;
            px[o + 1] = cc.g;
            px[o + 2] = cc.b;
            px[o + 3] = 255;
        } else @memset(px[o .. o + 4], 0);
    };
    app.gpa.free(p.pixels);
    p.pixels = px;
    p.width = xbm.w;
    p.height = xbm.h;
    changed(app, p);
}

/// The XBM text of -data, or of the file of -file when -data is empty.
fn bitmapText(it: *ztcl.Interp, data: []const u8, file: []const u8) ztcl.Error![]const u8 {
    if (data.len > 0) return data;
    if (file.len == 0) return "";
    const words = [_]Value{ .{ .str = "::ztk::priv::readbinary" }, .{ .str = file } };
    return binaryBytes(it, try it.eval(try it.str(try ztcl.value.newList(it.alloc(), &words))));
}

fn configureBitmap(app: *App, it: *ztcl.Interp, p: *Photo, args: []const Value) ztcl.Error!void {
    const b = p.bitmap.?;
    if (args.len % 2 != 0) return it.fail("value for \"{s}\" missing", .{try it.str(args[args.len - 1])});
    var k: usize = 0;
    while (k < args.len) : (k += 2) {
        const name = try it.str(args[k]);
        const i = for (bitmap_opts, 0..) |o, i| {
            if (std.mem.eql(u8, o, name)) break i;
        } else return it.fail("unknown option \"{s}\"", .{name});
        const v = try app.gpa.dupe(u8, try it.str(args[k + 1]));
        app.gpa.free(b.opts[i]);
        b.opts[i] = v;
    }
    try renderBitmap(app, it, p);
}

/// The command of one bitmap image: cget and configure.
fn cmdBitmap(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const name = try it.str(argv[0]);
    const p = app.images.find(name) orelse return it.fail("invalid command name \"{s}\"", .{name});
    if (argv.len < 2) return it.fail("wrong # args: should be \"{s} option ?arg ...?\"", .{name});
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    const b = p.bitmap.?;
    if (std.mem.eql(u8, sub, "cget")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} cget option\"", .{name});
        const o = try it.str(argv[2]);
        for (bitmap_opts, 0..) |n, i| if (std.mem.eql(u8, n, o)) return .{ .str = try a.dupe(u8, b.opts[i]) };
        return it.fail("unknown option \"{s}\"", .{o});
    }
    if (std.mem.eql(u8, sub, "configure")) {
        if (argv.len == 2) {
            const items = try a.alloc(Value, bitmap_opts.len);
            for (bitmap_opts, items, 0..) |n, *slot, i| {
                const row = [_]Value{ .{ .str = n }, .{ .str = "" }, .{ .str = "" }, .{ .str = "" }, .{ .str = try a.dupe(u8, b.opts[i]) } };
                slot.* = try ztcl.value.newList(a, &row);
            }
            return ztcl.value.wrapList(a, items);
        }
        try configureBitmap(app, it, p, argv[2..]);
        return Value.empty;
    }
    return it.fail("bad option \"{s}\": must be cget or configure", .{sub});
}

pub const Registry = struct {
    list: std.ArrayListUnmanaged(*Photo) = .empty,
    next: u32 = 1,
    /// Counts up at each change of an image.
    generation: u32 = 0,
    /// The serial of the last photo made.
    serials: u32 = 0,

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator) void {
        for (r.list.items) |p| {
            p.deinit(gpa);
            gpa.destroy(p);
        }
        r.list.deinit(gpa);
    }

    pub fn find(r: *const Registry, name: []const u8) ?*Photo {
        for (r.list.items) |p| if (std.mem.eql(u8, p.name, name)) return p;
        return null;
    }

    fn index(r: *const Registry, name: []const u8) ?usize {
        for (r.list.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }
};

fn changed(app: *App, p: *Photo) void {
    p.version +%= 1;
    app.images.generation +%= 1;
    // Each toplevel paints again, so each widget that shows the image draws it.
    var it = app.widgets.valueIterator();
    while (it.next()) |w| if (w.*.isToplevel() and w.*.alive()) {
        w.*.dirty.paint = true;
    };
    app.requestFrame();
}

const photo_opts = "-data, -file, -format, -gamma, -height, -palette, or -width";

fn loadPng(app: *App, it: *ztcl.Interp, p: *Photo, bytes: []const u8) ztcl.Error!void {
    const gif = @import("gif.zig");
    const img = (if (gif.isGif(bytes)) gif.decodeGif(app.gpa, bytes) else if (gif.isPpm(bytes)) gif.decodePpm(app.gpa, bytes) else png.decode(app.gpa, bytes)) catch return it.fail("couldn't recognize image data", .{});
    app.gpa.free(p.pixels);
    p.pixels = img.pixels;
    p.width = img.width;
    p.height = img.height;
}

/// Base64 text to bytes, as Tk reads it: white space and the padding are
/// left out, and extra bits at the end do not matter. Gives null for a
/// text with another character, which is then binary data.
fn base64Lenient(a: std.mem.Allocator, text: []const u8) !?[]u8 {
    const out = try a.alloc(u8, text.len / 4 * 3 + 3);
    var n: usize = 0;
    var acc: u32 = 0;
    var bits: u5 = 0;
    for (text) |c| {
        const v: u32 = switch (c) {
            'A'...'Z' => c - 'A',
            'a'...'z' => c - 'a' + 26,
            '0'...'9' => c - '0' + 52,
            '+' => 62,
            '/' => 63,
            '=', ' ', '\t', '\r', '\n' => continue,
            else => return null,
        };
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[n] = @truncate(acc >> bits);
            n += 1;
            acc &= (@as(u32, 1) << bits) - 1;
        }
    }
    return out[0..n];
}

/// True when a list is rows of color names, as `put` takes them.
fn colorRows(it: *ztcl.Interp, rows: []const Value) bool {
    if (rows.len == 0) return false;
    const first = it.list(rows[0]) catch return false;
    if (first.len == 0) return false;
    const t = it.str(first[0]) catch return false;
    return geom.Color.parseTk(t) != null;
}

/// Decodes image data: base64 text or the bytes of a file, in PNG, GIF,
/// or PPM. The caller frees `pixels` with the gpa of the App.
fn decodeData(app: *App, it: *ztcl.Interp, text: []const u8) ztcl.Error!?@import("render/renderer.zig").Image {
    const gif = @import("gif.zig");
    const bytes = (try base64Lenient(it.alloc(), text)) orelse try binaryBytes(it, .{ .str = text });
    const r = if (gif.isGif(bytes)) gif.decodeGif(app.gpa, bytes) else if (gif.isPpm(bytes)) gif.decodePpm(app.gpa, bytes) else png.decode(app.gpa, bytes);
    return r catch null;
}

/// The bytes of a binary string of Tcl: each character below 256 is one
/// byte. The string keeps the characters as UTF-8.
fn binaryBytes(it: *ztcl.Interp, v: Value) ztcl.Error![]const u8 {
    const t = try it.str(v);
    const out = try it.alloc().alloc(u8, t.len);
    var n: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(t);
    var iter = view.iterator();
    while (iter.nextCodepoint()) |cp| {
        out[n] = @truncate(cp);
        n += 1;
    }
    return out[0..n];
}

fn configurePhoto(app: *App, it: *ztcl.Interp, p: *Photo, args: []const Value) ztcl.Error!void {
    const gpa = app.gpa;
    var k: usize = 0;
    var load: enum { none, file, data } = .none;
    while (k < args.len) : (k += 2) {
        const name = try it.str(args[k]);
        if (k + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{name});
        const v = try it.str(args[k + 1]);
        if (std.mem.eql(u8, name, "-file")) {
            gpa.free(p.file);
            p.file = try gpa.dupe(u8, v);
            load = .file;
        } else if (std.mem.eql(u8, name, "-data")) {
            gpa.free(p.data);
            p.data = try gpa.dupe(u8, v);
            load = .data;
        } else if (std.mem.eql(u8, name, "-width") or std.mem.eql(u8, name, "-height")) {
            const n = std.fmt.parseInt(i64, std.mem.trim(u8, v, " "), 0) catch return it.fail("expected integer but got \"{s}\"", .{v});
            const c: u32 = @intCast(std.math.clamp(n, 0, 8192));
            if (name[1] == 'w') p.set_w = c else p.set_h = c;
        } else if (std.mem.eql(u8, name, "-format") or std.mem.eql(u8, name, "-gamma") or std.mem.eql(u8, name, "-palette")) {
            // Accepted and ignored: the decoder finds the format from the data.
        } else return it.fail("bad option \"{s}\": must be {s}", .{ name, photo_opts });
    }
    switch (load) {
        .none => {},
        .file => {
            // The file comes through `open`, so the file capability and
            // --root of the program apply, as for any file of the script.
            const words = [_]Value{ .{ .str = "::ztk::priv::readbinary" }, .{ .str = p.file } };
            const v = try it.eval(try it.str(try ztcl.value.newList(it.alloc(), &words)));
            try loadPng(app, it, p, try binaryBytes(it, v));
        },
        .data => {
            // -data is base64 text, or the bytes of the file as a binary
            // string, as in Tk 8.6.
            const bytes = (try base64Lenient(it.alloc(), p.data)) orelse try binaryBytes(it, .{ .str = p.data });
            try loadPng(app, it, p, bytes);
        },
    }
    const w = if (p.set_w > 0) p.set_w else p.width;
    const h = if (p.set_h > 0) p.set_h else p.height;
    try p.resize(gpa, w, h);
    changed(app, p);
}

fn photoCget(it: *ztcl.Interp, p: *Photo, name: []const u8) ztcl.Error!Value {
    const a = it.alloc();
    if (std.mem.eql(u8, name, "-file")) return .{ .str = try a.dupe(u8, p.file) };
    if (std.mem.eql(u8, name, "-data")) return .{ .str = try a.dupe(u8, p.data) };
    if (std.mem.eql(u8, name, "-width")) return .{ .int = p.set_w };
    if (std.mem.eql(u8, name, "-height")) return .{ .int = p.set_h };
    if (std.mem.eql(u8, name, "-format") or std.mem.eql(u8, name, "-palette")) return Value.empty;
    if (std.mem.eql(u8, name, "-gamma")) return .{ .str = "1.0" };
    return it.fail("unknown option \"{s}\"", .{name});
}

/// The command of one photo image.
fn cmdPhoto(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const name = try it.str(argv[0]);
    const p = app.images.find(name) orelse return it.fail("invalid command name \"{s}\"", .{name});
    if (argv.len < 2) return it.fail("wrong # args: should be \"{s} option ?arg ...?\"", .{name});
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "read")) {
        // `read file ?-format f? ?-to x y? ?-shrink?`: the image of the file
        // goes at -to, and the photo grows to hold it.
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} read fileName ?-option value ...?\"", .{name});
        var to: [2]i64 = .{ 0, 0 };
        var k: usize = 3;
        while (k < argv.len) : (k += 1) {
            const o = try it.str(argv[k]);
            if (std.mem.eql(u8, o, "-format")) {
                k += 1;
            } else if (std.mem.eql(u8, o, "-to")) {
                if (k + 2 >= argv.len) return it.fail("the \"-to\" option requires two values", .{});
                to = .{ try it.int(argv[k + 1]), try it.int(argv[k + 2]) };
                k += 2;
            } else if (std.mem.eql(u8, o, "-shrink")) {} else return it.fail("bad option \"{s}\": must be -format, -from, -shrink, or -to", .{o});
        }
        const words = [_]Value{ .{ .str = "::ztk::priv::readbinary" }, argv[2] };
        const bytes = try binaryBytes(it, try it.eval(try it.str(try ztcl.value.newList(a, &words))));
        const gif = @import("gif.zig");
        const img = (if (gif.isGif(bytes)) gif.decodeGif(app.gpa, bytes) else if (gif.isPpm(bytes)) gif.decodePpm(app.gpa, bytes) else png.decode(app.gpa, bytes)) catch
            return it.fail("couldn't recognize data in image file \"{s}\"", .{try it.str(argv[2])});
        defer app.gpa.free(img.pixels);
        try growTo(app, p, to[0] + img.width, to[1] + img.height);
        for (0..img.height) |yy| for (0..img.width) |xx| {
            const o = (yy * img.width + xx) * 4;
            const px = img.pixels[o..][0..4];
            setPx(p, to[0] + @as(i64, @intCast(xx)), to[1] + @as(i64, @intCast(yy)), .{ .r = px[0], .g = px[1], .b = px[2], .a = px[3] });
        };
        changed(app, p);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "blank")) {
        @memset(p.pixels, 0);
        changed(app, p);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "cget")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} cget option\"", .{name});
        return photoCget(it, p, try it.str(argv[2]));
    }
    if (std.mem.eql(u8, sub, "configure")) {
        if (argv.len == 3) {
            const o = try it.str(argv[2]);
            return ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, o) }, Value.empty, Value.empty, Value.empty, try photoCget(it, p, o) });
        }
        try configurePhoto(app, it, p, argv[2..]);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "get")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} get x y\"", .{name});
        const x = try it.int(argv[2]);
        const y = try it.int(argv[3]);
        if (x < 0 or y < 0 or x >= p.width or y >= p.height) return it.fail("{s} get: coordinates out of range", .{name});
        const o = (@as(usize, @intCast(y)) * p.width + @as(usize, @intCast(x))) * 4;
        return ztcl.value.newList(a, &.{ .{ .int = p.pixels[o] }, .{ .int = p.pixels[o + 1] }, .{ .int = p.pixels[o + 2] } });
    }
    if (std.mem.eql(u8, sub, "put")) {
        // `put color -to x1 y1 ?x2 y2?`, or `put {{row colors} ...} ?-to x y?`.
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} put data ?-option value ...?\"", .{name});
        var to: [4]i64 = .{ 0, 0, -1, -1 };
        var format: ?[]const u8 = null;
        var k: usize = 3;
        while (k < argv.len) : (k += 1) {
            if (std.mem.eql(u8, try it.str(argv[k]), "-format")) {
                if (k + 1 >= argv.len) return it.fail("value for \"-format\" missing", .{});
                format = try it.str(argv[k + 1]);
                k += 1;
                continue;
            }
            if (!std.mem.eql(u8, try it.str(argv[k]), "-to")) return it.fail("bad option \"{s}\": must be -format or -to", .{try it.str(argv[k])});
            var n: usize = 0;
            while (k + 1 < argv.len and n < 4) : (n += 1) {
                const v = std.fmt.parseInt(i64, try it.str(argv[k + 1]), 10) catch break;
                to[n] = v;
                k += 1;
            }
        }
        // Image data (PNG, GIF, or PPM, as base64 or bytes) goes at -to x y.
        // Data that is not a list of colors is image data, as in Tk.
        const as_list = it.list(argv[2]) catch null;
        const is_colors = format == null and as_list != null and colorRows(it, as_list.?);
        if (!is_colors) {
            const img = (try decodeData(app, it, try it.str(argv[2]))) orelse return it.fail("couldn't recognize image data", .{});
            defer app.gpa.free(img.pixels);
            try growTo(app, p, to[0] + img.width, to[1] + img.height);
            for (0..img.height) |yy| for (0..img.width) |xx| {
                const o = (yy * img.width + xx) * 4;
                const px = img.pixels[o..][0..4];
                if (px[3] == 0) continue;
                setPx(p, to[0] + @as(i64, @intCast(xx)), to[1] + @as(i64, @intCast(yy)), .{ .r = px[0], .g = px[1], .b = px[2], .a = px[3] });
            };
            changed(app, p);
            return Value.empty;
        }
        const rows = as_list.?;
        // One color fills the -to rectangle.
        const single = rows.len == 1 and (try it.list(rows[0])).len == 1;
        if (single) {
            const t = try it.str((try it.list(rows[0]))[0]);
            const c = geom.Color.parseTk(t) orelse return it.fail("can't parse color \"{s}\"", .{t});
            const x2 = if (to[2] < 0) to[0] + 1 else to[2];
            const y2 = if (to[3] < 0) to[1] + 1 else to[3];
            try growTo(app, p, x2, y2);
            var y = @max(to[1], 0);
            while (y < y2) : (y += 1) {
                var x = @max(to[0], 0);
                while (x < x2) : (x += 1) setPx(p, x, y, c);
            }
        } else {
            for (rows, 0..) |row, ry| {
                const cols = try it.list(row);
                try growTo(app, p, to[0] + @as(i64, @intCast(cols.len)), to[1] + @as(i64, @intCast(ry)) + 1);
                for (cols, 0..) |cv, rx| {
                    const t = try it.str(cv);
                    const c = geom.Color.parseTk(t) orelse return it.fail("can't parse color \"{s}\"", .{t});
                    setPx(p, to[0] + @as(i64, @intCast(rx)), to[1] + @as(i64, @intCast(ry)), c);
                }
            }
        }
        changed(app, p);
        return Value.empty;
    }
    return it.fail("bad option \"{s}\": must be blank, cget, configure, copy, data, get, put, read, redither, transparency, or write", .{sub});
}

fn growTo(app: *App, p: *Photo, x2: i64, y2: i64) !void {
    const w: u32 = if (p.set_w > 0) p.width else @intCast(std.math.clamp(@max(x2, p.width), 0, 8192));
    const h: u32 = if (p.set_h > 0) p.height else @intCast(std.math.clamp(@max(y2, p.height), 0, 8192));
    try p.resize(app.gpa, w, h);
}

fn setPx(p: *Photo, x: i64, y: i64, c: geom.Color) void {
    if (x < 0 or y < 0 or x >= p.width or y >= p.height) return;
    const o = (@as(usize, @intCast(y)) * p.width + @as(usize, @intCast(x))) * 4;
    p.pixels[o..][0..4].* = .{ c.r, c.g, c.b, c.a };
}

/// `image create|delete|height|inuse|names|type|types|width`.
pub fn cmdImage(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("image option ?args?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    const reg = &app.images;
    if (std.mem.eql(u8, sub, "create")) {
        if (argv.len < 3) return it.wrongArgs("image create type ?name? ?-option value ...?");
        const ty = try it.str(argv[2]);
        const is_bitmap = std.mem.eql(u8, ty, "bitmap");
        if (!std.mem.eql(u8, ty, "photo") and !is_bitmap) return it.fail("image type \"{s}\" doesn't exist", .{ty});
        var rest = argv[3..];
        var name: []const u8 = undefined;
        var buf: [32]u8 = undefined;
        if (rest.len > 0 and (try it.str(rest[0])).len > 0 and (try it.str(rest[0]))[0] != '-') {
            name = try it.str(rest[0]);
            rest = rest[1..];
        } else {
            while (true) {
                name = std.fmt.bufPrint(&buf, "image{d}", .{reg.next}) catch unreachable;
                reg.next += 1;
                if (reg.find(name) == null and it.findCommand(name) == null) break;
            }
        }
        const gpa = app.gpa;
        if (reg.find(name)) |old| {
            // A new image with the name of an old one replaces it.
            // The command map keys the command by the name of the old
            // photo, so the command goes before that name is freed.
            const i = reg.index(name).?;
            _ = it.commands.remove(old.name);
            it.epoch += 1;
            old.deinit(gpa);
            gpa.destroy(old);
            _ = reg.list.orderedRemove(i);
        }
        const p = try gpa.create(Photo);
        reg.serials +%= 1;
        p.* = .{ .name = try gpa.dupe(u8, name), .serial = reg.serials };
        if (is_bitmap) p.bitmap = try gpa.create(Bitmap);
        if (is_bitmap) p.bitmap.?.* = .{};
        (if (is_bitmap) configureBitmap(app, it, p, rest) else configurePhoto(app, it, p, rest)) catch |e| {
            p.deinit(gpa);
            gpa.destroy(p);
            return e;
        };
        try reg.list.append(gpa, p);
        try it.register(p.name, if (is_bitmap) cmdBitmap else cmdPhoto);
        return .{ .str = try a.dupe(u8, name) };
    }
    if (std.mem.eql(u8, sub, "delete")) {
        for (argv[2..]) |v| {
            const n = try it.str(v);
            const i = reg.index(n) orelse return it.fail("image \"{s}\" doesn't exist", .{n});
            const p = reg.list.items[i];
            _ = it.commands.remove(p.name);
            it.epoch += 1;
            _ = reg.list.orderedRemove(i);
            p.deinit(app.gpa);
            app.gpa.destroy(p);
            reg.generation +%= 1;
        }
        app.requestFrame();
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "names")) {
        if (argv.len != 2) return it.wrongArgs("image names");
        const items = try a.alloc(Value, reg.list.items.len);
        for (reg.list.items, items) |p, *s| s.* = .{ .str = try a.dupe(u8, p.name) };
        return ztcl.value.wrapList(a, items);
    }
    if (std.mem.eql(u8, sub, "types")) {
        if (argv.len != 2) return it.wrongArgs("image types");
        return .{ .str = "bitmap photo" };
    }
    const one = [_][]const u8{ "width", "height", "type", "inuse" };
    for (one) |o| if (std.mem.eql(u8, sub, o)) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"image {s} name\"", .{o});
        const n = try it.str(argv[2]);
        const p = reg.find(n) orelse return it.fail("image \"{s}\" doesn't exist", .{n});
        if (o[0] == 'w') return .{ .int = p.width };
        if (o[0] == 'h') return .{ .int = p.height };
        if (o[0] == 't') return .{ .str = if (p.bitmap != null) "bitmap" else "photo" };
        return .{ .int = 0 };
    };
    return it.fail("bad option \"{s}\": must be create, delete, height, inuse, names, type, types, or width", .{sub});
}
