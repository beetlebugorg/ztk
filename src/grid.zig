//! The `grid` geometry manager. The solver works on one axis. It gives
//! each line its minimum size (the `-minsize`, or the largest item of
//! one line plus the `-pad`), makes the lines of a uniform group
//! proportional to their weights, adds the extra space of items that span
//! lines (in the order of the span, by weight), and then fits the layout
//! to the space that the container has. Extra space goes to the lines by
//! weight. Missing space comes from the lines by weight, and a line that
//! reaches its `-minsize` leaves the group. Each division of space uses
//! the running sum of the weights, so the integer remainder goes to the
//! later lines. The rules for the rounding come from runs of `wish`, and
//! `tools/oracle-grid.tcl` compares both on random layouts.
//! The command code keeps one `Container` for each container widget and
//! one `Cell` for each widget that grid manages or has managed.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const layout = @import("layout.zig");
const options = @import("options.zig");
const widget_mod = @import("widget.zig");
const App = @import("app.zig").App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

pub const Sticky = packed struct(u8) {
    n: bool = false,
    e: bool = false,
    s: bool = false,
    w: bool = false,
    _pad: u4 = 0,
};

/// The grid data of one managed widget.
pub const Cell = struct {
    column: u16 = 0,
    row: u16 = 0,
    columnspan: u16 = 1,
    rowspan: u16 = 1,
    padx: [2]i32 = .{ 0, 0 },
    pady: [2]i32 = .{ 0, 0 },
    ipadx: i32 = 0,
    ipady: i32 = 0,
    sticky: Sticky = .{},
    in: *Widget,
    /// False after `grid remove`: the cell keeps its options for the next `grid` of the widget.
    managed: bool = true,
};

/// One row or one column of a container.
pub const Line = struct {
    minsize: i32 = 0,
    pad: i32 = 0,
    weight: i32 = 0,
    /// Owned by the allocator of the container, or the empty literal.
    uniform: []const u8 = "",
};

/// The size that one widget needs on one axis, with its padding.
pub const Item = struct { first: u16, span: u16, size: i32 };

const stack_lines = 32;

fn ceilDiv(a: i32, b: i32) i32 {
    return @divTrunc(a + b - 1, b);
}

/// Adds `extra` to `size[0..n]`. The share of a line is the running sum
/// of the weights times `extra`, divided by the total weight. With a total
/// weight of 0, each line has the weight 1.
fn spread(size: []i32, lines: []const Line, extra: i32) void {
    var total: i64 = 0;
    for (lines) |l| total += l.weight;
    const equal = total == 0;
    if (equal) total = @intCast(lines.len);
    var run: i64 = 0;
    var done: i64 = 0;
    for (size, lines) |*s, l| {
        run += if (equal) 1 else l.weight;
        const cut = @divTrunc(run * extra, total);
        s.* += @intCast(cut - done);
        done = cut;
    }
}

fn uniformPass(size: []i32, lines: []const Line) void {
    for (lines, 0..) |l, i| {
        if (l.uniform.len == 0) continue;
        // Handle each group once: at its first line.
        var seen = false;
        for (lines[0..i]) |p| if (std.mem.eql(u8, p.uniform, l.uniform)) {
            seen = true;
        };
        if (seen) continue;
        var k: i32 = 0;
        for (lines, 0..) |m, j| if (std.mem.eql(u8, m.uniform, l.uniform)) {
            k = @max(k, ceilDiv(size[j], @max(m.weight, 1)));
        };
        for (lines, 0..) |m, j| if (std.mem.eql(u8, m.uniform, l.uniform)) {
            size[j] = num.px(@as(i64, k) * @max(m.weight, 1));
        };
    }
}

/// The solver for one axis. It is a pure function. `offsets[i]` is the
/// start of line i, and `offsets[lines.len]` is the end. With `available`
/// null, the result is the minimum layout. With `available`, the layout
/// grows or shrinks to that size, as far as the weights allow. A
/// container with at most 32 lines needs no allocation.
pub fn solve(gpa: std.mem.Allocator, lines: []const Line, items: []const Item, available: ?i32, offsets: []i32) !void {
    const n = lines.len;
    std.debug.assert(offsets.len == n + 1);
    var stack: [stack_lines * 2]i32 = undefined;
    var heap: []i32 = &.{};
    defer if (heap.len != 0) gpa.free(heap);
    var size: []i32 = undefined;
    var has_item: []i32 = undefined;
    if (n <= stack_lines) {
        size = stack[0..n];
        has_item = stack[stack_lines..][0..n];
    } else {
        heap = try gpa.alloc(i32, n * 2);
        size = heap[0..n];
        has_item = heap[n..];
    }
    // Step 1: the minimum of each line.
    for (size, has_item, lines) |*s, *h, l| {
        s.* = num.px(@max(l.minsize, 0));
        h.* = 0;
    }
    var max_span: u16 = 1;
    for (items) |it| {
        max_span = @max(max_span, it.span);
        if (it.span == 1) has_item[it.first] = @max(has_item[it.first], num.px(it.size));
    }
    for (size, has_item, lines) |*s, h, l| {
        if (h > 0) s.* = @max(s.*, num.add(h, l.pad));
    }
    // Step 2: the uniform groups.
    uniformPass(size, lines);
    // Step 3: the items that span lines. `base` is the layout of the
    // single items, as end offsets. `end` starts as `base` and rises to
    // meet each span, the smaller spans first and, for equal spans, in the
    // order of the items.
    if (max_span > 1) {
        var base: []i32 = undefined;
        var end: []i32 = undefined;
        var buf: [stack_lines * 2]i32 = undefined;
        var buf_heap: []i32 = &.{};
        defer if (buf_heap.len != 0) gpa.free(buf_heap);
        if (n <= stack_lines) {
            base = buf[0..n];
            end = buf[stack_lines..][0..n];
        } else {
            buf_heap = try gpa.alloc(i32, n * 2);
            base = buf_heap[0..n];
            end = buf_heap[n..];
        }
        var run_sum: i32 = 0;
        for (size, base, end) |sz, *b, *e| {
            run_sum = num.add(run_sum, sz);
            b.* = run_sum;
            e.* = run_sum;
        }
        var span: u16 = 2;
        while (span <= max_span) : (span += 1) {
            for (items) |it| {
                if (it.span != span) continue;
                raiseSpan(lines, base, end, it);
            }
        }
        var prev: i32 = 0;
        for (size, end) |*sz, e| {
            sz.* = e - prev;
            prev = e;
        }
    }
    // The sum of all lines stays in the pixel range, so each offset below does too.
    var total: i32 = 0;
    for (size) |*s| {
        s.* = @min(s.*, num.max_px - total);
        total += s.*;
    }
    // Step 4: fit to the space of the container.
    if (available) |avail| {
        const diff = num.px(avail) - total;
        if (diff > 0) {
            growIfWeighted(size, lines, diff);
        } else if (diff < 0) try shrink(gpa, size, lines, -diff);
    }
    offsets[0] = 0;
    for (size, 0..) |s, i| offsets[i + 1] = num.add(offsets[i], s);
}

