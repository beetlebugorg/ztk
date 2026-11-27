# The two windows of tests/wayland-drag.sh. "source": the first drag of
# the button moves a file, the second one text, and the third one text
# that the window drops on itself. A line on stdout gives the answer of
# each drag. "target": a line on stdout for each drop. The script ends
# after 30 seconds.
# SPDX-License-Identifier: BSD-2-Clause
set mode [lindex $argv 0]
frame .f -width 400 -height 300 -background gray80
pack .f -fill both -expand 1
tkdnd::drop_target register .f {DND_Files DND_Text}
bind .f <<Drop:DND_Files>> {puts [list files %D]; flush stdout}
bind .f <<Drop:DND_Text>> {puts [list text %D]; flush stdout}
if {$mode eq "source"} {
    set n 0
    set busy 0
    bind .f <B1-Motion> {
        if {!$busy} {
            set busy 1
            incr n
            switch $n {
                1 {set r [ztk::dnd drag .f -files [list "/tmp/ztk drag/a b.txt"] -move 1]}
                2 {set r [ztk::dnd drag .f -text "drag text é"]}
                default {set r [ztk::dnd drag .f -text "own text"]}
            }
            puts "drag $n $r"
            flush stdout
        }
    }
    bind .f <ButtonPress-1> {set busy 0}
}
puts ready
flush stdout
after 30000 exit
