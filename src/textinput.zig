//! The state of the input method, for the backend and for the widgets.
//! After each flush, `sync` gives the backend the text widget that has
//! the focus (an entry, a spinbox, a combobox, or a text) and its rectangle in
//! logical pixels of its window, or turns the input method off. The
//! backend hears only of a change. The rectangle is the box of the
//! widget: the caret position is known only to the paint code of the
//! entry. `preedit` keeps the composition text of the last `preedit`
//! event and the widget that had the focus then, for a widget that draws
//! it. A `commit` event becomes key events in `dispatch.zig`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("base/geom.zig");
const App = @import("app.zig").App;
const Widget = @import("widget.zig").Widget;

pub const State = struct {
    /// The window, the state, and the rectangle that the backend has.
    win: ?*const anyopaque = null,
    on: bool = false,
    rect: geom.Rect = .{},
    /// The composition text and its caret, in bytes.
    preedit: std.ArrayListUnmanaged(u8) = .empty,
    preedit_caret: u32 = 0,
    preedit_widget: ?*Widget = null,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.preedit.deinit(gpa);
    }

    /// A widget that is deleted must not stay in the state.
    pub fn forget(s: *State, w: *const Widget) void {
        if (s.preedit_widget == w) s.preedit_widget = null;
    }
};

/// True for a widget for typed text: an entry, a spinbox, a combobox, or a text.
pub fn isTextWidget(w: *const Widget) bool {
    const r = w.class.role;
    return std.mem.eql(u8, r, "text field") or std.mem.eql(u8, r, "spin button") or std.mem.eql(u8, r, "combo box") or std.mem.eql(u8, r, "text area");
}

/// The box of a widget in logical pixels of its toplevel.
fn boxInWindow(w: *const Widget) geom.Rect {
    var r: geom.Rect = .{ .x = 0, .y = 0, .w = w.geom.w, .h = w.geom.h };
    var cur: ?*const Widget = w;
    while (cur) |c| : (cur = c.parent) {
        if (c.class.is_toplevel) break;
        r.x += c.geom.x;
        r.y += c.geom.y;
    }
    return r;
}

/// Gives the backend the text widget with the focus, when it changed.
pub fn sync(app: *App) void {
    const s = &app.text_input;
    const f: ?*Widget = if (app.focus.current) |c| (if (c.alive() and isTextWidget(c)) c else null) else null;
    const win = if (f) |w| app.winOf(w.toplevel()) else null;
    if (f == null) {
        if (!s.on) return;
        s.on = false;
        if (s.win) |old| app.platform.textInput(@ptrCast(@alignCast(@constCast(old))), false, s.rect);
        return;
    }
    const target = win orelse return;
    const rect = boxInWindow(f.?);
    if (s.on and s.win == @as(*const anyopaque, target) and std.meta.eql(s.rect, rect)) return;
    // The input method of the window that had it before goes off first.
    if (s.on) if (s.win) |old| if (old != @as(*const anyopaque, target)) app.platform.textInput(@ptrCast(@alignCast(@constCast(old))), false, s.rect);
    s.* = .{ .win = target, .on = true, .rect = rect, .preedit = s.preedit, .preedit_caret = s.preedit_caret, .preedit_widget = s.preedit_widget };
    app.platform.textInput(target, true, rect);
}

/// Keeps the composition text of a `preedit` event for the widget with the focus.
pub fn setPreedit(app: *App, text: []const u8, caret: u32) void {
    const s = &app.text_input;
    s.preedit.clearRetainingCapacity();
    s.preedit.appendSlice(app.gpa, text) catch {};
    s.preedit_caret = @min(caret, @as(u32, @intCast(s.preedit.items.len)));
    s.preedit_widget = if (text.len == 0) null else app.focus.current;
    if (app.focus.current) |w| if (w.alive()) w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}
