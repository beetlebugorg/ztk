//! `ttk::notebook`: a row of tabs over a client area, and one page for
//! each tab. The notebook is the geometry manager of its pages. Only the
//! page of the selected tab is mapped. It fills the client area inside the
//! `-padding` of the notebook and the `-padding` of its tab, and `-sticky`
//! places it there when it is smaller.
//!
//! A tab is `normal`, `disabled`, or `hidden`. A hidden tab has no place
//! in the row. The first tab that is added is selected. When the selected
//! tab is hidden or forgotten, the next tab that is not hidden is
//! selected, else the one before it. Each change of the selected tab
//! queues `<<NotebookTabChanged>>` as an idle callback, so it arrives
//! after the script that made the change, as in `wish`.
//!
//! The modern theme draws the tabs as text in the part `::tab`, the
//! selected tab in `::tab-selected`, the tab under the pointer in
//! `::tab-hover`, a disabled tab in `::tab-disabled`, a line under the
//! selected tab in `::indicator`, and the client area in `::client`. A tab
//! change slides the indicator from the old tab to the new one in 200 ms,
//! and the new page fades in over 150 ms: the notebook paints the color of
//! the client area over its page, from opaque to clear.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../base/num.zig");
const geom = @import("../base/geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const easing = @import("../base/easing.zig");
const layout = @import("../layout.zig");
const grid = @import("../grid.zig");
const focus = @import("../focus.zig");
const style_mod = @import("../style.zig");
const ttk_style = @import("style.zig");
const ttk_widgets = @import("widgets.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const s = ttk_widgets.s;

/// The options of `ttk::notebook`, in the order of `wish`.
const specs = [_]Spec{
    s("-width", "width", "Width", .pixels, "0"),
    s("-height", "height", "Height", .pixels, "0"),
    s("-padding", "padding", "Padding", .string, ""),
    ttk_widgets.takefocus,
    s("-cursor", "cursor", "Cursor", .string, ""),
    s("-style", "style", "Style", .string, ""),
    .{ .name = "-class", .type = .string, .allow_empty = true, .create_only = true },
};

const base: widget.Class = .{
    .command = "",
    .tk_class = "",
    .role = "tablist",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .configured = configured,
    .measure = measureSelf,
    .paint = paintNotebook,
    .overlay = paintOver,
    .subcommand = subcommand,
};

const subs = [_][]const u8{ "add", "configure", "cget", "forget", "hide", "identify", "index", "insert", "instate", "select", "state", "tab", "tabs" };
pub const class = ttk_widgets.derive(base, "ttk::notebook", "TNotebook", &specs, &subs, "*");

const TabState = enum { normal, disabled, hidden };

/// The tab options in the order of `tab`.
const tab_opts = [_][]const u8{ "-padding", "-sticky", "-state", "-text", "-image", "-compound", "-underline" };

const Tab = struct {
    w: *Widget,
    /// The texts of `-padding`, `-text`, `-image`, and `-compound`. Owned.
    padding: []u8 = &.{},
    text: []u8 = &.{},
    image: []u8 = &.{},
    compound: []u8 = &.{},
    pad: geom.Insets = .{},
    /// The sides in the order n, e, s, w: bit 0 is n.
    sticky: u4 = 0b1111,
    state: TabState = .normal,
    underline: i64 = -1,
    /// The place of the tab in the row, from the last paint or layout.
    x: i32 = 0,
    w_px: i32 = 0,
};

const Data = struct {
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    current: ?usize = null,
    /// The tab under the pointer.
    hot: ?usize = null,
    /// The slide of the indicator: its shown place at the start, and the time.
    ind_from: [2]f32 = .{ 0, 0 },
    ind_start: i64 = 0,
    sliding: bool = false,
    /// True after the first paint of the indicator.
    ind_valid: bool = false,
    /// The start of the fade of the page.
    fade_start: i64 = 0,
    fading: bool = false,
    /// The events that wait for the idle callback.
    pending: u32 = 0,
    tab_part: paint.PartAnim = .{},
};

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

fn freeTab(app: *App, t: *Tab) void {
    app.gpa.free(t.padding);
    app.gpa.free(t.text);
    app.gpa.free(t.image);
    app.gpa.free(t.compound);
    app.gpa.destroy(t);
}

fn deinit(w: *Widget) void {
    const d = data(w);
    for (d.tabs.items) |t| freeTab(w.app, t);
    d.tabs.deinit(w.app.gpa);
    w.app.gpa.destroy(d);
    w.data = null;
}

fn configured(w: *Widget, _: []const usize) ztcl.Error!void {
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

// ---- Sizes ----

/// Parses a padding list of 1 to 4 screen distances: left, top, right, bottom.
fn parsePadding(it: *ztcl.Interp, app: *App, text: []const u8) ztcl.Error!geom.Insets {
    var v: [4]i32 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    while (words.next()) |word| {
        if (n == 4) return it.fail("Wrong #elements in padding spec", .{});
        v[n] = options.parsePixels(word, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{word});
        n += 1;
    }
    return switch (n) {
        0 => .{},
        1 => .{ .left = v[0], .top = v[0], .right = v[0], .bottom = v[0] },
        2 => .{ .left = v[0], .top = v[1], .right = v[0], .bottom = v[1] },
        3 => .{ .left = v[0], .top = v[1], .right = v[2], .bottom = v[1] },
        else => .{ .left = v[0], .top = v[1], .right = v[2], .bottom = v[3] },
    };
}

fn ownPadding(w: *Widget) geom.Insets {
    const t = options.get(w, "-padding").text;
    if (t.len == 0) return .{};
    return parsePadding(w.app.it, w.app, t) catch .{};
}

fn tabStyle(w: *Widget) style_mod.Style {
    return w.app.styles.compute(w, "tab", &w.style, w.app.env);
}

/// The height of the row of tabs.
fn rowHeight(w: *Widget) i32 {
    w.app.ensureStyle(w);
    const st = tabStyle(w);
    const ins = paint.insets(&st);
    return paint.lineHeight(w.app, st.font) + ins.vertical();
}

/// Sets the place of each tab in the row.
fn placeTabs(w: *Widget) i32 {
    const d = data(w);
    w.app.ensureStyle(w);
    const st = tabStyle(w);
    const ins = paint.insets(&st);
    var x: i32 = 0;
    for (d.tabs.items) |t| {
        if (t.state == .hidden) {
            t.w_px = 0;
            t.x = x;
            continue;
        }
        t.x = x;
        t.w_px = paint.textSize(w.app, t.text, st.font).w + ins.horizontal();
        x += t.w_px;
    }
    return x;
}

/// The client area: under the row of tabs, inside a border of 1 logical pixel.
fn clientRect(w: *Widget) geom.Rect {
    const top = rowHeight(w);
    return .{ .x = 1, .y = top + 1, .w = w.geom.w - 2, .h = w.geom.h - top - 2 };
}

fn reqSize(w: *Widget) geom.Size {
    const d = data(w);
    const pad = ownPadding(w);
    var cw: i32 = 0;
    var ch: i32 = 0;
    for (d.tabs.items) |t| {
        cw = @max(cw, t.w.req.w + t.pad.horizontal());
        ch = @max(ch, t.w.req.h + t.pad.vertical());
    }
    const ow = options.get(w, "-width").value;
    const oh = options.get(w, "-height").value;
    if (ow == .pixels and ow.pixels > 0) cw = ow.pixels;
    if (oh == .pixels and oh.pixels > 0) ch = oh.pixels;
    const row = placeTabs(w);
    return .{ .w = @max(cw + pad.horizontal(), row) + 2, .h = ch + pad.vertical() + rowHeight(w) + 2 };
}

fn measureSelf(w: *Widget) geom.Size {
    return reqSize(w);
}

fn measure(w: *Widget) void {
    layout.setReq(w, reqSize(w));
}

fn arrange(w: *Widget) void {
    const d = data(w);
    _ = placeTabs(w);
    const c = clientRect(w);
    const pad = ownPadding(w);
    for (d.tabs.items, 0..) |t, i| {
        const sel = d.current != null and d.current.? == i;
        if (!sel) {
            layout.setMapped(t.w, false);
            continue;
        }
        const cell: geom.Rect = .{
            .x = c.x + pad.left + t.pad.left,
            .y = c.y + pad.top + t.pad.top,
            .w = c.w - pad.horizontal() - t.pad.horizontal(),
            .h = c.h - pad.vertical() - t.pad.vertical(),
        };
        if (cell.w <= 0 or cell.h <= 0) {
            layout.setMapped(t.w, false);
            continue;
        }
        var r = cell;
        const n = t.sticky & 1 != 0;
        const e = t.sticky & 2 != 0;
        const so = t.sticky & 4 != 0;
        const we = t.sticky & 8 != 0;
        if (!(e and we)) {
            r.w = @min(t.w.req.w, cell.w);
            r.x = if (we) cell.x else if (e) cell.x + cell.w - r.w else cell.x + @divTrunc(cell.w - r.w, 2);
        }
        if (!(n and so)) {
            r.h = @min(t.w.req.h, cell.h);
            r.y = if (n) cell.y else if (so) cell.y + cell.h - r.h else cell.y + @divTrunc(cell.h - r.h, 2);
        }
        _ = layout.setGeomIn(w, t.w, r, w.mapped);
    }
}

fn indexOf(d: *const Data, c: *const Widget) ?usize {
    for (d.tabs.items, 0..) |t, i| if (t.w == c) return i;
    return null;
}

fn forget(c: *Widget) void {
    const w: *Widget = @ptrCast(@alignCast(c.manager_data orelse return));
    c.manager_data = null;
    if (w.data == null) return;
    const i = indexOf(data(w), c) orelse return;
    removeTab(w, i);
}

fn release(w: *Widget) void {
    if (w.data != null) {
        const d = data(w);
        while (d.tabs.items.len > 0) removeTab(w, d.tabs.items.len - 1);
    }
    w.container_manager = null;
    w.container_data = null;
}

fn hasContent(w: *const Widget) bool {
    if (w.container_manager != &manager) return false;
    return data(w).tabs.items.len > 0;
}

fn propagates(_: *const Widget) bool {
    return true;
}

pub const manager: layout.Manager = .{ .name = "notebook", .measure = measure, .arrange = arrange, .forget = forget, .release = release, .has_content = hasContent, .propagates = propagates, .container_of = containerWidget };

/// The container of a pane: a pane can be a descendant of the parent of
/// the container, not only a child.
fn containerWidget(c: *const Widget) ?*Widget {
    return @ptrCast(@alignCast(c.manager_data orelse return null));
}

// ---- The selection ----

/// Queues `<<NotebookTabChanged>>` for the idle callbacks.
fn queueChanged(w: *Widget) void {
    const script = std.fmt.allocPrint(w.app.gpa, "if {{[winfo exists {{{s}}}]}} {{event generate {{{s}}} <<NotebookTabChanged>>}}", .{ w.path, w.path }) catch return;
    defer w.app.gpa.free(script);
    _ = w.app.loop.addIdle(script) catch {};
}

/// The shown place of the indicator: x and width.
fn indicatorAt(w: *Widget) [2]f32 {
    const d = data(w);
    const i = d.current orelse return .{ 0, 0 };
    const t = d.tabs.items[i];
    const to: [2]f32 = .{ @floatFromInt(t.x), @floatFromInt(t.w_px) };
    if (!d.sliding) return to;
    const app = w.app;
    const since = app.platform.nowUs() - d.ind_start;
    if (since >= slide_us or anim.reduced(app) or app.part_end) {
        if (since >= slide_us) d.sliding = false;
        return to;
    }
    app.anim_more = true;
    const lin = @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(slide_us));
    app.notePartMove(d.ind_start, .{ .duration_ms = @intCast(@divTrunc(slide_us, 1000)), .timing = easing.Timing.ease_out }, lin);
    const p = easing.Timing.ease_out.eval(lin);
    return .{ d.ind_from[0] + (to[0] - d.ind_from[0]) * p, d.ind_from[1] + (to[1] - d.ind_from[1]) * p };
}

const slide_us: i64 = 200_000;
const fade_us: i64 = 150_000;

/// Selects tab `i`, or no tab. A change starts the slide and the fade and queues the event.
fn select(w: *Widget, i: ?usize) void {
    const d = data(w);
    if (std.meta.eql(d.current, i)) return;
    const app = w.app;
    const now = app.platform.nowUs();
    if (d.current != null and i != null and d.ind_valid and !anim.reduced(app)) {
        d.ind_from = indicatorAt(w);
        d.ind_start = now;
        d.sliding = true;
        d.fade_start = now;
        d.fading = true;
    } else {
        d.sliding = false;
        d.fading = false;
    }
    if (d.current) |old| if (old < d.tabs.items.len) layout.setMapped(d.tabs.items[old].w, false);
    d.current = i;
    if (i) |k| d.tabs.items[k].state = if (d.tabs.items[k].state == .hidden) .normal else d.tabs.items[k].state;
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    queueChanged(w);
}

/// The nearest tab to `i` that is not hidden: `i` itself, then after, then before.
fn nearest(d: *const Data, i: usize) ?usize {
    var k = i;
    while (k < d.tabs.items.len) : (k += 1) if (d.tabs.items[k].state != .hidden) return k;
    k = @min(i, d.tabs.items.len);
    while (k > 0) : (k -= 1) if (d.tabs.items[k - 1].state != .hidden) return k - 1;
    return null;
}

fn removeTab(w: *Widget, i: usize) void {
    const d = data(w);
    const t = d.tabs.orderedRemove(i);
    const c = t.w;
    if (c.manager == &manager) {
        c.manager = null;
        c.manager_data = null;
    }
    if (c.alive()) layout.setMapped(c, false);
    freeTab(w.app, t);
    d.hot = null;
    if (d.current) |cur| {
        if (cur == i) {
            d.current = null;
            d.sliding = false;
            const next = nearest(d, i);
            if (next) |n| select(w, n) else queueChanged(w);
        } else if (cur > i) d.current = cur - 1;
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

fn hideTab(w: *Widget, i: usize) void {
    const d = data(w);
    d.tabs.items[i].state = .hidden;
    if (d.current != null and d.current.? == i) {
        if (nearest(d, i)) |n| select(w, n) else {
            d.current = null;
            layout.setMapped(d.tabs.items[i].w, false);
            queueChanged(w);
        }
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

// ---- The paint ----

fn paintNotebook(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    const d = data(w);
    _ = placeTabs(w);
    const row = rowHeight(w);
    const client = app.styles.compute(w, "client", &w.style, app.env);
    try paint.styledBox(b, .{ .x = 0, .y = row, .w = w.geom.w, .h = w.geom.h - row }, &client);
    const tab = paint.partStyle(w, "tab", &d.tab_part).style;
    const sel = app.styles.compute(w, "tab-selected", &w.style, app.env);
    const hov = app.styles.compute(w, "tab-hover", &w.style, app.env);
    const dis = app.styles.compute(w, "tab-disabled", &w.style, app.env);
    for (d.tabs.items, 0..) |t, i| {
        if (t.state == .hidden) continue;
        const r: geom.Rect = .{ .x = t.x, .y = 0, .w = t.w_px, .h = row };
        const ts: *const style_mod.Style = if (t.state == .disabled) &dis else if (d.current != null and d.current.? == i) &sel else if (d.hot != null and d.hot.? == i) &hov else &tab;
        try paint.styledBox(b, r, ts);
        const ins = paint.insets(ts);
        try paint.label(w, b, .{ .x = r.x + ins.left, .y = r.y + ins.top, .w = r.w - ins.horizontal(), .h = r.h - ins.vertical() }, t.text, ts, .center, .center);
    }
    if (d.current != null) {
        const ind = app.styles.compute(w, "indicator", &w.style, app.env);
        const at = indicatorAt(w);
        d.ind_valid = true;
        const th: i32 = 2;
        try paint.styledBox(b, .{ .x = num.pxRound(at[0]), .y = row - th, .w = num.pxRound(at[1]), .h = th }, &ind);
    }
}

/// Paints the color of the client area over the new page, from opaque to clear.
fn paintOver(w: *Widget, b: *scene.Builder) anyerror!void {
    const d = data(w);
    if (!d.fading) return;
    const app = w.app;
    const since = app.platform.nowUs() - d.fade_start;
    if (since >= fade_us or anim.reduced(app) or app.part_end) {
        if (since >= fade_us) d.fading = false;
        return;
    }
    app.anim_more = true;
    const lin = @as(f32, @floatFromInt(since)) / @as(f32, @floatFromInt(fade_us));
    app.notePartMove(d.fade_start, .{ .duration_ms = @intCast(@divTrunc(fade_us, 1000)), .timing = easing.Timing.ease_out }, lin);
    const p = easing.Timing.ease_out.eval(lin);
    const client = app.styles.compute(w, "client", &w.style, app.env);
    var cover = client.background;
    if (cover.a == 0) cover = w.style.background;
    const c = clientRect(w);
    try b.box(c, .{ .fill = cover, .opacity = 1 - p });
}

/// The shown progress of the slide of the indicator, for the tests.
pub fn indicatorOf(w: *Widget) [2]f32 {
    return indicatorAt(w);
}

// ---- The subcommands ----

fn tabArg(w: *Widget, it: *ztcl.Interp, v: Value, insert: bool) ztcl.Error!usize {
    const d = data(w);
    const t = try it.str(v);
    const n = d.tabs.items.len;
    if (std.mem.eql(u8, t, "end")) return n;
    if (std.mem.eql(u8, t, "current")) return d.current orelse it.fail("No tabs", .{});
    if (t.len > 0 and t[0] == '@') {
        var parts = std.mem.splitScalar(u8, t[1..], ',');
        const xs = parts.next() orelse "";
        const ys = parts.next() orelse "";
        const x = std.fmt.parseInt(i32, xs, 10) catch return it.fail("Invalid slave specification {s}", .{t});
        const y = std.fmt.parseInt(i32, ys, 10) catch return it.fail("Invalid slave specification {s}", .{t});
        return tabAt(w, x, y) orelse it.fail("Invalid slave specification {s}", .{t});
    }
    if (t.len > 0 and t[0] == '.') {
        const c = w.app.find(t) orelse return it.fail("Invalid slave specification {s}", .{t});
        return indexOf(d, c) orelse it.fail("{s} is not managed by {s}", .{ t, w.path });
    }
    const i = std.fmt.parseInt(i64, t, 10) catch return it.fail("Invalid slave specification {s}", .{t});
    if (i < 0 or i > n or (!insert and i == n)) return it.fail("Slave index {s} out of bounds", .{t});
    return @intCast(i);
}

fn tabAt(w: *Widget, x: i32, y: i32) ?usize {
    const d = data(w);
    // The tabs have no place before the notebook is shown, as in `wish`.
    if (!w.mapped) return null;
    if (y < 0 or y >= rowHeight(w)) return null;
    _ = placeTabs(w);
    for (d.tabs.items, 0..) |t, i| {
        if (t.state == .hidden) continue;
        if (x >= t.x and x < t.x + t.w_px) return i;
    }
    return null;
}

fn setOwned(app: *App, slot: *[]u8, text: []const u8) !void {
    const copy = try app.gpa.dupe(u8, text);
    app.gpa.free(slot.*);
    slot.* = copy;
}

fn parseSticky(it: *ztcl.Interp, text: []const u8) ztcl.Error!u4 {
    var v: u4 = 0;
    for (text) |c| switch (c) {
        'n', 'N' => v |= 1,
        'e', 'E' => v |= 2,
        's', 'S' => v |= 4,
        'w', 'W' => v |= 8,
        ' ', ',' => {},
        else => return it.fail("Bad -sticky specification {s}", .{text}),
    };
    return v;
}

fn stickyText(a: std.mem.Allocator, v: u4) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (v & 1 != 0) try out.append(a, 'n');
    if (v & 4 != 0) try out.append(a, 's');
    if (v & 2 != 0) try out.append(a, 'e');
    if (v & 8 != 0) try out.append(a, 'w');
    return out.items;
}

fn optIndex(it: *ztcl.Interp, name: []const u8) ztcl.Error!usize {
    for (tab_opts, 0..) |o, i| if (std.mem.eql(u8, o, name)) return i;
    return it.fail("unknown option \"{s}\"", .{name});
}

/// Checks the pairs of tab options, then applies them to `t`.
fn applyTabOpts(w: *Widget, it: *ztcl.Interp, t: *Tab, args: []const Value) ztcl.Error!void {
    const app = w.app;
    if (args.len % 2 != 0) return it.fail("value for \"{s}\" missing", .{try it.str(args[args.len - 1])});
    // Check each value first, so a bad pair leaves the tab as it was.
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const k = try optIndex(it, try it.str(args[i]));
        const v = try it.str(args[i + 1]);
        switch (k) {
            0 => _ = try parsePadding(it, app, v),
            1 => _ = try parseSticky(it, v),
            2 => if (std.meta.stringToEnum(TabState, v) == null) return it.fail("bad state \"{s}\": must be normal, disabled, or hidden", .{v}),
            6 => _ = try it.int(args[i + 1]),
            else => {},
        }
    }
    i = 0;
    while (i < args.len) : (i += 2) {
        const k = optIndex(it, try it.str(args[i])) catch unreachable;
        const v = try it.str(args[i + 1]);
        switch (k) {
            0 => {
                try setOwned(app, &t.padding, v);
                t.pad = try parsePadding(it, app, v);
            },
            1 => t.sticky = try parseSticky(it, v),
            2 => {
                const st = std.meta.stringToEnum(TabState, v).?;
                if (st == .hidden) {
                    if (indexOf(data(w), t.w)) |idx| hideTab(w, idx) else t.state = .hidden;
                } else t.state = st;
            },
            3 => try setOwned(app, &t.text, v),
            4 => try setOwned(app, &t.image, v),
            5 => try setOwned(app, &t.compound, v),
            6 => t.underline = try it.int(args[i + 1]),
            else => unreachable,
        }
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

fn tabValue(it: *ztcl.Interp, t: *const Tab, k: usize) ztcl.Error!Value {
    const a = it.alloc();
    return switch (k) {
        0 => .{ .str = if (t.padding.len > 0) try a.dupe(u8, t.padding) else "0" },
        1 => .{ .str = try stickyText(a, t.sticky) },
        2 => .{ .str = @tagName(t.state) },
        3 => .{ .str = try a.dupe(u8, t.text) },
        4 => .{ .str = try a.dupe(u8, t.image) },
        5 => .{ .str = try a.dupe(u8, t.compound) },
        6 => .{ .int = t.underline },
        else => unreachable,
    };
}

fn checkPage(it: *ztcl.Interp, w: *Widget, c: *Widget) ztcl.Error!void {
    if (c == w or c.isToplevel() or !grid.isDescendant(w, c.parent.?)) return it.fail("can't add {s} as slave of {s}", .{ c.path, w.path });
}

/// Makes `c` the page of a new tab at `at`.
fn manage(w: *Widget, c: *Widget, at: usize) ztcl.Error!*Tab {
    if (w.container_manager != &manager) {
        try layout.claim(w, &manager);
        w.container_manager = &manager;
        w.container_data = w.data;
    }
    if (c.manager) |m| if (m != &manager) m.forget(c);
    const d = data(w);
    const t = try w.app.gpa.create(Tab);
    t.* = .{ .w = c };
    d.tabs.insert(w.app.gpa, at, t) catch |e| {
        w.app.gpa.destroy(t);
        return e;
    };
    if (d.current) |cur| if (cur >= at) {
        d.current = cur + 1;
    };
    c.manager = &manager;
    c.manager_data = w;
    layout.setMapped(c, false);
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    return t;
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const app = w.app;
    const d = data(w);
    const name = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, name, "add")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} add window ?-option value ...?\"", .{w.path});
        const path = try it.str(argv[2]);
        const c = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
        try checkPage(it, w, c);
        if (indexOf(d, c)) |i| {
            const t = d.tabs.items[i];
            try applyTabOpts(w, it, t, argv[3..]);
            if (t.state == .hidden) t.state = .normal;
            return Value.empty;
        }
        // A bad option leaves no tab.
        var probe: Tab = .{ .w = c };
        defer {
            app.gpa.free(probe.padding);
            app.gpa.free(probe.text);
            app.gpa.free(probe.image);
            app.gpa.free(probe.compound);
        }
        try applyTabOpts(w, it, &probe, argv[3..]);
        const t = try manage(w, c, d.tabs.items.len);
        std.mem.swap(Tab, t, &probe);
        t.w = c;
        if (d.current == null and t.state != .hidden) select(w, d.tabs.items.len - 1);
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "insert")) {
        if (argv.len < 4) return it.fail("wrong # args: should be \"{s} insert index slave ?-option value ...?\"", .{w.path});
        const at = try tabArg(w, it, argv[2], true);
        const path = try it.str(argv[3]);
        const c = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
        if (indexOf(d, c)) |old| {
            const cur_w: ?*Widget = if (d.current) |cur| d.tabs.items[cur].w else null;
            const t = d.tabs.orderedRemove(old);
            const to = @min(at, d.tabs.items.len);
            d.tabs.insertAssumeCapacity(to, t);
            if (cur_w) |cw| d.current = indexOf(d, cw);
            try applyTabOpts(w, it, t, argv[4..]);
            return Value.empty;
        }
        try checkPage(it, w, c);
        var probe: Tab = .{ .w = c };
        defer {
            app.gpa.free(probe.padding);
            app.gpa.free(probe.text);
            app.gpa.free(probe.image);
            app.gpa.free(probe.compound);
        }
        try applyTabOpts(w, it, &probe, argv[4..]);
        const t = try manage(w, c, @min(at, d.tabs.items.len));
        std.mem.swap(Tab, t, &probe);
        t.w = c;
        if (d.current == null and t.state != .hidden) select(w, indexOf(d, c).?);
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "forget") or std.mem.eql(u8, name, "hide")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} {s} tab\"", .{ w.path, name });
        const i = try tabArg(w, it, argv[2], false);
        if (name[0] == 'f') removeTab(w, i) else hideTab(w, i);
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "index")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} index tab\"", .{w.path});
        const t = try it.str(argv[2]);
        if (std.mem.eql(u8, t, "current")) return if (d.current) |c| .{ .int = @intCast(c) } else Value.empty;
        if (t.len > 0 and t[0] == '@') {
            var parts = std.mem.splitScalar(u8, t[1..], ',');
            const x = std.fmt.parseInt(i32, parts.next() orelse "", 10) catch return it.fail("Invalid slave specification {s}", .{t});
            const y = std.fmt.parseInt(i32, parts.next() orelse "", 10) catch return it.fail("Invalid slave specification {s}", .{t});
            return if (tabAt(w, x, y)) |i| .{ .int = @intCast(i) } else Value.empty;
        }
        return .{ .int = @intCast(try tabArg(w, it, argv[2], std.mem.eql(u8, t, "end"))) };
    }
    if (std.mem.eql(u8, name, "select")) {
        if (argv.len > 3) return it.fail("wrong # args: should be \"{s} select ?tab?\"", .{w.path});
        if (argv.len == 2) return if (d.current) |c| .{ .str = d.tabs.items[c].w.path } else Value.empty;
        const i = try tabArg(w, it, argv[2], false);
        if (d.tabs.items[i].state != .disabled) select(w, i);
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "tab")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} tab tab ?-option ?value??...\"", .{w.path});
        const t = d.tabs.items[try tabArg(w, it, argv[2], false)];
        if (argv.len == 3) {
            var out: [tab_opts.len * 2]Value = undefined;
            for (tab_opts, 0..) |o, k| {
                out[2 * k] = .{ .str = o };
                out[2 * k + 1] = try tabValue(it, t, k);
            }
            return try ztcl.value.newList(a, &out);
        }
        if (argv.len == 4) return try tabValue(it, t, try optIndex(it, try it.str(argv[3])));
        try applyTabOpts(w, it, t, argv[3..]);
        return Value.empty;
    }
    if (std.mem.eql(u8, name, "tabs")) {
        if (argv.len != 2) return it.fail("wrong # args: should be \"{s} tabs \"", .{w.path});
        var out: std.ArrayListUnmanaged(Value) = .empty;
        for (d.tabs.items) |t| try out.append(a, .{ .str = t.w.path });
        return try ztcl.value.newList(a, out.items);
    }
    if (std.mem.eql(u8, name, "identify")) {
        if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} identify ?what? x y\"", .{w.path});
        var what: usize = 0;
        if (argv.len == 5) {
            const words = [_][]const u8{ "element", "tab" };
            what = try ttk_style.pick(it, try it.str(argv[2]), &words, "bad option");
        }
        const x: i32 = @intCast(std.math.clamp(try it.int(argv[argv.len - 2]), -1 << 24, 1 << 24));
        const y: i32 = @intCast(std.math.clamp(try it.int(argv[argv.len - 1]), -1 << 24, 1 << 24));
        const i = tabAt(w, x, y) orelse return Value.empty;
        if (what == 1) return .{ .int = @intCast(i) };
        const st = tabStyle(w);
        const ins = paint.insets(&st);
        const t = d.tabs.items[i];
        const inside = x >= t.x + ins.left and x < t.x + t.w_px - ins.right and y >= ins.top and y < rowHeight(w) - ins.bottom;
        return .{ .str = if (inside) "label" else "tab" };
    }
    return null;
}

