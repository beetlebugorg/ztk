//! The backend interface. A backend makes windows, gives events, tells
//! the time, and draws a scene. A `Platform` is a pointer and a table of
//! functions. The core calls a backend only through this table.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const geom = @import("../geom.zig");
const event = @import("../event.zig");
const loop = @import("../loop.zig");
const Event = event.Event;
const Target = @import("../render/thread.zig").Target;
const RenderThread = @import("../render/thread.zig").RenderThread;

pub const WindowOptions = struct {
    title: []const u8 = "",
    size: geom.Size = .{ .w = 200, .h = 200 },
    /// Null: a toplevel window. Else a popup surface next to an anchor
    /// in a parent window. Only a backend with `Platform.popups` reads it.
    popup: ?Popup = null,
};

/// A popup surface: a drawn menu or a drop-down list. On Wayland it is an
/// `xdg_popup`, and on the web it is a canvas in a layer above the page.
/// The popup can extend past the edges of its parent. The backend sends
/// `close` for the popup when the system dismissed it, for example after
/// a press outside it.
pub const Popup = struct {
    parent: *Window,
    /// The rectangle in the parent, in logical pixels, that the popup goes next to.
    anchor: geom.Rect,
    /// The side of the anchor for the popup. With `below`, the top-left
    /// corner of the popup goes at the bottom-left corner of the anchor.
    /// With `right`, it goes at the top-right corner. With `above` and
    /// `left`, the popup ends at the top and the left edge of the anchor.
    /// When the screen has no room on that side, the backend flips the
    /// popup to the other side of the anchor or slides it along the edge.
    side: Side = .below,
    /// A move of the popup from its place at the anchor, in logical pixels.
    offset: geom.Point = .{},
    /// The edges of the surface outside the box of the popup, for a shadow.
    /// The anchor, the offset, and the edges of the screen place the box.
    /// On Wayland it is the window geometry of the `xdg_surface`.
    margin: geom.Insets = .{},
    /// True: the popup gets the pointer and the keys of the program until it closes.
    grab: bool = true,

    pub const Side = enum { below, above, right, left };
};

/// The id of one native menu. The core gives each `menu` widget one id.
/// 0 is no menu.
pub const MenuId = u32;

/// One entry of a native menu. The strings are valid only during the call
/// that gives them: the backend copies what it keeps.
pub const MenuEntry = struct {
    kind: Kind = .command,
    /// UTF-8. Empty for a separator.
    label: []const u8 = "",
    /// The text of `-accelerator`, for example "Ctrl+O". The backend shows
    /// it at the right of the label. In Tk an accelerator only shows: a
    /// binding of the script handles the key. So the backend gives the key
    /// to the core as a `key` event and does not invoke the entry from it.
    accelerator: []const u8 = "",
    /// The character index in `label` of the underlined letter (`-underline`), or -1.
    underline: i32 = -1,
    enabled: bool = true,
    /// The indicator of a check or radio entry is on.
    selected: bool = false,
    /// The submenu of a cascade, or 0.
    submenu: MenuId = 0,
    /// The entry starts a new column (`-columnbreak`).
    column_break: bool = false,

    pub const Kind = enum { command, cascade, checkbutton, radiobutton, separator };
};

/// The entries of one native menu. The tearoff entry of Tk is not in the list.
pub const Menu = struct {
    id: MenuId,
    /// The title of the menu: the label of its cascade in a menu bar.
    title: []const u8 = "",
    /// The special place of the menu in a menu bar. The core sets it from
    /// the path name, as Tk on macOS does: a cascade `.apple` of the bar
    /// is `app`, `.help` is `help`, and `.window` is `window`. A backend
    /// without such menus ignores it.
    role: Role = .none,
    entries: []const MenuEntry,

    pub const Role = enum {
        none,
        /// The entries go at the top of the application menu (macOS).
        app,
        /// The Help menu of the system.
        help,
        /// The Window menu of the system.
        window,
    };
};

