//! One input event, in one form for all backends. Positions are logical
//! pixels in the window. The modifier bits follow the X11 state field.
//! SPDX-License-Identifier: BSD-2-Clause

const geom = @import("geom.zig");
const Window = @import("platform/platform.zig").Window;

pub const Mods = packed struct(u16) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    /// Alt
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    /// The logo key.
    mod4: bool = false,
    mod5: bool = false,
    button1: bool = false,
    button2: bool = false,
    button3: bool = false,
    button4: bool = false,
    button5: bool = false,
    _pad: u3 = 0,
};

/// The kinds of the `menu` event.
pub const MenuAction = enum {
    /// The user chose the entry. The core invokes it, as `invoke` does.
    invoke,
    /// The highlighted entry changed. The core sends `<<MenuSelect>>`. The entry is -1 for none.
    select,
    /// The menu is about to open from a bar or a cascade. The core runs
    /// `-postcommand` and calls `menuSet` when the entries changed. A
    /// backend with the menu handler of the platform calls the handler and
    /// shows the new entries. A queued event can arrive after the menu showed.
    opening,
    /// The menu closed.
    closed,
};

/// The commands of the application menu of the system (macOS) that go to the script.
/// The kinds of the `tray` event.
pub const TrayAction = enum {
    /// A click of the primary button. On macOS only for a tray with no menu.
    click,
    /// A double click. On macOS only for a tray with no menu.
    double,
    /// The request for the menu: the secondary button on Windows. The
    /// backend shows the menu of a tray that has one.
    menu,
};

pub const AppCommand = enum {
    /// About: the core calls `tkAboutDialog` when the script has it.
    about,
    /// Settings: the core calls `::tk::mac::ShowPreferences` when the script has it.
    settings,
    /// Quit: the core calls `::tk::mac::Quit` when the script has it, or
    /// else closes `.` as a `close` event does.
    quit,
};

pub const Event = union(enum) {
    motion: struct { window: *Window, x: f32, y: f32, mods: Mods, time_ms: u32 },
    button: struct { window: *Window, button: u8, pressed: bool, x: f32, y: f32, mods: Mods, time_ms: u32 },
    leave: struct { window: *Window },
    scroll: struct { window: *Window, dx: f32, dy: f32, x: f32, y: f32, mods: Mods, time_ms: u32 },
    key: struct {
        window: *Window,
        keysym: u32,
        keycode: u32,
        pressed: bool,
        repeat: bool,
        /// The UTF-8 that the key gives.
        text: [8]u8 = @splat(0),
        text_len: u8 = 0,
        mods: Mods,
        time_ms: u32,
    },
    focus: struct { window: *Window, focused: bool },
    resize: struct { window: *Window, size: geom.Size },
    scale: struct { window: *Window, scale: f32 },
    close: struct { window: *Window },
    frame: struct { window: *Window, time_us: i64 },
    /// The composition text of an input method, in UTF-8, and the caret
    /// in it as a byte offset. An empty text ends the composition. The
    /// text belongs to the backend until the next `poll`.
    preedit: struct { window: *Window, text: []const u8, caret: u32 },
    /// The text that an input method gives to the widget, in UTF-8. The
    /// text belongs to the backend until the next `poll`.
    commit: struct { window: *Window, text: []const u8 },
    /// The dark mode or the accent color of the system changed. The core
    /// reads them again with `Platform.appearance`.
    appearance: struct { window: *Window },
    /// An action of the user in a native menu. `window` is the window of
    /// the menu bar or of the post. `entry` is an index into the entries of
    /// the last `menuSet` of the menu, or -1.
    menu: struct { window: *Window, menu: u32, entry: i32, action: MenuAction },
    /// An action of the user on a tray icon. `window` is the window of `trayCreate`.
    tray: struct { window: *Window, id: u32, action: TrayAction },
    /// A global shortcut of `hotkeyAdd`. It can come when the app has no focus.
    hotkey: struct { window: ?*Window = null, id: u32 },
    /// A command of the application menu. It can come with no window open.
    app_command: struct { window: ?*Window = null, command: AppCommand },

    /// The window of the event, or null for an `app_command` with no
    /// window. The pointer is never dereferenced by the caller when the
    /// window may be gone.
    pub fn window(e: Event) ?*Window {
        return switch (e) {
            inline else => |v| v.window,
        };
    }
};
