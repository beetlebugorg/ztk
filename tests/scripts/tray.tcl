# The tray test of tests/tray-linux.sh: one tray icon, and a line on
# stdout for each action. A change of the tooltip comes after 300 ms.
# The script ends after 4 seconds.
# SPDX-License-Identifier: BSD-2-Clause
image create photo dot -width 4 -height 4
dot put red -to 0 0 4 4
set t [ztk::tray create -image dot -tooltip "first tip" -command {puts "tray %a"; flush stdout}]
puts "tray created $t [ztk::has tray]"
flush stdout
after 300 [list ztk::tray configure $t -tooltip "second tip"]
after 4000 exit
