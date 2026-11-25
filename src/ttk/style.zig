//! `ttk::style`. Each theme keeps the settings of `configure` and `map`
//! and the layouts that a script set. The settings of the current theme
//! and its parents become one style sheet with the origin `ttk`: a style
//! name `Accent.TButton` is the selector `TButton.Accent`, an option is a
//! CSS property, and each pair of a map is a rule with `:state()`. The
//! settings that the themes of `wish` 8.6.16 have are in each theme too,
//! for `lookup`, and give no rules. The themes `default`, `clam`, and
//! `alt` have the modern look, and `classic` has the look of Tk on X11.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const geom = @import("../geom.zig");
const options = @import("../options.zig");
const style_mod = @import("../style.zig");
const App = @import("../app.zig").App;
const Value = ztcl.Value;

/// The state names of `ttk`, in the order of `state` with no argument.
pub const state_names = [_][]const u8{ "active", "disabled", "focus", "pressed", "selected", "background", "alternate", "invalid", "readonly", "hover", "user6", "user5", "user4", "user3", "user2", "user1" };

/// The style types of the `ttk` widgets, for the style ".".
pub const types = [_][]const u8{ "TButton", "TCheckbutton", "TRadiobutton", "TLabel", "TFrame", "TLabelframe", "TEntry", "TSeparator", "TSizegrip" };

const Setting = struct { style: []u8, option: []u8, value: []u8, seed: bool };
const Layout = struct { style: []u8, spec: []u8 };

const Theme = struct {
    name: []u8,
    parent: ?usize,
    classic: bool,
    conf: std.ArrayListUnmanaged(Setting) = .empty,
    map: std.ArrayListUnmanaged(Setting) = .empty,
    layouts: std.ArrayListUnmanaged(Layout) = .empty,

    fn deinit(t: *Theme, gpa: std.mem.Allocator) void {
        for ([_]*std.ArrayListUnmanaged(Setting){ &t.conf, &t.map }) |l| {
            for (l.items) |s| {
                gpa.free(s.style);
                gpa.free(s.option);
                gpa.free(s.value);
            }
            l.deinit(gpa);
        }
        for (t.layouts.items) |l| {
            gpa.free(l.style);
            gpa.free(l.spec);
        }
        t.layouts.deinit(gpa);
        gpa.free(t.name);
    }
};

pub const Data = struct {
    themes: std.ArrayListUnmanaged(Theme) = .empty,
    current: usize = 0,
    /// The theme of `theme settings` while its script runs.
    target: ?usize = null,
    /// The id of the sheet of the settings, or 0.
    sheet: u32 = 0,
    /// The names of `element create`.
    elements: std.ArrayListUnmanaged([]u8) = .empty,

    pub fn deinit(d: *Data, gpa: std.mem.Allocator) void {
        for (d.themes.items) |*t| t.deinit(gpa);
        d.themes.deinit(gpa);
        for (d.elements.items) |e| gpa.free(e);
        d.elements.deinit(gpa);
    }

    fn find(d: *const Data, name: []const u8) ?usize {
        for (d.themes.items, 0..) |t, i| if (std.mem.eql(u8, t.name, name)) return i;
        return null;
    }

    /// True when the current theme has the classic look.
    pub fn classic(d: *const Data) bool {
        if (d.themes.items.len == 0) return false;
        return d.themes.items[d.current].classic;
    }
};

