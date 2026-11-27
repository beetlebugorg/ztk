//! `ztk::debug`: answers to "why is this widget like this".
//!
//! `ztk::debug sources on` makes each option write keep a `Source` on its
//! slot: the kind of call (create, configure, animate, or internal), the
//! source text of the command and its line, the words with their values,
//! the value before the write, the file of `info script`, and the call
//! stack of procs. Each later write of the same option replaces the
//! record and counts up. While recording is off, an option write reads
//! one flag of the App and keeps no record.
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
//!
//! `ztk::debug trace` keeps the records of `debugtrace.zig`. The hooks
//! in the event delivery, the layout, the frame, the focus, the grab,
//! and `Widget.invalidate` test `trace.mask` first and call the
//! functions here only while the trace is on.
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
const trace_mod = @import("debugtrace.zig");
const diff_mod = @import("debugdiff.zig");
const bind = @import("bind.zig");
const geom = @import("geom.zig");

pub const State = struct {
    /// True while an option write calls `note`: the sources or the
    /// option records of the trace are on.
    sources: bool = false,
    /// True while option writes keep their source.
    keep: bool = false,
    /// True while a new widget takes the values of the option database.
    from_db: bool = false,
    trace: trace_mod.Trace = .{},
    /// The marks of `ztk::debug mark`, by name. The keys are owned.
    marks: diff_mod.Marks = .empty,
    /// The command site of the widget call that runs, for its line.
    site: ?*ztcl.interp.Cmd = null,
    /// Counts the recorded writes and the trace records, so two can be ordered.
    seq: u64 = 0,

    /// Sets the gate of `note` from the record and the trace.
    pub fn update(s: *State) void {
        s.sources = s.keep or s.trace.on(.option);
        if (!s.sources) s.site = null;
    }

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        s.trace.deinit(gpa);
        diff_mod.deinit(&s.marks, gpa);
    }
};

/// `optiondb`: a value of the option database (`option add`) that a new
/// widget took.
pub const Kind = enum { create, configure, animate, internal, optiondb };

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
        .optiondb => try words.appendSlice(a, &.{ .{ .str = "option" }, .{ .str = "get" }, .{ .str = w.path } }),
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
    app.dbg.seq += 1;
    if (app.dbg.trace.on(.option)) {
        const proc: []const u8 = if (stack.len > 0) firstWord(stack[0]) else "";
        record(app, app.dbg.seq, .option, w.path, &.{
            .{ .str = "option" }, .{ .str = w.class.specs[i].name },
            .{ .str = "value" },  .{ .str = w.opts[i].text },
            .{ .str = "prev" },   .{ .str = prev_own },
            .{ .str = "source" }, .{ .str = @tagName(kind) },
            .{ .str = "code" },   .{ .str = code },
            .{ .str = "line" },   .{ .int = if (site) |c| c.line else 0 },
            .{ .str = "proc" },   .{ .str = proc },
        });
        app.dbg.trace.reason = app.dbg.seq;
    }
    if (!app.dbg.keep) {
        for (stack) |x| gpa.free(x);
        gpa.free(stack);
        gpa.free(call);
        gpa.free(code);
        gpa.free(file);
        gpa.free(prev_own);
        return;
    }
    const slot = &w.opts[i];
    const count: u32 = if (slot.src) |old| old.count +| 1 else 1;
    const s = gpa.create(Source) catch |e| {
        for (stack) |x| gpa.free(x);
        gpa.free(stack);
        return e;
    };
    s.* = .{ .kind = kind, .seq = app.dbg.seq, .count = count, .code = code, .call = call, .line = if (site) |c| c.line else 0, .file = file, .prev = prev_own, .stack = stack };
    if (slot.src) |old| old.free(gpa);
    slot.src = s;
}

/// The short answers and the MCP tools, as Tcl procs.
const library = @embedFile("library/debug.tcl");

pub fn register(it: *ztcl.Interp) !void {
    try it.register("ztk::debug", cmdDebug);
    _ = it.eval(library) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => @panic("src/library/debug.tcl failed"),
    };
}

/// The subcommands that the procs of `library` answer, with their usage.
const short_cmds = [_]struct { name: []const u8, usage: []const u8, min: usize, max: usize }{
    .{ .name = "explain", .usage = "ztk::debug explain pathName ?option?", .min = 1, .max = 2 },
    .{ .name = "ran", .usage = "ztk::debug ran ?seq?", .min = 0, .max = 1 },
    .{ .name = "click", .usage = "ztk::debug click pathName ?button?", .min = 1, .max = 2 },
    .{ .name = "type", .usage = "ztk::debug type text ?pathName?", .min = 1, .max = 2 },
    .{ .name = "changes", .usage = "ztk::debug changes name", .min = 1, .max = 1 },
    .{ .name = "tree", .usage = "ztk::debug tree ?pathName?", .min = 0, .max = 1 },
};

