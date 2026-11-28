# SPDX-License-Identifier: BSD-2-Clause
# Prints the value of each color name of src/base/tkcolors.zig, with
# `winfo rgb`, in the case of the table and in upper case. The same
# script runs in wish and in ztk, so the outputs compare. The last line
# gives the count of the names.
# Use: tools/oracle.sh tools/oracle-colors.tcl
set root [file dirname [file dirname [file normalize [info script]]]]
set f [open [file join $root src base tkcolors.zig]]
set text [read $f]
close $f
set n 0
foreach {- name} [regexp -all -inline {\.\{ "([^"]+)", \.\{} $text] {
    set v {}
    foreach c [list $name [string toupper $name]] {
        if {[catch {winfo rgb . $c} rgb]} {set rgb unknown}
        lappend v $rgb
    }
    puts "$name: [join $v { / }]"
    incr n
}
puts "names: $n"
exit
