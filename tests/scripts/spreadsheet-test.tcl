# The test of examples/spreadsheet.tcl. tests/apps.sh runs the example
# with this file after it on the headless backend. Each check prints
# "ok: NAME" or "FAIL: NAME".
set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok: $name"
    } else {
        puts "FAIL: $name: got '$got', want '$want'"
        incr ::fails
    }
}

# Types text into the widget with the focus, one key event for each character.
proc type {text} {
    array set sym {= equal + plus - minus * asterisk / slash ( parenleft ) parenright : colon . period , comma " " space $ dollar}
    foreach ch [split $text ""] {
        set k [expr {[info exists sym($ch)] ? $sym($ch) : $ch}]
        event generate [focus] <Key-$k>
        update
    }
}
proc key {k} { event generate [focus] <$k>; update }
proc v {cell} { return [expr {[info exists ss::val($cell)] ? $ss::val($cell) : ""}] }

update
focus .c
ss::setcur 19 2
type "=B2+C3*2"
key Return
check "a formula typed into the cell entry" [v C20] 580
check "Return moves the active cell down" $ss::cur {20 2}
type "=sum(B2:B7)"
key Return
check "sum of a range" [v C21] 1058
ss::setcur 1 1
type 500
key Return
check "a change of B2 computes the formula that reads it" [v C20] 660
check "a change of B2 computes the sum" [v C21] 1138
check "a change of B2 computes the total of the row" [v F2] 1845
ss::setcur 21 2
type "=avg(B2:B3)"
key Tab
check "avg" [v C22] 282.0
check "Tab moves the active cell right" $ss::cur {21 3}
type "=max(B2:E7)+min(C2:C7)"
key Tab
check "max and min" [v D22] 510
type "=sqrt(16)+abs(-2)+round(2.6)"
key Return
check "functions of expr" [v E22] 9.0
ss::change {A30 =1/0 A31 =Z99999 A32 =A99+ A33 =B33 B33 =A33+1 A34 =A33*2}
check "division by zero" [v A30] #DIV/0
check "a cell outside the sheet" [v A31] #REF
check "a formula that does not parse" [v A32] #ERROR
check "a cycle shows in the first cell" [v A33] #CYCLE
check "a cycle shows in the second cell" [v B33] #CYCLE
check "a formula that reads a cycle" [v A34] #CYCLE
ss::change {B33 5}
check "the end of the cycle" [list [v A33] [v A34]] {5 10}
set n [llength [.c find withtag cell]]

# A range with Shift and the arrows, copy, paste, and undo.
ss::setcur 1 1
focus .c
key Shift-Down
key Shift-Down
key Shift-Right
check "Shift and the arrows select a range" [ss::bounds] {1 1 3 2}
check "copy gives lines with tabs" [ss::copy] "500\t380\n64\t80\n120\t0"
ss::setcur 0 7
ss::paste
check "paste puts the range at the active cell" [list [v H1] [v I1] [v H3] [v I3]] {500 380 120 0}
ss::undo
check "undo removes the paste" [list [v H1] [v I3]] {{} {}}
ss::undo
check "the next undo removes the cycle fix" [v A33] #CYCLE
ss::paste "1\t2\n3\t=H1+I1+H2"
check "paste of text with tabs and a formula" [v I2] 6

# The mouse: a click on a cell, and a drag of the edge of a column header.
set x [expr {round($ss::X(3) + 10 - [.c canvasx 0])}]
set y [expr {round($ss::HH + 4 * $ss::RH + 5 - [.c canvasy 0])}]
event generate .c <Button-1> -x $x -y $y
event generate .c <ButtonRelease-1> -x $x -y $y
update
check "a click selects the cell under the pointer" $ss::cur {4 3}
set w0 $ss::colw(1)
set ex [expr {round($ss::X(2) - [.c canvasx 0])}]
event generate .c <Button-1> -x $ex -y 10
event generate .c <B1-Motion> -x [expr {$ex + 40}] -y 10
event generate .c <ButtonRelease-1> -x [expr {$ex + 40}] -y 10
update
check "a drag of the edge of a header resizes the column" [expr {$ss::colw(1) - $w0}] 40

# Number formats.
ss::setcur 1 5
set ss::fmtsel percent
ss::setfmt
check "a percent format" [ss::show F2 [v F2]] 184500.0%
set ss::fmtsel fixed
ss::setfmt
check "a fixed format" [ss::show F2 [v F2]] 1845.00
set ss::fmtsel thousands
ss::setfmt
check "a format with thousands" [ss::show F2 12345678] 12,345,678

# CSV in memory: this script has no file access.
set csv [ss::tocsv]
ss::save
check "save keeps the CSV in memory with no file access" [expr {$ss::saved eq $csv && [string match "*in memory*" $ss::status]}] 1
ss::change {B2 7}
ss::load
check "load reads the saved CSV" [list [v B2] [v F2] [v C21]] {500 1845 1138}
set rows [ss::fromcsv "a,\"b,\"\"c\"\"\",d\n1,2"]
check "a CSV field with a comma and a quote" [lindex $rows 0 1] {b,"c"}
check "the rows of a CSV text" [list [llength $rows] [lindex $rows 1 1]] {2 2}

# The 10 000 rows: a scroll to the middle and to the end keeps the items few.
.c yview moveto 0.5
update
check "the middle of the sheet has items only for the cells in view" [expr {[llength [.c find withtag cell]] < 600}] 1
ss::setcur 9999 0
update
check "the last row" [ss::name {*}$ss::cur] A10000
set first [.c find withtag hrow]
check "the header row stays at the top of the view" [expr {abs([lindex [.c coords [lindex $first 0]] 1] - [.c canvasy 0]) < 1}] 1
check "the header column stays at the left of the view" [expr {abs([lindex [.c coords [lindex [.c find withtag hcol] 0]] 0] - [.c canvasx 0]) < 1}] 1
key Prior
check "Page Up" $ss::cur {9989 0}
puts "fails: $fails"
exit [expr {$fails ? 1 : 0}]
