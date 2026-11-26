//! The class `ztk::terminal`: a terminal emulator widget. The state of
//! the terminal is a `Screen` of `screen.zig`. The widget draws the
//! cells of the screen with the fonts and the colors of ztk, so each
//! renderer draws it.
//!
//! The text comes from `write`, or from a program on a pseudo-terminal.
//! With `-command`, the widget runs `ztcl::pty spawn` in its interpreter,
//! so the program starts only when the embedder turned on the `exec`
//! capability of ztcl. A native timer reads the master side of the PTY
//! every 8 ms while the program writes, and every 32 ms when it is
//! quiet. The bytes that the terminal sends (keys, mouse reports, and
//! replies) go to the PTY, or to the script of `-inputcommand` when the
//! widget has no program.
//!
//! The paint draws each row in two passes. The first pass merges the
//! cells with one background into one box. The second pass shapes each
//! run of cells with one foreground and one font, and then puts glyph k
//! of the run at the left edge of its cell, so the columns stay in a
//! grid with any font. The cursor is a block when the widget has the
//! focus and a frame otherwise. The selection uses the colors of the
//! part `::selection`.
//!
//! The view shows the last rows of the screen. A wheel and Shift with
//! Prior or Next scroll the view into the scrollback. A drag with button
//! 1 selects cells, a double click selects a word, and a triple click a
//! line. Control-Shift-C copies the selection, and Control-Shift-V and
//! `paste` send the clipboard with the bracketed paste mode. When the
//! program asks for mouse reports, a click without Shift goes to the
//! program in the SGR or the X10 form.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const bind = @import("../bind.zig");
const keysym = @import("../keysym.zig");
const clipboard = @import("../clipboard.zig");
const shape = @import("../text/shape.zig");
const font_mod = @import("../text/font.zig");
const style_mod = @import("../style.zig");
const loop_mod = @import("../loop.zig");
const App = @import("../app.zig").App;
const screen_mod = @import("screen.zig");
const keys = @import("keys.zig");
const boxdraw = @import("boxdraw.zig");
const Screen = screen_mod.Screen;
const Cell = screen_mod.Cell;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

/// True on the platforms where `ztcl::pty` starts a program.
// The widget reads the PTY by its descriptor, and the PTY is a channel of
// ztcl. The PTY of ztcl on Windows is a pseudo console with handles, so
// Windows has no -command yet. x86-64 macOS has no channels in ztcl.
const pty_ok = ztcl.pty.supported and ztcl.sys.supported and builtin.os.tag != .windows;

pub const specs = [_]Spec{
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#ffffff", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "0", .from_style = true, .style_prop = .border_width },
    .{ .name = "-command", .db_name = "command", .db_class = "Command", .type = .string, .allow_empty = true },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .default = "xterm", .allow_empty = true },
    .{ .name = "-cwd", .db_name = "cwd", .db_class = "Cwd", .type = .string, .allow_empty = true },
    .{ .name = "-exitcommand", .db_name = "exitCommand", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkFixedFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-height", .db_name = "height", .db_class = "Height", .type = .int, .default = "24" },
    .{ .name = "-inputcommand", .db_name = "inputCommand", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "flat", .from_style = true },
    .{ .name = "-scrollback", .db_name = "scrollback", .db_class = "Scrollback", .type = .int, .default = "10000" },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "1", .allow_empty = true },
    .{ .name = "-width", .db_name = "width", .db_class = "Width", .type = .int, .default = "80" },
};

const subcommands = [_][]const u8{ "channel", "copy", "cursor", "get", "kill", "paste", "selection", "send", "size", "status", "title", "write", "yview" };

pub const class: widget.Class = .{
    .command = "ztk::terminal",
    .tk_class = "Terminal",
    .role = "terminal",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .created = created,
    .configured = configured,
    .measure = measure,
    .paint = paintTerminal,
    .subcommand = subcommand,
    .extra_subcommands = &subcommands,
    .event = onEvent,
};

const Pos = struct {
    line: usize,
    col: u16,

    fn before(a: Pos, b: Pos) bool {
        return a.line < b.line or (a.line == b.line and a.col < b.col);
    }
};

const Data = struct {
    screen: Screen,
    /// The channel of `ztcl::pty`, or empty.
    chan: []u8 = "",
    fd: i32 = -1,
    timer: ?loop_mod.TimerId = null,
    /// Bytes for the program that the PTY did not take yet.
    pending: std.ArrayList(u8) = .empty,
    /// The count of lines that the view is above the bottom.
    view_off: usize = 0,
    sel_a: ?Pos = null,
    sel_b: ?Pos = null,
    selecting: bool = false,
    /// The size of a cell in logical pixels from the last measure.
    cell_w: i32 = 8,
    cell_h: i32 = 16,
    /// True when the PTY needs the size of the screen.
    resize_pty: bool = false,
    /// The count of quiet reads in a row.
    quiet: u32 = 0,
    focused: bool = false,
    /// The mouse button that a report sent as pressed, or null.
    mouse_down: ?u8 = null,
    sel_anim: paint.PartAnim = .{},
    /// True after the create command ran `created`.
    created: bool = false,
};

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn optInt(w: *const Widget, comptime name: []const u8, default: i64) i64 {
    const v = options.get(w, name).value;
    return if (v == .int) v.int else default;
}