const usage = "ztk::debug sources ?on|off? | why pathName ?option? ?-all? | geometry pathName | trace subcommand ?arg ...? | mark name ?pathName? | diff name ?-image? ?-tolerance n? | marks | forget name | explain pathName ?option? | ran ?seq? | click pathName ?button? | type text ?pathName? | changes name | tree ?pathName?";

fn cmdDebug(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len < 2) return it.wrongArgs(usage);
    const app = App.of(it);
    const sub = try it.str(argv[1]);
    if (std.mem.eql(u8, sub, "sources")) {
        if (argv.len > 3) return it.wrongArgs("ztk::debug sources ?on|off?");
        if (argv.len == 3) {
            const on = options.parseBool(try it.str(argv[2])) orelse return it.fail("expected boolean value but got \"{s}\"", .{try it.str(argv[2])});
            app.dbg.keep = on;
            app.dbg.update();
        }
        return .{ .int = @intFromBool(app.dbg.keep) };
    }
    inline for (short_cmds) |c| if (std.mem.eql(u8, sub, c.name)) {
        const n = argv.len - 2;
        if (n < c.min or n > c.max) return it.wrongArgs(c.usage);
        const a = it.alloc();
        const words = try a.alloc(Value, argv.len - 1);
        words[0] = .{ .str = try std.mem.concat(a, u8, &.{ "::ztk::priv::dbg::", c.name }) };
        @memcpy(words[1..], argv[2..]);
        return it.eval(try it.str(try ztcl.value.newList(a, words)));
    };
    if (std.mem.eql(u8, sub, "why")) return cmdWhy(it, app, argv[2..]);
    if (std.mem.eql(u8, sub, "trace")) return cmdTrace(it, app, argv[2..]);
    if (std.mem.eql(u8, sub, "mark")) return cmdMark(it, app, argv[2..]);
    if (std.mem.eql(u8, sub, "diff")) return cmdDiff(it, app, argv[2..]);
    if (std.mem.eql(u8, sub, "marks")) {
        if (argv.len != 2) return it.wrongArgs("ztk::debug marks");
        var names: std.ArrayList(Value) = .empty;
        var iter = app.dbg.marks.keyIterator();
        while (iter.next()) |k| try names.append(it.alloc(), .{ .str = try it.alloc().dupe(u8, k.*) });
        std.mem.sort(Value, names.items, {}, lessStr);
        return ztcl.value.wrapList(it.alloc(), names.items);
    }
    if (std.mem.eql(u8, sub, "forget")) {
        if (argv.len != 3) return it.wrongArgs("ztk::debug forget name");
        if (app.dbg.marks.fetchRemove(try it.str(argv[2]))) |kv| {
            app.gpa.free(kv.key);
            kv.value.free(app.gpa);
        }
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "geometry")) {
        if (argv.len != 3) return it.wrongArgs("ztk::debug geometry pathName");
        return cmdGeometry(it, app, try it.str(argv[2]));
    }
    return it.fail("bad option \"{s}\": must be changes, click, diff, explain, forget, geometry, mark, marks, ran, sources, trace, tree, type, or why", .{sub});
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

// ---- The trace ----

/// Adds a trace record with the fields as one Tcl dict.
pub fn record(app: *App, seq: u64, kind: trace_mod.Kind, widget: []const u8, fields: []const Value) void {
    const it = app.it;
    const text = it.str(ztcl.value.newList(it.alloc(), fields) catch return) catch return;
    app.dbg.trace.add(app.gpa, seq, app.platform.nowUs(), kind, widget, text);
}

/// Adds a record with a new number and gives the number.
pub fn add(app: *App, kind: trace_mod.Kind, widget: []const u8, fields: []const Value) u64 {
    app.dbg.seq += 1;
    record(app, app.dbg.seq, kind, widget, fields);
    return app.dbg.seq;
}

