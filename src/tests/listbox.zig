//! Tests of the listbox: the options, each subcommand, the messages,
//! `-listvariable`, `see`, the views, and the four selection modes with
//! the pointer and the keys. The expected texts are from `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

test "listbox: options and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("listbox .l");
    try t.expectEqualStrings("-activestyle activeStyle ActiveStyle dotbox dotbox", try h.eval(".l configure -activestyle"));
    try t.expectEqualStrings("-selectmode selectMode SelectMode browse browse", try h.eval(".l configure -selectmode"));
    try t.expectEqualStrings("-height height Height 10 10", try h.eval(".l configure -height"));
    try t.expectEqualStrings("-listvariable listVariable Variable {} {}", try h.eval(".l configure -listvariable"));
    try t.expectEqualStrings("-1 0 0 0", try h.eval("list [.l nearest 5] [.l index end] [.l index active] [.l index anchor]"));
    _ = try h.eval(".l insert end a b c d e");
    const cases = [_][2][]const u8{
        .{ ".l bogus", "bad option \"bogus\": must be activate, bbox, cget, configure, curselection, delete, get, index, insert, itemcget, itemconfigure, nearest, scan, see, selection, size, xview, or yview" },
        .{ ".l index x", "bad listbox index \"x\": must be active, anchor, end, @x,y, or a number" },
        .{ ".l index end-1", "bad listbox index \"end-1\": must be active, anchor, end, @x,y, or a number" },
        .{ ".l index @3", "bad listbox index \"@3\": must be active, anchor, end, @x,y, or a number" },
        .{ ".l itemcget 5 -bg", "item number \"5\" out of range" },
        .{ ".l itemconfigure 0 -bogus 1", "unknown option \"-bogus\"" },
        .{ ".l itemconfigure 0 -f", "unknown option \"-f\"" },
        .{ ".l itemconfigure 0 -bg red -fg", "value for \"-fg\" missing" },
        .{ ".l itemconfigure 0 -bg xyzzy", "unknown color name \"xyzzy\"" },
        .{ ".l activate", "wrong # args: should be \".l activate index\"" },
        .{ ".l selection", "wrong # args: should be \".l selection option index ?index?\"" },
        .{ ".l selection includes", "wrong # args: should be \".l selection option index ?index?\"" },
        .{ ".l selection anchor 1 2", "wrong # args: should be \".l selection anchor index\"" },
        .{ ".l selection includes 1 2", "wrong # args: should be \".l selection includes index\"" },
        .{ ".l selection bogus 1", "bad option \"bogus\": must be anchor, clear, includes, or set" },
        .{ ".l scan", "wrong # args: should be \".l scan mark|dragto x y\"" },
        .{ ".l scan foo 1 2", "bad option \"foo\": must be mark or dragto" },
        .{ ".l delete", "wrong # args: should be \".l delete firstIndex ?lastIndex?\"" },
        .{ ".l insert", "wrong # args: should be \".l insert index ?element ...?\"" },
        .{ ".l get", "wrong # args: should be \".l get firstIndex ?lastIndex?\"" },
        .{ ".l bbox", "wrong # args: should be \".l bbox index\"" },
        .{ ".l nearest", "wrong # args: should be \".l nearest y\"" },
        .{ ".l see", "wrong # args: should be \".l see index\"" },
        .{ ".l index", "wrong # args: should be \".l index index\"" },
        .{ ".l itemconfigure", "wrong # args: should be \".l itemconfigure index ?-option? ?value? ?-option value ...?\"" },
        .{ ".l itemcget 0", "wrong # args: should be \".l itemcget index option\"" },
        .{ ".l curselection 1", "wrong # args: should be \".l curselection\"" },
        .{ ".l size 1", "wrong # args: should be \".l size\"" },
        .{ ".l yview foo", "bad listbox index \"foo\": must be active, anchor, end, @x,y, or a number" },
        .{ ".l configure -activestyle x", "bad activestyle \"x\": must be dotbox, none, or underline" },
        .{ ".l configure -state x", "bad state \"x\": must be disabled or normal" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try h.evalError(c[0]));
    _ = try h.eval(".l configure -selectmode bogus");
}