fn optText(w: *const Widget, comptime name: []const u8) []const u8 {
    return options.get(w, name).text;
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    errdefer w.app.gpa.destroy(d);
    d.* = .{ .screen = try Screen.init(w.app.gpa, 80, 24) };
    w.data = d;
}

fn deinit(w: *Widget) void {
    const d = data(w);
    const gpa = w.app.gpa;
    d.screen.deinit();
    d.pending.deinit(gpa);
    gpa.free(d.chan);
    gpa.destroy(d);
    w.data = null;
}

fn teardown(w: *Widget) void {
    const d = data(w);
    if (d.timer) |t| _ = w.app.loop.cancel(t);
    d.timer = null;
    closePty(w);
}

fn created(w: *Widget) ztcl.Error!void {
    const d = data(w);
    const cols: u16 = @intCast(std.math.clamp(optInt(w, "-width", 80), 1, 1000));
    const rows: u16 = @intCast(std.math.clamp(optInt(w, "-height", 24), 1, 1000));
    d.screen.resize(cols, rows) catch return error.OutOfMemory;
    d.screen.scrollback_max = @intCast(std.math.clamp(optInt(w, "-scrollback", 10000), 0, 1_000_000));
    d.created = true;
    if (optText(w, "-command").len > 0) try spawn(w);
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    const d = data(w);
    for (changed) |i| {
        const name = w.class.specs[i].name;
        if (std.mem.eql(u8, name, "-scrollback")) d.screen.scrollback_max = @intCast(std.math.clamp(optInt(w, "-scrollback", 10000), 0, 1_000_000));
        // A new command after the create replaces the program.
        if (std.mem.eql(u8, name, "-command") and d.created) {
            closePty(w);
            if (optText(w, "-command").len > 0) try spawn(w);
        }
    }
    w.invalidate(.{});
}

// The PTY.

fn spawn(w: *Widget) ztcl.Error!void {
    if (comptime !pty_ok) return w.app.it.fail("ztk::terminal -command is not available on this platform", .{});
    const it = w.app.it;
    const d = data(w);
    const a = it.alloc();
    var script: std.ArrayList(u8) = .empty;
    try script.print(a, "ztcl::pty spawn -size {{{d} {d}}} ", .{ d.screen.cols, d.screen.rows });
    const cwd = optText(w, "-cwd");
    if (cwd.len > 0) {
        try script.appendSlice(a, "-cwd ");
        try ztcl.value.appendElement(a, &script, cwd, false);
        try script.append(a, ' ');
    }
    try script.appendSlice(a, "-- {*}");
    try ztcl.value.appendElement(a, &script, optText(w, "-command"), false);
    const name = try it.str(try it.eval(script.items));
    const c = ztcl.chan.lookup(it, name) orelse return it.fail("ztcl::pty gave no channel", .{});
    d.chan = try w.app.gpa.dupe(u8, name);
    d.fd = c.fd;
    var cfg: std.ArrayList(u8) = .empty;
    try cfg.appendSlice(a, "fconfigure ");
    try ztcl.value.appendElement(a, &cfg, name, false);
    try cfg.appendSlice(a, " -blocking 0");
    _ = try it.eval(cfg.items);
    d.quiet = 0;
    schedule(w, 0);
}

fn schedule(w: *Widget, delay_us: i64) void {
    const d = data(w);
    if (d.timer != null) return;
    d.timer = w.app.loop.addNative(delay_us, tick, w) catch null;
}

/// Runs a script of words on the channel: `ztcl::pty <sub> $chan ...`.
fn ptyCall(w: *Widget, sub: []const u8, extra: []const u8) ztcl.Error!Value {
    const it = w.app.it;
    const a = it.alloc();
    var s: std.ArrayList(u8) = .empty;
    try s.print(a, "ztcl::pty {s} ", .{sub});
    try ztcl.value.appendElement(a, &s, data(w).chan, false);
    try s.appendSlice(a, extra);
    return it.eval(s.items);
}

fn closePty(w: *Widget) void {
    const d = data(w);
    if (d.chan.len == 0) return;
    const it = w.app.it;
    var s: std.ArrayList(u8) = .empty;
    s.appendSlice(it.alloc(), "close ") catch return;
    ztcl.value.appendElement(it.alloc(), &s, d.chan, false) catch return;
    _ = it.eval(s.items) catch {};
    w.app.gpa.free(d.chan);
    d.chan = "";
    d.fd = -1;
    d.pending.clearRetainingCapacity();
}

fn tick(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    if (!w.alive()) return;
    const d = data(w);
    d.timer = null;
    if (d.fd < 0) return;
    if (comptime !pty_ok) return;
    if (d.resize_pty) {
        d.resize_pty = false;
        var buf: [32]u8 = undefined;
        const extra = std.fmt.bufPrint(&buf, " {d} {d}", .{ d.screen.cols, d.screen.rows }) catch "";
        _ = ptyCall(w, "resize", extra) catch {};
    }
    flushPending(w);
    var got = false;
    var ended = false;
    var buf: [16384]u8 = undefined;
    var rounds: u32 = 0;
    while (rounds < 8) : (rounds += 1) {
        const n = switch (sysIo(false, d.fd, &buf, buf.len)) {
            .n => |x| x,
            .again => break,
            .fail => {
                ended = true;
                break;
            },
        };
        if (n == 0) {
            ended = true;
            break;
        }
        got = true;
        d.screen.write(buf[0..n]);
    }
    if (got) {
        d.quiet = 0;
        afterOutput(w);
    } else d.quiet +|= 1;
    if (ended) return programEnded(w);
    schedule(w, if (d.quiet < 25) 8000 else 32000);
}