/// An event that reaches a widget. Gives the number for the cause of
/// the records of its bindings, or 0 when the kind is off.
pub fn event(app: *App, ev: *const bind.WidgetEvent) u64 {
    const t = &app.dbg.trace;
    const motion = switch (ev.type) {
        .motion, .enter, .leave => true,
        else => false,
    };
    if (!t.on(if (motion) .motion else .event)) return 0;
    var buf: [64]u8 = undefined;
    const detail: u32 = switch (ev.type) {
        .button_press, .button_release => ev.button,
        .key_press, .key_release => ev.keysym,
        else => 0,
    };
    var name = bind.formatPattern(.{ .type = ev.type, .detail = detail, .virtual = ev.virtual }, &buf);
    // The short form of a key ("a") gets its type, so each name has the form <Type-detail>.
    var long: [80]u8 = undefined;
    if (name.len > 0 and name[0] != '<') {
        name = std.fmt.bufPrint(&long, "<KeyPress-{s}>", .{name}) catch name;
    } else if (std.mem.startsWith(u8, name, "<Key-")) {
        name = std.fmt.bufPrint(&long, "<KeyPress-{s}", .{name[5..]}) catch name;
    }
    return add(app, if (motion) .motion else .event, ev.widget.path, &.{
        .{ .str = "event" }, .{ .str = name },
        .{ .str = "x" },     .{ .int = ev.x },
        .{ .str = "y" },     .{ .int = ev.y },
        .{ .str = "text" },  .{ .str = ev.text },
    });
}

/// A binding that runs for an event.
pub fn binding(app: *App, w: *const Widget, tag: []const u8, pattern: bind.Pattern, script: []const u8) void {
    if (!app.dbg.trace.on(.binding)) return;
    // The bindings of pointer motion follow the kind `motion`.
    switch (pattern.type) {
        .motion, .enter, .leave => if (!app.dbg.trace.on(.motion)) return,
        else => {},
    }
    var buf: [64]u8 = undefined;
    _ = add(app, .binding, w.path, &.{
        .{ .str = "tag" },     .{ .str = tag },
        .{ .str = "pattern" }, .{ .str = bind.formatPattern(pattern, &buf) },
        .{ .str = "script" },  .{ .str = clipView(script) },
    });
}

/// The `-command` of a widget that runs.
/// A disabled widget runs no command: `ran` is 0 and `why` says so.
pub fn command(app: *App, w: *const Widget, script: []const u8, disabled: bool) void {
    if (!app.dbg.trace.on(.command)) return;
    _ = add(app, .command, w.path, &.{
        .{ .str = "script" }, .{ .str = clipView(script) },
        .{ .str = "ran" },    .{ .int = @intFromBool(!disabled and script.len > 0) },
        .{ .str = "why" },    .{ .str = if (disabled) "the widget is disabled" else if (script.len == 0) "no -command" else "" },
    });
}

fn clipView(text: []const u8) []const u8 {
    return text[0..@min(text.len, max_text)];
}

fn flagList(a: std.mem.Allocator, d: widget_mod.Dirty) !Value {
    var items: std.ArrayList(Value) = .empty;
    if (d.style) try items.append(a, .{ .str = "style" });
    if (d.measure) try items.append(a, .{ .str = "measure" });
    if (d.layout) try items.append(a, .{ .str = "layout" });
    if (d.paint) try items.append(a, .{ .str = "paint" });
    return ztcl.value.wrapList(a, items.items);
}

/// A widget that gets new dirty flags. `by` is the option record that
/// caused it, or 0.
pub fn dirty(w: *const Widget, d: widget_mod.Dirty) void {
    const app = w.app;
    if (!app.dbg.trace.on(.dirty)) return;
    const new: widget_mod.Dirty = .{ .style = d.style and !w.dirty.style, .measure = d.measure and !w.dirty.measure, .layout = d.layout and !w.dirty.layout, .paint = d.paint and !w.dirty.paint };
    if (!new.any()) return;
    const flags = flagList(app.it.alloc(), new) catch return;
    _ = add(app, .dirty, w.path, &.{ .{ .str = "flags" }, flags, .{ .str = "by" }, .{ .int = @intCast(app.dbg.trace.reason) } });
}