test "listbox: indexes, get, insert, delete, and the item options" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("listbox .l; .l insert end a b c d e");
    try t.expectEqualStrings("5 4 5", try h.eval("list [.l index end] [.l index active] [.l index anchor]"));
    try t.expectEqualStrings("-5 99 2 2", try h.eval("list [.l index -5] [.l index 99] [.l index { 2}] [.l index 0x2]"));
    try t.expectEqualStrings("", try h.eval(".l get 10"));
    try t.expectEqualStrings("b c d|e|a b|", try h.eval("join [list [.l get 1 3] [.l get end] [.l get -3 1] [.l get 3 1]] |"));
    _ = try h.eval(".l itemconfigure 0 -background red");
    try t.expectEqualStrings("{-background {} {} {} red} {-bg -background} {-fg -foreground} {-foreground {} {} {} {}} {-selectbackground {} {} {} {}} {-selectforeground {} {} {} {}}", try h.eval(".l itemconfigure 0"));
    try t.expectEqualStrings("red", try h.eval(".l itemcget 0 -bg"));
    try t.expectEqualStrings("-background {} {} {} red", try h.eval(".l itemconfigure 0 -bg"));
    _ = try h.eval(".l selection set 1 2; .l delete 0");
    try t.expectEqualStrings("0 1", try h.eval(".l curselection"));
    _ = try h.eval(".l selection clear 0 end; .l selection set 3 1");
    try t.expectEqualStrings("1 2 3", try h.eval(".l curselection"));
    _ = try h.eval(".l selection clear 0 end; .l selection set 1 2; .l insert 2 X");
    try t.expectEqualStrings("1 3", try h.eval(".l curselection"));
    try t.expectEqualStrings("1 0", try h.eval("list [.l selection includes 1] [.l selection includes 99]"));
    _ = try h.eval(".l selection anchor 99; .l activate -4");
    try t.expectEqualStrings("4 0", try h.eval("list [.l index anchor] [.l index active]"));
    _ = try h.eval(".l delete 3 1");
    try t.expectEqualStrings("5", try h.eval(".l size"));
    // A disabled listbox ignores the changes of the rows, the selection, and the active row.
    _ = try h.eval(".l configure -state disabled; .l insert end z; .l delete 0; .l selection clear 0 end; .l activate 3; .l selection anchor 0");
    try t.expectEqualStrings("5 {1 3} 0 4", try h.eval("list [.l size] [.l curselection] [.l index active] [.l index anchor]"));
}

test "listbox: the list variable in both directions" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("listbox .l; .l insert end a b c; .l configure -listvariable lv");
    try t.expectEqualStrings("a b c", try h.eval("set lv"));
    _ = try h.eval("set lv {x y}");
    try t.expectEqualStrings("2 x", try h.eval("list [.l size] [.l get 0]"));
    _ = try h.eval(".l insert end {two words}");
    try t.expectEqualStrings("x y {two words}", try h.eval("set lv"));
    _ = try h.eval("set lw {p q r}; listbox .m -listvariable lw");
    try t.expectEqualStrings("3 r", try h.eval("list [.m size] [.m get end]"));
    _ = try h.eval(".m selection set 2; set lw {p q}");
    try t.expectEqualStrings("", try h.eval(".m curselection"));
}

