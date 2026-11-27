//! The computed style of a widget. A `StyleSet` holds the parsed
//! stylesheets, each with an origin. `compute` finds the declarations
//! that match a widget, sorts them by origin, specificity, sheet order,
//! and rule order, and applies them in that order, so the last one wins.
//! The options that a script set on the widget come last, with the origin
//! `widget`. Custom properties (`--name`) inherit down the tree and
//! `var()` resolves in the value tokens before the typed parse. A cycle
//! or a missing variable with no fallback makes the declaration invalid.
//! The properties `color`, the font properties, `cursor`, `text-align`,
//! and `caret-color` inherit. The font properties come first, because
//! an `em` length depends on the font size of the widget.
//! String values (font family, cursor) are interned in the set, so a
//! style stays valid after a sheet is removed.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const ztcl = @import("ztcl");
const geom = @import("geom.zig");
const css_parse = @import("css/parse.zig");
const css_value = @import("css/value.zig");
const select = @import("css/select.zig");
const font_mod = @import("text/font.zig");
const options = @import("options.zig");
const scene = @import("scene.zig");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;
const Token = @import("css/token.zig").Token;

pub const Origin = enum(u8) { base, theme, platform, option_db, ttk, app, widget };

const easing = @import("easing.zig");

/// The properties that a transition or an animation moves.
pub const AnimProp = enum(u4) { color, background, border_color, outline_color, caret_color, opacity, radius, shadow, outline, padding, min_size };
pub const n_anim_props = @typeInfo(AnimProp).@"enum".field_names.len;

/// The timing of one property.
pub const TransSpec = struct {
    duration_ms: u32 = 0,
    delay_ms: u32 = 0,
    timing: easing.Timing = easing.Timing.ease,

    /// The length from the start to the end, with the delay. A spring has its own duration.
    pub fn totalUs(t: TransSpec) i64 {
        const d: i64 = switch (t.timing) {
            .spring => |p| @intFromFloat(easing.springDuration(p) * 1_000_000),
            else => @as(i64, t.duration_ms) * 1000,
        };
        return @as(i64, t.delay_ms) * 1000 + d;
    }

    /// The eased progress at `us` after the start.
    pub fn progress(t: TransSpec, us: i64) f32 {
        const after = us - @as(i64, t.delay_ms) * 1000;
        if (after <= 0) return t.timing.eval(0);
        const len = t.totalUs() - @as(i64, t.delay_ms) * 1000;
        if (len <= 0 or after >= len) return 1;
        return t.timing.eval(@as(f32, @floatFromInt(after)) / @as(f32, @floatFromInt(len)));
    }

    pub fn active(t: TransSpec) bool {
        return t.duration_ms > 0 or t.timing == .spring;
    }
};

/// The `transition` of a style: one timing for each property.
pub const Transition = struct {
    props: [n_anim_props]TransSpec = @splat(.{}),

    pub fn any(t: *const Transition) bool {
        for (t.props) |p| if (p.active()) return true;
        return false;
    }

    /// The longest total time of the properties.
    pub fn totalUs(t: *const Transition) i64 {
        var m: i64 = 0;
        for (t.props) |p| if (p.active()) {
            m = @max(m, p.totalUs());
        };
        return m;
    }
};

pub const Relief = enum { solid, raised, sunken, groove, ridge };

/// The `border-style` of a keyword: the CSS names and the Tk names.
pub fn reliefOf(n: []const u8) ?Relief {
    const names = [_]struct { []const u8, Relief }{
        .{ "solid", .solid }, .{ "outset", .raised }, .{ "inset", .sunken },  .{ "groove", .groove },
        .{ "ridge", .ridge }, .{ "raised", .raised }, .{ "sunken", .sunken },
    };
    for (names) |e| if (std.ascii.eqlIgnoreCase(n, e[0])) return e[1];
    return null;
}

pub const Direction = enum { normal, reverse, alternate, alternate_reverse };
pub const Fill = enum { none, forwards, backwards, both };

/// The `animation` of a style. An empty name is no animation.
pub const AnimationSpec = struct {
    name: []const u8 = "",
    spec: TransSpec = .{},
    /// The count of iterations. Infinite is 0.
    count: f32 = 1,
    direction: Direction = .normal,
    fill: Fill = .none,
};

pub const Style = struct {
    color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    background: geom.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    /// The end of a gradient.
    background2: ?geom.Color = null,
    gradient_angle_deg: f32 = 180,
    /// Top, right, bottom, left; logical pixels.
    border_width: [4]f32 = .{ 0, 0, 0, 0 },
    border_color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    /// The relief of the border (`border-style`). A relief other than
    /// `solid` draws the border in two shades of the background.
    relief: Relief = .solid,
    /// A negative number is a percentage: -50 means 50 %.
    radius: [4]f32 = .{ 0, 0, 0, 0 },
    padding: geom.Insets = .{},
    font: font_mod.FontDesc = .{},
    opacity: f32 = 1,
    shadow: ?scene.Shadow = null,
    outline_width: f32 = 0,
    outline_color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    outline_offset: f32 = 0,
    min_width: i32 = 0,
    min_height: i32 = 0,
    transition: Transition = .{},
    animation: AnimationSpec = .{},
    caret_color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    text_align: options.Justify = .left,
    cursor: []const u8 = "default",

    pub fn eql(a: *const Style, b: *const Style) bool {
        return std.meta.eql(a.*, b.*);
    }
};

pub const Env = struct {
    dark: bool = false,
    platform: []const u8 = "linux",
    root_font_size: f32 = 13,
};

const Sheet = struct {
    id: u32,
    origin: Origin,
    name: []const u8,
    sheet: css_parse.Sheet,
};

/// The result of `StyleSet.explain`: the sheet and the declaration.
pub const Explained = struct { sheet: []const u8, origin: Origin, decl: css_parse.Decl };

const Match = struct {
    origin: u8,
    specificity: u32,
    sheet_index: u32,
    order: u32,
    decl_index: u32,
    decls: []const css_parse.Decl,
};

fn matchLess(_: void, a: Match, b: Match) bool {
    if (a.origin != b.origin) return a.origin < b.origin;
    if (a.specificity != b.specificity) return a.specificity < b.specificity;
    if (a.sheet_index != b.sheet_index) return a.sheet_index < b.sheet_index;
    if (a.order != b.order) return a.order < b.order;
    return a.decl_index < b.decl_index;
}

