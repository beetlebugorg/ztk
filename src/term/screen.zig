//! The state of a terminal: two grids of cells (the primary screen and
//! the alternate screen), the cursor, the modes, and the scrollback of
//! the primary screen. `write` feeds bytes through the parser of
//! `parser.zig`, and the handler methods of this file change the state.
//!
//! A grid is an array of lines, and a line is an array of cells. A cell
//! has one code point, its colors, and its attributes. A wide character
//! has width 2 in its first cell, and the next cell is a spacer of width
//! 0. A scroll moves line slices and copies no cells. A line that
//! scrolls off the top of the full primary screen goes to the
//! scrollback, a ring of at most `scrollback_max` lines.
//!
//! The functions follow the DEC VT100 and VT220 manuals, ECMA-48, and
//! the xterm control sequences document: the cursor moves, the erase and
//! insert functions, the scroll region (DECSTBM), the origin mode, the
//! autowrap with the pending wrap of the last column, the tab stops,
//! SGR with 16, 256, and 24-bit colors, the DEC special graphics set,
//! the alternate screen (47, 1047, 1049), and the replies of DSR, DA,
//! and the OSC color queries. Replies go to `reply`. The owner sends
//! them to the program.
//!
//! A resize keeps the cells of each line from column 0 and does not
//! wrap lines again. When the screen gets shorter, the lines above the
//! cursor go to the scrollback, so the cursor line stays.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const parser_mod = @import("parser.zig");
const width = @import("width.zig");
const Csi = parser_mod.Csi;

/// A color: the default, an index of the 256-color palette, or RGB.
pub const Color = union(enum) {
    default,
    index: u8,
    rgb: [3]u8,
};

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    _pad: u8 = 0,
};

pub const Cell = struct {
    cp: u21 = ' ',
    /// 1 for a normal cell, 2 for the first cell of a wide character,
    /// and 0 for the spacer after it.
    width: u2 = 1,
    attrs: Attrs = .{},
    fg: Color = .default,
    bg: Color = .default,
};

pub const Line = struct {
    cells: []Cell,
    /// True when the text goes on in the next line (an autowrap).
    wrapped: bool = false,
};

const Grid = struct {
    lines: []Line = &.{},
};

const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    pending_wrap: bool = false,
    attrs: Attrs = .{},
    fg: Color = .default,
    bg: Color = .default,
    /// True when G0 is the DEC special graphics set.
    graphics: bool = false,
    origin: bool = false,
};

pub const MouseMode = enum { none, x10, normal, button, any };

pub const Modes = struct {
    autowrap: bool = true,
    insert: bool = false,
    newline: bool = false,
    cursor_keys_app: bool = false,
    keypad_app: bool = false,
    cursor_visible: bool = true,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    mouse: MouseMode = .none,
    mouse_sgr: bool = false,
    /// DECSCUSR: 0 or 1 blinking block, 2 block, 3 and 4 underline, 5
    /// and 6 bar.
    cursor_style: u8 = 0,
};

