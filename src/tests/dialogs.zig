//! Tests of the dialogs that ztk draws (`src/library/dialogs.tcl`): each
//! dialog with keys and the pointer through `event generate`, the
//! results, a cancel, and the messages of `wish` 8.6.16.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const build_options = @import("build_options");
const Harness = @import("../testing.zig").Harness;
const t = std.testing;

fn expectEvals(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = h.eval(c[0]) catch |e| {
            std.debug.print("{s}: {}\n", .{ c[0], e });
            return e;
        };
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("in: {s}\n", .{c[0]});
            return e;
        };
    }
}

fn expectErrors(h: *Harness, cases: []const [2][]const u8) !void {
    for (cases) |c| {
        const got = try h.evalError(c[0]);
        t.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("in: {s}\n", .{c[0]});
            return e;
        };
    }
}

test "dialogs: tk_messageBox, tk_dialog, and the messages of wish" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectEvals(&h, &.{
        .{ "after 10 {event generate [focus] <Key-Return>}; tk_messageBox -message hi -type yesno -icon question -title T -detail D", "yes" },
        .{ "winfo exists .__tk__messagebox", "0" },
        .{ "after 10 {event generate [focus] <Key-Escape>}; tk_messageBox -message hi -type yesnocancel", "cancel" },
        .{ "after 10 {event generate [focus] <Key-Escape>}; tk_messageBox -message hi -type yesno", "no" },
        .{ "after 10 {event generate [focus] <Key-Escape>}; tk_messageBox -message hi", "ok" },
        .{ "after 10 {event generate [focus] <Key-Return>}; tk_messageBox -message hi -type okcancel -default cancel", "cancel" },
        .{ "after 10 {set f [focus]; .__tk__messagebox.bot.retry invoke}; tk_messageBox -type abortretryignore", "retry" },
        .{ "set f", ".__tk__messagebox.bot.abort" },
        .{ "after 10 {set c [winfo class .__tk__messagebox]; set t [wm title .__tk__messagebox]; wm protocol .__tk__messagebox WM_DELETE_WINDOW}; after 20 {.__tk__messagebox.__cancel invoke}; tk_messageBox -type retrycancel -title Hello", "cancel" },
        .{ "list $c $t", "Dialog Hello" },
        .{ "after 10 {.d.bot.2 invoke}; tk_dialog .d Title Text questhead 1 A B C", "2" },
        .{ "after 10 {event generate [focus] <Key-Return>}; tk_dialog .d Title Text {} 1 A B C", "1" },
        .{ "after 10 {.d.__cancel invoke}; tk_dialog .d Title Text {} 0 A", "-1" },
    });
    try expectErrors(&h, &.{
        .{ "tk_messageBox -foo 1", "bad option \"-foo\": must be -default, -detail, -icon, -message, -parent, -title, or -type" },
        .{ "tk_messageBox -type foo", "bad -type value \"foo\": must be abortretryignore, ok, okcancel, retrycancel, yesno, or yesnocancel" },
        .{ "tk_messageBox -icon foo", "bad -icon value \"foo\": must be error, info, question, or warning" },
        .{ "tk_messageBox -type ok -default cancel", "bad -default value \"cancel\": must be abort, retry, ignore, ok, cancel, no, or yes" },
        .{ "tk_messageBox -parent .nope", "bad window path name \".nope\"" },
        .{ "tk_messageBox -message", "value for \"-message\" missing" },
        .{ "tk_dialog", "wrong # args: should be \"tk_dialog w title text bitmap default ?arg ...?\"" },
        .{ "tk_chooseColor -foo 1", "bad option \"-foo\": must be -initialcolor, -parent, or -title" },
        .{ "tk_chooseColor -initialcolor zzz", "unknown color name \"zzz\"" },
        .{ "::ztk::dialog::FileDialog dir -foo 1", "bad option \"-foo\": must be -initialdir, -mustexist, -parent, or -title" },
        .{ "::ztk::dialog::FileDialog open -foo 1", "bad option \"-foo\": must be -defaultextension, -filetypes, -initialdir, -initialfile, -multiple, -parent, -title, or -typevariable" },
        .{ "::ztk::dialog::FileDialog save -foo 1", "bad option \"-foo\": must be -confirmoverwrite, -defaultextension, -filetypes, -initialdir, -initialfile, -parent, -title, or -typevariable" },
        .{ "::ztk::dialog::FileDialog open -filetypes {{a}}", "bad file type \"a\", should be \"typeName {extension ?extensions ...?} ?{macType ?macTypes ...?}?\"" },
        .{ "ztk::toast hi -duration x", "expected integer but got \"x\"" },
    });
}

test "dialogs: tk_chooseColor with a swatch, the hex entry, and a cancel" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectEvals(&h, &.{
        .{ "after 10 {event generate [focus] <Key-Return>}; tk_chooseColor -initialcolor red", "#ff0000" },
        .{ "after 10 {event generate .__tk__color.top.sw.c10 <Button-1>; .__tk__color.bot.ok invoke}; tk_chooseColor", "#3b82f6" },
        .{ "after 10 {set ::ztk::dialog::color(hex) #102030; .__tk__color.bot.ok invoke}; tk_chooseColor", "#102030" },
        .{ "after 10 {event generate [focus] <Key-Escape>}; tk_chooseColor -initialcolor blue", "" },
        .{ "winfo exists .__tk__color", "0" },
    });
}

