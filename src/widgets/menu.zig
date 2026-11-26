//! The menu class: the model of a Tk menu. A menu has a list of entries.
//! Each entry has a type and a value for each option of its type. A null
//! value is the default of the option. The tables `kind_opts` give the
//! options of each type in the order of `entryconfigure` in `wish` 8.6.16,
//! and `opt_specs` gives the spec of each option, so `options.parseValue`
//! checks a value as it checks a widget option.
//!
//! A menu with `-tearoff 1` has a `tearoff` entry at index 0. The other
//! entries keep their Tk index. The native menus of the platform get the
//! list without the tearoff entry, so the index of a native entry is the
//! Tk index minus the count of tearoff entries.
//!
//! The indicator of a check or radio entry is not stored. It is the value
//! of the variable of the entry, read when the menu shows. So a write of the
//! variable needs no trace.
//!
//! With native menus (`Platform.hasNativeMenus`), the core gives each menu
//! an id, sends the entries with `menuSet` before a post or a menu bar, and
//! handles the `menu` events and the handler calls of the backend. Without
//! them, `post` posts a drawn menu (`menudraw.zig`).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("../geom.zig");
const widget = @import("../widget.zig");
const options = @import("../options.zig");
const paint = @import("../paint.zig");
const varlink = @import("../varlink.zig");
const event = @import("../event.zig");
const plat = @import("../platform/platform.zig");
const drawn = @import("menudraw.zig");
const App = @import("../app.zig").App;
const Spec = options.Spec;
const Widget = widget.Widget;
const Value = ztcl.Value;

const type_words = [_][]const u8{ "normal", "tearoff", "menubar" };

