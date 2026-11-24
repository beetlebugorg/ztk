# A status board: tiles with a gradient, and rows with colored badges.
# The look comes from dashboard.css. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load dashboard.css
}
wm title . "Print farm"

frame .main -padx 20 -pady 18
grid .main -sticky nsew
label .main.title -text "Print farm"
label .main.sub -text "4 printers, 5 jobs today"
grid .main.title - - -sticky w
grid .main.sub - - -sticky w -pady {0 14}

set col 0
foreach {name value caption} {
    blue   12    "Prints today"
    green  "98%" "Success rate"
    violet "3 h" "Queue time"
} {
    set t .main.$name
    frame $t -padx 16 -pady 12
    label $t.value -text $value
    label $t.caption -text $caption
    grid $t.value -sticky w
    grid $t.caption -sticky w
    grid $t -row 2 -column $col -sticky nsew -padx {0 10}
    incr col
}
grid configure .main.violet -padx 0

frame .main.jobs -padx 14 -pady 8
grid .main.jobs - - -sticky ew -pady {16 0}
set r 0
foreach {job printer state} {
    "bracket-v3.gcode"  "Bench 1" Printing
    "gear-housing.gcode" "Bench 2" Printing
    "lid-latch.gcode"   "Rack A"  Queued
    "cable-clip.gcode"  "Rack B"  Failed
    "enclosure.gcode"   "Bench 1" Done
} {
    label .main.jobs.j$r -text $job -anchor w
    label .main.jobs.p$r -text $printer -anchor w
    label .main.jobs.s$r -text $state -width 8
    grid .main.jobs.j$r .main.jobs.p$r .main.jobs.s$r -sticky ew -pady 4 -padx 6
    set badge(.main.jobs.s$r) [string tolower $state]
    incr r
}
grid columnconfigure .main.jobs 0 -weight 1
grid columnconfigure .main {0 1 2} -weight 1 -uniform t

if {[llength [info commands ::ztk::class]]} {
    foreach t {blue green violet} { ::ztk::class .main.$t add tile $t }
    ::ztk::class .main.jobs add panel
    ::ztk::class .main.sub add muted
    foreach w [array names badge] { ::ztk::class $w add badge $badge($w) }
    foreach w [winfo children .main.jobs] {
        if {[string match *.p* $w]} { ::ztk::class $w add muted }
    }
}