/// A frame of a toplevel: the widgets that became dirty since its last frame.
pub fn frame(app: *App, top: *const Widget, us: i64) void {
    const t = &app.dbg.trace;
    if (!t.on(.frame)) return;
    const a = app.it.alloc();
    var paths: std.ArrayList(Value) = .empty;
    var i = t.len;
    while (i > 0) {
        i -= 1;
        const r = t.at(i);
        if (r.kind == .frame and std.mem.eql(u8, r.widget, top.path)) break;
        if (r.kind != .dirty) continue;
        if (!inTop(r.widget, top.path)) continue;
        var seen = false;
        for (paths.items) |p| if (std.mem.eql(u8, p.str, r.widget)) {
            seen = true;
        };
        if (!seen) paths.append(a, .{ .str = r.widget }) catch return;
        if (paths.items.len == 64) break;
    }
    std.mem.reverse(Value, paths.items);
    const list = ztcl.value.wrapList(a, paths.items) catch return;
    _ = add(app, .frame, top.path, &.{ .{ .str = "frame" }, .{ .int = @intCast(app.frames) }, .{ .str = "us" }, .{ .int = us }, .{ .str = "dirty" }, list });
}

/// True when `path` is the toplevel `top` or a widget in it. A widget in
/// a nested toplevel also gives true; the toplevel of "." is ".".
fn inTop(path: []const u8, top: []const u8) bool {
    if (std.mem.eql(u8, top, ".")) return true;
    return std.mem.eql(u8, path, top) or (std.mem.startsWith(u8, path, top) and path.len > top.len and path[top.len] == '.');
}

/// The boxes of the content of a container before an arrange.
pub const Boxes = struct {
    items: []geom.Rect = &.{},
};

pub fn boxesBefore(c: *const Widget) Boxes {
    const app = c.app;
    if (!app.dbg.trace.on(.geometry)) return .{};
    const a = app.it.alloc();
    const out = a.alloc(geom.Rect, c.children.items.len) catch return .{};
    for (c.children.items, out) |ch, *o| o.* = ch.geom;
    return .{ .items = out };
}

/// A geometry pass of a container: each content widget whose box changed.
pub fn arranged(c: *const Widget, manager: []const u8, before: Boxes) void {
    const app = c.app;
    if (!app.dbg.trace.on(.geometry) or before.items.len != c.children.items.len) return;
    const a = app.it.alloc();
    var changed: std.ArrayList(Value) = .empty;
    for (c.children.items, before.items) |ch, old| {
        const g = ch.geom;
        if (g.x == old.x and g.y == old.y and g.w == old.w and g.h == old.h) continue;
        const item = ztcl.value.newList(a, &.{
            .{ .str = ch.path },
            ztcl.value.newList(a, &.{ .{ .int = old.x }, .{ .int = old.y }, .{ .int = old.w }, .{ .int = old.h } }) catch return,
            ztcl.value.newList(a, &.{ .{ .int = g.x }, .{ .int = g.y }, .{ .int = g.w }, .{ .int = g.h } }) catch return,
        }) catch return;
        changed.append(a, item) catch return;
    }
    const list = ztcl.value.wrapList(a, changed.items) catch return;
    _ = add(app, .geometry, c.path, &.{
        .{ .str = "manager" }, .{ .str = manager },
        .{ .str = "req" },     ztcl.value.newList(a, &.{ .{ .int = c.req.w }, .{ .int = c.req.h } }) catch return,
        .{ .str = "box" },     ztcl.value.newList(a, &.{ .{ .int = c.geom.w }, .{ .int = c.geom.h } }) catch return,
        .{ .str = "changed" }, list,
    });
}

/// A change of the focus.
pub fn focus(app: *App, old: ?*const Widget, new: ?*const Widget) void {
    if (!app.dbg.trace.on(.focus)) return;
    _ = add(app, .focus, if (new) |n| n.path else "", &.{ .{ .str = "from" }, .{ .str = if (old) |o| o.path else "" }, .{ .str = "to" }, .{ .str = if (new) |n| n.path else "" } });
}

/// A grab that starts or ends.
pub fn grab(app: *App, w: *const Widget, action: []const u8, global: bool) void {
    if (!app.dbg.trace.on(.grab)) return;
    _ = add(app, .grab, w.path, &.{ .{ .str = "action" }, .{ .str = action }, .{ .str = "global" }, .{ .int = @intFromBool(global) } });
}

const trace_usage = "ztk::debug trace start ?-kinds list? ?-size n? | stop | clear | status | records ?-kind list? ?-widget pattern? ?-match pattern? ?-cause n? ?-since n? ?-last n?";