test "listbox: the views, see, nearest, and bbox" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("listbox .m; pack .m; update");
    try t.expectEqualStrings("0.0 1.0|0.0 1.0|", try h.eval("join [list [.m yview] [.m xview] [.m bbox 0]] |"));
    _ = try h.eval(".m insert end 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; update");
    try t.expectEqualStrings("0.0 0.5", try h.eval(".m yview"));
    _ = try h.eval(".m yview scroll 1 pages");
    try t.expectEqualStrings("0.4 0.9", try h.eval(".m yview"));
    _ = try h.eval(".m yview moveto 0.12");
    try t.expectEqualStrings("0.1 0.6", try h.eval(".m yview"));
    _ = try h.eval(".m yview 3");
    try t.expectEqualStrings("0.15 0.65", try h.eval(".m yview"));
    _ = try h.eval(".m yview scroll 2 units");
    try t.expectEqualStrings("0.25 0.75", try h.eval(".m yview"));
    _ = try h.eval(".m see 0");
    try t.expectEqualStrings("0.0 0.5", try h.eval(".m yview"));
    _ = try h.eval(".m see 19");
    try t.expectEqualStrings("0.5 1.0", try h.eval(".m yview"));
    _ = try h.eval(".m see 0; .m see 11");
    try t.expectEqualStrings("0.1 0.6", try h.eval(".m yview"));
    try t.expectEqualStrings("", try h.eval(".m bbox 0"));
    const b = try h.eval(".m bbox 2");
    var it = std.mem.splitScalar(u8, b, ' ');
    _ = it.next();
    const y = try std.fmt.parseInt(i64, it.next().?, 10);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("2", try h.eval(try std.fmt.bufPrint(&buf, ".m nearest {d}", .{y + 2})));
    try t.expectEqualStrings("11", try h.eval(".m nearest 9999"));
    try t.expectEqualStrings("2", try h.eval(".m index @0,-50"));
}

fn rowPoint(h: *Harness, path: []const u8, row: usize) ![2]f32 {
    var buf: [64]u8 = undefined;
    const r = try h.eval(try std.fmt.bufPrint(&buf, "{s} bbox {d}", .{ path, row }));
    var it = std.mem.splitScalar(u8, r, ' ');
    const x = try std.fmt.parseFloat(f32, it.next().?);
    const y = try std.fmt.parseFloat(f32, it.next().?);
    const w = h.app.find(path).?;
    return .{ x + @as(f32, @floatFromInt(w.geom.x)) + 1, y + @as(f32, @floatFromInt(w.geom.y)) + 2 };
}

test "listbox: browse and single with the pointer, and ListboxSelect" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set n 0; listbox .l; .l insert end a b c d e f; pack .l; bind .l <<ListboxSelect>> {incr n}; update");
    const p1 = try rowPoint(&h, ".l", 1);
    h.head.click(h.win, p1[0], p1[1]);
    try h.update();
    try t.expectEqualStrings("1 1 1", try h.eval("list [.l curselection] [.l index active] $n"));
    try t.expectEqualStrings(".l", try h.eval("focus"));
    // A drag in browse mode moves the selection with the pointer.
    const p3 = try rowPoint(&h, ".l", 3);
    // A pause, so that the press is not a double click.
    h.head.advance(1000);
    h.head.pointerMove(h.win, p1[0], p1[1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, p3[0], p3[1]);
    try h.update();
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("3 3", try h.eval("list [.l curselection] [.l index active]"));
    // The keys move the active row and the selection.
    try h.head.press(h.win, "Down");
    try h.update();
    try t.expectEqualStrings("4 4", try h.eval("list [.l curselection] [.l index active]"));
    try h.head.press(h.win, "Up");
    try h.head.press(h.win, "Up");
    try h.update();
    try t.expectEqualStrings("2", try h.eval(".l curselection"));
    _ = try h.eval(".l configure -selectmode single; focus .l; update");
    try h.head.press(h.win, "Down");
    try h.update();
    try t.expectEqualStrings("2 3", try h.eval("list [.l curselection] [.l index active]"));
    try h.head.press(h.win, "space");
    try h.update();
    try t.expectEqualStrings("3", try h.eval(".l curselection"));
}

