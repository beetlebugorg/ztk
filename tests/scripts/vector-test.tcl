# The test of examples/vector.tcl. tests/apps.sh runs the example with
# this file after it on the headless backend. Each check prints "ok: NAME"
# or "FAIL: NAME". The SVG export goes to the output between the lines
# "--svg--" and "--end--", for the XML check of tests/apps.sh.
set fails 0
proc check {name got want} {
    if {$got eq $want} {
        puts "ok: $name"
    } else {
        puts "FAIL: $name: got '$got', want '$want'"
        incr ::fails
    }
}

# Canvas coordinates of a point of the page, as whole numbers for event generate.
proc at {x y} {
    return [list [expr {round($x * $vec::zoom + $vec::panx - [.c canvasx 0])}] [expr {round($y * $vec::zoom + $vec::pany - [.c canvasy 0])}]]
}
proc ev {type x y {state {}}} {
    lassign [at $x $y] cx cy
    event generate .c <$type> -x $cx -y $cy {*}$state
    update
}
# A drag with the first button from one point of the page to another.
proc drag {x0 y0 x1 y1 {steps 4}} {
    ev Button-1 $x0 $y0
    for {set i 1} {$i <= $steps} {incr i} {
        ev B1-Motion [expr {$x0 + ($x1 - $x0) * $i / double($steps)}] [expr {$y0 + ($y1 - $y0) * $i / double($steps)}]
    }
    ev ButtonRelease-1 $x1 $y1
}
proc last {} { return [lindex $vec::order end] }
proc prop {id key} { return [dict get $vec::S($id) $key] }

update
set n0 [llength $vec::order]

# Each drawing tool.
set vec::tool rect
drag 100 200 203 278
check "the rectangle tool, with snap to the grid" [list [prop [last] type] [prop [last] pts]] {rect {100 200 200 280}}
check "a new shape is selected" $vec::sel [last]
set vec::tool ellipse
drag 300 60 380 120
check "the ellipse tool" [list [prop [last] type] [prop [last] pts]] {ellipse {300 60 380 120}}
set vec::tool line
drag 20 20 80 40
check "the line tool" [list [prop [last] type] [prop [last] pts]] {line {20 20 80 40}}
set vec::tool polyline
ev Button-1 400 300; ev ButtonRelease-1 400 300
ev Button-1 450 250; ev ButtonRelease-1 450 250
ev Button-1 500 300; ev ButtonRelease-1 500 300
# The second click at the same point is a double click.
ev Button-1 500 300; ev ButtonRelease-1 500 300
check "the polyline tool ends at a double click" [list [prop [last] type] [prop [last] pts]] {polyline {400 300 450 250 500 300}}
set vec::tool polygon
foreach {x y} {200 300 260 300 230 340} { ev Button-1 $x $y; ev ButtonRelease-1 $x $y }
event generate .c <Return>
update
check "the polygon tool ends at Return" [list [prop [last] type] [prop [last] pts]] {polygon {200 300 260 300 230 340}}
set vec::tool free
drag 500 100 560 140 8
check "the freehand tool keeps the points of the drag" [list [prop [last] type] [expr {[llength [prop [last] pts]] >= 10}]] {free 1}
set vec::tool text
ev Button-1 40 360
.c.text insert 0 "Hello"
event generate .c.text <Return>
update
check "the text tool" [list [prop [last] type] [prop [last] text] [prop [last] pts]] {text Hello {40 360}}
check "seven new shapes" [expr {[llength $vec::order] - $n0}] 7
set rect [lindex $vec::order $n0]
set oval [lindex $vec::order [expr {$n0 + 1}]]

# The select tool: move, resize, rotate, Shift, and the rubber band.
set vec::tool select
ev Button-1 150 240; ev ButtonRelease-1 150 240
check "a click selects the top shape under the pointer" $vec::sel $rect
drag 150 240 200 260
check "a drag moves the shape, with snap" [prop $rect pts] {150 220 250 300}
lassign [.c coords h4] hx0 hy0 hx1 hy1
set hx [expr {round(($hx0 + $hx1) / 2 - [.c canvasx 0])}]; set hy [expr {round(($hy0 + $hy1) / 2 - [.c canvasy 0])}]
event generate .c <Button-1> -x $hx -y $hy
event generate .c <B1-Motion> -x [expr {$hx + 40}] -y [expr {$hy + 16}]
event generate .c <ButtonRelease-1> -x [expr {$hx + 40}] -y [expr {$hy + 16}]
update
lassign [prop $rect pts] x0 y0 x1 y1
check "the corner handle resizes from the other corner" [list [expr {round($x0)}] [expr {round($y0)}] [expr {round($x1 - $x0) > 100}] [expr {round($y1 - $y0) > 80}]] {150 220 1 1}
set before [prop $rect pts]
lassign [.c coords rot] rx0 ry0 rx1 ry1
set rx [expr {round(($rx0 + $rx1) / 2 - [.c canvasx 0])}]; set ry [expr {round(($ry0 + $ry1) / 2 - [.c canvasy 0])}]
lassign [vec::selbox] bx0 by0 bx1 by1
set cx [expr {round(($bx0 + $bx1) / 2 - [.c canvasx 0])}]; set cy [expr {round(($by0 + $by1) / 2 - [.c canvasy 0])}]
event generate .c <Button-1> -x $rx -y $ry
event generate .c <B1-Motion> -x [expr {$cx + 200}] -y $cy
event generate .c <ButtonRelease-1> -x [expr {$cx + 200}] -y $cy
update
check "the rotate handle turns the shape by 90 degrees" [prop $rect angle] 90.0
check "a rotated rectangle is a polygon on the canvas" [.c type s$rect] polygon
ev Shift-Button-1 340 90; ev ButtonRelease-1 340 90
check "Shift and a click add a shape to the selection" [lsort $vec::sel] [lsort [list $rect $oval]]
ev Shift-Button-1 340 90; ev ButtonRelease-1 340 90
check "Shift and a click remove a shape from the selection" $vec::sel $rect
vec::select {}
event generate .c <Button-1> -x 2 -y 2
event generate .c <B1-Motion> -x 520 -y 160
event generate .c <ButtonRelease-1> -x 520 -y 160
update
check "the rubber band selects the shapes inside it" [expr {$oval in $vec::sel && $rect ni $vec::sel}] 1

