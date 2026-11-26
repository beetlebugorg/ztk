---
name: ztk-app
description: Build, check, and drive a GUI app in ztk (Tk 8.6 commands in Zig, on the ztcl interpreter). Use when the task is a desktop or web GUI in Tcl/Tk with ztk, or when a ztk window must be seen, inspected, or clicked from a script.
---

# Build a ztk app

ztk runs Tk 8.6 scripts. A window is a tree of widgets, and `pack`, `grid`, and `place` put them in place. CSS gives the look. The docs are at https://beetlebug.org/ztk/, the page list for agents is https://beetlebug.org/ztk/llms.txt, and the commands and the options with their defaults are in https://beetlebug.org/ztk/api.json.

## The loop

1. Write the app as one script, `app.tcl`. Use only the commands in `api.json`. Put no `exit` in the app.
2. Run it with no display: `ztk --headless --exit-after-frames 2 --screenshot shot.png app.tcl`. Look at `shot.png`. A script error goes to stderr and the exit status is not 0.
3. Check the layout with `ztk::tree`, and drive the app with `ztk::inject`, in a check script that has the app and the checks, and ends with `exit`.
4. Change the app and run the loop again.

`ztk --headless` uses the CPU renderer, so a shot is the same on each platform.

## The tools of ztk

| Command | What it gives |
|---|---|
| `ztk::tree ?path?` | One list for each widget below the path (default `.`), depth first: the path, the class, x and y in the toplevel, the width, the height, and 1 when the widget is mapped. Logical pixels. |
| `ztk::snapshot path` | A PNG image of the widget as base64 text, after the pending frames. |
| `ztk::inject top motion x y` | A pointer motion, with the hit test and the hover state of a real event. |
| `ztk::inject top press button x y`, `release button x y` | A button press or release. Send a motion first, then a press and a release, to click. |
| `ztk::inject top key keysym ?press\|release?` | A key. With no third word, a press and a release. |
| `ztk::inject top text string` | Typed text, as an input method gives it. |
| `ztk::inject top wheel x y delta` | A wheel step. 120 is one step up. |

`event generate` sends one event to one widget and does not update the hover state, so a generated click does not invoke a button. Use `ztk::inject` to click.

## A check script

```tcl
set n 0
button .go -text Count -command {incr ::n}
label .count -textvariable n
pack .go .count -padx 12 -pady 8

update
foreach row [ztk::tree .] {
    lassign $row path class x y w h mapped
    if {$path eq ".go"} {
        set cx [expr {$x + $w / 2}]
        set cy [expr {$y + $h / 2}]
    }
}
ztk::inject . motion $cx $cy
ztk::inject . press 1 $cx $cy
ztk::inject . release 1 $cx $cy
update
puts "n = $n"
exit
```

`ztk --headless check.tcl` prints `n = 1`.

## Idioms

- Give each widget a short path that says what it is: `.toolbar.save`, `.form.name`.
- Use `-textvariable` and `-variable`, so the state is in variables that a check can read.
- Use `grid` for forms, `pack` for bars and stacks, and `place` for overlays.
- Use the `ttk::` widgets for a themed look. `ttk::style configure` and `ttk::style map` change it. `ztk::class path add switch` gives a check button the switch look.
- Keep the code short. A person reads it to check what the app can do.

## What a script can do

The `ztk` program gives a script no host access beyond the commands of Tk and of the ztcl core. `--allow a,b` turns on more capabilities of ztcl, for example `clock` or `socket`. Ask the person before you add a capability. In a browser, a script has no file, network, or process access.