/// A function of the core that a backend calls on the UI thread, inside
/// its menu loop, for the actions `opening` and `select` of a native menu.
/// For `opening` the core runs `-postcommand` and calls `menuSet` before
/// the call returns, so the menu shows its new entries. For `select` the
/// core sends `<<MenuSelect>>` before the call returns. `entry` has the
/// meaning of the `menu` event. The backend queues `invoke` and `closed`
/// as `menu` events.
pub const MenuHandler = struct {
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, id: MenuId, entry: i32, action: event.MenuAction) void,
};

/// The id of one tray icon. 0 is no tray.
pub const TrayId = u32;

/// The icon of a tray: RGBA, 8 bits, straight alpha, rows from the top.
/// The pixels are valid only during the call that gives them.
pub const TrayIcon = struct { width: u32, height: u32, pixels: []const u8 };

/// The kinds of data that a window accepts from the drops of other apps.
pub const DropTypes = packed struct(u8) {
    files: bool = false,
    text: bool = false,
    _pad: u6 = 0,

    pub fn any(t: DropTypes) bool {
        return t.files or t.text;
    }
};

/// The options of a native file dialog. The strings are UTF-8 and are
/// valid only during the call.
pub const FileDialog = struct {
    kind: Kind,
    /// The window that owns the dialog, or null.
    parent: ?*Window = null,
    title: []const u8 = "",
    /// The folder that the dialog shows first, and the first file name.
    initial_dir: []const u8 = "",
    initial_file: []const u8 = "",
    /// The filters of `-filetypes`, in order.
    filters: []const Filter = &.{},
    /// The extension that a save adds to a name with none, with no dot.
    default_ext: []const u8 = "",
    /// An open of more than one file.
    multiple: bool = false,
    /// A save asks before it replaces a file.
    confirm_overwrite: bool = true,

    pub const Kind = enum { open, save, folder };
    /// A filter: its name, and its patterns such as `*.txt`.
    pub const Filter = struct { name: []const u8, patterns: []const []const u8 };
};

/// The options of a native message box. The strings are UTF-8 and are
/// valid only during the call.
pub const MessageBox = struct {
    /// The window that owns the box, or null.
    parent: ?*Window = null,
    title: []const u8 = "",
    message: []const u8 = "",
    detail: []const u8 = "",
    icon: Icon = .info,
    buttons: Buttons = .ok,
    /// The button of the Return key.
    default: Button = .ok,

    pub const Icon = enum { @"error", info, question, warning };
    pub const Buttons = enum { abortretryignore, ok, okcancel, retrycancel, yesno, yesnocancel };
    pub const Button = enum { abort, retry, ignore, ok, cancel, no, yes };
};

/// The state of a window that `wm attributes` sets (ztk#68).
pub const WindowState = struct {
    /// The window covers its monitor with no frame.
    fullscreen: bool = false,
    /// The window stays above the windows that are not topmost.
    topmost: bool = false,
};
/// The options of a native color dialog. The title is UTF-8 and is valid
/// only during the call.
pub const ColorDialog = struct {
    /// The window that owns the dialog, or null.
    parent: ?*Window = null,
    title: []const u8 = "",
    /// The color that the dialog shows first.
    initial: geom.Color = .{ .r = 128, .g = 128, .b = 128 },
};
/// The answer of a file dialog, in memory of the allocator of the call.
pub const FileDialogResult = struct {
    /// The paths in UTF-8 with `/` between the parts.
    paths: [][]u8,
    /// The index of the filter that was chosen, or null.
    filter: ?u32 = null,

    pub fn deinit(r: FileDialogResult, gpa: std.mem.Allocator) void {
        for (r.paths) |p| gpa.free(p);
        gpa.free(r.paths);
    }
};
/// The id of one global shortcut. 0 is no shortcut.
pub const HotkeyId = u32;

/// The state of the taskbar or dock button of a window (ztk#61).
pub const Taskbar = struct {
    progress: Progress = .none,
    /// From 0 to 1, for `normal`, `paused`, and `failed`.
    value: f32 = 0,
    /// The count of the badge. 0 is no badge.
    badge: u32 = 0,

    pub const Progress = enum { none, normal, indeterminate, paused, failed };
};

/// The tabbing mode of a macOS window: `automatic` follows the setting of
/// the system, `preferred` opens new windows as tabs, and `disallowed`
/// gives the window no tab bar.
pub const Tabbing = enum { automatic, preferred, disallowed };

