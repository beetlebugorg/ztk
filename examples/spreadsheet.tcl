# A spreadsheet of 10 000 rows on a canvas. The canvas has items only for
# the cells in view, and the header row and column stay in place while
# the grid scrolls. Formulas are Tcl expressions with cell names. It runs
# in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load spreadsheet.css
}
wm title . "Spreadsheet"
set ztk [llength [info commands ::ztk::class]]
proc cls {w args} {
    if {$::ztk} { ::ztk::class $w add {*}$args }
}

namespace eval ss {
    variable NR 10000      ;# rows
    variable NC 26         ;# columns, A to Z
    variable RH 24         ;# the height of a row
    variable HH 26         ;# the height of the header row
    variable RW 52         ;# the width of the header column
    variable raw           ;# cell -> the text that the user typed
    variable val           ;# cell -> the value, or an error such as #REF
    variable prog          ;# cell -> the expression of a formula
    variable deps          ;# cell -> the cells that its formula reads
    variable rdeps         ;# cell -> a dict of the cells that read it
    variable fmt           ;# cell -> general, fixed, thousands, or percent
    variable colw          ;# column -> width
    variable X             ;# column -> left edge
    array set raw {}; array set val {}; array set prog {}; array set deps {}
    array set rdeps {}; array set fmt {}; array set colw {}; array set X {}
    variable cur {0 0}     ;# the active cell: row and column
    variable anchor {0 0}  ;# the other corner of the selection
    variable undo {}       ;# groups of {cell old new}
    variable clip ""       ;# copied text when there is no clipboard command
    variable saved ""      ;# the CSV text of Save when there is no file access
    variable view ""       ;# the block of rows and columns that has items
    variable top {0 0}     ;# the view origin when the headers were placed
    variable drag ""       ;# the column of a resize drag
    variable ftext ""      ;# the text of the formula bar
    variable fmtsel general
    variable status ""
    for {set c 0} {$c < $NC} {incr c} { set colw($c) 84 }
    set colw(0) 110
    variable P
    if {[llength [info commands ::ztk::style]] && [::ztk::style scheme] eq "dark"} {
        array set P {bg #17191d line #2a2e35 hdr #20232a hdrfg #9aa3b2 hdrline #343a44
            hdrsel #2b3a55 sel #1d3354 accent #60a5fa err #f87171 fg #e5e7eb}
    } else {
        array set P {bg #ffffff line #e5e7eb hdr #f4f5f7 hdrfg #5b6472 hdrline #d5d9e0
            hdrsel #dbe4f5 sel #e3edfd accent #2563eb err #dc2626 fg #111827}
    }
}

# ---- Names and formulas ----

proc ss::name {r c} { return [format %c [expr {65 + $c}]][expr {$r + 1}] }

# The row and column of a name, or an error #REF for a cell outside the sheet.
proc ss::cell {ref} {
    variable NR; variable NC
    if {![regexp {^\$?([A-Za-z]+)\$?([0-9]+)$} $ref -> l n]} { error #REF }
    set c 0
    foreach ch [split [string toupper $l] ""] { set c [expr {$c * 26 + [scan $ch %c] - 64}] }
    incr c -1
    set r [expr {[scan $n %d] - 1}]
    if {$c >= $NC || $r < 0 || $r >= $NR} { error #REF }
    return [list $r $c]
}

# Turns the text after = into an expression for expr, and gives the cells
# that it reads. A1 becomes [ss::ref 0 0], A1:B2 becomes [ss::range 0 0 1 1],
# and a bad name becomes [ss::bad].
proc ss::compile {text} {
    set f [string range $text 1 end]
    set out ""; set reads {}; set i 0
    set re {\$?([A-Za-z_]+)\$?([0-9]*)(?::\$?([A-Za-z]+)\$?([0-9]+))?(\s*\()?}
    while {[regexp -start $i -indices $re $f m l n l2 n2 paren]} {
        lassign $m s e
        # A division of two whole numbers gives a fraction, as in a spreadsheet.
        append out [string map {/ *1.0/} [string range $f $i [expr {$s - 1}]]]
        set tok [string range $f $s $e]
        set prev [string index $f [expr {$s - 1}]]
        set i [expr {$e + 1}]
        if {[lindex $paren 0] >= 0} {
            # A function call such as sum( or log10(.
            append out [string tolower $tok]
        } elseif {[regexp {[0-9A-Za-z_.]} $prev] || [lindex $n 0] > [lindex $n 1]} {
            # A word with no digits, or a part of a number such as 1e5.
            append out $tok
        } elseif {[catch {cell [string range $f {*}$l][string range $f {*}$n]} a]} {
            append out {[ss::bad]}
        } elseif {[lindex $l2 0] < 0} {
            append out "\[ss::ref $a\]"
            lappend reads [name {*}$a]
        } elseif {[catch {cell [string range $f {*}$l2][string range $f {*}$n2]} b]} {
            append out {[ss::bad]}
        } else {
            lassign $a r0 c0; lassign $b r1 c1
            if {$r0 > $r1} { lassign [list $r1 $r0] r0 r1 }
            if {$c0 > $c1} { lassign [list $c1 $c0] c0 c1 }
            append out "\[ss::range $r0 $c0 $r1 $c1\]"
            for {set r $r0} {$r <= $r1} {incr r} {
                for {set c $c0} {$c <= $c1} {incr c} { lappend reads [name $r $c] }
            }
        }
    }
    append out [string map {/ *1.0/} [string range $f $i end]]
    return [list $out $reads]
}

proc ss::bad {} { error #REF }

# The value of a cell for a formula. A cell of the recalculation is
# computed first. An empty cell is 0, and an error goes on to the formula.
proc ss::ref {r c} {
    variable val; variable dirty
    set cell [name $r $c]
    if {[info exists dirty($cell)]} { evalcell $cell }
    if {![info exists val($cell)] || $val($cell) eq ""} { return 0 }
    set v $val($cell)
    if {[string index $v 0] eq "#"} { error $v }
    return $v
}

# The numbers of a range, as one list, for sum, avg, min, max, and count.
proc ss::range {r0 c0 r1 c1} {
    variable val; variable dirty
    set out {}
    for {set r $r0} {$r <= $r1} {incr r} {
        for {set c $c0} {$c <= $c1} {incr c} {
            set cell [name $r $c]
            if {[info exists dirty($cell)]} { evalcell $cell }
            if {![info exists val($cell)]} continue
            set v $val($cell)
            if {[string index $v 0] eq "#"} { error $v }
            if {[string is double -strict $v]} { lappend out $v }
        }
    }
    return $out
}

proc ss::flat {args} { return [concat {*}$args] }
proc ::tcl::mathfunc::sum {args} {
    set t 0
    foreach x [ss::flat {*}$args] { set t [expr {$t + $x}] }
    return $t
}
proc ::tcl::mathfunc::count {args} { return [llength [ss::flat {*}$args]] }
proc ::tcl::mathfunc::avg {args} {
    set l [ss::flat {*}$args]
    if {![llength $l]} { error #DIV/0 }
    return [expr {sum($l) / double([llength $l])}]
}
proc ::tcl::mathfunc::min {args} {
    set l [ss::flat {*}$args]
    if {![llength $l]} { return 0 }
    return [lindex [lsort -real $l] 0]
}
proc ::tcl::mathfunc::max {args} {
    set l [ss::flat {*}$args]
    if {![llength $l]} { return 0 }
    return [lindex [lsort -real $l] end]
}

# Computes one cell of the recalculation. A cell that is reached again
# while it is in work is a cycle.
proc ss::evalcell {cell} {
    variable state; variable val; variable raw; variable prog; variable dirty
    if {[info exists state($cell)]} {
        if {$state($cell) eq "busy"} { error #CYCLE }
        return
    }
    set state($cell) busy
    if {![info exists raw($cell)]} {
        unset -nocomplain val($cell)
    } elseif {[info exists prog($cell)]} {
        if {[catch {expr $prog($cell)} v]} {
            if {[regexp {^#[A-Z/0-9]+$} $v]} {
            } elseif {[string match "*divide by zero*" $v]} {
                set v #DIV/0
            } else {
                set v #ERROR
            }
        } elseif {[regexp -nocase {^-?(inf|nan)} $v]} {
            set v #DIV/0
        }
        set val($cell) $v
    } else {
        set val($cell) $raw($cell)
    }
    set state($cell) done
    unset dirty($cell)
}

# Computes the cells and each cell that reads them, in the order of their reads.
proc ss::recalc {cells} {
    variable dirty; variable state; variable rdeps
    array unset dirty; array unset state
    while {[llength $cells]} {
        set next {}
        foreach c $cells {
            if {[info exists dirty($c)]} continue
            set dirty($c) 1
            if {[info exists rdeps($c)]} { lappend next {*}[dict keys $rdeps($c)] }
        }
        set cells $next
    }
    foreach c [array names dirty] {
        if {[info exists dirty($c)]} { catch {evalcell $c} }
    }
    array unset state
}

# Sets the text of a cell with no undo. RECALC 0 leaves the values for a
# later recalc of all cells.
proc ss::put {cell text {recalc 1}} {
    variable raw; variable prog; variable deps; variable rdeps
    if {[info exists deps($cell)]} {
        foreach d $deps($cell) {
            if {[info exists rdeps($d)]} { dict unset rdeps($d) $cell }
        }
        unset deps($cell)
    }
    unset -nocomplain prog($cell)
    if {$text eq ""} {
        unset -nocomplain raw($cell)
    } else {
        set raw($cell) $text
        if {[string index $text 0] eq "=" && [string length $text] > 1} {
            lassign [compile $text] e reads
            set prog($cell) $e
            set deps($cell) $reads
            foreach d $reads { dict set rdeps($d) $cell 1 }
        }
    }
    if {$recalc} { recalc [list $cell] }
}

# Sets cells as one step of undo: a list of cell and text.
proc ss::change {pairs} {
    variable raw; variable undo
    set group {}
    foreach {cell text} $pairs {
        set old [expr {[info exists raw($cell)] ? $raw($cell) : ""}]
        if {$old eq $text} continue
        lappend group [list $cell $old $text]
    }
    if {![llength $group]} return
    lappend undo $group
    foreach g $group { put [lindex $g 0] [lindex $g 2] 0 }
    recalc [lmap g $group {lindex $g 0}]
    render 1
    showcur
}

proc ss::undo {} {
    variable undo
    if {![llength $undo]} { setstatus "The undo list is empty."; return }
    set group [lindex $undo end]
    set undo [lrange $undo 0 end-1]
    foreach g $group { put [lindex $g 0] [lindex $g 1] 0 }
    recalc [lmap g $group {lindex $g 0}]
    render 1
    showcur
    setstatus "Undid a change of [llength $group] cells."
}

# The text of a value in its cell, with its number format.
proc ss::show {cell v} {
    variable fmt
    if {![string is double -strict $v]} { return $v }
    set f [expr {[info exists fmt($cell)] ? $fmt($cell) : "general"}]
    switch -- $f {
        fixed { return [format %.2f $v] }
        percent { return [format %.1f%% [expr {$v * 100.0}]] }
        thousands {
            return [expr {$v < 0 ? "-" : ""}][commas [format %.0f [expr {abs($v)}]]]
        }
        default {
            if {$v == round($v) && abs($v) < 1e15} { return [format %.0f $v] }
            return [format %.6g $v]
        }
    }
}

proc ss::commas {i} {
    set out ""
    while {[string length $i] > 3} {
        set out ",[string range $i end-2 end]$out"
        set i [string range $i 0 end-3]
    }
    return $i$out
}

# ---- The window ----

frame .bar -padx 10 -pady 8
label .bar.ref -text A1 -width 6 -anchor w
entry .bar.f -textvariable ss::ftext
pack .bar.ref -side left
pack .bar.f -side left -fill x -expand 1 -padx {6 0}
pack .bar -side top -fill x
cls .bar toolbar
cls .bar.ref ref

frame .tools -padx 10
pack .tools -side top -fill x -pady {0 8}
cls .tools toolbar
button .tools.undo -text Undo -command ss::undo
button .tools.copy -text Copy -command ss::copy
button .tools.paste -text Paste -command ss::paste
pack .tools.undo .tools.copy .tools.paste -side left -padx {0 6}
frame .tools.fmt
foreach {v t} {general General fixed 0.00 thousands 1,000 percent %} {
    radiobutton .tools.fmt.$v -text $t -variable ss::fmtsel -value $v -indicatoron 0 -command ss::setfmt
    pack .tools.fmt.$v -side left
    cls .tools.fmt.$v segmented
}
pack .tools.fmt -side left -padx 10
button .tools.load -text "Load CSV" -command ss::load
button .tools.save -text "Save CSV" -command ss::save
pack .tools.load .tools.save -side right -padx {6 0}

# The menu bar, and the context menu of the grid.
menu .menubar -tearoff 0
. configure -menu .menubar
foreach {m t} {file File edit Edit format Format} {
    menu .menubar.$m -tearoff 0
    .menubar add cascade -label $t -menu .menubar.$m -underline 0
}
.menubar.file add command -label "Load CSV..." -command ss::load
.menubar.file add command -label "Save CSV..." -command ss::save
.menubar.edit add command -label Undo -accelerator Ctrl+Z -command ss::undo
.menubar.edit add separator
.menubar.edit add command -label Copy -accelerator Ctrl+C -command ss::copy
.menubar.edit add command -label Paste -accelerator Ctrl+V -command ss::paste
foreach {v t} {general General fixed 0.00 thousands 1,000 percent %} {
    .menubar.format add radiobutton -label $t -variable ss::fmtsel -value $v -command ss::setfmt
}
bind .c <Button-3> {tk_popup .menubar.edit %X %Y}

label .status -textvariable ss::status -anchor w -padx 10 -pady 4
pack .status -side bottom -fill x
cls .status muted

# The sheet is the page of a notebook tab. The notebook and its page come
# first, so the canvas and the scrollbars that pack into the page are
# above them.
ttk::notebook .book
frame .sheet
.book add .sheet -text "Sheet 1"
pack .book -side top -fill both -expand 1 -padx 10 -pady {0 4}

canvas .c -width 640 -height 300 -highlightthickness 0 -borderwidth 0 -takefocus 1 \
    -background $ss::P(bg) -xscrollcommand ss::xscrolled -yscrollcommand ss::yscrolled
scrollbar .vs -orient vertical -command {.c yview}
scrollbar .hs -orient horizontal -command {.c xview}
pack .hs -in .sheet -side bottom -fill x
pack .vs -in .sheet -side right -fill y
pack .c -in .sheet -side top -fill both -expand 1
entry .c.ed -borderwidth 0
cls .c.ed celledit

# The left edge of each column, and the scroll region.
proc ss::layout {} {
    variable NC; variable RW; variable colw; variable X; variable NR; variable RH; variable HH
    set x $RW
    for {set c 0} {$c < $NC} {incr c} { set X($c) $x; incr x $colw($c) }
    set X($NC) $x
    .c configure -scrollregion [list 0 0 $x [expr {$HH + $NR * $RH}]]
}

proc ss::colat {x} {
    variable NC; variable X
    for {set c 0} {$c < $NC} {incr c} { if {$x < $X([expr {$c + 1}])} { return $c } }
    return [expr {$NC - 1}]
}

# Makes the items of the cells in a block of rows around the view. A
# scroll inside the block only moves the headers.
proc ss::render {{force 0}} {
    variable NR; variable NC; variable RH; variable HH; variable RW; variable X
    variable val; variable view; variable P; variable top
    set x0 [.c canvasx 0]; set y0 [.c canvasy 0]
    set h [winfo height .c]; set w [winfo width .c]
    set first [expr {max(0, int(($y0) / $RH) - 1)}]
    set r0 [expr {($first / 16) * 16}]
    set r1 [expr {min($NR - 1, $r0 + int($h / $RH) + 34)}]
    set c0 [colat [expr {$x0 + $RW}]]
    set c1 [colat [expr {$x0 + $w}]]
    set key [list $r0 $r1 $c0 $c1]
    if {$key eq $view && !$force} { headers; return }
    set view $key
    .c delete cell hdr
    set ya [expr {$HH + $r0 * $RH}]; set yb [expr {$HH + ($r1 + 1) * $RH}]
    set xa $X($c0); set xb $X([expr {$c1 + 1}])
    .c create rectangle 0 0 0 0 -fill $P(sel) -outline "" -tags {cell selfill}
    for {set r $r0} {$r <= $r1 + 1} {incr r} {
        set y [expr {$HH + $r * $RH}]
        .c create line $xa $y $xb $y -fill $P(line) -tags cell
    }
    for {set c $c0} {$c <= $c1 + 1} {incr c} {
        .c create line $X($c) $ya $X($c) $yb -fill $P(line) -tags cell
    }
    for {set r $r0} {$r <= $r1} {incr r} {
        set y [expr {$HH + $r * $RH + $RH / 2}]
        for {set c $c0} {$c <= $c1} {incr c} {
            set cell [format %c [expr {65 + $c}]][expr {$r + 1}]
            if {![info exists val($cell)] || $val($cell) eq ""} continue
            set v $val($cell)
            if {[string index $v 0] eq "#"} {
                .c create text [expr {$X([expr {$c + 1}]) - 6}] $y -text $v -anchor e -fill $P(err) -tags cell
            } elseif {[string is double -strict $v]} {
                .c create text [expr {$X([expr {$c + 1}]) - 6}] $y -text [show $cell $v] -anchor e -fill $P(fg) -tags cell
            } else {
                .c create text [expr {$X($c) + 6}] $y -text $v -anchor w -fill $P(fg) -tags cell
            }
        }
    }
    .c create rectangle 0 0 0 0 -outline $P(accent) -width 2 -tags {cell selbox}
    # The header column: a strip, the row numbers, and its lines.
    .c create rectangle 0 0 $RW [expr {$HH + $NR * $RH}] -fill $P(hdr) -outline "" -tags {hdr hcol}
    .c create rectangle 0 0 0 0 -fill $P(hdrsel) -outline "" -tags {hdr hcol hcolsel}
    for {set r $r0} {$r <= $r1} {incr r} {
        set y [expr {$HH + $r * $RH}]
        .c create line 0 $y $RW $y -fill $P(hdrline) -tags {hdr hcol}
        .c create text [expr {$RW / 2}] [expr {$y + $RH / 2}] -text [expr {$r + 1}] -fill $P(hdrfg) -tags {hdr hcol}
    }
    .c create line [expr {$RW - 0.5}] 0 [expr {$RW - 0.5}] [expr {$HH + $NR * $RH}] -fill $P(hdrline) -tags {hdr hcol}
    # The header row: a strip, the column letters, and the edges that a drag moves.
    .c create rectangle 0 0 $X($NC) $HH -fill $P(hdr) -outline "" -tags {hdr hrow}
    .c create rectangle 0 0 0 0 -fill $P(hdrsel) -outline "" -tags {hdr hrow hrowsel}
    for {set c 0} {$c < $NC} {incr c} {
        set xm [expr {($X($c) + $X([expr {$c + 1}])) / 2}]
        .c create text $xm [expr {$HH / 2}] -text [format %c [expr {65 + $c}]] -fill $P(hdrfg) -tags {hdr hrow}
        .c create line $X([expr {$c + 1}]) 0 $X([expr {$c + 1}]) $HH -fill $P(hdrline) -tags {hdr hrow}
    }
    .c create line 0 [expr {$HH - 0.5}] $X($NC) [expr {$HH - 0.5}] -fill $P(hdrline) -tags {hdr hrow}
    .c create rectangle 0 0 $RW $HH -fill $P(hdr) -outline $P(hdrline) -tags {hdr corner}
    set top {0 0}
    headers
    drawsel
}

# Keeps the header row at the top and the header column at the left of the view.
proc ss::headers {} {
    variable top
    set x0 [.c canvasx 0]; set y0 [.c canvasy 0]
    lassign $top tx ty
    if {$x0 != $tx || $y0 != $ty} {
        .c move hrow 0 [expr {$y0 - $ty}]
        .c move hcol [expr {$x0 - $tx}] 0
        .c move corner [expr {$x0 - $tx}] [expr {$y0 - $ty}]
        set top [list $x0 $y0]
    }
}

proc ss::yscrolled {a b} { .vs set $a $b; render; finishedit }
proc ss::xscrolled {a b} { .hs set $a $b; render; finishedit }

# ---- Selection ----

proc ss::bounds {} {
    variable cur; variable anchor
    lassign $cur r c; lassign $anchor ar ac
    return [list [expr {min($r, $ar)}] [expr {min($c, $ac)}] [expr {max($r, $ar)}] [expr {max($c, $ac)}]]
}

proc ss::drawsel {} {
    variable X; variable HH; variable RH; variable RW; variable cur; variable top
    lassign [bounds] r0 c0 r1 c1
    lassign $cur r c
    set ya [expr {$HH + $r0 * $RH}]; set yb [expr {$HH + ($r1 + 1) * $RH}]
    set xa $X($c0); set xb $X([expr {$c1 + 1}])
    .c coords selfill $xa $ya $xb $yb
    if {$r0 == $r1 && $c0 == $c1} { .c coords selfill 0 0 0 0 }
    .c coords selbox [expr {$xa + 1}] [expr {$ya + 1}] $xb $yb
    lassign $top tx ty
    .c coords hcolsel $tx $ya [expr {$tx + $RW}] $yb
    .c coords hrowsel $xa $ty $xb [expr {$ty + $HH}]
    .c raise selbox
    .c raise hcol
    .c raise hrow
    .c raise corner
}

# The text of the formula bar, the name box, and the status line.
proc ss::showcur {} {
    variable cur; variable raw; variable ftext; variable fmt; variable fmtsel
    set cell [name {*}$cur]
    .bar.ref configure -text $cell
    set ftext [expr {[info exists raw($cell)] ? $raw($cell) : ""}]
    set fmtsel [expr {[info exists fmt($cell)] ? $fmt($cell) : "general"}]
    lassign [bounds] r0 c0 r1 c1
    if {$r0 == $r1 && $c0 == $c1} {
        setstatus "Type a value or a formula such as =sum(B2:B7). Shift and the arrows select a range."
    } else {
        set n 0; set t 0
        foreach v [range $r0 $c0 $r1 $c1] { incr n; set t [expr {$t + $v}] }
        setstatus "[name $r0 $c0]:[name $r1 $c1]   Count $n   Sum [show {} $t]"
    }
}

proc ss::setstatus {text} { variable status; set status $text }

# Moves the active cell by rows and columns. EXTEND keeps the anchor.
proc ss::go {dr dc {extend 0}} {
    variable cur; variable anchor; variable NR; variable NC
    lassign $cur r c
    set r [expr {max(0, min($NR - 1, $r + $dr))}]
    set c [expr {max(0, min($NC - 1, $c + $dc))}]
    setcur $r $c $extend
}

proc ss::setcur {r c {extend 0}} {
    variable cur; variable anchor
    set cur [list $r $c]
    if {!$extend} { set anchor $cur }
    reveal $r $c
    drawsel
    showcur
}

# Scrolls so that a cell shows below and right of the headers.
proc ss::reveal {r c} {
    variable X; variable HH; variable RH; variable RW; variable NR
    if {[winfo height .c] < $HH + $RH} return
    set y [expr {$HH + $r * $RH}]
    set y0 [.c canvasy 0]; set h [winfo height .c]
    set total [expr {double($HH + $NR * $RH)}]
    if {$y - $HH < $y0} {
        .c yview moveto [expr {($y - $HH) / $total}]
    } elseif {$y + $RH > $y0 + $h} {
        .c yview moveto [expr {($y + $RH - $h) / $total}]
    }
    set x0 [.c canvasx 0]; set w [winfo width .c]
    set totalw [expr {double([lindex [.c cget -scrollregion] 2])}]
    if {$X($c) - $RW < $x0} {
        .c xview moveto [expr {($X($c) - $RW) / $totalw}]
    } elseif {$X([expr {$c + 1}]) > $x0 + $w} {
        .c xview moveto [expr {($X([expr {$c + 1}]) - $w) / $totalw}]
    }
}

# The cell under a point of the canvas, or {} on a header.
proc ss::hit {x y} {
    variable HH; variable RH; variable RW; variable NR
    set cx [.c canvasx $x]; set cy [.c canvasy $y]
    if {$x < $RW || $y < $HH} { return {} }
    set r [expr {min($NR - 1, int(($cy - $HH) / $RH))}]
    return [list $r [colat $cx]]
}

# The column whose right edge is near a point of the header row, or "".
proc ss::edge {x y} {
    variable HH; variable X; variable NC
    if {$y >= $HH} { return "" }
    set cx [.c canvasx $x]
    for {set c 0} {$c < $NC} {incr c} {
        if {abs($cx - $X([expr {$c + 1}])) <= 4} { return $c }
    }
    return ""
}

proc ss::press {x y shift} {
    variable drag
    focus .c
    finishedit
    set drag [edge $x $y]
    if {$drag ne ""} return
    set hit [hit $x $y]
    if {$hit eq ""} return
    setcur {*}$hit $shift
}

proc ss::motion {x y} {
    variable drag; variable colw; variable X
    if {$drag ne ""} {
        set colw($drag) [expr {max(30, int([.c canvasx $x] - $X($drag)))}]
        layout
        render 1
        return
    }
    set hit [hit [expr {max($x, 60)}] [expr {max($y, 30)}]]
    if {$hit ne ""} { setcur {*}$hit 1 }
}

bind .c <Button-1> {ss::press %x %y 0}
bind .c <Shift-Button-1> {ss::press %x %y 1}
bind .c <B1-Motion> {ss::motion %x %y}
bind .c <ButtonRelease-1> {set ss::drag ""}
bind .c <Double-Button-1> {if {[ss::hit %x %y] ne ""} {ss::edit}}
bind .c <Motion> {.c configure -cursor [expr {[ss::edge %x %y] ne "" ? "sb_h_double_arrow" : ""}]}
bind .c <Configure> {ss::render 1}

foreach {key dr dc} {Up -1 0 Down 1 0 Left 0 -1 Right 0 1} {
    bind .c <Key-$key> "ss::go $dr $dc; break"
    bind .c <Shift-Key-$key> "ss::go $dr $dc 1; break"
}
bind .c <Tab> {ss::go 0 1; break}
bind .c <Shift-Tab> {ss::go 0 -1; break}
bind .c <Return> {ss::go 1 0; break}
bind .c <Shift-Return> {ss::go -1 0; break}
bind .c <Prior> {ss::go -10 0; break}
bind .c <Next> {ss::go 10 0; break}
bind .c <Home> {ss::setcur [lindex $ss::cur 0] 0; break}
bind .c <F2> {ss::edit; break}
bind .c <Delete> {ss::clear; break}
bind .c <BackSpace> {ss::clear; break}
bind .c <Control-c> {ss::copy; break}
bind .c <Control-v> {ss::paste; break}
bind .c <Control-z> {ss::undo; break}
bind .c <Key> {ss::key %A}

# A printable key opens the entry with its character.
proc ss::key {ch} {
    if {[string length $ch] == 1 && [string is print $ch] && $ch ne " "} { edit $ch }
}

# ---- Editing ----

# Opens the entry over the active cell. TEXT replaces the old text.
proc ss::edit {{text ""}} {
    variable cur; variable X; variable HH; variable RH; variable raw
    lassign $cur r c
    reveal $r $c
    update idletasks
    set cell [name $r $c]
    set x [expr {round($X($c) - [.c canvasx 0])}]
    set y [expr {round($HH + $r * $RH - [.c canvasy 0])}]
    .c.ed delete 0 end
    if {$text ne ""} {
        .c.ed insert 0 $text
    } elseif {[info exists raw($cell)]} {
        .c.ed insert 0 $raw($cell)
    }
    place .c.ed -x $x -y $y -width [expr {$X([expr {$c + 1}]) - $X($c) + 1}] -height [expr {$RH + 1}]
    focus .c.ed
    .c.ed icursor end
}

# Puts the text of the entry into the active cell. GO moves the active cell after.
proc ss::commit {{dr 0} {dc 0}} {
    variable cur
    if {![winfo ismapped .c.ed] && [place info .c.ed] eq ""} return
    set text [.c.ed get]
    place forget .c.ed
    focus .c
    change [list [name {*}$cur] $text]
    go $dr $dc
}

proc ss::finishedit {} {
    if {[place info .c.ed] ne ""} { commit }
}

proc ss::cancel {} {
    place forget .c.ed
    focus .c
}

bind .c.ed <Return> {ss::commit 1 0; break}
bind .c.ed <Tab> {ss::commit 0 1; break}
bind .c.ed <Shift-Tab> {ss::commit 0 -1; break}
bind .c.ed <Up> {ss::commit -1 0; break}
bind .c.ed <Down> {ss::commit 1 0; break}
bind .c.ed <Escape> {ss::cancel; break}
bind .bar.f <Return> {ss::change [list [ss::name {*}$ss::cur] $ss::ftext]; focus .c}

proc ss::clear {} {
    lassign [bounds] r0 c0 r1 c1
    set pairs {}
    for {set r $r0} {$r <= $r1} {incr r} {
        for {set c $c0} {$c <= $c1} {incr c} { lappend pairs [name $r $c] "" }
    }
    change $pairs
}

proc ss::setfmt {} {
    variable fmt; variable fmtsel
    lassign [bounds] r0 c0 r1 c1
    for {set r $r0} {$r <= $r1} {incr r} {
        for {set c $c0} {$c <= $c1} {incr c} {
            if {$fmtsel eq "general"} { unset -nocomplain fmt([name $r $c]) } else { set fmt([name $r $c]) $fmtsel }
        }
    }
    render 1
    focus .c
}

# ---- Copy, paste, and CSV ----

# The selection as lines of text with tabs.
proc ss::copy {} {
    variable raw; variable clip
    lassign [bounds] r0 c0 r1 c1
    set lines {}
    for {set r $r0} {$r <= $r1} {incr r} {
        set row {}
        for {set c $c0} {$c <= $c1} {incr c} {
            set cell [name $r $c]
            lappend row [expr {[info exists raw($cell)] ? $raw($cell) : ""}]
        }
        lappend lines [join $row \t]
    }
    set clip [join $lines \n]
    if {[llength [info commands clipboard]]} { catch {clipboard clear; clipboard append $clip} }
    setstatus "Copied [expr {$r1 - $r0 + 1}] by [expr {$c1 - $c0 + 1}] cells."
    return $clip
}

# Puts text with tabs and lines at the active cell.
proc ss::paste {{text ""}} {
    variable clip; variable cur; variable NR; variable NC
    if {$text eq ""} {
        set text $clip
        if {[llength [info commands clipboard]]} { catch {set text [clipboard get]} }
    }
    lassign [bounds] r0 c0
    set pairs {}
    set r $r0
    foreach line [split [string trimright $text \n] \n] {
        set c $c0
        foreach f [split $line \t] {
            if {$r < $NR && $c < $NC} { lappend pairs [name $r $c] $f }
            incr c
        }
        incr r
    }
    change $pairs
    setstatus "Pasted [expr {[llength $pairs] / 2}] cells."
}

proc ss::csvfield {f} {
    if {[regexp {[,"\n]} $f]} { return "\"[string map {\" \"\"} $f]\"" }
    return $f
}

proc ss::tocsv {} {
    variable raw
    set mr -1; set mc -1
    foreach cell [array names raw] {
        lassign [cell $cell] r c
        set mr [expr {max($mr, $r)}]; set mc [expr {max($mc, $c)}]
    }
    set lines {}
    for {set r 0} {$r <= $mr} {incr r} {
        set row {}
        for {set c 0} {$c <= $mc} {incr c} {
            set cell [name $r $c]
            lappend row [csvfield [expr {[info exists raw($cell)] ? $raw($cell) : ""}]]
        }
        lappend lines [join $row ,]
    }
    return [join $lines \n]
}

# The rows of a CSV text, each a list of fields. A quoted field can hold
# commas, quotes, and new lines.
proc ss::fromcsv {text} {
    set rows {}; set row {}; set f ""; set q 0
    set n [string length $text]
    for {set i 0} {$i < $n} {incr i} {
        set ch [string index $text $i]
        if {$q} {
            if {$ch eq "\""} {
                if {[string index $text [expr {$i + 1}]] eq "\""} { append f \"; incr i } else { set q 0 }
            } else { append f $ch }
        } elseif {$ch eq "\""} {
            set q 1
        } elseif {$ch eq ","} {
            lappend row $f; set f ""
        } elseif {$ch eq "\n"} {
            lappend row $f; lappend rows $row; set row {}; set f ""
        } elseif {$ch ne "\r"} {
            append f $ch
        }
    }
    if {$f ne "" || [llength $row]} { lappend row $f; lappend rows $row }
    return $rows
}

# Replaces the sheet with the rows of a CSV text.
proc ss::loadcsv {text} {
    variable raw; variable val; variable prog; variable deps; variable rdeps; variable undo; variable NR; variable NC
    foreach v {raw val prog deps rdeps} { array unset $v }
    set undo {}
    set r 0
    foreach row [fromcsv $text] {
        set c 0
        foreach f $row {
            if {$f ne "" && $r < $NR && $c < $NC} { put [name $r $c] $f 0 }
            incr c
        }
        incr r
    }
    recalc [array names raw]
    render 1
    showcur
    return $r
}

proc ss::save {} {
    variable saved
    set text [tocsv]
    set rows [llength [split $text \n]]
    if {[llength [info commands open]]} {
        set f [open sheet.csv w]
        puts -nonewline $f $text
        close $f
        setstatus "Saved $rows rows to sheet.csv."
    } else {
        set saved $text
        setstatus "Saved $rows rows in memory. This script has no file access."
    }
    focus .c
}

proc ss::load {} {
    variable saved
    if {[llength [info commands open]] && ![catch {open sheet.csv} f]} {
        set text [read $f]
        close $f
    } elseif {$saved ne ""} {
        set text $saved
    } else {
        setstatus "There is no saved sheet."
        return
    }
    setstatus "Loaded [loadcsv $text] rows."
    focus .c
}

# ---- The first sheet ----

set ss::rows {
    {Item Q1 Q2 Q3 Q4 Total Share}
    {Filament 420 380 455 510 =sum(B2:E2) =F2/F$9}
    {Nozzles 64 80 72 96 =sum(B3:E3) =F3/F$9}
    {{Build plates} 120 0 140 60 =sum(B4:E4) =F4/F$9}
    {Power 210 195 188 230 =sum(B5:E5) =F5/F$9}
    {Shipping 145 162 171 208 =sum(B6:E6) =F6/F$9}
    {Software 99 99 99 99 =sum(B7:E7) =F7/F$9}
    {{} {} {} {} {} {} {}}
    {Total =sum(B2:B7) =sum(C2:C7) =sum(D2:D7) =sum(E2:E7) =sum(F2:F7) =sum(G2:G7)}
    {Average =avg(B2:B7) =avg(C2:C7) =avg(D2:D7) =avg(E2:E7) =avg(F2:F7)}
    {Largest =max(B2:E7) Smallest =min(B2:E7) {Growth} =round((E9-B9)/B9*1000)/10}
    {{} {} {} {} {} {} {}}
    {Checks =sqrt(B2)*2 =B4/C4 =Z20000 =hypot(3,4) =pow(2,10)}
}
set r 0
foreach row $ss::rows {
    set c 0
    foreach f $row {
        if {$f ne ""} { ss::put [ss::name $r $c] $f 0 }
        incr c
    }
    incr r
}
foreach cell {B2 B3 B4 B5 B6 B7 C2 C3 C4 C5 C6 C7 D2 D3 D4 D5 D6 D7 E2 E3 E4 E5 E6 E7 F2 F3 F4 F5 F6 F7 B9 C9 D9 E9 F9} {
    set ss::fmt($cell) thousands
}
foreach cell {B10 C10 D10 E10 F10} { set ss::fmt($cell) fixed }
foreach cell {G2 G3 G4 G5 G6 G7 G9} { set ss::fmt($cell) percent }
ss::recalc [array names ss::raw]
ss::layout
ss::render 1
ss::setcur 1 1
focus .c
wm geometry . 720x470
