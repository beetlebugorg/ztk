# Check and radio buttons

**Live:** the check button and radio button cards of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## checkbutton

![The check button Sync files on, the check button Some of the folders, in the mixed state, and a Wi-Fi switch that is off](../site/shots/widget-checkbutton-light.png)

<!-- widget: checkbutton; shot: update -->
```tcl
set opts(sync) 1
set opts(mixed) x
checkbutton .sync -text "Sync files" -variable opts(sync)
checkbutton .mixed -text "Some of the folders" -variable opts(mixed) -tristatevalue x
checkbutton .wifi -text "Wi-Fi" -variable opts(wifi)
ztk::class .wifi add switch
pack .sync .mixed .wifi -anchor w -padx 12 -pady 2
```

- The style class `switch` draws a check button as a switch. Its knob slides with a spring.
- A variable with the value of `-tristatevalue` shows the mixed state.
- `select`, `deselect`, `toggle`, and `invoke` work as in Tk. `flash` has no effect.

### Play: Moth Lamp

Moth Lamp is a pinball table on its side, and two check buttons switch the table: "Lamp bumpers" puts the three lamps in, and "Drain gate" closes the drain. Click the table or press Space to launch. Up and Down, or the pad, flip the top and the low flipper. A flip with the middle of a flipper is a strong flip: with "Play on the page" on, the ball leaves the table, falls across the page, and bounces off the headings and the code. Each one that it hits lights up and gives 500 points when the ball comes back. Escape or a scroll brings the ball back at once.