/// The settings of the themes of `wish` 8.6.16: theme, style, `configure`, and `map`.
const seeds = [_][4][]const u8{
    .{ "default", ".", "-selectforeground #ffffff -font TkDefaultFont -foreground #000000 -indicatordiameter 10 -selectbackground #4a6984 -troughcolor #c3c3c3 -background #d9d9d9 -insertwidth 1 -borderwidth 1", "-foreground {disabled #a3a3a3} -background {disabled #d9d9d9 active #ececec}" },
    .{ "default", "TButton", "-relief raised -padding {3 3} -anchor center -width -9 -shiftrelief 1", "-relief {{!disabled pressed} sunken}" },
    .{ "default", "TCheckbutton", "-padding 1 -indicatorrelief sunken -indicatorcolor #ffffff", "-indicatorrelief {alternate raised} -indicatorcolor {pressed #ececec {!disabled alternate} #9fbdd8 {disabled alternate} #c0c0c0 {!disabled selected} #4a6984 {disabled selected} #a3a3a3}" },
    .{ "default", "TRadiobutton", "-padding 1 -indicatorrelief sunken -indicatorcolor #ffffff", "-indicatorrelief {alternate raised} -indicatorcolor {pressed #ececec {!disabled alternate} #9fbdd8 {disabled alternate} #c0c0c0 {!disabled selected} #4a6984 {disabled selected} #a3a3a3}" },
    .{ "default", "TLabelframe", "-relief groove -borderwidth 2", "" },
    .{ "default", "TEntry", "-focuscolor #4a6984 -padding 1 -focuswidth 2 -fieldbackground white", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9}" },
    .{ "default", "Toolbutton", "-relief flat -padding 2", "-relief {disabled flat selected sunken pressed sunken active raised} -background {pressed #c3c3c3 active #ececec}" },
    .{ "default", "TCombobox", "-focuscolor #4a6984 -padding 1 -focuswidth 1 -fieldbackground white -arrowcolor black -arrowsize 12", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9} -arrowcolor {disabled #a3a3a3}" },
    .{ "default", "TSpinbox", "-focuscolor #4a6984 -padding {2 0 10 0} -focuswidth 1 -fieldbackground white -arrowcolor black -arrowsize 10", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9} -arrowcolor {disabled #a3a3a3}" },
    .{ "default", "TProgressbar", "-background #4a6984", "" },
    .{ "default", "TScale", "-sliderborderwidth 1 -sliderrelief raised", "" },
    .{ "default", "TScrollbar", "-width 12 -arrowsize 12", "-arrowcolor {disabled #a3a3a3}" },
    .{ "default", "TMenubutton", "-padding {10 3} -indicatorborderwidth 1 -relief raised", "" },
    .{ "default", "Treeview", "-focuscolor #4a6984 -foreground #000000 -focuswidth 1 -background #ffffff", "-foreground {disabled #a3a3a3 selected #ffffff} -background {disabled #d9d9d9 selected #4a6984}" },
    .{ "default", "Heading", "-relief raised -font TkHeadingFont", "" },
    .{ "classic", ".", "-highlightthickness 1 -borderwidth 1 -font TkDefaultFont -highlightcolor #d9d9d9 -background #d9d9d9 -selectbackground #c3c3c3 -troughcolor #b3b3b3 -focuswidth 0 -foreground black -selectforeground #000000 -indicatorcolor #d9d9d9 -insertwidth 2", "-highlightcolor {focus black} -foreground {disabled #a3a3a3} -background {disabled #d9d9d9 active #ececec}" },
    .{ "classic", "TButton", "-relief raised -padding {3m 1m} -anchor center -shiftrelief 1", "-relief {{!disabled pressed} sunken}" },
    .{ "classic", "TCheckbutton", "-indicatorrelief raised", "-indicatorrelief {alternate raised  selected sunken  pressed sunken} -indicatorcolor {pressed #d9d9d9 alternate #b05e5e selected #b03060}" },
    .{ "classic", "TRadiobutton", "-indicatorrelief raised", "-indicatorrelief {alternate raised  selected sunken  pressed sunken} -indicatorcolor {pressed #d9d9d9 alternate #b05e5e selected #b03060}" },
    .{ "classic", "TLabelframe", "-relief groove -borderwidth 2", "" },
    .{ "classic", "TEntry", "-font TkTextFont -padding 1 -relief sunken", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9}" },
    .{ "classic", "Toolbutton", "-focussolid 1 -relief flat -padding 2 -shiftrelief 2", "-relief {disabled flat selected sunken pressed sunken active raised} -background {pressed #b3b3b3 active #ececec}" },
    .{ "classic", "TCombobox", "-padding 1 -arrowsize 12", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9}" },
    .{ "classic", "TSpinbox", "-padding {2 0 10 0} -arrowsize 10", "-fieldbackground {readonly #d9d9d9 disabled #d9d9d9}" },
    .{ "classic", "TProgressbar", "-background SteelBlue", "" },
    .{ "classic", "TScale", "-sliderborderwidth 2 -sliderrelief raised", "-sliderrelief {{pressed !disabled} sunken}" },
    .{ "classic", "TScrollbar", "-relief raised -width 12 -arrowsize 12", "-relief {{pressed !disabled} sunken}" },
    .{ "classic", "TMenubutton", "-padding {3m 1m} -indicatorborderwidth 2 -relief raised", "" },
    .{ "classic", "Treeview", "-background #ffffff", "-foreground {disabled #a3a3a3 selected #000000} -background {disabled #d9d9d9 selected #c3c3c3}" },
    .{ "classic", "Heading", "-relief raised -font TkHeadingFont", "" },
};

/// The layouts of the themes of `wish` 8.6.16: theme, style, and layout.
const layouts = [_][3][]const u8{
    .{ "default", "TButton", "Button.border -sticky nswe -border 1 -children {Button.focus -sticky nswe -children {Button.padding -sticky nswe -children {Button.label -sticky nswe}}}" },
    .{ "default", "TCheckbutton", "Checkbutton.padding -sticky nswe -children {Checkbutton.indicator -side left -sticky {} Checkbutton.focus -side left -sticky w -children {Checkbutton.label -sticky nswe}}" },
    .{ "default", "TRadiobutton", "Radiobutton.padding -sticky nswe -children {Radiobutton.indicator -side left -sticky {} Radiobutton.focus -side left -sticky {} -children {Radiobutton.label -sticky nswe}}" },
    .{ "default", "TLabel", "Label.border -sticky nswe -border 1 -children {Label.padding -sticky nswe -border 1 -children {Label.label -sticky nswe}}" },
    .{ "default", "TFrame", "Frame.border -sticky nswe" },
    .{ "default", "TLabelframe", "Labelframe.border -sticky nswe" },
    .{ "default", "TEntry", "Entry.field -sticky nswe -border 1 -children {Entry.padding -sticky nswe -children {Entry.textarea -sticky nswe}}" },
    .{ "default", "TSeparator", "Separator.separator -sticky nswe" },
    .{ "default", "Horizontal.TSeparator", "Separator.separator -sticky nswe" },
    .{ "default", "Vertical.TSeparator", "Separator.separator -sticky nswe" },
    .{ "default", "TSizegrip", "Sizegrip.sizegrip -side bottom -sticky se" },
    .{ "default", "Toolbutton", "Toolbutton.border -sticky nswe -children {Toolbutton.focus -sticky nswe -children {Toolbutton.padding -sticky nswe -children {Toolbutton.label -sticky nswe}}}" },
    .{ "default", "TMenubutton", "Menubutton.border -sticky nswe -children {Menubutton.focus -sticky nswe -children {Menubutton.indicator -side right -sticky {} Menubutton.padding -sticky we -children {Menubutton.label -side left -sticky {}}}}" },
    .{ "default", "Horizontal.TScale", "Horizontal.Scale.focus -sticky nswe -children {Horizontal.Scale.padding -sticky nswe -children {Horizontal.Scale.trough -sticky nswe -children {Horizontal.Scale.slider -side left -sticky {}}}}" },
    .{ "default", "TCombobox", "Combobox.field -sticky nswe -children {Combobox.downarrow -side right -sticky ns Combobox.padding -sticky nswe -children {Combobox.textarea -sticky nswe}}" },
    .{ "default", "TSpinbox", "Spinbox.field -side top -sticky we -children {null -side right -sticky {} -children {Spinbox.uparrow -side top -sticky e Spinbox.downarrow -side bottom -sticky e} Spinbox.padding -sticky nswe -children {Spinbox.textarea -sticky nswe}}" },
    .{ "default", "Horizontal.TProgressbar", "Horizontal.Progressbar.trough -sticky nswe -children {Horizontal.Progressbar.pbar -side left -sticky ns}" },
    .{ "default", "Vertical.TProgressbar", "Vertical.Progressbar.trough -sticky nswe -children {Vertical.Progressbar.pbar -side bottom -sticky we}" },
    .{ "default", "Horizontal.TScrollbar", "Horizontal.Scrollbar.trough -sticky we -children {Horizontal.Scrollbar.leftarrow -side left -sticky {} Horizontal.Scrollbar.rightarrow -side right -sticky {} Horizontal.Scrollbar.thumb -sticky nswe}" },
    .{ "default", "Vertical.TScrollbar", "Vertical.Scrollbar.trough -sticky ns -children {Vertical.Scrollbar.uparrow -side top -sticky {} Vertical.Scrollbar.downarrow -side bottom -sticky {} Vertical.Scrollbar.thumb -sticky nswe}" },
    .{ "default", "Vertical.TScale", "Vertical.Scale.focus -sticky nswe -children {Vertical.Scale.padding -sticky nswe -children {Vertical.Scale.trough -sticky nswe -children {Vertical.Scale.slider -side top -sticky {}}}}" },
    .{ "classic", "TButton", "Button.highlight -sticky nswe -children {Button.border -sticky nswe -border 1 -children {Button.padding -sticky nswe -children {Button.label -sticky nswe}}}" },
};

/// The elements of the default theme and their options, from `wish` 8.6.16.
const elements = [_][2][]const u8{
    .{ "", "" },
    .{ "Checkbutton.indicator", "-background -indicatorcolor -indicatorrelief -indicatordiameter -indicatormargin -borderwidth" },
    .{ "Combobox.downarrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "Menubutton.indicator", "-background -indicatorwidth -indicatorheight -indicatorborderwidth -indicatorrelief -indicatormargin" },
    .{ "Radiobutton.indicator", "-background -indicatorcolor -indicatorrelief -indicatordiameter -indicatormargin -borderwidth" },
    .{ "Spinbox.downarrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "Spinbox.uparrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "Treeheading.cell", "-background -rownumber" },
    .{ "Treeitem.indicator", "-foreground -indicatorsize -indicatormargins" },
    .{ "Treeitem.row", "-background -rownumber" },
    .{ "arrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "background", "-background" },
    .{ "border", "-background -borderwidth -relief" },
    .{ "client", "-borderwidth -background -highlight -highlightcolor" },
    .{ "downarrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "field", "-fieldbackground -borderwidth -focuswidth -focuscolor" },
    .{ "fill", "-background" },
    .{ "focus", "-focuscolor -focusthickness -focussolid" },
    .{ "hsash", "-sashthickness" },
    .{ "hseparator", "-orient -background" },
    .{ "image", "-image -stipple -background" },
    .{ "indicator", "" },
    .{ "label", "-compound -space -text -font -foreground -underline -width -anchor -justify -wraplength -embossed -image -stipple -background" },
    .{ "leftarrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "padding", "-padding -relief -shiftrelief" },
    .{ "pbar", "-orient -thickness -barsize -pbarrelief -borderwidth -background" },
    .{ "rightarrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "separator", "-orient -background" },
    .{ "sizegrip", "-background" },
    .{ "slider", "-sliderlength -sliderthickness -sliderrelief -sliderborderwidth -background -orient" },
    .{ "tab", "-borderwidth -background -highlight -highlightcolor" },
    .{ "text", "-text -font -foreground -underline -width -anchor -justify -wraplength -embossed" },
    .{ "textarea", "-font -width" },
    .{ "thumb", "-orient -width -relief -background -borderwidth" },
    .{ "treearea", "" },
    .{ "trough", "-borderwidth -troughcolor -troughrelief" },
    .{ "uparrow", "-arrowsize -arrowcolor -background -borderwidth -relief" },
    .{ "vsash", "-sashthickness" },
    .{ "vseparator", "-orient -background" },
};

fn data(app: *App) *Data {
    return &app.ttk;
}

/// Makes the themes of `wish` with their settings.
pub fn setup(app: *App) !void {
    const d = data(app);
    const gpa = app.gpa;
    const names = [_][]const u8{ "clam", "alt", "default", "classic" };
    for (names) |n| {
        const parent: ?usize = if (std.mem.eql(u8, n, "default")) null else d.find("default");
        try d.themes.append(gpa, .{ .name = try gpa.dupe(u8, n), .parent = parent, .classic = std.mem.eql(u8, n, "classic") });
    }
    // `clam` and `alt` come before `default` in the list, as in `wish`.
    d.themes.items[0].parent = 2;
    d.themes.items[1].parent = 2;
    d.current = 2;
    const it = app.it;
    for (seeds) |row| {
        const t = d.find(row[0]).?;
        const conf = try it.list(.{ .str = row[2] });
        var i: usize = 0;
        while (i + 1 < conf.len) : (i += 2) try put(app, &d.themes.items[t].conf, row[1], try it.str(conf[i]), try it.str(conf[i + 1]), true);
        const map = try it.list(.{ .str = row[3] });
        i = 0;
        while (i + 1 < map.len) : (i += 2) try put(app, &d.themes.items[t].map, row[1], try it.str(map[i]), try it.str(map[i + 1]), true);
    }
}

fn put(app: *App, list: *std.ArrayListUnmanaged(Setting), st: []const u8, opt: []const u8, value: []const u8, seed: bool) !void {
    const gpa = app.gpa;
    for (list.items) |*s| if (std.mem.eql(u8, s.style, st) and std.mem.eql(u8, s.option, opt)) {
        const v = try gpa.dupe(u8, value);
        gpa.free(s.value);
        s.value = v;
        s.seed = seed;
        return;
    };
    const s1 = try gpa.dupe(u8, st);
    errdefer gpa.free(s1);
    const o1 = try gpa.dupe(u8, opt);
    errdefer gpa.free(o1);
    const v1 = try gpa.dupe(u8, value);
    errdefer gpa.free(v1);
    try list.append(gpa, .{ .style = s1, .option = o1, .value = v1, .seed = seed });
}

fn get(list: []const Setting, st: []const u8, opt: []const u8) ?[]const u8 {
    for (list) |s| if (std.mem.eql(u8, s.style, st) and std.mem.eql(u8, s.option, opt)) return s.value;
    return null;
}

// ---- states ----

/// The index of a state name in `state_names`.
pub fn stateIndex(name: []const u8) ?usize {
    for (state_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

pub const Spec = struct { on: u16 = 0, off: u16 = 0 };

/// Parses a state spec: a list of names, each with an optional `!`.
pub fn parseSpec(it: *ztcl.Interp, v: Value) ztcl.Error!Spec {
    var sp: Spec = .{};
    for (try it.list(v)) |e| {
        const word = try it.str(e);
        const neg = word.len > 0 and word[0] == '!';
        const name = if (neg) word[1..] else word;
        const i = stateIndex(name) orelse return it.fail("Invalid state name {s}", .{name});
        const bit = @as(u16, 1) << @intCast(i);
        if (neg) sp.off |= bit else sp.on |= bit;
    }
    return sp;
}

pub fn specMatches(sp: Spec, bits: u16) bool {
    return bits & sp.on == sp.on and bits & sp.off == 0;
}

// ---- the style sheet ----

fn validIdent(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}

/// Writes the selector of a style, with the text `tail` after each compound.
fn selector(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, st: []const u8, tail: []const u8) !bool {
    if (std.mem.eql(u8, st, ".")) {
        for (types, 0..) |t, i| {
            if (i > 0) try out.appendSlice(a, ", ");
            try out.print(a, "{s}{s}", .{ t, tail });
        }
        return true;
    }
    const dot = std.mem.lastIndexOfScalar(u8, st, '.');
    const ty = if (dot) |i| st[i + 1 ..] else st;
    if (!validIdent(ty)) return false;
    try out.appendSlice(a, ty);
    if (dot) |end| {
        var parts = std.mem.splitScalar(u8, st[0..end], '.');
        while (parts.next()) |p| {
            if (!validIdent(p)) return false;
            try out.print(a, ".{s}", .{p});
        }
    }
    try out.appendSlice(a, tail);
    return true;
}

fn isField(st: []const u8) bool {
    return std.mem.endsWith(u8, st, "TEntry") or std.mem.endsWith(u8, st, "TCombobox") or std.mem.endsWith(u8, st, "TSpinbox");
}

fn colorText(buf: *[7]u8, v: []const u8) ?[]const u8 {
    const c = geom.Color.parseTk(v) orelse return null;
    return c.formatTk(buf);
}

/// The CSS declaration and the part of one option, or null for an option with no CSS form.
fn declOf(it: *ztcl.Interp, a: std.mem.Allocator, st: []const u8, opt: []const u8, v: []const u8) !?struct { part: []const u8, text: []const u8 } {
    var buf: [7]u8 = undefined;
    const eq = std.mem.eql;
    if (eq(u8, opt, "-foreground")) {
        const c = colorText(&buf, v) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "color: {s};", .{c}) };
    }
    if ((eq(u8, opt, "-background") and !isField(st)) or (eq(u8, opt, "-fieldbackground") and isField(st))) {
        const c = colorText(&buf, v) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "background-color: {s};", .{c}) };
    }
    if (eq(u8, opt, "-bordercolor")) {
        const c = colorText(&buf, v) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "border-color: {s};", .{c}) };
    }
    if (eq(u8, opt, "-indicatorcolor")) {
        const c = colorText(&buf, v) orelse return null;
        return .{ .part = "::indicator", .text = try std.fmt.allocPrint(a, "background-color: {s};", .{c}) };
    }
    if (eq(u8, opt, "-borderwidth")) {
        const px = options.parsePixels(v, 96.0 / 72.0) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "border-width: {d}px;", .{@max(px, 0)}) };
    }
    if (eq(u8, opt, "-relief")) {
        if (eq(u8, v, "flat")) return .{ .part = "", .text = "border-style: solid; border-color: transparent;" };
        const r = style_mod.reliefOf(v) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "border-style: {s};", .{@tagName(r)}) };
    }
    if (eq(u8, opt, "-padding")) {
        const p = style_mod.parsePadding(v) orelse return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "padding: {d}px {d}px {d}px {d}px;", .{ p.top, p.right, p.bottom, p.left }) };
    }
    if (eq(u8, opt, "-font")) {
        const words = it.list(.{ .str = v }) catch return null;
        if (words.len < 2) return null;
        const fam = try it.str(words[0]);
        const size = std.fmt.parseInt(i32, try it.str(words[1]), 10) catch return null;
        const px: i32 = if (size < 0) -size else @divTrunc(size * 4 + 1, 3);
        var bold = false;
        for (words[2..]) |wd| if (eq(u8, try it.str(wd), "bold")) {
            bold = true;
        };
        if (!validIdent(std.mem.trim(u8, fam, " ")) and std.mem.indexOfAny(u8, fam, "\";{}") != null) return null;
        return .{ .part = "", .text = try std.fmt.allocPrint(a, "font-family: \"{s}\"; font-size: {d}px; font-weight: {s};", .{ fam, px, if (bold) "700" else "400" }) };
    }
    return null;
}