/// The options of `wish` 8.6.16 for `menu`, in its order.
pub const specs = [_]Spec{
    .{ .name = "-activebackground", .db_name = "activeBackground", .db_class = "Foreground", .type = .color, .default = "#ececec" },
    .{ .name = "-activeborderwidth", .db_name = "activeBorderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1" },
    .{ .name = "-activeforeground", .db_name = "activeForeground", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-background", .db_name = "background", .db_class = "Background", .type = .color, .default = "#d9d9d9", .from_style = true, .style_prop = .background },
    .{ .name = "-bd", .type = .synonym, .target = "-borderwidth" },
    .{ .name = "-bg", .type = .synonym, .target = "-background" },
    .{ .name = "-borderwidth", .db_name = "borderWidth", .db_class = "BorderWidth", .type = .pixels, .default = "1", .from_style = true, .style_prop = .border_width },
    .{ .name = "-cursor", .db_name = "cursor", .db_class = "Cursor", .type = .string, .default = "arrow" },
    .{ .name = "-disabledforeground", .db_name = "disabledForeground", .db_class = "DisabledForeground", .type = .color, .default = "#a3a3a3" },
    .{ .name = "-fg", .type = .synonym, .target = "-foreground" },
    .{ .name = "-font", .db_name = "font", .db_class = "Font", .type = .font, .default = "TkMenuFont" },
    .{ .name = "-foreground", .db_name = "foreground", .db_class = "Foreground", .type = .color, .default = "#000000", .from_style = true },
    .{ .name = "-postcommand", .db_name = "postCommand", .db_class = "Command", .type = .script, .allow_empty = true },
    .{ .name = "-relief", .db_name = "relief", .db_class = "Relief", .type = .relief, .default = "raised", .from_style = true },
    .{ .name = "-selectcolor", .db_name = "selectColor", .db_class = "Background", .type = .color, .default = "#000000" },
    .{ .name = "-takefocus", .db_name = "takeFocus", .db_class = "TakeFocus", .type = .string, .default = "0" },
    .{ .name = "-tearoff", .db_name = "tearOff", .db_class = "TearOff", .type = .boolean, .default = "1" },
    .{ .name = "-tearoffcommand", .db_name = "tearOffCommand", .db_class = "TearOffCommand", .type = .script, .allow_empty = true },
    .{ .name = "-title", .db_name = "title", .db_class = "Title", .type = .string, .allow_empty = true },
    .{ .name = "-type", .db_name = "type", .db_class = "Type", .type = .word, .default = "normal", .words = &type_words },
};

pub const Kind = enum { cascade, checkbutton, command, radiobutton, separator, tearoff };

/// The entry options of all types.
pub const Opt = enum { activebackground, activeforeground, accelerator, background, bitmap, columnbreak, command, compound, font, foreground, hidemargin, image, label, state, underline, indicatoron, offvalue, onvalue, selectcolor, selectimage, variable, value, menu };
const n_opts = @typeInfo(Opt).@"enum".fields.len;

const state_words = [_][]const u8{ "active", "normal", "disabled" };
const compound_words = [_][]const u8{ "bottom", "center", "left", "none", "right", "top" };

fn e(comptime name: []const u8, t: options.Type, default: []const u8) Spec {
    return .{ .name = name, .type = t, .default = default, .allow_empty = default.len == 0 };
}

/// The spec of each entry option, indexed by `Opt`.
const opt_specs = [n_opts]Spec{
    e("-activebackground", .color, ""),
    e("-activeforeground", .color, ""),
    e("-accelerator", .string, ""),
    e("-background", .color, ""),
    e("-bitmap", .string, ""),
    e("-columnbreak", .boolean, "0"),
    e("-command", .script, ""),
    .{ .name = "-compound", .db_name = "compound", .db_class = "Compound", .type = .word, .default = "none", .words = &compound_words },
    e("-font", .font, ""),
    e("-foreground", .color, ""),
    e("-hidemargin", .boolean, "0"),
    e("-image", .image, ""),
    e("-label", .string, ""),
    .{ .name = "-state", .type = .word, .default = "normal", .words = &state_words },
    e("-underline", .int, "-1"),
    e("-indicatoron", .boolean, "1"),
    e("-offvalue", .string, "0"),
    e("-onvalue", .string, "1"),
    e("-selectcolor", .color, ""),
    e("-selectimage", .image, ""),
    e("-variable", .string, ""),
    e("-value", .string, ""),
    e("-menu", .string, ""),
};

const common = [_]Opt{ .activebackground, .activeforeground, .accelerator, .background, .bitmap, .columnbreak, .command, .compound, .font, .foreground, .hidemargin, .image, .label, .state, .underline };

fn kindOpts(k: Kind) []const Opt {
    return switch (k) {
        .command => &common,
        .cascade => &([_]Opt{.menu} ++ common),
        .checkbutton => &([_]Opt{ .indicatoron, .offvalue, .onvalue, .selectcolor, .selectimage, .variable } ++ common),
        .radiobutton => &([_]Opt{ .indicatoron, .selectcolor, .selectimage, .value, .variable } ++ common),
        .separator, .tearoff => &[_]Opt{.background},
    };
}

/// The specs of the options of one type, in the order of `kindOpts`.
fn kindSpecs(comptime k: Kind) []const Spec {
    const list = comptime kindOpts(k);
    const out = comptime blk: {
        var a: [list.len]Spec = undefined;
        for (list, 0..) |o, i| a[i] = opt_specs[@intFromEnum(o)];
        break :blk a;
    };
    return &out;
}

fn specsOf(k: Kind) []const Spec {
    return switch (k) {
        inline else => |c| kindSpecs(c),
    };
}

pub const Entry = struct {
    kind: Kind,
    vals: [n_opts]?[]u8 = @splat(null),

    /// The value of an option: the set value or the default. The radio
    /// entry has the variable `selectedButton` by default.
    pub fn get(en: *const Entry, o: Opt) []const u8 {
        if (en.vals[@intFromEnum(o)]) |v| return v;
        if (o == .variable and en.kind == .radiobutton) return "selectedButton";
        return opt_specs[@intFromEnum(o)].default;
    }

    fn has(en: *const Entry, o: Opt) bool {
        return std.mem.indexOfScalar(Opt, kindOpts(en.kind), o) != null;
    }

    fn set(en: *Entry, gpa: std.mem.Allocator, o: Opt, v: []const u8) !void {
        const copy = try gpa.dupe(u8, v);
        if (en.vals[@intFromEnum(o)]) |old| gpa.free(old);
        en.vals[@intFromEnum(o)] = copy;
    }

    fn free(en: *Entry, gpa: std.mem.Allocator) void {
        for (&en.vals) |*v| if (v.*) |x| {
            gpa.free(x);
            v.* = null;
        };
    }

    /// True for an entry that `activate` and `invoke` accept.
    pub fn usable(en: *const Entry) bool {
        return en.kind != .separator and en.kind != .tearoff and !std.mem.eql(u8, en.get(.state), "disabled");
    }
};

pub const Data = struct {
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// The active entry, or -1.
    active: i64 = -1,
    /// The id of the native menu, or 0.
    native_id: plat.MenuId = 0,
    /// The menu is posted as a popup.
    posted: bool = false,
    /// The point of the post, in the coordinates of the window of the toplevel.
    post_at: geom.Point = .{},
    /// The entry with the open cascade, or -1.
    cascade: i64 = -1,
    /// The menu is the menu bar of a toplevel.
    is_bar: bool = false,
    /// The start of the open move of a drawn menu.
    open_us: i64 = 0,
};

pub fn data(w: *const Widget) *Data {
    return @ptrCast(@alignCast(w.data.?));
}

pub const class: widget.Class = .{
    .command = "menu",
    .tk_class = "Menu",
    .role = "menu",
    .specs = &specs,
    .init = init,
    .deinit = deinit,
    .teardown = teardown,
    .created = created,
    .configured = configured,
    .subcommand = subcommand,
    .bad_option_list = "activate, add, cget, clone, configure, delete, entrycget, entryconfigure, index, insert, invoke, post, postcascade, type, unpost, xposition, or yposition",
};

fn init(w: *Widget) anyerror!void {
    const d = try w.app.gpa.create(Data);
    d.* = .{};
    w.data = d;
}

fn deinit(w: *Widget) void {
    const d = data(w);
    const gpa = w.app.gpa;
    for (d.entries.items) |*en| en.free(gpa);
    d.entries.deinit(gpa);
    gpa.destroy(d);
    w.data = null;
}

fn teardown(w: *Widget) void {
    const app = w.app;
    const d = data(w);
    drawn.forget(w);
    if (d.native_id != 0) {
        if (d.posted) app.platform.unpostMenu(d.native_id);
        app.platform.menuDrop(d.native_id);
        _ = app.menu_ids.remove(d.native_id);
        d.native_id = 0;
    }
}

fn tearoffWanted(w: *const Widget) bool {
    const t = options.get(w, "-tearoff").value;
    const ty = options.get(w, "-type").value;
    const bar = ty == .word and ty.word == 2;
    return t == .boolean and t.boolean and !bar;
}

fn hasTearoff(d: *const Data) bool {
    return d.entries.items.len > 0 and d.entries.items[0].kind == .tearoff;
}

/// Adds or removes the tearoff entry to match `-tearoff` and `-type`.
fn syncTearoff(w: *Widget) !void {
    const d = data(w);
    const want = tearoffWanted(w);
    if (want == hasTearoff(d)) return;
    if (want) {
        try d.entries.insert(w.app.gpa, 0, .{ .kind = .tearoff });
        if (d.active >= 0) d.active += 1;
    } else {
        var en = d.entries.orderedRemove(0);
        en.free(w.app.gpa);
        if (d.active == 0) d.active = -1 else if (d.active > 0) d.active -= 1;
    }
}

fn created(w: *Widget) ztcl.Error!void {
    syncTearoff(w) catch return error.OutOfMemory;
}

fn configured(w: *Widget, _: []const usize) ztcl.Error!void {
    syncTearoff(w) catch return error.OutOfMemory;
    changed(w);
}

/// Sends the entries again to the native menu after a change.
pub fn changed(w: *Widget) void {
    const d = data(w);
    if (d.native_id != 0) syncNative(w, 0) catch {};
    // A drawn bar: each toplevel lays out and paints again, because the row can change its height.
    if (d.is_bar and !w.app.platform.hasNativeMenus()) {
        const all: widget.Dirty = .{ .style = false, .measure = true, .layout = true, .paint = true };
        if (w.app.root) |r| r.invalidate(all);
        for (w.app.tops.items) |t| if (t.alive()) t.invalidate(all);
    }
}

// ---- Indexes ----

fn globMatch(pat: []const u8, s: []const u8) bool {
    if (pat.len == 0) return s.len == 0;
    switch (pat[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= s.len) : (i += 1) if (globMatch(pat[1..], s[i..])) return true;
            return false;
        },
        '?' => return s.len > 0 and globMatch(pat[1..], s[1..]),
        '\\' => if (pat.len > 1) return s.len > 0 and s[0] == pat[1] and globMatch(pat[2..], s[1..]),
        else => {},
    }
    return s.len > 0 and s[0] == pat[0] and globMatch(pat[1..], s[1..]);
}

