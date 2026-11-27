# Debug a form

This page has a small sign-up form with three bugs. The form runs live in the page. Find each bug with the tools of [Debugging](debugging.md), fix the code in the editor, and see the window change.

The bar of the snippet has two tools for this page:

- **Console** opens a line under the window. A Tcl command in the line runs in the window, and the answer shows above the line. Use the up arrow for the last commands.
- **Inspect** shows the widget under the pointer. A click on a widget opens a panel with its options and the source of each value, its bindings, its geometry chain, its code, and its trace.

<!-- live -->
```tcl
ztk::debug sources on
# A sign-up form with three bugs.
set name ""
set email ""
frame .f -padx 12 -pady 8
label .f.l1 -text Name
entry .f.name -textvariable name
label .f.l2 -text Email
entry .f.email -textvariable mail
label .f.hint -text "Use your work address" -foreground #6b7180
button .f.save -text "Sign up" -command save -state disabled
label .f.status -text "Fill in both fields"
grid .f.l1 .f.name -sticky w -pady 2
grid .f.l2 .f.email -sticky w -pady 2
grid .f.save -column 1 -sticky w -pady 6
grid .f.status -columnspan 2 -sticky w
pack .f -fill both
proc check {args} {
    set ok [expr {$::name ne "" && [string match *@* $::email]}]
    .f.save configure -state [expr {$ok ? "normal" : "disabled"}]
}
trace add variable name write check
trace add variable mail write check
proc save {} {
    .f.status configure -text "Welcome, $::name"
}
# A click on the window clears the status.
bind . <ButtonRelease-1> {.f.status configure -text "Fill in both fields"}
```

The first line, `ztk::debug sources on`, starts the record of option sources. Keep it at the top, so the record has each call of the code.

## Bug 1: Sign up stays disabled

Type a name and an email address in the window. The button stays disabled. To type with the console, run these two commands:

```tcl
ztk::debug type Ada .f.name
ztk::debug type ada@example.com .f.email
```

Each answer lists the events, the bindings that ran, and the option writes. Each key gives the line `option .f.save -state: "disabled" again (line 3 of proc check)`. So `check` runs and keeps the button disabled. Ask why:

```tcl
ztk::debug explain .f.save -state
```

```
.f.save -state is "disabled": set by .f.save configure -state [expr {$ok ? "normal" : "disabled"}] at line 3 of proc check.
Before: "disabled". Writes: 19.
Stack: check ::mail {} write
A click on .f.save runs no -command while it is disabled.
```

The stack shows the words of the call of `check`: a write trace of `::mail` calls it. The proc reads `::email`. Ask where `mail` comes from:

```tcl
ztk::debug explain .f.email -textvariable
```

```
.f.email -textvariable is "mail": set by entry .f.email -textvariable mail at line 9.
Before: "". Writes: 1.
```

Line 9 of the code gives the entry the variable `mail`, so `::email` stays empty. With Inspect, the same answer is in the Options tab of `.f.save`: the source of `-state` is `configure line 3 in check`.

The fix: change `mail` to `email` on line 9 and in the `trace add variable mail write check` line. Type in the window again, and the button gets enabled.

## Bug 2: The hint does not show

The code makes the label `.f.hint`, but the window has no hint. A widget that is not mapped has no box to point at, so ask with the console:

```tcl
ztk::debug explain .f.hint
```

```
.f.hint Label, box 0,0 1x1, no manager, not mapped
  not mapped: no geometry manager (pack, grid, or place)
  -foreground "#6b7180": create at line 10
  -text "Use your work address": create at line 10
```

No geometry manager has the label. `ztk::debug geometry .f.hint` gives the same note, and `ztk::debug tree .f` gives each widget with its box and its map state.

The fix: add this line after the `grid .f.l2 .f.email` line:

```tcl
grid .f.hint -column 1 -sticky w
```

## Bug 3: Sign up shows no welcome

After the fix of bug 1, fill in the form and click Sign up. The status stays "Fill in both fields". Ask what ran for the click:

```tcl
ztk::debug click .f.save
```

The answer has the events of the click. The part for the release is:

```
#130 <ButtonRelease-1> on .f.save at 36,15
  binding Button <ButtonRelease-1>: ::ztk::priv::button up %W
  command .f.save: save
  option .f.status -text: "Fill in both fields" -> "Welcome, Ada" (line 2 of proc save)
  dirty .f.status: style measure layout
  binding . <ButtonRelease-1>: .f.status configure -text "Fill in both fields"
  option .f.status -text: "Welcome, Ada" -> "Fill in both fields" (line 1)
```

The numbers of the records depend on the events before the click. The command `save` writes the welcome. Then the binding of the tag `.` writes the old text back. The tag `.` is the toplevel, and each widget of the window has it in its bind tags:

```tcl
bindtags .f.save
```

```
.f.save Button . all
```

So the binding on `.` runs for a click on each widget, after the binding of the class. The Bindings tab of Inspect shows the same list for `.f.save`, with the script of each tag.

The fix: put the binding on the frame, so that only a click on the frame clears the status:

```tcl
bind .f <ButtonRelease-1> {.f.status configure -text "Fill in both fields"}
```

## Check each fix

A visual diff shows what an action changed. Take a mark, click, and ask for the changes:

```tcl
ztk::debug mark before
ztk::debug click .f.save
ztk::debug changes before
```

Before the fix of bug 3, the changes have no line for `.f.status`, because the text ends where it started. After the fix, the changes have this line:

```
.f.status -text: "Fill in both fields" -> "Welcome, Ada"
```

The first line of the changes gives the count of the pixels that changed and their box. `ztk::debug diff before -image` also gives a PNG of the window with the changed pixels in red.

## For an agent

An agent uses the same answers with `ztk --mcp`. Save the code as `form.tcl`, and start the server:

```sh
ztk --mcp form.tcl
```

Then each line of stdin is one JSON-RPC message. These calls find bug 3:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_type","arguments":{"path":".f.name","text":"Ada"}}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_type","arguments":{"path":".f.email","text":"ada@example.com"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_click","arguments":{"path":".f.save"}}}
```

The text of each answer is the text of the console. For a check in CI, a script runs the same commands in `ztk --headless`:

```tcl
source form.tcl
ztk::debug type Ada .f.name
ztk::debug type ada@example.com .f.email
ztk::debug click .f.save
puts [.f.status cget -text]
exit
```

With the three fixes, it prints `Welcome, Ada`. `tests/debug-form.sh` runs the code of this page with and without the fixes.