/// Raises the end offsets of the lines of one item that spans lines, so
/// that the item fits. The extra space goes to the lines by weight, or
/// equally when all their weights are 0. The proposal for each line starts
/// from the layout of the single items.
fn raiseSpan(lines: []const Line, base: []const i32, end: []i32, it: Item) void {
    const f: usize = it.first;
    const e = f + it.span - 1;
    if (e >= base.len) return;
    const start_end: i32 = if (f > 0) end[f - 1] else 0;
    if (end[e] - start_end >= it.size) return;
    const base_start: i32 = if (f > 0) base[f - 1] else 0;
    const extra: i64 = it.size - (base[e] - base_start);
    var total: i64 = 0;
    for (lines[f .. e + 1]) |l| total += l.weight;
    const equal = total == 0;
    if (equal) total = it.span;
    var run: i64 = 0;
    for (f..e + 1) |k| {
        run += if (equal) 1 else lines[k].weight;
        const proposal: i64 = @as(i64, start_end) + (base[k] - base_start) + @divTrunc(run * extra, total);
        end[k] = @max(end[k], num.px(proposal));
    }
    var k = e + 1;
    while (k < end.len) : (k += 1) end[k] = @max(end[k], num.add(end[k - 1], base[k] - base[k - 1]));
    k = 1;
    while (k < end.len) : (k += 1) end[k] = @max(end[k], end[k - 1]);
}

/// Adds `extra` only when some line has a weight.
fn growIfWeighted(size: []i32, lines: []const Line, extra: i32) void {
    var total: i64 = 0;
    for (lines) |l| total += l.weight;
    if (total == 0) return;
    spread(size, lines, extra);
}

/// The size below which a line does not shrink.
fn floorOf(l: Line) i32 {
    return @max(l.minsize, 0);
}

fn shrink(gpa: std.mem.Allocator, size: []i32, lines: []const Line, amount: i32) !void {
    const n = size.len;
    var active_buf: [stack_lines]bool = undefined;
    var active: []bool = undefined;
    var heap: []bool = &.{};
    defer if (heap.len != 0) gpa.free(heap);
    if (n > stack_lines) {
        heap = try gpa.alloc(bool, n);
        active = heap;
    } else active = active_buf[0..n];
    for (active, size, lines) |*a, s, l| a.* = l.weight > 0 and s > floorOf(l);
    var rem: i64 = amount;
    while (rem > 0) {
        var total: i64 = 0;
        for (active, lines) |a, l| if (a) {
            total += l.weight;
        };
        if (total == 0) break;
        var run: i64 = 0;
        var done: i64 = 0;
        var violated = false;
        for (active, size, lines) |a, s, l| {
            if (!a) continue;
            run += l.weight;
            const cut = @divTrunc(run * rem, total);
            const sh = cut - done;
            done = cut;
            if (s - sh < floorOf(l)) violated = true;
        }
        if (!violated) {
            run = 0;
            done = 0;
            for (active, size, lines) |a, *s, l| {
                if (!a) continue;
                run += l.weight;
                const cut = @divTrunc(run * rem, total);
                s.* -= @intCast(cut - done);
                done = cut;
            }
            break;
        }
        // Clamp each line that would go below its minimum, then try again.
        run = 0;
        done = 0;
        for (active, size, lines) |*a, *s, l| {
            if (!a.*) continue;
            run += l.weight;
            const cut = @divTrunc(run * rem, total);
            const sh = cut - done;
            done = cut;
            const floor = floorOf(l);
            if (s.* - sh < floor) {
                rem -= s.* - floor;
                s.* = floor;
                a.* = false;
            }
        }
    }
}

// ---- The data of a container ----

pub const Container = struct {
    gpa: std.mem.Allocator,
    /// The managed widgets, oldest first.
    slaves: std.ArrayListUnmanaged(*Widget) = .empty,
    cols: std.ArrayListUnmanaged(Line) = .empty,
    rows: std.ArrayListUnmanaged(Line) = .empty,
    propagate: bool = true,
    anchor: options.Anchor = .nw,

    fn deinit(c: *Container) void {
        for (c.cols.items) |l| if (l.uniform.len != 0) c.gpa.free(l.uniform);
        for (c.rows.items) |l| if (l.uniform.len != 0) c.gpa.free(l.uniform);
        c.cols.deinit(c.gpa);
        c.rows.deinit(c.gpa);
        c.slaves.deinit(c.gpa);
    }
};

fn cellOf(w: *const Widget) ?*Cell {
    return @ptrCast(@alignCast(w.manager_data orelse return null));
}

fn containerOf(w: *const Widget) ?*Container {
    return @ptrCast(@alignCast(w.container_data orelse return null));
}