test "listbox: multiple and extended with the pointer and the keys" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("listbox .l -selectmode multiple; .l insert end a b c d e f g; pack .l; update");
    const p = [_][2]f32{ try rowPoint(&h, ".l", 0), try rowPoint(&h, ".l", 1), try rowPoint(&h, ".l", 2), try rowPoint(&h, ".l", 3), try rowPoint(&h, ".l", 4), try rowPoint(&h, ".l", 5) };
    h.head.click(h.win, p[1][0], p[1][1]);
    try h.update();
    h.head.click(h.win, p[3][0], p[3][1]);
    try h.update();
    try t.expectEqualStrings("1 3", try h.eval(".l curselection"));
    h.head.advance(1000);
    h.head.click(h.win, p[1][0], p[1][1]);
    try h.update();
    try t.expectEqualStrings("3", try h.eval(".l curselection"));
    _ = try h.eval(".l configure -selectmode extended; .l selection clear 0 end; update");
    // A press and a drag select the range from the anchor.
    h.head.advance(1000);
    h.head.pointerMove(h.win, p[1][0], p[1][1]);
    h.head.pointerButton(h.win, 1, true);
    try h.update();
    h.head.pointerMove(h.win, p[4][0], p[4][1]);
    try h.update();
    h.head.pointerMove(h.win, p[3][0], p[3][1]);
    try h.update();
    h.head.pointerButton(h.win, 1, false);
    try h.update();
    try t.expectEqualStrings("1 2 3", try h.eval(".l curselection"));
    // Control with a press toggles one row and keeps the others.
    h.head.setMods(.{ .control = true });
    h.head.click(h.win, p[5][0], p[5][1]);
    try h.update();
    h.head.setMods(.{});
    try t.expectEqualStrings("1 2 3 5", try h.eval(".l curselection"));
    // Shift with a press extends from the anchor (row 5) and keeps the copy of the selection.
    h.head.setMods(.{ .shift = true });
    h.head.click(h.win, p[4][0], p[4][1]);
    try h.update();
    h.head.setMods(.{});
    try t.expectEqualStrings("1 2 3 4 5", try h.eval(".l curselection"));
    // Escape puts back the copy from before the Control press, as in wish.
    try h.head.press(h.win, "Escape");
    try h.update();
    try t.expectEqualStrings("1 2 3", try h.eval(".l curselection"));
    // Down selects one row, and Shift-Down extends it.
    _ = try h.eval(".l activate 0");
    try h.head.press(h.win, "Down");
    try h.update();
    try t.expectEqualStrings("1", try h.eval(".l curselection"));
    h.head.setMods(.{ .shift = true });
    try h.head.press(h.win, "Down");
    try h.head.press(h.win, "Down");
    h.head.setMods(.{});
    try h.update();
    try t.expectEqualStrings("1 2 3", try h.eval(".l curselection"));
    h.head.setMods(.{ .control = true });
    try h.head.press(h.win, "slash");
    h.head.setMods(.{});
    try h.update();
    try t.expectEqualStrings("0 1 2 3 4 5 6", try h.eval(".l curselection"));
    h.head.setMods(.{ .control = true });
    try h.head.press(h.win, "backslash");
    try h.head.press(h.win, "End");
    h.head.setMods(.{});
    try h.update();
    try t.expectEqualStrings("6 6", try h.eval("list [.l curselection] [.l index active]"));
}

test "listbox: the selection background moves between rows, and -emptytext" {
    var h: Harness = undefined;
    try h.initAnimated();
    defer h.deinit();
    _ = try h.eval("listbox .l -emptytext {No items}; pack .l; update");
    _ = try h.eval(".l insert end a b c d; .l selection set 0; update; .l selection clear 0; .l selection set 3; update");
    const w = h.app.find(".l").?;
    const d: *const @import("../widgets/listbox.zig").Data = @ptrCast(@alignCast(w.data.?));
    try t.expect(d.hl_moving);
    try t.expectEqual(@as(i64, 3), d.hl_row);
    try t.expectEqual(@as(f64, 0), d.hl_from);
    // A frame in the middle, then a replace: the next move starts at the shown row.
    h.head.advance(90);
    try h.update();
    try t.expect(d.hl_moving);
    _ = try h.eval(".l selection clear 0 end; .l selection set 1; update");
    try t.expect(d.hl_moving);
    try t.expectEqual(@as(i64, 1), d.hl_row);
    try t.expect(d.hl_from > 0.5 and d.hl_from < 3);
    // The end state.
    h.head.advance(400);
    try h.update();
    try t.expect(!d.hl_moving);
    // An empty listbox shows -emptytext.
    _ = try h.eval(".l delete 0 end; update");
    try t.expectEqualStrings("0", try h.eval(".l size"));
}
