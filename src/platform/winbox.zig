//! The color dialog, the font dialog, and the message box of the Win32
//! backend: `ChooseColorW` of comdlg32 for `tk_chooseColor`,
//! `ChooseFontW` for `tk fontchooser show`, and `MessageBoxW` for
//! `tk_messageBox`. Each runs modal on the UI thread with the owner
//! window. `colorConfig`, `fontConfig`, and `boxFlags` map the options of
//! ztk onto the structures of Windows, and the tests check them without a
//! dialog on the screen.
//!
//! `ChooseColorW` has no title in its structure, so a hook sets the
//! title of the dialog in `WM_INITDIALOG`. The 16 custom colors stay for
//! the life of the process, as in other Windows programs. `ChooseFontW`
//! gets its title from a hook of the same kind. Its `LOGFONTW` has the
//! height of the first font in pixels of the screen, as a negative number
//! for the height of the characters. The answer has the size in tenths
//! of a point. `MessageBoxW`
//! is in each Windows process, with no manifest: the message and the
//! detail go in its text with an empty line between them.
//!
//! The structures and the constants follow `commdlg.h` and `WinUser.h`
//! of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");
const geom = @import("../base/geom.zig");

pub const CHOOSECOLORW = extern struct {
    lStructSize: u32 = @sizeOf(CHOOSECOLORW),
    hwndOwner: ?w32.HWND = null,
    hInstance: ?*anyopaque = null,
    rgbResult: u32 = 0,
    lpCustColors: *[16]u32,
    Flags: u32 = 0,
    lCustData: isize = 0,
    lpfnHook: ?*const fn (?w32.HWND, u32, usize, isize) callconv(.winapi) usize = null,
    lpTemplateName: ?[*:0]const u16 = null,
};

pub const cc = struct {
    pub const rgb_init: u32 = 0x1;
    pub const full_open: u32 = 0x2;
    pub const enable_hook: u32 = 0x10;
    pub const any_color: u32 = 0x100;
};

const WM_INITDIALOG: u32 = 0x0110;

extern "comdlg32" fn ChooseColorW(c: *CHOOSECOLORW) callconv(.winapi) i32;
extern "user32" fn MessageBoxW(owner: ?w32.HWND, text: [*:0]const u16, caption: [*:0]const u16, flags: u32) callconv(.winapi) i32;
extern "user32" fn SetWindowTextW(h: w32.HWND, text: [*:0]const u16) callconv(.winapi) i32;

/// The custom colors of the dialog, white at the start.
var custom: [16]u32 = @splat(0xffffff);

/// A COLORREF is 0x00BBGGRR.
pub fn colorRef(c: geom.Color) u32 {
    return @as(u32, c.r) | @as(u32, c.g) << 8 | @as(u32, c.b) << 16;
}

pub fn colorOf(ref: u32) geom.Color {
    return .{ .r = @truncate(ref), .g = @truncate(ref >> 8), .b = @truncate(ref >> 16) };
}

/// The structure of `ChooseColorW` for the options: the first color, the
/// full dialog with the custom part open, and the hook of the title. The
/// title stays in memory of the caller.
pub fn colorConfig(opts: *const plat.ColorDialog, owner: ?w32.HWND, title: [*:0]const u16) CHOOSECOLORW {
    return .{
        .hwndOwner = owner,
        .rgbResult = colorRef(opts.initial),
        .lpCustColors = &custom,
        .Flags = cc.rgb_init | cc.full_open | cc.any_color | cc.enable_hook,
        .lCustData = @bitCast(@intFromPtr(title)),
        .lpfnHook = hook,
    };
}

fn hook(h: ?w32.HWND, msg: u32, _: usize, lp: isize) callconv(.winapi) usize {
    if (msg != WM_INITDIALOG) return 0;
    // The lParam of WM_INITDIALOG is the structure of the call.
    const c: *const CHOOSECOLORW = @ptrFromInt(@as(usize, @bitCast(lp)));
    const title: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(c.lCustData)));
    if (h) |hw| if (title[0] != 0) {
        _ = SetWindowTextW(hw, title);
    };
    return 0;
}

/// Runs the color dialog to its end: the chosen color, or null for a
/// cancel.
pub fn chooseColor(gpa: std.mem.Allocator, opts: *const plat.ColorDialog, owner: ?w32.HWND) ?geom.Color {
    const title = std.unicode.utf8ToUtf16LeAllocZ(gpa, opts.title) catch return null;
    defer gpa.free(title);
    var c = colorConfig(opts, owner, title.ptr);
    if (ChooseColorW(&c) == 0) return null;
    return colorOf(c.rgbResult);
}