// ---- The bindings ----

/// The next tab from `i` in the direction `dir` that is not hidden or disabled.
fn step(d: *const Data, from: usize, dir: i32) ?usize {
    const n: i32 = @intCast(d.tabs.items.len);
    var k: i32 = @intCast(from);
    var count: i32 = 0;
    while (count < n) : (count += 1) {
        k = @mod(k + dir, n);
        const t = d.tabs.items[@intCast(k)];
        if (t.state == .normal) return @intCast(k);
    }
    return null;
}

const Action = enum { press, motion, leave, step, cycle, mnemonic };

/// `::ztk::priv::notebook action path ?args?`
fn cmdNotebook(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::notebook action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.paint != paintNotebook) return Value.empty;
    const d = data(w);
    switch (act) {
        .press, .motion => {
            if (argv.len < 5) return Value.empty;
            const x: i32 = @intCast(std.math.clamp(try it.int(argv[3]), -1 << 24, 1 << 24));
            const y: i32 = @intCast(std.math.clamp(try it.int(argv[4]), -1 << 24, 1 << 24));
            const i = tabAt(w, x, y);
            if (act == .motion) {
                if (!std.meta.eql(d.hot, i)) {
                    d.hot = i;
                    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
                }
                return Value.empty;
            }
            const k = i orelse return Value.empty;
            if (d.tabs.items[k].state == .disabled or w.state.disabled) return Value.empty;
            select(w, k);
            if (focus.accepts(w)) focus.set(app, w);
        },
        .leave => {
            if (d.hot != null) {
                d.hot = null;
                w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
            }
        },
        .step, .cycle => {
            if (argv.len < 4 or w.state.disabled) return Value.empty;
            const dir: i32 = if (std.mem.eql(u8, try it.str(argv[3]), "-1")) -1 else 1;
            const cur = d.current orelse return Value.empty;
            if (step(d, cur, dir)) |k| select(w, k);
            if (act == .step and focus.accepts(w)) focus.set(app, w);
        },
        .mnemonic => {
            if (argv.len < 4) return Value.empty;
            const key = try it.str(argv[3]);
            if (key.len != 1) return Value.empty;
            for (d.tabs.items, 0..) |t, i| {
                if (t.state != .normal or t.underline < 0 or t.underline >= t.text.len) continue;
                if (std.ascii.toLower(t.text[@intCast(t.underline)]) == std.ascii.toLower(key[0])) {
                    select(w, i);
                    return .{ .int = 1 };
                }
            }
        },
    }
    return Value.empty;
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("ttk::notebook", widget.classCommand(&class));
    try app.classes.put(app.gpa, "ttk::notebook", &class);
    try it.register("ztk::priv::notebook", cmdNotebook);
    _ = try it.eval(
        \\bind TNotebook <Button-1> {::ztk::priv::notebook press %W %x %y}
        \\bind TNotebook <Motion> {::ztk::priv::notebook motion %W %x %y}
        \\bind TNotebook <Leave> {::ztk::priv::notebook leave %W}
        \\bind TNotebook <Key-Right> {::ztk::priv::notebook step %W 1}
        \\bind TNotebook <Key-Left> {::ztk::priv::notebook step %W -1}
        \\bind TNotebook <Control-Key-Tab> {::ztk::priv::notebook cycle %W 1}
        \\bind TNotebook <Control-Shift-Key-Tab> {::ztk::priv::notebook cycle %W -1}
        \\bind TNotebook <Control-Key-ISO_Left_Tab> {::ztk::priv::notebook cycle %W -1}
        \\bind TNotebook <Destroy> {::ttk::notebook::Cleanup %W}
        \\namespace eval ::ttk::notebook {}
        \\# The notebooks of each toplevel with traversal, in the order of the calls.
        \\proc ::ttk::notebook::enableTraversal {nb} {
        \\    variable TLNotebooks
        \\    set top [winfo toplevel $nb]
        \\    if {![info exists TLNotebooks($top)]} {
        \\        set TLNotebooks($top) {}
        \\        bind $top <Control-Key-Next> {+::ttk::notebook::TLCycleTab %W 1}
        \\        bind $top <Control-Key-Prior> {+::ttk::notebook::TLCycleTab %W -1}
        \\        bind $top <Control-Key-Tab> {+::ttk::notebook::TLCycleTab %W 1}
        \\        bind $top <Control-Shift-Key-Tab> {+::ttk::notebook::TLCycleTab %W -1}
        \\        bind $top <Control-Key-ISO_Left_Tab> {+::ttk::notebook::TLCycleTab %W -1}
        \\        bind $top <Alt-Key> {+::ttk::notebook::MnemonicActivation %W %K}
        \\    }
        \\    if {$nb ni $TLNotebooks($top)} {lappend TLNotebooks($top) $nb}
        \\}
        \\# The notebook of the focus, else the first one of the toplevel.
        \\proc ::ttk::notebook::ActiveNotebook {top} {
        \\    variable TLNotebooks
        \\    if {![info exists TLNotebooks($top)]} return
        \\    set f [focus]
        \\    foreach nb $TLNotebooks($top) {
        \\        if {![winfo exists $nb]} continue
        \\        if {$f eq $nb || [string first $nb. $f] == 0} {return $nb}
        \\    }
        \\    foreach nb $TLNotebooks($top) {if {[winfo exists $nb]} {return $nb}}
        \\}
        \\# The class binding of TNotebook cycles a notebook with the focus.
        \\proc ::ttk::notebook::TLCycleTab {w dir} {
        \\    set nb [ActiveNotebook [winfo toplevel $w]]
        \\    if {$nb ne "" && [focus] ne $nb} {::ztk::priv::notebook cycle $nb $dir}
        \\}
        \\proc ::ttk::notebook::MnemonicActivation {w key} {
        \\    variable TLNotebooks
        \\    set top [winfo toplevel $w]
        \\    if {![info exists TLNotebooks($top)]} return
        \\    foreach nb $TLNotebooks($top) {
        \\        if {[winfo exists $nb] && [::ztk::priv::notebook mnemonic $nb $key] eq "1"} return
        \\    }
        \\}
        \\proc ::ttk::notebook::Cleanup {nb} {
        \\    variable TLNotebooks
        \\    set top [winfo toplevel $nb]
        \\    if {[info exists TLNotebooks($top)]} {
        \\        set TLNotebooks($top) [lsearch -all -inline -not -exact $TLNotebooks($top) $nb]
        \\    }
        \\}
    );
}