fn ensureContainer(w: *Widget) !*Container {
    if (containerOf(w)) |c| return c;
    const c = try w.app.gpa.create(Container);
    c.* = .{ .gpa = w.app.gpa };
    w.container_data = c;
    w.container_manager = &manager;
    return c;
}

/// The number of columns and rows: the larger of the content and the last line that has a setting.
fn lastUsed(list: []const Line) usize {
    var n = list.len;
    while (n > 0) : (n -= 1) {
        const l = list[n - 1];
        if (l.minsize != 0 or l.pad != 0 or l.weight != 0 or l.uniform.len != 0) break;
    }
    return n;
}

fn dims(c: *const Container) struct { cols: usize, rows: usize } {
    var nc = lastUsed(c.cols.items);
    var nr = lastUsed(c.rows.items);
    for (c.slaves.items) |s| {
        const cell = cellOf(s).?;
        nc = @max(nc, @as(usize, cell.column) + cell.columnspan);
        nr = @max(nr, @as(usize, cell.row) + cell.rowspan);
    }
    return .{ .cols = nc, .rows = nr };
}

fn lineAt(list: []const Line, i: usize) Line {
    return if (i < list.len) list[i] else .{};
}

const Layout = struct {
    gpa: std.mem.Allocator,
    ncols: usize,
    nrows: usize,
    col_off: []i32,
    row_off: []i32,
    /// The origin of the layout inside the container.
    x0: i32,
    y0: i32,

    fn deinit(l: *Layout) void {
        l.gpa.free(l.col_off);
        l.gpa.free(l.row_off);
    }
};

const Axis = enum { x, y };

fn solveAxis(gpa: std.mem.Allocator, c: *const Container, axis: Axis, n: usize, available: ?i32, offsets: []i32) !void {
    var line_buf: [stack_lines]Line = undefined;
    var item_buf: [stack_lines * 2]Item = undefined;
    const lines_src = if (axis == .x) c.cols.items else c.rows.items;
    var lines: []Line = undefined;
    var lines_heap: []Line = &.{};
    defer if (lines_heap.len != 0) gpa.free(lines_heap);
    if (n <= stack_lines) {
        lines = line_buf[0..n];
    } else {
        lines_heap = try gpa.alloc(Line, n);
        lines = lines_heap;
    }
    for (lines, 0..) |*l, i| l.* = lineAt(lines_src, i);
    var items: []Item = undefined;
    var items_heap: []Item = &.{};
    defer if (items_heap.len != 0) gpa.free(items_heap);
    if (c.slaves.items.len <= item_buf.len) {
        items = item_buf[0..c.slaves.items.len];
    } else {
        items_heap = try gpa.alloc(Item, c.slaves.items.len);
        items = items_heap;
    }
    for (c.slaves.items, items) |s, *it| {
        const cell = cellOf(s).?;
        if (axis == .x) {
            it.* = .{ .first = cell.column, .span = cell.columnspan, .size = num.px(@as(i64, s.req.w) + 2 * @as(i64, cell.ipadx) + cell.padx[0] + cell.padx[1]) };
        } else {
            it.* = .{ .first = cell.row, .span = cell.rowspan, .size = num.px(@as(i64, s.req.h) + 2 * @as(i64, cell.ipady) + cell.pady[0] + cell.pady[1]) };
        }
    }
    try solve(gpa, lines, items, available, offsets);
}

/// Solves both axes for the current size of the container.
fn computeLayout(w: *Widget, c: *const Container, fit: bool) !Layout {
    const gpa = w.app.gpa;
    const d = dims(c);
    const ins = layout.insets(w);
    const cw = w.geom.w - ins.horizontal();
    const ch = w.geom.h - ins.vertical();
    const col_off = try gpa.alloc(i32, d.cols + 1);
    errdefer gpa.free(col_off);
    const row_off = try gpa.alloc(i32, d.rows + 1);
    errdefer gpa.free(row_off);
    try solveAxis(gpa, c, .x, d.cols, if (fit) cw else null, col_off);
    try solveAxis(gpa, c, .y, d.rows, if (fit) ch else null, row_off);
    var x0: i32 = ins.left;
    var y0: i32 = ins.top;
    if (fit) {
        const dx = cw - col_off[d.cols];
        const dy = ch - row_off[d.rows];
        switch (c.anchor) {
            .nw, .w, .sw => {},
            .n, .center, .s => x0 += @divTrunc(dx, 2),
            .ne, .e, .se => x0 += dx,
        }
        switch (c.anchor) {
            .nw, .n, .ne => {},
            .w, .center, .e => y0 += @divTrunc(dy, 2),
            .sw, .s, .se => y0 += dy,
        }
    }
    return .{ .gpa = gpa, .ncols = d.cols, .nrows = d.rows, .col_off = col_off, .row_off = row_off, .x0 = x0, .y0 = y0 };
}

/// True when the widget is a container that has managed content.
pub fn hasContent(w: *const Widget) bool {
    const c = containerOf(w) orelse return false;
    return c.slaves.items.len > 0;
}

fn measure(w: *Widget) void {
    const c = containerOf(w) orelse return;
    if (!c.propagate or c.slaves.items.len == 0) return;
    var l = computeLayout(w, c, false) catch return;
    defer l.deinit();
    const ins = layout.insets(w);
    layout.setReq(w, .{ .w = l.col_off[l.ncols] + ins.horizontal(), .h = l.row_off[l.nrows] + ins.vertical() });
}

