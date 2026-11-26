//! `ztk::inject`: input events from Tcl that take the path of the input
//! of a backend.
//!
//! `event generate` delivers one event to one widget, and the pointer
//! state of the dispatcher stays as it is. So a generated press and
//! release do not invoke a button, because the button checks the hover
//! flag that a real motion sets. `ztk::inject` makes one backend event
//! (`event.Event`) for the window of a toplevel and gives it to the event
//! handler of the App. The dispatcher then does the hit test, the hover
//! flags, Enter and Leave, the grab, the focus, and the click count, as
//! for a real event. Tools that drive an app use it, for example the MCP
//! bridge of dockyard, and an embed backend can use it.
//!
//! The forms, with x and y in logical pixels of the toplevel:
//!
//!     ztk::inject top motion x y
//!     ztk::inject top press button x y
//!     ztk::inject top release button x y
//!     ztk::inject top wheel x y delta      (delta as in <MouseWheel>: 120 is one step up)
//!     ztk::inject top key keysym ?press|release?
//!     ztk::inject top text string
//!
//! `-state mods` after the form gives the modifier bits, as for
//! `event generate`. `key` with no third word gives a press and a
//! release. `text` gives the text as a commit of an input method, so
//! each character is a press and a release of its keysym.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const event = @import("event.zig");
const keysym = @import("keysym.zig");
const App = app_mod.App;
const Value = ztcl.Value;

const usage = "ztk::inject toplevel motion|press|release|wheel|key|text ?arg ...? ?-state mods?";

pub fn register(it: *ztcl.Interp) !void {
    try it.register("ztk::inject", cmdInject);
}

fn cmdInject(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len < 3) return it.wrongArgs(usage);
    const app = App.of(it);
    const path = try it.str(argv[1]);
    const w = app.lookup(path) orelse return it.fail("bad window path name \"{s}\"", .{path});
    const top = w.toplevel();
    const win = app.winOf(top) orelse return it.fail("window \"{s}\" is not shown", .{path});
    const form = try it.str(argv[2]);
    var args = argv[3..];
    var mods: event.Mods = .{};
    if (args.len >= 2) if (std.mem.eql(u8, try it.str(args[args.len - 2]), "-state")) {
        mods = @bitCast(@as(u16, @intCast(std.math.clamp(try it.int(args[args.len - 1]), 0, 0x1fff))));
        args = args[0 .. args.len - 2];
    };
    const now: u32 = @truncate(@as(u64, @intCast(@max(app.loop.clock.now(app.loop.clock.ctx), 0))) / 1000);
    const eq = std.mem.eql;
    if (eq(u8, form, "motion")) {
        if (args.len != 2) return it.wrongArgs("ztk::inject toplevel motion x y");
        app.handleEvent(.{ .motion = .{ .window = win, .x = try coord(it, args[0]), .y = try coord(it, args[1]), .mods = mods, .time_ms = now } });
    } else if (eq(u8, form, "press") or eq(u8, form, "release")) {
        if (args.len != 3) return it.fail("wrong # args: should be \"ztk::inject toplevel {s} button x y\"", .{form});
        const button: u8 = @intCast(std.math.clamp(try it.int(args[0]), 1, 255));
        app.handleEvent(.{ .button = .{ .window = win, .button = button, .pressed = eq(u8, form, "press"), .x = try coord(it, args[1]), .y = try coord(it, args[2]), .mods = mods, .time_ms = now } });
    } else if (eq(u8, form, "wheel")) {
        if (args.len != 3) return it.wrongArgs("ztk::inject toplevel wheel x y delta");
        const delta = try coord(it, args[2]);
        app.handleEvent(.{ .scroll = .{ .window = win, .dx = 0, .dy = -delta / 120, .x = try coord(it, args[0]), .y = try coord(it, args[1]), .mods = mods, .time_ms = now } });
    } else if (eq(u8, form, "key")) {
        if (args.len != 1 and args.len != 2) return it.wrongArgs("ztk::inject toplevel key keysym ?press|release?");
        const name = try it.str(args[0]);
        const sym = keysym.fromName(name) orelse single(name) orelse return it.fail("bad keysym \"{s}\"", .{name});
        var press = true;
        var release = true;
        if (args.len == 2) {
            const which = try it.str(args[1]);
            if (eq(u8, which, "press")) release = false else if (eq(u8, which, "release")) press = false else return it.fail("bad key action \"{s}\": must be press or release", .{which});
        }
        var k: event.Event = .{ .key = .{ .window = win, .keysym = sym, .keycode = 0, .pressed = true, .repeat = false, .mods = mods, .time_ms = now } };
        // A printable key with no Control gives its text, as a backend does.
        if (!mods.control and !mods.mod1) if (codepoint(sym)) |cp| {
            const n = std.unicode.utf8Encode(cp, &k.key.text) catch 0;
            k.key.text_len = @intCast(n);
        };
        if (press) app.handleEvent(k);
        k.key.pressed = false;
        if (release) app.handleEvent(k);
    } else if (eq(u8, form, "text")) {
        if (args.len != 1) return it.wrongArgs("ztk::inject toplevel text string");
        const text = try it.str(args[0]);
        if (!std.unicode.utf8ValidateSlice(text)) return it.fail("the text is not valid UTF-8", .{});
        app.handleEvent(.{ .commit = .{ .window = win, .text = text } });
    } else return it.fail("bad form \"{s}\": must be motion, press, release, wheel, key, or text", .{form});
    return Value.empty;
}

fn coord(it: *ztcl.Interp, v: Value) ztcl.Error!f32 {
    const s = try it.str(v);
    const f = std.fmt.parseFloat(f64, s) catch return it.fail("expected number but got \"{s}\"", .{s});
    return @floatCast(f);
}

/// The printable code point of a keysym, or null.
fn codepoint(sym: u32) ?u21 {
    if (sym >= 0x20 and sym < 0x7f) return @intCast(sym);
    if (sym >= 0xa0 and sym < 0x100) return @intCast(sym);
    if (sym > 0x0100_0000 and sym <= 0x0110_ffff) return std.math.cast(u21, sym - 0x0100_0000);
    return null;
}

/// The keysym of a name of one character, for example "a" or "é".
fn single(name: []const u8) ?u32 {
    const view = std.unicode.Utf8View.init(name) catch return null;
    var cps = view.iterator();
    const cp = cps.nextCodepoint() orelse return null;
    if (cps.nextCodepoint() != null) return null;
    return keysym.fromCodepoint(cp);
}