/// The index of an entry from its Tk form, or -1 for `none`. `end_ok`
/// lets a number past the end give the last entry, as `wish` does.
pub fn parseIndex(w: *Widget, it: *ztcl.Interp, text: []const u8) ztcl.Error!i64 {
    const d = data(w);
    const n: i64 = @intCast(d.entries.items.len);
    if (text.len == 0 or std.mem.eql(u8, text, "none")) return -1;
    if (std.mem.eql(u8, text, "active")) return d.active;
    if (std.mem.eql(u8, text, "end") or std.mem.eql(u8, text, "last")) return n - 1;
    if (text[0] == '@') {
        const y = std.fmt.parseInt(i32, text[1..], 0) catch return it.fail("bad menu entry index \"{s}\"", .{text});
        return entryAtY(w, y);
    }
    if (std.fmt.parseInt(i64, std.mem.trim(u8, text, " "), 0)) |i| {
        if (i < 0) return it.fail("bad menu entry index \"{s}\"", .{text});
        return @min(i, n - 1);
    } else |_| {}
    for (d.entries.items, 0..) |*en, i| {
        if (!en.has(.label)) continue;
        if (globMatch(text, en.get(.label))) return @intCast(i);
    }
    return it.fail("bad menu entry index \"{s}\"", .{text});
}

