# ztk::taskbar, ztk::recent, and ztk::hotkey

These commands reach the shell of the desktop: the taskbar or Dock button of the app, the recent documents of the system, and global shortcuts.

## Synopsis

```tcl
ztk::taskbar progress ?none|indeterminate|VALUE ?-state normal|paused|error??
ztk::taskbar badge ?COUNT?
ztk::taskbar attention ?-critical?
ztk::recent add PATH
ztk::recent clear
ztk::hotkey add SEQUENCE SCRIPT
ztk::hotkey remove NAME
ztk::hotkey names
```

## ztk::taskbar

The command changes the taskbar button (Windows) or the Dock icon (macOS) of the window `.`.

- `progress VALUE` shows a progress bar. `VALUE` is a number from 0 to 1. `-state paused` and `-state error` show the bar in the colors of the system for a paused or a failed job. `indeterminate` shows a progress with no value, and `none` removes the bar. With no argument, `progress` gives the current value.
- `badge COUNT` shows the count on the button. 0 removes the badge. With no argument, `badge` gives the current count.
- `attention` asks the user to look at the app: the button flashes 3 times on Windows, and macOS makes an informational request on the Dock icon. With `-critical`, the button flashes until the app comes to the front, and macOS makes a critical request. macOS makes no request while the app is active.

```tcl
for {set i 0} {$i <= 10} {incr i} {
    ztk::taskbar progress [expr {$i / 10.0}]
    after 200; update
}
ztk::taskbar progress none
ztk::taskbar badge 3
```

## ztk::recent

`add` puts a file in the recent documents of the system and in the jump list of the app. `clear` empties the list of the app. The system keeps the list, so the command keeps no state.

`add` needs the file commands in host mode, with the real paths of the host. A path in the jail of `--root` is an error, because the system needs a real path.

## ztk::hotkey

`add` registers a global shortcut and gives its name, such as `hotkey1`. The script runs at the global level when the keys go down, also when another app has the focus. `remove` removes a shortcut, and `names` gives the names.

A sequence is the modifiers and one key symbol, joined with `-`, with or without the angle brackets of `bind`: `<Control-Alt-k>` or `Control-Alt-k`. The modifiers are `Control`, `Alt`, `Shift`, and `Super` (also `Command` and `Win`). An upper case letter adds Shift.

A global shortcut reads keys of the whole desktop, so it needs a grant: `Options.hotkeys` of the embedder, or `ztk --allow hotkey`.

```tcl
ztk::hotkey add <Control-Alt-k> {wm deiconify .; raise .}
```

## Platforms

| Command | Windows | macOS | Linux | Web |
|---|---|---|---|---|
| `ztk::taskbar` | Yes | Yes (the Dock icon) | No | No |
| `ztk::recent` | Yes | No | No | No |
| `ztk::hotkey` | Yes (`RegisterHotKey`) | No | No | No |

`ztk::has taskbar` and `ztk::has recent` give 1 where the command works ([ztk::has](tray.md#platform-features)).

## Errors

- `expected a number from 0 to 1, none, or indeterminate but got "X"`, `bad state "X"`, `-state needs a value from 0 to 1`.
- `this platform has no list of recent documents`.
- `ztk::recent add needs the file commands with the real paths of the host`.
- `global shortcuts need a grant of the embedder (ztk --allow hotkey)`.
- `this platform has no global shortcuts`.
- `bad shortcut "X"`, `shortcut "NAME" doesn't exist`.
- `the system refused the shortcut "X": another app may have it`.
