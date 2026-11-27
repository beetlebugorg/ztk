# ztk::dnd and tkdnd::drop_target

A widget takes drops of files and text from other apps with `tkdnd::drop_target`, the names of the `tkdnd` package of Tk. `ztk::dnd drag` drags files or text out of a window to other apps.

## Synopsis

```tcl
tkdnd::drop_target register window ?types?
tkdnd::drop_target unregister window
ztk::dnd drag window ?-files list? ?-text string? ?-move bool?
```

## Drops on a widget

`register` puts `window` on the list of drop targets. `types` is a list of `DND_Files`, `DND_Text`, or `*` (both). The default is `*`. `unregister` takes the widget off the list.

The window of a toplevel accepts the union of the types of its targets. A drop goes to the widget under the pointer, or to the nearest parent on the list that accepts the type. The widget gets these virtual events:

| Event | When |
|---|---|
| `<<DropEnter>>` | The drag comes over the target. |
| `<<DropPosition>>` | The drag moves over the target. |
| `<<DropLeave>>` | The drag goes off the target, or the user cancels it. |
| `<<Drop:DND_Files>>` or `<<Drop:DND_Text>>` | The user drops data of that type. |
| `<<Drop>>` | After the typed event of the drop. |

In a binding, `%D` and `%d` give the data of the drop. The name of the typed event gives the type. The data of files is a list of full host paths, with `/` between the parts on each platform. The data of text is the text.

```tcl
label .drop -text "Drop files here" -width 30 -height 6 -relief groove
pack .drop -padx 20 -pady 20
tkdnd::drop_target register .drop DND_Files
bind .drop <<Drop>> {.drop configure -text "[llength %D] files"}
```

## Drags out of a window

`ztk::dnd drag` starts a drag from a binding of `<B1-Motion>`. It runs in the modal loop of the system until the user drops or cancels. It gives the action of the target: `copy`, `move`, or `none`.

| Option | Value | Default |
|---|---|---|
| `-files list` | Full host paths of files to drag. | none |
| `-text string` | Text to drag. | none |
| `-move bool` | 1 offers a move to the target as well as a copy. | 0 |

```tcl
bind .file <B1-Motion> {
    if {[ztk::dnd drag .file -files [list $path] -move 1] eq "move"} { file delete $path }
}
```

## Platforms

| Platform | Drops | Drags |
|---|---|---|
| Windows | OLE drop targets | OLE drag source |
| macOS | File URLs and plain text of the view | `NSDraggingSession`, with the icon of each file |
| Linux, Wayland | The data device of the compositor | The data device of the compositor |
| Linux, X11 and the web | No | No |

## Errors

- `bad window path name "W"`: no widget has the name.
- `bad type "T"`: a type other than `DND_Files`, `DND_Text`, or `*`.
- `ZTK DND UNAVAILABLE` (the `errorCode`): `ztk::dnd drag` on a backend with no drags.

The guides [On Windows](../windows.md) and [On macOS](../macos.md#drops-from-other-apps) give the details of each system.