fn arrange(w: *Widget) void {
    const c = containerOf(w) orelse return;
    if (c.slaves.items.len == 0) return;
    var l = computeLayout(w, c, true) catch return;
    defer l.deinit();
    for (c.slaves.items) |s| {
        const cell = cellOf(s).?;
        const c0: usize = cell.column;
        const r0: usize = cell.row;
        const cx0 = l.x0 + l.col_off[c0] + cell.padx[0];
        const cx1 = l.x0 + l.col_off[c0 + cell.columnspan] - cell.padx[1];
        const cy0 = l.y0 + l.row_off[r0] + cell.pady[0];
        const cy1 = l.y0 + l.row_off[r0 + cell.rowspan] - cell.pady[1];
        const aw = cx1 - cx0;
        const ah = cy1 - cy0;
        var width = num.add(s.req.w, num.px(2 * @as(i64, cell.ipadx)));
        var height = num.add(s.req.h, num.px(2 * @as(i64, cell.ipady)));
        if (cell.sticky.e and cell.sticky.w) width = aw;
        if (cell.sticky.n and cell.sticky.s) height = ah;
        width = @min(width, aw);
        height = @min(height, ah);
        var x = cx0;
        if (!cell.sticky.w) x = if (cell.sticky.e) cx1 - width else cx0 + @divTrunc(aw - width, 2);
        var y = cy0;
        if (!cell.sticky.n) y = if (cell.sticky.s) cy1 - height else cy0 + @divTrunc(ah - height, 2);
        if (width < 1 or height < 1) {
            // A widget with no room is unmapped and keeps its old geometry.
            layout.setMapped(s, false);
            continue;
        }
        _ = layout.setGeom(s, .{ .x = num.px(x), .y = num.px(y), .w = num.px(width), .h = num.px(height) }, w.mapped);
    }
}

fn unlink(c: *Container, s: *Widget) void {
    for (c.slaves.items, 0..) |x, i| if (x == s) {
        _ = c.slaves.orderedRemove(i);
        return;
    };
}

fn forgetWidget(s: *Widget) void {
    const cell = cellOf(s) orelse return;
    if (cell.managed) {
        if (containerOf(cell.in)) |c| unlink(c, s);
        cell.in.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
        cell.managed = false;
    }
    s.manager = null;
    s.mapped = false;
}

fn release(w: *Widget) void {
    const c = containerOf(w) orelse return;
    for (c.slaves.items) |s| {
        const cell = cellOf(s).?;
        cell.managed = false;
        s.manager = null;
        s.mapped = false;
    }
    c.deinit();
    w.app.gpa.destroy(c);
    w.container_data = null;
    w.container_manager = null;
}

/// Ends the management of a widget and frees its cell.
fn forgetAtDelete(s: *Widget) void {
    forgetWidget(s);
    dropCell(s);
}

/// Frees the cell of a widget, also when `grid remove` kept it.
pub fn dropCell(s: *Widget) void {
    if (cellOf(s)) |cell| {
        s.app.gpa.destroy(cell);
        s.manager_data = null;
    }
}

pub const manager: layout.Manager = .{ .name = "grid", .measure = measure, .arrange = arrange, .forget = forgetAtDelete, .release = release };

// ---- The command ----

const subcommands = [_][]const u8{ "anchor", "bbox", "columnconfigure", "configure", "content", "forget", "info", "location", "propagate", "remove", "rowconfigure", "size", "slaves" };
const sub_list = "anchor, bbox, columnconfigure, configure, content, forget, info, location, propagate, remove, rowconfigure, size, or slaves";

const Sub = enum { anchor, bbox, columnconfigure, configure, content, forget, info, location, propagate, remove, rowconfigure, size, slaves };

fn findPrefix(comptime T: type, names: []const []const u8, text: []const u8) ?struct { idx: usize, ambiguous: bool } {
    _ = T;
    var found: ?usize = null;
    var count: usize = 0;
    for (names, 0..) |n, i| {
        if (std.mem.eql(u8, n, text)) return .{ .idx = i, .ambiguous = false };
        if (text.len > 0 and std.mem.startsWith(u8, n, text)) {
            found = i;
            count += 1;
        }
    }
    if (found) |f| return .{ .idx = f, .ambiguous = count > 1 };
    return null;
}

fn strOf(it: *ztcl.Interp, v: Value) ztcl.Error![]const u8 {
    return try it.str(v);
}

fn findWidget(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!*Widget {
    return app.find(path) orelse it.fail("bad window path name \"{s}\"", .{path});
}

/// `grid option arg ?arg ...?`
pub fn command(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("grid option arg ?arg ...?");
    const first = try strOf(it, argv[1]);
    if (first.len > 0 and (first[0] == '.' or std.mem.eql(u8, first, "x") or std.mem.eql(u8, first, "^"))) {
        return configure(it, app, argv[1..]);
    }
    if (argv.len < 3) return it.wrongArgs("grid option arg ?arg ...?");
    const found = findPrefix(Sub, &subcommands, first) orelse
        return it.fail("bad option \"{s}\": must be " ++ sub_list, .{first});
    if (found.ambiguous) return it.fail("ambiguous option \"{s}\": must be " ++ sub_list, .{first});
    const sub: Sub = @enumFromInt(found.idx);
    const rest = argv[2..];
    return switch (sub) {
        .configure => configure(it, app, rest),
        .forget => forgetCmd(it, app, rest, true),
        .remove => forgetCmd(it, app, rest, false),
        .info => infoCmd(it, app, rest),
        .size => sizeCmd(it, app, rest),
        .slaves, .content => slavesCmd(it, app, rest),
        .propagate => propagateCmd(it, app, rest),
        .anchor => anchorCmd(it, app, rest),
        .bbox => bboxCmd(it, app, rest),
        .location => locationCmd(it, app, rest),
        .columnconfigure => lineCmd(it, app, rest, .x),
        .rowconfigure => lineCmd(it, app, rest, .y),
    };
}

const Opts = struct {
    column: ?i64 = null,
    row: ?i64 = null,
    columnspan: ?i64 = null,
    rowspan: ?i64 = null,
    padx: ?[2]i32 = null,
    pady: ?[2]i32 = null,
    ipadx: ?i32 = null,
    ipady: ?i32 = null,
    sticky: ?Sticky = null,
    in: ?*Widget = null,
};

const opt_names = [_][]const u8{ "-column", "-columnspan", "-in", "-ipadx", "-ipady", "-padx", "-pady", "-row", "-rowspan", "-sticky" };
const opt_list = "-column, -columnspan, -in, -ipadx, -ipady, -padx, -pady, -row, -rowspan, or -sticky";

fn parseSticky(it: *ztcl.Interp, text: []const u8) ztcl.Error!Sticky {
    var s: Sticky = .{};
    for (text) |ch| switch (ch) {
        'n', 'N' => s.n = true,
        'e', 'E' => s.e = true,
        's', 'S' => s.s = true,
        'w', 'W' => s.w = true,
        ' ', ',', '\t', '\n' => {},
        else => return it.fail("bad stickyness value \"{s}\": must be a string containing n, e, s, and/or w", .{text}),
    };
    return s;
}

fn stickyText(s: Sticky, buf: *[4]u8) []const u8 {
    var n: usize = 0;
    if (s.n) {
        buf[n] = 'n';
        n += 1;
    }
    if (s.e) {
        buf[n] = 'e';
        n += 1;
    }
    if (s.s) {
        buf[n] = 's';
        n += 1;
    }
    if (s.w) {
        buf[n] = 'w';
        n += 1;
    }
    return buf[0..n];
}

fn parseIndexValue(it: *ztcl.Interp, what: []const u8, text: []const u8, min: i64, kind: []const u8) ztcl.Error!i64 {
    const v = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 0) catch
        return it.fail("bad {s} value \"{s}\": must be {s}", .{ what, text, kind });
    if (v < min or v > 10000) return it.fail("bad {s} value \"{s}\": must be {s}", .{ what, text, kind });
    return v;
}

