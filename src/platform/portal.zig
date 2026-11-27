//! The file dialogs of the desktop portal (`org.freedesktop.portal.FileChooser`)
//! over the D-Bus client of `dbus.zig`. A dialog is a `Request` object:
//! the client adds a match for its `Response` signal at the path that
//! the portal gives for the token of the call, calls `OpenFile` or
//! `SaveFile`, and waits for the signal. The response 0 has the chosen
//! files as `file://` URIs in `uris`, and the name of the chosen filter in
//! `current_filter`. A folder dialog is `OpenFile` with `directory`. The
//! interface comes from the XML of the portal (docs/references/dbus.md).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const dbus = @import("dbus.zig");
const plat = @import("platform.zig");

const dest = "org.freedesktop.portal.Desktop";
const obj = "/org/freedesktop/portal/desktop";
const iface = "org.freedesktop.portal.FileChooser";

var token_counter: u32 = 0;

/// The path of the `Request` object of a call: the unique name with no
/// colon and with `_` for each dot, and the token.
pub fn requestPath(buf: []u8, unique: []const u8, token: []const u8) ![]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    try w.writeAll("/org/freedesktop/portal/desktop/request/");
    for (unique) |ch| switch (ch) {
        ':' => {},
        '.' => try w.writeByte('_'),
        else => try w.writeByte(ch),
    };
    try w.print("/{s}", .{token});
    return w.buffered();
}

/// Writes the body of `OpenFile` or `SaveFile`: the parent window, the
/// title, and the options.
pub fn writeBody(w: *dbus.Writer, opts: *const plat.FileDialog, parent: []const u8, token: []const u8) void {
    w.string(parent);
    w.string(opts.title);
    const a = w.beginArray(8);
    w.dictString("handle_token", token);
    w.dictBool("modal", true);
    switch (opts.kind) {
        .open => w.dictBool("multiple", opts.multiple),
        .folder => w.dictBool("directory", true),
        .save => if (opts.initial_file.len > 0) w.dictString("current_name", opts.initial_file),
    }
    if (opts.kind != .folder and opts.filters.len > 0) {
        w.beginStruct();
        w.string("filters");
        w.variant("a(sa(us))");
        const fa = w.beginArray(8);
        for (opts.filters) |f| {
            w.beginStruct();
            w.string(f.name);
            const pa = w.beginArray(8);
            for (f.patterns) |p| {
                w.beginStruct();
                // 0: a glob pattern.
                w.uint(0);
                w.string(p);
            }
            w.endArray(pa);
        }
        w.endArray(fa);
    }
    if (opts.initial_dir.len > 0) {
        w.beginStruct();
        w.string("current_folder");
        w.variant("ay");
        w.byteString(opts.initial_dir);
    }
    w.endArray(a);
}

/// The path of a `file://` URI, with each `%XX` decoded. Another scheme gives null.
pub fn uriPath(gpa: std.mem.Allocator, uri: []const u8) !?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var rest = uri[prefix.len..];
    // A host part: file://host/path. Only an empty host or localhost is local.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) return null;
    rest = rest[slash..];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, rest[i]);
    }
    return try out.toOwnedSlice(gpa);
}

/// Adds the `file://` URI of an absolute path to `out`. Each byte other
/// than a letter, a digit, and `/-._~` becomes `%XX`.
pub fn appendFileUri(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), path: []const u8) !void {
    try out.appendSlice(gpa, "file://");
    for (path) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "/-._~", b) != null) {
            try out.append(gpa, b);
        } else {
            var buf: [3]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "%{X:0>2}", .{b}) catch unreachable);
        }
    }
}

/// Reads the body of a `Response` signal. A response other than 0 (the
/// user canceled, or the dialog ended in another way) gives null.
pub fn readResponse(gpa: std.mem.Allocator, body: []const u8, opts: *const plat.FileDialog) !?plat.FileDialogResult {
    var r: dbus.Reader = .{ .data = body };
    if (try r.uint() != 0) return null;
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    var filter: ?u32 = null;
    const end = try r.beginArray(8);
    while (r.pos < end) {
        try r.alignTo(8);
        const key = try r.string();
        const sig = try r.signature();
        if (std.mem.eql(u8, key, "uris") and std.mem.eql(u8, sig, "as")) {
            const uend = try r.beginArray(4);
            while (r.pos < uend) {
                const uri = try r.string();
                if (try uriPath(gpa, uri)) |p| {
                    errdefer gpa.free(p);
                    try paths.append(gpa, p);
                }
            }
        } else if (std.mem.eql(u8, key, "current_filter") and std.mem.eql(u8, sig, "(sa(us))")) {
            try r.alignTo(8);
            const name = try r.string();
            var k: usize = 0;
            try r.skip("a(us)", &k);
            for (opts.filters, 0..) |f, n| if (std.mem.eql(u8, f.name, name)) {
                filter = @intCast(n);
                break;
            };
        } else {
            var k: usize = 0;
            try r.skip(sig, &k);
        }
    }
    if (paths.items.len == 0) {
        paths.deinit(gpa);
        return null;
    }
    // A save adds the default extension to a name with none.
    if (opts.kind == .save and opts.default_ext.len > 0) {
        const p = paths.items[0];
        const base = std.fs.path.basename(p);
        if (std.mem.indexOfScalar(u8, base, '.') == null) {
            const longer = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ p, opts.default_ext });
            gpa.free(p);
            paths.items[0] = longer;
        }
    }
    return .{ .paths = try paths.toOwnedSlice(gpa), .filter = filter };
}

