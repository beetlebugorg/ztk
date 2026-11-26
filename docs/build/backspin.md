# Backspin, part by part

An agent builds [Backspin](../widgets/range.md#play-backspin) from five short prompts. Step through it with the arrow keys: each step adds one part, the code shows the new lines, and the handheld runs the game as it is at that step.

<!-- stage: toy-backspin -->

Each step runs in CI: `tests/replay.sh` runs its script and its check in `ztk --headless`.

## Taken apart

The same game as four layers: the canvas, the items on it, the scale, and the loop. Drag the slider, or press Explode, to pull the layers apart. A dashed arrow shows what drives what: the scale moves the paddle item through `-variable pos`, and the loop moves the ball with `box`, which sets the coordinates of an item. Hover a layer to mark its code. With reduced motion, Explode goes to the end at once.

<!-- live wide: 830x380 -->
```tcl
# Backspin, taken apart: drag the slider, or press Explode. Hover a layer to see its code.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
set bg #f7f5ff
canvas .c -width 560 -height 340 -bg $bg -highlightthickness 0
text .code -width 30 -height 19 -font {TkFixedFont 9} -wrap none -relief flat -background #1d1a33 -foreground #b9b4dc -padx 8 -pady 8
ttk::frame .bar
ttk::button .bar.go -text Explode -command toggle -width 10
ttk::scale .bar.e -from 0 -to 1 -variable e -command spread -length 240
ttk::label .bar.hint -text "Hover a layer"
pack .bar -side bottom -fill x -padx 8 -pady 6
pack .bar.go .bar.e .bar.hint -side left -padx 6
pack .c -side left
pack .code -side left -fill y
.code tag configure on -background #3a3560 -foreground #ffcf5c

# The layers, from the bottom: the name, the code lines, and what the
# layer has in it. Each layer is a flat card in an isometric view.
set layers {
    court {canvas: the court} {canvas .c -width $W -height $H} {px $x $y 4 8 4 ;# the net}
    items {items: paddles, ball} {.c addtag ball withtag [px ...]} {box me 6 $pos 8 $P}
    paddle {scale: your paddle} {scale .s -variable pos} {pack .s -side left}
    loop {after: the loop} {proc tick {} { ... }} {after 16 tick}
}
set code {}
foreach {id name a b} $layers { lappend code "# $name" $a $b "" }
.code insert end [join $code \n]
.code configure -state disabled

# A point of a card: u across, v deep, on the plane at height z.
proc iso {u v z} { list [expr {92 + $u * 0.95 + $v * 0.8}] [expr {176 + $v * 0.4 - $u * 0.24 - $z}] }
proc quad {u0 v0 u1 v1 z} { concat [iso $u0 $v0 $z] [iso $u1 $v0 $z] [iso $u1 $v1 $z] [iso $u0 $v1 $z] }

set z0 {court 0 items 0 paddle 0 loop 0}
set gap {court 0 items 56 paddle 112 loop 168}
proc card {id fill} {
    .c create polygon [quad 0 0 200 120 0] -fill $fill -outline #8b86b8 -width 1 -tags [list $id $id.card layer]
}
# The court: the dark field and the dashed net.
card court [lindex $ink 0]
for {set v 4} {$v < 120} {incr v 14} { .c create polygon [quad 98 $v 102 [expr {$v + 8}] 0] -fill [lindex $ink 4] -outline "" -tags {court layer} }
# The items: the two paddles, the ball, and the score, on a glass card.
card items ""
.c itemconfigure items.card -fill "" -outline #8b86b8 -dash {4 3}
.c create polygon [quad 6 40 12 70 0] -fill [lindex $ink 1] -outline "" -tags {items me layer}
.c create polygon [quad 188 50 194 80 0] -fill [lindex $ink 2] -outline "" -tags {items layer}
.c create polygon [quad 120 60 128 68 0] -fill [lindex $ink 3] -outline "" -tags {items ball layer}
# The scale: a slot and its slider, at the left edge.
card paddle ""
.c itemconfigure paddle.card -fill "" -outline ""
.c create polygon [quad -26 0 -14 120 0] -fill #d9d6ec -outline #8b86b8 -tags {paddle layer}
.c create polygon [quad -26 34 -14 64 0] -fill #6d5ce8 -outline "" -tags {paddle knob layer}
# The loop: a ring of arrows that runs each 16 ms.
card loop ""
.c itemconfigure loop.card -fill "" -outline ""
.c create polygon [quad 70 30 130 90 0] -fill "" -outline #ef5b5b -width 2 -dash {6 4} -tags {loop layer}
.c create text {*}[iso 100 60 0] -text "16ms" -fill #ef5b5b -font {TkFixedFont 9 bold} -tags {loop layer}

# The labels at the right, with a leader line to each layer, and the
# lines of what drives what.
foreach {id name a b} $layers {
    .c create line 0 0 0 0 -fill #8b86b8 -tags [list $id.lead lead]
    .c create text 0 0 -text $name -anchor w -fill #1d1a33 -font {TkDefaultFont 10 bold} -tags [list $id.label label]
}
.c create line 0 0 0 0 -fill #6d5ce8 -width 2 -arrow last -dash {5 3} -tags {drive1 drive}
.c create text 0 0 -text "-variable pos" -fill #6d5ce8 -font {TkFixedFont 9} -anchor ne -tags {drive1t drive}
.c create line 0 0 0 0 -fill #ef5b5b -width 2 -arrow last -dash {5 3} -tags {drive2 drive}
.c create text 0 0 -text "box, coords" -fill #ef5b5b -font {TkFixedFont 9} -anchor w -tags {drive2t drive}
.c lower court

# Place each layer at the height of the explode value e, from 0 (built)
# to 1 (apart), and the labels and lines with it.
set e 0
set at {court 0 items 0 paddle 0 loop 0}
proc spread {args} {
    global e at gap
    foreach {id g} $gap {
        # The stack also moves down as it opens, so that it stays in the middle.
        set want [expr {($g - 84) * $e}]
        .c move $id 0 [expr {[dict get $at $id] - $want}]
        dict set at $id $want
        # Each label is at the side of its layer, with a line to a point
        # that the layer shows: the scale is at the left of the court.
        lassign [dict get {court {200 60 r} items {200 60 r} paddle {-26 4 l} loop {130 60 r}} $id] u v side
        lassign [iso $u $v $want] x y
        if {$side eq "r"} {
            .c coords $id.lead $x $y 392 $y
            .c coords $id.label 398 $y
            .c itemconfigure $id.label -anchor w
        } else {
            .c coords $id.lead $x $y $x [expr {$y - 22}]
            .c coords $id.label [expr {$x - 6}] [expr {$y - 26}]
            .c itemconfigure $id.label -anchor sw
        }
    }
    set on [expr {$e > 0.25 ? "normal" : "hidden"}]
    .c itemconfigure lead -state $on
    .c itemconfigure label -state $on
    .c itemconfigure drive -state $on
    lassign [iso -20 120 [dict get $at paddle]] x0 y0
    lassign [iso 9 70 [dict get $at items]] x1 y1
    .c coords drive1 $x0 $y0 $x1 $y1
    .c coords drive1t [expr {$x0 - 6}] [expr {$y0 + 4}]
    lassign [iso 130 90 [dict get $at loop]] x0 y0
    lassign [iso 128 68 [dict get $at items]] x1 y1
    .c coords drive2 $x0 $y0 $x1 $y1
    .c coords drive2t [expr {$x0 + 6}] $y0
    .bar.go configure -text [expr {$e > 0.5 ? "Put together" : "Explode"}]
}
# The button moves the slider to the other end in 700 ms, one frame at a
# time. With reduced motion it goes there at once.
proc toggle {} {
    global e
    set ::to [expr {$e > 0.5 ? 0.0 : 1.0}]
    set ::from $e
    set ::k 0.0
    step
}
proc step {} {
    global e
    set k [set ::k [expr {min(1.0, $::k + 16 / 700.0)}]]
    if {[ztk::animate reduce]} { set k [set ::k 1.0] }
    set k [expr {$k < 0.5 ? 2*$k*$k : 1 - pow(-2*$k + 2, 2) / 2}]
    set e [expr {$::from + ($::to - $::from) * $k}]
    spread
    if {$::k < 1.0} { after 16 step }
}
# A hover on a layer marks its code.
.c bind layer <Enter> {mark [lindex [.c gettags current] 0]}
.c bind layer <Leave> {mark ""}
proc mark {id} {
    .code tag remove on 1.0 end
    .c itemconfigure layer -width 1
    if {$id eq ""} { .bar.hint configure -text "Hover a layer"; return }
    set i [lsearch $::layers $id]
    set line [expr {$i / 4 * 4 + 1}]
    .code tag add on $line.0 [expr {$line + 3}].0
    .code see $line.0
    .bar.hint configure -text [lindex $::layers [expr {$i + 1}]]
}
spread
```
