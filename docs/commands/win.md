# ztk::win

The `ztk::win::` commands reach APIs of Windows that a window needs. The commands exist on each platform. On a backend other than Windows each one gives the error code `ZTK WIN UNAVAILABLE`, so a script tests `ztk::has win` first.

## Synopsis

```tcl
ztk::win::backdrop window ?auto|none|mica|acrylic|tabbed?
ztk::win::jumplist ?task ...?
ztk::win::thumbbar window ?button ...?
```

## ztk::win::backdrop

Sets the system backdrop of a toplevel: the material that Windows 11 renders behind the window (`DWMWA_SYSTEMBACKDROP_TYPE`). With no type, the command gives the type that it set last, or `auto`. The client area of ztk is opaque, so the backdrop shows in the title bar.

```tcl
ztk::win::backdrop . mica
```

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
- `bad window path name "W"`, `"W" is not a toplevel`, `"W" has no window`.
- `bad backdrop "X": must be acrylic, auto, mica, none, or tabbed`.
- `a thumbnail has at most 7 buttons`, `bad key "K" of a button: must be command, disabled, image, or tooltip`, `image "NAME" doesn't exist`, `a task needs a title`.

[On Windows](../windows.md) is the guide for the Windows backend.
