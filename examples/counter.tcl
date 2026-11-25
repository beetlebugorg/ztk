# The window of the quick start: a counter with a ttk button, a switch,
# and a stylesheet.
ztk::style load counter.css
wm title . "Counter"
set count 0
set fast 0
ttk::label .value -textvariable count
ttk::button .add -text "Add one" -style Accent.TButton -command {incr count [expr {$fast ? 10 : 1}]}
ttk::checkbutton .fast -text "Count by ten" -style Switch.TCheckbutton -variable fast
pack .value .add .fast -padx 16 -pady 6
bind . <Key-space> {.add invoke}