fn parsePad1(it: *ztcl.Interp, app: *App, text: []const u8, which: []const u8) ztcl.Error!i32 {
    const v = options.parsePixels(text, app.scaling);
    if (v == null or v.? < 0) return it.fail("bad {s} value \"{s}\": must be positive screen distance", .{ which, text });
    return v.?;
}

fn parsePad(it: *ztcl.Interp, app: *App, v: Value) ztcl.Error![2]i32 {
    const parts = try it.list(v);
    if (parts.len < 1 or parts.len > 2) return it.fail("wrong number of parts to pad specification", .{});
    const a = try parsePad1(it, app, try strOf(it, parts[0]), "pad");
    if (parts.len == 1) return .{ a, a };
    const b = try parsePad1(it, app, try strOf(it, parts[1]), "2nd pad");
    return .{ a, b };
}

fn parseOpts(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Opts {
    var o: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const name = try strOf(it, args[i]);
        const found = findPrefix(void, &opt_names, name) orelse
            return it.fail("bad option \"{s}\": must be " ++ opt_list, .{name});
        if (found.ambiguous) return it.fail("ambiguous option \"{s}\": must be " ++ opt_list, .{name});
        const val = args[i + 1];
        const text = try strOf(it, val);
        switch (found.idx) {
            0 => o.column = try parseIndexValue(it, "column", text, 0, "a non-negative integer"),
            1 => o.columnspan = try parseIndexValue(it, "columnspan", text, 1, "a positive integer"),
            2 => o.in = try findWidget(it, app, text),
            3 => o.ipadx = try parsePad1(it, app, text, "ipadx"),
            4 => o.ipady = try parsePad1(it, app, text, "ipady"),
            5 => o.padx = try parsePad(it, app, val),
            6 => o.pady = try parsePad(it, app, val),
            7 => o.row = try parseIndexValue(it, "row", text, 0, "a non-negative integer"),
            8 => o.rowspan = try parseIndexValue(it, "rowspan", text, 1, "a positive integer"),
            9 => o.sticky = try parseSticky(it, text),
            else => unreachable,
        }
    }
    return o;
}

fn isRelative(s: []const u8) bool {
    return s.len == 1 and (s[0] == '-' or s[0] == 'x' or s[0] == '^');
}

fn isDescendant(w: *const Widget, of: *const Widget) bool {
    var x: ?*const Widget = w;
    while (x) |p| : (x = p.parent) if (p == of) return true;
    return false;
}

/// The first row after the content.
fn nextRow(c: *const Container) i64 {
    var r: i64 = 0;
    for (c.slaves.items) |s| {
        const cell = cellOf(s).?;
        r = @max(r, @as(i64, cell.row) + cell.rowspan);
    }
    return r;
}

