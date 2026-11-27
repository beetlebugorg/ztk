# Drives SaVi 1.6.0 with no change to it: loads a constellation, opens
# the coverage map, runs the simulation, and writes snapshots of the
# windows. libztk sources it with ZTK_SCRIPT=shots.tcl. SHOTS is the
# folder of the images, and SAVI_FILE the constellation (a file of data/).
# SPDX-License-Identifier: BSD-2-Clause
set shots $env(SHOTS)
proc snap {w name} {
    global shots
    update
    if {![winfo exists $w]} { puts stderr "no window $w"; return }
    set f [open [file join $shots $name.png] wb]
    chan puts -nonewline $f [binary decode base64 [ztk::snapshot $w]]
    close $f
    puts stderr "shot $name [winfo width $w]x[winfo height $w]"
}
set file [expr {[info exists env(SAVI_FILE)] ? $env(SAVI_FILE) : "iridium-66.tcl"}]
after 500 [list main(load_file) [file join $env(SAVI) data $file]]
after 1500 {snap .main main}
after 2000 {coverage(build)}
after 3000 {main(forwards)}
after 6000 {snap .coverage coverage}
after 6500 {puts stderr "windows: [winfo children .]"; exit 0}