fn entryAt(w: *Widget, i: i64) ?*Entry {
    const d = data(w);
    if (i < 0 or i >= d.entries.items.len) return null;
    return &d.entries.items[@intCast(i)];
}

// ---- Layout ----

/// The heights of the rows: the line of the font and the padding of the
/// part `::item`, a separator, and a tearoff entry.
pub const Metrics = struct { pad: i32, row: i32, sep: i32, tear: i32 };

pub fn metrics(w: *Widget) Metrics {
    const app = w.app;
    app.ensureStyle(w);
    const box = paint.insets(&w.style);
    const item = app.styles.compute(w, "item", &w.style, app.env);
    const ins = paint.insets(&item);
    return .{ .pad = box.top, .row = paint.lineHeight(app, item.font) + ins.vertical(), .sep = 9, .tear = 8 };
}

fn rowHeight(m: Metrics, k: Kind) i32 {
    return switch (k) {
        .separator => m.sep,
        .tearoff => m.tear,
        else => m.row,
    };
}

/// The top of an entry in the coordinates of the menu.
pub fn yOf(w: *Widget, index: i64) i32 {
    const m = metrics(w);
    var y = m.pad;
    for (data(w).entries.items, 0..) |en, i| {
        if (i == index) break;
        y += rowHeight(m, en.kind);
    }
    return y;
}

pub fn entryAtY(w: *Widget, y: i32) i64 {
    const m = metrics(w);
    var top = m.pad;
    if (y < top) return -1;
    for (data(w).entries.items, 0..) |en, i| {
        const h = rowHeight(m, en.kind);
        if (y < top + h) return @intCast(i);
        top += h;
    }
    return -1;
}

// ---- Entries ----

fn kindOf(it: *ztcl.Interp, text: []const u8) ztcl.Error!Kind {
    inline for (.{ "cascade", "checkbutton", "command", "radiobutton", "separator" }) |name| {
        if (std.mem.eql(u8, text, name)) return @field(Kind, name);
    }
    return it.fail("bad menu entry type \"{s}\": must be cascade, checkbutton, command, radiobutton, or separator", .{text});
}

/// Checks and sets option-value pairs on an entry.
fn configureEntry(w: *Widget, it: *ztcl.Interp, en: *Entry, index: i64, pairs: []const Value) ztcl.Error!void {
    const gpa = w.app.gpa;
    const sp = specsOf(en.kind);
    const list = kindOpts(en.kind);
    if (pairs.len % 2 != 0) {
        _ = try options.find(it, sp, try it.str(pairs[pairs.len - 1]));
        return it.fail("value for \"{s}\" missing", .{try it.str(pairs[pairs.len - 1])});
    }
    var k: usize = 0;
    while (k < pairs.len) : (k += 2) {
        const i = try options.find(it, sp, try it.str(pairs[k]));
        const text = try it.str(pairs[k + 1]);
        var norm: []const u8 = text;
        _ = try options.parseValue(w, it, sp[i], text, &norm);
        const o = list[i];
        if (o == .state) {
            const d = data(w);
            if (std.mem.eql(u8, norm, "active")) {
                if (en.kind != .separator and en.kind != .tearoff) d.active = index;
                en.set(gpa, o, "normal") catch return error.OutOfMemory;
                continue;
            }
            if (d.active == index) d.active = -1;
        }
        en.set(gpa, o, norm) catch return error.OutOfMemory;
    }
}

fn addEntry(w: *Widget, it: *ztcl.Interp, at: usize, kind: Kind, pairs: []const Value) ztcl.Error!void {
    const gpa = w.app.gpa;
    var en: Entry = .{ .kind = kind };
    errdefer en.free(gpa);
    try configureEntry(w, it, &en, -1, pairs);
    // A check entry without a variable uses its label, and a radio entry without a value uses its label.
    if (kind == .checkbutton and en.vals[@intFromEnum(Opt.variable)] == null) en.set(gpa, .variable, en.get(.label)) catch return error.OutOfMemory;
    if (kind == .radiobutton and en.vals[@intFromEnum(Opt.value)] == null) en.set(gpa, .value, en.get(.label)) catch return error.OutOfMemory;
    const d = data(w);
    d.entries.insert(gpa, at, en) catch return error.OutOfMemory;
    if (d.active >= @as(i64, @intCast(at))) d.active += 1;
}