fn configure(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    // Split the words from the options.
    var n_words: usize = 0;
    while (n_words < args.len) : (n_words += 1) {
        const s = try strOf(it, args[n_words]);
        if (s.len > 1 and s[0] == '-') break;
        if (s.len == 0 or !(s[0] == '.' or isRelative(s))) {
            return it.fail("unexpected parameter \"{s}\" in configure list: should be window name or option", .{s});
        }
    }
    const words = args[0..n_words];
    const opt_args = args[n_words..];
    if (opt_args.len % 2 != 0) return it.fail("extra option or option with no value", .{});

    // The container: -in, or the parent of the first window.
    var first_window: ?*Widget = null;
    for (words) |wd| {
        const s = try strOf(it, wd);
        if (s[0] == '^' and first_window == null) return it.fail("can't use '^', cant find master", .{});
        if (s[0] != '.') continue;
        const w = try findWidget(it, app, s);
        if (first_window == null) first_window = w;
    }
    if (first_window == null) return it.fail("can't determine master window", .{});
    // Check each window name before the options.
    for (words) |wd| {
        const s = try strOf(it, wd);
        if (s[0] == '.') {
            const w = try findWidget(it, app, s);
            if (w.isToplevel()) return it.fail("can't manage \"{s}\": it's a top-level window", .{s});
        }
    }
    const o = try parseOpts(it, app, opt_args);
    const container = o.in orelse (first_window.?.parent orelse return it.fail("can't manage \"{s}\": it's a top-level window", .{first_window.?.path}));
    for (words) |wd| {
        const s = try strOf(it, wd);
        if (s[0] != '.') continue;
        const w = app.find(s).?;
        if (w == container) return it.fail("window can't be managed in itself", .{});
        if (!isDescendant(container, w.parent.?)) return it.fail("can't put {s} inside {s}", .{ w.path, container.path });
        // A management loop: the container is placed by this widget.
        var up: ?*Widget = container;
        while (up) |x| {
            if (x == w) return it.fail("can't put {s} inside {s}, would cause management loop", .{ w.path, container.path });
            up = if (x.manager_data != null and x.manager != null) cellOf(x).?.in else null;
        }
    }

    const cont = try ensureContainer(container);
    const gpa = app.gpa;
    var col: i64 = 0;
    const row_default: i64 = o.row orelse nextRow(cont);
    var prev: ?*Widget = null;
    var i: usize = 0;
    while (i < words.len) : (i += 1) {
        const s = try strOf(it, words[i]);
        switch (s[0]) {
            'x' => col += 1,
            '-' => {
                const p = prev orelse return it.fail("can't use '-' as the first argument", .{});
                const cell = cellOf(p).?;
                if (cell.columnspan < 10000) cell.columnspan += 1;
                col += 1;
            },
            '^' => {
                // Extend the widget in the row above.
                const r = row_default;
                var above: ?*Widget = null;
                for (cont.slaves.items) |sl| {
                    const cell = cellOf(sl).?;
                    if (cell.column <= col and col < @as(i64, cell.column) + cell.columnspan and
                        cell.row < r and r - 1 < @as(i64, cell.row) + cell.rowspan) above = sl;
                }
                const a = above orelse return it.fail("can't find slave to extend with \"^\"", .{});
                const cell = cellOf(a).?;
                cell.rowspan = @intCast(@min(r - cell.row + 1, 10000));
                col += 1;
                container.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            },
            else => {
                const w = app.find(s).?;
                if (w.manager) |m| if (m != &manager) m.forget(w);
                var cell: *Cell = undefined;
                var fresh = false;
                if (cellOf(w)) |c| {
                    cell = c;
                } else {
                    cell = try gpa.create(Cell);
                    cell.* = .{ .in = container, .managed = false };
                    w.manager_data = cell;
                    fresh = true;
                }
                if (cell.managed and cell.in != container) {
                    if (containerOf(cell.in)) |old| unlink(old, w);
                    cell.in.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
                    cell.managed = false;
                    fresh = true;
                }
                const had_position = !fresh;
                // Look ahead for the "-" words that extend this widget.
                var extend: usize = 0;
                var j = i + 1;
                while (j < words.len) : (j += 1) {
                    const t = try strOf(it, words[j]);
                    if (t.len == 1 and t[0] == '-') extend += 1 else break;
                }
                if (!had_position) {
                    cell.column = @intCast(@min(col, 10000));
                    cell.row = @intCast(@min(row_default, 10000));
                }
                if (o.column) |v| cell.column = @intCast(v);
                if (o.row) |v| cell.row = @intCast(v);
                if (o.columnspan) |v| cell.columnspan = @intCast(v);
                if (o.rowspan) |v| cell.rowspan = @intCast(v);
                if (o.padx) |v| cell.padx = v;
                if (o.pady) |v| cell.pady = v;
                if (o.ipadx) |v| cell.ipadx = v;
                if (o.ipady) |v| cell.ipady = v;
                if (o.sticky) |v| cell.sticky = v;
                cell.in = container;
                if (!cell.managed) {
                    cell.managed = true;
                    cont.slaves.append(gpa, w) catch return error.OutOfMemory;
                    // The newest widget is first in the list of `grid slaves`.
                }
                w.manager = &manager;
                // The widget follows the container, so its map state follows.
                w.dirty.layout = true;
                col += cell.columnspan;
                prev = w;
                // The "-" words that follow add to the span.
                if (extend > 0) {
                    // A script can give any count of words. A span stops at 10000.
                    cell.columnspan = @intCast(@min(@as(usize, cell.columnspan) + extend, 10000));
                    col += @intCast(extend);
                    i += extend;
                }
                container.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
            },
        }
    }
    return Value.empty;
}

fn forgetCmd(it: *ztcl.Interp, app: *App, args: []const Value, free_cell: bool) ztcl.Error!Value {
    for (args) |a| _ = try findWidget(it, app, try strOf(it, a));
    for (args) |a| {
        const w = app.find(try strOf(it, a)).?;
        if (w.manager != &manager) continue;
        if (free_cell) {
            forgetAtDelete(w);
        } else forgetWidget(w);
    }
    return Value.empty;
}

fn slaveCell(w: *Widget) ?*Cell {
    const c = cellOf(w) orelse return null;
    return if (c.managed and w.manager == &manager) c else null;
}

fn infoCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len != 1) return it.wrongArgs("grid info window");
    const w = try findWidget(it, app, try strOf(it, args[0]));
    const cell = slaveCell(w) orelse return Value.empty;
    const a = it.alloc();
    var sb: [4]u8 = undefined;
    const items = try a.alloc(Value, 20);
    const names = [_][]const u8{ "-in", "-column", "-row", "-columnspan", "-rowspan", "-ipadx", "-ipady", "-padx", "-pady", "-sticky" };
    for (names, 0..) |n, i| items[i * 2] = .{ .str = n };
    items[1] = .{ .str = cell.in.path };
    items[3] = .{ .int = cell.column };
    items[5] = .{ .int = cell.row };
    items[7] = .{ .int = cell.columnspan };
    items[9] = .{ .int = cell.rowspan };
    items[11] = .{ .int = cell.ipadx };
    items[13] = .{ .int = cell.ipady };
    items[15] = try padValue(a, cell.padx);
    items[17] = try padValue(a, cell.pady);
    items[19] = .{ .str = try a.dupe(u8, stickyText(cell.sticky, &sb)) };
    return ztcl.value.wrapList(a, items);
}

