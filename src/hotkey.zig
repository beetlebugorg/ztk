//! The `ztk::hotkey` command: global shortcuts, which work when the app
//! has no focus (ztk#63).
//!
//!     ztk::hotkey add <Control-Alt-k> script   ;# gives a name: hotkey1
//!     ztk::hotkey remove hotkey1
//!     ztk::hotkey names
//!
//! A shortcut reaches the keys of the whole desktop, so the embedder
//! grants the command with `Options.hotkeys`, and the ztk program with
//! `--allow hotkey`. With no grant, `add` is an error.
//!
//! A sequence is the modifiers and one key symbol, joined with `-`, in
//! the angle brackets of `bind` or without them. The modifiers are
//! `Control`, `Alt`, `Shift`, and `Super` (the logo key, also
//! `Command` and `Win`). An upper case letter adds Shift. `add` sends
//! the modifiers and the keysym to `hotkeyAdd` of the platform, which
//! gives an id, and a `hotkey` event with that id runs the script at
//! the global level.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const event = @import("base/event.zig");
const keysym = @import("base/keysym.zig");
const Value = ztcl.Value;

pub const Hotkey = struct {
    name: []u8,
    id: plat.HotkeyId,
    script: []u8,
};

pub const State = struct {
    list: std.ArrayListUnmanaged(Hotkey) = .empty,
    next: u32 = 1,

    pub fn deinit(s: *State, app: *App) void {
        for (s.list.items) |k| {
            app.platform.hotkeyRemove(k.id);
            app.gpa.free(k.name);
            app.gpa.free(k.script);
        }
        s.list.deinit(app.gpa);
    }
};

pub const Sequence = struct { mods: event.Mods, sym: u32 };

/// The modifiers and the keysym of a sequence, or null.
pub fn parse(text_in: []const u8) ?Sequence {
    var text = text_in;
    if (text.len >= 2 and text[0] == '<' and text[text.len - 1] == '>') text = text[1 .. text.len - 1];
    var mods: event.Mods = .{};
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        // A last part of "-" is the minus key.
        if (dash + 1 == rest.len) break;
        const m = rest[0..dash];
        if (std.mem.eql(u8, m, "Control")) {
            mods.control = true;
        } else if (std.mem.eql(u8, m, "Alt")) {
            mods.mod1 = true;
        } else if (std.mem.eql(u8, m, "Shift")) {
            mods.shift = true;
        } else if (std.mem.eql(u8, m, "Super") or std.mem.eql(u8, m, "Command") or std.mem.eql(u8, m, "Win")) {
            mods.mod4 = true;
        } else return null;
        rest = rest[dash + 1 ..];
    }
    const sym = keysym.fromName(rest) orelse return null;
    if (sym >= 'A' and sym <= 'Z') mods.shift = true;
    return .{ .mods = mods, .sym = sym };
}

pub fn cmdHotkey(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("ztk::hotkey add|names|remove ?arg ...?");
    const sub = try it.str(argv[1]);
    const s = &app.hotkeys;
    if (std.mem.eql(u8, sub, "add")) {
        if (argv.len != 4) return it.wrongArgs("ztk::hotkey add sequence script");
        if (!app.hotkeys_allowed) return it.fail("global shortcuts need a grant of the embedder (ztk --allow hotkey)", .{});
        if (!app.platform.hasHotkeys()) return it.fail("this platform has no global shortcuts", .{});
        const win = app.window orelse return it.fail("this platform has no global shortcuts", .{});
        const text = try it.str(argv[2]);
        const seq = parse(text) orelse return it.fail("bad shortcut \"{s}\"", .{text});
        const id = app.platform.hotkeyAdd(win, seq.mods, seq.sym);
        if (id == 0) return it.fail("the system refused the shortcut \"{s}\": another app may have it", .{text});
        const name = std.fmt.allocPrint(app.gpa, "hotkey{d}", .{s.next}) catch return error.OutOfMemory;
        const script = app.gpa.dupe(u8, try it.str(argv[3])) catch {
            app.gpa.free(name);
            return error.OutOfMemory;
        };
        s.list.append(app.gpa, .{ .name = name, .id = id, .script = script }) catch {
            app.gpa.free(name);
            app.gpa.free(script);
            app.platform.hotkeyRemove(id);
            return error.OutOfMemory;
        };
        s.next += 1;
        return .{ .str = try it.alloc().dupe(u8, name) };
    }
    if (std.mem.eql(u8, sub, "remove")) {
        if (argv.len != 3) return it.wrongArgs("ztk::hotkey remove name");
        const name = try it.str(argv[2]);
        for (s.list.items, 0..) |k, i| if (std.mem.eql(u8, k.name, name)) {
            app.platform.hotkeyRemove(k.id);
            app.gpa.free(k.name);
            app.gpa.free(k.script);
            _ = s.list.orderedRemove(i);
            return .{ .str = "" };
        };
        return it.fail("shortcut \"{s}\" doesn't exist", .{name});
    }
    if (std.mem.eql(u8, sub, "names")) {
        if (argv.len != 2) return it.wrongArgs("ztk::hotkey names");
        var out: std.ArrayListUnmanaged(u8) = .empty;
        for (s.list.items, 0..) |k, i| {
            if (i > 0) try out.append(it.alloc(), ' ');
            try out.appendSlice(it.alloc(), k.name);
        }
        return .{ .str = out.items };
    }
    return it.fail("bad option \"{s}\": must be add, names, or remove", .{sub});
}

/// Runs the script of a shortcut for a `hotkey` event.
pub fn handleEvent(app: *App, id: plat.HotkeyId) void {
    for (app.hotkeys.list.items) |k| if (k.id == id) {
        app.callback(k.script);
        return;
    };
}

test "hotkey: the sequences of a shortcut" {
    const a = parse("<Control-Alt-k>").?;
    try std.testing.expect(a.mods.control and a.mods.mod1 and !a.mods.shift);
    try std.testing.expectEqual(@as(u32, 'k'), a.sym);
    const b = parse("Super-K").?;
    try std.testing.expect(b.mods.mod4 and b.mods.shift);
    try std.testing.expectEqual(@as(u32, 0xffc2), parse("Control-F5").?.sym);
    try std.testing.expect(parse("Hyper-k") == null);
    try std.testing.expect(parse("Control-nokey") == null);
}