fn entryInfo(it: *ztcl.Interp, en: *const Entry, i: usize) ztcl.Error!Value {
    const a = it.alloc();
    const sp = specsOf(en.kind)[i];
    return ztcl.value.newList(a, &.{ .{ .str = sp.name }, .{ .str = sp.db_name }, .{ .str = sp.db_class }, .{ .str = sp.default }, .{ .str = try a.dupe(u8, shown(en, kindOpts(en.kind)[i], -1, -2)) } });
}

/// The text of an option for `entrycget`: `-state` is `active` for the active entry.
fn shown(en: *const Entry, o: Opt, index: i64, active: i64) []const u8 {
    if (o == .state and index == active and std.mem.eql(u8, en.get(.state), "normal")) return "active";
    return en.get(o);
}

/// Runs a script at the global level and gives its result.
fn evalGlobal(app: *App, script: []const u8) ztcl.Error!Value {
    const it = app.it;
    const saved_frame = it.frame;
    const saved_ns = it.ns;
    it.frame = &it.global;
    it.ns = "";
    defer {
        it.frame = saved_frame;
        it.ns = saved_ns;
    }
    return it.eval(try it.alloc().dupe(u8, script));
}

/// `invoke`: sets the variable of a check or radio entry, then runs `-command`.
pub fn invoke(w: *Widget, index: i64) ztcl.Error!Value {
    const app = w.app;
    const en = entryAt(w, index) orelse return Value.empty;
    if (!en.usable()) return Value.empty;
    switch (en.kind) {
        .checkbutton => {
            const name = en.get(.variable);
            const cur = varlink.read(w, name) orelse "";
            const on = en.get(.onvalue);
            const next = if (std.mem.eql(u8, cur, on)) en.get(.offvalue) else on;
            try varlink.write(w, try app.it.alloc().dupe(u8, name), try app.it.alloc().dupe(u8, next));
        },
        .radiobutton => {
            try varlink.write(w, try app.it.alloc().dupe(u8, en.get(.variable)), try app.it.alloc().dupe(u8, en.get(.value)));
        },
        else => {},
    }
    if (!w.alive()) return Value.empty;
    const en2 = entryAt(w, index) orelse return Value.empty;
    const cmd = en2.get(.command);
    if (cmd.len == 0) return Value.empty;
    const copy = try app.it.alloc().dupe(u8, cmd);
    return evalGlobal(app, copy);
}

/// True when the indicator of a check or radio entry is on.
pub fn selected(w: *Widget, en: *const Entry) bool {
    const want = switch (en.kind) {
        .checkbutton => en.get(.onvalue),
        .radiobutton => en.get(.value),
        else => return false,
    };
    const cur = varlink.read(w, en.get(.variable)) orelse return false;
    return std.mem.eql(u8, cur, want);
}