fn cmdTrace(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len == 0) return it.wrongArgs(trace_usage);
    const t = &app.dbg.trace;
    const sub = try it.str(args[0]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "start")) {
        var mask: u16 = (1 << trace_mod.n_kinds) - 1;
        mask &= ~(@as(u16, 1) << @intFromEnum(trace_mod.Kind.motion));
        var size: usize = trace_mod.default_size;
        var k: usize = 1;
        while (k < args.len) : (k += 2) {
            if (k + 1 >= args.len) return it.wrongArgs(trace_usage);
            const opt = try it.str(args[k]);
            if (std.mem.eql(u8, opt, "-kinds")) {
                const items = try it.readList(args[k + 1]);
                const names = try a.alloc([]const u8, items.len);
                for (items, names) |v, *n| n.* = try it.str(v);
                mask = trace_mod.maskOf(names) orelse return it.fail("bad kind in \"{s}\": must be {s}, or all", .{ try it.str(args[k + 1]), trace_mod.kind_names });
            } else if (std.mem.eql(u8, opt, "-size")) {
                const n = try it.int(args[k + 1]);
                if (n < 1 or n > 1_000_000) return it.fail("bad size \"{d}\": must be 1 to 1000000", .{n});
                size = @intCast(n);
            } else return it.fail("bad option \"{s}\": must be -kinds or -size", .{opt});
        }
        t.start(app.gpa, mask, size) catch return error.OutOfMemory;
        app.dbg.update();
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "stop")) {
        t.mask = 0;
        app.dbg.update();
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "clear")) {
        t.clear(app.gpa);
        return Value.empty;
    }
    if (std.mem.eql(u8, sub, "status")) {
        var kinds: std.ArrayList(Value) = .empty;
        inline for (@typeInfo(trace_mod.Kind).@"enum".field_names) |n| {
            if (t.on(@field(trace_mod.Kind, n))) try kinds.append(a, .{ .str = n });
        }
        return ztcl.value.newList(a, &.{
            .{ .str = "on" },      .{ .int = @intFromBool(t.mask != 0) },
            .{ .str = "kinds" },   try ztcl.value.wrapList(a, kinds.items),
            .{ .str = "count" },   .{ .int = @intCast(t.len) },
            .{ .str = "size" },    .{ .int = @intCast(t.ring.len) },
            .{ .str = "dropped" }, .{ .int = @intCast(t.dropped) },
        });
    }
    if (std.mem.eql(u8, sub, "records")) return records(it, app, args[1..]);
    return it.fail("bad option \"{s}\": must be clear, records, start, status, or stop", .{sub});
}

pub const Filter = struct {
    kinds: u16 = 0xffff,
    widget: ?[]const u8 = null,
    /// A glob pattern for the text of the fields.
    match: ?[]const u8 = null,
    cause: ?u64 = null,
    since: u64 = 0,
    last: ?usize = null,

    pub fn keep(f: Filter, r: *const trace_mod.Record) bool {
        if (f.kinds & (@as(u16, 1) << @intFromEnum(r.kind)) == 0) return false;
        if (r.seq <= f.since) return false;
        if (f.cause) |c| if (r.cause != c and r.seq != c) return false;
        if (f.widget) |g| if (!trace_mod.glob(g, r.widget)) return false;
        if (f.match) |g| if (!trace_mod.glob(g, r.fields)) return false;
        return true;
    }
};

pub fn parseFilter(it: *ztcl.Interp, args: []const Value) ztcl.Error!Filter {
    var f: Filter = .{};
    var k: usize = 0;
    while (k < args.len) : (k += 2) {
        if (k + 1 >= args.len) return it.wrongArgs("ztk::debug trace records ?-kind list? ?-widget pattern? ?-match pattern? ?-cause n? ?-since n? ?-last n?");
        const opt = try it.str(args[k]);
        const v = args[k + 1];
        if (std.mem.eql(u8, opt, "-kind")) {
            const items = try it.readList(v);
            const names = try it.alloc().alloc([]const u8, items.len);
            for (items, names) |x, *n| n.* = try it.str(x);
            f.kinds = trace_mod.maskOf(names) orelse return it.fail("bad kind in \"{s}\": must be {s}, or all", .{ try it.str(v), trace_mod.kind_names });
        } else if (std.mem.eql(u8, opt, "-widget")) {
            f.widget = try it.str(v);
        } else if (std.mem.eql(u8, opt, "-match")) {
            f.match = try it.str(v);
        } else if (std.mem.eql(u8, opt, "-cause")) {
            f.cause = @intCast(@max(try it.int(v), 0));
        } else if (std.mem.eql(u8, opt, "-since")) {
            f.since = @intCast(@max(try it.int(v), 0));
        } else if (std.mem.eql(u8, opt, "-last")) {
            f.last = @intCast(@max(try it.int(v), 0));
        } else return it.fail("bad option \"{s}\": must be -cause, -kind, -last, -match, -since, or -widget", .{opt});
    }
    return f;
}

