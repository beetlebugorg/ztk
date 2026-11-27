//! `ztk::debug`: answers to "why is this widget like this".
//!
//! `ztk::debug sources on` makes each option write keep a `Source` on its
//! slot: the kind of call (create, configure, animate, or internal), the
//! source text of the command and its line, the words with their values,
//! the value before the write, the file of `info script`, and the call
//! stack of procs. Each later write of the same option replaces the
//! record and counts up. While recording is off, an option write reads
//! one flag of the App and keeps nothing.
//!
//! `ztk::debug why path ?option?` gives the source of an option. An
//! option that no call set gives `default`, or `style` for an option
//! that `cget` reads from the computed style. For an option with a
//! matching CSS property, the answer also names the winning declaration:
//! its sheet, origin, and line. `StyleSet.explain` finds it with the sort
//! order of `compute`. A property that inherits and has no declaration on
//! the widget gives the declaration of the nearest ancestor that has one.
//!
//! `ztk::debug geometry path` gives the chain from the widget up to its
//! toplevel: the requested size, the box, the geometry manager and its
//! `info`, the propagation of the container, and notes that compare the
//! requested size with the box.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const widget_mod = @import("widget.zig");
const options = @import("options.zig");
const css_parse = @import("css/parse.zig");
const style_mod = @import("style.zig");
const App = app_mod.App;
const Widget = widget_mod.Widget;
const Value = ztcl.Value;

pub const State = struct {
    /// True while option writes keep their source.
    sources: bool = false,
    /// The command site of the widget call that runs, for its line.
    site: ?*ztcl.interp.Cmd = null,
    /// Counts the recorded writes, so two sources can be ordered.
    seq: u64 = 0,
};

pub const Kind = enum { create, configure, animate, internal };

/// The last write of one option. All text is owned by the App allocator.
pub const Source = struct {
    kind: Kind,
    seq: u64,
    /// The count of recorded writes of this option.
    count: u32,
    /// The source text of the command, before substitution.
    code: []u8,
    /// The words of the call with their values.
    call: []u8,
    /// The line of the command in its own script: a proc body, a
    /// binding script, or the file.
    line: u32,
    /// The value of `info script` at the write.
    file: []u8,
    /// The value before the write.
    prev: []u8,
    /// One entry for each proc frame, innermost first: the words of the call.
    stack: [][]u8,

    pub fn free(s: *Source, gpa: std.mem.Allocator) void {
        gpa.free(s.code);
        gpa.free(s.call);
        gpa.free(s.file);
        gpa.free(s.prev);
        for (s.stack) |f| gpa.free(f);
        gpa.free(s.stack);
        gpa.destroy(s);
    }
};

/// The longest text of one stack frame or call. Longer text ends in "...".
const max_text = 200;
/// The deepest stack that a source keeps.
const max_frames = 16;

fn clip(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len <= max_text) return gpa.dupe(u8, text);
    return std.mem.concat(gpa, u8, &.{ text[0 .. max_text - 3], "..." });
}

/// Records the write of option `i` of `w`. `pairs` are the option words
/// of a create or configure call. A failure to allocate keeps the old record.
pub fn note(w: *Widget, it: *ztcl.Interp, i: usize, kind: Kind, pairs: []const Value, prev: []const u8) void {
    noteOrFail(w, it, i, kind, pairs, prev) catch {};
}