/// Sends the replies of the screen, and draws again.
fn afterOutput(w: *Widget) void {
    const d = data(w);
    if (d.screen.reply.items.len > 0) {
        send(w, d.screen.reply.items);
        d.screen.reply.clearRetainingCapacity();
    }
    w.invalidate(.{ .style = false, .measure = false, .layout = false });
}

fn programEnded(w: *Widget) void {
    const status = ptyCall(w, "status", "") catch Value{ .str = "" };
    const status_text = w.app.it.str(status) catch "";
    const text = w.app.it.alloc().dupe(u8, status_text) catch "";
    closePty(w);
    const script = optText(w, "-exitcommand");
    if (script.len == 0) return;
    const it = w.app.it;
    var s: std.ArrayList(u8) = .empty;
    s.appendSlice(it.alloc(), script) catch return;
    s.append(it.alloc(), ' ') catch return;
    ztcl.value.appendElement(it.alloc(), &s, text, false) catch return;
    _ = it.eval(s.items) catch |e| w.app.backgroundError(e);
}

const Io = union(enum) { n: usize, again, fail };

/// A read or a write of a descriptor: a system call on Linux, so a build
/// with no libc works, and libc on macOS. EIO on the master side of a
/// PTY means that the program closed its side.
fn sysIo(comptime write: bool, fd: i32, ptr: [*]u8, len: usize) Io {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        const rc = if (write) linux.write(fd, ptr, len) else linux.read(fd, ptr, len);
        return switch (linux.errno(rc)) {
            .SUCCESS => .{ .n = rc },
            .AGAIN, .INTR => .again,
            else => .fail,
        };
    } else if (comptime pty_ok) {
        const rc = if (write) std.c.write(fd, ptr, len) else std.c.read(fd, ptr, len);
        if (rc >= 0) return .{ .n = @intCast(rc) };
        return switch (std.c.errno(rc)) {
            .AGAIN, .INTR => .again,
            else => .fail,
        };
    } else return .fail;
}

fn flushPending(w: *Widget) void {
    const d = data(w);
    if (comptime !pty_ok) return;
    while (d.pending.items.len > 0 and d.fd >= 0) {
        const n = switch (sysIo(true, d.fd, d.pending.items.ptr, d.pending.items.len)) {
            .n => |x| x,
            else => break,
        };
        if (n == 0) break;
        std.mem.copyForwards(u8, d.pending.items[0 .. d.pending.items.len - n], d.pending.items[n..]);
        d.pending.items.len -= n;
    }
}

/// Sends bytes to the program, or to `-inputcommand`.
fn send(w: *Widget, bytes: []const u8) void {
    const d = data(w);
    if (d.fd >= 0) {
        d.pending.appendSlice(w.app.gpa, bytes) catch return;
        flushPending(w);
        if (d.pending.items.len > 0) schedule(w, 2000);
        return;
    }
    const script = optText(w, "-inputcommand");
    if (script.len == 0) return;
    const it = w.app.it;
    var s: std.ArrayList(u8) = .empty;
    s.appendSlice(it.alloc(), script) catch return;
    s.append(it.alloc(), ' ') catch return;
    ztcl.value.appendElement(it.alloc(), &s, bytes, false) catch return;
    _ = it.eval(s.items) catch |e| w.app.backgroundError(e);
}

// Size and paint.

fn cellSize(w: *Widget, desc: font_mod.FontDesc) void {
    const d = data(w);
    d.cell_w = @max(paint.zeroWidth(w.app, desc), 1);
    d.cell_h = @max(paint.lineHeight(w.app, desc), 1);
}

fn measure(w: *Widget) geom.Size {
    const app = w.app;
    app.ensureStyle(w);
    const st = &w.style;
    cellSize(w, st.font);
    const d = data(w);
    const cols = std.math.clamp(optInt(w, "-width", 80), 1, 1000);
    const rows = std.math.clamp(optInt(w, "-height", 24), 1, 1000);
    const ins = paint.insets(st);
    return .{ .w = num.add(@intCast(cols * d.cell_w), ins.horizontal()), .h = num.add(@intCast(rows * d.cell_h), ins.vertical()) };
}

/// The 16 colors of the palette: the xterm colors with a lighter blue.
const ansi = [16][3]u8{
    .{ 0, 0, 0 },       .{ 205, 49, 49 },   .{ 13, 188, 121 }, .{ 229, 229, 16 },
    .{ 36, 114, 200 },  .{ 188, 63, 188 },  .{ 17, 168, 205 }, .{ 229, 229, 229 },
    .{ 102, 102, 102 }, .{ 241, 76, 76 },   .{ 35, 209, 139 }, .{ 245, 245, 67 },
    .{ 59, 142, 234 },  .{ 214, 112, 214 }, .{ 41, 184, 219 }, .{ 255, 255, 255 },
};