pub const LOGFONTW = extern struct {
    lfHeight: i32 = 0,
    lfWidth: i32 = 0,
    lfEscapement: i32 = 0,
    lfOrientation: i32 = 0,
    lfWeight: i32 = 0,
    lfItalic: u8 = 0,
    lfUnderline: u8 = 0,
    lfStrikeOut: u8 = 0,
    /// DEFAULT_CHARSET.
    lfCharSet: u8 = 1,
    lfOutPrecision: u8 = 0,
    lfClipPrecision: u8 = 0,
    lfQuality: u8 = 0,
    lfPitchAndFamily: u8 = 0,
    lfFaceName: [32]u16 = @splat(0),
};

pub const CHOOSEFONTW = extern struct {
    lStructSize: u32 = @sizeOf(CHOOSEFONTW),
    hwndOwner: ?w32.HWND = null,
    hDC: ?*anyopaque = null,
    lpLogFont: *LOGFONTW,
    iPointSize: i32 = 0,
    Flags: u32 = 0,
    rgbColors: u32 = 0,
    lCustData: isize = 0,
    lpfnHook: ?*const fn (?w32.HWND, u32, usize, isize) callconv(.winapi) usize = null,
    lpTemplateName: ?[*:0]const u16 = null,
    hInstance: ?*anyopaque = null,
    lpszStyle: ?[*:0]u16 = null,
    nFontType: u16 = 0,
    missing_alignment: u16 = 0,
    nSizeMin: i32 = 0,
    nSizeMax: i32 = 0,
};

pub const cf = struct {
    pub const screen_fonts: u32 = 0x1;
    pub const enable_hook: u32 = 0x8;
    pub const init_to_logfont: u32 = 0x40;
    pub const effects: u32 = 0x100;
};

extern "comdlg32" fn ChooseFontW(c: *CHOOSEFONTW) callconv(.winapi) i32;
extern "user32" fn GetDpiForSystem() callconv(.winapi) u32;

/// The structures of `ChooseFontW` for the options: the first font in
/// `lf`, the screen fonts, the underline and strikeout boxes, and the
/// hook of the title. `dpi` is the count of pixels of the screen in one
/// inch, for the height of the first font. A family of more than 31
/// UTF-16 units stays empty, and the dialog then shows its default. The
/// title and `lf` stay in memory of the caller.
pub fn fontConfig(opts: *const plat.FontDialog, owner: ?w32.HWND, title: [*:0]const u16, lf: *LOGFONTW, dpi: u32) CHOOSEFONTW {
    const f = opts.initial;
    lf.* = .{
        .lfHeight = -@as(i32, @intCast((@as(u32, f.size) * dpi + 36) / 72)),
        .lfWeight = if (f.bold) 700 else 400,
        .lfItalic = @intFromBool(f.italic),
        .lfUnderline = @intFromBool(f.underline),
        .lfStrikeOut = @intFromBool(f.overstrike),
    };
    if (std.unicode.calcUtf16LeLen(f.family)) |n| {
        if (n < lf.lfFaceName.len) _ = std.unicode.utf8ToUtf16Le(&lf.lfFaceName, f.family) catch 0;
    } else |_| {}
    return .{
        .hwndOwner = owner,
        .lpLogFont = lf,
        .Flags = cf.screen_fonts | cf.init_to_logfont | cf.effects | cf.enable_hook,
        .lCustData = @bitCast(@intFromPtr(title)),
        .lpfnHook = fontHook,
    };
}

fn fontHook(h: ?w32.HWND, msg: u32, _: usize, lp: isize) callconv(.winapi) usize {
    if (msg != WM_INITDIALOG) return 0;
    // The lParam of WM_INITDIALOG is the structure of the call.
    const c: *const CHOOSEFONTW = @ptrFromInt(@as(usize, @bitCast(lp)));
    const title: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(c.lCustData)));
    if (h) |hw| if (title[0] != 0) {
        _ = SetWindowTextW(hw, title);
    };
    return 0;
}

/// The font of an answer of `ChooseFontW`: the family of `lf`, the size
/// of `tenths` (tenths of a point) as the nearest point, and the styles.
/// The family is in memory of `gpa`.
pub fn fontOf(gpa: std.mem.Allocator, lf: *const LOGFONTW, tenths: i32) !plat.FontChoice {
    const face = std.mem.sliceTo(&lf.lfFaceName, 0);
    return .{
        .family = try std.unicode.utf16LeToUtf8Alloc(gpa, face),
        .size = @intCast(std.math.clamp(@divTrunc(tenths + 5, 10), 1, 999)),
        .bold = lf.lfWeight >= 600,
        .italic = lf.lfItalic != 0,
        .underline = lf.lfUnderline != 0,
        .overstrike = lf.lfStrikeOut != 0,
    };
}