/// Runs a file dialog of the portal to its end. `parent` is the handle of
/// the parent window (`wayland:<handle>`) or empty. `idle` runs while the
/// dialog is open.
pub fn fileDialog(gpa: std.mem.Allocator, conn: *dbus.Conn, opts: *const plat.FileDialog, parent: []const u8, idle: ?dbus.Conn.Idle) !?plat.FileDialogResult {
    token_counter += 1;
    var tbuf: [24]u8 = undefined;
    const token = try std.fmt.bufPrint(&tbuf, "ztk{d}", .{token_counter});
    var pbuf: [256]u8 = undefined;
    const path = try requestPath(&pbuf, conn.unique, token);
    var rbuf: [400]u8 = undefined;
    // The match goes first, so the signal cannot come before it.
    try conn.addMatch(try std.fmt.bufPrint(&rbuf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{path}));
    var w: dbus.Writer = .{ .gpa = gpa };
    defer w.deinit();
    writeBody(&w, opts, parent, token);
    const member = if (opts.kind == .save) "SaveFile" else "OpenFile";
    const reply = try conn.call(.{ .destination = dest, .path = obj, .interface = iface, .member = member, .signature = "ssa{sv}", .body = try w.bytes() }, 10_000);
    defer reply.deinit(gpa);
    var rr = reply.reader();
    const handle = try rr.string();
    // An old portal gives another path. Its signal can then come before this match.
    if (!std.mem.eql(u8, handle, path)) {
        try conn.addMatch(try std.fmt.bufPrint(&rbuf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{handle}));
    }
    const sig = try conn.waitSignal(handle, "org.freedesktop.portal.Request", "Response", idle);
    defer sig.deinit(gpa);
    return readResponse(gpa, sig.body, opts);
}

// ---- Settings ----

/// The keys of the setting for less motion: GNOME has `enable-animations`
/// (false: less motion), and KDE has `AnimationDurationFactor` (0: no
/// animations).
pub const motion_keys = [_][2][]const u8{
    .{ "org.gnome.desktop.interface", "enable-animations" },
    .{ "org.kde.kdeglobals.KDE", "AnimationDurationFactor" },
};

/// Reads a value of a setting body: a variant, maybe in a second variant
/// (`Read` of version 1 of the portal). A boolean or a number gives true
/// for less motion.
pub fn motionValue(r: *dbus.Reader) !?bool {
    var sig = try r.signature();
    if (std.mem.eql(u8, sig, "v")) sig = try r.signature();
    if (std.mem.eql(u8, sig, "b")) return !(try r.boolean());
    if (std.mem.eql(u8, sig, "d")) return (try r.double()) == 0;
    return null;
}

/// The setting for less motion from `org.freedesktop.portal.Settings`, or
/// null when the portal has none of `motion_keys`.
pub fn reducedMotion(gpa: std.mem.Allocator, conn: *dbus.Conn) ?bool {
    for (motion_keys) |k| {
        for ([_][]const u8{ "ReadOne", "Read" }) |member| {
            var w: dbus.Writer = .{ .gpa = gpa };
            defer w.deinit();
            w.string(k[0]);
            w.string(k[1]);
            const reply = conn.call(.{ .destination = dest, .path = obj, .interface = "org.freedesktop.portal.Settings", .member = member, .signature = "ss", .body = w.bytes() catch return null }, 2000) catch continue;
            defer reply.deinit(gpa);
            var r = reply.reader();
            if (motionValue(&r) catch null) |v| return v;
        }
    }
    return null;
}

/// The less-motion value of a `SettingChanged` signal (namespace, key,
/// value), or null for another setting.
pub fn motionChange(body: []const u8) ?bool {
    var r: dbus.Reader = .{ .data = body };
    const ns = r.string() catch return null;
    const key = r.string() catch return null;
    for (motion_keys) |k| if (std.mem.eql(u8, k[0], ns) and std.mem.eql(u8, k[1], key)) {
        return motionValue(&r) catch null;
    };
    return null;
}