fn noteOrFail(w: *Widget, it: *ztcl.Interp, i: usize, kind: Kind, pairs: []const Value, prev: []const u8) !void {
    const app = w.app;
    const gpa = app.gpa;
    const a = it.alloc();
    const site: ?*ztcl.interp.Cmd = if (kind == .create or kind == .configure) app.dbg.site else null;
    var words: std.ArrayList(Value) = .empty;
    switch (kind) {
        .create => try words.appendSlice(a, &.{ .{ .str = w.class.command }, .{ .str = w.path } }),
        .configure => try words.appendSlice(a, &.{ .{ .str = w.path }, .{ .str = "configure" } }),
        .animate, .internal => {},
    }
    try words.appendSlice(a, pairs);
    const call = try clip(gpa, try it.str(try ztcl.value.newList(a, words.items)));
    errdefer gpa.free(call);
    const code = try clip(gpa, if (site) |c| c.text else "");
    errdefer gpa.free(code);
    const file = try gpa.dupe(u8, it.script_name);
    errdefer gpa.free(file);
    const prev_own = try clip(gpa, prev);
    errdefer gpa.free(prev_own);
    var frames: std.ArrayList([]u8) = .empty;
    errdefer {
        for (frames.items) |f| gpa.free(f);
        frames.deinit(gpa);
    }
    var f: ?*ztcl.interp.Frame = it.frame;
    while (f) |fr| : (f = fr.parent) {
        if (fr.argv.len == 0) continue;
        if (frames.items.len == max_frames) break;
        const text = try it.str(try ztcl.value.newList(a, fr.argv));
        try frames.append(gpa, try clip(gpa, text));
    }
    const stack = try frames.toOwnedSlice(gpa);
    const slot = &w.opts[i];
    const count: u32 = if (slot.src) |old| old.count +| 1 else 1;
    const s = gpa.create(Source) catch |e| {
        for (stack) |x| gpa.free(x);
        gpa.free(stack);
        return e;
    };
    app.dbg.seq += 1;
    s.* = .{ .kind = kind, .seq = app.dbg.seq, .count = count, .code = code, .call = call, .line = if (site) |c| c.line else 0, .file = file, .prev = prev_own, .stack = stack };
    if (slot.src) |old| old.free(gpa);
    slot.src = s;
}

pub fn register(it: *ztcl.Interp) !void {
    try it.register("ztk::debug", cmdDebug);
}

const usage = "ztk::debug sources ?on|off? | why pathName ?option? ?-all? | geometry pathName";

fn cmdDebug(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const app = App.of(it);
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "sources")) {
        if (argv.len > 3) return it.wrongArgs("ztk::debug sources ?on|off?");
        if (argv.len == 3) {
            const on = options.parseBool(try it.str(argv[2])) orelse return it.fail("expected boolean value but got \"{s}\"", .{try it.str(argv[2])});
            app.dbg.sources = on;
            if (!on) app.dbg.site = null;
        }
        return .{ .int = @intFromBool(app.dbg.sources) };
    }
    if (std.mem.eql(u8, sub, "why")) return cmdWhy(it, app, argv[2..]);
    if (std.mem.eql(u8, sub, "geometry")) {
        if (argv.len != 3) return it.wrongArgs("ztk::debug geometry pathName");
        return cmdGeometry(it, app, try it.str(argv[2]));
    }
    return it.fail("bad option \"{s}\": must be geometry, sources, or why", .{sub});
}

fn widgetOf(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!*Widget {
    return app.lookup(path) orelse it.fail("bad window path name \"{s}\"", .{path});
}

fn cmdWhy(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len < 1 or args.len > 3) return it.wrongArgs("ztk::debug why pathName ?option? ?-all?");
    const w = try widgetOf(it, app, try it.str(args[0]));
    var all = false;
    var name: ?[]const u8 = null;
    for (args[1..]) |v| {
        const t = try it.str(v);
        if (std.mem.eql(u8, t, "-all")) all = true else if (name == null) name = t else return it.wrongArgs("ztk::debug why pathName ?option? ?-all?");
    }
    const a = it.alloc();
    const specs = w.class.specs;
    if (name) |n| {
        var i = try options.find(it, specs, n);
        if (specs[i].type == .synonym) i = try options.find(it, specs, specs[i].target);
        return why(it, w, i);
    }
    // Each option that a call or a style set, or every option with -all.
    var items: std.ArrayList(Value) = .empty;
    for (specs, 0..) |sp, i| {
        if (sp.hidden or sp.type == .synonym) continue;
        const slot = w.opts[i];
        if (!all and !slot.set and !(sp.from_style and sp.style_prop != .none) and !variableText(w, i)) continue;
        try items.append(a, try why(it, w, i));
    }
    return ztcl.value.wrapList(a, items.items);
}

