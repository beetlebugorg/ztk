# Debugging

`ztk::debug` answers the question "why is this widget like this". It gives the source of each option of a widget and the geometry chain that sets its size and place. Its trace records what ran for each event, and its visual diffs show what an action changed. [Debug a form](debug-a-form.md) has a live form with three bugs to find with these tools. The answers are Tcl dicts, so a script, a test, or an agent can read them.

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

## Traces

`ztk::debug trace start` records what happens in the app: each event, the bindings that it runs, the `-command` of a button, each option write, each geometry pass, each widget that gets dirty, each frame, and each change of the focus and the grab. `ztk::debug trace records` gives the records as dicts, oldest first.

```tcl
button .save -text Save -command {.status configure -text Saved}
label .status -text Ready
pack .save .status
update
ztk::debug trace start
.save invoke
update
foreach r [ztk::debug trace records -kind {command option frame}] {
    puts $r
}
```

Each record starts with the same keys:

| Key | What it has |
|---|---|
| `seq` | The number of the record. Option sources use the same numbers. |
| `kind` | The kind of the record. |
| `widget` | The widget of the record. |
| `cause` | The number of the event whose bindings ran when the record was made, or 0. |
| `us` | The time of the clock of the app, in microseconds. |

The other keys depend on the kind:

| Kind | Keys |
|---|---|
| `event` | `event` (for example `<ButtonRelease-1>`), `x`, `y`, `text`. |
| `motion` | The same keys, for `<Motion>`, `<Enter>`, and `<Leave>`. This kind is off unless `-kinds` names it. |
| `binding` | `tag`, `pattern`, `script`. |
| `command` | `script`, `ran` (0 when the command did not run), `why` (for example `the widget is disabled`). |
| `option` | `option`, `value`, `prev`, `source`, `code`, `line`, `proc`, as in `ztk::debug why`. |
| `dirty` | `flags` (the new flags of `style`, `measure`, `layout`, and `paint`), `by` (the number of the option record that made the widget dirty, or 0). |
| `geometry` | `manager`, `req`, `box`, `changed` (each content widget whose box changed: the path, the old box, and the new box). |
| `frame` | `frame` (the count of frames), `us` (the time of the frame), `dirty` (the widgets that got dirty since the last frame of the toplevel). |
| `focus` | `from`, `to`. |
| `grab` | `action` (`set` or `release`), `global`. |

The subcommands:

| Command | What it does |
|---|---|
| `ztk::debug trace start ?-kinds list? ?-size n?` | Starts the trace. `-kinds` is a list of kinds, or `all`. The default is each kind except `motion`. `-size` is the count of records that the ring keeps (default 10,000). A new record replaces the oldest one. |
| `ztk::debug trace stop` | Stops the trace and keeps the records. |
| `ztk::debug trace clear` | Removes the records. |
| `ztk::debug trace status` | Gives `on`, `kinds`, `count`, `size`, and `dropped` (the count of records that the ring replaced). |
| `ztk::debug trace records ?filter ...?` | Gives the records that pass each filter. |

The filters of `records`:

| Filter | What it keeps |
|---|---|
| `-kind list` | The records of these kinds. |
| `-widget pattern` | The records of the widgets that match the pattern, with `*` and `?`. |
| `-match pattern` | The records whose fields match the pattern, for example `*ButtonRelease*`. |
| `-cause n` | The event `n` and each record that its bindings made: the answer to "what ran when I clicked". |
| `-since n` | The records after the number `n`. |
| `-last n` | The last `n` records that pass the other filters. |

This script answers "what ran when I clicked Save":

```tcl
set click [lindex [ztk::debug trace records -kind event -widget .save -match *ButtonRelease* -last 1] 0]
foreach r [ztk::debug trace records -cause [dict get $click seq]] {
    puts "[dict get $r kind] [dict get $r widget]"
}
```

While the trace is off, each hook tests one mask and makes no record.

## Visual diffs

`ztk::debug mark name ?path?` keeps the image of the toplevel of `path` (default `.`) and the state of each widget in it: the class, the box, the map state, and the text of each option. `ztk::debug diff name` makes the same capture again and gives what changed.

```tcl
label .msg -text Ready
button .go -text Go -command {.msg configure -text Done -foreground red}
pack .msg .go
update
ztk::debug mark before
.go invoke
update
puts [ztk::debug diff before]
```