test "dialogs: tk_chooseColor gives a native color dialog its options" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    // A stand-in for the command of a backend with colorDialog.
    try expectEvals(&h, &.{
        .{ "proc ::ztk::priv::nativecolor {title r g b parent} {list $title $r $g $b $parent}; tk_chooseColor -initialcolor #102030 -title Pick", "Pick 16 32 48 ." },
        .{ "tk_chooseColor", "{Choose a color} 128 128 128 ." },
        .{ "rename ::ztk::priv::nativecolor {}; winfo exists .__tk__color", "0" },
    });
}

test "dialogs: tk fontchooser show gives a native font dialog its options and takes its font" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectEvals(&h, &.{
        // With no font dialog, the options are only stored.
        .{ "tk fontchooser show; tk fontchooser configure -visible", "1" },
        .{ "tk fontchooser hide; tk fontchooser configure -visible", "0" },
        // A stand-in for the command of a backend with fontDialog. It
        // keeps its words and the value of -visible during the dialog.
        .{ "proc ::ztk::priv::nativefont {args} {set ::words $args; set ::during [tk fontchooser configure -visible]; return {{Segoe UI} 14 bold overstrike}}; set ::log {}", "" },
        .{ "bind . <<TkFontchooserVisibility>> {lappend ::log vis}; bind . <<TkFontchooserFontChanged>> {lappend ::log font}", "" },
        .{ "tk fontchooser configure -title Pick -font {Helvetica 12 bold italic underline} -command {lappend ::log got}; tk fontchooser show", "" },
        .{ "lrange $::words 2 end", "12 1 1 1 0 ." },
        .{ "list [lindex $::words 0] $::during [tk fontchooser configure -visible]", "Pick 1 0" },
        .{ "update; set ::log", "vis vis got {{Segoe UI} 14 bold overstrike} font" },
        .{ "tk fontchooser configure -font", "{Segoe UI} 14 bold overstrike" },
        // A cancel changes no font and calls no command.
        .{ "proc ::ztk::priv::nativefont {args} {return {}}; set ::log {}; tk fontchooser show; update; list $::log [tk fontchooser configure -font]", "{vis vis} {{Segoe UI} 14 bold overstrike}" },
        // An empty -font gives the default font of the app.
        .{ "proc ::ztk::priv::nativefont {args} {set ::words $args; return {}}; tk fontchooser configure -font {}; tk fontchooser show; expr {[lindex $::words 1] eq [font actual TkDefaultFont -family]}", "1" },
        .{ "rename ::ztk::priv::nativefont {}", "" },
    });
}

test "dialogs: the file dialogs list a folder and give paths" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectErrors(&h, &.{.{ "::ztk::dialog::FileDialog open", "the file dialogs need the file capability" }});
    try h.it.allow(@backingInt(ztcl.interp.Capability.file));
    // The file commands see the folder examples/ as "/".
    const root = try std.fmt.allocPrint(t.allocator, "{s}/examples", .{build_options.repo_root});
    defer t.allocator.free(root);
    try ztcl.fsroot.setRoot(&h.it, root);
    _ = try h.eval("set dir /");
    try expectEvals(&h, &.{
        .{ "after 10 {set l [.__tk_filedialog.list.l get 0 end]; .__tk_filedialog.bot.cancel invoke}; list [catch {::ztk::dialog::FileDialog open -initialdir $dir -filetypes {{Tcl .tcl} {Style .css}}} e] $e", "0 {}" },
        .{ "expr {[lsearch $l gallery.tcl] >= 0 && [lsearch $l gallery.css] < 0}", "1" },
        .{ "after 10 {set ::ztk::dialog::fd(name) gallery.tcl; event generate .__tk_filedialog.name.e <Key-Return>}; file tail [::ztk::dialog::FileDialog open -initialdir $dir -typevariable ty -filetypes {{Tcl .tcl} {All *}}]", "gallery.tcl" },
        .{ "set ty", "Tcl" },
        .{ "after 10 {set i [lsearch [.__tk_filedialog.list.l get 0 end] gallery.tcl]; .__tk_filedialog.list.l selection set $i; event generate .__tk_filedialog.list.l <<ListboxSelect>>; .__tk_filedialog.bot.ok invoke}; file tail [::ztk::dialog::FileDialog open -initialdir $dir]", "gallery.tcl" },
        .{ "after 10 {set ::ztk::dialog::fd(name) new; .__tk_filedialog.bot.ok invoke}; file tail [::ztk::dialog::FileDialog save -initialdir $dir -defaultextension .tcl]", "new.tcl" },
        .{ "after 10 {after 20 {set q [winfo exists .__tk__messagebox]; event generate [focus] <Key-Escape>; after 10 {.__tk_filedialog.bot.cancel invoke}}; set ::ztk::dialog::fd(name) gallery.tcl; .__tk_filedialog.bot.ok invoke}; ::ztk::dialog::FileDialog save -initialdir $dir", "" },
        .{ "set q", "1" },
        .{ "after 10 {.__tk_filedialog.bot.ok invoke}; ::ztk::dialog::FileDialog dir -initialdir $dir", "/" },
    });
}

test "dialogs: a toast slides in and goes away, and the banner style" {
    var h: Harness = undefined;
    try h.init();
    defer h.deinit();
    try expectEvals(&h, &.{
        .{ "set w [ztk::toast Saved -duration 50]", ".__ztk_toast1" },
        .{ "winfo class $w", "Label" },
        .{ "after 700 {set done 1}; vwait done; winfo exists $w", "0" },
        .{ "frame .b; ztk::class .b add banner; ztk::class .b", "banner" },
    });
}