/// The colors that the OSC queries 10, 11, and 12 report.
pub const Theme = struct {
    fg: [3]u8 = .{ 0, 0, 0 },
    bg: [3]u8 = .{ 255, 255, 255 },
    cursor: [3]u8 = .{ 0, 0, 0 },
};

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    primary: Grid = .{},
    alternate: Grid = .{},
    alt_active: bool = false,
    cursor: Cursor = .{},
    saved: Cursor = .{},
    saved_alt: Cursor = .{},
    modes: Modes = .{},
    /// The scroll region: the top and the bottom row, inclusive.
    top: u16 = 0,
    bottom: u16 = 0,
    tabs: std.DynamicBitSetUnmanaged = .{},
    /// The ring of scrollback lines. `sb_head` is the oldest line.
    scrollback: std.ArrayList(Line) = .empty,
    sb_head: usize = 0,
    scrollback_max: usize = 10000,
    parser: parser_mod.Parser = .{},
    /// The bytes that the terminal sends back to the program.
    reply: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    title_changed: bool = false,
    bells: u32 = 0,
    /// The count of changes. The owner draws again when it differs.
    generation: u64 = 0,
    /// The last printed code point, for REP.
    last_cp: u21 = ' ',
    theme: Theme = .{},

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        var s: Screen = .{ .gpa = gpa, .cols = @max(cols, 1), .rows = @max(rows, 1) };
        s.bottom = s.rows - 1;
        s.primary = try s.newGrid();
        s.alternate = try s.newGrid();
        try s.resetTabs();
        return s;
    }

    pub fn deinit(s: *Screen) void {
        s.freeGrid(&s.primary);
        s.freeGrid(&s.alternate);
        for (s.scrollback.items) |l| s.gpa.free(l.cells);
        s.scrollback.deinit(s.gpa);
        s.tabs.deinit(s.gpa);
        s.reply.deinit(s.gpa);
        s.title.deinit(s.gpa);
    }

    fn newLine(s: *Screen) ![]Cell {
        const cells = try s.gpa.alloc(Cell, s.cols);
        @memset(cells, .{});
        return cells;
    }

    fn newGrid(s: *Screen) !Grid {
        const lines = try s.gpa.alloc(Line, s.rows);
        for (lines) |*l| l.* = .{ .cells = try s.newLine() };
        return .{ .lines = lines };
    }

    fn freeGrid(s: *Screen, g: *Grid) void {
        for (g.lines) |l| s.gpa.free(l.cells);
        s.gpa.free(g.lines);
        g.lines = &.{};
    }

    fn resetTabs(s: *Screen) !void {
        try s.tabs.resize(s.gpa, s.cols, false);
        s.tabs.unsetAll();
        var x: usize = 8;
        while (x < s.cols) : (x += 8) s.tabs.set(x);
    }

    fn grid(s: *Screen) *Grid {
        return if (s.alt_active) &s.alternate else &s.primary;
    }

    /// The count of scrollback lines that the view shows. The alternate
    /// screen shows none.
    pub fn scrollbackLen(s: *const Screen) usize {
        return if (s.alt_active) 0 else s.scrollback.items.len;
    }

    /// Line `i` of the view: the scrollback from the oldest line, then
    /// the rows of the screen.
    pub fn lineAt(s: *const Screen, i: usize) *const Line {
        const sb = s.scrollbackLen();
        if (i < sb) return &s.scrollback.items[(s.sb_head + i) % s.scrollback.items.len];
        const g = if (s.alt_active) &s.alternate else &s.primary;
        return &g.lines[@min(i - sb, s.rows - 1)];
    }

    pub fn write(s: *Screen, bytes: []const u8) void {
        s.parser.feed(bytes, s);
        s.generation +%= 1;
    }

    fn blank(s: *const Screen) Cell {
        // An erase uses the background of the pen, as in xterm.
        return .{ .bg = s.cursor.bg };
    }

    fn line(s: *Screen, y: u16) *Line {
        return &s.grid().lines[y];
    }

    // The handler methods of the parser.

    pub fn print(s: *Screen, cp_in: u21) void {
        var cp = cp_in;
        if (s.cursor.graphics and cp >= 0x5f and cp <= 0x7e) cp = graphics_map[cp - 0x5f];
        const w = width.of(cp);
        if (w == 0) return;
        s.last_cp = cp;
        if (s.cursor.pending_wrap and s.modes.autowrap) {
            s.line(s.cursor.y).wrapped = true;
            s.cursor.x = 0;
            s.index();
        }
        s.cursor.pending_wrap = false;
        if (w == 2 and s.cursor.x + 1 >= s.cols) {
            if (s.cols < 2) return;
            if (s.modes.autowrap) {
                s.line(s.cursor.y).cells[s.cursor.x] = s.blank();
                s.line(s.cursor.y).wrapped = true;
                s.cursor.x = 0;
                s.index();
            } else s.cursor.x = s.cols - 2;
        }
        const ln = s.line(s.cursor.y);
        if (s.modes.insert) s.insertCells(w);
        s.clearWide(ln, s.cursor.x);
        if (w == 2) s.clearWide(ln, s.cursor.x + 1);
        ln.cells[s.cursor.x] = .{ .cp = cp, .width = w, .attrs = s.cursor.attrs, .fg = s.cursor.fg, .bg = s.cursor.bg };
        if (w == 2) ln.cells[s.cursor.x + 1] = .{ .cp = ' ', .width = 0, .attrs = s.cursor.attrs, .fg = s.cursor.fg, .bg = s.cursor.bg };
        const next = s.cursor.x + w;
        if (next >= s.cols) {
            s.cursor.x = s.cols - 1;
            s.cursor.pending_wrap = true;
        } else s.cursor.x = next;
    }

    /// Clears the other half of a wide character at column `x`.
    fn clearWide(s: *Screen, ln: *Line, x: u16) void {
        const c = ln.cells[x];
        if (c.width == 2 and x + 1 < s.cols) ln.cells[x + 1] = s.blank();
        if (c.width == 0 and x > 0) ln.cells[x - 1] = s.blank();
    }

    pub fn execute(s: *Screen, b: u8) void {
        switch (b) {
            0x07 => s.bells += 1,
            0x08 => {
                if (s.cursor.x > 0) s.cursor.x -= 1;
                s.cursor.pending_wrap = false;
            },
            0x09 => s.tabForward(1),
            0x0a, 0x0b, 0x0c => {
                s.index();
                if (s.modes.newline) s.cursor.x = 0;
            },
            0x0d => {
                s.cursor.x = 0;
                s.cursor.pending_wrap = false;
            },
            0x0e => s.cursor.graphics = true,
            0x0f => s.cursor.graphics = false,
            else => {},
        }
    }

    pub fn esc(s: *Screen, inter: u8, final: u8) void {
        if (inter == '(') {
            s.cursor.graphics = final == '0';
            return;
        }
        if (inter == '#' and final == '8') {
            // DECALN: fill the screen with E.
            for (s.grid().lines) |*l| @memset(l.cells, .{ .cp = 'E' });
            return;
        }
        if (inter != 0) return;
        switch (final) {
            '7' => s.saveCursor(),
            '8' => s.restoreCursor(),
            'D' => s.index(),
            'E' => {
                s.index();
                s.cursor.x = 0;
            },
            'H' => s.tabs.set(s.cursor.x),
            'M' => s.reverseIndex(),
            'c' => s.fullReset(),
            '=' => s.modes.keypad_app = true,
            '>' => s.modes.keypad_app = false,
            else => {},
        }
    }

    pub fn osc(s: *Screen, text: []const u8) void {
        const semi = std.mem.indexOfScalar(u8, text, ';') orelse return;
        const num = std.fmt.parseInt(u16, text[0..semi], 10) catch return;
        const arg = text[semi + 1 ..];
        switch (num) {
            0, 2 => {
                s.title.clearRetainingCapacity();
                s.title.appendSlice(s.gpa, arg) catch {};
                s.title_changed = true;
            },
            10, 11, 12 => if (std.mem.eql(u8, arg, "?")) {
                const c = switch (num) {
                    10 => s.theme.fg,
                    11 => s.theme.bg,
                    else => s.theme.cursor,
                };
                s.reply.print(s.gpa, "\x1b]{d};rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{ num, c[0], c[0], c[1], c[1], c[2], c[2] }) catch {};
            },
            else => {},
        }
    }

    pub fn csi(s: *Screen, c: *const Csi) void {
        if (c.private == '?') return s.decPrivate(c);
        if (c.private == '>') {
            // The secondary device attributes: a VT220-class terminal.
            if (c.final == 'c') s.reply.appendSlice(s.gpa, "\x1b[>1;10;0c") catch {};
            return;
        }
        if (c.private != 0) return;
        if (c.inter == ' ' and c.final == 'q') {
            s.modes.cursor_style = @intCast(@min(c.get(0, 0), 6));
            return;
        }
        if (c.inter == '!' and c.final == 'p') return s.softReset();
        if (c.inter != 0) return;
        const n = c.get(0, 1);
        switch (c.final) {
            '@' => s.insertCells(n),
            'A' => s.moveUp(n),
            'B', 'e' => s.moveDown(n),
            'C', 'a' => s.moveTo(s.cursor.x +| n, s.cursor.y),
            'D' => s.moveTo(s.cursor.x -| n, s.cursor.y),
            'E' => {
                s.moveDown(n);
                s.cursor.x = 0;
            },
            'F' => {
                s.moveUp(n);
                s.cursor.x = 0;
            },
            'G', '`' => s.moveTo(n - 1, s.cursor.y),
            'H', 'f' => {
                const base: u16 = if (s.cursor.origin) s.top else 0;
                s.moveTo(c.get(1, 1) - 1, base +| (c.get(0, 1) - 1));
            },
            'I' => s.tabForward(n),
            'J' => s.eraseDisplay(c.get(0, 0)),
            'K' => s.eraseLine(c.get(0, 0)),
            'L' => s.insertLines(n),
            'M' => s.deleteLines(n),
            'P' => s.deleteCells(n),
            'S' => s.scrollUp(s.top, s.bottom, n),
            'T' => s.scrollDown(s.top, s.bottom, n),
            'X' => {
                const ln = s.line(s.cursor.y);
                const end = @min(@as(usize, s.cursor.x) + n, s.cols);
                @memset(ln.cells[s.cursor.x..end], s.blank());
                s.cursor.pending_wrap = false;
            },
            'Z' => {
                var k: u16 = 0;
                while (k < n and s.cursor.x > 0) : (k += 1) {
                    s.cursor.x -= 1;
                    while (s.cursor.x > 0 and !s.tabs.isSet(s.cursor.x)) s.cursor.x -= 1;
                }
            },
            'b' => {
                var k: u16 = 0;
                while (k < n) : (k += 1) s.print(s.last_cp);
            },
            'c' => if (c.get(0, 0) == 0) s.reply.appendSlice(s.gpa, "\x1b[?62;22c") catch {},
            'd' => {
                const base: u16 = if (s.cursor.origin) s.top else 0;
                s.moveTo(s.cursor.x, base +| (n - 1));
            },
            'g' => switch (c.get(0, 0)) {
                0 => s.tabs.unset(s.cursor.x),
                3 => s.tabs.unsetAll(),
                else => {},
            },
            'h', 'l' => {
                const on = c.final == 'h';
                for (0..@max(c.count, 1)) |k| switch (c.params[k]) {
                    4 => s.modes.insert = on,
                    20 => s.modes.newline = on,
                    else => {},
                };
            },
            'm' => s.sgr(c),
            'n' => switch (c.get(0, 0)) {
                5 => s.reply.appendSlice(s.gpa, "\x1b[0n") catch {},
                6 => {
                    const y = if (s.cursor.origin) s.cursor.y - s.top else s.cursor.y;
                    s.reply.print(s.gpa, "\x1b[{d};{d}R", .{ y + 1, s.cursor.x + 1 }) catch {};
                },
                else => {},
            },
            'r' => {
                const t = c.get(0, 1) - 1;
                const b = @min(c.get(1, s.rows), s.rows) - 1;
                if (t < b) {
                    s.top = t;
                    s.bottom = b;
                    s.cursor.x = 0;
                    s.cursor.y = if (s.cursor.origin) t else 0;
                    s.cursor.pending_wrap = false;
                }
            },
            's' => s.saveCursor(),
            'u' => s.restoreCursor(),
            else => {},
        }
    }

    fn decPrivate(s: *Screen, c: *const Csi) void {
        if (c.final != 'h' and c.final != 'l') return;
        const on = c.final == 'h';
        for (0..@max(c.count, 1)) |k| switch (c.params[k]) {
            1 => s.modes.cursor_keys_app = on,
            6 => {
                s.cursor.origin = on;
                s.moveTo(0, if (on) s.top else 0);
            },
            7 => s.modes.autowrap = on,
            9 => s.modes.mouse = if (on) .x10 else .none,
            25 => s.modes.cursor_visible = on,
            47, 1047 => s.useAlternate(on, false),
            1049 => s.useAlternate(on, true),
            1000 => s.modes.mouse = if (on) .normal else .none,
            1002 => s.modes.mouse = if (on) .button else .none,
            1003 => s.modes.mouse = if (on) .any else .none,
            1004 => s.modes.focus_events = on,
            1006 => s.modes.mouse_sgr = on,
            1048 => if (on) s.saveCursor() else s.restoreCursor(),
            2004 => s.modes.bracketed_paste = on,
            else => {},
        };
    }

    fn useAlternate(s: *Screen, on: bool, save: bool) void {
        if (on == s.alt_active) return;
        if (on) {
            if (save) s.saved_alt = s.cursor;
            s.alt_active = true;
            for (s.alternate.lines) |*l| {
                @memset(l.cells, .{});
                l.wrapped = false;
            }
        } else {
            s.alt_active = false;
            if (save) s.cursor = s.saved_alt;
        }
        s.cursor.pending_wrap = false;
    }

    fn sgr(s: *Screen, c: *const Csi) void {
        const cur = &s.cursor;
        if (c.count == 0) {
            cur.attrs = .{};
            cur.fg = .default;
            cur.bg = .default;
            return;
        }
        var k: usize = 0;
        while (k < c.count) : (k += 1) {
            const p = c.params[k];
            switch (p) {
                0 => {
                    cur.attrs = .{};
                    cur.fg = .default;
                    cur.bg = .default;
                },
                1 => cur.attrs.bold = true,
                2 => cur.attrs.dim = true,
                3 => cur.attrs.italic = true,
                4 => cur.attrs.underline = !(k + 1 < c.count and c.sub & (@as(u16, 1) << @intCast(k + 1)) != 0 and c.params[k + 1] == 0),
                5, 6 => cur.attrs.blink = true,
                7 => cur.attrs.inverse = true,
                8 => cur.attrs.hidden = true,
                9 => cur.attrs.strike = true,
                21 => cur.attrs.underline = true,
                22 => {
                    cur.attrs.bold = false;
                    cur.attrs.dim = false;
                },
                23 => cur.attrs.italic = false,
                24 => cur.attrs.underline = false,
                25 => cur.attrs.blink = false,
                27 => cur.attrs.inverse = false,
                28 => cur.attrs.hidden = false,
                29 => cur.attrs.strike = false,
                30...37 => cur.fg = .{ .index = @intCast(p - 30) },
                39 => cur.fg = .default,
                40...47 => cur.bg = .{ .index = @intCast(p - 40) },
                49 => cur.bg = .default,
                90...97 => cur.fg = .{ .index = @intCast(p - 90 + 8) },
                100...107 => cur.bg = .{ .index = @intCast(p - 100 + 8) },
                38, 48, 58 => {
                    const col = extendedColor(c, &k) orelse continue;
                    if (p == 38) cur.fg = col else if (p == 48) cur.bg = col;
                },
                else => {},
            }
            // Skip the sub-parameters of a code that does not use them.
            while (k + 1 < c.count and c.sub & (@as(u16, 1) << @intCast(k + 1)) != 0) k += 1;
        }
    }

    /// Reads `38;5;n`, `38;2;r;g;b`, and the forms with `:`. `k` is at
    /// the 38 and moves to the last parameter that the color uses.
    fn extendedColor(c: *const Csi, k: *usize) ?Color {
        if (k.* + 1 >= c.count) return null;
        const colon = c.sub & (@as(u16, 1) << @intCast(k.* + 1)) != 0;
        const kind = c.params[k.* + 1];
        if (kind == 5) {
            if (k.* + 2 >= c.count) return null;
            k.* += 2;
            return .{ .index = @intCast(@min(c.params[k.*], 255)) };
        }
        if (kind != 2) return null;
        // `38:2::r:g:b` has a color space id after the 2. `38:2:r:g:b`
        // and `38;2;r;g;b` have none.
        var first = k.* + 2;
        if (colon and k.* + 5 < c.count and c.sub & (@as(u16, 1) << @intCast(k.* + 5)) != 0) first += 1;
        if (first + 2 >= c.count) return null;
        k.* = first + 2;
        return .{ .rgb = .{ @intCast(@min(c.params[first], 255)), @intCast(@min(c.params[first + 1], 255)), @intCast(@min(c.params[first + 2], 255)) } };
    }

    fn saveCursor(s: *Screen) void {
        s.saved = s.cursor;
    }

    fn restoreCursor(s: *Screen) void {
        s.cursor = s.saved;
        s.cursor.x = @min(s.cursor.x, s.cols - 1);
        s.cursor.y = @min(s.cursor.y, s.rows - 1);
    }

    fn softReset(s: *Screen) void {
        s.modes = .{};
        s.top = 0;
        s.bottom = s.rows - 1;
        s.cursor.attrs = .{};
        s.cursor.fg = .default;
        s.cursor.bg = .default;
        s.cursor.origin = false;
        s.cursor.graphics = false;
        s.saved = .{};
    }

    fn fullReset(s: *Screen) void {
        s.useAlternate(false, false);
        s.softReset();
        s.cursor = .{};
        for (s.primary.lines) |*l| {
            @memset(l.cells, .{});
            l.wrapped = false;
        }
        s.resetTabs() catch {};
        s.title.clearRetainingCapacity();
        s.title_changed = true;
    }

    fn moveTo(s: *Screen, x: u16, y: u16) void {
        s.cursor.x = @min(x, s.cols - 1);
        var lo: u16 = 0;
        var hi: u16 = s.rows - 1;
        if (s.cursor.origin) {
            lo = s.top;
            hi = s.bottom;
        }
        s.cursor.y = std.math.clamp(y, lo, hi);
        s.cursor.pending_wrap = false;
    }

    fn moveUp(s: *Screen, n: u16) void {
        const lo: u16 = if (s.cursor.y >= s.top) s.top else 0;
        s.cursor.y = @max(s.cursor.y -| n, lo);
        s.cursor.pending_wrap = false;
    }

    fn moveDown(s: *Screen, n: u16) void {
        const hi: u16 = if (s.cursor.y <= s.bottom) s.bottom else s.rows - 1;
        s.cursor.y = @min(s.cursor.y +| n, hi);
        s.cursor.pending_wrap = false;
    }

    fn tabForward(s: *Screen, n: u16) void {
        var k: u16 = 0;
        while (k < n and s.cursor.x < s.cols - 1) : (k += 1) {
            s.cursor.x += 1;
            while (s.cursor.x < s.cols - 1 and !s.tabs.isSet(s.cursor.x)) s.cursor.x += 1;
        }
        s.cursor.pending_wrap = false;
    }

    /// LF: down one row, with a scroll at the bottom of the region.
    fn index(s: *Screen) void {
        if (s.cursor.y == s.bottom) {
            s.scrollUp(s.top, s.bottom, 1);
        } else if (s.cursor.y < s.rows - 1) s.cursor.y += 1;
        s.cursor.pending_wrap = false;
    }

    fn reverseIndex(s: *Screen) void {
        if (s.cursor.y == s.top) {
            s.scrollDown(s.top, s.bottom, 1);
        } else if (s.cursor.y > 0) s.cursor.y -= 1;
        s.cursor.pending_wrap = false;
    }

    /// Moves the lines of `top..bottom` up by `n`. On the full primary
    /// screen the lines at the top go to the scrollback.
    fn scrollUp(s: *Screen, top: u16, bottom: u16, n_in: u16) void {
        const lines = s.grid().lines;
        const n = @min(n_in, bottom - top + 1);
        const to_sb = !s.alt_active and top == 0 and s.scrollback_max > 0;
        for (0..n) |_| {
            var gone = lines[top];
            std.mem.copyForwards(Line, lines[top..bottom], lines[top + 1 .. bottom + 1]);
            if (to_sb) {
                if (s.pushScrollback(gone)) |fresh| {
                    gone = .{ .cells = fresh };
                } else |_| {}
            }
            @memset(gone.cells, s.blank());
            gone.wrapped = false;
            lines[bottom] = gone;
        }
    }

    /// Adds a line to the scrollback. Gives the cells of a line for the
    /// screen: a new array, or the oldest line of a full ring.
    fn pushScrollback(s: *Screen, l: Line) ![]Cell {
        if (s.scrollback.items.len < s.scrollback_max) {
            const fresh = try s.newLine();
            errdefer s.gpa.free(fresh);
            try s.scrollback.append(s.gpa, l);
            // The ring is not full, so the head stays at 0.
            return fresh;
        }
        const old = s.scrollback.items[s.sb_head];
        s.scrollback.items[s.sb_head] = l;
        s.sb_head = (s.sb_head + 1) % s.scrollback.items.len;
        if (old.cells.len == s.cols) return old.cells;
        s.gpa.free(old.cells);
        return s.newLine();
    }

    fn scrollDown(s: *Screen, top: u16, bottom: u16, n_in: u16) void {
        const lines = s.grid().lines;
        const n = @min(n_in, bottom - top + 1);
        for (0..n) |_| {
            const gone = lines[bottom];
            std.mem.copyBackwards(Line, lines[top + 1 .. bottom + 1], lines[top..bottom]);
            @memset(gone.cells, s.blank());
            lines[top] = .{ .cells = gone.cells };
        }
    }

    fn insertLines(s: *Screen, n: u16) void {
        if (s.cursor.y < s.top or s.cursor.y > s.bottom) return;
        s.scrollDown(s.cursor.y, s.bottom, n);
        s.cursor.x = 0;
        s.cursor.pending_wrap = false;
    }

    fn deleteLines(s: *Screen, n: u16) void {
        if (s.cursor.y < s.top or s.cursor.y > s.bottom) return;
        // A delete in the region never goes to the scrollback.
        const keep = s.scrollback_max;
        s.scrollback_max = 0;
        s.scrollUp(s.cursor.y, s.bottom, n);
        s.scrollback_max = keep;
        s.cursor.x = 0;
        s.cursor.pending_wrap = false;
    }

    fn insertCells(s: *Screen, n_in: u16) void {
        const cells = s.line(s.cursor.y).cells;
        const x = s.cursor.x;
        const n = @min(n_in, s.cols - x);
        std.mem.copyBackwards(Cell, cells[x + n ..], cells[x .. s.cols - n]);
        @memset(cells[x .. x + n], s.blank());
        s.cursor.pending_wrap = false;
    }

    fn deleteCells(s: *Screen, n_in: u16) void {
        const cells = s.line(s.cursor.y).cells;
        const x = s.cursor.x;
        const n = @min(n_in, s.cols - x);
        std.mem.copyForwards(Cell, cells[x .. s.cols - n], cells[x + n ..]);
        @memset(cells[s.cols - n ..], s.blank());
        s.cursor.pending_wrap = false;
    }

    fn eraseLine(s: *Screen, mode: u16) void {
        const ln = s.line(s.cursor.y);
        const x = s.cursor.x;
        switch (mode) {
            0 => {
                @memset(ln.cells[x..], s.blank());
                ln.wrapped = false;
            },
            1 => @memset(ln.cells[0 .. x + 1], s.blank()),
            2 => {
                @memset(ln.cells, s.blank());
                ln.wrapped = false;
            },
            else => {},
        }
        s.cursor.pending_wrap = false;
    }

    fn eraseDisplay(s: *Screen, mode: u16) void {
        const lines = s.grid().lines;
        switch (mode) {
            0 => {
                s.eraseLine(0);
                for (lines[s.cursor.y + 1 ..]) |*l| @memset(l.cells, s.blank());
            },
            1 => {
                s.eraseLine(1);
                for (lines[0..s.cursor.y]) |*l| @memset(l.cells, s.blank());
            },
            2 => for (lines) |*l| {
                @memset(l.cells, s.blank());
                l.wrapped = false;
            },
            3 => {
                for (s.scrollback.items) |l| s.gpa.free(l.cells);
                s.scrollback.clearRetainingCapacity();
                s.sb_head = 0;
            },
            else => {},
        }
    }

    /// Changes the size. See the comment at the top of the file.
    pub fn resize(s: *Screen, cols_in: u16, rows_in: u16) !void {
        const cols = @max(cols_in, 1);
        const rows = @max(rows_in, 1);
        if (cols == s.cols and rows == s.rows) return;
        for ([_]*Grid{ &s.primary, &s.alternate }, 0..) |g, gi| {
            const is_active = (gi == 1) == s.alt_active;
            // The rows above the cursor that go when the screen gets shorter.
            var drop_top: usize = 0;
            if (rows < s.rows and is_active and s.cursor.y >= rows) drop_top = s.cursor.y - rows + 1;
            const lines = try s.gpa.alloc(Line, rows);
            var k: usize = 0;
            for (g.lines, 0..) |l, i| {
                if (i < drop_top) {
                    if (gi == 0 and s.scrollback_max > 0) {
                        s.pushOld(l);
                    } else s.gpa.free(l.cells);
                    continue;
                }
                if (k >= rows) {
                    s.gpa.free(l.cells);
                    continue;
                }
                lines[k] = .{ .cells = try resizeCells(s.gpa, l.cells, cols), .wrapped = l.wrapped };
                k += 1;
            }
            while (k < rows) : (k += 1) {
                const cells = try s.gpa.alloc(Cell, cols);
                @memset(cells, .{});
                lines[k] = .{ .cells = cells };
            }
            s.gpa.free(g.lines);
            g.lines = lines;
            if (is_active and drop_top > 0) s.cursor.y -= @intCast(drop_top);
        }
        s.cols = cols;
        s.rows = rows;
        s.top = 0;
        s.bottom = rows - 1;
        s.cursor.x = @min(s.cursor.x, cols - 1);
        s.cursor.y = @min(s.cursor.y, rows - 1);
        s.cursor.pending_wrap = false;
        s.saved.x = @min(s.saved.x, cols - 1);
        s.saved.y = @min(s.saved.y, rows - 1);
        try s.resetTabs();
        s.generation +%= 1;
    }

    /// Adds a line of an old width to the scrollback during a resize.
    fn pushOld(s: *Screen, l: Line) void {
        if (s.scrollback.items.len < s.scrollback_max) {
            s.scrollback.append(s.gpa, l) catch s.gpa.free(l.cells);
            return;
        }
        s.gpa.free(s.scrollback.items[s.sb_head].cells);
        s.scrollback.items[s.sb_head] = l;
        s.sb_head = (s.sb_head + 1) % s.scrollback.items.len;
    }

    /// The text of view line `i`, with no trailing blanks.
    pub fn lineText(s: *const Screen, a: std.mem.Allocator, i: usize, from: usize, to: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        const cells = s.lineAt(i).cells;
        var end = @min(to, cells.len);
        while (end > from and cells[end - 1].cp == ' ' and cells[end - 1].width == 1) end -= 1;
        var x = from;
        while (x < end) : (x += 1) {
            if (cells[x].width == 0) continue;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cells[x].cp, &buf) catch 0;
            try out.appendSlice(a, buf[0..n]);
        }
        return out.toOwnedSlice(a);
    }
};