/// Sets the active entry. An entry that `activate` does not accept gives none.
pub fn activate(w: *Widget, index: i64) void {
    const d = data(w);
    const en = entryAt(w, index);
    d.active = if (en != null and en.?.usable()) index else -1;
    if (d.posted and w.alive()) w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

/// Runs `-postcommand`. An error goes to the background error handler.
pub fn runPostCommand(w: *Widget) ztcl.Error!void {
    const cmd = options.get(w, "-postcommand").text;
    if (cmd.len == 0) return;
    _ = try evalGlobal(w.app, cmd);
}

fn subWindow(w: *Widget) ?*plat.Window {
    return w.app.winOf(w.toplevel());
}

/// Posts the menu at a point of the window of its toplevel.
pub fn post(w: *Widget, at: geom.Point, entry: i64) ztcl.Error!void {
    try runPostCommand(w);
    if (!w.alive()) return;
    const app = w.app;
    const d = data(w);
    d.posted = true;
    d.post_at = at;
    if (app.platform.hasNativeMenus()) {
        try syncNative(w, 0);
        const win = subWindow(w) orelse return;
        const native: i32 = if (entry < 0) -1 else @intCast(entry - @intFromBool(hasTearoff(d)));
        app.platform.postMenu(win, d.native_id, at, native);
        return;
    }
    if (entry >= 0) d.post_at.y -= yOf(w, entry);
    drawn.post(w);
}

pub fn unpost(w: *Widget) void {
    const app = w.app;
    const d = data(w);
    if (!app.platform.hasNativeMenus()) return drawn.unpost(w);
    if (d.native_id != 0 and d.posted) app.platform.unpostMenu(d.native_id);
    d.posted = false;
    d.active = -1;
    d.cascade = -1;
    if (w.alive()) w.toplevel().invalidate(.{ .style = false, .measure = false, .layout = false, .paint = true });
}

// ---- Native menus ----

/// The id of the native menu of a widget. It makes the id on the first call.
fn nativeId(w: *Widget) !plat.MenuId {
    const app = w.app;
    const d = data(w);
    if (d.native_id != 0) return d.native_id;
    if (app.menu_next == 0) app.menu_next = 1;
    d.native_id = app.menu_next;
    app.menu_next +%= 1;
    try app.menu_ids.put(app.gpa, d.native_id, w);
    return d.native_id;
}

/// The role of a cascade menu in a menu bar, from its name as Tk on macOS has it.
fn roleOf(bar: *Widget, sub: *Widget) plat.Menu.Role {
    if (!data(bar).is_bar or sub.parent != bar) return .none;
    const name = sub.path[std.mem.lastIndexOfScalar(u8, sub.path, '.').? + 1 ..];
    if (std.mem.eql(u8, name, "apple")) return .app;
    if (std.mem.eql(u8, name, "help")) return .help;
    if (std.mem.eql(u8, name, "window")) return .window;
    return .none;
}

/// Sends the entries of a menu and of its cascades to the backend.
pub fn syncNative(w: *Widget, depth: u8) ztcl.Error!void {
    return syncAs(w, depth, "", .none);
}

fn syncAs(w: *Widget, depth: u8, title: []const u8, role: plat.Menu.Role) ztcl.Error!void {
    const app = w.app;
    if (!app.platform.hasNativeMenus() or depth > 16) return;
    const id = nativeId(w) catch return error.OutOfMemory;
    const d = data(w);
    const a = app.it.alloc();
    var list: std.ArrayListUnmanaged(plat.MenuEntry) = .empty;
    for (d.entries.items) |*en| {
        if (en.kind == .tearoff) continue;
        var me: plat.MenuEntry = .{
            .kind = switch (en.kind) {
                .cascade => .cascade,
                .checkbutton => .checkbutton,
                .radiobutton => .radiobutton,
                .separator => .separator,
                else => .command,
            },
        };
        if (en.kind != .separator) {
            me.label = en.get(.label);
            me.accelerator = en.get(.accelerator);
            me.underline = std.fmt.parseInt(i32, en.get(.underline), 0) catch -1;
            me.enabled = !std.mem.eql(u8, en.get(.state), "disabled");
            me.selected = selected(w, en);
            me.column_break = options.parseBool(en.get(.columnbreak)) orelse false;
        }
        if (en.kind == .cascade) if (app.find(en.get(.menu))) |sub| if (sub.class == &class and sub != w) {
            try syncAs(sub, depth + 1, en.get(.label), roleOf(w, sub));
            me.submenu = data(sub).native_id;
        };
        list.append(a, me) catch return error.OutOfMemory;
    }
    app.platform.menuSet(&.{ .id = id, .title = title, .role = role, .entries = list.items });
}

/// The menu of a native id, or null.
fn byId(app: *App, id: plat.MenuId) ?*Widget {
    const w = app.menu_ids.get(id) orelse return null;
    if (!w.alive()) return null;
    return w;
}

/// The Tk index of a native entry index.
fn tkIndex(w: *Widget, entry: i32) i64 {
    if (entry < 0) return -1;
    return @as(i64, entry) + @intFromBool(hasTearoff(data(w)));
}

/// Handles a `menu` event of the backend.
pub fn handleEvent(app: *App, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
    const w = byId(app, id) orelse return;
    const i = tkIndex(w, entry);
    switch (action) {
        .invoke => {
            _ = invoke(w, i) catch |err| app.backgroundError(err);
        },
        .select => {
            activate(w, i);
            selectEvent(w);
        },
        .opening => {
            runPostCommand(w) catch |err| app.backgroundError(err);
            if (w.alive()) syncNative(w, 0) catch {};
        },
        .closed => {
            const d = data(w);
            d.posted = false;
            d.active = -1;
        },
    }
}

/// Sends `<<MenuSelect>>` to the menu.
pub fn selectEvent(w: *Widget) void {
    const app = w.app;
    const script = std.fmt.allocPrint(app.gpa, "event generate {s} <<MenuSelect>>", .{w.path}) catch return;
    defer app.gpa.free(script);
    app.callback(script);
}

fn handlerCall(ctx: ?*anyopaque, id: plat.MenuId, entry: i32, action: event.MenuAction) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.enter();
    defer app.leave();
    handleEvent(app, id, entry, action);
}