/// Runs the font dialog to its end: the chosen font, or null for a
/// cancel.
pub fn chooseFont(gpa: std.mem.Allocator, opts: *const plat.FontDialog, owner: ?w32.HWND) ?plat.FontChoice {
    const title = std.unicode.utf8ToUtf16LeAllocZ(gpa, opts.title) catch return null;
    defer gpa.free(title);
    var lf: LOGFONTW = .{};
    var c = fontConfig(opts, owner, title.ptr, &lf, GetDpiForSystem());
    if (ChooseFontW(&c) == 0) return null;
    return fontOf(gpa, &lf, c.iPointSize) catch null;
}

pub const mb = struct {
    pub const ok: u32 = 0x0;
    pub const okcancel: u32 = 0x1;
    pub const abortretryignore: u32 = 0x2;
    pub const yesnocancel: u32 = 0x3;
    pub const yesno: u32 = 0x4;
    pub const retrycancel: u32 = 0x5;
    pub const icon_error: u32 = 0x10;
    pub const icon_question: u32 = 0x20;
    pub const icon_warning: u32 = 0x30;
    pub const icon_information: u32 = 0x40;
    pub const default_button2: u32 = 0x100;
    pub const default_button3: u32 = 0x200;
    /// The box is modal to the owner window only, or to the thread with
    /// no owner.
    pub const task_modal: u32 = 0x2000;
    pub const set_foreground: u32 = 0x10000;
};

/// The buttons of each type, in the order of `MessageBoxW`.
fn buttonsOf(b: plat.MessageBox.Buttons) []const plat.MessageBox.Button {
    return switch (b) {
        .ok => &.{.ok},
        .okcancel => &.{ .ok, .cancel },
        .abortretryignore => &.{ .abort, .retry, .ignore },
        .yesnocancel => &.{ .yes, .no, .cancel },
        .yesno => &.{ .yes, .no },
        .retrycancel => &.{ .retry, .cancel },
    };
}

/// The flags of `MessageBoxW` for the options. A default that is not a
/// button of the type gives the first button.
pub fn boxFlags(opts: *const plat.MessageBox, owned: bool) u32 {
    var f: u32 = switch (opts.buttons) {
        .ok => mb.ok,
        .okcancel => mb.okcancel,
        .abortretryignore => mb.abortretryignore,
        .yesnocancel => mb.yesnocancel,
        .yesno => mb.yesno,
        .retrycancel => mb.retrycancel,
    };
    f |= switch (opts.icon) {
        .@"error" => mb.icon_error,
        .info => mb.icon_information,
        .question => mb.icon_question,
        .warning => mb.icon_warning,
    };
    const list = buttonsOf(opts.buttons);
    const at = std.mem.indexOfScalar(plat.MessageBox.Button, list, opts.default) orelse 0;
    f |= switch (at) {
        1 => mb.default_button2,
        2 => mb.default_button3,
        else => 0,
    };
    if (!owned) f |= mb.task_modal | mb.set_foreground;
    return f;
}

/// The button of an answer of `MessageBoxW` (IDOK 1 to IDNO 7). The Close
/// button and Escape give IDCANCEL, or IDOK for a box of one button.
pub fn buttonOf(id: i32) ?plat.MessageBox.Button {
    return switch (id) {
        1 => .ok,
        2 => .cancel,
        3 => .abort,
        4 => .retry,
        5 => .ignore,
        6 => .yes,
        7 => .no,
        else => null,
    };
}

/// The text of the box: the message, then the detail after an empty line.
pub fn boxText(gpa: std.mem.Allocator, opts: *const plat.MessageBox) ![:0]u16 {
    const s = if (opts.detail.len == 0)
        try gpa.dupe(u8, opts.message)
    else
        try std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ opts.message, opts.detail });
    defer gpa.free(s);
    return std.unicode.utf8ToUtf16LeAllocZ(gpa, s) catch |e| switch (e) {
        error.InvalidUtf8 => std.unicode.utf8ToUtf16LeAllocZ(gpa, ""),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Runs the message box to its end, and gives its button, or null when it
/// could not show.
pub fn messageBox(gpa: std.mem.Allocator, opts: *const plat.MessageBox, owner: ?w32.HWND) ?plat.MessageBox.Button {
    const text = boxText(gpa, opts) catch return null;
    defer gpa.free(text);
    const caption = std.unicode.utf8ToUtf16LeAllocZ(gpa, opts.title) catch return null;
    defer gpa.free(caption);
    return buttonOf(MessageBoxW(owner, text.ptr, caption.ptr, boxFlags(opts, owner != null)));
}
