//! Tests of `ztk::terminal`: the options, `write` and `get`, the keys
//! and the replies through `-inputcommand`, the selection, the view of
//! the scrollback, and a frame with colors. The tests start no program.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Harness = @import("../testing.zig").Harness;
const testing_h = @import("../testing.zig");
const t = std.testing;

test "terminal: size, write, and get" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::terminal .t -width 20 -height 5; pack .t; update");
    try t.expectEqualStrings("20 5", try h.eval(".t size"));
    try t.expectEqualStrings("Terminal", try h.eval("winfo class .t"));
    _ = try h.eval(".t write \"hello\\r\\nworld\"");
    try t.expectEqualStrings("hello\nworld", try h.eval(".t get 0 1"));
    try t.expectEqualStrings("5 1", try h.eval(".t cursor"));
    _ = try h.eval(".t write \"\\x1b\\]0;my title\\x07\"");
    try t.expectEqualStrings("my title", try h.eval(".t title"));
    try t.expectEqualStrings("wrong # args: should be \".t write data\"", try h.evalError(".t write"));
    try t.expectEqualStrings("none", try h.eval(".t status"));
}

test "terminal: keys and replies go to -inputcommand" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("set sent {}; ztk::terminal .t -width 20 -height 5 -inputcommand {append ::sent}; pack .t; update");
    _ = try h.eval("event generate .t <Key-Up>; event generate .t <Key-Return>; event generate .t <Control-Key-c>");
    try t.expectEqualStrings("\x1b[A\r\x03", try h.eval("set sent"));
    // The application cursor mode changes the cursor keys.
    _ = try h.eval("set sent {}; .t write \"\\x1b\\[?1h\"; event generate .t <Key-Up>");
    try t.expectEqualStrings("\x1bOA", try h.eval("set sent"));
    _ = try h.eval("set sent {}; .t write \"ab\\x1b\\[6n\"");
    try t.expectEqualStrings("\x1b[1;3R", try h.eval("set sent"));
    // A paste with the bracketed paste mode.
    _ = try h.eval("set sent {}; .t write \"\\x1b\\[?2004h\"; .t paste \"x\\ny\"");
    try t.expectEqualStrings("\x1b[200~x\ry\x1b[201~", try h.eval("set sent"));
}

test "terminal: selection and copy" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::terminal .t -width 10 -height 3; pack .t; update");
    _ = try h.eval(".t write \"one two\\r\\nthree\"");
    _ = try h.eval(".t selection range 0 4 1 3");
    try t.expectEqualStrings("two\nthr", try h.eval(".t selection get"));
    _ = try h.eval(".t copy");
    try t.expectEqualStrings("two\nthr", try h.eval("clipboard get"));
    _ = try h.eval(".t selection clear");
    try t.expectEqualStrings("", try h.eval(".t selection get"));
}

test "terminal: the scrollback and the view" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::terminal .t -width 10 -height 4 -scrollback 100; pack .t; update");
    _ = try h.eval("for {set i 1} {$i <= 10} {incr i} {.t write \"line $i\\r\\n\"}");
    try t.expectEqualStrings("line 8\nline 9\nline 10\n", try h.eval(".t get"));
    try t.expectEqualStrings("line 1", try h.eval(".t get -7"));
    try t.expectEqualStrings("0.6363636363636364 1.0", try h.eval(".t yview"));
    _ = try h.eval(".t yview scroll -2 units");
    try t.expectEqualStrings("0.45454545454545453 0.8181818181818182", try h.eval(".t yview"));
    _ = try h.eval(".t yview moveto 0");
    try t.expectEqualStrings("0.0 0.36363636363636365", try h.eval(".t yview"));
    _ = try h.eval("update");
}