| Key | What it has |
|---|---|
| `pixels` | The count of device pixels that changed. |
| `box` | The bounding box of the changed pixels in logical pixels: x, y, width, height. |
| `size` | The old and the new size of the image, when it changed. |
| `added`, `removed` | The widgets that are new, and the widgets that are gone. |
| `moved` | Each widget whose box changed: the path, the old box, and the new box. |
| `mapped` | Each widget whose map state changed: the path, the old state, and the new state. |
| `options` | Each option whose text changed: the path, the option, the old text, and the new text. |
| `image` | With `-image`: a PNG of the new image as base64 text. A changed pixel is red, and each other pixel is a pale copy. |

The answer has only the keys with a change. The answer `pixels 0` with no other key means that the image and the widgets are the same. `-tolerance n` counts a pixel only when a channel changed by more than `n` (default 0). `ztk::debug marks` gives the names of the marks, and `ztk::debug forget name` removes one.

## Short answers

These subcommands give lines of text for a person or an agent. Each answer has at most 24 lines, and a longer answer ends with a line that gives the count of the lines that it left out.

| Command | The question that it answers |
|---|---|
| `ztk::debug explain path ?option?` | "Why is `.f.ok` disabled?" With an option: the value, the call that set it with its line and stack, the value before, and the style. With no option: the box, the geometry notes, and each option that a call set. |
| `ztk::debug click path ?button?` | "What ran when I clicked Save?" It clicks the center of the widget through the hit test and gives each event with its bindings, commands, option changes, and dirty widgets, then the geometry passes and the frames. |
| `ztk::debug type text ?path?` | The same for text: into the widget with the focus, or into `path` after a click on it. |
| `ztk::debug ran ?seq?` | What ran for the last event that ran a binding, or for the event with the number `seq`. It needs the trace. |
| `ztk::debug changes name` | "Diff the UI before and after": the answer of `ztk::debug diff` as lines. |
| `ztk::debug tree ?path?` | One line for each widget: the path, the class, the box, and the map state. |

`click` and `type` start the trace when it is off, and stop it again after. For example, `ztk --headless app.tcl` with this `app.tcl`:

```tcl
ztk::debug sources on
button .save -text Save -command save
label .status -text Ready
pack .save .status
proc save {} { .status configure -text Saved; lock .save }
proc lock {w} { $w configure -state disabled }
puts [ztk::debug click .save]
puts [ztk::debug explain .save -state]
```

The second answer is:

```
.save -state is "disabled": set by $w configure -state disabled at line 1 of proc lock in app.tcl.
Before: "normal". Writes: 1.
Stack: lock .save < save
A click on .save runs no -command while it is disabled.
```

## MCP tools

`ztk --mcp app.tcl` runs the script on the headless backend and then serves the Model Context Protocol on stdin and stdout: one JSON-RPC message on each line. The output of the script goes to stderr. The app runs only inside the calls of the tools, so two runs with the same calls give the same answers. The trace is on from the start.

| Tool | Arguments | What it gives |
|---|---|---|
| `ui_tree` | `path` | The answer of `ztk::debug tree`. |
| `ui_explain` | `path`, `option` | The answer of `ztk::debug explain`. |
| `ui_geometry` | `path` | The geometry chain, one line for each level. |
| `ui_click` | `path`, `button` | The answer of `ztk::debug click`. |
| `ui_type` | `text`, `path` | The answer of `ztk::debug type`. |
| `ui_ran` | `seq` | The answer of `ztk::debug ran`. |
| `ui_trace` | `kind`, `widget`, `last` | The trace records, one line each (default: the last 20). |
| `ui_mark` | `name` | Takes a mark for `ui_diff`. |
| `ui_diff` | `name`, `image` | The answer of `ztk::debug changes`. With `image`, also the PNG with the changed pixels in red. |
| `ui_snapshot` | `path` | A PNG image of the widget. |
| `tcl_eval` | `script` | The result of the script at the global level, after an `update`. |

An MCP client that starts a server from a command line gets the command `ztk` and the arguments `--mcp /path/to/app.tcl`.

## Cost

A script with 200,000 calls of `.b configure -text $i -state normal` ran 1,161,719,315 instructions before `ztk::debug` existed, 1,165,918,947 with the record off (0.36 % more, 21 instructions for each call), and 2,211,793,540 with the record on. The command was `perf stat -e instructions:u -r 3 ztk --headless --allow clock bench/debug-configure.tcl` on a ReleaseFast build, on 2026-11-26, on an Intel Core i7-6700K with Linux. The difference in time with the record off was smaller than the spread between runs.

## Limits

- The line of a command in a proc counts from the body of the proc. The file of the proc and the line in that file need the debug interface of ztcl.
- The record keeps only the last write of each option. The trace has each write.