fn paletteColor(i: u8) geom.Color {
    if (i < 16) return .{ .r = ansi[i][0], .g = ansi[i][1], .b = ansi[i][2] };
    if (i < 232) {
        const k = i - 16;
        const steps = [6]u8{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = steps[k / 36], .g = steps[(k / 6) % 6], .b = steps[k % 6] };
    }
    const g: u8 = 8 + (i - 232) * 10;
    return .{ .r = g, .g = g, .b = g };
}

fn resolve(c: screen_mod.Color, default: geom.Color, bold: bool) geom.Color {
    return switch (c) {
        .default => default,
        .index => |i| paletteColor(if (bold and i < 8) i + 8 else i),
        .rgb => |v| .{ .r = v[0], .g = v[1], .b = v[2] },
    };
}

const Colors = struct { fg: geom.Color, bg: ?geom.Color };

fn selected(d: *const Data, line: usize, col: u16) bool {
    const a = d.sel_a orelse return false;
    const b = d.sel_b orelse return false;
    const lo = if (b.before(a)) b else a;
    const hi = if (b.before(a)) a else b;
    const p: Pos = .{ .line = line, .col = col };
    return !p.before(lo) and p.before(hi);
}

fn cellOf(cells: []const Cell, x: usize) Cell {
    return if (x < cells.len) cells[x] else .{};
}

fn cellColors(d: *const Data, c: Cell, line: usize, col: u16, st: *const style_mod.Style, sel: *const style_mod.Style, cursor: bool) Colors {
    var fg = resolve(c.fg, st.color, c.attrs.bold);
    var bg: ?geom.Color = switch (c.bg) {
        .default => null,
        else => resolve(c.bg, st.background, false),
    };
    if (c.attrs.inverse) {
        const old = fg;
        fg = bg orelse st.background;
        bg = old;
    }
    if (c.attrs.dim) fg.a = 160;
    if (c.attrs.hidden) fg = bg orelse st.background;
    if (selected(d, line, col)) {
        fg = sel.color;
        bg = sel.background;
    }
    if (cursor) {
        fg = bg orelse st.background;
        bg = st.color;
    }
    return .{ .fg = fg, .bg = bg };
}

/// The first view line that the widget shows.
fn topLine(d: *const Data) usize {
    const sb = d.screen.scrollbackLen();
    return sb - @min(d.view_off, sb);
}

/// The style with an opaque background. A theme with no rule for the
/// class gives a clear background, so the option `-background` fills in.
fn solid(w: *const Widget, shown: *const style_mod.Style) style_mod.Style {
    var st = shown.*;
    if (st.background.a == 0) {
        const v = options.get(w, "-background").value;
        st.background = if (v == .color) v.color else .{ .r = 255, .g = 255, .b = 255 };
    }
    return st;
}