/// Sets the native menu bar of a toplevel from its `-menu`. An empty name removes it.
pub fn setBar(top: *Widget, name: []const u8) ztcl.Error!void {
    const app = top.app;
    if (!app.platform.hasNativeMenus()) return;
    const win = app.winOf(top) orelse return;
    const m = app.find(name) orelse {
        app.platform.setMenuBar(win, 0);
        return;
    };
    if (m.class != &class) return;
    data(m).is_bar = true;
    try syncNative(m, 0);
    app.platform.setMenuBar(win, data(m).native_id);
}

// ---- Subcommands ----

fn wrong(it: *ztcl.Interp, w: *Widget, comptime rest: []const u8) ztcl.Error {
    return it.fail("wrong # args: should be \"{s} " ++ rest ++ "\"", .{w.path});
}

fn subcommand(w: *Widget, it: *ztcl.Interp, argv: []const Value) ztcl.Error!?Value {
    const sub = try it.str(argv[1]);
    const d = data(w);
    const gpa = w.app.gpa;
    const eq = std.mem.eql;
    if (eq(u8, sub, "add")) {
        if (argv.len < 3) return wrong(it, w, "add type ?-option value ...?");
        try addEntry(w, it, d.entries.items.len, try kindOf(it, try it.str(argv[2])), argv[3..]);
        changed(w);
        return Value.empty;
    }
    if (eq(u8, sub, "insert")) {
        if (argv.len < 4) return wrong(it, w, "insert index type ?-option value ...?");
        const idx_text = try it.str(argv[2]);
        var at: i64 = if (eq(u8, idx_text, "end") or eq(u8, idx_text, "last")) @intCast(d.entries.items.len) else try parseIndex(w, it, idx_text);
        if (at < 0) at = @intCast(d.entries.items.len);
        if (hasTearoff(d) and at == 0) at = 1;
        try addEntry(w, it, @intCast(@min(at, @as(i64, @intCast(d.entries.items.len)))), try kindOf(it, try it.str(argv[3])), argv[4..]);
        changed(w);
        return Value.empty;
    }
    if (eq(u8, sub, "delete")) {
        if (argv.len < 3 or argv.len > 4) return wrong(it, w, "delete first ?last?");
        // A number past the end deletes no entry, as in `wish`.
        const n_entries: i64 = @intCast(d.entries.items.len);
        const first_text = try it.str(argv[2]);
        if (std.fmt.parseInt(i64, std.mem.trim(u8, first_text, " "), 0)) |v| if (v >= n_entries) return Value.empty else {} else |_| {}
        var first = try parseIndex(w, it, first_text);
        const last = if (argv.len == 4) try parseIndex(w, it, try it.str(argv[3])) else first;
        if (first < 0 or last < 0) return Value.empty;
        // The tearoff entry stays, as in `wish`.
        if (first == 0 and hasTearoff(d)) first = 1;
        if (last < first) return Value.empty;
        var k = last;
        while (k >= first) : (k -= 1) {
            var en = d.entries.orderedRemove(@intCast(k));
            en.free(gpa);
        }
        const n = last - first + 1;
        if (d.active >= first and d.active <= last) d.active = -1 else if (d.active > last) d.active -= n;
        changed(w);
        return Value.empty;
    }
    if (eq(u8, sub, "index")) {
        if (argv.len != 3) return wrong(it, w, "index string");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        return if (i < 0) .{ .str = "none" } else .{ .int = i };
    }
    if (eq(u8, sub, "type")) {
        if (argv.len != 3) return wrong(it, w, "type index");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        const en = entryAt(w, i) orelse return Value.empty;
        return .{ .str = @tagName(en.kind) };
    }
    if (eq(u8, sub, "entrycget")) {
        if (argv.len != 4) return wrong(it, w, "entrycget index option");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        const en = entryAt(w, i) orelse return Value.empty;
        const k = try options.find(it, specsOf(en.kind), try it.str(argv[3]));
        return .{ .str = try it.alloc().dupe(u8, shown(en, kindOpts(en.kind)[k], i, d.active)) };
    }
    if (eq(u8, sub, "entryconfigure")) {
        if (argv.len < 3) return wrong(it, w, "entryconfigure index ?-option value ...?");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        const en = entryAt(w, i) orelse return Value.empty;
        if (argv.len == 3) {
            const a = it.alloc();
            const list = kindOpts(en.kind);
            const items = try a.alloc(Value, list.len);
            for (items, 0..) |*v, k| v.* = try entryInfo(it, en, k);
            return try ztcl.value.newList(a, items);
        }
        if (argv.len == 4) {
            const k = try options.find(it, specsOf(en.kind), try it.str(argv[3]));
            return try entryInfo(it, en, k);
        }
        try configureEntry(w, it, en, i, argv[3..]);
        changed(w);
        return Value.empty;
    }
    if (eq(u8, sub, "activate")) {
        if (argv.len != 3) return wrong(it, w, "activate index");
        activate(w, try parseIndex(w, it, try it.str(argv[2])));
        return Value.empty;
    }
    if (eq(u8, sub, "invoke")) {
        if (argv.len != 3) return wrong(it, w, "invoke index");
        return try invoke(w, try parseIndex(w, it, try it.str(argv[2])));
    }
    if (eq(u8, sub, "post")) {
        if (argv.len != 4 and argv.len != 5) return wrong(it, w, "post x y ?index?");
        const x = try it.int(argv[2]);
        const y = try it.int(argv[3]);
        const entry = if (argv.len == 5) try parseIndex(w, it, try it.str(argv[4])) else -1;
        const clamp = struct {
            fn f(v: i64) i32 {
                return @intCast(std.math.clamp(v, -1 << 24, 1 << 24));
            }
        }.f;
        try post(w, .{ .x = clamp(x), .y = clamp(y) }, entry);
        return Value.empty;
    }
    if (eq(u8, sub, "unpost")) {
        if (argv.len != 2) return wrong(it, w, "unpost");
        unpost(w);
        return Value.empty;
    }
    if (eq(u8, sub, "postcascade")) {
        if (argv.len != 3) return wrong(it, w, "postcascade index");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        if (!w.app.platform.hasNativeMenus()) {
            try drawn.postCascade(w, i);
            return Value.empty;
        }
        const en = entryAt(w, i);
        d.cascade = if (d.posted and en != null and en.?.kind == .cascade and en.?.usable()) i else -1;
        return Value.empty;
    }
    if (eq(u8, sub, "xposition")) {
        if (argv.len != 3) return wrong(it, w, "xposition index");
        _ = try parseIndex(w, it, try it.str(argv[2]));
        return .{ .int = metrics(w).pad };
    }
    if (eq(u8, sub, "yposition")) {
        if (argv.len != 3) return wrong(it, w, "yposition index");
        const i = try parseIndex(w, it, try it.str(argv[2]));
        return .{ .int = yOf(w, @max(i, 0)) };
    }
    if (eq(u8, sub, "clone")) {
        if (argv.len < 3 or argv.len > 4) return wrong(it, w, "clone newMenuName ?menuType?");
        try clone(w, it, try it.str(argv[2]), if (argv.len == 4) try it.str(argv[3]) else null);
        return Value.empty;
    }
    return null;
}

