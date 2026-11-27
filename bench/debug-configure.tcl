# SPDX-License-Identifier: BSD-2-Clause
# The cost of the record of option sources: 200,000 configure calls.
# Use: perf stat -e instructions:u ztk --headless --allow clock bench/debug-configure.tcl ?on?
if {[llength $argv] && [lindex $argv 0] eq "on"} {ztk::debug sources on}
button .b -text x
set us [lindex [time {
for {set i 0} {$i < 200000} {incr i} { .b configure -text $i -state normal }
}] 0]
puts [expr {$us / 200000.0}]
exit