/// The appearance of the system.
pub const Appearance = struct {
    dark: bool,
    /// The accent color, when the system has one.
    accent: ?geom.Color = null,
};

/// The pointer shapes, with the names of the CSS `cursor` property.
pub const Cursor = enum {
    default,
    pointer,
    text,
    wait,
    progress,
    crosshair,
    move,
    not_allowed,
    help,
    grab,
    grabbing,
    ew_resize,
    ns_resize,
    nwse_resize,
    nesw_resize,

    /// The shape of a CSS name. A name with no shape gives `default`.
    pub fn fromCss(name: []const u8) Cursor {
        var buf: [16]u8 = undefined;
        if (name.len > buf.len) return .default;
        for (name, 0..) |ch, i| buf[i] = if (ch == '-') '_' else ch;
        return std.meta.stringToEnum(Cursor, buf[0..name.len]) orelse .default;
    }

    /// The shape of a cursor name of Tk (the X cursor font), or null
    /// for a name with no shape here.
    pub fn fromTk(name: []const u8) ?Cursor {
        const map = [_]struct { []const u8, Cursor }{
            .{ "arrow", .default },               .{ "left_ptr", .default },            .{ "top_left_arrow", .default },
            .{ "xterm", .text },                  .{ "hand1", .pointer },               .{ "hand2", .pointer },
            .{ "watch", .wait },                  .{ "crosshair", .crosshair },         .{ "cross", .crosshair },
            .{ "tcross", .crosshair },            .{ "fleur", .move },                  .{ "question_arrow", .help },
            .{ "sb_h_double_arrow", .ew_resize }, .{ "sb_v_double_arrow", .ns_resize }, .{ "X_cursor", .not_allowed },
            .{ "size_we", .ew_resize },           .{ "size_ns", .ns_resize },           .{ "size_nw_se", .nwse_resize },
            .{ "size_ne_sw", .nesw_resize },      .{ "size", .move },
        };
        for (map) |m| if (std.mem.eql(u8, m[0], name)) return m[1];
        return null;
    }
};

pub const Window = struct {
    /// Logical pixels.
    size: geom.Size,
    scale: f32 = 1,
    /// The toplevel widget.
    user: ?*anyopaque = null,
    /// The data of the backend.
    impl: ?*anyopaque = null,
    /// For a popup: the place of the top-left corner of its surface (with
    /// the margin) in the surface of its parent window, in logical pixels. The backend sets it, and sends `resize` when the
    /// place changes after a flip or a slide.
    pos: geom.Point = .{},
    /// The render thread of the window, for the pointer positions that the
    /// backend gives it from any thread. Null when the window has none.
    render: std.atomic.Value(?*RenderThread) = .init(null),

    /// Gives a pointer position to the render thread of the window.
    pub fn feedPointer(w: *Window, x: f32, y: f32) void {
        if (w.render.load(.acquire)) |r| r.pointer(x, y);
    }
};