/// Puts each number of a style in its range.
fn sanitize(st: *Style) void {
    const m: f32 = @floatFromInt(num.max_px);
    for (&st.border_width) |*v| v.* = num.clampF(v.*, 0, m);
    // A negative radius is a percentage.
    for (&st.radius) |*v| v.* = num.clampF(v.*, -m, m);
    st.font.size = num.clampF(st.font.size, 0, num.max_font_size);
    st.opacity = num.clampF(st.opacity, 0, 1);
    st.gradient_angle_deg = num.clampF(st.gradient_angle_deg, -36000, 36000);
    st.outline_width = num.clampF(st.outline_width, 0, m);
    st.outline_offset = num.clampF(st.outline_offset, -m, m);
    if (st.shadow) |*sh| {
        sh.dx = num.clampF(sh.dx, -m, m);
        sh.dy = num.clampF(sh.dy, -m, m);
        sh.blur = num.clampF(sh.blur, 0, m);
        sh.spread = num.clampF(sh.spread, -m, m);
    }
    st.min_width = num.px(st.min_width);
    st.min_height = num.px(st.min_height);
    st.padding = .{ .top = num.px(st.padding.top), .right = num.px(st.padding.right), .bottom = num.px(st.padding.bottom), .left = num.px(st.padding.left) };
}

const Vars = std.StringHashMapUnmanaged([]const Token);

/// The cache entry of one match key: the sorted rules, and the last style
/// that they gave. The style is valid again when the parent style, the
/// nearest ancestor with variables, and the variable generation are the same.
const Entry = struct {
    matches: []const Match,
    /// False when the rules declare custom properties.
    memoizable: bool = true,
    memo_ok: bool = false,
    memo_has_parent: bool = false,
    memo_parent: Style = .{},
    memo_holder: ?*const Widget = null,
    memo_gen: u32 = 0,
    memo: Style = .{},
};

