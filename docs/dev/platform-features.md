# Platform features

This page is the plan of the milestone "Platform features" (#53): the features of the operating system beyond the core Tk API, in ztk and in ztcl. The macOS and the Windows backends build to it. The issues of the milestone have the requests, and their comments have the decisions of the user that this page follows.

## The rules

**Generic or direct.** A feature that exists in a similar form on most platforms gets one generic command. A feature of one platform, or one that loses its use in a generic form, gets a direct command in a platform namespace. On another platform a direct command gives the error `"ztk::win::jumplist" is not available on macos`, with the name of the command and of the platform.

**ztk or ztcl.** A feature that needs no window lives in ztcl, so a script without ztk can use it: generic commands in `ztcl::*`, direct ones in `ztcl::mac::*`, `ztcl::win::*`, and `ztcl::linux::*`. A feature that needs a window, a menu, or the event loop of ztk lives in ztk: `ztk::*`, `ztk::mac::*`, `ztk::win::*`, and `ztk::linux::*`. Each command of ztcl is behind a capability that the embedder grants, and the `ztk` program grants one only from a flag (AGENTS.md, rule 5).

**A test for a feature.** `ztk::has feature` and `ztcl::has feature` give 1 when the feature works in this program on this platform, and 0 otherwise. A script calls them before it uses a feature. They give 0 for a feature with no backend code, also on the platform of a direct command.

## The features

| Issue | Feature | Repository | Command | macOS | Windows | Linux | Priority |
|---|---|---|---|---|---|---|---|
| ztk#54 | Tray or status icon | ztk | `ztk::tray` | `NSStatusItem` | `Shell_NotifyIcon` | StatusNotifierItem | P1 |
| ztcl#108 | Notifications | ztcl | `ztcl::notify` | `UNUserNotificationCenter` | Toast notifications | freedesktop notifications | P1 |
| ztk#57 | File, folder, color, and font dialogs | ztk | `tk_getOpenFile` and the others | `NSOpenPanel` and the others | `IFileOpenDialog`, `IFileSaveDialog`, `ChooseColorW`, `ChooseFontW` | the desktop portal | P1 |
| ztcl#109 | Open a URL or a file with the default app | ztcl | `ztcl::open` | `NSWorkspace` | `ShellExecuteExW` | the portal or `xdg-open` | P1 |
| ztk#56 | Bundle a macOS app | ztk | `ztk bundle` | `.app` | | | P1 |
| ztk#59 | Bundle a Windows app | ztk | `ztk bundle` | | `.exe` with resources | | P2 |
| ztk#60 | Bundle a Linux app | ztk | `ztk bundle` | | | AppImage or `.desktop` | P2 |
| ztk#61 | Badge, progress, attention | ztk | `ztk::taskbar` | dock tile | `ITaskbarList3`, `FlashWindowEx` | Unity launcher API | P2 |
| ztk#62 | Drag and drop between apps | ztk | `ztk::dnd` | `NSDraggingDestination` | `IDropTarget`, `DoDragDrop` | Wayland data device | P2 |
| ztk#63 | Global shortcuts | ztk | `ztk::hotkey` | `RegisterEventHotKey` | `RegisterHotKey` | the portal | P2 |
| ztk#64 | Recent documents | ztk | `ztk::recent` | `NSDocumentController` | `SHAddToRecentDocs` | `recently-used.xbel` | P2 |
| ztk#65 | macOS only | ztk | `ztk::mac::*` | dock menu, sheets, window tabs | | | P3 |
| ztk#66 | Windows only | ztk | `ztk::win::*` | | jump lists, taskbar buttons, backdrops | | P3 |
| ztcl#110 | Linux only | ztcl | `ztcl::linux::*` | | | portals, D-Bus | P3 |
| ztcl#111 | macOS and Windows with no window | ztcl | `ztcl::mac::*`, `ztcl::win::*` | keychain, defaults, launch at login | registry, credentials, file associations | | P3 |
| ztk#68 | Window state | ztk | `wm attributes` | full screen, level | `WS_EX_TOPMOST`, full screen | xdg toplevel states | P3 |

## The platform interface

The features of ztk go through `Platform.VTable`, as the menus do: optional entries, and the core calls them on the UI thread. A backend without an entry gives 0 for the feature in `ztk::has`.

**Tray (ztk#54).**

- `trayCreate(icon: Image, template: bool, tooltip) TrayId`, `traySet(id, icon, template, tooltip, menu: MenuId)`, and `trayDrop(id)`. The icon is an RGBA image of the core. With `template`, macOS sets `template` on the `NSImage` of the status item and draws the icon in the colors of the menu bar for light, dark, and highlight. Windows and Linux ignore it. The menu is a native menu of `docs/dev/menus.md`, with `menuSet` before `traySet`.
- An event `tray` with the id and an action: `click`, `double`, or `menu`. A tray with a menu shows it in the backend: on macOS a status item with a menu opens it on each click, and Windows posts the menu at the pointer after `SetForegroundWindow` on a click of the right button, as the documentation of `TrackPopupMenu` asks. On macOS `click` and `double` come only for a tray with no menu. Windows gives them for the left button also with a menu. A script that needs the same behavior on both gives a tray either a menu or a command.
- `ztk::tray create -image photo -template bool -tooltip text -menu .m -command script` gives a name, with `configure` and `destroy`. The script gets the action in `%a`.

**Dialogs (ztk#57).**

- `fileDialog(opts) ?[][]u8`: a modal dialog with a kind (`open`, `save`, `folder`), the parent window, the title, the first folder and the first file, the filters of `-filetypes`, the default extension, and multiple selection. It returns the paths in UTF-8, or null for Cancel. The core maps the options and the result of `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory` onto it, as the manual pages give them.
  The call is synchronous on each platform. With a parent window, macOS begins a sheet and runs a modal loop until the completion handler of the sheet, so `tk_getOpenFile` keeps its result as in Tk.
- `colorDialog(parent, title, initial) ?Color` for `tk_chooseColor`. A font dialog follows when ztk has a `tk fontchooser`.
- A backend without the entry gets the dialogs that the core draws, from task 17 of the widget stage.

**Bundles (ztk#56, ztk#59, ztk#60).** `ztk bundle` writes a program with the scripts and the style sheets inside it, from any host, as ztcl#40 asks for ztcl. On Windows the bundle is one `.exe` with its resources written by ztk in Zig: the icon, a manifest with the per-monitor DPI awareness and the common controls, and the version info. The build needs no resource compiler, so a build on Linux or macOS works.

## The order

Windows: the tray, the file dialogs, `ztcl::open` and `ztcl::notify` in ztcl, then the `.exe` bundle. macOS: the order of the macOS session, with the same interface. The first PR of each feature adds its entries to `platform.zig` or its commands to ztcl, and the second backend builds to them.

## Decisions

- The capabilities of the programs (the user, 2026-11-26). The `ztk` program turns on the file commands and the file channels of ztcl by default, because a desktop program needs files. The other capabilities (`exec`, `socket`, and the rest) stay behind `--allow a,b`, with the names and the rules of the `ztcl` runner. A program that embeds ztk grants each capability in code.
- The file commands of the `ztk` and `ztcl` programs use real paths of the host by default, as `wish` and `tclsh` do, so the paths of a native dialog open as they are. `--root DIR` keeps them in one folder (the jail of `fsroot.zig`). An embedder gets the jail by default. ztcl#122 added the host mode.

## Decisions for the user

1. The name of the feature test in ztcl: `ztcl::has`, as ztcl#111 says, with the same names of features as `ztk::has`. The recommendation is one list of names for both.
2. `ztk bundle` as a subcommand of the `ztk` program, or a build step of `zig build`. The recommendation is the subcommand, so a user with a release program and no Zig can bundle.