/// True when option `i` is the `-text` that a `-textvariable` shows.
fn variableText(w: *Widget, i: usize) bool {
    const f = w.class.variable_text orelse return false;
    return std.mem.eql(u8, w.class.specs[i].name, "-text") and f(w) != null;
}

/// The CSS properties that give the look of an option.
fn cssProps(name: []const u8) []const css_parse.Prop {
    const eql = std.mem.eql;
    if (eql(u8, name, "-background")) return &.{ .background_color, .background };
    if (eql(u8, name, "-foreground")) return &.{.color};
    if (eql(u8, name, "-borderwidth")) return &.{ .border_width, .border };
    if (eql(u8, name, "-relief")) return &.{ .border_style, .border };
    if (eql(u8, name, "-font")) return &.{ .font_family, .font_size, .font_weight };
    if (eql(u8, name, "-padx") or eql(u8, name, "-pady") or eql(u8, name, "-padding"))
        return &.{ .padding, .padding_top, .padding_right, .padding_bottom, .padding_left };
    if (eql(u8, name, "-cursor")) return &.{.cursor};
    if (eql(u8, name, "-insertbackground")) return &.{.caret_color};
    return &.{};
}

fn inherits(p: css_parse.Prop) bool {
    return switch (p) {
        .color, .font_family, .font_size, .font_weight, .cursor, .text_align, .caret_color => true,
        else => false,
    };
}

/// The text of a declaration: `name: value`.
fn declText(a: std.mem.Allocator, d: css_parse.Decl) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(a, "{s}: ", .{d.name});
    for (d.value) |t| switch (t) {
        .ident => |x| try out.appendSlice(a, x),
        .function => |x| try out.print(a, "{s}(", .{x}),
        .at_keyword => |x| try out.print(a, "@{s}", .{x}),
        .hash => |x| try out.print(a, "#{s}", .{x}),
        .string => |x| try out.print(a, "\"{s}\"", .{x}),
        .number => |n| try out.print(a, "{d}", .{n}),
        .dimension => |dm| try out.print(a, "{d}{s}", .{ dm.value, dm.unit }),
        .percentage => |n| try out.print(a, "{d}%", .{n}),
        .delim => |c| try out.append(a, c),
        .colon => try out.append(a, ':'),
        .semicolon => try out.append(a, ';'),
        .comma => try out.append(a, ','),
        .lparen => try out.append(a, '('),
        .rparen => try out.append(a, ')'),
        .lbracket => try out.append(a, '['),
        .rbracket => try out.append(a, ']'),
        .lbrace => try out.append(a, '{'),
        .rbrace => try out.append(a, '}'),
        .whitespace => try out.append(a, ' '),
        .eof => {},
    };
    return out.items;
}

/// The style part of an answer: the winning declaration for the CSS
/// properties of the option, on the widget or the nearest ancestor for a
/// property that inherits. Null when no sheet sets the properties.
fn styleWhy(it: *ztcl.Interp, w: *Widget, props: []const css_parse.Prop) ztcl.Error!?Value {
    if (props.len == 0) return null;
    const a = it.alloc();
    const app = w.app;
    var cur: ?*Widget = w;
    while (cur) |c| : (cur = c.parent) {
        if (app.styles.explain(c, app.env, props)) |e| {
            var fields: std.ArrayList(Value) = .empty;
            try fields.appendSlice(a, &.{
                .{ .str = "sheet" },  .{ .str = try a.dupe(u8, e.sheet) },
                .{ .str = "origin" }, .{ .str = @tagName(e.origin) },
                .{ .str = "line" },   .{ .int = e.decl.line },
                .{ .str = "decl" },   .{ .str = try declText(a, e.decl) },
            });
            if (c != w) try fields.appendSlice(a, &.{ .{ .str = "inherited" }, .{ .str = try a.dupe(u8, c.path) } });
            return try ztcl.value.wrapList(a, fields.items);
        }
        if (!inherits(props[0])) break;
    }
    return null;
}