fn padValue(a: std.mem.Allocator, p: [2]i32) !Value {
    if (p[0] == p[1]) return .{ .int = p[0] };
    return .{ .str = try std.fmt.allocPrint(a, "{d} {d}", .{ p[0], p[1] }) };
}

fn containerArg(it: *ztcl.Interp, app: *App, v: Value) ztcl.Error!*Widget {
    return findWidget(it, app, try strOf(it, v));
}

fn sizeCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len != 1) return it.wrongArgs("grid size window");
    const w = try containerArg(it, app, args[0]);
    const c = containerOf(w) orelse return .{ .str = "0 0" };
    const d = dims(c);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "{d} {d}", .{ d.cols, d.rows }) };
}

fn slavesCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len < 1 or args.len % 2 == 0) return it.fail("wrong # args: should be \"grid slaves window ?-option value...?\"", .{});
    const w = try containerArg(it, app, args[0]);
    var want_row: ?i64 = null;
    var want_col: ?i64 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        const name = try strOf(it, args[i]);
        if (std.mem.eql(u8, name, "-row")) {
            want_row = try it.int(args[i + 1]);
        } else if (std.mem.eql(u8, name, "-column")) {
            want_col = try it.int(args[i + 1]);
        } else return it.fail("bad option \"{s}\": must be -column or -row", .{name});
    }
    const a = it.alloc();
    var list: std.ArrayListUnmanaged(Value) = .empty;
    if (containerOf(w)) |c| {
        var k = c.slaves.items.len;
        while (k > 0) {
            k -= 1;
            const s = c.slaves.items[k];
            const cell = cellOf(s).?;
            if (want_row) |r| if (!(r >= cell.row and r < @as(i64, cell.row) + cell.rowspan)) continue;
            if (want_col) |cc| if (!(cc >= cell.column and cc < @as(i64, cell.column) + cell.columnspan)) continue;
            try list.append(a, .{ .str = try a.dupe(u8, s.path) });
        }
    }
    return ztcl.value.wrapList(a, try list.toOwnedSlice(a));
}

fn boolArg(it: *ztcl.Interp, v: Value) ztcl.Error!bool {
    const text = try strOf(it, v);
    if (options.parseBool(text)) |b| return b;
    if (std.fmt.parseInt(i64, text, 0)) |n| return n != 0 else |_| {}
    return it.fail("expected boolean value but got \"{s}\"", .{text});
}

fn propagateCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len < 1 or args.len > 2) return it.wrongArgs("grid propagate window ?boolean?");
    const w = try containerArg(it, app, args[0]);
    if (args.len == 1) {
        const on = if (containerOf(w)) |c| c.propagate else true;
        return .{ .int = @intFromBool(on) };
    }
    const b = try boolArg(it, args[1]);
    const c = try ensureContainer(w);
    if (c.propagate != b) {
        c.propagate = b;
        w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    }
    return Value.empty;
}

fn anchorCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len < 1 or args.len > 2) return it.wrongArgs("grid anchor window ?anchor?");
    const w = try containerArg(it, app, args[0]);
    if (args.len == 1) {
        const an = if (containerOf(w)) |c| c.anchor else .nw;
        return .{ .str = @tagName(an) };
    }
    const text = try strOf(it, args[1]);
    const an = std.meta.stringToEnum(options.Anchor, text) orelse
        return it.fail("bad anchor \"{s}\": must be n, ne, e, se, s, sw, w, nw, or center", .{text});
    const c = try ensureContainer(w);
    if (c.anchor != an) {
        c.anchor = an;
        w.invalidate(.{ .style = false, .measure = false, .layout = true, .paint = true });
    }
    return Value.empty;
}

fn clampIdx(v: i64, n: usize) usize {
    if (v < 0) return 0;
    return @intCast(@min(v, @as(i64, @intCast(n))));
}

fn bboxCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len != 1 and args.len != 3 and args.len != 5) return it.fail("wrong # args: should be \"grid bbox master ?column row ?column row??\"", .{});
    const w = try containerArg(it, app, args[0]);
    var c1: ?i64 = null;
    var r1: ?i64 = null;
    var c2: ?i64 = null;
    var r2: ?i64 = null;
    if (args.len >= 3) {
        c1 = try it.int(args[1]);
        r1 = try it.int(args[2]);
        c2 = c1;
        r2 = r1;
    }
    if (args.len == 5) {
        c2 = try it.int(args[3]);
        r2 = try it.int(args[4]);
    }
    const zero: Value = .{ .str = "0 0 0 0" };
    const c = containerOf(w) orelse return zero;
    if (c.slaves.items.len == 0) return zero;
    var l = computeLayout(w, c, true) catch return error.OutOfMemory;
    defer l.deinit();
    var xa: i32 = 0;
    var xb: i32 = l.col_off[l.ncols];
    var ya: i32 = 0;
    var yb: i32 = l.row_off[l.nrows];
    if (c1) |ci| {
        const ca = clampIdx(ci, l.ncols);
        const cb = clampIdx(@max(c2.?, ci) +| 1, l.ncols);
        const ra = clampIdx(r1.?, l.nrows);
        const rb = clampIdx(@max(r2.?, r1.?) +| 1, l.nrows);
        xa = l.col_off[ca];
        xb = l.col_off[cb];
        ya = l.row_off[ra];
        yb = l.row_off[rb];
    }
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "{d} {d} {d} {d}", .{ l.x0 + xa, l.y0 + ya, xb - xa, yb - ya }) };
}

fn locationCmd(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len != 3) return it.fail("wrong # args: should be \"grid location master x y\"", .{});
    const w = try containerArg(it, app, args[0]);
    const x = options.parsePixels(try strOf(it, args[1]), app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{try strOf(it, args[1])});
    const y = options.parsePixels(try strOf(it, args[2]), app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{try strOf(it, args[2])});
    const c = containerOf(w) orelse return .{ .str = "-1 -1" };
    var l = computeLayout(w, c, true) catch return error.OutOfMemory;
    defer l.deinit();
    const cx = locate(l.col_off, x - l.x0);
    const ry = locate(l.row_off, y - l.y0);
    return .{ .str = try std.fmt.allocPrint(it.alloc(), "{d} {d}", .{ cx, ry }) };
}

