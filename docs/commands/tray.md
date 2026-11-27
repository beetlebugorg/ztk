# ztk::tray and ztk::has

`ztk::tray` shows an icon in the tray of the system, with a tooltip, a menu, and a command. `ztk::has` tells a script if the program has a platform feature.

## Synopsis

```tcl
ztk::tray create ?-option value ...?
ztk::tray configure name ?-option value ...?
ztk::tray destroy name
ztk::tray names
ztk::has feature
```

## Tray icons

`create` makes a tray icon and gives its name, such as `tray1`. `configure` changes the options of the icon. `destroy` removes it. `names` gives the names of the icons.

| Option | Value |
|---|---|
| `-image photo` | A photo image for the icon. A later change of the photo shows at the next `configure`. |
| `-tooltip text` | The text that the system shows when the pointer stays on the icon. |
| `-menu menu` | A menu widget. The system shows it as a native menu. |
| `-command script` | Runs at an action of the user. `%a` in the script is the action: `click`, `double`, or `menu`. |
| `-template bool` | macOS: 1 shows the image as a template image, in the colors of the menu bar. |

```tcl
image create photo dot -width 16 -height 16
dot put #2c7be5 -to 2 2 14 14
menu .traymenu -tearoff 0
.traymenu add command -label Quit -command exit
set t [ztk::tray create -image dot -tooltip "Backup" -menu .traymenu \
    -command {if {"%a" eq "double"} {wm deiconify .}}]
```

The tray is on Windows (the notification area), macOS (the menu bar), and Linux on Wayland (a StatusNotifierItem on the session bus, for a panel that hosts these items). On Linux the item has no D-Bus menu yet: `-menu` has no effect there, so post the menu from `-command` when `%a` is `menu`.

## Platform features

`ztk::has feature` gives 1 when the program has the feature on this platform, and 0 when it does not.

| Feature | 1 when |
|---|---|
| `tray` | `ztk::tray create` can show an icon. |
| `taskbar` | [`ztk::taskbar`](taskbar.md) reaches the taskbar or Dock button of the app. |
| `recent` | [`ztk::recent`](taskbar.md#ztkrecent) reaches the recent documents of the system. |
| `native-menus` | Menus show as menus of the system. |
| `mac` | The [`ztk::mac::` commands](../macos.md#direct-apis-of-macos) work. |
| `win` | The [`ztk::win::` commands](win.md) work. |

## Errors

- `this platform has no tray`, or `the system has no tray`: `create` on a backend or a desktop with no tray. Test `ztk::has tray` first.
- `tray "NAME" doesn't exist`.
- `image "NAME" doesn't exist`, `"W" is not a menu`, `bad option "-X"`.
- `bad feature "NAME"`: `ztk::has` with a name that is not in the table.