<!-- widget: toy-mothlamp; shot: update -->
```tcl
# Moth Lamp: a pinball table on its side. The check buttons switch the table.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
set H 176
canvas .c -width 360 -height $H -bg [lindex $ink 0] -highlightthickness 0
checkbutton .lamps -text "Lamp bumpers" -variable lamps
checkbutton .gate -text "Drain gate" -variable gate
pack .c -fill x
pack .lamps .gate -side left -padx 8
set lamps 1; set gate 0
# Three lamps: a hit gives 100 points and a kick.
set bumpers {150 60 220 110 270 50}
foreach {x y} $bumpers { .c create oval [expr {$x-14}] [expr {$y-14}] [expr {$x+14}] [expr {$y+14}] -tags lamp -fill [lindex $ink 3] -width 0 }
.c create rectangle 0 0 4 $H -tags gate -fill [lindex $ink 4] -width 0
foreach {tag y} {top 40 low 136} { .c create rectangle 8 [expr {$y-24}] 16 [expr {$y+24}] -tags $tag -fill [lindex $ink 1] -width 0 }
.c create rectangle 0 0 8 8 -tags ball -fill [lindex $ink 2] -width 0
.c create text 270 160 -tags msg -text "CLICK TO LAUNCH" -fill [lindex $ink 3] -font {TkFixedFont 12 bold}
.c create text 320 14 -tags score -fill [lindex $ink 1] -font {TkFixedFont 12 bold}
array set b {x 340 y 88 vx 0 vy 0 run 0 out 0 score 0 flip 0}
array set toy {spill 0 out {} back {} sfx {}}
# The keys: Up flips the top flipper, Down the low one, A launches.
proc toy_press {key} {
    global b
    switch $key {
        up - down { set b(flip) $key; after 120 {set b(flip) 0} }
        default { if {!$b(run)} { array set b {x 340 y 88 vx -7 run 1}; set b(vy) [expr {rand()*4-2}]; .c itemconfigure msg -text "" } }
    }
}
foreach {k v} {<Up> up <Down> down <space> a <ButtonPress-1> a} { bind .c $k [list toy_press $v] }
focus .c
proc tick {} {
    global b toy H lamps gate bumpers
    .c itemconfigure lamp -state [expr {$lamps ? "normal" : "hidden"}]
    .c itemconfigure gate -fill [lindex $::ink [expr {$gate ? 1 : 4}]]
    foreach {tag y key} {top 40 up low 136 down} { .c coords $tag [expr {$b(flip) eq $key ? 12 : 8}] [expr {$y-24}] 20 [expr {$y+24}] }
    if {$b(run) && !$b(out)} {
        # The table leans to the left, so the ball falls to the flippers.
        set b(vx) [expr {$b(vx) - 0.12}]
        set b(x) [expr {$b(x) + $b(vx)}]
        set b(y) [expr {$b(y) + $b(vy)}]
        if {$b(y) < 0 || $b(y) > $H - 8} { set b(vy) [expr {-$b(vy)}]; set b(y) [expr {max(0, min($H - 8, $b(y)))}] }
        if {$b(x) > 352} { set b(vx) [expr {-abs($b(vx))}] }
        if {$lamps} {
            foreach {x y} $bumpers {
                set dx [expr {$b(x) + 4 - $x}]; set dy [expr {$b(y) + 4 - $y}]
                set d [expr {hypot($dx, $dy)}]
                if {$d < 18} { set b(vx) [expr {6 * $dx / $d}]; set b(vy) [expr {6 * $dy / $d}]; incr b(score) 100; lappend toy(sfx) hit }
            }
        }
        if {$b(x) < 16 && $b(vx) < 0} {
            set f [expr {$b(y) < 88 ? "up" : "down"}]
            set fy [expr {$f eq "up" ? 40 : 136}]
            if {$b(flip) eq $f && abs($b(y) + 4 - $fy) < 28} {
                # A flip: a hit near the middle of the flipper launches the ball out of the table.
                set b(vx) 9; set b(vy) [expr {($b(y) + 4 - $fy) / 4.0}]
                lappend toy(sfx) smash
                if {$toy(spill) && abs($b(y) + 4 - $fy) < 8} {
                    set toy(out) [list $b(x) $b(y) 8 -10 0.4]
                    set b(out) 1
                }
            } elseif {$gate} { set b(vx) [expr {abs($b(vx))}]; lappend toy(sfx) wall
            } elseif {$b(x) < -8} { set b(run) 0; .c itemconfigure msg -text "CLICK TO LAUNCH"; lappend toy(sfx) point }
        }
    }
    # The page gives the ball back as {x vx vy hits}: each heading that it hit gives 500.
    if {$b(out) && $toy(back) ne ""} {
        lassign $toy(back) b(x) b(vx) b(vy) hits
        set b(x) [expr {max(200, $b(x))}]; set b(y) 0; set b(vx) [expr {-abs($b(vx))}]
        incr b(score) [expr {500 * $hits}]
        set b(out) 0; set toy(back) {}
    }
    .c coords ball [expr {$b(out) ? -20 : int($b(x))/4*4}] [expr {int($b(y))/4*4}] [expr {$b(out) ? -12 : int($b(x))/4*4+8}] [expr {int($b(y))/4*4+8}]
    .c itemconfigure score -text $b(score)
    after 16 tick
}
tick
```

## radiobutton

![Three radio buttons with Fine detail selected, and a segmented control of List, Grid, and Columns with List selected](../site/shots/widget-radiobutton-light.png)

<!-- widget: radiobutton; shot: update -->
```tcl
set quality high
foreach {v t} {low Draft normal Normal high "Fine detail"} {
    radiobutton .q$v -text $t -variable quality -value $v
    pack .q$v -anchor w -padx 12
}
frame .seg
foreach {v t} {list List grid Grid columns Columns} {
    radiobutton .seg.$v -text $t -variable view -value $v -indicatoron 0
    ztk::class .seg.$v add segmented
    pack .seg.$v -side left
}
set view list
pack .seg -padx 12 -pady 8
```

The style class `segmented` joins radio buttons with `-indicatoron 0` into a segmented control.

## In CSS

The indicator is the part `::indicator`, and the states are pseudo-classes:

```css
Checkbutton.switch:checked::indicator { background: #16a34a; }
Radiobutton:hover::indicator { border-color: var(--accent); }
```

The `ttk` forms are on [Themed widgets](ttk.md).
