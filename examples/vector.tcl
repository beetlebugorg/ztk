# A vector drawing tool on a canvas: shapes, handles that move, resize,
# and rotate, a properties panel, undo, SVG export, and a console that
# runs Tcl on the drawing in a child interpreter with limits. It runs in
# ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load vector.css
}
wm title . "Vector"
set ztk [llength [info commands ::ztk::class]]
proc cls {w args} {
    if {$::ztk} { ::ztk::class $w add {*}$args }
}

namespace eval vec {
    variable S             ;# shape id -> dict of type, pts, fill, stroke, width, opacity, angle, text, group
    array set S {}
    variable order {}      ;# the shape ids from the bottom to the top
    variable sel {}        ;# the selected shape ids
    variable next 1        ;# the next shape id
    variable ngroup 1      ;# the next group number
    variable tool select
    variable zoom 0.8
    variable panx 36
    variable pany 30
    variable snap 1
    variable GRID 10
    variable W 640         ;# the size of the page
    variable H 440
    variable undo {}
    variable redo {}
    variable mode ""       ;# the drag in progress
    variable pfill #60a5fa
    variable pstroke #1e3a8a
    variable pwidth 2
    variable popacity 100
    variable ptext "Text"
    variable conlines {}
    variable conout ""
    variable history {}
    variable hpos -1
    variable cmd ""
    variable saved ""
    variable svg ""
    variable space 0
    variable P
    if {[llength [info commands ::ztk::style]] && [::ztk::style scheme] eq "dark"} {
        array set P {desk #121418 page #ffffff grid #edf0f4 accent #60a5fa handle #1b1e24}
    } else {
        array set P {desk #e9ecf1 page #ffffff grid #edf0f4 accent #2563eb handle #ffffff}
    }
    variable names
    array set names {black #000000 white #ffffff red #ff0000 green #008000 blue #0000ff
        yellow #ffff00 orange #ffa500 purple #800080 gray #808080 grey #808080
        pink #ffc0cb cyan #00ffff magenta #ff00ff brown #a52a2a navy #000080 teal #008080}
}

# ---- Colors ----

# The red, green, and blue of a color, or {} for a color with no known value.
proc vec::rgb {color} {
    variable names
    set c [string tolower $color]
    if {[info exists names($c)]} { set c $names($c) }
    if {[regexp {^#([0-9a-f])([0-9a-f])([0-9a-f])$} $c -> r g b]} { set c "#$r$r$g$g$b$b" }
    if {![regexp {^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$} $c -> r g b]} { return {} }
    return [list [scan $r %x] [scan $g %x] [scan $b %x]]
}

# A color mixed with the white of the page, for the opacity of a shape.
proc vec::blend {color opacity} {
    if {$color eq "" || $opacity >= 1.0} { return $color }
    set c [rgb $color]
    if {$c eq ""} { return $color }
    set out #
    foreach v $c { append out [format %02x [expr {round($v * $opacity + 255 * (1.0 - $opacity))}]] }
    return $out
}

# ---- The model ----

# The points of a shape in page units, with the rotation of a box applied.
proc vec::points {id} {
    variable S
    set s $S($id)
    set pts [dict get $s pts]
    set type [dict get $s type]
    set a [dict get $s angle]
    if {$type eq "rect" || $type eq "ellipse"} {
        lassign $pts x0 y0 x1 y1
        set cx [expr {($x0 + $x1) / 2.0}]; set cy [expr {($y0 + $y1) / 2.0}]
        set rx [expr {($x1 - $x0) / 2.0}]; set ry [expr {($y1 - $y0) / 2.0}]
        set t [expr {$a * acos(-1) / 180.0}]
        set ca [expr {cos($t)}]; set sa [expr {sin($t)}]
        set out {}
        if {$type eq "rect"} {
            foreach {u v} {-1 -1 1 -1 1 1 -1 1} {
                set dx [expr {$u * $rx}]; set dy [expr {$v * $ry}]
                lappend out [expr {$cx + $dx * $ca - $dy * $sa}] [expr {$cy + $dx * $sa + $dy * $ca}]
            }
        } else {
            for {set i 0} {$i < 48} {incr i} {
                set e [expr {$i * acos(-1) / 24.0}]
                set dx [expr {$rx * cos($e)}]; set dy [expr {$ry * sin($e)}]
                lappend out [expr {$cx + $dx * $ca - $dy * $sa}] [expr {$cy + $dx * $sa + $dy * $ca}]
            }
        }
        return $out
    }
    return $pts
}

# Page units to canvas units.
proc vec::toscreen {pts} {
    variable zoom; variable panx; variable pany
    set out {}
    foreach {x y} $pts { lappend out [expr {$x * $zoom + $panx}] [expr {$y * $zoom + $pany}] }
    return $out
}

proc vec::topage {x y} {
    variable zoom; variable panx; variable pany
    return [list [expr {([.c canvasx $x] - $panx) / $zoom}] [expr {([.c canvasy $y] - $pany) / $zoom}]]
}

proc vec::snapped {x y} {
    variable snap; variable GRID
    if {!$snap} { return [list $x $y] }
    return [list [expr {round($x / $GRID) * $GRID}] [expr {round($y / $GRID) * $GRID}]]
}

# Makes the canvas items of a shape again. STACK 0 leaves the item on top,
# for a redraw of all shapes in order.
proc vec::draw {id {stack 1}} {
    variable S; variable order; variable zoom
    .c delete s$id
    set s $S($id)
    set type [dict get $s type]
    set o [expr {[dict get $s opacity] / 100.0}]
    set fill [blend [dict get $s fill] $o]
    set stroke [blend [dict get $s stroke] $o]
    set w [dict get $s width]
    set tags [list doc shape s$id]
    set xy [toscreen [points $id]]
    switch -- $type {
        rect {
            if {[dict get $s angle] == 0} {
                .c create rectangle {*}[toscreen [dict get $s pts]] -fill $fill -outline $stroke -width $w -tags $tags
            } else {
                .c create polygon {*}$xy -fill $fill -outline $stroke -width $w -tags $tags
            }
        }
        ellipse {
            if {[dict get $s angle] == 0} {
                .c create oval {*}[toscreen [dict get $s pts]] -fill $fill -outline $stroke -width $w -tags $tags
            } else {
                .c create polygon {*}$xy -fill $fill -outline $stroke -width $w -tags $tags
            }
        }
        line - polyline {
            .c create line {*}$xy -fill $stroke -width $w -capstyle round -joinstyle round -tags $tags
        }
        free {
            .c create line {*}$xy -fill $stroke -width $w -capstyle round -joinstyle round -smooth 1 -tags $tags
        }
        polygon {
            .c create polygon {*}$xy -fill $fill -outline $stroke -width $w -tags $tags
        }
        text {
            .c create text {*}$xy -text [dict get $s text] -fill [expr {$fill eq "" ? $stroke : $fill}] -anchor nw -tags $tags
        }
    }
    if {$stack && [lindex $order end] ne $id} {
        set i [lsearch -exact $order $id]
        foreach above [lrange $order [expr {$i + 1}] end] {
            if {[llength [.c find withtag s$above]]} { .c lower s$id s$above; break }
        }
    }
    if {$stack} { .c raise ui }
}

proc vec::redraw {} {
    variable order
    .c delete shape
    foreach id $order { draw $id 0 }
    .c raise ui
    handles
}

# Adds a shape and returns its id. OPTS are -fill, -stroke, -width,
# -opacity, -angle, and -text.
proc vec::add {type pts args} {
    variable S; variable order; variable next
    variable pfill; variable pstroke; variable pwidth; variable popacity
    set id $next
    incr next
    set s [dict create type $type pts $pts fill $pfill stroke $pstroke width $pwidth \
        opacity $popacity angle 0 text "" group ""]
    if {$type in {line polyline free}} { dict set s fill "" }
    set S($id) $s
    lappend order $id
    configure $id {*}$args
    return $id
}

proc vec::configure {id args} {
    variable S
    foreach {o v} $args {
        switch -- $o {
            -fill { dict set S($id) fill $v }
            -stroke - -outline { dict set S($id) stroke $v }
            -width { dict set S($id) width [expr {max(0, double($v))}] }
            -opacity { dict set S($id) opacity [expr {max(0, min(100, double($v)))}] }
            -angle { dict set S($id) angle [expr {double($v)}] }
            -text { dict set S($id) text $v }
            default { error "bad option \"$o\": must be -angle, -fill, -opacity, -stroke, -text, or -width" }
        }
    }
    draw $id
}

proc vec::remove {ids} {
    variable S; variable order; variable sel
    foreach id $ids {
        .c delete s$id
        unset -nocomplain S($id)
        set order [lsearch -all -inline -exact -not $order $id]
    }
    set sel [lmap id $sel { if {[info exists S($id)]} { set id } else continue }]
    handles
}

# Moves shapes by a distance in page units.
proc vec::shift {ids dx dy} {
    variable S; variable zoom
    foreach id $ids {
        set pts {}
        foreach {x y} [dict get $S($id) pts] { lappend pts [expr {$x + $dx}] [expr {$y + $dy}] }
        dict set S($id) pts $pts
        .c move s$id [expr {$dx * $zoom}] [expr {$dy * $zoom}]
    }
}

# ---- Undo ----

proc vec::state {} {
    variable S; variable order; variable next
    return [list [array get S] $order $next]
}

proc vec::restore {st} {
    variable S; variable order; variable next; variable sel
    array unset S
    array set S [lindex $st 0]
    set order [lindex $st 1]
    set next [lindex $st 2]
    set sel [lmap id $sel { if {[info exists S($id)]} { set id } else continue }]
    redraw
}

# Keeps the drawing before a change, for undo.
proc vec::checkpoint {} {
    variable undo; variable redo
    lappend undo [state]
    if {[llength $undo] > 100} { set undo [lrange $undo end-99 end] }
    set redo {}
}

proc vec::undo {} {
    variable undo; variable redo
    if {![llength $undo]} return
    lappend redo [state]
    restore [lindex $undo end]
    set undo [lrange $undo 0 end-1]
}

proc vec::redo {} {
    variable undo; variable redo
    if {![llength $redo]} return
    lappend undo [state]
    restore [lindex $redo end]
    set redo [lrange $redo 0 end-1]
}

# ---- The window ----

frame .tools -padx 8 -pady 8
pack .tools -side left -fill y
cls .tools panel
foreach {t label} {select Select rect Rectangle ellipse Ellipse line Line polyline Polyline polygon Polygon free Freehand text Text} {
    radiobutton .tools.$t -text $label -variable vec::tool -value $t -indicatoron 0 -anchor w -command vec::cancel
    pack .tools.$t -fill x -pady 1
    cls .tools.$t tool
}
frame .tools.gap -height 10
pack .tools.gap
button .tools.undo -text Undo -command vec::undo
button .tools.redo -text Redo -command vec::redo
pack .tools.undo .tools.redo -fill x -pady 2
label .tools.ll -text Layers -anchor w
listbox .tools.layers -height 8 -width 10 -selectmode extended -exportselection 0 -activestyle none
pack .tools.ll -fill x -pady {12 2}
pack .tools.layers -fill both -expand 1
cls .tools.ll heading
bind .tools.layers <<ListboxSelect>> vec::picklayers

frame .props -padx 10 -pady 8
pack .props -side right -fill y
cls .props panel
label .props.h -text Properties -anchor w
pack .props.h -fill x
cls .props.h heading

# A row of color swatches on a small canvas.
proc vec::swatches {w var} {
    canvas $w -width 152 -height 22 -highlightthickness 0 -borderwidth 0
    set x 1
    foreach c {"" #1e293b #ef4444 #f59e0b #22c55e #60a5fa #a855f7} {
        if {$c eq ""} {
            $w create rectangle $x 1 [expr {$x + 19}] 20 -fill #ffffff -outline #9ca3af -tags none
            $w create line [expr {$x + 2}] 19 [expr {$x + 17}] 2 -fill #ef4444 -width 2 -tags none
            $w bind none <Button-1> [list vec::setprop $var ""]
        } else {
            set i [$w create rectangle $x 1 [expr {$x + 19}] 20 -fill $c -outline #9ca3af]
            $w bind $i <Button-1> [list vec::setprop $var $c]
        }
        incr x 22
    }
    return $w
}

label .props.fl -text Fill -anchor w
entry .props.f -textvariable vec::pfill -width 10
vec::swatches .props.fs pfill
label .props.sl -text Stroke -anchor w
entry .props.s -textvariable vec::pstroke -width 10
vec::swatches .props.ss pstroke
label .props.wl -text Width -anchor w
scale .props.w -orient horizontal -from 0 -to 16 -resolution 1 -variable vec::pwidth -showvalue 1 -command {vec::setprop pwidth}
label .props.ol -text Opacity -anchor w
scale .props.o -orient horizontal -from 0 -to 100 -resolution 5 -variable vec::popacity -showvalue 1 -command {vec::setprop popacity}
pack .props.fl .props.f .props.fs .props.sl .props.s .props.ss .props.wl .props.w .props.ol .props.o -fill x -pady 1
bind .props.f <Return> {vec::setprop pfill $vec::pfill}
bind .props.s <Return> {vec::setprop pstroke $vec::pstroke}
frame .props.order
button .props.order.up -text Raise -command {vec::zorder raise}
button .props.order.down -text Lower -command {vec::zorder lower}
pack .props.order.up .props.order.down -side left -fill x -expand 1 -padx 1
frame .props.grp
button .props.grp.g -text Group -command vec::group
button .props.grp.u -text Ungroup -command vec::ungroup
pack .props.grp.g .props.grp.u -side left -fill x -expand 1 -padx 1
checkbutton .props.snap -text "Snap to grid" -variable vec::snap -anchor w
frame .props.file
button .props.file.svg -text "Export SVG" -command vec::exportsvg
button .props.file.save -text Save -command vec::save
button .props.file.load -text Load -command vec::load
pack .props.file.svg -fill x -pady 1
pack .props.file.save .props.file.load -side left -fill x -expand 1 -padx 1
pack .props.order .props.grp .props.snap .props.file -fill x -pady {6 0}

# The console: an output area and an entry with a history.
frame .con -padx 10 -pady 6
pack .con -side bottom -fill x
cls .con console
label .con.out -textvariable vec::conout -anchor nw -justify left -height 3
frame .con.line
label .con.line.p -text "%"
entry .con.line.e -textvariable vec::cmd
pack .con.line.p -side left
pack .con.line.e -side left -fill x -expand 1 -padx {6 0}
pack .con.out -fill x
pack .con.line -fill x
cls .con.out conout
cls .con.line.p muted

canvas .c -width 560 -height 380 -highlightthickness 0 -borderwidth 0 -background $vec::P(desk) -takefocus 1
pack .c -side top -fill both -expand 1

# The page and its grid. The grid lines are thin rectangles, which draw
# as one box each.
proc vec::page {} {
    variable W; variable H; variable P; variable GRID
    .c delete page
    .c create rectangle {*}[toscreen [list 0 0 $W $H]] -fill $P(page) -outline "" -tags {doc page}
    for {set x [expr {$GRID * 4}]} {$x < $W} {incr x [expr {$GRID * 4}]} {
        .c create rectangle {*}[toscreen [list $x 0 [expr {$x + 1}] $H]] -fill $P(grid) -outline "" -tags {doc page grid}
    }
    for {set y [expr {$GRID * 4}]} {$y < $H} {incr y [expr {$GRID * 4}]} {
        .c create rectangle {*}[toscreen [list 0 $y $W [expr {$y + 1}]]] -fill $P(grid) -outline "" -tags {doc page grid}
    }
    .c lower page
}

# ---- Selection and handles ----

# The box of the selection in canvas units, or {}. It comes from the
# points of the shapes, so the stroke width is not in it.
proc vec::selbox {} {
    variable sel; variable S
    set xs {}; set ys {}
    foreach id $sel {
        if {[dict get $S($id) type] eq "text"} {
            set xy [.c bbox s$id]
        } else {
            set xy [toscreen [points $id]]
        }
        foreach {x y} $xy { lappend xs $x; lappend ys $y }
    }
    if {![llength $xs]} { return {} }
    set xs [lsort -real $xs]; set ys [lsort -real $ys]
    return [list [lindex $xs 0] [lindex $ys 0] [lindex $xs end] [lindex $ys end]]
}

# Fills the layer list from the shapes, the top shape first, and shows
# the selection in it. The rows change only when the shapes change.
proc vec::layers {} {
    variable order; variable sel; variable S; variable layerrows
    set rows {}
    foreach id [lreverse $order] {
        set label "[string totitle [dict get $S($id) type]] $id"
        if {[dict get $S($id) group] ne ""} { append label "  (group [dict get $S($id) group])" }
        lappend rows $label
    }
    if {![info exists layerrows] || $rows ne $layerrows} {
        set layerrows $rows
        .tools.layers delete 0 end
        .tools.layers insert end {*}$rows
    }
    .tools.layers selection clear 0 end
    set n [llength $order]
    foreach id $sel {
        set i [lsearch -exact $order $id]
        if {$i >= 0} { .tools.layers selection set [expr {$n - 1 - $i}] }
    }
}

# A pick in the layer list selects the shapes of its rows.
proc vec::picklayers {} {
    variable order
    set n [llength $order]
    set ids {}
    foreach i [.tools.layers curselection] { lappend ids [lindex $order [expr {$n - 1 - $i}]] }
    select $ids
}

proc vec::handles {} {
    variable P
    layers
    .c delete ui
    set box [selbox]
    if {$box eq ""} { props; return }
    lassign $box x0 y0 x1 y1
    set xm [expr {($x0 + $x1) / 2.0}]; set ym [expr {($y0 + $y1) / 2.0}]
    .c create rectangle $x0 $y0 $x1 $y1 -outline $P(accent) -dash {4 3} -tags ui
    .c create line $xm $y0 $xm [expr {$y0 - 22}] -fill $P(accent) -tags ui
    .c create oval [expr {$xm - 5}] [expr {$y0 - 27}] [expr {$xm + 5}] [expr {$y0 - 17}] \
        -fill $P(handle) -outline $P(accent) -width 1.5 -tags {ui handle rot}
    set i 0
    foreach {hx hy} [list $x0 $y0 $xm $y0 $x1 $y0 $x1 $ym $x1 $y1 $xm $y1 $x0 $y1 $x0 $ym] {
        .c create rectangle [expr {$hx - 4}] [expr {$hy - 4}] [expr {$hx + 4}] [expr {$hy + 4}] \
            -fill $P(handle) -outline $P(accent) -width 1.5 -tags [list ui handle h$i]
        incr i
    }
    props
}

# Shows the properties of the first selected shape in the panel.
proc vec::props {} {
    variable sel; variable S
    variable pfill; variable pstroke; variable pwidth; variable popacity
    if {![llength $sel]} return
    set s $S([lindex $sel 0])
    set pfill [dict get $s fill]
    set pstroke [dict get $s stroke]
    set pwidth [expr {round([dict get $s width])}]
    set popacity [expr {round([dict get $s opacity])}]
}

# The shape ids of a selection with each group made whole.
proc vec::withgroups {ids} {
    variable S; variable order
    set groups {}
    foreach id $ids {
        set g [dict get $S($id) group]
        if {$g ne "" && $g ni $groups} { lappend groups $g }
    }
    if {![llength $groups]} { return $ids }
    set out {}
    foreach id $order {
        if {$id in $ids || [dict get $S($id) group] in $groups} { lappend out $id }
    }
    return $out
}

proc vec::select {ids} {
    variable sel
    set sel [withgroups $ids]
    handles
}

# The top shape under a point of the canvas, or "".
proc vec::shapeat {x y} {
    set cx [.c canvasx $x]; set cy [.c canvasy $y]
    set hit ""
    foreach item [.c find overlapping [expr {$cx - 3}] [expr {$cy - 3}] [expr {$cx + 3}] [expr {$cy + 3}]] {
        foreach t [.c gettags $item] {
            if {[regexp {^s([0-9]+)$} $t -> id]} { set hit $id }
        }
    }
    return $hit
}

# The handle under a point of the canvas: rot, a number from 0 to 7, or "".
proc vec::handleat {x y} {
    set cx [.c canvasx $x]; set cy [.c canvasy $y]
    set hit ""
    foreach item [.c find overlapping [expr {$cx - 1}] [expr {$cy - 1}] [expr {$cx + 1}] [expr {$cy + 1}]] {
        foreach t [.c gettags $item] {
            if {$t eq "rot"} { set hit rot } elseif {[regexp {^h([0-7])$} $t -> n]} { set hit $n }
        }
    }
    return $hit
}

# A property of the panel changed: it goes to each selected shape.
proc vec::setprop {var value} {
    variable sel; variable S
    variable $var
    set $var $value
    if {![llength $sel]} return
    set key [dict get {pfill fill pstroke stroke pwidth width popacity opacity} $var]
    set changed 0
    foreach id $sel { if {[dict get $S($id) $key] ne $value} { set changed 1 } }
    if {!$changed} return
    checkpoint
    foreach id $sel { configure $id -$key $value }
    handles
}

proc vec::zorder {how} {
    variable sel; variable order
    if {![llength $sel]} return
    checkpoint
    set rest [lmap id $order { if {$id in $sel} continue; set id }]
    set mine [lmap id $order { if {$id ni $sel} continue; set id }]
    if {$how eq "raise"} {
        set order [concat $rest $mine]
        foreach id $mine { .c raise s$id }
    } else {
        set order [concat $mine $rest]
        foreach id [lreverse $mine] { .c raise s$id page }
    }
    .c raise ui
}

proc vec::group {} {
    variable sel; variable S; variable ngroup
    if {[llength $sel] < 2} return
    checkpoint
    set g g$ngroup
    incr ngroup
    foreach id $sel { dict set S($id) group $g }
}

proc vec::ungroup {} {
    variable sel; variable S
    if {![llength $sel]} return
    checkpoint
    foreach id $sel { dict set S($id) group "" }
}

# ---- The mouse ----

proc vec::press {x y shift} {
    variable tool; variable mode; variable sel; variable S; variable space
    variable start; variable orig; variable box0; variable poly
    focus .c
    set start [list $x $y]
    if {$space} { set mode pan; .c scan mark $x $y; return }
    set p [topage $x $y]
    if {$tool eq "select"} {
        set h [handleat $x $y]
        if {$h ne ""} {
            set box0 [selbox]
            set orig {}
            foreach id $sel { lappend orig $id $S($id) }
            checkpoint
            set mode [expr {$h eq "rot" ? "rotate" : "resize $h"}]
            return
        }
        set id [shapeat $x $y]
        if {$id ne ""} {
            if {$shift} {
                set ids [withgroups [list $id]]
                if {$id in $sel} {
                    select [lmap s $sel { if {$s in $ids} continue; set s }]
                } else {
                    select [concat $sel $ids]
                }
                set mode ""
                return
            }
            if {$id ni $sel} { select [list $id] }
            checkpoint
            set orig [snapped {*}$p]
            set mode move
            return
        }
        if {!$shift} { select {} }
        set mode band
        .c create rectangle $x $y $x $y -outline $vec::P(accent) -dash {2 2} -tags {ui band}
        return
    }
    set p [snapped {*}$p]
    switch -- $tool {
        rect - ellipse - line - free {
            set mode draw
            set poly $p
        }
        polyline - polygon {
            if {$mode ne "poly"} { set mode poly; set poly {} }
            lappend poly {*}$p
            preview
        }
        text { textat $x $y $p }
    }
}

proc vec::motion {x y} {
    variable mode; variable start; variable tool; variable poly; variable panx; variable pany
    variable sel; variable orig; variable zoom
    if {$mode eq ""} return
    set p [topage $x $y]
    switch -glob -- $mode {
        pan {
            # The view moves, and the items keep their coordinates.
            .c scan dragto $x $y 1
        }
        move {
            lassign $orig ox oy
            lassign [snapped {*}$p] nx ny
            set dx [expr {$nx - $ox}]; set dy [expr {$ny - $oy}]
            if {$dx != 0 || $dy != 0} {
                shift $sel $dx $dy
                .c move ui [expr {$dx * $zoom}] [expr {$dy * $zoom}]
                set orig [list $nx $ny]
            }
        }
        band {
            lassign $start x0 y0
            .c coords band [.c canvasx $x0] [.c canvasy $y0] [.c canvasx $x] [.c canvasy $y]
        }
        draw {
            if {$tool eq "free"} {
                lassign [lrange $poly end-1 end] lx ly
                lassign $p px py
                if {hypot($px - $lx, $py - $ly) > 2.0 / $zoom} { lappend poly $px $py }
            } else {
                set poly [concat [lrange $poly 0 1] [snapped {*}$p]]
            }
            preview
        }
        poly { preview [snapped {*}$p] }
        rotate { rotateto $x $y }
        resize* { resizeto [lindex $mode 1] $x $y }
    }
}

proc vec::release {x y shift} {
    variable mode; variable tool; variable poly; variable sel
    switch -glob -- $mode {
        band {
            set ids {}
            lassign [.c coords band] x0 y0 x1 y1
            foreach item [.c find enclosed [expr {min($x0, $x1)}] [expr {min($y0, $y1)}] [expr {max($x0, $x1)}] [expr {max($y0, $y1)}]] {
                foreach t [.c gettags $item] { if {[regexp {^s([0-9]+)$} $t -> id]} { lappend ids $id } }
            }
            .c delete band
            select [concat [expr {$shift ? $sel : ""}] $ids]
        }
        draw {
            .c delete preview
            set mode ""
            finish
            return
        }
        poly return
        move - rotate - resize* { handles }
    }
    set mode ""
}

# The outline of a shape that the user draws.
proc vec::preview {{extra {}}} {
    variable poly; variable tool; variable P
    .c delete preview
    set pts [concat $poly $extra]
    if {[llength $pts] < 4} return
    set xy [toscreen $pts]
    switch -- $tool {
        rect { .c create rectangle {*}[lrange $xy 0 3] -outline $P(accent) -dash {4 3} -tags {ui preview} }
        ellipse { .c create oval {*}[lrange $xy 0 3] -outline $P(accent) -dash {4 3} -tags {ui preview} }
        default { .c create line {*}$xy -fill $P(accent) -width 1.5 -tags {ui preview} }
    }
}

# Makes the shape of the drawing tool from the points.
proc vec::finish {} {
    variable poly; variable tool; variable mode
    .c delete preview
    set pts $poly
    set mode ""
    set poly {}
    if {$tool in {polyline polygon}} {
        # A double click adds the last point two times.
        if {[llength $pts] >= 4 && [lrange $pts end-3 end-2] eq [lrange $pts end-1 end]} { set pts [lrange $pts 0 end-2] }
        if {[llength $pts] < ($tool eq "polygon" ? 6 : 4)} return
    } elseif {$tool in {rect ellipse}} {
        lassign $pts x0 y0 x1 y1
        if {abs($x1 - $x0) < 2 || abs($y1 - $y0) < 2} return
        set pts [list [expr {min($x0, $x1)}] [expr {min($y0, $y1)}] [expr {max($x0, $x1)}] [expr {max($y0, $y1)}]]
    } elseif {[llength $pts] < 4} {
        return
    }
    checkpoint
    select [list [add $tool $pts]]
}

proc vec::cancel {} {
    variable mode; variable poly
    .c delete preview
    set mode ""
    set poly {}
    place forget .c.text
}

# The text tool: an entry at the point, and Return makes the text shape.
entry .c.text -width 16
proc vec::textat {x y p} {
    variable textpos
    set textpos $p
    .c.text delete 0 end
    place .c.text -x $x -y $y
    focus .c.text
}
proc vec::textdone {} {
    variable textpos
    set t [.c.text get]
    place forget .c.text
    focus .c
    if {$t eq ""} return
    checkpoint
    select [list [add text $textpos -text $t]]
}
bind .c.text <Return> vec::textdone
bind .c.text <Escape> vec::cancel

# Rotates the selection about the center of its box, from the angle at the press.
proc vec::rotateto {x y} {
    variable box0; variable orig; variable start; variable S; variable snap; variable zoom; variable panx; variable pany
    lassign $box0 x0 y0 x1 y1
    set cx [expr {($x0 + $x1) / 2.0}]; set cy [expr {($y0 + $y1) / 2.0}]
    lassign $start sx sy
    set a0 [expr {atan2([.c canvasy $sy] - $cy, [.c canvasx $sx] - $cx)}]
    set a1 [expr {atan2([.c canvasy $y] - $cy, [.c canvasx $x] - $cx)}]
    set deg [expr {($a1 - $a0) * 180.0 / acos(-1)}]
    if {$snap} { set deg [expr {round($deg / 15.0) * 15.0}] }
    set pcx [expr {($cx - $panx) / $zoom}]; set pcy [expr {($cy - $pany) / $zoom}]
    foreach {id s} $orig { set S($id) [rotated $s $pcx $pcy $deg]; draw $id }
}

# A shape dict rotated by DEG about a point.
proc vec::rotated {s cx cy deg} {
    set t [expr {$deg * acos(-1) / 180.0}]
    set ca [expr {cos($t)}]; set sa [expr {sin($t)}]
    set type [dict get $s type]
    if {$type in {rect ellipse text}} {
        set pts [dict get $s pts]
        lassign $pts x0 y0 x1 y1
        if {$type eq "text"} { set x1 $x0; set y1 $y0 }
        set mx [expr {($x0 + $x1) / 2.0}]; set my [expr {($y0 + $y1) / 2.0}]
        set nx [expr {$cx + ($mx - $cx) * $ca - ($my - $cy) * $sa}]
        set ny [expr {$cy + ($mx - $cx) * $sa + ($my - $cy) * $ca}]
        set out {}
        foreach {x y} $pts { lappend out [expr {$x + $nx - $mx}] [expr {$y + $ny - $my}] }
        dict set s pts $out
        if {$type ne "text"} { dict set s angle [expr {fmod([dict get $s angle] + $deg, 360.0)}] }
        return $s
    }
    set out {}
    foreach {x y} [dict get $s pts] {
        lappend out [expr {$cx + ($x - $cx) * $ca - ($y - $cy) * $sa}] [expr {$cy + ($x - $cx) * $sa + ($y - $cy) * $ca}]
    }
    dict set s pts $out
    return $s
}

# Scales the selection from the side or the corner across from handle H.
proc vec::resizeto {h x y} {
    variable box0; variable orig; variable S; variable zoom; variable panx; variable pany
    lassign $box0 x0 y0 x1 y1
    set cx [.c canvasx $x]; set cy [.c canvasy $y]
    lassign [snapped [expr {($cx - $panx) / $zoom}] [expr {($cy - $pany) / $zoom}]] px py
    set cx [expr {$px * $zoom + $panx}]; set cy [expr {$py * $zoom + $pany}]
    # The handles go clockwise from the top left corner.
    set ax [lindex {x1 - x0 x0 x0 - x1 x1} $h]; set ay [lindex {y1 y1 y1 - y0 y0 y0 -} $h]
    set fx 1.0; set fy 1.0
    if {$ax ne "-"} {
        set a [set $ax]; set b [expr {$ax eq "x1" ? $x0 : $x1}]
        if {abs($b - $a) > 0.5} { set fx [expr {($cx - $a) / double($b - $a)}] }
    }
    if {$ay ne "-"} {
        set a [set $ay]; set b [expr {$ay eq "y1" ? $y0 : $y1}]
        if {abs($b - $a) > 0.5} { set fy [expr {($cy - $a) / double($b - $a)}] }
    }
    set ox [expr {(($ax eq "-" ? $x0 : [set $ax]) - $panx) / $zoom}]
    set oy [expr {(($ay eq "-" ? $y0 : [set $ay]) - $pany) / $zoom}]
    foreach {id s} $orig {
        set pts {}
        foreach {px py} [dict get $s pts] { lappend pts [expr {$ox + ($px - $ox) * $fx}] [expr {$oy + ($py - $oy) * $fy}] }
        if {[dict get $s type] in {rect ellipse}} {
            lassign $pts a b c d
            set pts [list [expr {min($a, $c)}] [expr {min($b, $d)}] [expr {max($a, $c)}] [expr {max($b, $d)}]]
        }
        dict set s pts $pts
        set S($id) $s
        draw $id
    }
}

# Zooms about a point of the canvas. The items scale on the canvas, and
# the stroke widths and the text keep their size.
proc vec::zoomby {f x y} {
    variable zoom; variable panx; variable pany
    set nz [expr {max(0.1, min(16.0, $zoom * $f))}]
    set f [expr {$nz / $zoom}]
    set cx [.c canvasx $x]; set cy [.c canvasy $y]
    .c scale doc $cx $cy $f $f
    set zoom $nz
    set panx [expr {$cx + ($panx - $cx) * $f}]
    set pany [expr {$cy + ($pany - $cy) * $f}]
    handles
}

bind .c <Button-1> {vec::press %x %y 0}
bind .c <Shift-Button-1> {vec::press %x %y 1}
bind .c <B1-Motion> {vec::motion %x %y}
bind .c <ButtonRelease-1> {vec::release %x %y 0}
bind .c <Shift-ButtonRelease-1> {vec::release %x %y 1}
# The second press of a double click ends a polyline or a polygon, and
# in the other tools it is a press.
bind .c <Double-Button-1> {if {$vec::mode eq "poly"} vec::finish else {vec::press %x %y 0}}
bind .c <Shift-Double-Button-1> {vec::press %x %y 1}
bind .c <Button-2> {set vec::space 1; vec::press %x %y 0}
bind .c <B2-Motion> {vec::motion %x %y}
bind .c <ButtonRelease-2> {set vec::space 0; set vec::mode ""}
bind .c <Motion> {if {$vec::mode eq "poly"} {vec::motion %x %y}}
bind .c <MouseWheel> {vec::zoomby [expr {pow(1.1, %D / 120.0)}] %x %y; break}
bind .c <KeyPress-space> {set vec::space 1}
bind .c <KeyRelease-space> {set vec::space 0}
bind .c <Return> {if {$vec::mode eq "poly"} vec::finish}
bind .c <Escape> vec::cancel
bind .c <Delete> {if {[llength $vec::sel]} {vec::checkpoint; vec::remove $vec::sel}}

# The menu bar, and the context menu of the page.
menu .menubar -tearoff 0
. configure -menu .menubar
foreach {m t} {file File edit Edit arrange Arrange} {
    menu .menubar.$m -tearoff 0
    .menubar add cascade -label $t -menu .menubar.$m -underline 0
}
.menubar.file add command -label Save -command vec::save
.menubar.file add command -label Load -command vec::load
.menubar.file add separator
.menubar.file add command -label "Export SVG" -command vec::exportsvg
.menubar.edit add command -label Undo -command vec::undo
.menubar.edit add command -label Redo -command vec::redo
.menubar.edit add separator
.menubar.edit add command -label Delete -accelerator Delete -command {if {[llength $vec::sel]} {vec::checkpoint; vec::remove $vec::sel}}
.menubar.arrange add command -label Raise -command {vec::zorder raise}
.menubar.arrange add command -label Lower -command {vec::zorder lower}
.menubar.arrange add separator
.menubar.arrange add command -label Group -command vec::group
.menubar.arrange add command -label Ungroup -command vec::ungroup
bind .c <Button-3> {tk_popup .menubar.arrange %X %Y}
bind .c <BackSpace> {if {[llength $vec::sel]} {vec::checkpoint; vec::remove $vec::sel}}
bind .c <Control-z> vec::undo
bind .c <Control-y> vec::redo
bind .c <Control-Z> vec::redo
bind .c <Control-g> vec::group
bind .c <Configure> vec::handles

# ---- SVG, save, and load ----

proc vec::esc {text} { return [string map {& &amp; < &lt; > &gt; \" &quot;} $text] }
proc vec::num {v} { return [format %g $v] }

# The drawing as an SVG document.
proc vec::svgtext {} {
    variable W; variable H; variable S; variable order
    set out "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"$W\" height=\"$H\" viewBox=\"0 0 $W $H\">\n"
    append out "  <rect width=\"$W\" height=\"$H\" fill=\"#ffffff\"/>\n"
    foreach id $order {
        set s $S($id)
        set fill [dict get $s fill]
        set paint "fill=\"[expr {$fill eq "" ? "none" : [esc $fill]}]\" stroke=\"[expr {[dict get $s stroke] eq "" || [dict get $s width] == 0 ? "none" : [esc [dict get $s stroke]]}]\" stroke-width=\"[num [dict get $s width]]\""
        set o [dict get $s opacity]
        if {$o < 100} { append paint " opacity=\"[num [expr {$o / 100.0}]]\"" }
        set g [dict get $s group]
        if {$g ne ""} { append paint " class=\"$g\"" }
        set pts [dict get $s pts]
        lassign $pts x0 y0 x1 y1
        set rot ""
        if {[dict get $s angle] != 0} {
            set rot " transform=\"rotate([num [dict get $s angle]] [num [expr {($x0 + $x1) / 2.0}]] [num [expr {($y0 + $y1) / 2.0}]])\""
        }
        set list [join [lmap {x y} $pts {format %s,%s [num $x] [num $y]}] " "]
        switch -- [dict get $s type] {
            rect { append out "  <rect id=\"s$id\" x=\"[num $x0]\" y=\"[num $y0]\" width=\"[num [expr {$x1 - $x0}]]\" height=\"[num [expr {$y1 - $y0}]]\" $paint$rot/>\n" }
            ellipse { append out "  <ellipse id=\"s$id\" cx=\"[num [expr {($x0 + $x1) / 2.0}]]\" cy=\"[num [expr {($y0 + $y1) / 2.0}]]\" rx=\"[num [expr {($x1 - $x0) / 2.0}]]\" ry=\"[num [expr {($y1 - $y0) / 2.0}]]\" $paint$rot/>\n" }
            line { append out "  <line id=\"s$id\" x1=\"[num $x0]\" y1=\"[num $y0]\" x2=\"[num $x1]\" y2=\"[num $y1]\" $paint stroke-linecap=\"round\"/>\n" }
            polyline - free { append out "  <polyline id=\"s$id\" points=\"$list\" $paint stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n" }
            polygon { append out "  <polygon id=\"s$id\" points=\"$list\" $paint/>\n" }
            text { append out "  <text id=\"s$id\" x=\"[num $x0]\" y=\"[num [expr {$y0 + 13}]]\" font-family=\"Inter, sans-serif\" font-size=\"13\" fill=\"[esc [expr {$fill eq "" ? [dict get $s stroke] : $fill}]]\">[esc [dict get $s text]]</text>\n" }
        }
    }
    append out "</svg>\n"
    return $out
}

proc vec::write {name text} {
    if {[llength [info commands open]]} {
        set f [open $name w]
        puts -nonewline $f $text
        close $f
        return "Wrote $name ([string length $text] bytes)."
    }
    return "Kept [string length $text] bytes in memory: this script has no file access."
}

proc vec::exportsvg {} {
    variable svg
    set svg [svgtext]
    log [write drawing.svg $svg]
}

# The own format: a first line, then one line for each shape, bottom to top.
proc vec::doc {} {
    variable order; variable S; variable W; variable H
    set out "ztk-vector 1 $W $H\n"
    foreach id $order { append out [list $id $S($id)] \n }
    return $out
}

proc vec::opendoc {text} {
    variable S; variable order; variable next; variable sel
    set lines [split [string trim $text] \n]
    if {![string match "ztk-vector 1 *" [lindex $lines 0]]} { error "not a drawing of this tool" }
    checkpoint
    array unset S
    set order {}; set sel {}; set next 1
    foreach line [lrange $lines 1 end] {
        lassign $line id s
        set S($id) $s
        lappend order $id
        set next [expr {max($next, $id + 1)}]
    }
    redraw
    return [llength $order]
}

proc vec::save {} {
    variable saved
    set saved [doc]
    log [write drawing.ztv $saved]
}

proc vec::load {} {
    variable saved
    set text $saved
    if {[llength [info commands open]] && ![catch {open drawing.ztv} f]} {
        set text [read $f]
        close $f
    }
    if {$text eq ""} { log "There is no saved drawing."; return }
    log "Loaded [opendoc $text] shapes."
}

# ---- The console ----

proc vec::log {text} {
    variable conlines; variable conout
    foreach line [split $text \n] { lappend conlines $line }
    set conlines [lrange $conlines end-199 end]
    set conout [join [lrange $conlines end-2 end] \n]
}

# The commands of a console script. They run in this interpreter, and the
# script calls them through the aliases of the child interpreter.
namespace eval vec::api {}
proc vec::api::shape {sub args} {
    switch -- $sub {
        rect - oval - ellipse {
            set opts [lassign $args x y w h]
            if {$h eq ""} { error "wrong # args: should be \"shape $sub x y w h ?-option value ...?\"" }
            set type [expr {$sub eq "rect" ? "rect" : "ellipse"}]
            return [vec::add $type [list $x $y [expr {$x + $w}] [expr {$y + $h}]] {*}$opts]
        }
        line - polyline - polygon {
            set i [lsearch -glob $args -*]
            if {$i < 0} { set i [llength $args] }
            set pts [lrange $args 0 [expr {$i - 1}]]
            if {[llength $pts] < 4 || [llength $pts] % 2} { error "shape $sub needs pairs of coordinates" }
            return [vec::add [expr {$sub eq "line" && [llength $pts] > 4 ? "polyline" : $sub}] $pts {*}[lrange $args $i end]]
        }
        text {
            set opts [lassign $args x y text]
            return [vec::add text [list $x $y] -text $text {*}$opts]
        }
        list { return $vec::order }
        get {
            lassign $args id key
            vec::api::known $id
            if {$key eq ""} { return $vec::S($id) }
            return [dict get $vec::S($id) [string trimleft $key -]]
        }
        config - configure {
            set opts [lassign $args id]
            vec::api::known $id
            vec::configure $id {*}$opts
            vec::handles
            return
        }
        delete { vec::remove $args; return }
        default { error "bad option \"$sub\": must be config, delete, ellipse, get, line, list, oval, polygon, polyline, rect, or text" }
    }
}
proc vec::api::known {id} {
    if {![info exists vec::S($id)]} { error "no shape \"$id\"" }
}
proc vec::api::select {args} {
    if {![llength $args]} { return $vec::sel }
    set ids [concat {*}$args]
    foreach id $ids { known $id }
    vec::select $ids
    return $vec::sel
}
proc vec::api::move {ids dx dy} {
    if {$ids eq "selection"} { set ids $vec::sel }
    foreach id $ids { known $id }
    vec::shift $ids $dx $dy
    vec::handles
}
proc vec::api::clear {} {
    vec::remove $vec::order
}
proc vec::api::puts {args} {
    vec::log [lindex $args end]
}

# The child interpreter of the console. It has the commands of ztcl and
# the aliases of the drawing.
proc vec::newconsole {} {
    catch {interp delete con}
    interp create con
    foreach c {shape select move clear puts} {
        interp alias con $c {} vec::api::$c
    }
    interp eval con {
        proc each {var body} {
            upvar 1 $var v
            foreach v [shape list] { uplevel 1 $body }
        }
    }
}

# Runs a script of the console with a step limit and a memory limit. A
# script that ends its steps or its memory gives an error here, and the
# app goes on.
proc vec::run {script} {
    variable history; variable hpos
    if {[string trim $script] eq ""} return
    log "% $script"
    checkpoint
    if {[llength [info commands ::ztk::limit]]} {
        set code [catch {::ztk::limit -steps 200000 -memory 16000000 [list interp eval con $script]} r]
    } else {
        # wish: a command limit, and a time limit for a loop with no commands.
        interp limit con time -seconds [expr {[clock seconds] + 2}]
        interp limit con command -value [expr {[interp eval con info cmdcount] + 200000}]
        set code [catch {interp eval con $script} r]
    }
    if {$code} {
        log "error: $r"
    } elseif {$r ne ""} {
        log $r
    }
    if {[lindex $history end] ne $script} { lappend history $script }
    set hpos [llength $history]
    handles
    return -code $code $r
}

proc vec::histmove {d} {
    variable history; variable hpos; variable cmd
    set hpos [expr {max(0, min([llength $history], $hpos + $d))}]
    set cmd [lindex $history $hpos]
    .con.line.e icursor end
}

bind .con.line.e <Return> {catch {vec::run $vec::cmd}; set vec::cmd ""}
bind .con.line.e <Up> {vec::histmove -1; break}
bind .con.line.e <Down> {vec::histmove 1; break}

# Three sample scripts in the history: Up in the console gives them.
set vec::history {
    {for {set i 0} {$i < 48} {incr i} {set a [expr {$i * 0.4}]; set r [expr {14 + $i * 3.2}]; shape oval [expr {320 + $r * cos($a) - 9}] [expr {220 + $r * sin($a) - 9}] 18 18 -fill [format #%02x%02x%02x [expr {250 - $i * 4}] [expr {90 + $i * 3}] 220] -width 0}}
    {for {set y 0} {$y < 4} {incr y} {for {set x 0} {$x < 6} {incr x} {shape rect [expr {40 + $x * 50}] [expr {40 + $y * 50}] 40 40 -fill [lindex {#f87171 #fbbf24 #34d399 #60a5fa} $y] -angle [expr {$x * 15}]}}}
    {each shape {if {[shape get $shape type] eq "ellipse"} {shape config $shape -opacity 60}}}
}
set vec::hpos [llength $vec::history]
vec::newconsole

# ---- The first drawing ----

proc vec::start {} {
    variable pfill; variable pstroke; variable pwidth
    page
    add rect {40 40 600 400} -fill #e0f2fe -stroke "" -width 0
    add ellipse {450 70 550 170} -fill #fbbf24 -stroke #f59e0b -width 3
    add polygon {40 400 200 190 320 330 420 230 600 400} -fill #34d399 -stroke #047857 -width 2
    add rect {90 300 170 360} -fill #f87171 -stroke #7f1d1d -width 2 -angle -12
    add free {70 120 100 100 130 112 160 96 190 110} -stroke #1e293b -width 3
    add line {230 110 330 80} -stroke #2563eb -width 4
    add text {60 52} -text "Valley at noon" -fill #0f172a
    set pfill #60a5fa; set pstroke #1e3a8a; set pwidth 2
    select 2
    log "Console: Tcl in a child interpreter with a step limit. Press Up for sample scripts."
    log "Commands: shape rect|oval|line|polygon|text|list|get|config|delete, select, move, each, clear."
}
vec::start
focus .c
wm geometry . 860x560
