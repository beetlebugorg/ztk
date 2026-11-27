# Opens a window, waits for its first frames, and writes a snapshot of it
# to the file of the first argument. The window stays open for the number
# of milliseconds of the second argument (default 0), for a screen
# capture. The exit status is 0 when the window is viewable. tests/cross-window.sh and the CI runs of cross builds use it.
# SPDX-License-Identifier: BSD-2-Clause
wm title . "ztk window test"
label .l -text "A window from a cross build" -padx 20 -pady 20
button .b -text OK
pack .l .b
update
after 1500
update
set ok [winfo viewable .]
set f [open [lindex $argv 0] w]
fconfigure $f -translation binary
puts -nonewline $f [binary decode base64 [ztk::snapshot .]]
close $f
puts "viewable $ok"
flush stdout
set hold [expr {[llength $argv] > 1 ? [lindex $argv 1] : 0}]
after $hold
exit [expr {$ok ? 0 : 1}]
