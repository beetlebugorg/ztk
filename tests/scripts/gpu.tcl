# A window that does not change after its first frames: text, a border,
# a color, and an entry. tests/wayland-gpu.sh makes a shot of it with each
# renderer and compares the two shots.
label .l -text "ztk on the GPU" -font {Inter 18}
frame .f -background "#3366cc" -width 120 -height 40 -relief raised -borderwidth 3
button .b -text "A button"
entry .e
.e insert 0 "Some text"
grid .l -padx 8 -pady 8
grid .f -padx 8 -pady 4
grid .b -padx 8 -pady 4
grid .e -padx 8 -pady 8