/// The settings of the current theme and its parents, as CSS.
fn sheetText(app: *App, a: std.mem.Allocator) ![]const u8 {
    const d = data(app);
    const it = app.it;
    var chain: [16]usize = undefined;
    var n: usize = 0;
    var t: ?usize = d.current;
    while (t) |i| : (t = d.themes.items[i].parent) {
        if (n == chain.len) break;
        chain[n] = i;
        n += 1;
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    // The parents first, so the settings of a child theme come later and win.
    var k = n;
    while (k > 0) {
        k -= 1;
        const th = &d.themes.items[chain[k]];
        // The style "." first, so the settings of a style win over it.
        for ([_]bool{ true, false }) |root| {
            for (th.conf.items) |s| {
                if (s.seed or std.mem.eql(u8, s.style, ".") != root) continue;
                const dc = (try declOf(it, a, s.style, s.option, s.value)) orelse continue;
                if (!try selector(&out, a, s.style, dc.part)) continue;
                try out.print(a, " {{ {s} }}\n", .{dc.text});
            }
            for (th.map.items) |s| {
                if (s.seed or std.mem.eql(u8, s.style, ".") != root) continue;
                const pairs = it.list(.{ .str = s.value }) catch continue;
                // The first pair that matches wins in Tk, and the last rule wins in CSS.
                var p = pairs.len / 2;
                while (p > 0) {
                    p -= 1;
                    const dc = (try declOf(it, a, s.style, s.option, try it.str(pairs[2 * p + 1]))) orelse continue;
                    var tail: std.ArrayListUnmanaged(u8) = .empty;
                    for (try it.list(pairs[2 * p])) |e| try tail.print(a, ":state({s})", .{try it.str(e)});
                    try tail.appendSlice(a, dc.part);
                    if (!try selector(&out, a, s.style, tail.items)) continue;
                    try out.print(a, " {{ {s} }}\n", .{dc.text});
                }
            }
        }
    }
    return out.items;
}

/// Makes the sheet of the settings again, and the theme sheets when the look changed.
pub fn rebuild(app: *App) !void {
    const d = data(app);
    var arena = std.heap.ArenaAllocator.init(app.gpa);
    defer arena.deinit();
    const text = try sheetText(app, arena.allocator());
    if (d.sheet != 0) app.styles.remove(d.sheet);
    d.sheet = 0;
    if (text.len > 0) d.sheet = try app.styles.add(.ttk, "ttk", text);
    try app.setLook(d.classic());
}

// ---- the command ----

/// The word of `list` that `word` names, or a unique prefix of it.
pub fn pick(it: *ztcl.Interp, word: []const u8, list: []const []const u8, what: []const u8) ztcl.Error!usize {
    var found: ?usize = null;
    for (list, 0..) |w, i| {
        if (std.mem.eql(u8, w, word)) return i;
        if (word.len > 0 and std.mem.startsWith(u8, w, word)) {
            if (found != null) {
                found = null;
                break;
            }
            found = i;
        }
    }
    if (found) |f| return f;
    return it.fail("{s} \"{s}\": must be {s}", .{ what, word, try joinOr(it.alloc(), list) });
}

/// "a, b, or c"
pub fn joinOr(a: std.mem.Allocator, list: []const []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (list, 0..) |w, i| {
        if (i > 0) try out.appendSlice(a, if (i + 1 == list.len) (if (list.len > 2) ", or " else " or ") else ", ");
        try out.appendSlice(a, w);
    }
    return out.items;
}

fn str(it: *ztcl.Interp, text: []const u8) ztcl.Error!Value {
    return .{ .str = try it.alloc().dupe(u8, text) };
}

fn flat(it: *ztcl.Interp, list: []const Setting, st: []const u8) ztcl.Error!Value {
    const a = it.alloc();
    var out: std.ArrayListUnmanaged(Value) = .empty;
    for (list) |s| if (std.mem.eql(u8, s.style, st)) {
        try out.append(a, .{ .str = try a.dupe(u8, s.option) });
        try out.append(a, .{ .str = try a.dupe(u8, s.value) });
    };
    return ztcl.value.newList(a, out.items);
}

/// The theme that `configure`, `map`, and `layout` change.
fn target(d: *const Data) usize {
    return d.target orelse d.current;
}

/// `ttk::style configure|map|lookup|layout|theme|element`
pub fn command(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("ttk::style option ?arg ...?");
    const subs = [_][]const u8{ "configure", "map", "lookup", "layout", "theme", "element" };
    const d = data(app);
    switch (try pick(it, try it.str(argv[1]), &subs, "bad command")) {
        0, 1 => |which| {
            const is_map = which == 1;
            const name = subs[which];
            if (argv.len < 3 or (argv.len > 4 and argv.len % 2 == 0)) return it.fail("wrong # args: should be \"ttk::style {s} style ?-option ?value...??\"", .{name});
            const st = try it.str(argv[2]);
            const th = &d.themes.items[target(d)];
            const list = if (is_map) &th.map else &th.conf;
            if (argv.len == 3) return flat(it, list.items, st);
            if (argv.len == 4) return str(it, get(list.items, st, try it.str(argv[3])) orelse "");
            var k: usize = 3;
            // Check each value of a map first, so an error changes nothing.
            if (is_map) while (k < argv.len) : (k += 2) {
                const pairs = try it.list(argv[k + 1]);
                if (pairs.len % 2 != 0) return it.fail("State map must have an even number of elements", .{});
                var p: usize = 0;
                while (p < pairs.len) : (p += 2) _ = try parseSpec(it, pairs[p]);
            };
            k = 3;
            while (k < argv.len) : (k += 2) try put(app, list, st, try it.str(argv[k]), try it.str(argv[k + 1]), false);
            try rebuild(app);
            return Value.empty;
        },
        2 => {
            if (argv.len < 4 or argv.len > 6) return it.wrongArgs("ttk::style lookup style -option ?state? ?default?");
            const opt = try it.str(argv[3]);
            const bits: u16 = if (argv.len >= 5) blk: {
                const sp = try parseSpec(it, argv[4]);
                break :blk sp.on;
            } else 0;
            if (try lookup(app, try it.str(argv[2]), opt, bits)) |v| return str(it, v);
            return if (argv.len == 6) argv[5] else Value.empty;
        },
        3 => {
            if (argv.len < 3 or argv.len > 4) return it.wrongArgs("ttk::style layout name ?spec?");
            const st = try it.str(argv[2]);
            const th = &d.themes.items[target(d)];
            if (argv.len == 4) {
                const spec = try it.str(argv[3]);
                for (th.layouts.items) |*l| if (std.mem.eql(u8, l.style, st)) {
                    const v = try app.gpa.dupe(u8, spec);
                    app.gpa.free(l.spec);
                    l.spec = v;
                    return Value.empty;
                };
                const s1 = try app.gpa.dupe(u8, st);
                errdefer app.gpa.free(s1);
                const v1 = try app.gpa.dupe(u8, spec);
                errdefer app.gpa.free(v1);
                try th.layouts.append(app.gpa, .{ .style = s1, .spec = v1 });
                return Value.empty;
            }
            if (layoutOf(d, st)) |l| return str(it, l);
            return it.fail("Layout {s} not found", .{st});
        },
        4 => return theme(app, it, argv),
        5 => return element(app, it, argv),
        else => unreachable,
    }
}

/// The value of an option of a style in a state: the map and then the
/// settings of the style, of each style that it builds on, and of ".",
/// in the current theme and its parents.
pub fn lookup(app: *App, st: []const u8, opt: []const u8, bits: u16) !?[]const u8 {
    const d = data(app);
    var t: ?usize = d.current;
    while (t) |i| : (t = d.themes.items[i].parent) {
        const th = &d.themes.items[i];
        var name = st;
        while (true) {
            if (get(th.map.items, name, opt)) |m| {
                const pairs = app.it.list(.{ .str = m }) catch &.{};
                var p: usize = 0;
                while (p + 1 < pairs.len) : (p += 2) {
                    const sp = parseSpec(app.it, pairs[p]) catch continue;
                    if (specMatches(sp, bits)) return try app.it.str(pairs[p + 1]);
                }
            }
            if (get(th.conf.items, name, opt)) |v| return v;
            if (std.mem.eql(u8, name, ".")) break;
            name = if (std.mem.indexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else ".";
        }
    }
    return null;
}

fn layoutOf(d: *const Data, st: []const u8) ?[]const u8 {
    var name = st;
    while (true) {
        var t: ?usize = d.current;
        while (t) |i| : (t = d.themes.items[i].parent) {
            const th = &d.themes.items[i];
            for (th.layouts.items) |l| if (std.mem.eql(u8, l.style, name)) return l.spec;
            for (layouts) |l| if (std.mem.eql(u8, l[0], th.name) and std.mem.eql(u8, l[1], name)) return l[2];
        }
        name = if (std.mem.indexOfScalar(u8, name, '.')) |dot| name[dot + 1 ..] else return null;
    }
}

/// Selects a theme by name for `theme use` and `ztk::style theme`.
pub fn useTheme(app: *App, name: []const u8) !bool {
    const d = data(app);
    const i = d.find(name) orelse return false;
    d.current = i;
    try rebuild(app);
    return true;
}

fn theme(app: *App, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(app);
    if (argv.len < 3) return it.wrongArgs("ttk::style theme option ?arg ...?");
    const subs = [_][]const u8{ "create", "names", "settings", "use" };
    switch (try pick(it, try it.str(argv[2]), &subs, "bad command")) {
        0 => {
            if (argv.len < 4 or argv.len % 2 != 0) return it.wrongArgs("ttk::style theme create name ?-option value ...?");
            const name = try it.str(argv[3]);
            if (d.find(name) != null) return it.fail("Theme {s} already exists", .{name});
            var parent: usize = d.find("default").?;
            var script: ?Value = null;
            var k: usize = 4;
            while (k < argv.len) : (k += 2) {
                const o = try it.str(argv[k]);
                if (std.mem.eql(u8, o, "-parent")) {
                    const pn = try it.str(argv[k + 1]);
                    parent = d.find(pn) orelse return it.fail("theme \"{s}\" doesn't exist", .{pn});
                } else if (std.mem.eql(u8, o, "-settings")) {
                    script = argv[k + 1];
                } else return it.fail("bad option \"{s}\": must be -parent or -settings", .{o});
            }
            try d.themes.append(app.gpa, .{ .name = try app.gpa.dupe(u8, name), .parent = parent, .classic = d.themes.items[parent].classic });
            if (script) |s| return settings(app, it, d.themes.items.len - 1, s);
            return Value.empty;
        },
        1 => {
            // `wish` accepts more words here.
            const a = it.alloc();
            const items = try a.alloc(Value, d.themes.items.len);
            for (d.themes.items, items) |t, *v| v.* = .{ .str = try a.dupe(u8, t.name) };
            return ztcl.value.newList(a, items);
        },
        2 => {
            if (argv.len != 5) return it.wrongArgs("ttk::style theme settings theme script");
            const name = try it.str(argv[3]);
            const i = d.find(name) orelse return it.fail("theme \"{s}\" doesn't exist", .{name});
            return settings(app, it, i, argv[4]);
        },
        3 => {
            if (argv.len > 4) return it.wrongArgs("ttk::style theme use ?theme?");
            if (argv.len == 3) return str(it, d.themes.items[d.current].name);
            const name = try it.str(argv[3]);
            if (!try useTheme(app, name)) return it.fail("theme \"{s}\" doesn't exist", .{name});
            return Value.empty;
        },
        else => unreachable,
    }
}

fn settings(app: *App, it: *ztcl.Interp, i: usize, script: Value) ztcl.Error!Value {
    const d = data(app);
    const saved = d.target;
    d.target = i;
    defer d.target = saved;
    _ = try it.eval(try it.str(script));
    return Value.empty;
}

fn element(app: *App, it: *ztcl.Interp, argv: []const Value) ztcl.Error!Value {
    const d = data(app);
    if (argv.len < 3) return it.wrongArgs("ttk::style element option ?arg ...?");
    const subs = [_][]const u8{ "create", "names", "options" };
    const a = it.alloc();
    switch (try pick(it, try it.str(argv[2]), &subs, "bad command")) {
        0 => {
            if (argv.len < 5) return it.wrongArgs("ttk::style element create name type ?-option value ...?");
            const name = try it.str(argv[3]);
            const ty = try it.str(argv[4]);
            if (!std.mem.eql(u8, ty, "from") and !std.mem.eql(u8, ty, "image")) return it.fail("No such element type {s}", .{ty});
            if (elementKnown(d, name)) return it.fail("Duplicate element {s}", .{name});
            try d.elements.append(app.gpa, try app.gpa.dupe(u8, name));
            return Value.empty;
        },
        1 => {
            if (argv.len != 3) return it.wrongArgs("ttk::style element names");
            var out: std.ArrayListUnmanaged(Value) = .empty;
            for (elements) |e| try out.append(a, .{ .str = e[0] });
            for (d.elements.items) |e| try out.append(a, .{ .str = try a.dupe(u8, e) });
            return ztcl.value.newList(a, out.items);
        },
        2 => {
            if (argv.len != 4) return it.wrongArgs("ttk::style element options element");
            const name = try it.str(argv[3]);
            for (elements) |e| if (std.mem.eql(u8, e[0], name)) return str(it, e[1]);
            // Tk finds the element of the last part of a name.
            if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| for (elements) |e| if (std.mem.eql(u8, e[0], name[dot + 1 ..])) return str(it, e[1]);
            return Value.empty;
        },
        else => unreachable,
    }
}

fn elementKnown(d: *const Data, name: []const u8) bool {
    for (elements) |e| if (std.mem.eql(u8, e[0], name)) return true;
    for (d.elements.items) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}
