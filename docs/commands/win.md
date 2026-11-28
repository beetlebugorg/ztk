# ztk::win

The `ztk::win::` commands reach APIs of Windows that a window needs. The commands exist on each platform. On a backend other than Windows each one gives the error code `ZTK WIN UNAVAILABLE`, so a script tests `ztk::has win` first.

## Synopsis

```tcl
ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?
ztk::win::fileassoc add extension ?-name text? ?-args text? ?-icon file? ?-iconindex n?
ztk::win::fileassoc remove extension
ztk::win::jumplist ?task ...?
ztk::win::thumbbar window ?button ...?
```

## ztk::win::backdrop

Sets the system backdrop of a toplevel: the material that Windows 11 renders behind the window (`DWMWA_SYSTEMBACKDROP_TYPE`). With no type, the command gives the type that it set last, or `auto`. The client area of ztk is opaque, so the backdrop shows in the title bar.

```tcl
ztk::win::backdrop . mica
```

## ztk::win::fileassoc

Makes this program a handler of a file extension for the user, so the shell can open such a file with it. `add` puts the program in the "Open with" list of the extension: the shell starts the program with the path of the file as its last argument, after the words of `-args`. It does not replace the default program that the user chose. `-name` is the name of the file type (the default is `EXT file`), and `-icon` with `-iconindex` is the icon of such a file (the default is the first icon of the program). `remove` takes the handler back.

```tcl
ztk::win::fileassoc add .note -name "Note file" -args --open
ztk::win::fileassoc remove .note
```

The command writes the registry of the user (`HKEY_CURRENT_USER\Software\Classes`), with no rights of an administrator. The keys name the path of the program, so call `add` again after the program moves. The values stay after the program ends, until `remove`.

## ztk::win::jumplist

Sets the tasks of the jump list of the app: the items under "Tasks" in the menu of its taskbar button. Each task is a dict with the keys `title` and `args`, and optionally `description`, `icon`, and `iconindex`. A task starts this program again with `args`. With no task, the command removes the list of the app.

```tcl
ztk::win::jumplist {title "New window" args --new} {title "Open recent" args --recent}
```

[`ztk::recent`](taskbar.md#ztkrecent) adds files to the "Recent" part of the same jump list.

## ztk::win::thumbbar

Sets the buttons under the thumbnail of the taskbar button of a toplevel, at most 7. Each button is a dict with the keys `image` (a photo), `tooltip`, `command`, and `disabled`. A click runs `command` at the global level.

```tcl
ztk::win::thumbbar . [list image play tooltip Play command {player toggle}]
```

## Errors

- `ZTK WIN UNAVAILABLE` (the `errorCode`), with the message `NAME is only on Windows`.
- `ZTK WIN BACKDROP`: the version of Windows has no system backdrop.
- `ZTK WIN FILEASSOC`: the registry refused a value of the file association.
- `unknown subcommand "X": must be add or remove`, `bad extension "X": must be a dot and then letters, digits, "+", "-", or "_"`, `bad option "X": must be -args, -icon, -iconindex, or -name`.
- `bad window path name "W"`, `"W" is not a toplevel`, `"W" has no window`.
- `bad backdrop "X": must be acrylic, auto, mica, none, or tabbed`.
- `a thumbnail has at most 7 buttons`, `bad key "K" of a button: must be command, disabled, image, or tooltip`, `image "NAME" doesn't exist`, `a task needs a title`.

[On Windows](../windows.md) is the guide for the Windows backend.