pub const setting_rule = "type='signal',interface='org.freedesktop.portal.Settings',member='SettingChanged',path='/org/freedesktop/portal/desktop'";

const t = std.testing;

test "portal: SettingChanged of the animations of GNOME and of KDE" {
    var w: dbus.Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    w.string("org.gnome.desktop.interface");
    w.string("enable-animations");
    w.variant("b");
    w.boolean(false);
    try t.expectEqual(@as(?bool, true), motionChange(try w.bytes()));
    var w2: dbus.Writer = .{ .gpa = t.allocator };
    defer w2.deinit();
    w2.string("org.kde.kdeglobals.KDE");
    w2.string("AnimationDurationFactor");
    w2.variant("v");
    w2.variant("d");
    w2.alignTo(8);
    w2.raw(&@as([8]u8, @bitCast(@as(f64, 1.0))));
    try t.expectEqual(@as(?bool, false), motionChange(try w2.bytes()));
    var w3: dbus.Writer = .{ .gpa = t.allocator };
    defer w3.deinit();
    w3.string("org.freedesktop.appearance");
    w3.string("color-scheme");
    w3.variant("u");
    w3.uint(1);
    try t.expectEqual(@as(?bool, null), motionChange(try w3.bytes()));
}

test "portal: the request path of a unique name" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("/org/freedesktop/portal/desktop/request/1_42/ztk1", try requestPath(&buf, ":1.42", "ztk1"));
}

test "portal: a file URI gives its decoded path" {
    const p = (try uriPath(t.allocator, "file:///data/a/My%20File.txt")).?;
    defer t.allocator.free(p);
    try t.expectEqualStrings("/data/a/My File.txt", p);
    try t.expect(try uriPath(t.allocator, "https://example.com/x") == null);
    try t.expect(try uriPath(t.allocator, "file://other/x") == null);
}

test "portal: a path gives its file URI and back" {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(t.allocator);
    try appendFileUri(t.allocator, &out, "/data/a/My File%é.txt");
    try t.expectEqualStrings("file:///data/a/My%20File%25%C3%A9.txt", out.items);
    const p = (try uriPath(t.allocator, out.items)).?;
    defer t.allocator.free(p);
    try t.expectEqualStrings("/data/a/My File%é.txt", p);
}

/// A `Response` body: the response code, the URIs, and the filter name.
fn responseBody(w: *dbus.Writer, code: u32, uris: []const []const u8, filter: ?[]const u8) !void {
    w.uint(code);
    const a = w.beginArray(8);
    w.beginStruct();
    w.string("uris");
    w.variant("as");
    const ua = w.beginArray(4);
    for (uris) |u| w.string(u);
    w.endArray(ua);
    if (filter) |f| {
        w.beginStruct();
        w.string("current_filter");
        w.variant("(sa(us))");
        w.beginStruct();
        w.string(f);
        const pa = w.beginArray(8);
        w.beginStruct();
        w.uint(0);
        w.string("*.png");
        w.endArray(pa);
    }
    w.beginStruct();
    w.string("choices");
    w.variant("a(ss)");
    const ca = w.beginArray(8);
    w.endArray(ca);
    w.endArray(a);
}

test "portal: a response gives the paths and the filter" {
    const filters = [_]plat.FileDialog.Filter{ .{ .name = "Text", .patterns = &.{"*.txt"} }, .{ .name = "Images", .patterns = &.{"*.png"} } };
    const opts: plat.FileDialog = .{ .kind = .open, .multiple = true, .filters = &filters };
    var w: dbus.Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    try responseBody(&w, 0, &.{ "file:///tmp/a.png", "file:///tmp/b%25.png" }, "Images");
    const res = (try readResponse(t.allocator, try w.bytes(), &opts)).?;
    defer res.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), res.paths.len);
    try t.expectEqualStrings("/tmp/a.png", res.paths[0]);
    try t.expectEqualStrings("/tmp/b%.png", res.paths[1]);
    try t.expectEqual(@as(?u32, 1), res.filter);
}

test "portal: a canceled dialog gives null, and a save adds the extension" {
    const opts: plat.FileDialog = .{ .kind = .save, .default_ext = "txt" };
    var w: dbus.Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    try responseBody(&w, 1, &.{}, null);
    try t.expect(try readResponse(t.allocator, try w.bytes(), &opts) == null);
    var w2: dbus.Writer = .{ .gpa = t.allocator };
    defer w2.deinit();
    try responseBody(&w2, 0, &.{"file:///tmp/notes"}, null);
    const res = (try readResponse(t.allocator, try w2.bytes(), &opts)).?;
    defer res.deinit(t.allocator);
    try t.expectEqualStrings("/tmp/notes.txt", res.paths[0]);
}

