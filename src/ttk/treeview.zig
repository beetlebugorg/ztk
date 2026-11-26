//! `ttk::treeview`: a tree of items with columns of values.
//!
//! The items form a tree under the root item, whose id is the empty
//! string. Each item has an id, a parent, a list of children, the item
//! options (`-text`, `-image`, `-values`, `-open`, and `-tags`), and a
//! selection flag. A map from the id to the item finds an item at once.
//! A detached item keeps its children and has no parent until `move`
//! puts it back.
//!
//! The rows are the items that show: the children of the root, and the
//! children of each open item that shows, in the order of the tree. Each
//! row has the height of the font of the widget with the padding of the
//! part `::item`. The tree column (`#0`) indents each level by `indent`
//! pixels and draws an arrow for an item with children. The heading row
//! goes above the rows when `-show` has `headings`.
//!
//! The columns are the tree column and the columns of `-columns`, and
//! `-displaycolumns` gives the data columns that show and their order.
//! When the columns are narrower than the widget, the columns with
//! `-stretch` grow to fill it, and the width of each one changes as in
//! `wish`. A drag of the border at the right of a heading changes the
//! width of its column.
//!
//! An item that opens or closes moves the rows below it: the block of
//! its children grows or shrinks in 200 ms, and its arrow turns. The
//! script sees the end state at once. The views of `scroll.zig` scroll
//! the rows by pixels.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const num = @import("../num.zig");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const scene = @import("../scene.zig");
const anim = @import("../anim.zig");
const easing = @import("../easing.zig");
const focus = @import("../focus.zig");
const bind = @import("../bind.zig");
const path = @import("../path.zig");
const scroll = @import("../scroll.zig");
const style_mod = @import("../style.zig");
const label = @import("../widgets/label.zig");
const font_mod = @import("../text/font.zig");
const ttk_widgets = @import("widgets.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const s = ttk_widgets.s;

/// The options of `ttk::treeview`, in the order of `wish`, then `-emptytext`.
const specs = [_]Spec{
    s("-columns", "columns", "Columns", .string, ""),
    s("-displaycolumns", "displayColumns", "DisplayColumns", .string, "#all"),
    s("-show", "show", "Show", .string, "tree headings"),
    .{ .name = "-selectmode", .db_name = "selectMode", .db_class = "SelectMode", .type = .word, .default = "extended", .words = &select_words, .allow_empty = false },
    s("-height", "height", "Height", .pixels, "10"),
    s("-padding", "padding", "Pad", .string, ""),
    s("-xscrollcommand", "xScrollCommand", "ScrollCommand", .string, ""),
    s("-yscrollcommand", "yScrollCommand", "ScrollCommand", .string, ""),
    ttk_widgets.takefocus,
    s("-cursor", "cursor", "Cursor", .string, ""),
    s("-style", "style", "Style", .string, ""),
    .{ .name = "-class", .type = .string, .allow_empty = true, .create_only = true },
    s("-emptytext", "emptyText", "EmptyText", .string, ""),
};

const select_words = [_][]const u8{ "none", "browse", "extended" };

const base: widget.Class = .{
    .command = "",
    .tk_class = "",
    .role = "tree",
    .focusable = true,
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .configured = configured,
    .measure = measure,
    .paint = paintTree,
    .event = tagEvent,
    .subcommand = subcommand,
};

const subs = [_][]const u8{ "bbox", "children", "cget", "column", "configure", "delete", "detach", "drag", "drop", "exists", "focus", "heading", "identify", "index", "instate", "insert", "item", "move", "next", "parent", "prev", "see", "selection", "set", "state", "tag", "xview", "yview" };
pub const class = ttk_widgets.derive(base, "ttk::treeview", "Treeview", &specs, &subs, "*");

/// The indent of a level of the tree, the size of the arrow, and the
/// width of the area of a heading border that starts a resize.
const indent = 20;
const arrow_size = 9;
const halo = 3;
const open_us: i64 = 200_000;

// ---- The data ----

const Item = struct {
    id: []u8,
    parent: ?*Item = null,
    children: std.ArrayListUnmanaged(*Item) = .empty,
    text: []u8 = &.{},
    image: []u8 = &.{},
    /// The text of `-values` and of `-tags`. Owned.
    values: []u8 = &.{},
    tags: []u8 = &.{},
    open: bool = false,
    sel: bool = false,
    detached: bool = false,
    /// The open or close animation: the start time and the shown
    /// fraction of the children at the start.
    anim_start: i64 = 0,
    anim_from: f32 = 1,
    animating: bool = false,
};

const Column = struct {
    id: []u8,
    width: i32 = 200,
    minwidth: i32 = 20,
    stretch: bool = true,
    anchor: options.Anchor = .w,
    /// The heading.
    h_text: []u8 = &.{},
    h_image: []u8 = &.{},
    h_anchor: options.Anchor = .center,
    h_command: []u8 = &.{},
    h_state: []u8 = &.{},
};

const Tag = struct {
    name: []u8,
    text: []u8 = &.{},
    image: []u8 = &.{},
    anchor: []u8 = &.{},
    background: []u8 = &.{},
    foreground: []u8 = &.{},
    font: []u8 = &.{},
};

const Data = struct {
    root: *Item,
    items: std.StringHashMapUnmanaged(*Item) = .empty,
    serial: u32 = 0,
    /// The tree column at 0, then the columns of `-columns`.
    cols: std.ArrayListUnmanaged(*Column) = .empty,
    /// The indexes in `cols` of the data columns that show.
    display: std.ArrayListUnmanaged(usize) = .empty,
    tags: std.ArrayListUnmanaged(*Tag) = .empty,
    bindings: bind.Table,
    focus: ?*Item = null,
    /// The anchor of a range selection with Shift.
    anchor: ?*Item = null,
    hover: ?*Item = null,
    vx: scroll.View = .{},
    vy: scroll.View = .{},
    /// The column of a resize drag, and the heading of a press.
    drag_col: ?usize = null,
    pressed_heading: ?usize = null,
    sel_anim: paint.PartAnim = .{},
    select_pending: bool = false,
};

fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

fn init(w: *Widget) anyerror!void {
    const gpa = w.app.gpa;
    const d = try gpa.create(Data);
    errdefer gpa.destroy(d);
    const root = try gpa.create(Item);
    root.* = .{ .id = try gpa.dupe(u8, "") };
    d.* = .{ .root = root, .bindings = bind.Table.init(gpa) };
    try d.items.put(gpa, root.id, root);
    const tree = try gpa.create(Column);
    tree.* = .{ .id = try gpa.dupe(u8, "") };
    try d.cols.append(gpa, tree);
    w.data = d;
}

fn freeItem(gpa: std.mem.Allocator, it: *Item) void {
    gpa.free(it.id);
    gpa.free(it.text);
    gpa.free(it.image);
    gpa.free(it.values);
    gpa.free(it.tags);
    it.children.deinit(gpa);
    gpa.destroy(it);
}

fn freeColumn(gpa: std.mem.Allocator, c: *Column) void {
    gpa.free(c.id);
    gpa.free(c.h_text);
    gpa.free(c.h_image);
    gpa.free(c.h_command);
    gpa.free(c.h_state);
    gpa.destroy(c);
}

fn freeTag(gpa: std.mem.Allocator, t: *Tag) void {
    inline for (.{ "name", "text", "image", "anchor", "background", "foreground", "font" }) |f| gpa.free(@field(t, f));
    gpa.destroy(t);
}

fn deinit(w: *Widget) void {
    const gpa = w.app.gpa;
    const d = data(w);
    var iter = d.items.valueIterator();
    while (iter.next()) |v| freeItem(gpa, v.*);
    d.items.deinit(gpa);
    for (d.cols.items) |c| freeColumn(gpa, c);
    d.cols.deinit(gpa);
    d.display.deinit(gpa);
    for (d.tags.items) |t| freeTag(gpa, t);
    d.tags.deinit(gpa);
    d.bindings.deinit();
    scroll.forget(w);
    gpa.destroy(d);
    w.data = null;
}

fn setOwned(gpa: std.mem.Allocator, slot: *[]u8, text: []const u8) !void {
    const copy = try gpa.dupe(u8, text);
    gpa.free(slot.*);
    slot.* = copy;
}

fn repaint(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

fn rowsChanged(w: *Widget) void {
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
}

// ---- The options of the widget ----

/// The text of an option, or its default when the script did not set it.
fn optText(w: *const Widget, comptime name: []const u8) []const u8 {
    const slot = options.get(w, name);
    if (slot.set) return slot.text;
    inline for (specs) |sp| if (comptime std.mem.eql(u8, sp.name, name)) return sp.default;
    return "";
}

fn showTree(w: *const Widget) bool {
    return hasWord(optText(w, "-show"), "tree");
}

fn showHeadings(w: *const Widget) bool {
    return hasWord(optText(w, "-show"), "headings");
}

fn hasWord(list: []const u8, word: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, list, " \t\n");
    while (words.next()) |x| if (std.mem.eql(u8, x, word)) return true;
    return false;
}

fn selectMode(w: *const Widget) u8 {
    const v = options.get(w, "-selectmode").value;
    return if (v == .word) v.word else 2;
}

fn configured(w: *Widget, changed: []const usize) ztcl.Error!void {
    const it = w.app.it;
    const gpa = w.app.gpa;
    const d = data(w);
    for (changed) |i| {
        const name = specs[i].name;
        if (std.mem.eql(u8, name, "-show")) {
            const words = try it.list(.{ .str = optText(w, "-show") });
            for (words) |v| {
                const x = try it.str(v);
                if (!std.mem.eql(u8, x, "tree") and !std.mem.eql(u8, x, "headings")) return it.fail("bad value \"{s}\": must be tree or headings", .{x});
            }
        } else if (std.mem.eql(u8, name, "-columns")) {
            const words = try it.list(.{ .str = optText(w, "-columns") });
            // The columns with the same id keep their options.
            var next: std.ArrayListUnmanaged(*Column) = .empty;
            defer next.deinit(gpa);
            try next.append(gpa, d.cols.items[0]);
            for (words) |v| {
                const id = try it.str(v);
                var found: ?*Column = null;
                for (d.cols.items[1..]) |c| if (std.mem.eql(u8, c.id, id)) {
                    found = c;
                };
                for (next.items[1..]) |c| if (found != null and c == found.?) {
                    found = null;
                };
                const col = found orelse blk: {
                    const c = try gpa.create(Column);
                    c.* = .{ .id = try gpa.dupe(u8, id) };
                    break :blk c;
                };
                try next.append(gpa, col);
            }
            for (d.cols.items[1..]) |c| {
                if (std.mem.indexOfScalar(*Column, next.items, c) == null) freeColumn(gpa, c);
            }
            d.cols.clearRetainingCapacity();
            try d.cols.appendSlice(gpa, next.items);
            try setDisplay(w, it, optText(w, "-displaycolumns"), false);
        } else if (std.mem.eql(u8, name, "-displaycolumns")) {
            try setDisplay(w, it, optText(w, "-displaycolumns"), true);
        } else if (std.mem.eql(u8, name, "-padding")) {
            _ = try parsePadding(w, optText(w, "-padding"));
        }
    }
    rowsChanged(w);
}

/// Sets the data columns that show from the text of `-displaycolumns`.
fn setDisplay(w: *Widget, it: *ztcl.Interp, text: []const u8, strict: bool) ztcl.Error!void {
    const d = data(w);
    const gpa = w.app.gpa;
    var list: std.ArrayListUnmanaged(usize) = .empty;
    errdefer list.deinit(gpa);
    const words = try it.list(.{ .str = text });
    if (words.len == 1 and std.mem.eql(u8, try it.str(words[0]), "#all")) {
        for (1..d.cols.items.len) |k| try list.append(gpa, k);
    } else for (words) |v| {
        const t = try it.str(v);
        const k = dataColumn(d, t) orelse {
            if (!strict) continue;
            return it.fail("Invalid column index {s}", .{t});
        };
        try list.append(gpa, k);
    }
    d.display.deinit(gpa);
    d.display = list;
}

/// A data column by its id or its number in `-columns`.
fn dataColumn(d: *const Data, t: []const u8) ?usize {
    for (d.cols.items[1..], 1..) |c, k| if (std.mem.eql(u8, c.id, t)) return k;
    const n = std.fmt.parseInt(usize, t, 10) catch return null;
    if (n + 1 < d.cols.items.len) return n + 1;
    return null;
}

fn parsePadding(w: *Widget, text: []const u8) ztcl.Error!geom.Insets {
    const it = w.app.it;
    var v: [4]i32 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    while (words.next()) |word| {
        if (n == 4) return it.fail("Wrong #elements in padding spec", .{});
        v[n] = options.parsePixels(word, w.app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{word});
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

// ---- The geometry ----

fn itemStyle(w: *Widget) style_mod.Style {
    return w.app.styles.compute(w, "item", &w.style, w.app.env);
}

fn headingStyle(w: *Widget) style_mod.Style {
    return w.app.styles.compute(w, "heading", &w.style, w.app.env);
}

fn rowH(w: *Widget) i32 {
    const st = itemStyle(w);
    return @max(paint.lineHeight(w.app, w.style.font) + st.padding.top + st.padding.bottom, 1);
}

fn headH(w: *Widget) i32 {
    if (!showHeadings(w)) return 0;
    const st = headingStyle(w);
    return paint.lineHeight(w.app, st.font) + st.padding.top + st.padding.bottom;
}

/// The content of the widget: inside the border and `-padding`.
fn content(w: *Widget) geom.Rect {
    const ins = paint.insets(&w.style);
    const pad = parsePadding(w, optText(w, "-padding")) catch geom.Insets{};
    const l = ins.left + pad.left;
    const t = ins.top + pad.top;
    return .{ .x = l, .y = t, .w = @max(w.geom.w - l - ins.right - pad.right, 0), .h = @max(w.geom.h - t - ins.bottom - pad.bottom, 0) };
}

/// The rows: the content under the heading row.
fn rowsRect(w: *Widget) geom.Rect {
    const c = content(w);
    const hh = headH(w);
    return .{ .x = c.x, .y = c.y + hh, .w = c.w, .h = @max(c.h - hh, 0) };
}

/// The columns that show, in order: the tree column first when it shows.
fn shownCols(w: *Widget, a: std.mem.Allocator) ![]usize {
    const d = data(w);
    var out: std.ArrayList(usize) = .empty;
    if (showTree(w)) try out.append(a, 0);
    try out.appendSlice(a, d.display.items);
    return out.items;
}

fn totalWidth(w: *Widget, cols: []const usize) i32 {
    const d = data(w);
    var t: i32 = 0;
    for (cols) |k| t += d.cols.items[k].width;
    return t;
}

/// Gives the extra width of the widget to the columns with `-stretch`,
/// or takes the missing width from them down to their `-minwidth`.
fn stretch(w: *Widget) void {
    const d = data(w);
    var buf: [256]usize = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&buf));
    const cols = shownCols(w, fba.allocator()) catch return;
    const avail = rowsRect(w).w;
    if (avail <= 1 or cols.len == 0) return;
    var extra = avail - totalWidth(w, cols);
    var n: i32 = 0;
    for (cols) |k| {
        if (d.cols.items[k].stretch) n += 1;
    }
    if (n == 0 or extra == 0) return;
    // Each pass gives an even share to the columns that can take it.
    var pass: u32 = 0;
    while (extra != 0 and pass < 4) : (pass += 1) {
        var open: i32 = 0;
        for (cols) |k| {
            const c = d.cols.items[k];
            if (c.stretch and (extra > 0 or c.width > c.minwidth)) open += 1;
        }
        if (open == 0) break;
        const share = @divTrunc(extra, open);
        var left = extra - share * open;
        for (cols) |k| {
            const c = d.cols.items[k];
            if (!c.stretch or (extra < 0 and c.width <= c.minwidth)) continue;
            var dw = share;
            if (left != 0) {
                const one: i32 = if (left > 0) 1 else -1;
                dw += one;
                left -= one;
            }
            const nw = @max(c.width + dw, c.minwidth);
            extra -= nw - c.width;
            c.width = nw;
        }
    }
}

fn measure(w: *Widget) geom.Size {
    w.app.ensureStyle(w);
    var buf: [256]usize = undefined;
    var fba = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(&buf));
    const cols = shownCols(w, fba.allocator()) catch &.{};
    const ins = paint.insets(&w.style);
    const pad = parsePadding(w, optText(w, "-padding")) catch geom.Insets{};
    const hv = options.get(w, "-height").value;
    const nrows: i32 = if (hv == .pixels) @max(hv.pixels, 0) else 10;
    return .{
        .w = @max(totalWidth(w, cols), 1) + ins.horizontal() + pad.horizontal(),
        .h = nrows * rowH(w) + headH(w) + ins.vertical() + pad.vertical(),
    };
}

