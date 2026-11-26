//! The terminal core of `ztk::terminal`: a `Screen` on `ztcl.vt.Term`,
//! the binding of ztcl to libghostty-vt.
//!
//! `Screen` has the fields and the methods that `widget.zig` reads. The
//! fields `cols`, `rows`, `cursor`, `modes`, `alt_active`, and `title`
//! are copies of the state of the terminal, and `sync` makes them again
//! after each `write` and `resize`. The replies of the terminal go to
//! `reply`, and the widget sends them to the program.
//!
//! `lineAt` reads one line of the view into a ring of four line
//! buffers, so a caller can hold up to four lines at one time. Line 0
//! of the view is the oldest line of the scrollback, and the rows of
//! the active area come after the scrollback.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const vt = @import("ztcl").vt;

pub const Color = vt.Color;
pub const Attrs = vt.Attrs;
pub const Cell = vt.Cell;
pub const MouseMode = vt.MouseMode;

pub const Line = struct {
    cells: []Cell,
    /// True when the text goes on in the next line (an autowrap).
    wrapped: bool = false,
};

pub const Modes = struct {
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

const ring = 4;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    term: *vt.Term,
    cols: u16,
    rows: u16,
    cursor: struct { x: u16 = 0, y: u16 = 0 } = .{},
    modes: Modes = .{},
    alt_active: bool = false,
    /// The bytes that the terminal sends back to the program.
    reply: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    scrollback_max: usize = 10000,
    applied_max: usize = 10000,
    lines: [ring]Line = @splat(.{ .cells = &.{} }),
    next: usize = 0,

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const t = try vt.Term.create(gpa, cols, rows, 10000);
        var s: Screen = .{ .gpa = gpa, .term = t, .cols = t.colCount(), .rows = t.rowCount() };
        s.sync();
        return s;
    }

    pub fn deinit(s: *Screen) void {
        for (s.lines) |l| s.gpa.free(l.cells);
        s.reply.deinit(s.gpa);
        s.title.deinit(s.gpa);
        s.term.destroy();
    }

    fn sync(s: *Screen) void {
        const t = s.term;
        if (s.scrollback_max != s.applied_max) {
            t.t.setScrollbackMaxLines(s.scrollback_max);
            s.applied_max = s.scrollback_max;
        }
        s.cols = t.colCount();
        s.rows = t.rowCount();
        const c = t.cursor();
        s.cursor = .{ .x = c.x, .y = c.y };
        const m = t.modes();
        s.modes = .{
            .cursor_keys_app = m.cursor_keys_app,
            .keypad_app = m.keypad_app,
            .cursor_visible = m.cursor_visible,
            .bracketed_paste = m.bracketed_paste,
            .focus_events = m.focus_events,
            .mouse = m.mouse,
            .mouse_sgr = m.mouse_sgr,
            .cursor_style = t.cursorStyle(),
        };
        s.alt_active = m.alt_screen;
        if (t.reply.items.len > 0) {
            s.reply.appendSlice(s.gpa, t.reply.items) catch {};
            t.reply.clearRetainingCapacity();
        }
        const title = t.title();
        if (!std.mem.eql(u8, title, s.title.items)) {
            s.title.clearRetainingCapacity();
            s.title.appendSlice(s.gpa, title) catch {};
        }
    }

    pub fn write(s: *Screen, bytes: []const u8) void {
        if (s.scrollback_max != s.applied_max) s.sync();
        s.term.write(bytes);
        s.sync();
    }

    pub fn resize(s: *Screen, cols: u16, rows: u16) !void {
        try s.term.resize(cols, rows);
        s.sync();
    }

    /// The count of scrollback lines that the view shows. The alternate
    /// screen has none.
    pub fn scrollbackLen(s: *const Screen) usize {
        return s.term.scrollbackLen();
    }

    /// Line `i` of the view: the scrollback from the oldest line, then
    /// the rows of the screen.
    pub fn lineAt(s: *const Screen, i: usize) *const Line {
        const self: *Screen = @constCast(s);
        const k = self.next;
        self.next = (k + 1) % ring;
        const l = &self.lines[k];
        if (l.cells.len != s.cols) {
            self.gpa.free(l.cells);
            l.cells = self.gpa.alloc(Cell, s.cols) catch &.{};
        }
        const y = @min(i, s.scrollbackLen() + s.rows - 1);
        l.wrapped = s.term.row(y, l.cells);
        for (l.cells) |*c| {
            if (c.cp == 0 and c.width != 0) c.cp = ' ';
        }
        return l;
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
