# Debugging

`ztk::debug` answers the question "why is this widget like this". It gives the source of each option of a widget and the geometry chain that sets its size and place. The answers are Tcl dicts, so a script, a test, or an agent can read them.

## The source of an option

`ztk::debug sources on` starts the record of option sources. Turn it on before the code that you want to check, for example on the first line of the script. While it is off, a `configure` call keeps no record, and its cost is one test of a flag.

```tcl
ztk::debug sources on
button .ok -text Save
pack .ok
proc lock {w} {
    $w configure -state disabled
}
lock .ok
puts [ztk::debug why .ok -state]
```

The output is one dict:

```
option -state value disabled source configure code {$w configure -state disabled} call {.ok configure -state disabled} file app.tcl line 2 proc lock prev normal count 1 seq 3 stack {{lock .ok}}
```

| Key | What it has |
|---|---|
| `option`, `value` | The option and the value that `cget` gives. |
| `source` | `create`, `configure`, `animate` (a step of `ztk::animate`), `internal` (the widget keeps the option equal to its state), `variable` (the `-text` of a `-textvariable`), `call` (a call set it while the record was off), `style` (`cget` reads the computed style), or `default`. |
| `code` | The source text of the command, before substitution. |
| `call` | The words of the call with their values. |
| `file`, `line` | The value of `info script`, and the line of the command in its own script. For a command in a proc, the line counts from the start of the body of the proc. |
| `proc`, `stack` | The innermost proc, and the words of each proc call, innermost first. A call at the global level has an empty stack. |
| `prev` | The value before the call. |
| `count`, `seq` | The count of recorded writes of the option, and the order of the last write among all recorded writes. |
| `default` | The default value, for the source `default`. |
| `style` | For an option that no call set: the CSS declaration that gives the look, with its sheet, its origin, and its line. |
| `overrides` | For an option that a call set: the CSS declaration that the option overrides. |
| `variable` | The name of the `-textvariable`. |

An option with a CSS property is `-background`, `-foreground`, `-borderwidth`, `-relief`, `-font`, `-padx`, `-pady`, `-padding`, `-cursor`, or `-insertbackground`. For a property that inherits, such as `color`, the declaration can be on an ancestor. Then the dict has the key `inherited` with the path of that ancestor.

`ztk::debug why .ok` with no option gives a list of these dicts: one for each option that a call set or that the style gives. Add `-all` for each option of the widget.

ztk has no option database. `option add` does not exist, so no source is `option`.

## The geometry chain

`ztk::debug geometry path` runs the pending layout, and then gives one dict for the widget and one for each container up to its toplevel.

```tcl
frame .f -width 100 -height 40
pack propagate .f 0
pack .f
button .f.ok -text "A long label"
pack .f.ok
puts [lindex [ztk::debug geometry .f.ok] 0]
```

| Key | What it has |
|---|---|
| `widget`, `class` | The path and the class. |
| `req` | The requested width and height in logical pixels. |
| `box` | The x, y, width, and height in the container. |
| `mapped` | 1 when the widget is mapped. |
| `size` | The `-width` and `-height` that a call set. |
| `manager`, `info` | The geometry manager and the result of its `info` subcommand. An empty `manager` means that no manager has the widget. |
| `propagate` | For a container: 1 when its content sets its requested size. |
| `notes` | Each difference between the requested size and the box, and the reason that a widget is not mapped. |

## Cost

A script with 200,000 calls of `.b configure -text $i -state normal` ran 1,161,719,315 instructions before `ztk::debug` existed, 1,165,918,947 with the record off (0.36 % more, 21 instructions for each call), and 2,211,793,540 with the record on. The command was `perf stat -e instructions:u -r 3 ztk --headless --allow clock bench/debug-configure.tcl` on a ReleaseFast build, on 2026-11-26, on an Intel Core i7-6700K with Linux. The difference in time with the record off was smaller than the spread between runs.

## Limits

- The line of a command in a proc counts from the body of the proc. The file of the proc and the line in that file need the debug interface of ztcl.
- The record keeps the last write of each option, not each write.
