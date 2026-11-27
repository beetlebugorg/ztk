//! The `font` command of Tk: `actual`, `configure`, `create`, `delete`,
//! `families`, `measure`, `metrics`, and `names`, with the messages of
//! `wish` 8.6.16. The App keeps the named fonts in a `Store`. A widget
//! with a named font as its `-font` gets the attributes of that font,
//! and a change of a named font restyles each widget.
//!
//! The standard fonts (TkDefaultFont and the others) are named fonts
//! with no attribute set: each one gives the font of its widget, as in
//! the theme, until a script sets an attribute.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const font_mod = @import("text/font.zig");
const paint = @import("paint.zig");
const Value = ztcl.Value;
const FontDesc = font_mod.FontDesc;

/// The attributes of a named font. A null attribute comes from the base
/// font of the widget.
pub const Attrs = struct {
    family: ?[]const u8 = null,
    /// Tk units: points when positive, pixels when negative.
    size: ?f64 = null,
    bold: ?bool = null,
    italic: ?bool = null,
    underline: bool = false,
    overstrike: bool = false,
};

const Named = struct { attrs: Attrs, fixed: bool = false };

pub const Store = struct {
    fonts: std.StringArrayHashMapUnmanaged(Named) = .empty,
    /// The family texts of all attributes. A style can point into one, so
    /// they stay until the end of the App.
    strings: std.ArrayListUnmanaged([]u8) = .empty,
    next: u32 = 1,

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        for (s.fonts.keys()) |k| gpa.free(k);
        s.fonts.deinit(gpa);
        for (s.strings.items) |t| gpa.free(t);
        s.strings.deinit(gpa);
    }

    fn keep(s: *Store, gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
        const t = try gpa.dupe(u8, text);
        errdefer gpa.free(t);
        try s.strings.append(gpa, t);
        return t;
    }
};

const standard = [_][]const u8{ "TkDefaultFont", "TkTextFont", "TkFixedFont", "TkMenuFont", "TkHeadingFont", "TkCaptionFont", "TkSmallCaptionFont", "TkIconFont", "TkTooltipFont" };

/// Adds the standard named fonts. The App calls it once at the start.
pub fn init(app: *App) !void {
    for (standard) |n| {
        const k = try app.gpa.dupe(u8, n);
        errdefer app.gpa.free(k);
        try app.named_fonts.fonts.put(app.gpa, k, .{ .attrs = .{}, .fixed = std.mem.eql(u8, n, "TkFixedFont") });
    }
}

fn apply(app: *App, a: Attrs, fixed: bool, base: FontDesc) FontDesc {
    var d = base;
    if (fixed) d.family = "monospace";
    if (a.family) |f| d.family = f;
    if (a.size) |sz| {
        if (sz > 0) d.size = @floatCast(sz * app.scaling) else if (sz < 0) d.size = @floatCast(-sz);
    }
    if (a.bold) |b| d.weight = if (b) 700 else 400;
    if (a.italic) |i| d.italic = i;
    return d;
}

/// Parses the value of a `-font` option: a named font, a list of
/// `-option value` pairs, or a description of Tk such as `{Helvetica} 12
/// bold`. Gives null for a value that is none of these.
pub fn parse(app: *App, text: []const u8, base: FontDesc) ?FontDesc {
    const t = std.mem.trim(u8, text, " \t\n");
    if (app.named_fonts.fonts.get(t)) |n| return apply(app, n.attrs, n.fixed, base);
    if (t.len > 0 and t[0] == '-') {
        const a = parseOptions(app, t) orelse return null;
        return apply(app, a, false, base);
    }
    return font_mod.Fonts.parseTk(t, base, app.scaling);
}

/// Parses `-family f -size n -weight w -slant s -underline b -overstrike b`
/// with no error message. The family text stays until the end of the App.
fn parseOptions(app: *App, text: []const u8) ?Attrs {
    const it = app.it;
    const words = it.list(.{ .str = text }) catch return null;
    if (words.len % 2 != 0) return null;
    var a: Attrs = .{};
    var i: usize = 0;
    while (i < words.len) : (i += 2) {
        setAttr(app, &a, it.str(words[i]) catch return null, words[i + 1]) catch return null;
    }
    return a;
}

const option_names = "-family, -size, -weight, -slant, -underline, or -overstrike";

fn setAttr(app: *App, a: *Attrs, name: []const u8, v: Value) ztcl.Error!void {
    const it = app.it;
    const s = try it.str(v);
    if (eq(name, "-family")) {
        a.family = app.named_fonts.keep(app.gpa, s) catch return it.memError();
    } else if (eq(name, "-size")) {
        const n = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return it.fail("expected integer but got \"{s}\"", .{s});
        if (!std.math.isFinite(n) or @abs(n) > 10000) return it.fail("expected integer but got \"{s}\"", .{s});
        a.size = n;
    } else if (eq(name, "-weight")) {
        if (eq(s, "bold")) a.bold = true else if (eq(s, "normal")) a.bold = false else return it.fail("bad -weight value \"{s}\": must be normal, or bold", .{s});
    } else if (eq(name, "-slant")) {
        if (eq(s, "italic")) a.italic = true else if (eq(s, "roman")) a.italic = false else return it.fail("bad -slant value \"{s}\": must be roman, or italic", .{s});
    } else if (eq(name, "-underline")) {
        a.underline = @import("options.zig").parseBool(s) orelse return it.fail("expected boolean value but got \"{s}\"", .{s});
    } else if (eq(name, "-overstrike")) {
        a.overstrike = @import("options.zig").parseBool(s) orelse return it.fail("expected boolean value but got \"{s}\"", .{s});
    } else return it.fail("bad option \"{s}\": must be {s}", .{ name, option_names });
}