fn paintTerminal(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const shown = anim.shown(app, w);
    const solid_style = solid(w, shown);
    const st = &solid_style;
    const d = data(w);
    try paint.box(w, b, st);
    cellSize(w, st.font);
    const r = paint.contentRect(w, st);
    // The size of the grid follows the size of the widget.
    const cols: u16 = @intCast(std.math.clamp(@divFloor(r.w, d.cell_w), 1, 1000));
    const rows: u16 = @intCast(std.math.clamp(@divFloor(r.h, d.cell_h), 1, 1000));
    if (cols != d.screen.cols or rows != d.screen.rows) {
        try d.screen.resize(cols, rows);
        d.view_off = @min(d.view_off, d.screen.scrollbackLen());
        if (d.fd >= 0) {
            d.resize_pty = true;
            schedule(w, 0);
        }
    }
    const sel_part = paint.partStyle(w, "::selection", &d.sel_anim);
    var sel_style = sel_part.style;
    if (sel_style.background.a == 0) {
        sel_style.background = st.color;
        sel_style.color = st.background;
    }
    const sel = &sel_style;
    b.pushClip(r);
    defer b.popClip();
    const top = topLine(d);
    const show_cursor = d.screen.modes.cursor_visible and d.view_off == 0;
    const cy = d.screen.cursor.y;
    const cx = d.screen.cursor.x;
    // Pass 1: the backgrounds.
    for (0..rows) |ry| {
        const li = top + ry;
        const cells = d.screen.lineAt(li).cells;
        var x: u16 = 0;
        while (x < cols) {
            const here = cellColors(d, cellOf(cells, x), li, x, st, sel, show_cursor and d.focused and ry == cy and x == cx);
            var end = x + 1;
            while (end < cols) : (end += 1) {
                const next = cellColors(d, cellOf(cells, end), li, end, st, sel, show_cursor and d.focused and ry == cy and end == cx);
                if (!sameColor(next.bg, here.bg)) break;
            }
            if (here.bg) |bg| try b.box(.{ .x = r.x + @as(i32, x) * d.cell_w, .y = r.y + @as(i32, @intCast(ry)) * d.cell_h, .w = @as(i32, end - x) * d.cell_w, .h = d.cell_h }, .{ .fill = bg });
            x = end;
        }
    }
    // Pass 2: the text.
    const mfont = app.fonts.get(st.font, 1) catch return;
    const ascent = font_mod.Fonts.metrics(mfont).ascent;
    var text: std.ArrayList(u8) = .empty;
    var starts: std.ArrayList(u16) = .empty;
    const a = app.it.alloc();
    for (0..rows) |ry| {
        const li = top + ry;
        const cells = d.screen.lineAt(li).cells;
        const y = r.y + @as(i32, @intCast(ry)) * d.cell_h;
        var x: u16 = 0;
        while (x < cols) {
            const c0 = cellOf(cells, x);
            const here = cellColors(d, c0, li, x, st, sel, show_cursor and d.focused and ry == cy and x == cx);
            text.clearRetainingCapacity();
            starts.clearRetainingCapacity();
            var end = x;
            while (end < cols) : (end += 1) {
                const c = cellOf(cells, end);
                if (c.width == 0) continue;
                if (boxdraw.covers(c.cp)) {
                    const cc0 = cellColors(d, c, li, end, st, sel, show_cursor and d.focused and ry == cy and end == cx);
                    try boxdraw.draw(b, c.cp, .{ .x = r.x + @as(i32, end) * d.cell_w, .y = y, .w = d.cell_w, .h = d.cell_h }, cc0.fg);
                    continue;
                }
                const cc = cellColors(d, c, li, end, st, sel, show_cursor and d.focused and ry == cy and end == cx);
                if (end > x and (!sameColor(cc.fg, here.fg) or c.attrs.bold != c0.attrs.bold or c.attrs.italic != c0.attrs.italic or c.attrs.underline != c0.attrs.underline or c.attrs.strike != c0.attrs.strike)) break;
                var ub: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c.cp, &ub) catch 0;
                try starts.append(a, end - x);
                try text.appendSlice(a, ub[0..n]);
            }
            if (end == x) end = x + 1;
            const run_x = r.x + @as(i32, x) * d.cell_w;
            const fg = here.fg;
            if (std.mem.trim(u8, text.items, " ").len > 0) try drawRun(app, b, st.font, c0.attrs, text.items, starts.items, run_x, y + ascent, d.cell_w, fg);
            if (c0.attrs.underline) try b.box(.{ .x = run_x, .y = y + ascent + 1, .w = @as(i32, end - x) * d.cell_w, .h = 1 }, .{ .fill = fg });
            if (c0.attrs.strike) try b.box(.{ .x = run_x, .y = y + @divFloor(d.cell_h, 2), .w = @as(i32, end - x) * d.cell_w, .h = 1 }, .{ .fill = fg });
            x = end;
        }
    }
    // The cursor without the focus is a frame, and the bar and the
    // underline styles are thin boxes.
    if (show_cursor) {
        const rect: geom.Rect = .{ .x = r.x + @as(i32, cx) * d.cell_w, .y = r.y + @as(i32, cy) * d.cell_h, .w = d.cell_w, .h = d.cell_h };
        const style = d.screen.modes.cursor_style;
        if (!d.focused) {
            try b.box(rect, .{ .border = .{ 1, 1, 1, 1 }, .border_color = st.color });
        } else if (style == 5 or style == 6) {
            try b.box(.{ .x = rect.x, .y = rect.y, .w = 2, .h = rect.h }, .{ .fill = st.color });
        } else if (style == 3 or style == 4) {
            try b.box(.{ .x = rect.x, .y = rect.y + rect.h - 2, .w = rect.w, .h = 2 }, .{ .fill = st.color });
        }
    }
}

fn sameColor(x: ?geom.Color, y: ?geom.Color) bool {
    if (x == null or y == null) return x == null and y == null;
    const p = x.?;
    const q = y.?;
    return p.r == q.r and p.g == q.g and p.b == q.b and p.a == q.a;
}

fn drawRun(app: *App, b: *scene.Builder, base: font_mod.FontDesc, attrs: screen_mod.Attrs, text: []const u8, starts: []const u16, x: i32, baseline: i32, cell_w: i32, color: geom.Color) !void {
    var desc = base;
    if (attrs.bold) desc.weight = 700;
    if (attrs.italic) desc.italic = true;
    const pfont = try app.fonts.get(desc, b.scale);
    var run = try shape.shape(app.gpa, pfont, text);
    defer run.deinit(app.gpa);
    // Glyph k goes to the left edge of its cell. The cluster is the byte
    // index of the code point of the glyph.
    var byte: usize = 0;
    var k: usize = 0;
    for (run.glyphs) |*g| {
        while (k + 1 < starts.len and byte < g.cluster) {
            const n = std.unicode.utf8ByteSequenceLength(text[byte]) catch 1;
            byte += n;
            k += 1;
        }
        g.x = @as(f32, @floatFromInt(@as(i32, starts[k]) * cell_w)) * b.scale;
    }
    try b.text(&app.atlas, &run, x, baseline, color);
}

// Events.

