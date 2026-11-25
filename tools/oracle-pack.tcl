# SPDX-License-Identifier: BSD-2-Clause
# Makes random pack layouts from a seed and prints the geometry of each
# widget. The same script runs in wish and in ztk, so the outputs compare.
# Use: oracle-pack.tcl seed count ?v?
catch {ztk::style add {Frame { border-width: 0; padding: 0 }}}
set s [lindex $argv 0]
set count [lindex $argv 1]
set verbose [string match *v* [lindex $argv 2]]

proc rnd {n} {
    global s
    set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
    return [expr {($s >> 8) % $n}]
}

proc pad {} {
    if {[rnd 3] == 0} { return [list [rnd 6] [rnd 6]] }
    return [rnd 5]
}

for {set k 0} {$k < $count} {incr k} {
    set prop [rnd 2]
    frame .c -width [expr {20 + [rnd 200]}] -height [expr {20 + [rnd 150]}]
    if {$verbose} { puts "frame .c -width [.c cget -width] -height [.c cget -height]; pack propagate .c $prop" }
    pack propagate .c $prop
    set n [expr {1 + [rnd 7]}]
    for {set i 0} {$i < $n} {incr i} {
        frame .c.f$i -width [expr {1 + [rnd 40]}] -height [expr {1 + [rnd 30]}]
        set opts [list -side [lindex {top bottom left right} [rnd 4]] \
            -fill [lindex {none x y both} [rnd 4]] -expand [rnd 2] \
            -anchor [lindex {n ne e se s sw w nw center} [rnd 9]] \
            -padx [pad] -pady [pad] -ipadx [rnd 4] -ipady [rnd 4]]
        if {$verbose} { puts "frame .c.f$i -width [.c.f$i cget -width] -height [.c.f$i cget -height]; pack .c.f$i $opts" }
        pack .c.f$i {*}$opts
    }
    place .c -x 0 -y 0
    update
    puts "layout $k prop $prop req [winfo reqwidth .c] [winfo reqheight .c] size [winfo width .c] [winfo height .c]"
    for {set i 0} {$i < $n} {incr i} {
        puts "  f$i [winfo ismapped .c.f$i] [winfo x .c.f$i] [winfo y .c.f$i] [winfo width .c.f$i] [winfo height .c.f$i]"
    }
    destroy .c
}
exit
