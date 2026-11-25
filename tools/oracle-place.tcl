# SPDX-License-Identifier: BSD-2-Clause
# Makes random place layouts from a seed and prints the geometry of each
# widget. The same script runs in wish and in ztk, so the outputs compare.
# Use: oracle-place.tcl seed count
catch {ztk::style add {Frame { border-width: 0; padding: 0 }}}
set s [lindex $argv 0]
set count [lindex $argv 1]

proc rnd {n} {
    global s
    set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
    return [expr {($s >> 8) % $n}]
}

frame .c -width 300 -height 200
place .c -x 0 -y 0
for {set k 0} {$k < $count} {incr k} {
    .c configure -width [expr {20 + [rnd 300]}] -height [expr {20 + [rnd 200]}]
    frame .c.f -width [expr {1 + [rnd 40]}] -height [expr {1 + [rnd 30]}]
    set opts [list -x [expr {[rnd 80] - 20}] -y [expr {[rnd 80] - 20}] \
        -anchor [lindex {n ne e se s sw w nw center} [rnd 9]]]
    if {[rnd 2]} { lappend opts -relx [expr {[rnd 100] / 100.0}] }
    if {[rnd 2]} { lappend opts -rely [expr {[rnd 100] / 100.0}] }
    if {[rnd 3] == 0} { lappend opts -width [rnd 60] }
    if {[rnd 3] == 0} { lappend opts -height [rnd 60] }
    if {[rnd 3] == 0} { lappend opts -relwidth [expr {[rnd 100] / 100.0}] }
    if {[rnd 3] == 0} { lappend opts -relheight [expr {[rnd 100] / 100.0}] }
    place .c.f {*}$opts
    update
    puts "layout $k [winfo width .c] [winfo height .c]: [winfo ismapped .c.f] [winfo x .c.f] [winfo y .c.f] [winfo width .c.f] [winfo height .c.f]"
    destroy .c.f
}
exit
