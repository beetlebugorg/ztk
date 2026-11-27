# Sets full screen with wm attributes. tests/wayland-smoke.sh reads the
# state of the window from sway while the script runs.
label .l -text "full screen"
pack .l
after 200 {wm attributes . -fullscreen 1}
after 4000 exit