pub const StyleSet = struct {
    gpa: std.mem.Allocator,
    sheets: std.ArrayListUnmanaged(Sheet) = .empty,
    next_id: u32 = 1,
    strings: std.StringHashMapUnmanaged(void) = .empty,
    /// The custom properties that a widget declares. A widget with none has no entry.
    vars: std.AutoHashMapUnmanaged(*const Widget, *Vars) = .empty,
    /// Counts up at each `add` and `remove`.
    generation: u32 = 0,
    /// The count of `compute` calls, for the tests.
    compute_calls: u64 = 0,
    /// The sorted matching rules, by the key of `matchKey`. Cleared when a sheet changes.
    cache: std.StringHashMapUnmanaged(*Entry) = .empty,
    /// Counts up each time the custom properties of a widget change.
    vars_gen: u32 = 1,
    /// Counts the `compute` calls that found their rules in the cache, for the tests.
    cache_hits: u64 = 0,
    /// True when a selector has a combinator, so ancestors change the match.
    has_combinators: bool = false,
    /// True when a selector has an id, so the name of the widget changes the match.
    has_ids: bool = false,

    pub fn init(gpa: std.mem.Allocator) StyleSet {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *StyleSet) void {
        s.clearCache();
        for (s.sheets.items) |*sh| {
            s.gpa.free(sh.name);
            sh.sheet.deinit();
        }
        s.sheets.deinit(s.gpa);
        var it = s.strings.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.strings.deinit(s.gpa);
        s.freeVars();
        s.vars.deinit(s.gpa);
        s.cache.deinit(s.gpa);
    }

    pub fn clearCache(s: *StyleSet) void {
        var it = s.cache.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*.matches);
            s.gpa.destroy(e.value_ptr.*);
        }
        s.cache.clearRetainingCapacity();
        s.has_combinators = false;
        s.has_ids = false;
        for (s.sheets.items) |sh| for (sh.sheet.rules) |rule| for (rule.selectors) |sel| {
            if (sel.compounds.len > 1) s.has_combinators = true;
            for (sel.compounds) |c| if (c.id != null) {
                s.has_ids = true;
            };
        };
    }

    /// Writes the facts of one widget that a selector can test.
    fn describe(s: *const StyleSet, w: *const Widget, out: *std.ArrayListUnmanaged(u8), buf: std.mem.Allocator) !void {
        try out.appendSlice(buf, w.tk_class);
        try out.append(buf, 0);
        try out.appendSlice(buf, w.ttkStyle());
        try out.append(buf, 0);
        try out.appendSlice(buf, w.class.css_base);
        try out.append(buf, 0);
        const bits: u16 = @bitCast(w.state);
        try out.appendSlice(buf, std.mem.asBytes(&bits));
        try out.append(buf, w.ttk_user);
        try out.append(buf, if (w.parent == null) 1 else 0);
        if (s.has_ids) try out.appendSlice(buf, w.name());
        try out.append(buf, 0);
        for (w.classes.items) |cl| {
            try out.appendSlice(buf, cl);
            try out.append(buf, 0);
        }
        try out.append(buf, 1);
    }

    /// The key of the rules that match a widget. Two widgets with the
    /// same key match the same rules.
    fn matchKey(s: *const StyleSet, w: *const Widget, part: ?[]const u8, env: Env, out: *std.ArrayListUnmanaged(u8), buf: std.mem.Allocator) !void {
        try out.append(buf, if (env.dark) 1 else 0);
        try out.appendSlice(buf, env.platform);
        try out.append(buf, 0);
        if (part) |p| try out.appendSlice(buf, p);
        try out.append(buf, 0);
        try s.describe(w, out, buf);
        if (s.has_combinators) {
            var a = w.parent;
            while (a) |x| : (a = x.parent) try s.describe(x, out, buf);
        }
    }

    fn freeVars(s: *StyleSet) void {
        var it = s.vars.valueIterator();
        while (it.next()) |v| {
            v.*.deinit(s.gpa);
            s.gpa.destroy(v.*);
        }
        s.vars.clearRetainingCapacity();
    }

    /// Forgets the data of a widget that is deleted.
    pub fn forget(s: *StyleSet, w: *const Widget) void {
        if (s.vars.fetchRemove(w)) |kv| {
            kv.value.deinit(s.gpa);
            s.gpa.destroy(kv.value);
            s.vars_gen +%= 1;
        }
    }

    fn intern(s: *StyleSet, text: []const u8) []const u8 {
        if (s.strings.getKey(text)) |k| return k;
        const owned = s.gpa.dupe(u8, text) catch return "default";
        s.strings.put(s.gpa, owned, {}) catch {
            s.gpa.free(owned);
            return "default";
        };
        return owned;
    }

    /// Adds a sheet. Returns an id for `remove`. The diagnostics of the
    /// parser stay with the sheet.
    pub fn add(s: *StyleSet, origin: Origin, name: []const u8, src: []const u8) !u32 {
        var sheet = try css_parse.parse(s.gpa, src);
        errdefer sheet.deinit();
        const owned = try s.gpa.dupe(u8, name);
        errdefer s.gpa.free(owned);
        const id = s.next_id;
        try s.sheets.append(s.gpa, .{ .id = id, .origin = origin, .name = owned, .sheet = sheet });
        s.next_id += 1;
        s.generation += 1;
        s.freeVars();
        s.clearCache();
        return id;
    }

    pub fn remove(s: *StyleSet, id: u32) void {
        for (s.sheets.items, 0..) |*sh, i| if (sh.id == id) {
            s.gpa.free(sh.name);
            sh.sheet.deinit();
            _ = s.sheets.orderedRemove(i);
            s.generation += 1;
            s.freeVars();
            s.clearCache();
            return;
        };
    }

    /// The `@keyframes` rule with a name. A later sheet wins.
    pub fn keyframes(s: *const StyleSet, name: []const u8) ?css_parse.Keyframes {
        var i = s.sheets.items.len;
        while (i > 0) {
            i -= 1;
            for (s.sheets.items[i].sheet.keyframes) |k| if (std.mem.eql(u8, k.name, name)) return k;
        }
        return null;
    }

    /// The style of one keyframe: the declarations on top of `base`.
    pub fn keyframeStyle(s: *StyleSet, w: *const Widget, base: *const Style, parent: ?*const Style, env: Env, decls: []const css_parse.Decl) Style {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const ctx: Ctx = .{ .s = s, .w = w, .a = arena.allocator(), .env = env, .parent = parent, .parent_font_size = if (parent) |p| p.font.size else env.root_font_size };
        var st = base.*;
        ctx.applyAll(&st, decls);
        sanitize(&st);
        return st;
    }

    pub fn diagnostics(s: *const StyleSet, id: u32) []const css_parse.Diagnostic {
        for (s.sheets.items) |sh| if (sh.id == id) return sh.sheet.diagnostics;
        return &.{};
    }

    /// The declaration that wins for one of `props` on `w`, for
    /// `ztk::debug why`. It sorts the matches as `compute` does and gives
    /// the last one. It reads no cache and runs only when a script asks.
    pub fn explain(s: *const StyleSet, w: *const Widget, env: Env, props: []const css_parse.Prop) ?Explained {
        var best: ?Explained = null;
        var best_key: Match = undefined;
        for (s.sheets.items, 0..) |sh, si| {
            for (sh.sheet.rules) |rule| {
                if (!mediaOk(rule.media, env)) continue;
                var spec: ?u32 = null;
                for (rule.selectors) |*sel| {
                    if (sel.part == null and select.matches(sel, w, null)) {
                        if (spec == null or sel.specificity > spec.?) spec = sel.specificity;
                    }
                }
                const sp = spec orelse continue;
                for (rule.decls, 0..) |d, di| {
                    if (std.mem.indexOfScalar(css_parse.Prop, props, d.prop) == null) continue;
                    const key: Match = .{ .origin = @intFromEnum(sh.origin), .specificity = sp, .sheet_index = @intCast(si), .order = rule.order, .decl_index = @intCast(di), .decls = &.{} };
                    if (best == null or !matchLess({}, key, best_key)) {
                        best = .{ .sheet = sh.name, .origin = sh.origin, .decl = d };
                        best_key = key;
                    }
                }
            }
        }
        return best;
    }

    fn mediaOk(m: css_parse.Media, env: Env) bool {
        if (m.dark) |d| if (d != env.dark) return false;
        if (m.platform) |p| if (!std.mem.eql(u8, p, env.platform)) return false;
        return true;
    }

    /// The style of a widget, or of a part of it. `parent` is the style
    /// of the parent widget, or null for a toplevel.
    /// The computed style. Each number of the result is finite and in the
    /// pixel range, so the code after this point needs no check of a style value.
    pub fn compute(s: *StyleSet, w: *const Widget, part: ?[]const u8, parent: ?*const Style, env: Env) Style {
        var st = s.computeRaw(w, part, parent, env);
        sanitize(&st);
        return st;
    }

    fn computeRaw(s: *StyleSet, w: *const Widget, part: ?[]const u8, parent: ?*const Style, env: Env) Style {
        s.compute_calls += 1;
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // Collect the matching rules, or take them from the cache.
        var key_buf: [1024]u8 = undefined;
        var key_fba = std.heap.FixedBufferAllocator.init(&key_buf);
        var key: std.ArrayListUnmanaged(u8) = .empty;
        const key_ok = if (s.matchKey(w, part, env, &key, key_fba.allocator())) |_| true else |_| false;
        var entry: ?*Entry = null;
        if (key_ok) entry = s.cache.get(key.items);
        var matches_items: []const Match = &.{};
        if (entry) |c| {
            s.cache_hits += 1;
            matches_items = c.matches;
        } else {
            var matches: std.ArrayListUnmanaged(Match) = .empty;
            for (s.sheets.items, 0..) |sh, si| {
                for (sh.sheet.rules) |rule| {
                    if (!mediaOk(rule.media, env)) continue;
                    var best: ?u32 = null;
                    for (rule.selectors) |*sel| {
                        if (select.matches(sel, w, part)) {
                            if (best == null or sel.specificity > best.?) best = sel.specificity;
                        }
                    }
                    if (best) |spec| matches.append(a, .{
                        .origin = @intFromEnum(sh.origin),
                        .specificity = spec,
                        .sheet_index = @intCast(si),
                        .order = rule.order,
                        .decl_index = 0,
                        .decls = rule.decls,
                    }) catch break;
                }
            }
            std.mem.sort(Match, matches.items, {}, matchLess);
            matches_items = matches.items;
            if (key_ok) store: {
                const k = s.gpa.dupe(u8, key.items) catch break :store;
                const v = s.gpa.dupe(Match, matches.items) catch {
                    s.gpa.free(k);
                    break :store;
                };
                const e = s.gpa.create(Entry) catch {
                    s.gpa.free(k);
                    s.gpa.free(v);
                    break :store;
                };
                var own_vars = false;
                for (v) |m| for (m.decls) |d| if (d.prop == .custom) {
                    own_vars = true;
                };
                e.* = .{ .matches = v, .memoizable = !own_vars };
                s.cache.put(s.gpa, k, e) catch {
                    s.gpa.free(k);
                    s.gpa.free(v);
                    s.gpa.destroy(e);
                    break :store;
                };
                entry = e;
            }
        }

        // The variables of this widget: its own declarations over those of its ancestors.
        var own: ?*Vars = null;
        for (matches_items) |m| for (m.decls) |d| if (d.prop == .custom) {
            if (own == null) {
                own = s.gpa.create(Vars) catch break;
                own.?.* = .empty;
            }
            own.?.put(s.gpa, d.name, d.value) catch {};
        };
        if (part == null) {
            if (s.vars.fetchRemove(w)) |kv| {
                kv.value.deinit(s.gpa);
                s.gpa.destroy(kv.value);
                s.vars_gen +%= 1;
            }
            if (own != null) s.vars_gen +%= 1;
            if (own) |o| s.vars.put(s.gpa, w, o) catch {
                o.deinit(s.gpa);
                s.gpa.destroy(o);
            };
        } else if (own) |o| {
            o.deinit(s.gpa);
            s.gpa.destroy(o);
            own = null;
        }

        // The nearest ancestor with variables decides which variables the widget sees.
        var holder: ?*const Widget = null;
        if (entry != null and entry.?.memoizable) {
            var x = w.parent;
            while (x) |wd| : (x = wd.parent) if (s.vars.contains(wd)) {
                holder = wd;
                break;
            };
            const e = entry.?;
            if (e.memo_ok and e.memo_gen == s.vars_gen and e.memo_holder == holder and
                e.memo_has_parent == (parent != null) and (parent == null or e.memo_parent.eql(parent.?)))
            {
                var out = e.memo;
                if (part == null) applyOptions(w, &out);
                return out;
            }
        }

        var st: Style = .{};
        st.font.size = env.root_font_size;
        if (parent) |p| {
            st.color = p.color;
            st.font = p.font;
            st.cursor = p.cursor;
            st.text_align = p.text_align;
            st.caret_color = p.caret_color;
        }
        const parent_font_size = st.font.size;
        const ctx: Ctx = .{ .s = s, .w = w, .a = a, .env = env, .parent = parent, .parent_font_size = parent_font_size };

        // Pass 1: the font. Pass 2: the other properties.
        for ([2]u8{ 0, 1 }) |pass| {
            for (matches_items) |m| for (m.decls) |d| {
                const is_font = d.prop == .font_family or d.prop == .font_size or d.prop == .font_weight;
                if (d.prop == .custom) continue;
                if (is_font != (pass == 0)) continue;
                ctx.apply(&st, d);
            };
        }
        if (entry != null and entry.?.memoizable) {
            const e = entry.?;
            e.memo_ok = true;
            e.memo_gen = s.vars_gen;
            e.memo_holder = holder;
            e.memo_has_parent = parent != null;
            if (parent) |p| e.memo_parent = p.*;
            e.memo = st;
        }
        if (part == null) applyOptions(w, &st);
        return st;
    }
};