fn resizeCells(gpa: std.mem.Allocator, old: []Cell, cols: u16) ![]Cell {
    if (old.len == cols) return old;
    const cells = try gpa.alloc(Cell, cols);
    const n = @min(old.len, cols);
    @memcpy(cells[0..n], old[0..n]);
    @memset(cells[n..], .{});
    // A wide character cut in half at the edge becomes a blank.
    if (n > 0 and cells[n - 1].width == 2) cells[n - 1] = .{};
    gpa.free(old);
    return cells;
}

/// The DEC special graphics set for the bytes 0x5f to 0x7e: the line
/// drawing characters of the VT100.
const graphics_map = [32]u21{
    ' ',    0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240a, 0x00b0,
    0x00b1, 0x2424, 0x240b, 0x2518, 0x2510, 0x250c, 0x2514, 0x253c,
    0x23ba, 0x23bb, 0x2500, 0x23bc, 0x23bd, 0x251c, 0x2524, 0x2534,
    0x252c, 0x2502, 0x2264, 0x2265, 0x03c0, 0x2260, 0x00a3, 0x00b7,
};

// Tests.

fn testScreen(cols: u16, rows: u16) !Screen {
    return Screen.init(std.testing.allocator, cols, rows);
}

fn expectRow(s: *const Screen, y: usize, want: []const u8) !void {
    const got = try s.lineText(std.testing.allocator, s.scrollbackLen() + y, 0, s.cols);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "text, line feeds, and the autowrap" {
    var s = try testScreen(5, 3);
    defer s.deinit();
    s.write("ab\r\ncdefgh");
    try expectRow(&s, 0, "ab");
    try expectRow(&s, 1, "cdefg");
    try expectRow(&s, 2, "h");
    try std.testing.expect(s.lineAt(1).wrapped);
    // The last column keeps the cursor until the next character.
    s.write("\x1b[2;1Hvwxyz");
    try std.testing.expectEqual(@as(u16, 4), s.cursor.x);
    try std.testing.expect(s.cursor.pending_wrap);
}

test "the scroll sends lines to the scrollback" {
    var s = try testScreen(4, 2);
    defer s.deinit();
    s.write("1\r\n2\r\n3\r\n4");
    try std.testing.expectEqual(@as(usize, 2), s.scrollbackLen());
    try expectRow(&s, 0, "3");
    try expectRow(&s, 1, "4");
    const first = try s.lineText(std.testing.allocator, 0, 0, 4);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("1", first);
    // The ring keeps at most scrollback_max lines.
    s.scrollback_max = 2;
    s.write("\r\n5\r\n6");
    try std.testing.expectEqual(@as(usize, 2), s.scrollbackLen());
    const oldest = try s.lineText(std.testing.allocator, 0, 0, 4);
    defer std.testing.allocator.free(oldest);
    try std.testing.expectEqualStrings("3", oldest);
}

test "cursor moves, erase, insert, and delete" {
    var s = try testScreen(6, 3);
    defer s.deinit();
    s.write("abcdef\x1b[1;3H\x1b[K");
    try expectRow(&s, 0, "ab");
    s.write("\x1b[2;1Hxyz\x1b[2;2H\x1b[2@");
    try expectRow(&s, 1, "x  yz");
    s.write("\x1b[2;2H\x1b[2P");
    try expectRow(&s, 1, "xyz");
    s.write("\x1b[2J");
    try expectRow(&s, 1, "");
    s.write("\x1b[3;1Hq\x1b[1;1H\x1b[L");
    try expectRow(&s, 2, "");
    s.write("\x1b[3;1Hz\x1b[1;1H\x1b[M");
    try expectRow(&s, 1, "z");
}

test "the scroll region and reverse index" {
    var s = try testScreen(3, 4);
    defer s.deinit();
    s.write("a\r\nb\r\nc\r\nd\x1b[2;3r\x1b[3;1H\n");
    try expectRow(&s, 0, "a");
    try expectRow(&s, 1, "c");
    try expectRow(&s, 2, "");
    try expectRow(&s, 3, "d");
    try std.testing.expectEqual(@as(usize, 0), s.scrollbackLen());
    s.write("\x1b[2;1H\x1bM");
    try expectRow(&s, 1, "");
    try expectRow(&s, 2, "c");
}

test "SGR colors and attributes" {
    var s = try testScreen(8, 1);
    defer s.deinit();
    s.write("\x1b[1;31mA\x1b[38;5;200mB\x1b[38;2;1;2;3mC\x1b[48:2::4:5:6mD\x1b[0mE\x1b[7;94mF");
    const c = s.lineAt(0).cells;
    try std.testing.expect(c[0].attrs.bold);
    try std.testing.expectEqual(Color{ .index = 1 }, c[0].fg);
    try std.testing.expectEqual(Color{ .index = 200 }, c[1].fg);
    try std.testing.expectEqual(Color{ .rgb = .{ 1, 2, 3 } }, c[2].fg);
    try std.testing.expectEqual(Color{ .rgb = .{ 4, 5, 6 } }, c[3].bg);
    try std.testing.expectEqual(Color.default, c[4].fg);
    try std.testing.expect(!c[4].attrs.bold);
    try std.testing.expect(c[5].attrs.inverse);
    try std.testing.expectEqual(Color{ .index = 12 }, c[5].fg);
}

test "wide characters take two cells" {
    var s = try testScreen(5, 2);
    defer s.deinit();
    s.write("a\u{4e2d}b");
    const c = s.lineAt(0).cells;
    try std.testing.expectEqual(@as(u2, 2), c[1].width);
    try std.testing.expectEqual(@as(u2, 0), c[2].width);
    try expectRow(&s, 0, "a\u{4e2d}b");
    // A wide character at the last column wraps first.
    s.write("\x1b[1;5H\u{4e2d}");
    try expectRow(&s, 1, "\u{4e2d}");
}

test "the alternate screen keeps the primary screen" {
    var s = try testScreen(4, 2);
    defer s.deinit();
    s.write("main\x1b[?1049h\x1b[Halt");
    try expectRow(&s, 0, "alt");
    try std.testing.expectEqual(@as(usize, 0), s.scrollbackLen());
    s.write("\x1b[?1049l");
    try expectRow(&s, 0, "main");
    try std.testing.expectEqual(@as(u16, 3), s.cursor.x);
}

test "replies to the status queries" {
    var s = try testScreen(10, 5);
    defer s.deinit();
    s.write("\x1b[3;4H\x1b[6n\x1b[c\x1b]11;?\x07");
    try std.testing.expectEqualStrings("\x1b[3;4R\x1b[?62;22c\x1b]11;rgb:ffff/ffff/ffff\x1b\\", s.reply.items);
}

test "modes, the title, and the line drawing set" {
    var s = try testScreen(10, 2);
    defer s.deinit();
    s.write("\x1b[?1h\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?25l\x1b]0;hello\x07\x1b(0qx\x1b(Bq");
    try std.testing.expect(s.modes.cursor_keys_app);
    try std.testing.expect(s.modes.bracketed_paste);
    try std.testing.expectEqual(MouseMode.normal, s.modes.mouse);
    try std.testing.expect(s.modes.mouse_sgr);
    try std.testing.expect(!s.modes.cursor_visible);
    try std.testing.expectEqualStrings("hello", s.title.items);
    try expectRow(&s, 0, "\u{2500}\u{2502}q");
}

test "resize keeps the cursor line" {
    var s = try testScreen(6, 4);
    defer s.deinit();
    s.write("1\r\n2\r\n3\r\n4");
    try s.resize(3, 2);
    try expectRow(&s, 0, "3");
    try expectRow(&s, 1, "4");
    try std.testing.expectEqual(@as(usize, 2), s.scrollbackLen());
    try std.testing.expectEqual(@as(u16, 1), s.cursor.y);
    try s.resize(8, 5);
    try expectRow(&s, 1, "4");
    s.write("\x1b[5;8HZ");
    try expectRow(&s, 4, "       Z");
}

test "tabs" {
    var s = try testScreen(20, 1);
    defer s.deinit();
    s.write("a\tb\x1b[2Zc");
    try std.testing.expectEqual(@as(u21, 'c'), s.lineAt(0).cells[0].cp);
    try std.testing.expectEqual(@as(u21, 'b'), s.lineAt(0).cells[8].cp);
}