// ---- The rows ----

/// True when the item and each of its ancestors is attached and each
/// ancestor is open.
fn shows(d: *const Data, item: *const Item) bool {
    var x = item;
    while (x.parent) |p| : (x = p) {
        if (!p.open and p.parent != null) return false;
    }
    return x == d.root;
}

fn depth(item: *const Item) i32 {
    var n: i32 = 0;
    var x = item;
    while (x.parent) |p| : (x = p) n += 1;
    return n - 1;
}

/// The rows in the order of the tree, for the end state.
fn rows(w: *Widget, a: std.mem.Allocator) ![]*Item {
    var out: std.ArrayList(*Item) = .empty;
    try walk(a, data(w).root, &out);
    return out.items;
}

fn walk(a: std.mem.Allocator, item: *Item, out: *std.ArrayList(*Item)) !void {
    if (!item.open and item.parent != null) return;
    for (item.children.items) |c| {
        try out.append(a, c);
        try walk(a, c, out);
    }
}

fn rowIndex(w: *Widget, item: *const Item, a: std.mem.Allocator) ?usize {
    const rs = rows(w, a) catch return null;
    for (rs, 0..) |r, k| if (r == item) return k;
    return null;
}

fn sync(w: *Widget) void {
    w.app.ensureStyle(w);
    const d = data(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const all = rows(w, arena.allocator()) catch return;
    const n = all.len;
    const r = rowsRect(w);
    d.vy.setSize(@floatFromInt(@as(i64, @intCast(n)) * rowH(w)), @floatFromInt(r.h));
    stretch(w);
    const cols = shownCols(w, arena.allocator()) catch &.{};
    d.vx.setSize(@floatFromInt(totalWidth(w, cols)), @floatFromInt(r.w));
}

fn report(w: *Widget) void {
    const d = data(w);
    scroll.report(w, &d.vx, "-xscrollcommand");
    scroll.report(w, &d.vy, "-yscrollcommand");
}

/// The x of the left edge of each shown column, from the left of the content.
fn columnX(w: *Widget, cols: []const usize, k: usize) i32 {
    const d = data(w);
    var x: i32 = 0;
    for (cols[0..k]) |c| x += d.cols.items[c].width;
    return x;
}

// ---- Lookups ----

fn find(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!*Item {
    const id = try it.str(v);
    return data(w).items.get(id) orelse it.fail("Item {s} not found", .{id});
}

fn findList(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error![]*Item {
    const words = try it.list(v);
    const out = try it.alloc().alloc(*Item, words.len);
    for (words, out) |x, *o| o.* = try find(w, it, x);
    return out;
}

/// A column by `#n` (a shown column), an id, or a number in `-columns`.
fn columnArg(w: *Widget, it: *ztcl.Interp, v: Value) ztcl.Error!usize {
    const d = data(w);
    const t = try it.str(v);
    if (t.len > 0 and t[0] == '#') {
        const n = std.fmt.parseInt(usize, t[1..], 10) catch return it.fail("Invalid column index {s}", .{t});
        if (n == 0) return 0;
        if (n > d.display.items.len) return it.fail("Column {s} out of range", .{t});
        return d.display.items[n - 1];
    }
    return dataColumn(d, t) orelse it.fail("Invalid column index {s}", .{t});
}

// ---- The item options ----

const item_opts = [_][]const u8{ "-text", "-image", "-values", "-open", "-tags" };

fn optIndex(it: *ztcl.Interp, names: []const []const u8, t: []const u8) ztcl.Error!usize {
    for (names, 0..) |n, k| if (std.mem.eql(u8, n, t)) return k;
    return it.fail("unknown option \"{s}\"", .{t});
}

fn itemValue(item: *const Item, k: usize) Value {
    return switch (k) {
        0 => .{ .str = item.text },
        1 => .{ .str = item.image },
        2 => .{ .str = item.values },
        3 => .{ .int = @intFromBool(item.open) },
        else => .{ .str = item.tags },
    };
}

/// Applies item options. Each value is checked before a change.
fn applyItem(w: *Widget, it: *ztcl.Interp, item: *Item, args: []const Value) ztcl.Error!void {
    const gpa = w.app.gpa;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const k = try optIndex(it, &item_opts, try it.str(args[i]));
        if (i + 1 >= args.len) return it.fail("value for \"{s}\" missing", .{item_opts[k]});
        const v = try it.str(args[i + 1]);
        switch (k) {
            1 => if (v.len > 0 and w.app.images.find(v) == null) return it.fail("image \"{s}\" doesn't exist", .{v}),
            2, 4 => _ = try it.list(args[i + 1]),
            3 => _ = options.parseBool(v) orelse return it.fail("expected boolean value but got \"{s}\"", .{v}),
            else => {},
        }
    }
    i = 0;
    while (i < args.len) : (i += 2) {
        const k = optIndex(it, &item_opts, try it.str(args[i])) catch unreachable;
        const v = try it.str(args[i + 1]);
        switch (k) {
            0 => setOwned(gpa, &item.text, v) catch return error.OutOfMemory,
            1 => setOwned(gpa, &item.image, v) catch return error.OutOfMemory,
            2 => setOwned(gpa, &item.values, v) catch return error.OutOfMemory,
            3 => setOpen(w, item, options.parseBool(v).?),
            else => {
                setOwned(gpa, &item.tags, v) catch return error.OutOfMemory;
                for (try it.list(args[i + 1])) |t| _ = try ensureTag(w, try it.str(t));
            },
        }
    }
    rowsChanged(w);
}

/// Opens or closes an item, with the move of the rows below it.
fn setOpen(w: *Widget, item: *Item, open: bool) void {
    if (item.open == open) return;
    const shown = openShown(w, item);
    item.open = open;
    if (item.children.items.len > 0 and !anim.reduced(w.app) and item.parent != null) {
        item.anim_from = shown;
        item.anim_start = w.app.platform.nowUs();
        item.animating = true;
    }
    rowsChanged(w);
}

/// The shown fraction of the children of an item: 0 closed, 1 open.
fn openShown(w: *Widget, item: *Item) f32 {
    const end: f32 = if (item.open) 1 else 0;
    if (!item.animating) return end;
    const app = w.app;
    const since = app.platform.nowUs() - item.anim_start;
    if (since >= open_us or app.part_end) {
        if (since >= open_us) item.animating = false;
        return end;
    }
    app.anim_more = true;
    const lin = @as(f32, @floatFromInt(@max(since, 0))) / @as(f32, @floatFromInt(open_us));
    app.notePartMove(item.anim_start, .{ .duration_ms = @intCast(@divTrunc(open_us, 1000)), .timing = easing.Timing.ease_out }, lin);
    const p = easing.Timing.ease_out.eval(lin);
    return item.anim_from + (end - item.anim_from) * p;
}

// ---- Tags ----

const tag_opts = [_][]const u8{ "-text", "-image", "-anchor", "-background", "-foreground", "-font" };

fn findTag(d: *const Data, name: []const u8) ?*Tag {
    for (d.tags.items) |t| if (std.mem.eql(u8, t.name, name)) return t;
    return null;
}

fn ensureTag(w: *Widget, name: []const u8) !*Tag {
    const d = data(w);
    if (findTag(d, name)) |t| return t;
    const gpa = w.app.gpa;
    const t = try gpa.create(Tag);
    t.* = .{ .name = try gpa.dupe(u8, name) };
    try d.tags.append(gpa, t);
    return t;
}

fn tagSlot(t: *Tag, k: usize) *[]u8 {
    return switch (k) {
        0 => &t.text,
        1 => &t.image,
        2 => &t.anchor,
        3 => &t.background,
        4 => &t.foreground,
        else => &t.font,
    };
}

fn hasTag(it: *ztcl.Interp, item: *const Item, name: []const u8) bool {
    const words = it.list(.{ .str = item.tags }) catch return false;
    for (words) |v| if (std.mem.eql(u8, it.str(v) catch continue, name)) return true;
    return false;
}

/// The colors and the font of the tags of an item: the first tag in the
/// list of the item that sets an option wins.
const Look = struct { bg: ?geom.Color = null, fg: ?geom.Color = null, font: ?[]const u8 = null };

fn lookOf(w: *Widget, item: *const Item) Look {
    const d = data(w);
    var l: Look = .{};
    if (item.tags.len == 0) return l;
    const it = w.app.it;
    const words = it.list(.{ .str = item.tags }) catch return l;
    for (words) |v| {
        const t = findTag(d, it.str(v) catch continue) orelse continue;
        if (l.bg == null and t.background.len > 0) l.bg = geom.Color.parseTk(t.background);
        if (l.fg == null and t.foreground.len > 0) l.fg = geom.Color.parseTk(t.foreground);
        if (l.font == null and t.font.len > 0) l.font = t.font;
    }
    return l;
}

// ---- Edits of the tree ----

fn isAncestor(a: *const Item, b: *const Item) bool {
    var x: ?*const Item = b;
    while (x) |y| : (x = y.parent) if (y == a) return true;
    return false;
}

fn unlink(item: *Item) void {
    const p = item.parent orelse return;
    if (std.mem.indexOfScalar(*Item, p.children.items, item)) |k| _ = p.children.orderedRemove(k);
    item.parent = null;
}

fn link(gpa: std.mem.Allocator, item: *Item, parent: *Item, at: usize) !void {
    try parent.children.insert(gpa, @min(at, parent.children.items.len), item);
    item.parent = parent;
    item.detached = false;
}

fn removeItem(w: *Widget, item: *Item) void {
    const d = data(w);
    for (item.children.items) |c| {
        c.parent = null;
        removeItem(w, c);
    }
    if (d.focus == item) d.focus = null;
    if (d.anchor == item) d.anchor = null;
    if (d.hover == item) d.hover = null;
    if (item.sel) queueSelect(w);
    _ = d.items.remove(item.id);
    freeItem(w.app.gpa, item);
}

fn indexArg(it: *ztcl.Interp, v: Value, n: usize) ztcl.Error!usize {
    const t = try it.str(v);
    if (std.mem.eql(u8, t, "end")) return n;
    const k = it.int(v) catch return it.fail("expected integer but got \"{s}\"", .{t});
    return @intCast(std.math.clamp(k, 0, @as(i64, @intCast(n))));
}

// ---- The selection ----

fn queueSelect(w: *Widget) void {
    const d = data(w);
    if (d.select_pending) return;
    d.select_pending = true;
    _ = w.app.loop.addNativeIdle(fireSelect, w) catch {
        d.select_pending = false;
    };
}

fn fireSelect(ctx: ?*anyopaque) void {
    const w: *Widget = @ptrCast(@alignCast(ctx.?));
    if (!w.alive() or w.data == null) return;
    data(w).select_pending = false;
    const script = std.fmt.allocPrint(w.app.gpa, "event generate {{{s}}} <<TreeviewSelect>>", .{w.path}) catch return;
    defer w.app.gpa.free(script);
    _ = w.app.it.eval(script) catch |e| w.app.backgroundError(e);
}

fn setSel(w: *Widget, item: *Item, on: bool) void {
    if (item.sel == on or item == data(w).root) return;
    item.sel = on;
    queueSelect(w);
    repaint(w);
}

fn clearSel(w: *Widget) void {
    var iter = data(w).items.valueIterator();
    while (iter.next()) |v| setSel(w, v.*, false);
}

fn selection(w: *Widget, out: *std.ArrayList(Value), item: *Item, a: std.mem.Allocator) !void {
    for (item.children.items) |c| {
        if (c.sel) try out.append(a, .{ .str = c.id });
        try selection(w, out, c, a);
    }
}

// ---- The subcommands ----

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const d = data(w);
    const app = w.app;
    const gpa = app.gpa;
    const a = it.alloc();
    const name = try it.str(argv[1]);
    const eq = std.mem.eql;
    if (eq(u8, name, "insert")) {
        if (argv.len < 4) return it.fail("wrong # args: should be \"{s} insert parent index ?-id id? -options...\"", .{w.path});
        const parent = try find(w, it, argv[2]);
        const at = try indexArg(it, argv[3], parent.children.items.len);
        var rest = argv[4..];
        var id_buf: ?[]u8 = null;
        if (rest.len >= 2 and eq(u8, try it.str(rest[0]), "-id")) {
            const id = try it.str(rest[1]);
            if (d.items.get(id) != null) return it.fail("Item {s} already exists", .{id});
            id_buf = try gpa.dupe(u8, id);
            rest = rest[2..];
        }
        errdefer if (id_buf) |b| gpa.free(b);
        const id = id_buf orelse blk: {
            while (true) {
                d.serial += 1;
                const t = try std.fmt.allocPrint(gpa, "I{X:0>3}", .{d.serial});
                if (d.items.get(t) == null) break :blk t;
                gpa.free(t);
            }
        };
        const item = try gpa.create(Item);
        item.* = .{ .id = id };
        id_buf = null;
        applyItem(w, it, item, rest) catch |e| {
            freeItem(gpa, item);
            return e;
        };
        item.animating = false;
        try d.items.put(gpa, item.id, item);
        try link(gpa, item, parent, at);
        rowsChanged(w);
        return .{ .str = item.id };
    }
    if (eq(u8, name, "item")) {
        if (argv.len < 3) return it.fail("wrong # args: should be \"{s} item item ?-option ?value??...\"", .{w.path});
        const item = try find(w, it, argv[2]);
        if (argv.len == 3) {
            var out: std.ArrayList(Value) = .empty;
            for (item_opts, 0..) |n, k| try out.appendSlice(a, &.{ .{ .str = n }, itemValue(item, k) });
            return try ztcl.value.newList(a, out.items);
        }
        if (argv.len == 4) return itemValue(item, try optIndex(it, &item_opts, try it.str(argv[3])));
        try applyItem(w, it, item, argv[3..]);
        return Value.empty;
    }
    if (eq(u8, name, "children")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} children item ?newchildren?\"", .{w.path});
        const item = try find(w, it, argv[2]);
        if (argv.len == 3) {
            const out = try a.alloc(Value, item.children.items.len);
            for (item.children.items, out) |c, *o| o.* = .{ .str = c.id };
            return try ztcl.value.newList(a, out);
        }
        const list = try findList(w, it, argv[3]);
        for (list) |c| if (isAncestor(c, item)) return it.fail("Cannot insert {s} as descendant of {s}", .{ c.id, item.id });
        for (item.children.items) |c| {
            c.parent = null;
            c.detached = true;
        }
        item.children.clearRetainingCapacity();
        for (list) |c| {
            unlink(c);
            try link(gpa, c, item, item.children.items.len);
        }
        rowsChanged(w);
        return Value.empty;
    }
    if (eq(u8, name, "parent") or eq(u8, name, "next") or eq(u8, name, "prev") or eq(u8, name, "index")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} {s} item\"", .{ w.path, name });
        const item = try find(w, it, argv[2]);
        const p = item.parent orelse return if (name[0] == 'i') Value{ .int = 0 } else Value.empty;
        const k = std.mem.indexOfScalar(*Item, p.children.items, item).?;
        switch (name[0]) {
            'p' => if (name[1] == 'a') return .{ .str = p.id } else return if (k > 0) Value{ .str = p.children.items[k - 1].id } else Value.empty,
            'n' => return if (k + 1 < p.children.items.len) Value{ .str = p.children.items[k + 1].id } else Value.empty,
            else => return .{ .int = @intCast(k) },
        }
    }
    if (eq(u8, name, "exists")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} exists item\"", .{w.path});
        return .{ .int = @intFromBool(d.items.get(try it.str(argv[2])) != null) };
    }
    if (eq(u8, name, "delete") or eq(u8, name, "detach")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} {s} item\"", .{ w.path, name });
        const list = try findList(w, it, argv[2]);
        for (list) |item| {
            if (item == d.root) continue;
            if (name[1] == 'e' and name[2] == 'l') {
                // An item in the list can be under an item that went before.
                if (d.items.get(item.id) != item) continue;
                unlink(item);
                removeItem(w, item);
            } else {
                unlink(item);
                item.detached = true;
            }
        }
        rowsChanged(w);
        return Value.empty;
    }
    if (eq(u8, name, "move")) {
        if (argv.len != 5) return it.fail("wrong # args: should be \"{s} move item parent index\"", .{w.path});
        const item = try find(w, it, argv[2]);
        const parent = try find(w, it, argv[3]);
        if (isAncestor(item, parent)) return it.fail("Cannot insert {s} as descendant of {s}", .{ item.id, parent.id });
        var at = try indexArg(it, argv[4], parent.children.items.len);
        if (item.parent == parent) {
            const old = std.mem.indexOfScalar(*Item, parent.children.items, item).?;
            if (old < at) at -= 1;
        }
        unlink(item);
        try link(gpa, item, parent, at);
        rowsChanged(w);
        return Value.empty;
    }
    if (eq(u8, name, "set")) {
        if (argv.len < 3 or argv.len > 5) return it.fail("wrong # args: should be \"{s} set item ?column ?value??\"", .{w.path});
        const item = try find(w, it, argv[2]);
        const vals = try it.list(.{ .str = item.values });
        if (argv.len == 3) {
            var out: std.ArrayList(Value) = .empty;
            for (d.cols.items[1..], 0..) |c, k| if (k < vals.len) try out.appendSlice(a, &.{ .{ .str = c.id }, vals[k] });
            return try ztcl.value.newList(a, out.items);
        }
        const k = try columnArg(w, it, argv[3]);
        if (k == 0) return it.fail("Display column #0 cannot be set", .{});
        if (argv.len == 4) return if (k - 1 < vals.len) vals[k - 1] else Value.empty;
        var next: std.ArrayList(Value) = .empty;
        try next.appendSlice(a, vals);
        while (next.items.len < k) try next.append(a, Value.empty);
        next.items[k - 1] = argv[4];
        setOwned(gpa, &item.values, try it.str(try ztcl.value.newList(a, next.items))) catch return error.OutOfMemory;
        repaint(w);
        return Value.empty;
    }
    if (eq(u8, name, "column") or eq(u8, name, "heading")) return try cmdColumn(w, it, argv, name[0] == 'h');
    if (eq(u8, name, "selection")) return try cmdSelection(w, it, argv);
    if (eq(u8, name, "focus")) {
        if (argv.len > 3) return it.fail("wrong # args: should be \"{s} focus ?item?\"", .{w.path});
        if (argv.len == 2) return if (d.focus) |f| Value{ .str = f.id } else Value.empty;
        const t = try it.str(argv[2]);
        d.focus = if (t.len == 0) null else try find(w, it, argv[2]);
        repaint(w);
        return Value.empty;
    }
    if (eq(u8, name, "see")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"{s} see item\"", .{w.path});
        see(w, try find(w, it, argv[2]));
        return Value.empty;
    }
    if (eq(u8, name, "bbox")) {
        if (argv.len != 3 and argv.len != 4) return it.fail("wrong # args: should be \"{s} bbox item ?column?\"", .{w.path});
        const item = try find(w, it, argv[2]);
        const col: ?usize = if (argv.len == 4) try columnArg(w, it, argv[3]) else null;
        const r = itemBox(w, item, col) orelse return Value.empty;
        const vals = [_]Value{ .{ .int = r.x }, .{ .int = r.y }, .{ .int = r.w }, .{ .int = r.h } };
        return try ztcl.value.newList(a, &vals);
    }
    if (eq(u8, name, "identify")) return try cmdIdentify(w, it, argv);
    if (eq(u8, name, "tag")) return try cmdTag(w, it, argv);
    if (eq(u8, name, "xview") or eq(u8, name, "yview")) {
        sync(w);
        const y = name[0] == 'y';
        const v = if (y) &d.vy else &d.vx;
        const st: scroll.Steps = if (y) .{ .unit = @floatFromInt(rowH(w)), .page = @max(v.visible - @as(f64, @floatFromInt(rowH(w))), 1) } else .{ .unit = 10, .page = @max(v.visible - 10, 10) };
        const r = try scroll.command(w, it, argv, v, st, true);
        if (r == null) {
            const n = it.int(argv[2]) catch return it.fail("expected integer but got \"{s}\"", .{try it.str(argv[2])});
            v.moveTo(w, @as(f64, @floatFromInt(@max(n, 0))) * st.unit, scroll.step_us);
        }
        if (argv.len > 2) {
            report(w);
            repaint(w);
        }
        return r orelse Value.empty;
    }
    if (eq(u8, name, "drag")) {
        if (argv.len != 4) return it.fail("wrong # args: should be \"{s} drag column position\"", .{w.path});
        const k = try columnArg(w, it, argv[2]);
        const x = try it.int(argv[3]);
        try dragColumn(w, k, x);
        return Value.empty;
    }
    if (eq(u8, name, "drop")) return Value.empty;
    return null;
}