pub const Platform = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// True for a backend that can give events by itself (a display).
    /// A wait on such a backend can end. A wait on the headless backend
    /// with no timer cannot.
    live: bool = false,
    /// True when the target can draw on a thread other than the UI thread.
    thread_safe_draw: bool = false,
    /// True when the backend shows native menus: the menu functions of
    /// the table. Else the core draws each menu as Tk does on X11.
    native_menus: bool = false,
    /// True when `createWindow` makes a popup surface for `WindowOptions.popup`.
    /// Else the core draws a popup inside its parent window.
    popups: bool = false,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        createWindow: *const fn (ptr: *anyopaque, opts: WindowOptions) anyerror!*Window,
        destroyWindow: *const fn (ptr: *anyopaque, w: *Window) void,
        setTitle: *const fn (ptr: *anyopaque, w: *Window, title: []const u8) void,
        /// Asks for a size. The backend answers with a `resize` event.
        requestSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        setMinSize: *const fn (ptr: *anyopaque, w: *Window, size: geom.Size) void,
        /// Asks for one `frame` event at the next display refresh.
        requestFrame: *const fn (ptr: *anyopaque, w: *Window) void,
        /// Blocks until an event exists or the time passed. Null: no limit.
        wait: *const fn (ptr: *anyopaque, timeout_us: ?i64) void,
        /// Moves the pending events to `out`.
        poll: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) anyerror!void,
        nowUs: *const fn (ptr: *anyopaque) i64,
        /// The target that draws and shows one frame of the window. The
        /// render thread calls it.
        target: *const fn (ptr: *anyopaque, w: *Window) Target,
        /// Sets the clock. Only a backend with a manual clock has it.
        setTimeUs: ?*const fn (ptr: *anyopaque, us: i64) void = null,
        /// Sets the pointer shape over the client area of a window. Null:
        /// the backend keeps its own shape.
        setCursor: ?*const fn (ptr: *anyopaque, w: *Window, shape: Cursor) void = null,
        /// Puts data of a type on the clipboard of the system. The core
        /// calls it with the type `STRING` and UTF-8 text.
        clipboardSet: ?*const fn (ptr: *anyopaque, typ: []const u8, data: []const u8) void = null,
        /// The data of a type on the clipboard of the system, in memory of
        /// `gpa`. Null: the system has no data of the type, or the data of
        /// the last `clipboardSet` is still the latest.
        clipboardGet: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 = null,
        /// Turns the input method of a window on for a text widget with the
        /// focus, or off. `rect` is the place of the text in logical pixels
        /// of the window, for the candidate window of the input method.
        textInput: ?*const fn (ptr: *anyopaque, w: *Window, on: bool, rect: geom.Rect) void = null,
        /// The dark mode and the accent color of the system. A backend
        /// gives an `appearance` event when they change.
        appearance: ?*const fn (ptr: *anyopaque) Appearance = null,
        /// Runs a native file dialog to its end, as `tk_getOpenFile`,
        /// `tk_getSaveFile`, and `tk_chooseDirectory` need. Null: the dialog
        /// was canceled, or it could not show.
        fileDialog: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, opts: *const FileDialog) ?FileDialogResult = null,
        /// Runs a native message box to its end, as `tk_messageBox` needs,
        /// and gives the name of the button that closed it, or null when it
        /// could not show.
        messageBox: ?*const fn (ptr: *anyopaque, opts: *const MessageBox) ?MessageBox.Button = null,
        /// Runs a native color dialog to its end, as `tk_chooseColor`
        /// needs. Null: the dialog was canceled, or it could not show.
        colorDialog: ?*const fn (ptr: *anyopaque, gpa: std.mem.Allocator, opts: *const ColorDialog) ?geom.Color = null,
        /// Sets the full screen and the topmost state of a window, from
        /// `wm attributes`.
        setWindowState: ?*const fn (ptr: *anyopaque, w: *Window, s: WindowState) void = null,
        /// The setting of the system to show less motion, which
        /// `ztk::animate` follows unless a script sets `reduce`. The core
        /// reads it at the start and on each `appearance` event.
        reducedMotion: ?*const fn (ptr: *anyopaque) bool = null,

        // The native menus. A backend with `native_menus` has each of these
        // functions. The core calls them on the UI thread. The backend
        // answers with `menu` events. `docs/dev/menus.md` has the design.

        /// Defines a menu or replaces each of its entries. The core calls it
        /// for each menu before the menu is in a menu bar, in a cascade, or
        /// posted, and again after each change of the menu.
        menuSet: ?*const fn (ptr: *anyopaque, menu: *const Menu) void = null,
        /// Changes one entry of a menu and keeps the count of entries, for
        /// example the indicator of a check entry.
        menuEntrySet: ?*const fn (ptr: *anyopaque, id: MenuId, index: u32, entry: *const MenuEntry) void = null,
        /// Removes a menu. The core removes it from each bar and each cascade first.
        menuDrop: ?*const fn (ptr: *anyopaque, id: MenuId) void = null,
        /// Sets the menu bar of a window (`toplevel -menu`). The cascades of
        /// the menu are the menus of the bar. 0 removes the bar. On macOS
        /// the system menu bar shows the bar of the key window.
        setMenuBar: ?*const fn (ptr: *anyopaque, w: *Window, id: MenuId) void = null,
        /// Shows a menu as a popup at a point of a window, in logical pixels
        /// (`post` and `tk_popup`). When `entry` is 0 or more, that entry
        /// goes at the point. A backend with a modal menu loop returns after
        /// the menu closes and queues the events of the menu.
        postMenu: ?*const fn (ptr: *anyopaque, w: *Window, id: MenuId, at: geom.Point, entry: i32) void = null,
        /// Closes a posted menu and its open cascades (`unpost`).
        unpostMenu: ?*const fn (ptr: *anyopaque, id: MenuId) void = null,
        /// Gives the backend the handler for `opening` and `select`. The
        /// core calls it one time, before the first menu call. A backend
        /// without it queues `opening` and `select` as `menu` events.
        setMenuHandler: ?*const fn (ptr: *anyopaque, h: MenuHandler) void = null,

        // The tray or status icons. `docs/dev/platform-features.md` has the design.

        /// Shows an icon in the tray (the notification area of Windows, the
        /// menu bar of macOS). `w` is the window that gets its events.
        /// `template` is for macOS, which draws a template icon in the colors
        /// of the menu bar. Gives 0 when the system has no tray.
        trayCreate: ?*const fn (ptr: *anyopaque, w: *Window, icon: TrayIcon, template: bool, tooltip: []const u8) TrayId = null,
        /// Changes the icon, the tooltip, and the menu of a tray. A menu of 0
        /// is no menu. A tray with a menu shows it in the backend.
        traySet: ?*const fn (ptr: *anyopaque, id: TrayId, icon: TrayIcon, template: bool, tooltip: []const u8, menu: MenuId) void = null,
        /// Removes a tray icon.
        trayDrop: ?*const fn (ptr: *anyopaque, id: TrayId) void = null,

        /// The name of the native look of the platform for the platform
        /// sheet of the modern theme (`windows`), or null for the default.
        nativeLook: ?*const fn (ptr: *anyopaque) ?[]const u8 = null,

        /// The text engine of the system for the fonts of the app
        /// (`text/system.zig`), or null for the TrueType faces of ztk.
        textSystem: ?*const fn (ptr: *anyopaque) ?@import("../text/system.zig").System = null,

        // The direct APIs of macOS (`ztk::mac::*`, ztk#65). Only the AppKit
        // backend has them, and the commands give an error elsewhere.

        /// The menu of the Dock icon, or 0 for no menu of the app.
        macDockMenu: ?*const fn (ptr: *anyopaque, id: MenuId) void = null,
        /// The tabs of a window: the tabbing mode, and the group of the
        /// windows that join one tab bar. An empty group is the default.
        macTabbing: ?*const fn (ptr: *anyopaque, w: *Window, mode: Tabbing, group: []const u8) void = null,

        // The taskbar or dock button (ztk#61).

        /// Shows the progress and the badge of `state` on the button of `w`.
        taskbarSet: ?*const fn (ptr: *anyopaque, w: *Window, state: Taskbar) void = null,
        /// Asks for the attention of the user with the button of `w`.
        /// `critical` keeps the request until the window has the focus.
        attention: ?*const fn (ptr: *anyopaque, w: *Window, critical: bool) void = null,
        // The recent documents of the app (ztk#64).

        /// Adds a file to the recent documents of the app. `path` is a
        /// full host path in UTF-8 with `/` between the parts. Gives false
        /// when the system refuses it.
        recentAdd: ?*const fn (ptr: *anyopaque, path: []const u8) bool = null,
        /// Empties the recent documents of the app, and only of the app.
        recentClear: ?*const fn (ptr: *anyopaque) void = null,
        // The global shortcuts (ztk#63).

        /// Registers a shortcut that works when the app has no focus: the
        /// key `keysym` with the modifiers `shift`, `control`, `mod1` (Alt),
        /// and `mod4` (the logo key) of `mods`. Its presses come as `hotkey`
        /// events for `w`. Gives 0 when the system refuses it, for example
        /// when another app has the shortcut.
        hotkeyAdd: ?*const fn (ptr: *anyopaque, w: *Window, mods: event.Mods, keysym: u32) HotkeyId = null,
        hotkeyRemove: ?*const fn (ptr: *anyopaque, id: HotkeyId) void = null,
        /// Sets the kinds of data that `w` accepts from the drops of other
        /// apps (ztk#62). No kind stops the drops. The drags come as `drop`
        /// events.
        dropTypes: ?*const fn (ptr: *anyopaque, w: *Window, types: DropTypes) void = null,
    };

    pub fn hasRecent(p: Platform) bool {
        return p.vtable.recentAdd != null and p.vtable.recentClear != null;
    }
    pub fn recentAdd(p: Platform, path: []const u8) bool {
        const f = p.vtable.recentAdd orelse return false;
        return f(p.ptr, path);
    }
    pub fn recentClear(p: Platform) void {
        if (p.vtable.recentClear) |f| f(p.ptr);
    }

    pub fn hasNativeMenus(p: Platform) bool {
        return p.native_menus and p.vtable.menuSet != null and p.vtable.postMenu != null;
    }
    pub fn menuSet(p: Platform, menu: *const Menu) void {
        if (p.vtable.menuSet) |f| f(p.ptr, menu);
    }
    pub fn menuEntrySet(p: Platform, id: MenuId, index: u32, entry: *const MenuEntry) void {
        if (p.vtable.menuEntrySet) |f| f(p.ptr, id, index, entry);
    }
    pub fn menuDrop(p: Platform, id: MenuId) void {
        if (p.vtable.menuDrop) |f| f(p.ptr, id);
    }
    pub fn setMenuBar(p: Platform, w: *Window, id: MenuId) void {
        if (p.vtable.setMenuBar) |f| f(p.ptr, w, id);
    }
    pub fn postMenu(p: Platform, w: *Window, id: MenuId, at: geom.Point, entry: i32) void {
        if (p.vtable.postMenu) |f| f(p.ptr, w, id, at, entry);
    }
    pub fn unpostMenu(p: Platform, id: MenuId) void {
        if (p.vtable.unpostMenu) |f| f(p.ptr, id);
    }
    pub fn hasTray(p: Platform) bool {
        return p.vtable.trayCreate != null and p.vtable.traySet != null and p.vtable.trayDrop != null;
    }
    pub fn trayCreate(p: Platform, w: *Window, icon: TrayIcon, template: bool, tooltip: []const u8) TrayId {
        const f = p.vtable.trayCreate orelse return 0;
        return f(p.ptr, w, icon, template, tooltip);
    }
    pub fn traySet(p: Platform, id: TrayId, icon: TrayIcon, template: bool, tooltip: []const u8, menu: MenuId) void {
        if (p.vtable.traySet) |f| f(p.ptr, id, icon, template, tooltip, menu);
    }
    pub fn trayDrop(p: Platform, id: TrayId) void {
        if (p.vtable.trayDrop) |f| f(p.ptr, id);
    }
    pub fn hasTaskbar(p: Platform) bool {
        return p.vtable.taskbarSet != null and p.vtable.attention != null;
    }
    pub fn taskbarSet(p: Platform, w: *Window, state: Taskbar) void {
        if (p.vtable.taskbarSet) |f| f(p.ptr, w, state);
    }
    pub fn attention(p: Platform, w: *Window, critical: bool) void {
        if (p.vtable.attention) |f| f(p.ptr, w, critical);
    }
    pub fn hasHotkeys(p: Platform) bool {
        return p.vtable.hotkeyAdd != null and p.vtable.hotkeyRemove != null;
    }
    pub fn hotkeyAdd(p: Platform, w: *Window, mods: event.Mods, keysym: u32) HotkeyId {
        const f = p.vtable.hotkeyAdd orelse return 0;
        return f(p.ptr, w, mods, keysym);
    }
    pub fn hotkeyRemove(p: Platform, id: HotkeyId) void {
        if (p.vtable.hotkeyRemove) |f| f(p.ptr, id);
    }
    pub fn textSystem(p: Platform) ?@import("../text/system.zig").System {
        const f = p.vtable.textSystem orelse return null;
        return f(p.ptr);
    }
    pub fn hasDrops(p: Platform) bool {
        return p.vtable.dropTypes != null;
    }
    pub fn dropTypes(p: Platform, w: *Window, types: DropTypes) void {
        if (p.vtable.dropTypes) |f| f(p.ptr, w, types);
    }
    pub fn nativeLook(p: Platform) ?[]const u8 {
        const f = p.vtable.nativeLook orelse return null;
        return f(p.ptr);
    }
    pub fn setMenuHandler(p: Platform, h: MenuHandler) void {
        if (p.vtable.setMenuHandler) |f| f(p.ptr, h);
    }

    /// Null: the backend has no appearance of the system.
    pub fn hasMessageBox(p: Platform) bool {
        return p.vtable.messageBox != null;
    }
    pub fn messageBox(p: Platform, opts: *const MessageBox) ?MessageBox.Button {
        const f = p.vtable.messageBox orelse return null;
        return f(p.ptr, opts);
    }
    pub fn hasWindowState(p: Platform) bool {
        return p.vtable.setWindowState != null;
    }
    pub fn setWindowState(p: Platform, w: *Window, s: WindowState) void {
        if (p.vtable.setWindowState) |f| f(p.ptr, w, s);
    }
    /// Null: the backend does not know the setting.
    pub fn reducedMotion(p: Platform) ?bool {
        const f = p.vtable.reducedMotion orelse return null;
        return f(p.ptr);
    }
    pub fn hasColorDialog(p: Platform) bool {
        return p.vtable.colorDialog != null;
    }
    pub fn colorDialog(p: Platform, gpa: std.mem.Allocator, opts: *const ColorDialog) ?geom.Color {
        const f = p.vtable.colorDialog orelse return null;
        return f(p.ptr, gpa, opts);
    }
    pub fn hasFileDialog(p: Platform) bool {
        return p.vtable.fileDialog != null;
    }
    pub fn fileDialog(p: Platform, gpa: std.mem.Allocator, opts: *const FileDialog) ?FileDialogResult {
        const f = p.vtable.fileDialog orelse return null;
        return f(p.ptr, gpa, opts);
    }
    pub fn appearance(p: Platform) ?Appearance {
        const f = p.vtable.appearance orelse return null;
        return f(p.ptr);
    }

    pub fn textInput(p: Platform, w: *Window, on: bool, rect: geom.Rect) void {
        if (p.vtable.textInput) |f| f(p.ptr, w, on, rect);
    }

    pub fn clipboardSet(p: Platform, typ: []const u8, data: []const u8) void {
        if (p.vtable.clipboardSet) |f| f(p.ptr, typ, data);
    }

    pub fn clipboardGet(p: Platform, gpa: std.mem.Allocator, typ: []const u8) ?[]u8 {
        const f = p.vtable.clipboardGet orelse return null;
        return f(p.ptr, gpa, typ);
    }

    pub fn setCursor(p: Platform, w: *Window, shape: Cursor) void {
        if (p.vtable.setCursor) |f| f(p.ptr, w, shape);
    }

    pub fn target(p: Platform, w: *Window) Target {
        return p.vtable.target(p.ptr, w);
    }
    pub fn createWindow(p: Platform, opts: WindowOptions) !*Window {
        return p.vtable.createWindow(p.ptr, opts);
    }
    pub fn destroyWindow(p: Platform, w: *Window) void {
        p.vtable.destroyWindow(p.ptr, w);
    }
    pub fn requestFrame(p: Platform, w: *Window) void {
        p.vtable.requestFrame(p.ptr, w);
    }
    pub fn nowUs(p: Platform) i64 {
        return p.vtable.nowUs(p.ptr);
    }
    pub fn wait(p: Platform, timeout_us: ?i64) void {
        p.vtable.wait(p.ptr, timeout_us);
    }
    pub fn poll(p: Platform, gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(Event)) !void {
        return p.vtable.poll(p.ptr, gpa, out);
    }

    fn clockNow(ctx: ?*anyopaque) i64 {
        const p: *const Platform = @ptrCast(@alignCast(ctx.?));
        return p.nowUs();
    }

    fn clockWait(ctx: ?*anyopaque, micros: ?i64) void {
        const p: *const Platform = @ptrCast(@alignCast(ctx.?));
        p.wait(micros);
    }

    /// The clock of the loop. `p` must stay at the same address while
    /// the clock is in use, so the App keeps its Platform and gives the
    /// address. This differs from the plan, which passes the value.
    pub fn clock(p: *const Platform) loop.Clock {
        return .{ .ctx = @constCast(p), .now = clockNow, .wait = clockWait };
    }
};
