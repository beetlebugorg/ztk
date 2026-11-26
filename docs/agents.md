# For agents

ztk is a GUI toolkit that an agent can see. A script builds a window with the Tk 8.6 commands. Then the same script, or a check script, can look at the window and drive it:

- `ztk::snapshot path` gives a PNG image of a widget.
- `ztk::tree` gives each widget with its class, its box, and its map state.
- `ztk::inject` sends pointer, wheel, key, and text events through the hit test and the focus, as a real backend does.

`ztk --headless` runs a script with no display and the CPU renderer, so the image of a window is the same on each platform.

## The files for agents

| File | What it has |
|---|---|
| [llms.txt](https://beetlebug.org/ztk/llms.txt) | The list of the docs pages. |
| [llms-full.txt](https://beetlebug.org/ztk/llms-full.txt) | The Markdown of each docs page in one file. |
| [api.json](https://beetlebug.org/ztk/api.json) | Each command, and each widget command with its options and their defaults, from the build of the site. |
| [The skill](../skills/ztk-app/SKILL.md) | The loop of an agent that builds a ztk app, the tools, a check script, and the idioms. Copy the folder `skills/ztk-app` into the skills folder of your agent. |

## A check script

This script builds a counter, clicks its button with `ztk::inject`, and prints the count. `ztk --headless check.tcl` prints `n = 1`. `tests/skill.sh` runs it on each change.

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

## What a script can do

A script in the `ztk` program has the commands of Tk and of the ztcl core. `--allow a,b` turns on more capabilities of ztcl ([Install](install.md)). In a browser, a script has no file, network, or process access. Tcl code is short, so a person can read the code of an app and see what it does.