fn cmdColumn(w: *Widget, it: *ztcl.Interp, argv: []const Value, heading: bool) ztcl.Error!Value {
    const word = if (heading) "heading" else "column";
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} {s} column ?-option ?value??...\"", .{ w.path, word });
    const d = data(w);
    const a = it.alloc();
    const k = try columnArg(w, it, argv[2]);
    const c = d.cols.items[k];
    const names: []const []const u8 = if (heading) &.{ "-text", "-image", "-anchor", "-command", "state" } else &.{ "-width", "-minwidth", "-stretch", "-anchor", "-id" };
    const valueOf = struct {
        fn f(al: std.mem.Allocator, col: *const Column, h: bool, i: usize) !Value {
            if (h) return switch (i) {
                0 => .{ .str = col.h_text },
                1 => .{ .str = col.h_image },
                2 => .{ .str = @tagName(col.h_anchor) },
                3 => .{ .str = col.h_command },
                else => .{ .str = col.h_state },
            };
            _ = al;
            return switch (i) {
                0 => .{ .int = col.width },
                1 => .{ .int = col.minwidth },
                2 => .{ .int = @intFromBool(col.stretch) },
                3 => .{ .str = @tagName(col.anchor) },
                else => .{ .str = col.id },
            };
        }
    }.f;
    if (argv.len == 3) {
        var out: std.ArrayList(Value) = .empty;
        for (names, 0..) |n, i| try out.appendSlice(a, &.{ .{ .str = n }, try valueOf(a, c, heading, i) });
        return try ztcl.value.newList(a, out.items);
    }
    if (argv.len == 4) return try valueOf(a, c, heading, try optIndex(it, names, try it.str(argv[3])));
    // Check each value, then apply.
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        var i: usize = 3;
        while (i < argv.len) : (i += 2) {
            const n = try optIndex(it, names, try it.str(argv[i]));
            if (i + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{names[n]});
            const v = try it.str(argv[i + 1]);
            const apply = pass == 1;
            if (heading) switch (n) {
                0 => if (apply) setOwned(w.app.gpa, &c.h_text, v) catch return error.OutOfMemory,
                1 => {
                    if (v.len > 0 and w.app.images.find(v) == null) return it.fail("image \"{s}\" doesn't exist", .{v});
                    if (apply) setOwned(w.app.gpa, &c.h_image, v) catch return error.OutOfMemory;
                },
                2 => {
                    const an = try parseAnchor(it, v);
                    if (apply) c.h_anchor = an;
                },
                3 => if (apply) setOwned(w.app.gpa, &c.h_command, v) catch return error.OutOfMemory,
                else => if (apply) setOwned(w.app.gpa, &c.h_state, v) catch return error.OutOfMemory,
            } else switch (n) {
                0, 1 => {
                    const px = options.parsePixels(v, w.app.scaling) orelse return it.fail("expected integer but got \"{s}\"", .{v});
                    if (apply) {
                        if (n == 0) c.width = @max(px, 0) else c.minwidth = @max(px, 0);
                    }
                },
                2 => {
                    const b = options.parseBool(v) orelse return it.fail("expected boolean value but got \"{s}\"", .{v});
                    if (apply) c.stretch = b;
                },
                3 => {
                    const an = try parseAnchor(it, v);
                    if (apply) c.anchor = an;
                },
                else => return it.fail("Attempt to change read-only option", .{}),
            }
        }
    }
    rowsChanged(w);
    return Value.empty;
}

