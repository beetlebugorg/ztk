# The Stage 1 demo. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load demo.css
}
wm title . "ztk demo"
set name ""
set count 0
set msg "Type a name, then press Enter."

label .title -text "Hello from ztk"
label .lname -text "Name:"
entry .name -textvariable name -width 24
button .greet -text "Greet" -command {set msg "Hello, $name!"}
button .count -text "Count" -command {incr count; set msg "Clicks: $count"}
button .quit -text "Quit" -command {destroy .}
label .msg -textvariable msg

grid .title -     -      -sticky w  -padx 12 -pady {12 6}
grid .lname .name -      -sticky ew -padx 12 -pady 4
grid .greet .count .quit -sticky ew -padx 12 -pady 4
grid .msg   -     -      -sticky w  -padx 12 -pady {6 12}
grid columnconfigure . 1 -weight 1

bind .name <Return> {.greet invoke}
bind . <Escape> {destroy .}
bind .title <Enter> {set msg "The pointer is on the title."}
bind .title <Leave> {set msg "The pointer left the title."}
focus .name
