# SPDX-License-Identifier: BSD-2-Clause
# Makes random grid layouts from a seed and prints the geometry of each
# widget. The same script runs in wish and in ztk, so the outputs compare.
# Use: oracle-grid.tcl seed count
# ztk has no border and no padding on a frame in this oracle; wish has none by default.
catch {ztk::style add {Frame { border-width: 0; padding: 0 }}}
set s [lindex $argv 0]
set count [lindex $argv 1]
set mode [lindex $argv 2]
set verbose [string match *v* $mode]
set spans [expr {![string match *nospan* $mode]}]

proc rnd {n} {
    global s
    set s [expr {($s * 1103515245 + 12345) & 0x7fffffff}]
    return [expr {($s >> 8) % $n}]
}

proc sticky {} {
    set r ""
    foreach {bit ch} {1 n 2 e 4 s 8 w} {
        if {[rnd 2]} { append r $ch }
    }
    return $r
}

proc pad {} {
    if {[rnd 3] == 0} { return [list [rnd 6] [rnd 6]] }
    return [rnd 5]
}

for {set k 0} {$k < $count} {incr k} {
    set prop [rnd 2]
    frame .c -width [expr {20 + [rnd 200]}] -height [expr {20 + [rnd 150]}]
    if {$verbose} { puts "frame .c -width [.c cget -width] -height [.c cget -height]; grid propagate .c $prop" }
    grid propagate .c $prop
    set n [expr {2 + [rnd 7]}]
    for {set i 0} {$i < $n} {incr i} {
        frame .c.f$i -width [expr {1 + [rnd 40]}] -height [expr {1 + [rnd 30]}]
        set opts [list -row [rnd 4] -column [rnd 4] -sticky [sticky] \
            -padx [pad] -pady [pad] -ipadx [rnd 4] -ipady [rnd 4]]
        if {[rnd 4] == 0 && $spans} { lappend opts -columnspan [expr {1 + [rnd 3]}] }
        if {[rnd 4] == 0 && $spans} { lappend opts -rowspan [expr {1 + [rnd 3]}] }
        if {$verbose} { puts "frame .c.f$i -width [.c.f$i cget -width] -height [.c.f$i cget -height]; grid .c.f$i $opts" }
        grid .c.f$i {*}$opts
    }
    foreach kind {columnconfigure rowconfigure} {
        for {set j 0} {$j < 4} {incr j} {
            set o {}
            if {[rnd 2]} { lappend o -weight [rnd 4] }
            if {[rnd 3] == 0} { lappend o -minsize [rnd 40] }
            if {[rnd 4] == 0} { lappend o -pad [rnd 6] }
            if {[rnd 4] == 0} { lappend o -uniform [lindex {a b} [rnd 2]] }
            if {[llength $o]} {
                if {$verbose} { puts "grid $kind .c $j $o" }
                grid $kind .c $j {*}$o
            }
        }
    }
    if {[rnd 3] == 0} { grid anchor .c [lindex {n ne e se s sw w nw center} [rnd 9]] }
    grid .c -row 0 -column 0
    update
    puts "layout $k prop $prop size [grid size .c] req [winfo reqwidth .c] [winfo reqheight .c] bbox [grid bbox .c]"
    for {set i 0} {$i < $n} {incr i} {
        puts "  f$i [winfo x .c.f$i] [winfo y .c.f$i] [winfo width .c.f$i] [winfo height .c.f$i]"
    }
    destroy .c
}
exit