fn parseAnchor(it: *ztcl.Interp, v: []const u8) ztcl.Error!options.Anchor {
    return std.meta.stringToEnum(options.Anchor, v) orelse it.fail("bad anchor \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{v});
}

fn cmdSelection(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    const a = it.alloc();
    if (argv.len == 2) {
        var out: std.ArrayList(Value) = .empty;
        try selection(w, &out, d.root, a);
        return try ztcl.value.newList(a, out.items);
    }
    const ops = [_][]const u8{ "add", "remove", "set", "toggle" };
    const op = try it.str(argv[2]);
    var which: ?usize = null;
    for (ops, 0..) |o, i| if (std.mem.eql(u8, o, op)) {
        which = i;
    };
    if (which == null or argv.len != 4) return it.fail("wrong # args: should be \"{s} selection ?add|remove|set|toggle items?\"", .{w.path});
    const list = try findList(w, it, argv[3]);
    switch (which.?) {
        0 => for (list) |x| setSel(w, x, true),
        1 => for (list) |x| setSel(w, x, false),
        2 => {
            var iter = d.items.valueIterator();
            while (iter.next()) |v| {
                const on = std.mem.indexOfScalar(*Item, list, v.*) != null;
                setSel(w, v.*, on);
            }
        },
        else => for (list) |x| setSel(w, x, !x.sel),
    }
    return Value.empty;
}

// ---- The places of the rows ----

/// The box of an item, or of one of its cells, in the window, with no
/// animation. An item that does not show, or a row outside the window,
/// gives null.
fn itemBox(w: *Widget, item: *Item, col: ?usize) ?geom.Rect {
    const d = data(w);
    sync(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const k = rowIndex(w, item, a) orelse return null;
    const r = rowsRect(w);
    const rh = rowH(w);
    const y = r.y + @as(i32, @intCast(k)) * rh - num.pxRound(d.vy.pos);
    if (y + rh <= r.y or y >= r.y + r.h) return null;
    const xoff = num.pxRound(d.vx.pos);
    const cols = shownCols(w, a) catch return null;
    if (col) |c| {
        const pos = std.mem.indexOfScalar(usize, cols, c) orelse return null;
        return .{ .x = r.x + columnX(w, cols, pos) - xoff, .y = y, .w = d.cols.items[c].width, .h = rh };
    }
    return .{ .x = r.x - xoff, .y = y, .w = totalWidth(w, cols), .h = rh };
}

fn see(w: *Widget, item: *Item) void {
    const d = data(w);
    // `see` opens the ancestors of the item.
    var p = item.parent;
    while (p) |x| : (p = x.parent) {
        if (x != d.root) setOpen(w, x, true);
    }
    sync(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const k = rowIndex(w, item, arena.allocator()) orelse return;
    const rh: f64 = @floatFromInt(rowH(w));
    const top = @as(f64, @floatFromInt(k)) * rh;
    const vis = d.vy.visible;
    if (top < d.vy.pos) {
        d.vy.moveTo(w, top, scroll.step_us);
    } else if (top + rh > d.vy.pos + vis) {
        d.vy.moveTo(w, top + rh - vis, scroll.step_us);
    }
    report(w);
    repaint(w);
}

const Region = enum { nothing, heading, separator, tree, cell };

const Hit = struct { region: Region = .nothing, item: ?*Item = null, col: ?usize = null, shown_col: usize = 0, x_in: i32 = 0, depth: i32 = 0 };

fn hitTest(w: *Widget, x: i64, y: i64) Hit {
    const d = data(w);
    sync(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const c = content(w);
    var h: Hit = .{};
    const cols = shownCols(w, a) catch return h;
    const xoff = num.pxRound(d.vx.pos);
    const cx: i64 = x - c.x + xoff;
    // The column under the point, and a heading border near it.
    var edge: i64 = 0;
    for (cols, 0..) |k, i| {
        const cw = d.cols.items[k].width;
        if (cx >= edge and cx < edge + cw) {
            h.col = k;
            h.shown_col = i;
            h.x_in = @intCast(cx - edge);
        }
        edge += cw;
    }
    const hh = headH(w);
    if (hh > 0 and y >= c.y and y < c.y + hh) {
        var e: i64 = 0;
        for (cols, 0..) |k, i| {
            e += d.cols.items[k].width;
            if (@abs(cx - e) <= halo) {
                h.region = .separator;
                h.col = k;
                h.shown_col = i;
                return h;
            }
        }
        if (h.col != null) h.region = .heading;
        return h;
    }
    const r = rowsRect(w);
    if (y < r.y or y >= r.y + r.h or h.col == null) return h;
    const rs = rows(w, a) catch return h;
    const ty = y - r.y + num.pxRound(d.vy.pos);
    if (ty < 0) return h;
    const k: usize = @intCast(@divTrunc(ty, rowH(w)));
    if (k >= rs.len) return h;
    h.item = rs[k];
    h.depth = depth(rs[k]);
    h.region = if (h.col.? == 0) .tree else .cell;
    return h;
}

fn cmdIdentify(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const a = it.alloc();
    if (argv.len == 4) {
        // The form of Tk 8.5: `identify x y`.
        const h = hitTest(w, try it.int(argv[2]), try it.int(argv[3]));
        return switch (h.region) {
            .heading, .separator => .{ .str = try std.fmt.allocPrint(a, "heading #{d}", .{shownNumber(w, h)}) },
            .tree, .cell => .{ .str = try std.fmt.allocPrint(a, "item {s} column #{d}", .{ h.item.?.id, shownNumber(w, h) }) },
            .nothing => .{ .str = "nothing" },
        };
    }
    if (argv.len != 5) return it.fail("wrong # args: should be \"{s} identify command x y\"", .{w.path});
    const cmds = [_][]const u8{ "region", "item", "column", "row", "element" };
    const t = try it.str(argv[2]);
    var which: ?usize = null;
    for (cmds, 0..) |c, i| if (std.mem.eql(u8, c, t)) {
        which = i;
    };
    if (which == null) return it.fail("bad command \"{s}\": must be region, item, column, row, or element", .{t});
    const h = hitTest(w, try it.int(argv[3]), try it.int(argv[4]));
    switch (which.?) {
        0 => return .{ .str = @tagName(h.region) },
        1, 3 => return if (h.item) |x| Value{ .str = x.id } else Value.empty,
        2 => return if (h.col != null) Value{ .str = try std.fmt.allocPrint(a, "#{d}", .{shownNumber(w, h)}) } else Value.empty,
        else => {
            const item = h.item orelse return Value.empty;
            if (h.col.? != 0) return .{ .str = "text" };
            const ind = h.depth * indent;
            _ = item;
            if (h.x_in >= ind and h.x_in < ind + indent) return .{ .str = "Treeitem.indicator" };
            if (h.x_in < ind) return .{ .str = "padding" };
            return .{ .str = "text" };
        },
    }
}

/// The `#n` number of the column of a hit.
fn shownNumber(w: *Widget, h: Hit) usize {
    return if (showTree(w)) h.shown_col else h.shown_col + 1;
}

fn dragColumn(w: *Widget, k: usize, x: i64) ztcl.Error!void {
    const d = data(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const cols = try shownCols(w, arena.allocator());
    const pos = std.mem.indexOfScalar(usize, cols, k) orelse return;
    const c = content(w);
    const left = c.x + columnX(w, cols, pos) - num.pxRound(d.vx.pos);
    const col = d.cols.items[k];
    col.width = @intCast(@max(x - left, col.minwidth));
    rowsChanged(w);
}

// ---- Tags ----

fn cmdTag(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(w);
    const a = it.alloc();
    const gpa = w.app.gpa;
    if (argv.len < 3) return it.fail("wrong # args: should be \"{s} tag command ?arg arg...?\"", .{w.path});
    const ops = [_][]const u8{ "add", "bind", "configure", "has", "names", "remove" };
    const op = try it.str(argv[2]);
    var which: ?usize = null;
    for (ops, 0..) |o, i| if (std.mem.eql(u8, o, op)) {
        which = i;
    };
    const k = which orelse return it.fail("bad command \"{s}\": must be add, bind, configure, has, names, or remove", .{op});
    switch (k) {
        0 => {
            if (argv.len != 5) return it.fail("wrong # args: should be \"{s} tag add tagName items\"", .{w.path});
            const tn = try it.str(argv[3]);
            _ = try ensureTag(w, tn);
            for (try findList(w, it, argv[4])) |item| {
                if (hasTag(it, item, tn)) continue;
                var l: std.ArrayList(Value) = .empty;
                try l.appendSlice(a, try it.list(.{ .str = item.tags }));
                try l.append(a, .{ .str = tn });
                setOwned(gpa, &item.tags, try it.str(try ztcl.value.newList(a, l.items))) catch return error.OutOfMemory;
            }
            repaint(w);
            return Value.empty;
        },
        1 => {
            if (argv.len < 4 or argv.len > 6) return it.fail("wrong # args: should be \"{s} tag bind tagName ?sequence? ?script?\"", .{w.path});
            const tn = try it.str(argv[3]);
            if (argv.len == 4) {
                const pats = try d.bindings.list(tn, a);
                const vals = try a.alloc(Value, pats.len);
                for (pats, vals) |p, *sv| {
                    var b: [128]u8 = undefined;
                    sv.* = .{ .str = try a.dupe(u8, bind.formatPattern(p, &b)) };
                }
                return try ztcl.value.wrapList(a, vals);
            }
            const p = try bind.parsePattern(it, try it.str(argv[4]));
            switch (p.type) {
                .key_press, .key_release, .button_press, .button_release, .motion, .virtual => {},
                else => return it.fail("unsupported event {s}\nonly key, button, motion, and virtual events supported", .{try it.str(argv[4])}),
            }
            if (argv.len == 5) return .{ .str = try a.dupe(u8, d.bindings.get(tn, p) orelse "") };
            _ = try ensureTag(w, tn);
            d.bindings.set(tn, p, try it.str(argv[5])) catch return error.OutOfMemory;
            return Value.empty;
        },
        2 => {
            if (argv.len < 4) return it.fail("wrong # args: should be \"{s} tag configure tagName ?-option ?value??...\"", .{w.path});
            const t = try ensureTag(w, try it.str(argv[3]));
            if (argv.len == 4) {
                var out: std.ArrayList(Value) = .empty;
                for (tag_opts, 0..) |n, i| try out.appendSlice(a, &.{ .{ .str = n }, .{ .str = tagSlot(t, i).* } });
                return try ztcl.value.newList(a, out.items);
            }
            if (argv.len == 5) return .{ .str = tagSlot(t, try optIndex(it, &tag_opts, try it.str(argv[4]))).* };
            var i: usize = 4;
            while (i < argv.len) : (i += 2) {
                const n = try optIndex(it, &tag_opts, try it.str(argv[i]));
                if (i + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{tag_opts[n]});
                const v = try it.str(argv[i + 1]);
                        if ((n == 3 or n == 4) and v.len > 0 and geom.Color.parseTk(v) == null) return it.fail("unknown color name \"{s}\"", .{v});
            }
            i = 4;
            while (i < argv.len) : (i += 2) {
                const n = optIndex(it, &tag_opts, try it.str(argv[i])) catch unreachable;
                setOwned(gpa, tagSlot(t, n), try it.str(argv[i + 1])) catch return error.OutOfMemory;
            }
            repaint(w);
            return Value.empty;
        },
        3 => {
            if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} tag has tagName ?item?\"", .{w.path});
            const tn = try it.str(argv[3]);
            if (argv.len == 5) return .{ .int = @intFromBool(hasTag(it, try find(w, it, argv[4]), tn)) };
            var out: std.ArrayList(Value) = .empty;
            try tagged(it, d.root, tn, &out, a);
            return try ztcl.value.newList(a, out.items);
        },
        4 => {
            if (argv.len != 3) return it.fail("wrong # args: should be \"{s} tag names\"", .{w.path});
            const out = try a.alloc(Value, d.tags.items.len);
            for (d.tags.items, out) |t, *o| o.* = .{ .str = t.name };
            return try ztcl.value.newList(a, out);
        },
        else => {
            if (argv.len != 4 and argv.len != 5) return it.fail("wrong # args: should be \"{s} tag remove tagName ?items?\"", .{w.path});
            const tn = try it.str(argv[3]);
            if (argv.len == 4) {
                var iter = d.items.valueIterator();
                while (iter.next()) |v| try dropTag(w, it, v.*, tn);
            } else for (try findList(w, it, argv[4])) |item| try dropTag(w, it, item, tn);
            repaint(w);
            return Value.empty;
        },
    }
}

fn tagged(it: *ztcl.Interp, item: *Item, tn: []const u8, out: *std.ArrayList(Value), a: std.mem.Allocator) !void {
    for (item.children.items) |c| {
        if (hasTag(it, c, tn)) try out.append(a, .{ .str = c.id });
        try tagged(it, c, tn, out, a);
    }
}

fn dropTag(w: *Widget, it: *ztcl.Interp, item: *Item, tn: []const u8) ztcl.Error!void {
    if (!hasTag(it, item, tn)) return;
    const a = it.alloc();
    var l: std.ArrayList(Value) = .empty;
    for (try it.list(.{ .str = item.tags })) |v| if (!std.mem.eql(u8, try it.str(v), tn)) try l.append(a, v);
    setOwned(w.app.gpa, &item.tags, try it.str(try ztcl.value.newList(a, l.items))) catch return error.OutOfMemory;
}

// ---- Events of the tags ----

/// The bindings of the tags of an item run before the bindings of the
/// widget: the item under the pointer for a pointer event, and the focus
/// item for a key or a virtual event.
fn tagEvent(w: *Widget, ev: *const bind.WidgetEvent) void {
    if (!w.alive() or w.data == null) return;
    const d = data(w);
    switch (ev.type) {
        .motion, .leave => {
            const h: ?*Item = if (ev.type == .leave) null else hitTest(w, ev.x, ev.y).item;
            if (h != d.hover) {
                d.hover = h;
                repaint(w);
            }
        },
        else => {},
    }
    const item = switch (ev.type) {
        .button_press, .button_release, .motion => hitTest(w, ev.x, ev.y).item,
        .key_press, .key_release, .virtual => d.focus,
        else => null,
    } orelse return;
    const it = w.app.it;
    const words = it.list(.{ .str = item.tags }) catch return;
    var names: std.ArrayList([]const u8) = .empty;
    const a = it.alloc();
    for (words) |v| names.append(a, it.str(v) catch continue) catch return;
    if (names.items.len > 0) bind.runTags(w.app, &d.bindings, names.items, ev);
}

// ---- Paint ----

fn paintTree(w: *Widget, b: *scene.Builder) anyerror!void {
    const app = w.app;
    const st = anim.shown(app, w);
    try paint.box(w, b, st);
    sync(w);
    report(w);
    const d = data(w);
    const c = content(w);
    if (c.w <= 0 or c.h <= 0) return;
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cols = try shownCols(w, a);
    const xoff = num.pxRound(d.vx.shown(w));
    const first_quad = b.scene.quads.items.len;
    if (d.vy.moving or d.vx.moving) {
        if (app.part_move != .blocked) app.part_move = .mixed;
    }
    // The heading row.
    const hh = headH(w);
    if (hh > 0) {
        const hs = headingStyle(w);
        b.pushClip(.{ .x = c.x, .y = c.y, .w = c.w, .h = hh });
        try paint.styledBox(b, .{ .x = c.x, .y = c.y, .w = c.w, .h = hh }, &hs);
        const sep = app.styles.compute(w, "separator", &w.style, app.env);
        var x = c.x - xoff;
        for (cols) |k| {
            const col = d.cols.items[k];
            const ins = paint.insets(&hs);
            const r: geom.Rect = .{ .x = x + ins.left, .y = c.y + ins.top, .w = col.width - ins.horizontal(), .h = hh - ins.vertical() };
            try paint.label(w, b, r, col.h_text, &hs, col.h_anchor, .left);
            x += col.width;
            try b.box(.{ .x = x - 1, .y = c.y + 4, .w = 1, .h = @max(hh - 8, 1) }, .{ .fill = sep.background });
        }
        try b.box(.{ .x = c.x, .y = c.y + hh - 1, .w = c.w, .h = 1 }, .{ .fill = sep.background });
        b.popClip();
    }
    const r = rowsRect(w);
    b.pushClip(r);
    defer b.popClip();
    if (d.root.children.items.len == 0) {
        const e = options.get(w, "-emptytext");
        if (e.set and e.text.len > 0) {
            const es = app.styles.compute(w, "empty", st, app.env);
            try paint.label(w, b, r, e.text, &es, .center, .center);
        }
        try scroll.paintDrag(w, b, &d.vy, first_quad, 1);
        return;
    }
    var p: Painter = .{
        .w = w,
        .b = b,
        .a = a,
        .cols = cols,
        .r = r,
        .xoff = xoff,
        .rh = rowH(w),
        .ist = itemStyle(w),
        .sel = paint.partStyle(w, "selection", &d.sel_anim).style,
        .hov = app.styles.compute(w, "hover", &w.style, app.env),
        .ind = app.styles.compute(w, "indicator", &w.style, app.env),
        .fg = st.color,
        .y = r.y - num.pxRound(d.vy.shown(w)),
    };
    try p.children(d.root, 1);
    try scroll.paintDrag(w, b, &d.vx, first_quad, 0);
    try scroll.paintDrag(w, b, &d.vy, first_quad, 1);
}

const Painter = struct {
    w: *Widget,
    b: *scene.Builder,
    a: std.mem.Allocator,
    cols: []const usize,
    r: geom.Rect,
    xoff: i32,
    rh: i32,
    ist: style_mod.Style,
    sel: style_mod.Style,
    hov: style_mod.Style,
    ind: style_mod.Style,
    fg: geom.Color,
    /// The top of the next row.
    y: i32,

    /// Paints the children of an item, with the shown fraction `f` of
    /// the block of the children.
    fn children(p: *Painter, item: *Item, f: f32) anyerror!void {
        for (item.children.items) |c| {
            if (p.y >= p.r.y + p.r.h) return;
            try p.row(c);
            p.y += p.rh;
            const cf = openShown(p.w, c);
            if (cf <= 0 or c.children.items.len == 0) continue;
            if (cf >= 1) {
                try p.children(c, 1);
                continue;
            }
            // The block of the children shows its top part, and the rows
            // after it move up by the hidden part.
            const top = p.y;
            const full = blockHeight(c) * p.rh;
            const shown_h: i32 = @intFromFloat(@round(@as(f32, @floatFromInt(full)) * cf));
            p.b.pushClip(.{ .x = p.r.x, .y = top, .w = p.r.w, .h = shown_h });
            try p.children(c, cf);
            p.b.popClip();
            p.y = top + shown_h;
        }
        _ = f;
    }

    fn row(p: *Painter, item: *Item) !void {
        const w = p.w;
        const app = w.app;
        const d = data(w);
        if (p.y + p.rh <= p.r.y) return;
        const full_w = @max(totalWidth(w, p.cols), p.r.w);
        const rect: geom.Rect = .{ .x = p.r.x - p.xoff, .y = p.y, .w = full_w, .h = p.rh };
        const look = lookOf(w, item);
        var fg = look.fg orelse p.fg;
        if (look.bg) |bg| try p.b.box(rect, .{ .fill = bg });
        if (item.sel) {
            try paint.styledBox(p.b, rect, &p.sel);
            fg = p.sel.color;
        } else if (d.hover == item) {
            try paint.styledBox(p.b, rect, &p.hov);
        }
        if (d.focus == item and w.state.focus) {
            try p.b.box(rect, .{ .border = .{ 1, 1, 1, 1 }, .border_color = p.ind.color, .radii = .{ 4, 4, 4, 4 } });
        }
        var font = w.style.font;
        if (look.font) |fname| font = font_mod.Fonts.parseTk(fname, w.style.font, app.scaling) orelse font;
        var ts = p.ist;
        ts.color = fg;
        ts.font = font;
        const vals = app.it.list(.{ .str = item.values }) catch &.{};
        var x = p.r.x - p.xoff;
        for (p.cols) |k| {
            const col = d.cols.items[k];
            var cell: geom.Rect = .{ .x = x + p.ist.padding.left, .y = p.y, .w = col.width - p.ist.padding.left - p.ist.padding.right, .h = p.rh };
            var txt: []const u8 = "";
            if (k == 0) {
                const lvl = depth(item);
                const ax = x + lvl * indent;
                if (item.children.items.len > 0) try p.arrow(ax + @divTrunc(indent - arrow_size, 2) + 2, p.y + @divTrunc(p.rh - arrow_size, 2), openShown(w, item), fg);
                cell.x = ax + indent;
                cell.w = col.width - lvl * indent - indent - p.ist.padding.right;
                if (item.image.len > 0) if (app.images.find(item.image)) |ph| {
                    const ih: i32 = @intCast(ph.height);
                    try label.drawPhoto(p.b, &app.atlas, ph, cell.x, p.y + @divTrunc(p.rh - ih, 2), 1);
                    cell.x += @as(i32, @intCast(ph.width)) + 4;
                    cell.w -= @as(i32, @intCast(ph.width)) + 4;
                };
                txt = item.text;
            } else if (k - 1 < vals.len) {
                txt = app.it.str(vals[k - 1]) catch "";
            }
            if (txt.len > 0 and cell.w > 0) {
                p.b.pushClip(.{ .x = x, .y = p.y, .w = col.width, .h = p.rh });
                try paint.label(w, p.b, cell, txt, &ts, if (k == 0) .w else col.anchor, .left);
                p.b.popClip();
            }
            x += col.width;
        }
    }

    /// The arrow of an item with children: a chevron that points right,
    /// turned by 90 degrees times the shown fraction of its children.
    fn arrow(p: *Painter, x: i32, y: i32, f: f32, color: geom.Color) !void {
        const cx: f32 = @as(f32, @floatFromInt(x)) + @as(f32, arrow_size) / 2.0;
        const cy: f32 = @as(f32, @floatFromInt(y)) + @as(f32, arrow_size) / 2.0;
        const ang = f * std.math.pi / 2.0;
        const co = @cos(ang);
        const si = @sin(ang);
        const base_pts = [_][2]f32{ .{ -2, -4 }, .{ 2.5, 0 }, .{ -2, 4 }, .{ -2, 2.2 }, .{ 0.5, 0 }, .{ -2, -2.2 } };
        var pts: [6]path.Pt = undefined;
        for (base_pts, 0..) |q, i| pts[i] = .{ .x = cx + q[0] * co - q[1] * si, .y = cy + q[0] * si + q[1] * co };
        var sh: path.Shape = .{};
        defer sh.deinit(p.b.gpa);
        try sh.contour(p.b.gpa, &pts);
        try paint.fillShape(p.b, &sh, color, 0.75);
    }
};

/// The count of rows under an open item, in the end state.
fn blockHeight(item: *const Item) i32 {
    var n: i32 = 0;
    for (item.children.items) |c| {
        n += 1;
        if (c.open) n += blockHeight(c);
    }
    return n;
}

// ---- The class bindings ----

const Action = enum { press, shift, control, double, motion, release, leave, key, toggle };

/// `::ztk::priv::treeview action path ?args?`
fn cmdTreeview(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 3) return it.wrongArgs("::ztk::priv::treeview action window ?arg ...?");
    const act = std.meta.stringToEnum(Action, try it.str(argv[1])) orelse return it.fail("bad action", .{});
    const w = app.find(try it.str(argv[2])) orelse return Value.empty;
    if (w.class.paint != paintTree) return Value.empty;
    const d = data(w);
    const disabled = w.state.disabled;
    switch (act) {
        .press, .shift, .control, .double, .motion, .release => {
            if (argv.len < 5) return Value.empty;
            const x = try it.int(argv[3]);
            const y = try it.int(argv[4]);
            if (act == .motion) {
                if (d.drag_col) |k| try dragColumn(w, k, x);
                return Value.empty;
            }
            if (act == .release) {
                d.drag_col = null;
                const pk = d.pressed_heading orelse return Value.empty;
                d.pressed_heading = null;
                const h = hitTest(w, x, y);
                if (h.region == .heading and h.col != null and h.col.? == pk) {
                    const cmd = d.cols.items[pk].h_command;
                    if (cmd.len > 0 and !disabled) {
                        const script = try it.alloc().dupe(u8, cmd);
                        _ = try it.eval(script);
                    }
                }
                return Value.empty;
            }
            if (disabled) return Value.empty;
            if (focus.accepts(w)) focus.set(app, w);
            const h = hitTest(w, x, y);
            switch (h.region) {
                .separator => d.drag_col = h.col,
                .heading => d.pressed_heading = h.col,
                .tree, .cell => {
                    const item = h.item.?;
                    const on_arrow = h.region == .tree and h.x_in >= h.depth * indent and h.x_in < (h.depth + 1) * indent and item.children.items.len > 0;
                    if (act == .double) {
                        try toggle(w, item);
                        return Value.empty;
                    }
                    if (on_arrow and act == .press) {
                        try toggle(w, item);
                        return Value.empty;
                    }
                    try choose(w, item, switch (act) {
                        .shift => .extend,
                        .control => .toggle,
                        else => .set,
                    });
                },
                .nothing => {},
            }
        },
        .leave => {
            if (d.hover != null) {
                d.hover = null;
                repaint(w);
            }
        },
        .toggle => {
            if (disabled) return Value.empty;
            if (d.focus) |f| try toggle(w, f);
        },
        .key => {
            if (argv.len < 4 or disabled) return Value.empty;
            const key = try it.str(argv[3]);
            const extend = argv.len > 4;
            try keynav(w, key, extend);
        },
    }
    return Value.empty;
}

const Choose = enum { set, extend, toggle };

/// A click on an item: the selection of the mode, the focus, and the anchor.
fn choose(w: *Widget, item: *Item, how: Choose) ztcl.Error!void {
    const d = data(w);
    d.focus = item;
    const mode = selectMode(w);
    repaint(w);
    if (mode == 0) return;
    if (mode == 1 or how == .set) {
        clearSel(w);
        setSel(w, item, true);
        d.anchor = item;
        return;
    }
    if (how == .toggle) {
        setSel(w, item, !item.sel);
        d.anchor = item;
        return;
    }
    // A range from the anchor to the item, in the order of the rows.
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const rs = rows(w, arena.allocator()) catch return error.OutOfMemory;
    const from = (if (d.anchor) |an| std.mem.indexOfScalar(*Item, rs, an) else null) orelse {
        clearSel(w);
        setSel(w, item, true);
        d.anchor = item;
        return;
    };
    const to = std.mem.indexOfScalar(*Item, rs, item) orelse return;
    clearSel(w);
    for (rs[@min(from, to) .. @max(from, to) + 1]) |x| setSel(w, x, true);
}

/// Opens or closes an item, with `<<TreeviewOpen>>` before an open and
/// `<<TreeviewClose>>` after a close, as the bindings of `wish` do.
fn toggle(w: *Widget, item: *Item) ztcl.Error!void {
    const d = data(w);
    const it = w.app.it;
    d.focus = item;
    const id = try it.alloc().dupe(u8, item.id);
    const path_s = try it.alloc().dupe(u8, w.path);
    if (!item.open) {
        _ = try it.eval(try std.fmt.allocPrint(it.alloc(), "event generate {{{s}}} <<TreeviewOpen>>", .{path_s}));
        if (!w.alive()) return;
        const again = data(w).items.get(id) orelse return;
        setOpen(w, again, true);
    } else {
        setOpen(w, item, false);
        _ = try it.eval(try std.fmt.allocPrint(it.alloc(), "event generate {{{s}}} <<TreeviewClose>>", .{path_s}));
    }
}

fn keynav(w: *Widget, key: []const u8, extend: bool) ztcl.Error!void {
    const d = data(w);
    var arena = std.heap.ArenaAllocator.init(w.app.gpa);
    defer arena.deinit();
    const rs = rows(w, arena.allocator()) catch return error.OutOfMemory;
    if (rs.len == 0) return;
    const cur = d.focus;
    const at = if (cur) |c| std.mem.indexOfScalar(*Item, rs, c) else null;
    const eq = std.mem.eql;
    var next: ?*Item = null;
    if (eq(u8, key, "up")) {
        next = if (at) |k| rs[if (k > 0) k - 1 else 0] else rs[0];
    } else if (eq(u8, key, "down")) {
        next = if (at) |k| rs[@min(k + 1, rs.len - 1)] else rs[0];
    } else if (eq(u8, key, "left")) {
        const c = cur orelse return;
        if (c.open and c.children.items.len > 0) {
            try toggle(w, c);
            return;
        }
        if (c.parent) |p| if (p != d.root) {
            next = p;
        };
    } else if (eq(u8, key, "right")) {
        const c = cur orelse return;
        if (c.children.items.len > 0) {
            if (!c.open) {
                try toggle(w, c);
                return;
            }
            next = c.children.items[0];
        }
    } else if (eq(u8, key, "home")) {
        next = rs[0];
    } else if (eq(u8, key, "end")) {
        next = rs[rs.len - 1];
    }
    const n = next orelse return;
    d.focus = n;
    see(w, n);
    if (selectMode(w) != 0) try choose(w, n, if (extend and selectMode(w) == 2) .extend else .set);
}

pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("ttk::treeview", widget.classCommand(&class));
    try app.classes.put(app.gpa, "ttk::treeview", &class);
    try it.register("ztk::priv::treeview", cmdTreeview);
    _ = try it.eval(
        \\bind Treeview <Button-1> {::ztk::priv::treeview press %W %x %y}
        \\bind Treeview <Shift-Button-1> {::ztk::priv::treeview shift %W %x %y}
        \\bind Treeview <Control-Button-1> {::ztk::priv::treeview control %W %x %y}
        \\bind Treeview <Double-Button-1> {::ztk::priv::treeview double %W %x %y}
        \\bind Treeview <B1-Motion> {::ztk::priv::treeview motion %W %x %y}
        \\bind Treeview <ButtonRelease-1> {::ztk::priv::treeview release %W %x %y}
        \\bind Treeview <Leave> {::ztk::priv::treeview leave %W}
        \\bind Treeview <Key-Up> {::ztk::priv::treeview key %W up}
        \\bind Treeview <Key-Down> {::ztk::priv::treeview key %W down}
        \\bind Treeview <Shift-Key-Up> {::ztk::priv::treeview key %W up extend}
        \\bind Treeview <Shift-Key-Down> {::ztk::priv::treeview key %W down extend}
        \\bind Treeview <Key-Left> {::ztk::priv::treeview key %W left}
        \\bind Treeview <Key-Right> {::ztk::priv::treeview key %W right}
        \\bind Treeview <Key-Home> {::ztk::priv::treeview key %W home}
        \\bind Treeview <Key-End> {::ztk::priv::treeview key %W end}
        \\bind Treeview <Key-Prior> {%W yview scroll -1 pages}
        \\bind Treeview <Key-Next> {%W yview scroll 1 pages}
        \\bind Treeview <Key-Return> {::ztk::priv::treeview toggle %W}
        \\bind Treeview <Key-space> {if {[%W focus] ne ""} {%W selection toggle [list [%W focus]]}}
        \\bind Treeview <MouseWheel> {%W yview scroll [expr {-%D / 40.0}] units}
        \\bind Treeview <Shift-MouseWheel> {%W xview scroll [expr {-%D / 4.0}] units}
        \\bind Treeview <Button-4> {%W yview scroll -5 units}
        \\bind Treeview <Button-5> {%W yview scroll 5 units}
    );
}

/// The shown fraction of the children of an item, for the tests.
pub fn openShownOf(w: *Widget, id: []const u8) f32 {
    const item = data(w).items.get(id) orelse return 0;
    return openShown(w, item);
}