fn locate(off: []const i32, v: i32) i64 {
    if (v < 0) return -1;
    var i: usize = 0;
    while (i + 1 < off.len) : (i += 1) if (v < off[i + 1]) return @intCast(i);
    return @intCast(off.len - 1);
}

const line_names = [_][]const u8{ "-minsize", "-pad", "-uniform", "-weight" };
const line_list = "-minsize, -pad, -uniform, or -weight";

fn lineValue(it: *ztcl.Interp, l: Line, which: usize) ztcl.Error!Value {
    _ = it;
    return switch (which) {
        0 => .{ .int = l.minsize },
        1 => .{ .int = l.pad },
        2 => .{ .str = l.uniform },
        else => .{ .int = l.weight },
    };
}

fn lineCmd(it: *ztcl.Interp, app: *App, args: []const Value, axis: Axis) ztcl.Error!Value {
    const cmdname = if (axis == .x) "columnconfigure" else "rowconfigure";
    if (args.len < 2) return it.fail("wrong # args: should be \"grid {s} master index ?-option value ...?\"", .{cmdname});
    const w = try containerArg(it, app, args[0]);
    // The index: a list of numbers, `all`, or widget paths.
    const idx_items = try it.list(args[1]);
    const a = it.alloc();
    var indexes: std.ArrayListUnmanaged(usize) = .empty;
    const c0 = containerOf(w);
    for (idx_items) |iv| {
        const text = try strOf(it, iv);
        if (std.mem.eql(u8, text, "all")) {
            if (c0) |c| for (c.slaves.items) |s| {
                const cell = cellOf(s).?;
                const first: usize = if (axis == .x) cell.column else cell.row;
                const span: usize = if (axis == .x) cell.columnspan else cell.rowspan;
                for (first..first + span) |k| try addUnique(&indexes, a, k);
            };
        } else if (text.len > 0 and text[0] == '.') {
            const sw = try findWidget(it, app, text);
            const cell = slaveCell(sw);
            if (cell == null or cell.?.in != w) return it.fail("the window \"{s}\" is not managed by \"{s}\"", .{ text, w.path });
            const first: usize = if (axis == .x) cell.?.column else cell.?.row;
            const span: usize = if (axis == .x) cell.?.columnspan else cell.?.rowspan;
            for (first..first + span) |k| try addUnique(&indexes, a, k);
        } else {
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 0) catch return it.fail("illegal index \"{s}\"", .{text});
            if (v < 0 or v > 10000) return it.fail("\"{s}\" is out of range", .{text});
            try addUnique(&indexes, a, @intCast(v));
        }
    }
    const opt_args = args[2..];
    if (opt_args.len == 0 or opt_args.len == 1) {
        if (indexes.items.len != 1) return it.fail("must specify a single element on retrieval", .{});
        const l = if (c0) |c| lineAt(if (axis == .x) c.cols.items else c.rows.items, indexes.items[0]) else Line{};
        if (opt_args.len == 1) {
            const name = try strOf(it, opt_args[0]);
            const f = findPrefix(void, &line_names, name) orelse return it.fail("bad option \"{s}\": must be " ++ line_list, .{name});
            return lineValue(it, l, f.idx);
        }
        const items = try a.alloc(Value, 8);
        for (line_names, 0..) |n, i| {
            items[i * 2] = .{ .str = n };
            items[i * 2 + 1] = try lineValue(it, l, i);
        }
        return ztcl.value.wrapList(a, items);
    }
    if (opt_args.len % 2 != 0) return it.fail("wrong # args: should be \"grid {s} master index ?-option value ...?\"", .{cmdname});
    // Parse all the options first, then apply.
    var set_minsize: ?i32 = null;
    var set_pad: ?i32 = null;
    var set_uniform: ?[]const u8 = null;
    var set_weight: ?i32 = null;
    var i: usize = 0;
    while (i < opt_args.len) : (i += 2) {
        const name = try strOf(it, opt_args[i]);
        const f = findPrefix(void, &line_names, name) orelse return it.fail("bad option \"{s}\": must be " ++ line_list, .{name});
        const text = try strOf(it, opt_args[i + 1]);
        switch (f.idx) {
            0 => set_minsize = options.parsePixels(text, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{text}),
            1 => {
                const v = options.parsePixels(text, app.scaling) orelse return it.fail("bad screen distance \"{s}\"", .{text});
                if (v < 0) return it.fail("invalid arg \"{s}\": should be non-negative", .{name});
                set_pad = v;
            },
            2 => set_uniform = text,
            else => {
                const v = try it.int(opt_args[i + 1]);
                if (v < 0) return it.fail("invalid arg \"{s}\": should be non-negative", .{name});
                set_weight = @intCast(@min(v, 1 << 20));
            },
        }
    }
    const c = try ensureContainer(w);
    const list = if (axis == .x) &c.cols else &c.rows;
    for (indexes.items) |k| {
        while (list.items.len <= k) try list.append(c.gpa, .{});
        const l = &list.items[k];
        if (set_minsize) |v| l.minsize = v;
        if (set_pad) |v| l.pad = v;
        if (set_weight) |v| l.weight = v;
        if (set_uniform) |u| {
            const owned: []const u8 = if (u.len == 0) "" else try c.gpa.dupe(u8, u);
            if (l.uniform.len != 0) c.gpa.free(l.uniform);
            l.uniform = owned;
        }
    }
    w.invalidate(.{ .style = false, .measure = true, .layout = true, .paint = true });
    return Value.empty;
}

fn addUnique(list: *std.ArrayListUnmanaged(usize), a: std.mem.Allocator, k: usize) !void {
    for (list.items) |x| if (x == k) return;
    try list.append(a, k);
}