/// The answer for option `i`: a dict with the option, the value, the
/// source, and the fields of the source.
fn why(it: *ztcl.Interp, w: *Widget, i: usize) ztcl.Error!Value {
    const a = it.alloc();
    const sp = w.class.specs[i];
    const slot = w.opts[i];
    var d: std.ArrayList(Value) = .empty;
    try d.appendSlice(a, &.{
        .{ .str = "option" }, .{ .str = sp.name },
        .{ .str = "value" },  .{ .str = try a.dupe(u8, try options.textOf(w, it, i)) },
    });
    if (variableText(w, i)) {
        const v = if (options.maybe(w, "-textvariable")) |s| s.text else "";
        try d.appendSlice(a, &.{ .{ .str = "source" }, .{ .str = "variable" }, .{ .str = "variable" }, .{ .str = try a.dupe(u8, v) } });
    } else if (slot.src) |s| {
        try d.appendSlice(a, &.{
            .{ .str = "source" }, .{ .str = @tagName(s.kind) },
            .{ .str = "code" },   .{ .str = try a.dupe(u8, s.code) },
            .{ .str = "call" },   .{ .str = try a.dupe(u8, s.call) },
            .{ .str = "file" },   .{ .str = try a.dupe(u8, s.file) },
            .{ .str = "line" },   .{ .int = s.line },
            .{ .str = "proc" },   .{ .str = if (s.stack.len > 0) try a.dupe(u8, firstWord(s.stack[0])) else "" },
            .{ .str = "prev" },   .{ .str = try a.dupe(u8, s.prev) },
            .{ .str = "count" },  .{ .int = s.count },
            .{ .str = "seq" },    .{ .int = @intCast(s.seq) },
        });
        const st = try a.alloc(Value, s.stack.len);
        for (s.stack, st) |x, *o| o.* = .{ .str = try a.dupe(u8, x) };
        try d.appendSlice(a, &.{ .{ .str = "stack" }, try ztcl.value.wrapList(a, st) });
    } else if (slot.set) {
        // Set while recording was off.
        try d.appendSlice(a, &.{ .{ .str = "source" }, .{ .str = "call" } });
    } else if (sp.from_style and sp.style_prop != .none) {
        try d.appendSlice(a, &.{ .{ .str = "source" }, .{ .str = "style" } });
    } else {
        try d.appendSlice(a, &.{ .{ .str = "source" }, .{ .str = "default" }, .{ .str = "default" }, .{ .str = sp.default } });
    }
    if (try styleWhy(it, w, cssProps(sp.name))) |s| {
        // A set option overrides the style. The field names what the
        // option overrides, or what draws the widget while it is unset.
        try d.appendSlice(a, &.{ .{ .str = if (slot.set) "overrides" else "style" }, s });
    }
    return ztcl.value.wrapList(a, d.items);
}

fn firstWord(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse text.len;
    return text[0..end];
}

fn cmdGeometry(it: *ztcl.Interp, app: *App, path: []const u8) ztcl.Error!Value {
    _ = try widgetOf(it, app, path);
    try app.flush();
    // A script in the flush can delete the widget.
    var cur: ?*Widget = try widgetOf(it, app, path);
    const a = it.alloc();
    var levels: std.ArrayList(Value) = .empty;
    while (cur) |w| : (cur = w.parent) {
        try levels.append(a, try level(it, w));
        if (w.isToplevel()) break;
    }
    return ztcl.value.wrapList(a, levels.items);
}