fn cellAt(w: *Widget, ev_x: i32, ev_y: i32) Pos {
    const d = data(w);
    const st = &w.style;
    const r = paint.contentRect(w, st);
    const col = std.math.clamp(@divFloor(ev_x - r.x, d.cell_w), 0, d.screen.cols - 1);
    const row = std.math.clamp(@divFloor(ev_y - r.y, d.cell_h), 0, d.screen.rows - 1);
    return .{ .line = topLine(d) + @as(usize, @intCast(row)), .col = @intCast(col) };
}

fn modsOf(ev: *const bind.WidgetEvent) keys.Mods {
    return .{ .shift = ev.mods.shift, .control = ev.mods.control, .alt = ev.mods.mod1 };
}

fn repaint(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false });
}

fn onEvent(w: *Widget, ev: *const bind.WidgetEvent) void {
    if (!w.alive()) return;
    const d = data(w);
    switch (ev.type) {
        .key_press => onKey(w, ev),
        .focus_in, .focus_out => {
            d.focused = ev.type == .focus_in;
            if (d.screen.modes.focus_events) send(w, if (d.focused) "\x1b[I" else "\x1b[O");
            repaint(w);
        },
        .button_press => {
            if (ev.button == 4 or ev.button == 5) return wheel(w, ev, if (ev.button == 4) 1 else -1);
            if (d.screen.modes.mouse != .none and !ev.mods.shift) return mouseReport(w, ev, ev.button - 1, true);
            if (ev.button != 1) return;
            const p = cellAt(w, ev.x, ev.y);
            switch (ev.count) {
                2 => selectWord(w, p),
                3 => {
                    d.sel_a = .{ .line = p.line, .col = 0 };
                    d.sel_b = .{ .line = p.line, .col = d.screen.cols };
                },
                else => {
                    d.sel_a = p;
                    d.sel_b = p;
                    d.selecting = true;
                },
            }
            repaint(w);
        },
        .motion => {
            if (d.mouse_down != null and (d.screen.modes.mouse == .button or d.screen.modes.mouse == .any)) return mouseReport(w, ev, d.mouse_down.? + 32, true);
            if (d.screen.modes.mouse == .any) return mouseReport(w, ev, 35, true);
            if (!d.selecting) return;
            var p = cellAt(w, ev.x, ev.y);
            // The cell under the pointer is in the selection.
            if (!p.before(d.sel_a.?)) p.col +|= 1;
            d.sel_b = p;
            repaint(w);
        },
        .button_release => {
            if (d.mouse_down) |btn| {
                _ = btn;
                return mouseReport(w, ev, 3, false);
            }
            d.selecting = false;
            if (d.sel_a != null and d.sel_b != null and d.sel_a.?.line == d.sel_b.?.line and d.sel_a.?.col == d.sel_b.?.col) {
                d.sel_a = null;
                d.sel_b = null;
                repaint(w);
            }
        },
        .mouse_wheel => wheel(w, ev, if (ev.delta > 0) 1 else -1),
        else => {},
    }
}

fn onKey(w: *Widget, ev: *const bind.WidgetEvent) void {
    const d = data(w);
    const name = keysym.toName(ev.keysym) orelse "";
    const m = modsOf(ev);
    if (m.control and m.shift and (std.ascii.eqlIgnoreCase(name, "c"))) return copySelection(w);
    if (m.control and m.shift and (std.ascii.eqlIgnoreCase(name, "v"))) return pasteClipboard(w);
    if (m.shift and !m.control and (std.mem.eql(u8, name, "Prior") or std.mem.eql(u8, name, "Next"))) {
        scrollView(w, if (std.mem.eql(u8, name, "Prior")) @as(i64, d.screen.rows) - 1 else -(@as(i64, d.screen.rows) - 1));
        return;
    }
    var out: std.ArrayList(u8) = .empty;
    const a = w.app.it.alloc();
    const sent = keys.encode(a, &out, name, ev.text, m, d.screen.modes.cursor_keys_app) catch return;
    if (!sent) return;
    if (d.view_off != 0) {
        d.view_off = 0;
        repaint(w);
    }
    send(w, out.items);
}

fn wheel(w: *Widget, ev: *const bind.WidgetEvent, dir: i64) void {
    const d = data(w);
    if (d.screen.modes.mouse != .none and !ev.mods.shift) return mouseReport(w, ev, if (dir > 0) 64 else 65, true);
    if (d.screen.alt_active) {
        // A full-screen program with no mouse mode gets cursor keys.
        const key = if (dir > 0) "\x1b[A" else "\x1b[B";
        const app_key = if (dir > 0) "\x1bOA" else "\x1bOB";
        for (0..3) |_| send(w, if (d.screen.modes.cursor_keys_app) app_key else key);
        return;
    }
    scrollView(w, dir * 3);
}

fn scrollView(w: *Widget, lines: i64) void {
    const d = data(w);
    const sb: i64 = @intCast(d.screen.scrollbackLen());
    const off = std.math.clamp(@as(i64, @intCast(d.view_off)) + lines, 0, sb);
    d.view_off = @intCast(off);
    repaint(w);
}

