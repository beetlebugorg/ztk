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

    fn deinit(p: *Photo, gpa: std.mem.Allocator) void {
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
    const img = png.decode(app.gpa, bytes) catch return it.fail("couldn't recognize image data", .{});
    app.gpa.free(p.pixels);
    p.pixels = img.pixels;
    p.width = img.width;
    p.height = img.height;
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
            // Accepted and ignored: the stand-in reads PNG only.
        } else return it.fail("bad option \"{s}\": must be {s}", .{ name, photo_opts });
    }
    switch (load) {
        .none => {},
        .file => {
            const bytes = app.readFile(p.file, it.alloc()) catch return it.fail("couldn't open \"{s}\": no such file or directory", .{p.file});
            try loadPng(app, it, p, bytes);
        },
        .data => {
            const dec = std.base64.standard.Decoder;
            const clean = try it.alloc().alloc(u8, p.data.len);
            var n: usize = 0;
            for (p.data) |c| if (!std.ascii.isWhitespace(c)) {
                clean[n] = c;
                n += 1;
            };
            const size = dec.calcSizeForSlice(clean[0..n]) catch return it.fail("couldn't recognize image data", .{});
            const bytes = try it.alloc().alloc(u8, size);
            dec.decode(bytes, clean[0..n]) catch return it.fail("couldn't recognize image data", .{});
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
        const rows = try it.list(argv[2]);
        var to: [4]i64 = .{ 0, 0, -1, -1 };
        var k: usize = 3;
        while (k < argv.len) : (k += 1) {
            if (!std.mem.eql(u8, try it.str(argv[k]), "-to")) return it.fail("bad option \"{s}\": must be -format or -to", .{try it.str(argv[k])});
            var n: usize = 0;
            while (k + 1 < argv.len and n < 4) : (n += 1) {
                const v = std.fmt.parseInt(i64, try it.str(argv[k + 1]), 10) catch break;
                to[n] = v;
                k += 1;
            }
        }
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
        if (!std.mem.eql(u8, ty, "photo")) return it.fail("image type \"{s}\" doesn't exist", .{ty});
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
        configurePhoto(app, it, p, rest) catch |e| {
            p.deinit(gpa);
            gpa.destroy(p);
            return e;
        };
        try reg.list.append(gpa, p);
        try it.register(p.name, cmdPhoto);
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
        return .{ .str = "photo" };
    }
    const one = [_][]const u8{ "width", "height", "type", "inuse" };
    for (one) |o| if (std.mem.eql(u8, sub, o)) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"image {s} name\"", .{o});
        const n = try it.str(argv[2]);
        const p = reg.find(n) orelse return it.fail("image \"{s}\" doesn't exist", .{n});
        if (o[0] == 'w') return .{ .int = p.width };
        if (o[0] == 'h') return .{ .int = p.height };
        if (o[0] == 't') return .{ .str = "photo" };
        return .{ .int = 0 };
    };
    return it.fail("bad option \"{s}\": must be create, delete, height, inuse, names, type, types, or width", .{sub});
}