/// The `-padding` of a `ttk` widget: one to four distances, left, top,
/// right, and bottom, as in Tk.
pub fn parsePadding(text: []const u8) ?geom.Insets {
    var v: [4]i32 = undefined;
    var n: usize = 0;
    var words = std.mem.tokenizeAny(u8, text, " \t\n");
    while (words.next()) |wd| {
        if (n == 4) return null;
        v[n] = @max(options.parsePixels(wd, 96.0 / 72.0) orelse return null, 0);
        n += 1;
    }
    if (n == 0) return null;
    const l = v[0];
    const t = if (n > 1) v[1] else l;
    const r = if (n > 2) v[2] else l;
    const b = if (n > 3) v[3] else t;
    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

/// The options that the script set on the widget: the origin `widget`.
pub fn applyOptions(w: *const Widget, st: *Style) void {
    // The stylesheet gives each class a proportional family. A `-font`
    // with the default TkFixedFont (text, terminal) that the script did
    // not set keeps the size and the weight of the stylesheet, and gets
    // the monospace family.
    for (w.class.specs, w.opts) |sp, slot| {
        if (!slot.set and std.mem.eql(u8, sp.name, "-font") and std.mem.eql(u8, sp.default, "TkFixedFont")) st.font.family = "monospace";
    }
    for (w.class.specs, w.opts) |sp, slot| {
        if (!slot.set or sp.type == .synonym) continue;
        const n = sp.name;
        if (std.mem.eql(u8, n, "-background")) {
            if (slot.value == .color) {
                st.background = slot.value.color;
                st.background2 = null;
            }
        } else if (std.mem.eql(u8, n, "-activebackground")) {
            if (w.state.hover and slot.value == .color) {
                st.background = slot.value.color;
                st.background2 = null;
            }
        } else if (std.mem.eql(u8, n, "-activeforeground")) {
            if (w.state.hover and slot.value == .color) st.color = slot.value.color;
        } else if (std.mem.eql(u8, n, "-disabledforeground")) {
            if (w.state.disabled and slot.value == .color) st.color = slot.value.color;
        } else if (std.mem.eql(u8, n, "-foreground")) {
            if (slot.value == .color) st.color = slot.value.color;
        } else if (std.mem.eql(u8, n, "-borderwidth")) {
            if (slot.value == .pixels) {
                const v: f32 = @floatFromInt(@max(slot.value.pixels, 0));
                st.border_width = .{ v, v, v, v };
            }
        } else if (std.mem.eql(u8, n, "-padx")) {
            if (slot.value == .pixels) {
                st.padding.left = @max(slot.value.pixels, 0);
                st.padding.right = st.padding.left;
            }
        } else if (std.mem.eql(u8, n, "-pady")) {
            if (slot.value == .pixels) {
                st.padding.top = @max(slot.value.pixels, 0);
                st.padding.bottom = st.padding.top;
            }
        } else if (std.mem.eql(u8, n, "-font")) {
            if (@import("fontcmd.zig").parse(w.app, slot.text, st.font)) |d| st.font = d;
        } else if (std.mem.eql(u8, n, "-relief")) {
            if (slot.value == .relief) switch (slot.value.relief) {
                .flat => st.border_width = .{ 0, 0, 0, 0 },
                else => |r| st.relief = reliefOf(@tagName(r)) orelse .solid,
            } else if (slot.text.len > 0) {
                if (reliefOf(slot.text)) |r| st.relief = r;
                if (std.mem.eql(u8, slot.text, "flat")) st.border_width = .{ 0, 0, 0, 0 };
            }
        } else if (std.mem.eql(u8, n, "-padding")) {
            if (parsePadding(slot.text)) |p| st.padding = p;
        }
    }
}


const Ctx = struct {
    s: *StyleSet,
    w: *const Widget,
    a: std.mem.Allocator,
    env: Env,
    parent: ?*const Style,
    parent_font_size: f32,

    /// The value of a custom property: the widget, then its ancestors.
    fn lookupVar(c: Ctx, name: []const u8) ?[]const Token {
        var x: ?*const Widget = c.w;
        while (x) |wd| : (x = wd.parent) {
            if (c.s.vars.get(wd)) |vars| if (vars.get(name)) |v| return v;
        }
        return null;
    }

    /// Replaces each var() in the tokens. Null means the value is invalid.
    fn expand(c: Ctx, tokens: []const Token, depth: u32, out: *std.ArrayListUnmanaged(Token)) ?void {
        if (depth > 16) return null;
        var i: usize = 0;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t == .function and std.ascii.eqlIgnoreCase(t.function, "var")) {
                // Find the closing parenthesis.
                var j = i + 1;
                var nest: usize = 1;
                while (j < tokens.len) : (j += 1) {
                    switch (tokens[j]) {
                        .function, .lparen => nest += 1,
                        .rparen => {
                            nest -= 1;
                            if (nest == 0) break;
                        },
                        else => {},
                    }
                }
                if (j >= tokens.len) return null;
                const inner = tokens[i + 1 .. j];
                var k: usize = 0;
                while (k < inner.len and inner[k] == .whitespace) k += 1;
                if (k >= inner.len or inner[k] != .ident) return null;
                const name = inner[k].ident;
                k += 1;
                while (k < inner.len and inner[k] == .whitespace) k += 1;
                var fallback: ?[]const Token = null;
                if (k < inner.len) {
                    if (inner[k] != .comma) return null;
                    fallback = inner[k + 1 ..];
                }
                if (c.lookupVar(name)) |v| {
                    var tmp: std.ArrayListUnmanaged(Token) = .empty;
                    if (c.expand(v, depth + 1, &tmp) != null) {
                        for (trim(tmp.items)) |x| out.append(c.a, x) catch return null;
                        i = j;
                        continue;
                    }
                }
                if (fallback) |fb| {
                    var tmp: std.ArrayListUnmanaged(Token) = .empty;
                    c.expand(trim(fb), depth + 1, &tmp) orelse return null;
                    for (tmp.items) |x| out.append(c.a, x) catch return null;
                    i = j;
                    continue;
                }
                return null;
            }
            out.append(c.a, t) catch return null;
        }
    }

    fn trim(t: []const Token) []const Token {
        var a: usize = 0;
        var b = t.len;
        while (a < b and t[a] == .whitespace) a += 1;
        while (b > a and t[b - 1] == .whitespace) b -= 1;
        return t[a..b];
    }

    fn lengthPx(c: Ctx, l: css_value.Length, em: f32) f32 {
        return switch (l.unit) {
            .px => l.value,
            .pt => l.value * 96.0 / 72.0,
            .em => l.value * em,
            .rem => l.value * c.env.root_font_size,
            .percent => l.value,
        };
    }

    fn color(c: Ctx, st: *const Style, tokens: []const Token) ?geom.Color {
        _ = c;
        const t = trim(tokens);
        if (t.len == 1 and t[0] == .ident and std.ascii.eqlIgnoreCase(t[0].ident, "currentcolor")) return st.color;
        return css_value.parseColor(t);
    }

    fn isKeyword(tokens: []const Token, kw: []const u8) bool {
        const t = trim(tokens);
        return t.len == 1 and t[0] == .ident and std.ascii.eqlIgnoreCase(t[0].ident, kw);
    }

    /// Splits at the commas that are not inside parentheses.
    fn splitCommas(c: Ctx, tokens: []const Token) []const []const Token {
        var out: std.ArrayListUnmanaged([]const Token) = .empty;
        var depth: usize = 0;
        var start: usize = 0;
        for (tokens, 0..) |t, i| {
            switch (t) {
                .function, .lparen => depth += 1,
                .rparen => depth -|= 1,
                .comma => if (depth == 0) {
                    out.append(c.a, tokens[start..i]) catch return out.items;
                    start = i + 1;
                },
                else => {},
            }
        }
        out.append(c.a, tokens[start..]) catch {};
        return out.items;
    }

    fn apply(c: Ctx, st: *Style, d: css_parse.Decl) void {
        var buf: std.ArrayListUnmanaged(Token) = .empty;
        if (c.expand(d.value, 0, &buf) == null) return;
        const v = trim(buf.items);
        if (v.len == 0) return;
        const em = st.font.size;
        const init_style: Style = .{};
        if (isKeyword(v, "inherit") or isKeyword(v, "initial")) {
            const src: Style = if (isKeyword(v, "inherit")) (if (c.parent) |p| p.* else init_style) else init_style;
            switch (d.prop) {
                .color => st.color = src.color,
                .background_color, .background => {
                    st.background = src.background;
                    st.background2 = src.background2;
                },
                .border => {
                    st.border_width = src.border_width;
                    st.border_color = src.border_color;
                },
                .border_width => st.border_width = src.border_width,
                .border_color => st.border_color = src.border_color,
                .border_style => st.relief = src.relief,
                .border_radius => st.radius = src.radius,
                .padding => st.padding = src.padding,
                .padding_top => st.padding.top = src.padding.top,
                .padding_right => st.padding.right = src.padding.right,
                .padding_bottom => st.padding.bottom = src.padding.bottom,
                .padding_left => st.padding.left = src.padding.left,
                .font_family => st.font.family = src.font.family,
                .font_size => st.font.size = if (c.parent != null and isKeyword(v, "inherit")) c.parent_font_size else c.env.root_font_size,
                .font_weight => st.font.weight = src.font.weight,
                .opacity => st.opacity = src.opacity,
                .box_shadow => st.shadow = src.shadow,
                .outline => {
                    st.outline_width = src.outline_width;
                    st.outline_color = src.outline_color;
                },
                .outline_offset => st.outline_offset = src.outline_offset,
                .min_width => st.min_width = src.min_width,
                .min_height => st.min_height = src.min_height,
                .transition => st.transition = src.transition,
                .animation => st.animation = src.animation,
                .caret_color => st.caret_color = src.caret_color,
                .cursor => st.cursor = src.cursor,
                .text_align => st.text_align = src.text_align,
                .custom => {},
            }
            return;
        }
        switch (d.prop) {
            .color => if (c.color(st, v)) |x| {
                st.color = x;
            },
            .background_color => if (c.color(st, v)) |x| {
                st.background = x;
                st.background2 = null;
            },
            .background => c.applyBackground(st, v),
            .caret_color => if (c.color(st, v)) |x| {
                st.caret_color = x;
            },
            .border_color => if (c.color(st, v)) |x| {
                st.border_color = x;
            },
            .border_width => if (css_value.parseSides(v)) |sides| {
                for (sides, 0..) |l, i| st.border_width[i] = @max(c.lengthPx(l, em), 0);
            },
            .border => c.applyBorder(st, v),
            .border_style => if (v.len == 1 and v[0] == .ident) {
                if (reliefOf(v[0].ident)) |r| st.relief = r;
            },
            .border_radius => c.applyRadius(st, v),
            .padding => if (css_value.parseSides(v)) |sides| {
                st.padding = .{
                    .top = c.px(sides[0], em),
                    .right = c.px(sides[1], em),
                    .bottom = c.px(sides[2], em),
                    .left = c.px(sides[3], em),
                };
            },
            .padding_top => if (c.single(v)) |l| {
                st.padding.top = c.px(l, em);
            },
            .padding_right => if (c.single(v)) |l| {
                st.padding.right = c.px(l, em);
            },
            .padding_bottom => if (c.single(v)) |l| {
                st.padding.bottom = c.px(l, em);
            },
            .padding_left => if (c.single(v)) |l| {
                st.padding.left = c.px(l, em);
            },
            .font_family => {
                // With no memory the list of parts can be empty.
                const families = c.splitCommas(v);
                if (families.len == 0) return;
                const t = trim(families[0]);
                if (t.len > 0) switch (t[0]) {
                    .ident => |n| st.font.family = c.s.intern(n),
                    .string => |n| st.font.family = c.s.intern(n),
                    else => {},
                };
            },
            .font_size => if (c.single(v)) |l| {
                const base = c.parent_font_size;
                st.font.size = switch (l.unit) {
                    .em => l.value * base,
                    .percent => l.value / 100 * base,
                    else => c.lengthPx(l, base),
                };
            },
            .font_weight => {
                const t = trim(v);
                if (t.len == 1) switch (t[0]) {
                    .ident => |n| {
                        if (std.ascii.eqlIgnoreCase(n, "normal")) st.font.weight = 400 else if (std.ascii.eqlIgnoreCase(n, "bold")) st.font.weight = 700;
                    },
                    .number => |n| st.font.weight = @intFromFloat(num.clampF(n, 100, 900)),
                    else => {},
                };
            },
            .opacity => {
                const t = trim(v);
                if (t.len == 1) switch (t[0]) {
                    .number => |n| st.opacity = std.math.clamp(n, 0, 1),
                    .percentage => |n| st.opacity = std.math.clamp(n / 100, 0, 1),
                    else => {},
                };
            },
            .box_shadow => c.applyShadow(st, v),
            .outline => c.applyOutline(st, v),
            .outline_offset => if (c.single(v)) |l| {
                st.outline_offset = c.lengthPx(l, em);
            },
            .min_width => if (c.single(v)) |l| {
                st.min_width = num.pxRound(@max(c.lengthPx(l, em), 0));
            },
            .min_height => if (c.single(v)) |l| {
                st.min_height = num.pxRound(@max(c.lengthPx(l, em), 0));
            },
            .transition => c.applyTransition(st, v),
            .animation => c.applyAnimation(st, v),
            .cursor => {
                const t = trim(v);
                if (t.len == 1 and t[0] == .ident) st.cursor = c.s.intern(t[0].ident);
            },
            .text_align => {
                const t = trim(v);
                if (t.len == 1 and t[0] == .ident) {
                    const n = t[0].ident;
                    if (std.ascii.eqlIgnoreCase(n, "left")) st.text_align = .left else if (std.ascii.eqlIgnoreCase(n, "center")) st.text_align = .center else if (std.ascii.eqlIgnoreCase(n, "right")) st.text_align = .right;
                }
            },
            .custom => {},
        }
    }

    fn single(c: Ctx, v: []const Token) ?css_value.Length {
        _ = c;
        const t = trim(v);
        if (t.len != 1) return null;
        return css_value.parseLength(t[0]);
    }

    fn px(c: Ctx, l: css_value.Length, em: f32) i32 {
        return num.pxRound(@max(c.lengthPx(l, em), 0));
    }

    fn applyRadius(c: Ctx, st: *Style, v: []const Token) void {
        const sides = css_value.parseSides(v) orelse return;
        for (sides, 0..) |l, i| {
            st.radius[i] = if (l.unit == .percent) -l.value else @max(c.lengthPx(l, st.font.size), 0);
        }
    }

    fn applyBackground(c: Ctx, st: *Style, v: []const Token) void {
        if (c.color(st, v)) |x| {
            st.background = x;
            st.background2 = null;
            return;
        }
        if (v.len == 0 or v[0] != .function or !std.ascii.eqlIgnoreCase(v[0].function, "linear-gradient")) return;
        if (v[v.len - 1] != .rparen) return;
        const parts = c.splitCommas(v[1 .. v.len - 1]);
        if (parts.len < 2) return;
        var angle: f32 = 180;
        var first_color: usize = 0;
        const head = trim(parts[0]);
        if (head.len == 1 and head[0] == .dimension and std.ascii.eqlIgnoreCase(head[0].dimension.unit, "deg")) {
            angle = head[0].dimension.value;
            first_color = 1;
        } else if (head.len >= 2 and head[0] == .ident and std.ascii.eqlIgnoreCase(head[0].ident, "to")) {
            var k: usize = 1;
            while (k < head.len and head[k] == .whitespace) k += 1;
            if (k < head.len and head[k] == .ident) {
                const side = head[k].ident;
                if (std.ascii.eqlIgnoreCase(side, "top")) angle = 0 else if (std.ascii.eqlIgnoreCase(side, "right")) angle = 90 else if (std.ascii.eqlIgnoreCase(side, "bottom")) angle = 180 else if (std.ascii.eqlIgnoreCase(side, "left")) angle = 270 else return;
            }
            first_color = 1;
        }
        if (parts.len < first_color + 2) return;
        const c1 = c.color(st, parts[first_color]) orelse return;
        const c2 = c.color(st, parts[first_color + 1]) orelse return;
        st.background = c1;
        st.background2 = c2;
        st.gradient_angle_deg = angle;
    }

    fn applyBorder(c: Ctx, st: *Style, v: []const Token) void {
        var width: ?f32 = null;
        var col: ?geom.Color = null;
        var none = false;
        var i: usize = 0;
        while (i < v.len) {
            const t = v[i];
            switch (t) {
                .whitespace => i += 1,
                .dimension, .number => {
                    const l = css_value.parseLength(t) orelse return;
                    width = @max(c.lengthPx(l, st.font.size), 0);
                    i += 1;
                },
                .ident => |n| {
                    if (reliefOf(n)) |r| {
                        st.relief = r;
                        i += 1;
                    } else if (std.ascii.eqlIgnoreCase(n, "none")) {
                        none = true;
                        i += 1;
                    } else {
                        col = c.color(st, v[i .. i + 1]) orelse return;
                        i += 1;
                    }
                },
                .hash => {
                    col = css_value.parseColor(v[i .. i + 1]) orelse return;
                    i += 1;
                },
                .function => {
                    var j = i;
                    while (j < v.len and v[j] != .rparen) j += 1;
                    if (j >= v.len) return;
                    col = css_value.parseColor(v[i .. j + 1]) orelse return;
                    i = j + 1;
                },
                else => return,
            }
        }
        if (none) {
            st.border_width = .{ 0, 0, 0, 0 };
            return;
        }
        const w = width orelse 3;
        st.border_width = .{ w, w, w, w };
        if (col) |x| st.border_color = x else st.border_color = st.color;
    }

    fn applyOutline(c: Ctx, st: *Style, v: []const Token) void {
        var tmp: Style = st.*;
        c.applyBorder(&tmp, v);
        st.outline_width = tmp.border_width[0];
        st.outline_color = tmp.border_color;
    }

    fn applyShadow(c: Ctx, st: *Style, v: []const Token) void {
        if (isKeyword(v, "none")) {
            st.shadow = null;
            return;
        }
        var lens: [4]f32 = .{ 0, 0, 0, 0 };
        var n: usize = 0;
        var col: ?geom.Color = null;
        var i: usize = 0;
        while (i < v.len) {
            const t = v[i];
            switch (t) {
                .whitespace => i += 1,
                .dimension, .number => {
                    if (n == 4) return;
                    const l = css_value.parseLength(t) orelse return;
                    lens[n] = c.lengthPx(l, st.font.size);
                    n += 1;
                    i += 1;
                },
                .function => {
                    var j = i;
                    while (j < v.len and v[j] != .rparen) j += 1;
                    if (j >= v.len) return;
                    col = css_value.parseColor(v[i .. j + 1]) orelse return;
                    i = j + 1;
                },
                else => {
                    col = c.color(st, v[i .. i + 1]) orelse return;
                    i += 1;
                },
            }
        }
        if (n < 2) return;
        st.shadow = .{ .dx = lens[0], .dy = lens[1], .blur = lens[2], .spread = lens[3], .color = col orelse st.color };
    }

    /// A time in ms from a token: `ms` or `s`.
    fn timeMs(tk: Token) ?u32 {
        if (tk != .dimension) return null;
        const d = tk.dimension;
        if (std.ascii.eqlIgnoreCase(d.unit, "ms")) return @intFromFloat(num.clampF(d.value, 0, 600000));
        if (std.ascii.eqlIgnoreCase(d.unit, "s")) return @intFromFloat(num.clampF(d.value * 1000, 0, 600000));
        return null;
    }

    /// The numbers inside a function, separated by commas or white space.
    fn funcNumbers(v: []const Token, start: usize, out: []f32) struct { n: usize, end: usize } {
        var n: usize = 0;
        var i = start;
        while (i < v.len and v[i] != .rparen) : (i += 1) {
            if (v[i] == .number and n < out.len) {
                out[n] = v[i].number;
                n += 1;
            }
        }
        return .{ .n = n, .end = i };
    }

    /// A timing function at `v[i]`, or null. `i` moves past it.
    fn timingAt(v: []const Token, i: *usize) ?easing.Timing {
        const tk = v[i.*];
        switch (tk) {
            .ident => |n| {
                const named = [_]struct { []const u8, easing.Timing }{
                    .{ "linear", .linear },             .{ "ease", easing.Timing.ease },
                    .{ "ease-in", easing.Timing.ease_in }, .{ "ease-out", easing.Timing.ease_out },
                    .{ "ease-in-out", easing.Timing.ease_in_out },
                    .{ "step-start", .{ .steps = .{ .n = 1, .pos = .jump_start } } },
                    .{ "step-end", .{ .steps = .{ .n = 1, .pos = .jump_end } } },
                };
                for (named) |e| if (std.ascii.eqlIgnoreCase(n, e[0])) return e[1];
                return null;
            },
            .function => |f| {
                var nums: [4]f32 = undefined;
                const r = funcNumbers(v, i.* + 1, &nums);
                if (std.ascii.eqlIgnoreCase(f, "cubic-bezier")) {
                    if (r.n != 4) return null;
                    i.* = r.end;
                    return .{ .cubic = .{ num.clampF(nums[0], 0, 1), nums[1], num.clampF(nums[2], 0, 1), nums[3] } };
                }
                if (std.ascii.eqlIgnoreCase(f, "spring")) {
                    i.* = r.end;
                    var p = [3]f32{ 100, 10, 1 };
                    for (0..@min(r.n, 3)) |k| p[k] = num.clampF(nums[k], 0.01, 100000);
                    return .{ .spring = p };
                }
                if (std.ascii.eqlIgnoreCase(f, "steps")) {
                    if (r.n < 1) return null;
                    var pos: easing.StepPos = .jump_end;
                    var k = i.* + 1;
                    while (k < r.end) : (k += 1) if (v[k] == .ident) {
                        const w = v[k].ident;
                        if (std.ascii.eqlIgnoreCase(w, "jump-start") or std.ascii.eqlIgnoreCase(w, "start")) pos = .jump_start;
                        if (std.ascii.eqlIgnoreCase(w, "jump-none")) pos = .jump_none;
                        if (std.ascii.eqlIgnoreCase(w, "jump-both")) pos = .jump_both;
                    };
                    i.* = r.end;
                    return .{ .steps = .{ .n = @intFromFloat(num.clampF(nums[0], 1, 1000)), .pos = pos } };
                }
                return null;
            },
            else => return null,
        }
    }

    /// The properties that a name in `transition` selects, as a bit mask.
    fn propMask(name: []const u8) ?u16 {
        const one = struct {
            fn b(p: AnimProp) u16 {
                return @as(u16, 1) << @intFromEnum(p);
            }
        }.b;
        const table = [_]struct { []const u8, u16 }{
            .{ "all", 0xffff },
            .{ "color", one(.color) },
            .{ "background-color", one(.background) },
            .{ "background", one(.background) },
            .{ "border-color", one(.border_color) },
            .{ "border", one(.border_color) },
            .{ "outline-color", one(.outline_color) },
            .{ "outline", one(.outline_color) | one(.outline) },
            .{ "outline-offset", one(.outline) },
            .{ "caret-color", one(.caret_color) },
            .{ "opacity", one(.opacity) },
            .{ "border-radius", one(.radius) },
            .{ "box-shadow", one(.shadow) },
            .{ "padding", one(.padding) },
            .{ "min-width", one(.min_size) },
            .{ "min-height", one(.min_size) },
            .{ "none", 0 },
        };
        for (table) |e| if (std.ascii.eqlIgnoreCase(name, e[0])) return e[1];
        return null;
    }

    fn applyTransition(c: Ctx, st: *Style, v: []const Token) void {
        var t: Transition = .{};
        for (c.splitCommas(v)) |part_raw| {
            const part = trim(part_raw);
            var spec: TransSpec = .{};
            var mask: u16 = 0xffff;
            var times: u8 = 0;
            var i: usize = 0;
            while (i < part.len) : (i += 1) {
                const tk = part[i];
                if (tk == .whitespace) continue;
                if (timeMs(tk)) |ms| {
                    if (times == 0) spec.duration_ms = ms else spec.delay_ms = ms;
                    times += 1;
                    continue;
                }
                if (timingAt(part, &i)) |tm| {
                    spec.timing = tm;
                    continue;
                }
                if (tk == .ident) if (propMask(tk.ident)) |m| {
                    mask = m;
                };
            }
            for (&t.props, 0..) |*slot, k| if (mask & (@as(u16, 1) << @intCast(k)) != 0) {
                slot.* = spec;
            };
        }
        st.transition = t;
    }

    fn applyAnimation(c: Ctx, st: *Style, v: []const Token) void {
        var an: AnimationSpec = .{};
        var times: u8 = 0;
        var i: usize = 0;
        while (i < v.len) : (i += 1) {
            const tk = v[i];
            if (tk == .whitespace) continue;
            if (timeMs(tk)) |ms| {
                if (times == 0) an.spec.duration_ms = ms else an.spec.delay_ms = ms;
                times += 1;
                continue;
            }
            if (tk == .number) {
                an.count = num.clampF(tk.number, 0.001, 1000000);
                continue;
            }
            if (timingAt(v, &i)) |tm| {
                an.spec.timing = tm;
                continue;
            }
            if (tk == .ident) {
                const n = tk.ident;
                if (std.ascii.eqlIgnoreCase(n, "infinite")) {
                    an.count = 0;
                } else if (std.meta.stringToEnum(Direction, n)) |d| {
                    an.direction = d;
                } else if (std.ascii.eqlIgnoreCase(n, "alternate-reverse")) {
                    an.direction = .alternate_reverse;
                } else if (std.meta.stringToEnum(Fill, n)) |f| {
                    if (f != .none) an.fill = f else an.name = "";
                } else if (std.ascii.eqlIgnoreCase(n, "running") or std.ascii.eqlIgnoreCase(n, "paused")) {} else {
                    an.name = c.s.intern(n);
                }
            }
        }
        st.animation = an;
    }

    /// Applies declarations to a style, for a keyframe.
    fn applyAll(c: Ctx, st: *Style, decls: []const css_parse.Decl) void {
        for (decls) |d| {
            if (d.prop == .custom or d.prop == .transition or d.prop == .animation) continue;
            c.apply(st, d);
        }
    }
};

