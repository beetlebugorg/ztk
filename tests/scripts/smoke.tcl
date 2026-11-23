# One label, one button, and one entry in a grid. The label changes every
# 20 ms, so the window draws a new frame each time.
label .l -text "ztk smoke"
button .b -text Quit -command {destroy .}
entry .e
grid .l -padx 8 -pady 8
grid .b -padx 8 -pady 4
grid .e -padx 8 -pady 8
focus .e
set n 0
proc tick {} {
    global n
    incr n
    .l configure -text "frame $n"
    after 20 tick
}
after 20 tick
