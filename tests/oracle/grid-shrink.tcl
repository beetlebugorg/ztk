# A container that is smaller than its layout, with a line that reaches its
# minimum. wish gives "1 24". ztk gives "0 25".
frame .c -width 25 -height 10; grid propagate .c 0; grid .c
frame .c.a -width 23 -height 5; frame .c.b -width 42 -height 5
grid .c.a -row 0 -column 0 -sticky ew; grid .c.b -row 0 -column 1 -sticky ew
grid columnconfigure .c 0 -weight 3; grid columnconfigure .c 1 -weight 2
update
foreach c {0 1} { puts -nonewline "[lindex [grid bbox .c $c 0] 2] " }
puts ""
exit