/// The records that pass the filter, oldest first. With `-last n`, the
/// last n of them. With `-cause n`, the event n and the records that its
/// bindings made.
fn records(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    const f = try parseFilter(it, args);
    const t = &app.dbg.trace;
    const a = it.alloc();
    var picked: std.ArrayList(*const trace_mod.Record) = .empty;
    for (0..t.len) |i| {
        const r = t.at(i);
        if (f.keep(r)) try picked.append(a, r);
    }
    var from: usize = 0;
    if (f.last) |n| from = picked.items.len -| n;
    var out: std.ArrayList(Value) = .empty;
    for (picked.items[from..]) |r| try out.append(a, try recordValue(it, r));
    return ztcl.value.wrapList(a, out.items);
}

pub fn recordValue(it: *ztcl.Interp, r: *const trace_mod.Record) ztcl.Error!Value {
    const a = it.alloc();
    const head = try ztcl.value.newList(a, &.{
        .{ .str = "seq" },    .{ .int = @intCast(r.seq) },
        .{ .str = "kind" },   .{ .str = @tagName(r.kind) },
        .{ .str = "widget" }, .{ .str = try a.dupe(u8, r.widget) },
        .{ .str = "cause" },  .{ .int = @intCast(r.cause) },
        .{ .str = "us" },     .{ .int = r.us },
    });
    const text = try std.mem.concat(a, u8, &.{ try it.str(head), " ", r.fields });
    return .{ .str = text };
}

// ---- Visual diffs ----

fn lessStr(_: void, x: Value, y: Value) bool {
    return std.mem.lessThan(u8, x.str, y.str);
}

/// `ztk::debug mark name ?pathName?`: keeps the image and the widgets of
/// the toplevel of pathName (default ".") under the name.
fn cmdMark(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    if (args.len < 1 or args.len > 2) return it.wrongArgs("ztk::debug mark name ?pathName?");
    const name = try it.str(args[0]);
    const path = if (args.len == 2) try it.str(args[1]) else ".";
    _ = try widgetOf(it, app, path);
    try app.flush();
    const w = try widgetOf(it, app, path);
    const m = try diff_mod.capture(it, app, w, path);
    const gpa = app.gpa;
    const gop = app.dbg.marks.getOrPut(gpa, name) catch {
        m.free(gpa);
        return error.OutOfMemory;
    };
    if (gop.found_existing) {
        gop.value_ptr.*.free(gpa);
    } else {
        gop.key_ptr.* = gpa.dupe(u8, name) catch {
            _ = app.dbg.marks.remove(name);
            m.free(gpa);
            return error.OutOfMemory;
        };
    }
    gop.value_ptr.* = m;
    return .{ .str = try it.alloc().dupe(u8, name) };
}

/// `ztk::debug diff name ?-image? ?-tolerance n?`: compares the mark with
/// the toplevel now.
fn cmdDiff(it: *ztcl.Interp, app: *App, args: []const Value) ztcl.Error!Value {
    const usage_diff = "ztk::debug diff name ?-image? ?-tolerance n?";
    if (args.len < 1) return it.wrongArgs(usage_diff);
    const name = try it.str(args[0]);
    var want_image = false;
    var tolerance: u8 = 0;
    var k: usize = 1;
    while (k < args.len) : (k += 1) {
        const opt = try it.str(args[k]);
        if (std.mem.eql(u8, opt, "-image")) {
            want_image = true;
        } else if (std.mem.eql(u8, opt, "-tolerance")) {
            k += 1;
            if (k >= args.len) return it.wrongArgs(usage_diff);
            tolerance = @intCast(std.math.clamp(try it.int(args[k]), 0, 255));
        } else return it.fail("bad option \"{s}\": must be -image or -tolerance", .{opt});
    }
    const old = app.dbg.marks.get(name) orelse return it.fail("no mark \"{s}\"", .{name});
    const top_path = try it.alloc().dupe(u8, old.top);
    try app.flush();
    const w = try widgetOf(it, app, top_path);
    // The flush can run a script that replaces the mark.
    const mark = app.dbg.marks.get(name) orelse return it.fail("no mark \"{s}\"", .{name});
    const now = try diff_mod.capture(it, app, w, top_path);
    defer now.free(app.gpa);
    return diff_mod.compare(it, app.gpa, mark, now, tolerance, want_image);
}