test "terminal: a frame with colors, wide characters, and the alternate screen" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::terminal .t -width 30 -height 6; pack .t; focus -force .t; update");
    _ = try h.eval(".t write \"\\x1b\\[1;31mred\\x1b\\[0m \\x1b\\[38;2;10;200;30;48;5;17mrgb\\x1b\\[0m \\u4e2d\\u6587 \\x1b\\[7minv\\x1b\\[0m\\x1b(0lqk\\x1b(B\"");
    _ = try h.eval(".t selection range 0 0 0 3; update");
    _ = try h.eval(".t write \"\\x1b\\[?1049h\\x1b\\[2J\\x1b\\[3;3Hfull\"; update");
    try t.expectEqualStrings("  full", try h.eval(".t get 2"));
    _ = try h.eval(".t write \"\\x1b\\[?1049l\"; update");
    try t.expectEqualStrings("red rgb \u{4e2d}\u{6587} inv\u{250c}\u{2500}\u{2510}", try h.eval(".t get 0"));
    _ = try h.eval("destroy .t; update");
}

test "terminal: -command runs cmd.exe on the pseudo console of Windows" {
    if (@import("builtin").os.tag != .windows or !@import("ztcl").pty.supported) return error.SkipZigTest;
    const ztcl = @import("ztcl");
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    const env = [_][:0]const u8{ "PATH=C:\\Windows\\System32", "SystemRoot=C:\\Windows" };
    h.it.exec_host = .{ .env = &env };
    try h.it.allow(@backingInt(ztcl.interp.Capability.exec) | @backingInt(ztcl.interp.Capability.channels));
    _ = try h.eval("set ::done {}; ztk::terminal .t -width 40 -height 6 -command {cmd.exe /c echo hi-term} -exitcommand {set ::done}; pack .t; update");
    try t.expectEqualStrings("running", try h.eval(".t status"));
    // The widget reads its PTY on a timer of the loop.
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        h.head.advance(10_000);
        try h.update();
        if (!std.mem.eql(u8, try h.eval("set ::done"), "")) break;
        ztcl.proc.sleepMs(10);
    }
    try t.expect(std.mem.indexOf(u8, try h.eval(".t get 0 5"), "hi-term") != null);
    try t.expectEqualStrings("exit 0", try h.eval("set ::done"));
}

test "terminal: -shell runs the shell of ztcl" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    _ = try h.eval("ztk::terminal .t -shell 1 -width 40 -height 6; pack .t; update");
    _ = try h.eval(".t send \"set x 4\\r\"");
    try t.expectEqualStrings("% set x 4\n4\n%", try h.eval(".t get 0 2"));
    // Tab completes a command and a subcommand.
    _ = try h.eval(".t send \"pu\\t\\$x\\r\"");
    try t.expectEqualStrings("% puts $x\n4", try h.eval(".t get 2 3"));
    _ = try h.eval(".t send \"string tou\\t\"");
    try t.expectEqualStrings("% string toupper", try h.eval(".t get 4 4"));
    // A command of the shell can destroy the widget.
    _ = try h.eval(".t send \"\\x15destroy .t\\r\"");
    try t.expectEqualStrings("0", try h.eval("winfo exists .t"));
    _ = try h.eval("ztk::terminal .u -shell 1; .u configure -shell 0; destroy .u");
}

test "terminal: hello in the cells of the monospace face" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // TkFixedFont is JetBrains Mono, so each letter fills its cell, and
    // the golden image has no gap after the narrow l.
    const fonts = &h.app.fonts;
    const f = try fonts.get(.{ .family = "monospace", .size = 12 }, 1);
    try t.expect(f.face == fonts.faces.items[@import("../text/font.zig").Fonts.mono_face]);
    _ = try h.eval("wm geometry . 120x40; ztk::terminal .t -width 8 -height 1; pack .t; .t write hello; update");
    try h.update();
    try testing_h.expectGolden("terminal-hello", h.head.image(h.win).?, .{});
    try testing_h.expectScene("terminal-hello", h.app.lastScene());
}