fn mouseReport(w: *Widget, ev: *const bind.WidgetEvent, button: u8, press: bool) void {
    const d = data(w);
    const p = cellAt(w, ev.x, ev.y);
    const x: u32 = p.col + 1;
    const y: u32 = @intCast(p.line - topLine(d) + 1);
    var code: u32 = button;
    if (ev.mods.shift) code += 4;
    if (ev.mods.mod1) code += 8;
    if (ev.mods.control) code += 16;
    if (button < 3) d.mouse_down = if (press) button else null;
    if (!press) d.mouse_down = null;
    if (d.screen.modes.mouse == .x10 and !press) return;
    var buf: [48]u8 = undefined;
    const msg = if (d.screen.modes.mouse_sgr)
        std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{ code, x, y, @as(u8, if (press) 'M' else 'm') }) catch return
    else
        std.fmt.bufPrint(&buf, "\x1b[M{c}{c}{c}", .{ @as(u8, @intCast(@min(32 + (if (press) code else 3), 255))), @as(u8, @intCast(@min(32 + x, 255))), @as(u8, @intCast(@min(32 + y, 255))) }) catch return;
    send(w, msg);
}

fn isWordChar(cp: u21) bool {
    return cp > 127 or std.ascii.isAlphanumeric(@intCast(cp)) or cp == '_' or cp == '-' or cp == '.' or cp == '/' or cp == '~';
}

fn selectWord(w: *Widget, p: Pos) void {
    const d = data(w);
    const cells = d.screen.lineAt(p.line).cells;
    if (p.col >= cells.len) return;
    var lo = p.col;
    var hi = p.col;
    if (!isWordChar(cells[p.col].cp)) {
        hi += 1;
    } else {
        while (lo > 0 and isWordChar(cells[lo - 1].cp)) lo -= 1;
        while (hi < cells.len and isWordChar(cells[hi].cp)) hi += 1;
    }
    d.sel_a = .{ .line = p.line, .col = lo };
    d.sel_b = .{ .line = p.line, .col = hi };
}

/// The text of the selection. A wrapped line joins the next line with
/// no newline.
fn selectionText(w: *Widget, a: std.mem.Allocator) ![]const u8 {
    const d = data(w);
    const sa = d.sel_a orelse return "";
    const sb = d.sel_b orelse return "";
    const lo = if (sb.before(sa)) sb else sa;
    const hi = if (sb.before(sa)) sa else sb;
    var out: std.ArrayList(u8) = .empty;
    const last = d.screen.scrollbackLen() + d.screen.rows;
    var li = lo.line;
    while (li <= hi.line and li < last) : (li += 1) {
        const from: usize = if (li == lo.line) lo.col else 0;
        const to: usize = if (li == hi.line) hi.col else d.screen.cols;
        try out.appendSlice(a, try d.screen.lineText(a, li, from, to));
        if (li < hi.line and !d.screen.lineAt(li).wrapped) try out.append(a, '\n');
    }
    return out.items;
}

fn copySelection(w: *Widget) void {
    const text = selectionText(w, w.app.it.alloc()) catch return;
    if (text.len == 0) return;
    clipboard.setText(w.app, text) catch {};
}

fn pasteText(w: *Widget, text: []const u8) void {
    const d = data(w);
    const a = w.app.it.alloc();
    var out: std.ArrayList(u8) = .empty;
    if (d.screen.modes.bracketed_paste) out.appendSlice(a, "\x1b[200~") catch return;
    // A newline in a paste is a carriage return, as a key press of Return.
    for (text) |c| {
        if (c == 0x1b and d.screen.modes.bracketed_paste) continue;
        out.append(a, if (c == '\n') '\r' else c) catch return;
    }
    if (d.screen.modes.bracketed_paste) out.appendSlice(a, "\x1b[201~") catch return;
    send(w, out.items);
}

fn pasteClipboard(w: *Widget) void {
    const text = (clipboard.read(w.app, w.app.it.alloc(), "STRING") catch return) orelse return;
    pasteText(w, text);
}

// Subcommands.