// ---- the commands ----

fn stringResult(it: *ztcl.Interp, text: []const u8) ztcl.Error!ztcl.Value {
    return .{ .str = try it.alloc().dupe(u8, text) };
}

/// `ztk::style add|load|remove|diagnostics|scheme|theme`
pub fn cmdStyle(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    const app = @import("app.zig").App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("ztk::style option ?arg ...?");
    const sub = try it.str(argv[1]);
    const a = it.alloc();
    if (std.mem.eql(u8, sub, "add")) {
        if (argv.len != 3) return it.wrongArgs("ztk::style add cssText");
        const id = app.styles.add(.app, "script", try it.str(argv[2])) catch return error.OutOfMemory;
        return stringResult(it, try std.fmt.allocPrint(a, "style{d}", .{id}));
    }
    if (std.mem.eql(u8, sub, "load")) {
        if (argv.len != 3) return it.wrongArgs("ztk::style load fileName");
        const root = app.style_root orelse return it.fail("ztk::style load is not allowed", .{});
        const name = try it.str(argv[2]);
        if (name.len == 0 or name[0] == '/' or std.mem.indexOf(u8, name, "..") != null) {
            return it.fail("file \"{s}\" is outside the style folder", .{name});
        }
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ root, name });
        const text = app.readFile(path, a) catch |e| {
            if (e == error.OutsideStyleFolder) return it.fail("file \"{s}\" is outside the style folder", .{name});
            return it.fail("cannot read \"{s}\": {s}", .{ name, @errorName(e) });
        };
        const id = app.styles.add(.app, name, text) catch return error.OutOfMemory;
        return stringResult(it, try std.fmt.allocPrint(a, "style{d}", .{id}));
    }
    if (std.mem.eql(u8, sub, "remove") or std.mem.eql(u8, sub, "diagnostics")) {
        if (argv.len != 3) return it.fail("wrong # args: should be \"ztk::style {s} id\"", .{sub});
        const text = try it.str(argv[2]);
        const id = if (std.mem.startsWith(u8, text, "style")) std.fmt.parseInt(u32, text[5..], 10) catch 0 else 0;
        if (id == 0) return it.fail("bad style id \"{s}\"", .{text});
        if (std.mem.eql(u8, sub, "remove")) {
            app.styles.remove(id);
            return ztcl.Value.empty;
        }
        const diags = app.styles.diagnostics(id);
        const items = try a.alloc(ztcl.Value, diags.len);
        for (diags, items) |dg, *slot| {
            slot.* = try ztcl.value.newList(a, &.{ .{ .int = dg.line }, .{ .str = try a.dupe(u8, dg.message) } });
        }
        return ztcl.value.wrapList(a, items);
    }
    if (std.mem.eql(u8, sub, "theme")) {
        // `ztk::style theme ?modern|classic?`: the look. It selects the `ttk` theme `default` or `classic`.
        if (argv.len > 3) return it.wrongArgs("ztk::style theme ?name?");
        if (argv.len == 3) {
            const name = try it.str(argv[2]);
            const ttk_name = if (std.mem.eql(u8, name, "modern")) "default" else if (std.mem.eql(u8, name, "classic")) "classic" else return it.fail("bad theme \"{s}\": must be classic or modern", .{name});
            _ = try @import("ttk/style.zig").useTheme(app, ttk_name);
            return ztcl.Value.empty;
        }
        return stringResult(it, if (app.classic_look) "classic" else "modern");
    }
    // The color scheme, for the colors of canvas items.
    if (std.mem.eql(u8, sub, "scheme")) return stringResult(it, if (app.env.dark) "dark" else "light");
    return it.fail("bad option \"{s}\": must be add, diagnostics, load, remove, scheme, or theme", .{sub});
}