/// The font of the root, for a font value with no widget.
fn baseDesc(app: *App) FontDesc {
    if (app.root) |r| if (r.styled) return r.style.font;
    return .{};
}

fn resolve(app: *App, v: Value) ztcl.Error!FontDesc {
    const it = app.it;
    const s = try it.str(v);
    return parse(app, s, baseDesc(app)) orelse it.fail("font \"{s}\" doesn't exist", .{s});
}

fn underlineOf(app: *App, v: Value) [2]bool {
    const s = app.it.str(v) catch return .{ false, false };
    if (app.named_fonts.fonts.get(std.mem.trim(u8, s, " "))) |n| return .{ n.attrs.underline, n.attrs.overstrike };
    return .{ std.mem.indexOf(u8, s, "underline") != null, std.mem.indexOf(u8, s, "overstrike") != null };
}

/// The attribute list of `font actual` and `font configure`.
fn attrList(app: *App, d: FontDesc, lines: [2]bool, only: ?[]const u8) ztcl.Error!Value {
    const it = app.it;
    const a = it.alloc();
    const pts: i64 = @intFromFloat(@round(@as(f64, d.size) / app.scaling));
    const family: []const u8 = if (eq(d.family, "monospace")) "JetBrains Mono" else if (eq(d.family, "system-ui")) "Inter" else d.family;
    const items = [_][2]Value{
        .{ .{ .str = "-family" }, .{ .str = family } },
        .{ .{ .str = "-size" }, .{ .int = pts } },
        .{ .{ .str = "-weight" }, .{ .str = if (d.weight >= 600) "bold" else "normal" } },
        .{ .{ .str = "-slant" }, .{ .str = if (d.italic) "italic" else "roman" } },
        .{ .{ .str = "-underline" }, .{ .int = @intFromBool(lines[0]) } },
        .{ .{ .str = "-overstrike" }, .{ .int = @intFromBool(lines[1]) } },
    };
    if (only) |o| {
        for (items) |p| if (eq(p[0].str, o)) return p[1];
        return it.fail("bad option \"{s}\": must be {s}", .{ o, option_names });
    }
    var out = try a.alloc(Value, items.len * 2);
    for (items, 0..) |p, k| {
        out[2 * k] = p[0];
        out[2 * k + 1] = p[1];
    }
    return ztcl.value.wrapList(a, out);
}

/// Removes `-displayof window` from the words after the subcommand.
fn dropDisplayof(it: *ztcl.Interp, words: []const Value) ztcl.Error![]const Value {
    if (words.len >= 1 and eq(try it.str(words[0]), "-displayof")) {
        if (words.len < 2) return it.fail("value for \"-displayof\" missing", .{});
        return words[2..];
    }
    return words;
}

