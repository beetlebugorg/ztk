# A menu and its cascade in popup surfaces, near the right edge of the
# output, so the compositor slides the menu and flips the cascade. The
# label changes every 20 ms, so the window draws a new frame each time.
menu .m -tearoff 0
.m add command -label Open -accelerator Ctrl+O
.m add cascade -label More -menu .m.c
menu .m.c -tearoff 0
.m.c add command -label Deep
label .l -text "popup smoke"
pack .l -padx 8 -pady 8
update
.m post [expr {[winfo width .] - 20}] 40
.m postcascade 1
set n 0
proc tick {} {
    global n
    incr n
    .l configure -text "frame $n"
    after 20 tick
}
after 20 tick