/// `clone`: a new menu with the options and the entries of this menu.
fn clone(w: *Widget, it: *ztcl.Interp, path: []const u8, ty: ?[]const u8) ztcl.Error!void {
    const app = w.app;
    const a = it.alloc();
    var words: std.ArrayListUnmanaged(Value) = .empty;
    try words.append(a, .{ .str = "menu" });
    try words.append(a, .{ .str = try a.dupe(u8, path) });
    for (specs, 0..) |sp, i| {
        if (sp.type == .synonym or !w.opts[i].set) continue;
        try words.append(a, .{ .str = sp.name });
        try words.append(a, .{ .str = try a.dupe(u8, w.opts[i].text) });
    }
    if (ty) |t| {
        try words.append(a, .{ .str = "-type" });
        try words.append(a, .{ .str = try a.dupe(u8, t) });
    }
    _ = try it.callWords(words.items);
    const c = app.find(path) orelse return;
    const cd = data(c);
    for (data(w).entries.items) |*en| {
        if (en.kind == .tearoff) continue;
        var copy: Entry = .{ .kind = en.kind };
        for (en.vals, 0..) |v, k| if (v) |x| {
            copy.vals[k] = app.gpa.dupe(u8, x) catch {
                copy.free(app.gpa);
                return error.OutOfMemory;
            };
        };
        cd.entries.append(app.gpa, copy) catch {
            copy.free(app.gpa);
            return error.OutOfMemory;
        };
    }
}

pub fn register(app: *App) !void {
    try app.it.register("menu", widget.classCommand(&class));
    try app.classes.put(app.gpa, "menu", &class);
    app.platform.setMenuHandler(.{ .ctx = app, .call = handlerCall });
    try drawn.register(app);
    _ = try app.it.eval(
        \\proc ::tk_popup {menu x y {entry {}}} {
        \\    if {$entry eq {}} {$menu post $x $y} else {$menu post $x $y $entry}
        \\}
    );
}