pub fn cmdFont(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("font option ?arg?");
    const sub = try it.str(argv[1]);
    const subs = [_][]const u8{ "actual", "configure", "create", "delete", "families", "measure", "metrics", "names" };
    var pick: ?[]const u8 = null;
    for (subs) |c| if (std.mem.startsWith(u8, c, sub) and sub.len > 0) {
        if (pick != null) {
            pick = null;
            break;
        }
        pick = c;
    };
    const c = pick orelse return it.fail("bad option \"{s}\": must be actual, configure, create, delete, families, measure, metrics, or names", .{sub});
    const a = it.alloc();
    if (eq(c, "actual")) {
        if (argv.len < 3) return it.wrongArgs("font actual font ?-displayof window? ?option? ?--? ?char?");
        var rest = try dropDisplayof(it, argv[3..]);
        if (rest.len > 0 and eq(try it.str(rest[rest.len - 1]), "--")) rest = rest[0 .. rest.len - 1];
        if (rest.len >= 2 and eq(try it.str(rest[rest.len - 2]), "--")) rest = rest[0 .. rest.len - 2];
        const d = try resolve(app, argv[2]);
        const only: ?[]const u8 = if (rest.len >= 1) try it.str(rest[0]) else null;
        return attrList(app, d, underlineOf(app, argv[2]), only);
    }
    if (eq(c, "configure")) {
        if (argv.len < 3) return it.wrongArgs("font configure fontname ?-option value ...?");
        const name = try it.str(argv[2]);
        const n = app.named_fonts.fonts.getPtr(name) orelse return it.fail("named font \"{s}\" doesn't exist", .{name});
        const d = apply(app, n.attrs, n.fixed, baseDesc(app));
        if (argv.len == 3) return attrList(app, d, .{ n.attrs.underline, n.attrs.overstrike }, null);
        if (argv.len == 4) return attrList(app, d, .{ n.attrs.underline, n.attrs.overstrike }, try it.str(argv[3]));
        if (argv.len % 2 != 1) return it.fail("value for \"{s}\" missing", .{try it.str(argv[argv.len - 1])});
        var attrs = n.attrs;
        var i: usize = 3;
        while (i < argv.len) : (i += 2) try setAttr(app, &attrs, try it.str(argv[i]), argv[i + 1]);
        n.attrs = attrs;
        changed(app);
        return Value.empty;
    }
    if (eq(c, "create")) {
        var i: usize = 2;
        var name_buf: [32]u8 = undefined;
        var name: []const u8 = undefined;
        if (argv.len > 2 and !std.mem.startsWith(u8, try it.str(argv[2]), "-")) {
            name = try it.str(argv[2]);
            i = 3;
            if (app.named_fonts.fonts.contains(name)) return it.fail("named font \"{s}\" already exists", .{name});
        } else {
            while (true) {
                name = std.fmt.bufPrint(&name_buf, "font{d}", .{app.named_fonts.next}) catch unreachable;
                app.named_fonts.next += 1;
                if (!app.named_fonts.fonts.contains(name)) break;
            }
        }
        if ((argv.len - i) % 2 != 0) return it.fail("value for \"{s}\" missing", .{try it.str(argv[argv.len - 1])});
        var attrs: Attrs = .{};
        while (i < argv.len) : (i += 2) try setAttr(app, &attrs, try it.str(argv[i]), argv[i + 1]);
        const k = app.gpa.dupe(u8, name) catch return it.memError();
        app.named_fonts.fonts.put(app.gpa, k, .{ .attrs = attrs }) catch {
            app.gpa.free(k);
            return it.memError();
        };
        return .{ .str = try a.dupe(u8, name) };
    }
    if (eq(c, "delete")) {
        if (argv.len < 3) return it.wrongArgs("font delete fontname ?fontname ...?");
        for (argv[2..]) |v| {
            const name = try it.str(v);
            const kv = app.named_fonts.fonts.fetchOrderedRemove(name) orelse return it.fail("named font \"{s}\" doesn't exist", .{name});
            app.gpa.free(kv.key);
        }
        changed(app);
        return Value.empty;
    }
    if (eq(c, "families")) {
        const rest = try dropDisplayof(it, argv[2..]);
        if (rest.len != 0) return it.wrongArgs("font families ?-displayof window?");
        const fams = [_][]const u8{ "Courier", "Helvetica", "Inter", "JetBrains Mono", "Times" };
        const out = try a.alloc(Value, fams.len);
        for (fams, out) |f, *slot| slot.* = .{ .str = f };
        return ztcl.value.wrapList(a, out);
    }
    if (eq(c, "measure")) {
        if (argv.len < 4) return it.wrongArgs("font measure font ?-displayof window? text");
        const rest = try dropDisplayof(it, argv[3..]);
        if (rest.len != 1) return it.wrongArgs("font measure font ?-displayof window? text");
        const d = try resolve(app, argv[2]);
        return .{ .int = paint.textSize(app, try it.str(rest[0]), d).w };
    }
    if (eq(c, "metrics")) {
        if (argv.len < 3) return it.wrongArgs("font metrics font ?-displayof window? ?option?");
        const rest = try dropDisplayof(it, argv[3..]);
        const d = try resolve(app, argv[2]);
        const m = paint.fontMetrics(app, d);
        const fixed: i64 = @intFromBool(font_mod.Fonts.isMono(d.family));
        const items = [_][2]Value{
            .{ .{ .str = "-ascent" }, .{ .int = m.ascent } },
            .{ .{ .str = "-descent" }, .{ .int = m.descent } },
            .{ .{ .str = "-linespace" }, .{ .int = m.line_height } },
            .{ .{ .str = "-fixed" }, .{ .int = fixed } },
        };
        if (rest.len == 1) {
            const o = try it.str(rest[0]);
            for (items) |p| if (eq(p[0].str, o)) return p[1];
            return it.fail("bad metric \"{s}\": must be -ascent, -descent, -linespace, or -fixed", .{o});
        }
        if (rest.len > 1) return it.wrongArgs("font metrics font ?-displayof window? ?option?");
        var out = try a.alloc(Value, 8);
        for (items, 0..) |p, k| {
            out[2 * k] = p[0];
            out[2 * k + 1] = p[1];
        }
        return ztcl.value.wrapList(a, out);
    }
    // names
    if (argv.len != 2) return it.wrongArgs("font names");
    const keys = app.named_fonts.fonts.keys();
    const out = try a.alloc(Value, keys.len);
    for (keys, out) |k, *slot| slot.* = .{ .str = try a.dupe(u8, k) };
    return ztcl.value.wrapList(a, out);
}

/// Restyles each widget after a change of a named font.
fn changed(app: *App) void {
    app.styles.generation += 1;
    app.requestFrame();
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