# The properties, the z-order, and groups.
vec::select [list $oval]
vec::setprop pfill #ff0000
check "the fill of the panel goes to the selection" [prop $oval fill] #ff0000
vec::setprop popacity 50
check "the opacity mixes the fill with the page" [.c itemcget s$oval -fill] #ff8080
vec::setprop pwidth 6
check "the stroke width" [list [prop $oval width] [.c itemcget s$oval -width]] {6.0 6.0}
vec::zorder lower
check "Lower puts the shape at the bottom" [lindex $vec::order 0] $oval
vec::zorder raise
check "Raise puts the shape at the top" [last] $oval
vec::select [list $rect $oval]
vec::group
vec::select {}
ev Button-1 340 90; ev ButtonRelease-1 340 90
check "a click on a shape of a group selects the group" [lsort $vec::sel] [lsort [list $rect $oval]]
vec::ungroup

# Undo and redo.
set count [llength $vec::order]
event generate .c <Delete>
update
check "Delete removes the selection" [llength $vec::order] [expr {$count - 2}]
vec::undo
check "undo brings the shapes back" [list [llength $vec::order] [prop $oval fill]] [list $count #ff0000]
vec::undo
check "the next undo removes the group" [prop $oval group] g1
vec::redo
check "redo" [prop $oval group] ""

# Zoom and pan.
set c0 [.c coords s$oval]
vec::zoomby 2.0 0 0
check "the wheel zooms" $vec::zoom 1.6
check "a zoom scales the items on the canvas" [expr {abs([lindex [.c coords s$oval] 2] - 2 * [lindex $c0 2] + [.c canvasx 0]) < 0.01}] 1
event generate .c <MouseWheel> -x 10 -y 10 -delta -120
update
check "a wheel event zooms out" [format %.4f $vec::zoom] 1.4545
set px [.c canvasx 0]
set vec::space 1
event generate .c <Button-1> -x 100 -y 100
event generate .c <B1-Motion> -x 130 -y 110
event generate .c <ButtonRelease-1> -x 130 -y 110
set vec::space 0
update
check "a drag with Space held pans" [expr {round($px - [.c canvasx 0])}] 30
vec::zoomby [expr {0.8 / $vec::zoom}] 0 0

# The console.
set count [llength $vec::order]
vec::histmove -1
vec::histmove -1
vec::histmove -1
check "the history has the sample scripts" [string match "for *shape oval*" $vec::cmd] 1
vec::run $vec::cmd
check "the spiral sample makes 48 circles" [llength $vec::order] [expr {$count + 48}]
vec::undo
check "undo removes the shapes of a script" [llength $vec::order] $count
vec::run {set id [shape rect 10 10 30 20 -fill blue]; move $id 5 5; select $id; shape get $id pts}
check "the console API: shape, move, select, and get" [lindex $vec::conlines end] {15 15 45 35}
check "the result of a script" $vec::sel [last]
vec::run {set n 0; each shape {incr n}; set n}
check "each runs a body for each shape" [lindex $vec::conlines end] [llength $vec::order]
check "a script that does not end stops at the step limit" [catch {vec::run {while 1 {}}} e] 1
check "the step limit error shows in the console" [lindex $vec::conlines end] "error: step limit reached"
catch {vec::run {set s x; while 1 {append s $s}}}
check "a script that uses too much memory stops" [lindex $vec::conlines end] "error: the script used too much memory"
catch {vec::run {shape bogus}}
check "an error of the API shows in the console" [string match "error: bad option \"bogus\"*" [lindex $vec::conlines end]] 1
catch {vec::run {exit}}
check "the console has no exit" [lindex $vec::conlines end] {error: invalid command name "exit"}
vec::run {llength [shape list]}
check "the app goes on after the errors" [lindex $vec::conlines end] [llength $vec::order]

# The layer list: a row for each shape, the top shape first, and a pick selects the shape.
update
check "the layer list has a row for each shape" [.tools.layers size] [llength $vec::order]
.tools.layers selection clear 0 end
.tools.layers selection set end
event generate .tools.layers <<ListboxSelect>>
check "a pick in the layer list selects the bottom shape" $vec::sel [lindex $vec::order 0]
check "the selection shows in the layer list" [.tools.layers curselection] [expr {[llength $vec::order] - 1}]

# SVG export, and the own format.
vec::exportsvg
set svg $vec::svg
check "the SVG has an element for each shape" [regexp -all {id="s[0-9]+"} $svg] [llength $vec::order]
check "the SVG has the rotation of the rectangle" [regexp "<rect id=\"s$rect\"\[^>\]*transform=\"rotate\\(90 " $svg] 1
check "the SVG has the opacity of the ellipse" [regexp "<ellipse id=\"s$oval\"\[^>\]*opacity=\"0.5\"" $svg] 1
check "the export works with no file access" [string match "Kept * bytes in memory*" [lindex $vec::conlines end]] 1
puts --svg--
puts -nonewline $svg
puts --end--
set doc [vec::doc]
vec::save
vec::run clear
check "clear" [llength $vec::order] 0
vec::load
check "load gives the saved drawing back" [vec::doc] $doc
puts "fails: $fails"
exit [expr {$fails ? 1 : 0}]