fn level(it: *ztcl.Interp, w: *Widget) ztcl.Error!Value {
    const a = it.alloc();
    var d: std.ArrayList(Value) = .empty;
    const req = try ztcl.value.newList(a, &.{ .{ .int = w.req.w }, .{ .int = w.req.h } });
    const box = try ztcl.value.newList(a, &.{ .{ .int = w.geom.x }, .{ .int = w.geom.y }, .{ .int = w.geom.w }, .{ .int = w.geom.h } });
    try d.appendSlice(a, &.{
        .{ .str = "widget" }, .{ .str = try a.dupe(u8, w.path) },
        .{ .str = "class" },  .{ .str = try a.dupe(u8, w.tk_class) },
        .{ .str = "req" },    req,
        .{ .str = "box" },    box,
        .{ .str = "mapped" }, .{ .int = @intFromBool(w.mapped) },
    });
    // The options that fix the requested size.
    var sized: std.ArrayList(Value) = .empty;
    for (w.class.specs, w.opts) |sp, slot| {
        if (!slot.set) continue;
        if (std.mem.eql(u8, sp.name, "-width") or std.mem.eql(u8, sp.name, "-height")) {
            try sized.appendSlice(a, &.{ .{ .str = sp.name }, .{ .str = try a.dupe(u8, slot.text) } });
        }
    }
    if (sized.items.len > 0) try d.appendSlice(a, &.{ .{ .str = "size" }, try ztcl.value.wrapList(a, sized.items) });
    if (w.container_manager) |cm| if (cm.propagates) |f| {
        try d.appendSlice(a, &.{ .{ .str = "propagate" }, .{ .int = @intFromBool(f(w)) } });
    };
    var notes: std.ArrayList(Value) = .empty;
    if (w.manager) |m| {
        try d.appendSlice(a, &.{ .{ .str = "manager" }, .{ .str = m.name } });
        const cmd = try ztcl.value.newList(a, &.{ .{ .str = m.name }, .{ .str = "info" }, .{ .str = w.path } });
        if (it.eval(try it.str(cmd))) |v| {
            try d.appendSlice(a, &.{ .{ .str = "info" }, .{ .str = try a.dupe(u8, try it.str(v)) } });
        } else |_| {}
        if (w.mapped) {
            if (w.geom.w < w.req.w) try notes.append(a, .{ .str = try std.fmt.allocPrint(a, "narrower than requested by {d}: the container has no more space", .{w.req.w - w.geom.w}) });
            if (w.geom.h < w.req.h) try notes.append(a, .{ .str = try std.fmt.allocPrint(a, "shorter than requested by {d}: the container has no more space", .{w.req.h - w.geom.h}) });
            if (w.geom.w > w.req.w) try notes.append(a, .{ .str = try std.fmt.allocPrint(a, "wider than requested by {d}: fill, expand, or sticky", .{w.geom.w - w.req.w}) });
            if (w.geom.h > w.req.h) try notes.append(a, .{ .str = try std.fmt.allocPrint(a, "taller than requested by {d}: fill, expand, or sticky", .{w.geom.h - w.req.h}) });
        } else if (w.parent != null and !w.parent.?.mapped) {
            try notes.append(a, .{ .str = "not mapped: the container is not mapped" });
        } else if (w.geom.w <= 0 or w.geom.h <= 0) {
            try notes.append(a, .{ .str = "not mapped: the container gives it no space" });
        } else {
            try notes.append(a, .{ .str = "not mapped" });
        }
    } else if (!w.isToplevel()) {
        try d.appendSlice(a, &.{ .{ .str = "manager" }, .{ .str = "" } });
        try notes.append(a, .{ .str = "not mapped: no geometry manager (pack, grid, or place)" });
    }
    if (notes.items.len > 0) try d.appendSlice(a, &.{ .{ .str = "notes" }, try ztcl.value.wrapList(a, notes.items) });
    return ztcl.value.wrapList(a, d.items);
}