fn wrong(w: *const Widget, it: *ztcl.Interp, comptime rest: []const u8) ztcl.Error {
    return it.failCode("TCL WRONGARGS", "wrong # args: should be \"{s} " ++ rest ++ "\"", .{w.path});
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const d = data(w);
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "write")) {
        if (argv.len != 3) return wrong(w, it, "write data");
        d.screen.write(try it.str(argv[2]));
        if (d.screen.reply.items.len > 0) {
            const r = try a.dupe(u8, d.screen.reply.items);
            d.screen.reply.clearRetainingCapacity();
            send(w, r);
        }
        repaint(w);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "send")) {
        if (argv.len != 3) return wrong(w, it, "send data");
        send(w, try it.str(argv[2]));
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "paste")) {
        if (argv.len != 3) return wrong(w, it, "paste text");
        pasteText(w, try it.str(argv[2]));
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "copy")) {
        copySelection(w);
        return .{ .str = "" };
    }
    if (std.mem.eql(u8, sub, "get")) {
        // `get ?first? ?last?`: view lines, where 0 is the first row of
        // the screen and a negative index is in the scrollback.
        if (argv.len > 4) return wrong(w, it, "get ?first? ?last?");
        const sb: i64 = @intCast(d.screen.scrollbackLen());
        const first = if (argv.len > 2) try it.int(argv[2]) else 0;
        const last = if (argv.len > 3) try it.int(argv[3]) else if (argv.len > 2) first else @as(i64, d.screen.rows) - 1;
        var out: std.ArrayList(u8) = .empty;
        var i = std.math.clamp(first, -sb, @as(i64, d.screen.rows) - 1);
        const end = std.math.clamp(last, -sb, @as(i64, d.screen.rows) - 1);
        while (i <= end) : (i += 1) {
            const li: usize = @intCast(i + sb);
            try out.appendSlice(a, try d.screen.lineText(a, li, 0, d.screen.cols));
            if (i < end) try out.append(a, '\n');
        }
        return .{ .str = out.items };
    }
    if (std.mem.eql(u8, sub, "size")) {
        var v = [2]Value{ .{ .int = d.screen.cols }, .{ .int = d.screen.rows } };
        return try ztcl.value.wrapList(a, try a.dupe(Value, &v));
    }
    if (std.mem.eql(u8, sub, "cursor")) {
        var v = [2]Value{ .{ .int = d.screen.cursor.x }, .{ .int = d.screen.cursor.y } };
        return try ztcl.value.wrapList(a, try a.dupe(Value, &v));
    }
    if (std.mem.eql(u8, sub, "title")) return .{ .str = try a.dupe(u8, d.screen.title.items) };
    if (std.mem.eql(u8, sub, "channel")) return .{ .str = try a.dupe(u8, d.chan) };
    if (std.mem.eql(u8, sub, "status")) {
        if (d.chan.len == 0) return .{ .str = "none" };
        return try ptyCall(w, "status", "");
    }
    if (std.mem.eql(u8, sub, "kill")) {
        if (d.chan.len == 0) return .{ .str = "" };
        var extra: std.ArrayList(u8) = .empty;
        if (argv.len > 2) {
            try extra.append(a, ' ');
            try ztcl.value.appendElement(a, &extra, try it.str(argv[2]), false);
        }
        return try ptyCall(w, "kill", extra.items);
    }
    if (std.mem.eql(u8, sub, "selection")) {
        if (argv.len < 3) return wrong(w, it, "selection get|clear|range ?...?");
        const op = try it.str(argv[2]);
        if (std.mem.eql(u8, op, "get")) return .{ .str = try selectionText(w, a) };
        if (std.mem.eql(u8, op, "clear")) {
            d.sel_a = null;
            d.sel_b = null;
            repaint(w);
            return .{ .str = "" };
        }
        if (std.mem.eql(u8, op, "range")) {
            // `selection range line col line col`, in view lines as for `get`.
            if (argv.len != 7) return wrong(w, it, "selection range line col line col");
            const sb: i64 = @intCast(d.screen.scrollbackLen());
            const max_line = sb + d.screen.rows - 1;
            var ps: [2]Pos = undefined;
            for (0..2) |k| {
                const l = std.math.clamp(try it.int(argv[3 + 2 * k]) + sb, 0, max_line);
                const c = std.math.clamp(try it.int(argv[4 + 2 * k]), 0, d.screen.cols);
                ps[k] = .{ .line = @intCast(l), .col = @intCast(c) };
            }
            d.sel_a = ps[0];
            d.sel_b = ps[1];
            repaint(w);
            return .{ .str = "" };
        }
        return it.fail("bad selection option \"{s}\": must be clear, get, or range", .{op});
    }
    if (std.mem.eql(u8, sub, "yview")) {
        const sb = d.screen.scrollbackLen();
        const total: f64 = @floatFromInt(sb + d.screen.rows);
        if (argv.len == 2) {
            const top: f64 = @floatFromInt(topLine(d));
            var v = [2]Value{ .{ .double = top / total }, .{ .double = (top + @as(f64, @floatFromInt(d.screen.rows))) / total } };
            return try ztcl.value.wrapList(a, try a.dupe(Value, &v));
        }
        const op = try it.str(argv[2]);
        if (std.mem.eql(u8, op, "scroll") and argv.len == 5) {
            const n = try it.int(argv[3]);
            const unit = try it.str(argv[4]);
            const lines = if (std.mem.startsWith(u8, unit, "p")) n * (@as(i64, d.screen.rows) - 1) else n;
            scrollView(w, -lines);
            return .{ .str = "" };
        }
        if (std.mem.eql(u8, op, "moveto") and argv.len == 4) {
            const f = std.math.clamp(std.fmt.parseFloat(f64, try it.str(argv[3])) catch return it.fail("expected floating-point number but got \"{s}\"", .{try it.str(argv[3])}), 0, 1);
            const top: usize = @intFromFloat(@round(f * total));
            d.view_off = sb - @min(top, sb);
            repaint(w);
            return .{ .str = "" };
        }
        return wrong(w, it, "yview ?moveto fraction? ?scroll number units|pages?");
    }
    return null;
}

pub fn register(app: *App) !void {
    try app.it.register("ztk::terminal", widget.classCommand(&class));
    try app.classes.put(app.gpa, "ztk::terminal", &class);
    // The keys that the bindings of `all` take (focus traversal) go to
    // the program. The class binding ends the event.
    _ = try app.it.eval(
        \\bind Terminal <Tab> break
        \\bind Terminal <Shift-Tab> break
        \\bind Terminal <<PrevWindow>> break
        \\bind Terminal <Button-1> {focus %W}
    );
}
