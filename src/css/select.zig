//! Selector matching. A selector matches a widget (or a part of it) when
//! its last compound matches the widget and each earlier compound
//! matches the parent (child combinator) or an ancestor (descendant
//! combinator). The type is the Tk class of the widget, the id is the
//! last part of its path, and a class is an entry of its style classes.
//! The pseudo-classes read the state bits of the widget.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const parse = @import("parse.zig");
const widget = @import("../widget.zig");
const Widget = widget.Widget;

fn pseudoMatches(p: parse.Pseudo, w: *const Widget) bool {
    return switch (p) {
        .hover => w.state.hover,
        .active => w.state.pressed,
        .focus, .focus_visible => w.state.focus,
        .disabled => w.state.disabled,
        .checked => w.state.selected,
        .read_only => w.state.readonly,
        .invalid => w.state.invalid,
        .indeterminate => w.state.alternate,
        .window_inactive => w.state.background,
        .root => w.parent == null,
        .scrolling => w.state.scrolling,
        .placeholder_shown => w.state.placeholder,
    };
}

/// The state bit of a `ttk` state name. An unknown name matches nothing.
fn stateMatches(name: []const u8, w: *const Widget) bool {
    if (name.len > 0 and name[0] == '!') return !stateMatches(name[1..], w);
    const s = w.state;
    if (std.mem.eql(u8, name, "hover")) return s.hover;
    if (name.len == 5 and std.mem.startsWith(u8, name, "user") and name[4] >= '1' and name[4] <= '6') {
        return w.ttk_user & (@as(u8, 1) << @intCast('6' - name[4])) != 0;
    }
    if (std.mem.eql(u8, name, "active")) return s.hover;
    if (std.mem.eql(u8, name, "pressed")) return s.pressed;
    if (std.mem.eql(u8, name, "focus")) return s.focus;
    if (std.mem.eql(u8, name, "disabled")) return s.disabled;
    if (std.mem.eql(u8, name, "selected")) return s.selected;
    if (std.mem.eql(u8, name, "readonly")) return s.readonly;
    if (std.mem.eql(u8, name, "invalid")) return s.invalid;
    if (std.mem.eql(u8, name, "alternate")) return s.alternate;
    if (std.mem.eql(u8, name, "background")) return s.background;
    return false;
}

fn compoundMatches(c: *const parse.Compound, w: *const Widget) bool {
    if (c.type_name) |t| if (!std.mem.eql(u8, t, w.styleType()) and !std.mem.eql(u8, t, w.class.css_base)) return false;
    if (c.id) |id| if (!std.mem.eql(u8, id, w.name())) return false;
    for (c.classes) |cl| if (!w.hasClass(cl)) return false;
    for (c.pseudos) |p| if (!pseudoMatches(p, w)) return false;
    for (c.states) |s| if (!stateMatches(s, w)) return false;
    return true;
}

fn matchFrom(compounds: []const parse.Compound, idx: usize, w: *const Widget) bool {
    if (!compoundMatches(&compounds[idx], w)) return false;
    if (idx == 0) return true;
    switch (compounds[idx].combinator) {
        .child => {
            const p = w.parent orelse return false;
            return matchFrom(compounds, idx - 1, p);
        },
        .descendant => {
            var a = w.parent;
            while (a) |x| : (a = x.parent) if (matchFrom(compounds, idx - 1, x)) return true;
            return false;
        },
        .none => return true,
    }
}

/// A selector with a part matches only when `part` is that name. A
/// selector with no part matches only when `part` is null.
pub fn matches(sel: *const parse.Selector, w: *const Widget, part: ?[]const u8) bool {
    if (sel.part) |sp| {
        const p = part orelse return false;
        if (!std.mem.eql(u8, sp, p)) return false;
    } else if (part != null) return false;
    return matchFrom(sel.compounds, sel.compounds.len - 1, w);
}
