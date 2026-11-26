set name Ada
set level 60
set wifi 1
label .title -text "Hello from ztk"
entry .name -textvariable name -width 18
button .greet -text "Greet" -command {set msg "Hello, $name!"}
set msg "Type a name, then press Return"
label .msg -textvariable msg
ttk::scale .level -from 0 -to 100 -variable level
ttk::progressbar .meter -variable level
ttk::checkbutton .wifi -text "Wi-Fi" -style Switch.TCheckbutton -variable wifi
grid .title - -sticky w -padx 12 -pady 6
grid .name .greet -sticky ew -padx 12 -pady 4
grid .msg - -sticky w -padx 12
grid .level .meter -sticky ew -padx 12 -pady 8
grid .wifi - -sticky w -padx 12
grid columnconfigure . 0 -weight 1
bind .name <Return> {.greet invoke}
