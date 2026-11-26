# Scale and scrollbar

**Live:** the Scale and Scrollbar cards of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## scale

![A horizontal scale at 40 with the ticks 0, 25, 50, 75, and 100](../site/shots/widget-scale-light.png)

<!-- widget: scale; shot: update -->
```tcl
set vol 40
scale .vol -orient horizontal -from 0 -to 100 -variable vol -tickinterval 25 -length 260
pack .vol -fill x -padx 12 -pady 8
```

### Play: Backspin

Backspin is a paddle game, and the scale sets the size of your paddle. Click the screen or press Space to serve. Up and Down, the mouse, or the pad of the handheld move the paddle. A hit while the paddle moves fast is a smash: with "Play on the page" on, the ball leaves the screen, bounces off the headings and the code of this page, and comes back. Escape or a scroll brings it back at once. The page sets `toy(spill)`, reads `toy(out)` and `toy(sfx)`, and gives the ball back in `toy(back)`. In `ztk` with no page, a smash makes the ball faster.

<!-- widget: toy-backspin; shot: update -->
```tcl
# Backspin. The scale sets the size of your paddle (left).
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
set H 168
canvas .c -width 360 -height $H -bg [lindex $ink 0] -highlightthickness 0
scale .s -orient horizontal -from 12 -to 72 -resolution 4 -variable size -label "Paddle size"
pack .c .s -fill x
set size 36
proc px {x y w h i} { .c create rectangle $x $y [expr {$x+$w}] [expr {$y+$h}] -fill [lindex $::ink $i] -width 0 }
expr {srand(7)}
for {set i 0} {$i < 24} {incr i} { px [expr {int(rand()*90)*4}] [expr {int(rand()*30)*4}] 4 4 4 }
for {set y 0} {$y < $H} {incr y 12} { px 178 $y 4 8 4 }
foreach {tag i} {me 1 cpu 2 ball 3} { .c addtag $tag withtag [px 0 0 0 0 $i] }
.c create text 180 120 -tags msg -text "CLICK TO SERVE" -fill [lindex $ink 3] -font {TkFixedFont 14 bold}
.c create text 180 14 -tags score -fill [lindex $ink 1] -font {TkFixedFont 14 bold}
array set g {y 84 dy 0 cy 84 bx 176 by 80 vx 0 vy 0 me 0 cpu 0 run 0 out 0}
# The page sets toy(spill), reads toy(out) and toy(sfx), and gives the ball back in toy(back).
array set toy {spill 0 out {} back {} sfx {}}
proc box {tag x y w h} { set x [expr {int($x)/4*4}]; set y [expr {int($y)/4*4}]; .c coords $tag $x $y [expr {$x+$w}] [expr {$y+$h}] }
proc toy_press {key} {
    global g
    switch $key {
        up { set g(y) [expr {$g(y) - 12}]; set g(dy) [expr {$g(dy) - 12}] }
        down { set g(y) [expr {$g(y) + 12}]; set g(dy) [expr {$g(dy) + 12}] }
        default { if {!$g(run)} { array set g {bx 176 by 80 vx -3 vy 1 run 1}; .c itemconfigure msg -text "" } }
    }
}
bind .c <Motion> { set g(dy) [expr {$g(dy) + %y - $g(y)}]; set g(y) %y }
foreach {k v} {<Up> up <Down> down <space> a <ButtonPress-1> a} { bind .c $k [list toy_press $v] }
focus .c
proc tick {} {
    global g size toy H
    set g(y) [expr {max($size/2, min($H - $size/2, $g(y)))}]
    set g(cy) [expr {$g(cy) + max(-2.5, min(2.5, $g(by) - $g(cy)))}]
    if {$g(run) && !$g(out)} {
        set g(bx) [expr {$g(bx) + $g(vx)}]
        set g(by) [expr {$g(by) + $g(vy)}]
        if {$g(by) < 0 || $g(by) > $H - 8} { set g(vy) [expr {-$g(vy)}]; lappend toy(sfx) wall }
        if {$g(vx) < 0 && $g(bx) < 16 && $g(bx) > 4 && abs($g(by) + 4 - $g(y)) < $size/2 + 4} {
            set g(vx) [expr {min(7, 0.25 - $g(vx))}]
            set g(vy) [expr {$g(vy) + $g(dy) / 6.0}]
            lappend toy(sfx) hit
            # A smash: a hit while the paddle moves fast.
            if {abs($g(dy)) > 10 && $toy(spill)} {
                set toy(out) [list $g(bx) $g(by) [expr {$g(vx)*2}] [expr {$g(vy) - 6}]]
                set g(out) 1
            } elseif {abs($g(dy)) > 10} { set g(vx) 7 }
        }
        if {$g(vx) > 0 && $g(bx) > 336 && abs($g(by) + 4 - $g(cy)) < 20} { set g(vx) [expr {-$g(vx)}] }
        if {$g(bx) < -8 || $g(bx) > 368} {
            incr g([expr {$g(bx) < 0 ? "cpu" : "me"}])
            set g(run) 0
            .c itemconfigure msg -text "CLICK TO SERVE"
        }
    }
    if {$g(out) && $toy(back) ne ""} {
        lassign $toy(back) g(bx) g(vx) g(vy)
        set g(by) 0; set g(out) 0; set toy(back) {}
    }
    box me 8 [expr {$g(y) - $size/2}] 8 $size
    box cpu 344 [expr {$g(cy) - 16}] 8 32
    box ball [expr {$g(out) ? -20 : $g(bx)}] $g(by) 8 8
    .c itemconfigure score -text "$g(me)   $g(cpu)"
    set g(dy) [expr {$g(dy) * 0.7}]
    after 16 tick
}
tick
```

- The slider follows the pointer on the render thread, so a drag stays smooth while the script is busy.
- The parts `::trough`, `::fill`, `::slider`, and `::value` accept CSS rules.

## scrollbar

![An entry with a long line of text and a horizontal scrollbar under it](../site/shots/widget-scrollbar-light.png)

<!-- widget: scrollbar; shot: update -->
```tcl
entry .e -width 22 -xscrollcommand {.s set}
scrollbar .s -orient horizontal -command {.e xview}
.e insert 0 "A long line of text that is wider than its entry, so the scrollbar under it moves the view."
pack .e .s -fill x -padx 12
```

- The modern scrollbar is an overlay. Its thumb shows while the view scrolls, on hover, and during a drag, and then fades out. The `classic` theme draws the scrollbar of Tk.
- A scroll by units or pages eases over 160 ms. A touchpad step adds momentum.
- The mouse wheel sends `<MouseWheel>` with `%D` (120 for one step), and `<Shift-MouseWheel>` for a horizontal step, as in Tk 8.7. A touchpad gives fractions of 120.
- The parts `::trough` and `::thumb` and the pseudo-class `:scrolling` accept CSS rules.