test "portal: the options of an open have the filters and the folder" {
    const filters = [_]plat.FileDialog.Filter{.{ .name = "Text", .patterns = &.{ "*.txt", "*.md" } }};
    const opts: plat.FileDialog = .{ .kind = .open, .title = "Open", .initial_dir = "/tmp", .filters = &filters };
    var w: dbus.Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    writeBody(&w, &opts, "", "ztk9");
    var r: dbus.Reader = .{ .data = try w.bytes() };
    try t.expectEqualStrings("", try r.string());
    try t.expectEqualStrings("Open", try r.string());
    var k: usize = 0;
    try r.skip("a{sv}", &k);
    try t.expectEqual(r.data.len, r.pos);
    // The keys in order.
    var r2: dbus.Reader = .{ .data = try w.bytes() };
    _ = try r2.string();
    _ = try r2.string();
    const end = try r2.beginArray(8);
    var keys: [8][]const u8 = undefined;
    var n: usize = 0;
    while (r2.pos < end) : (n += 1) {
        try r2.alignTo(8);
        keys[n] = try r2.string();
        var j: usize = 0;
        try r2.skip("v", &j);
    }
    try t.expectEqual(@as(usize, 5), n);
    try t.expectEqualStrings("handle_token", keys[0]);
    try t.expectEqualStrings("filters", keys[3]);
    try t.expectEqualStrings("current_folder", keys[4]);
}

/// The bus and the portal for the test: SASL, Hello, AddMatch, and an
/// OpenFile that answers with one file.
fn fakeBus(fd: i32) void {
    const linux = std.os.linux;
    var line: [256]u8 = undefined;
    var got: usize = 0;
    var ok_sent = false;
    // The client sends AUTH, gets OK, and sends BEGIN. Read one byte at a
    // time, so the first message stays in the socket.
    while (std.mem.indexOf(u8, line[0..got], "BEGIN\r\n") == null) {
        if (got == line.len) return;
        const rc = linux.read(fd, line[got..].ptr, 1);
        if (@as(isize, @bitCast(rc)) <= 0) return;
        got += rc;
        if (!ok_sent and std.mem.endsWith(u8, line[0..got], "\r\n")) {
            if (std.mem.indexOf(u8, line[0..got], "\x00AUTH EXTERNAL ") != 0) return;
            _ = linux.write(fd, "OK 0123456789abcdef\r\n", 21);
            ok_sent = true;
        }
    }
    var c: dbus.Conn = .{ .gpa = t.allocator, .fd = fd };
    while (true) {
        const m = c.read(2000) catch return;
        defer m.deinit(t.allocator);
        var w: dbus.Writer = .{ .gpa = t.allocator };
        defer w.deinit();
        if (std.mem.eql(u8, m.member, "Hello")) {
            w.string(":1.7");
            _ = c.send(.{ .type = .method_return, .reply_serial = m.serial, .signature = "s", .body = w.bytes() catch return }) catch return;
        } else if (std.mem.eql(u8, m.member, "AddMatch")) {
            _ = c.send(.{ .type = .method_return, .reply_serial = m.serial }) catch return;
        } else if (std.mem.eql(u8, m.member, "OpenFile")) {
            const path = "/org/freedesktop/portal/desktop/request/1_7/ztk" ++ "";
            var pbuf: [128]u8 = undefined;
            const req = std.fmt.bufPrint(&pbuf, "{s}{d}", .{ path, token_counter }) catch return;
            w.string(req);
            _ = c.send(.{ .type = .method_return, .reply_serial = m.serial, .signature = "o", .body = w.bytes() catch return }) catch return;
            var b: dbus.Writer = .{ .gpa = t.allocator };
            defer b.deinit();
            responseBody(&b, 0, &.{"file:///srv/data/report%201.csv"}, null) catch return;
            _ = c.send(.{ .type = .signal, .path = req, .interface = "org.freedesktop.portal.Request", .member = "Response", .signature = "ua{sv}", .body = b.bytes() catch return }) catch return;
            return;
        }
    }
}

test "portal: an open over a fake bus gives the file of the response" {
    const linux = std.os.linux;
    var fds: [2]i32 = undefined;
    if (@as(isize, @bitCast(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds))) < 0) return error.SkipZigTest;
    const th = try std.Thread.spawn(.{}, fakeBus, .{fds[1]});
    defer {
        th.join();
        _ = linux.close(fds[1]);
    }
    const conn = try dbus.Conn.fromFd(t.allocator, fds[0]);
    defer conn.deinit();
    try t.expectEqualStrings(":1.7", conn.unique);
    const opts: plat.FileDialog = .{ .kind = .open, .title = "Open a report" };
    const res = (try fileDialog(t.allocator, conn, &opts, "", null)).?;
    defer res.deinit(t.allocator);
    try t.expectEqualStrings("/srv/data/report 1.csv", res.paths[0]);
}