/// `ztk::class path ?add|remove|set? ?name ...?`
pub fn cmdClass(it: *ztcl.Interp, argv: []const ztcl.Value, _: ?*ztcl.interp.Cmd) ztcl.Error!ztcl.Value {
    const app = @import("app.zig").App.of(it);
    app.enter();
    defer app.leave();
    if (argv.len < 2) return it.wrongArgs("ztk::class path ?add|remove|set? ?name ...?");
    const path = try it.str(argv[1]);
    const w = app.find(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const a = it.alloc();
    if (argv.len == 2) {
        var out: std.ArrayListUnmanaged(ztcl.Value) = .empty;
        for (w.classes.items) |cl| try out.append(a, .{ .str = try a.dupe(u8, cl) });
        return ztcl.value.newList(a, out.items);
    }
    const sub = try it.str(argv[2]);
    const gpa = app.gpa;
    if (std.mem.eql(u8, sub, "set")) {
        for (w.classes.items) |cl| gpa.free(cl);
        w.classes.clearRetainingCapacity();
    } else if (!std.mem.eql(u8, sub, "add") and !std.mem.eql(u8, sub, "remove")) {
        return it.fail("bad option \"{s}\": must be add, remove, or set", .{sub});
    }
    for (argv[3..]) |nv| {
        const name = try it.str(nv);
        var idx: ?usize = null;
        for (w.classes.items, 0..) |cl, i| if (std.mem.eql(u8, cl, name)) {
            idx = i;
        };
        if (std.mem.eql(u8, sub, "remove")) {
            if (idx) |i| gpa.free(w.classes.orderedRemove(i));
        } else if (idx == null) {
            const owned = try gpa.dupe(u8, name);
            errdefer gpa.free(owned);
            try w.classes.append(gpa, owned);
        }
    }
    w.invalidate(.{ .style = true, .measure = true, .layout = true, .paint = true });
    return ztcl.Value.empty;
}
