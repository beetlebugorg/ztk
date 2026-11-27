# title: Lamplighter
# widget: ttk::notebook
# page: docs/widgets/panes.md
# pitch: Light the lamps of a hill town before the night comes. Each tab of the notebook is one street of the level.
# order: 1

# Lamplighter. Night falls on a hill town, and you carry the last flame.
# Each level is a walk through 2 or 3 streets, and each street is a tab
# of the ttk::notebook. Walk off the right edge to open the next tab.
# Touch a lamp to light it: each lamp pushes the night back. Light all
# the lamps of a level to open its gate. A click on a tab that you saw
# takes you back to its start.

set W 472; set H 232
array set toy {sfx {} music title save {} calm 0}
proc sfx {name} { lappend ::toy(sfx) $name }

# The palette: dusk and night, mixed by the dark of the level.
array set dusk {sky0 #24204a sky1 #4a3366 sky2 #9a4f6e sky3 #e0885e hill #3a2c52 hill2 #2c2242 ground #241b36 edge #6f5a8f}
array set night {sky0 #080a1c sky1 #10142e sky2 #1a1d3e sky3 #262650 hill #141530 hill2 #0f1026 ground #0c0b1a edge #2e2c52}
set ink(text) #f6ecd6; set ink(dim) #a89cc4; set ink(gold) #ffd27a; set ink(flame) #ff9a3c
set ink(lampoff) #4c4466; set ink(cloak) #4a86a8; set ink(face) #f2d2ac; set ink(water) #2b3f74

proc mix {a b t} {
    scan $a #%2x%2x%2x r1 g1 b1
    scan $b #%2x%2x%2x r2 g2 b2
    set t [expr {max(0.0, min(1.0, $t))}]
    format #%02x%02x%02x [expr {int($r1 + ($r2 - $r1) * $t)}] [expr {int($g1 + ($g2 - $g1) * $t)}] [expr {int($b1 + ($b2 - $b1) * $t)}]
}
proc ease {t} { expr {$t < 0.5 ? 4 * $t * $t * $t : 1 - pow(-2 * $t + 2, 3) / 2} }

# The levels. Each street has blocks {x0 top x1} that go to the floor,
# ledges {x0 y x1} that you can jump up through, lamps {x y}, springs
# {x y}, boats {x0 y x1 dx frames} that swing, crumbling boards {x0 y x1},
# and water {x0 x1}. The gate is at the right of the last street.
set levels {
    {"Lantern Lane" {
        {Gatehouse {{0 196 472}} {} {{236 166}} {} {} {} {}}
        {Bakery {{0 196 180} {180 176 300} {300 196 472}} {} {{240 146} {420 166}} {} {} {} {}}
    }}
    {"Mill Steps" {
        {Millrace {{0 196 150} {250 196 472}} {{150 170 250}} {{200 140} {400 166}} {} {} {} {{150 250}}}
        {Mill {{0 196 472}} {{120 160 200} {230 124 310} {340 88 420}} {{380 58}} {{60 196}} {} {} {}}
        {Granary {{0 196 120} {120 150 240} {240 196 472}} {} {{180 120} {360 166}} {} {} {} {}}
    }}
    {"The Ford" {
        {Bank {{0 196 110} {390 196 472}} {} {{60 166} {430 166}} {} {{140 190 196 120 110}} {} {{110 390}}}
        {Shallows {{0 196 80} {420 196 472}} {{196 150 276}} {{236 120}} {} {{90 190 146 90 90} {300 190 356 -80 100}} {} {{80 420}}}
        {"Far Bank" {{0 196 472}} {{160 160 230} {270 128 340}} {{300 98} {440 166}} {} {} {} {}}
    }}
    {"Bell Tower" {
        {Square {{0 196 472}} {{90 166 160} {200 140 270}} {{235 110}} {{360 196}} {} {} {}}
        {Stairwell {{0 196 90} {380 196 472}} {} {{430 166}} {} {} {{100 176 160} {180 150 240} {260 124 320} {330 150 380}} {{90 380}}}
        {Belfry {{0 196 472}} {{60 160 130} {160 124 230} {270 92 340} {370 60 440}} {{405 30} {100 130}} {} {} {} {}}
    }}
    {"Hilltop" {
        {Orchard {{0 196 130} {210 176 300} {380 196 472}} {} {{255 146} {430 166}} {{100 196}} {} {} {{130 210} {300 380}}}
        {Ridge {{0 196 70} {410 196 472}} {} {{240 60}} {} {{80 186 160 100 120} {250 160 330 -110 140}} {{190 120 240}} {{70 410}}}
        {Summit {{0 196 472}} {{110 166 180} {220 136 290} {330 106 400}} {{365 76} {150 136} {40 166}} {{40 196}} {} {} {}}
    }}
}

# The notebook in the colors of the night: the tabs are the street signs.
ztk::style add {
    TNotebook { background-color: #15122a; }
    TNotebook::client { background-color: #15122a; border: 1px solid #3a3358; border-radius: 6px; }
    TNotebook::tab, TNotebook::tab-selected, TNotebook::tab-hover, TNotebook::tab-disabled { color: #8f86b0; padding: 4px 12px; }
    TNotebook::tab-selected, TNotebook::tab-hover { color: #f6ecd6; }
    TNotebook::tab-disabled { opacity: 0.4; }
    TNotebook::indicator { background-color: #ffd27a; }
}
. configure -background #15122a
ttk::notebook .nb
pack .nb -fill both -expand 1 -padx 4 -pady 4
for {set i 0} {$i < 3} {incr i} {
    canvas .nb.s$i -width $W -height $H -highlightthickness 0 -background $dusk(sky0)
}

# The state of the run.
array set g {state title level 0 scene 0 dark 0 frames 0 shake 0 freeze 0 pick 0 clear 0 msgT 0 unlocked 1}
array set best {}
array set h {x 30 y 150 vx 0 vy 0 ground 1 coyote 0 buffer 0 face 1 sx 1 sy 1 step 0 spawnS 0 spawnX 30 spawnY 150 ride -1 crumble -1}
array set hold {left 0 right 0 jump 0}
set parts {}

proc toy_restore {data} {
    global g best
    if {[catch {dict get $data unlocked} u]} return
    set g(unlocked) [expr {max(1, min(5, $u))}]
    if {![catch {dict get $data best} b]} { array set best $b }
    title
}
proc save {} { set ::toy(save) [list unlocked $::g(unlocked) best [array get ::best]] }

proc toy_input {key state} {
    global g hold h
    set on [expr {$state eq "press"}]
    switch $g(state) {
        title {
            if {!$on} return
            switch $key {
                left { if {$g(pick) > 0} { incr g(pick) -1; sfx move; title } }
                right { if {$g(pick) < $g(unlocked) - 1} { incr g(pick); sfx move; title } }
                a - start - up { sfx start; start $g(pick) }
            }
        }
        play {
            switch $key {
                left - right { set hold($key) $on }
                a - up - b {
                    set hold(jump) $on
                    if {$on} { set h(buffer) 7 } elseif {$h(vy) < -2} { set h(vy) [expr {$h(vy) * 0.45}] }
                }
            }
        }
        clear - night - done {
            if {$on && $key in {a start up}} {
                if {$g(state) eq "night"} { sfx start; start $g(level) } \
                elseif {$g(state) eq "done"} { set g(state) title; title } \
                elseif {$g(level) < 4} { sfx start; start [expr {$g(level) + 1}] } \
                else { set g(state) done; ending }
            }
        }
    }
}

# Draws one street on its canvas. The lit lamps keep their glow.
proc street {i} {
    global levels g W H dusk ink
    set c .nb.s$i
    $c delete all
    lassign [lindex $levels $g(level) 1 $i] name blocks ledges lamps springs boats crumbles water
    # The sky in four bands, and stars that come out with the night.
    for {set k 0} {$k < 20} {incr k} { $c create rectangle 0 [expr {$k * 9}] $W [expr {$k == 19 ? $H : ($k + 1) * 9}] -width 0 -tags "sky sky$k" }
    for {set k 0} {$k < 26} {incr k} {
        set x [expr {($k * 131 + $i * 57 + $g(level) * 23) % $W}]; set y [expr {($k * 37 + $i * 11) % 40}]
        $c create rectangle $x $y [expr {$x + 2}] [expr {$y + 2}] -width 0 -fill $dusk(sky0) -tags "star"
    }
    # Two lines of hills, then the roofs of the town.
    set pts {}; for {set x 0} {$x <= $W + 40} {incr x 40} { lappend pts $x [expr {150 + 18 * sin(($x + $i * 90 + $g(level) * 40) / 70.0)}] }
    $c create polygon 0 $H {*}$pts $W $H -width 0 -tags hill
    set pts {}; for {set x 0} {$x <= $W + 30} {incr x 30} { lappend pts $x [expr {170 + 10 * sin(($x * 1.7 + $i * 40) / 50.0)}] }
    $c create polygon 0 $H {*}$pts $W $H -width 0 -tags hill2
    for {set x 10} {$x < $W} {incr x 70} {
        set w [expr {30 + ($x * 7 + $i) % 20}]; set top [expr {150 + ($x * 3 + $g(level) * 5) % 20}]
        $c create polygon $x 190 $x $top [expr {$x + $w / 2}] [expr {$top - 14}] [expr {$x + $w}] $top [expr {$x + $w}] 190 -width 0 -tags hill2
        $c create rectangle [expr {$x + 8}] [expr {$top + 8}] [expr {$x + 13}] [expr {$top + 14}] -width 0 -fill #e8b86a -tags "window"
    }
    foreach wt $water { lassign $wt x0 x1; $c create rectangle $x0 206 $x1 $H -width 0 -fill $ink(water) -tags water
        for {set x [expr {$x0 + 6}]} {$x < $x1 - 6} {incr x 18} { $c create line $x 210 [expr {$x + 8}] 210 -fill #6a86c8 -width 2 -tags ripple } }
    foreach b $blocks { lassign $b x0 y x1
        $c create rectangle $x0 $y $x1 $H -width 0 -tags ground
        $c create rectangle $x0 $y $x1 [expr {$y + 3}] -width 0 -tags edge
        for {set x [expr {$x0 + 7}]} {$x < $x1 - 4} {incr x 23} { $c create line $x $y [expr {$x - 2}] [expr {$y - 4}] $x $y [expr {$x + 3}] [expr {$y - 5}] -fill #7d6aa0 -tags tuft } }
    foreach l $ledges { lassign $l x0 y x1
        $c create rectangle $x0 $y $x1 [expr {$y + 6}] -width 0 -tags ground
        $c create rectangle $x0 $y $x1 [expr {$y + 2}] -width 0 -tags edge }
    set n 0
    foreach cr $crumbles { lassign $cr x0 y x1
        $c create rectangle $x0 $y $x1 [expr {$y + 5}] -width 0 -fill #8a6a4a -tags "crumble cr$n"
        for {set x [expr {$x0 + 10}]} {$x < $x1} {incr x 12} { $c create line $x $y $x [expr {$y + 5}] -fill #5a4430 -tags "crumble cr$n" }
        incr n }
    set n 0
    foreach bt $boats { lassign $bt x0 y x1
        $c create polygon $x0 $y $x1 $y [expr {$x1 - 6}] [expr {$y + 8}] [expr {$x0 + 6}] [expr {$y + 8}] -fill #a0703c -outline #d09a5a -tags "boat bt$n"
        incr n }
    foreach s $springs { lassign $s x y
        $c create rectangle [expr {$x - 9}] [expr {$y - 5}] [expr {$x + 9}] $y -width 0 -fill #5fb27a -tags spring
        $c create rectangle [expr {$x - 9}] [expr {$y - 7}] [expr {$x + 9}] [expr {$y - 5}] -width 0 -fill #a6e6b2 -tags spring }
    set n 0
    foreach l $lamps { lassign $l x y
        foreach r {40 33 27 21 15 10} k {6 5 4 3 2 1} { $c create oval [expr {$x - $r}] [expr {$y - $r}] [expr {$x + $r}] [expr {$y + $r}] -width 0 -state hidden -tags "glow glow$n g$k" }
        $c create rectangle [expr {$x - 1}] [expr {$y + 6}] [expr {$x + 1}] [expr {$y + 30}] -width 0 -fill #1a1426 -tags post
        $c create polygon [expr {$x - 6}] [expr {$y - 4}] [expr {$x + 6}] [expr {$y - 4}] [expr {$x + 4}] [expr {$y + 6}] [expr {$x - 4}] [expr {$y + 6}] -fill $ink(lampoff) -outline #1a1426 -tags "lamp lamp$n"
        $c create polygon [expr {$x - 8}] [expr {$y - 4}] $x [expr {$y - 10}] [expr {$x + 8}] [expr {$y - 4}] -fill #1a1426 -width 0 -tags post
        incr n }
    if {$i == [llength [lindex $levels $g(level) 1]] - 1} {
        # The gate of the level: bars that go up when each lamp is lit.
        $c create rectangle 440 120 444 196 -width 0 -fill #1a1426 -tags gatepost
        $c create rectangle 466 120 470 196 -width 0 -fill #1a1426 -tags gatepost
        for {set x 446} {$x < 466} {incr x 5} { $c create rectangle $x 124 [expr {$x + 2}] 196 -width 0 -fill #8f86b0 -tags bars }
    }
    # The hero: a cloak, a face, a hat, and the flame on a pole.
    $c create rectangle 0 0 1 1 -width 0 -fill $ink(cloak) -tags "hero hcloak"
    $c create rectangle 0 0 1 1 -width 0 -fill $ink(face) -tags "hero hface"
    $c create rectangle 0 0 1 1 -width 0 -fill #1a1426 -tags "hero hhat"
    $c create line 0 0 1 1 -fill #c8b088 -width 2 -tags "hero hpole"
    $c create oval 0 0 1 1 -width 0 -fill $ink(flame) -tags "hero hflame"
    $c create oval 0 0 1 1 -width 0 -fill $ink(gold) -tags "hero hcore"
    for {set k 0} {$k < 20} {incr k} { $c create rectangle -9 -9 -8 -8 -width 0 -fill $ink(gold) -tags "part p$k"; set ::pcolor($k) $ink(gold) }
    $c create text 8 6 -anchor nw -fill $ink(text) -font {TkFixedFont 10 bold} -tags hud
    $c create rectangle 360 9 464 15 -outline $ink(dim) -width 1 -tags hudbar
    $c create rectangle 361 10 463 14 -width 0 -fill $ink(gold) -tags hudfill
    $c create text [expr {$W / 2}] 92 -fill $ink(text) -font {TkFixedFont 20 bold} -tags "msg"
    $c create text [expr {$W / 2}] 122 -fill $ink(dim) -font {TkFixedFont 10 bold} -tags "msg2"
    paint $i
}

# The colors of a street for the dark of the level, from 0 to 1.
proc paint {i} {
    global dusk night g
    set c .nb.s$i
    set t [ease $g(dark)]
    # Twenty bands of the sky, mixed between the four colors of the palette.
    for {set k 0} {$k < 20} {incr k} {
        set u [expr {$k / 19.0 * 3}]; set a [expr {min(2, int($u))}]; set f [expr {$u - $a}]
        set top [mix $dusk(sky$a) $dusk(sky[expr {$a + 1}]) $f]
        set low [mix $night(sky$a) $night(sky[expr {$a + 1}]) $f]
        $c itemconfigure sky$k -fill [mix $top $low $t]
    }
    foreach k {hill hill2 ground edge} { $c itemconfigure $k -fill [mix $dusk($k) $night($k) $t] }
    $c itemconfigure star -fill [mix [mix $dusk(sky0) $night(sky0) $t] #dcd6ff [expr {($t - 0.3) * 1.6}]]
    $c configure -background [mix $dusk(sky0) $night(sky0) $t]
    # Each glow mixes the gold of the lamp into the sky behind it.
    set sky [mix $dusk(sky1) $night(sky1) $t]
    foreach k {6 5 4 3 2 1} f {0.07 0.13 0.2 0.29 0.4 0.56} { $c itemconfigure g$k -fill [mix $sky #ffd27a $f] }
}

proc lvl {} { lindex $::levels $::g(level) 1 }
# The parts of the current street, read once when you enter it.
proc loadStreet {} {
    foreach what {name blocks ledges lamps springs boats crumbles water} v [lindex [lvl] $::g(scene)] { set ::cur($what) $v }
}
proc data {what} { return $::cur($what) }

proc start {n} {
    global g h levels toy lit crumb
    array set g [list state play level $n scene 0 dark 0 frames 0 shake 0 freeze 0 clear 0 msgT 120]
    array unset lit; array unset crumb
    set toy(music) play
    set scenes [lvl]
    foreach t [.nb tabs] { .nb forget $t }
    for {set i 0} {$i < [llength $scenes]} {incr i} {
        .nb add .nb.s$i -text [lindex $scenes $i 0] -state [expr {$i ? "disabled" : "normal"}]
        street $i
    }
    tabtext
    array set h {x 24 y 150 vx 0 vy 0 ground 0 coyote 0 buffer 0 face 1 sx 1 sy 1 ride -1 crumble -1}
    array set h {spawnS 0 spawnX 24 spawnY 150}
    .nb select 0
    enter 0 24
    say [lindex $levels $n 0] "Level [expr {$n + 1}] of 5"
}

# The name of each tab, with a dot for each lamp: lit or not.
proc tabtext {} {
    global lit
    set i 0
    foreach s [lvl] {
        set dots ""
        for {set k 0} {$k < [llength [lindex $s 3]]} {incr k} { append dots [expr {[info exists lit($i,$k)] ? "●" : "○"}] }
        .nb tab $i -text "[lindex $s 0] $dots"
        incr i
    }
}

proc say {a b} {
    set c .nb.s$::g(scene)
    $c itemconfigure msg -text $a
    $c itemconfigure msg2 -text $b
    set ::g(msgT) 150
}

# A click on a tab of a street that you saw takes you to its start.
bind .nb <<NotebookTabChanged>> {
    set n [.nb index current]
    if {$g(state) eq "play" && $n != $g(scene)} { enter $n 24; set h(y) 120; set h(vy) 0 }
}
proc enter {n x} {
    global g h
    foreach i {0 1 2} { if {[winfo exists .nb.s$i]} { .nb.s$i itemconfigure hero -state hidden } }
    set g(scene) $n; set h(x) $x
    loadStreet
    .nb.s$n itemconfigure hero -state normal
    paint $n
    if {[.nb index current] != $n} { .nb select $n }
}

proc burst {x y n color {up 0}} {
    global parts
    for {set k 0} {$k < $n} {incr k} {
        set a [expr {rand() * 6.283}]; set s [expr {0.6 + rand() * 1.8}]
        lappend parts [list $x $y [expr {cos($a) * $s}] [expr {sin($a) * $s - $up}] [expr {24 + int(rand() * 18)}] $color]
    }
    set parts [lrange $parts end-19 end]
}

proc hurt {} {
    global h g
    sfx hurt
    set g(shake) 10
    set g(dark) [expr {min(1.0, $g(dark) + 0.05)}]
    burst $h(x) $h(y) 12 #ff9a3c 1
    if {$h(spawnS) != $g(scene)} { enter $h(spawnS) $h(spawnX) }
    set h(x) $h(spawnX); set h(y) $h(spawnY); set h(vx) 0; set h(vy) 0
}

# The solid tops under the feet: blocks, ledges, boats, and boards.
proc floors {} {
    global g h crumb
    set out {}
    foreach b [data blocks] { lappend out [concat $b solid -1] }
    foreach l [data ledges] { lappend out [concat $l ledge -1] }
    set n 0
    foreach bt [data boats] {
        lassign $bt x0 y x1 dx per
        set off [expr {$dx * sin($g(frames) * 6.283 / $per)}]
        lappend out [list [expr {$x0 + $off}] $y [expr {$x1 + $off}] boat $n]
        incr n
    }
    set n 0
    foreach cr [data crumbles] {
        if {![info exists crumb($g(scene),$n)] || [lindex $crumb($g(scene),$n) 0] < 40} { lappend out [concat $cr crumble $n] }
        incr n
    }
    return $out
}

proc tick {} {
    global g
    after 16 tick
    if {$g(state) eq "title"} { titleTick; return }
    if {$g(freeze) > 0} { incr g(freeze) -1; return }
    if {$g(state) eq "play"} { step }
    draw
}

proc step {} {
    global g h hold lit crumb toy levels
    incr g(frames)
    set c .nb.s$g(scene)
    # The night comes in about 100 seconds; each lamp holds it back.
    set g(dark) [expr {min(1.0, $g(dark) + 1.0 / 6000)}]
    if {$g(frames) % 20 == 0} { paint $g(scene) }
    if {$g(dark) >= 1.0} {
        set g(state) night; set toy(music) ""; sfx lose
        say "Night fell" "Press A to try again"; return
    }
    # Run: speed up on a press, slow down on a release, less in the air.
    set dir [expr {$hold(right) - $hold(left)}]
    set acc [expr {$h(ground) ? 0.45 : 0.28}]
    if {$dir != 0} {
        set h(face) $dir
        set h(vx) [expr {max(-2.7, min(2.7, $h(vx) + $dir * $acc))}]
    } else {
        set f [expr {$h(ground) ? 0.42 : 0.12}]
        set h(vx) [expr {abs($h(vx)) <= $f ? 0 : $h(vx) - ($h(vx) > 0 ? $f : -$f)}]
    }
    # A jump: the press waits 7 frames (the buffer), and the ground
    # stays for 6 frames after the edge (coyote time).
    if {$h(buffer) > 0} { incr h(buffer) -1 }
    if {$h(ground)} { set h(coyote) 6 } elseif {$h(coyote) > 0} { incr h(coyote) -1 }
    if {$h(buffer) > 0 && $h(coyote) > 0} {
        set h(vy) -6.3; set h(buffer) 0; set h(coyote) 0; set h(ground) 0; set h(ride) -1
        set h(sx) 0.7; set h(sy) 1.35; sfx jump
        burst $h(x) [expr {$h(y) + 7}] 4 #c8b8e0
    }
    set h(vy) [expr {min(6.0, $h(vy) + ($h(vy) < 0 && $hold(jump) ? 0.30 : 0.42))}]
    # Ride a boat: move with it.
    if {$h(ride) >= 0} {
        foreach f [floors] { lassign $f x0 y x1 kind n; if {$kind eq "boat" && $n == $h(ride)} { set h(x) [expr {$h(x) + ($x0 - $h(rideX))}]; set h(rideX) $x0 } }
    }
    set h(x) [expr {$h(x) + $h(vx)}]
    # The sides of the blocks.
    foreach b [data blocks] {
        lassign $b x0 top x1
        if {$h(y) + 7 > $top + 2 && $h(x) + 5 > $x0 && $h(x) - 5 < $x1} {
            set h(x) [expr {$h(vx) > 0 ? $x0 - 5 : $x1 + 5}]; set h(vx) 0
        }
    }
    set oy $h(y)
    set h(y) [expr {$h(y) + $h(vy)}]
    set was $h(ground)
    set h(ground) 0
    if {$h(vy) >= 0} {
        foreach f [floors] {
            lassign $f x0 y x1 kind n
            if {$oy + 7 <= $y + 1 && $h(y) + 7 >= $y && $h(x) + 4 > $x0 && $h(x) - 4 < $x1} {
                set h(y) [expr {$y - 7}]
                if {!$was && $h(vy) > 2.5} {
                    set h(sx) 1.35; set h(sy) 0.7; sfx land
                    burst $h(x) $y [expr {$h(vy) > 5 ? 8 : 4}] #c8b8e0
                    if {$h(vy) > 5.5} { set g(shake) 4 }
                }
                set h(vy) 0; set h(ground) 1
                set h(ride) [expr {$kind eq "boat" ? $n : -1}]
                if {$kind eq "boat"} { set h(rideX) $x0 }
                if {$kind eq "crumble" && ![info exists crumb($g(scene),$n)]} { set crumb($g(scene),$n) {0} }
                break
            }
        }
    }
    if {!$h(ground)} { set h(ride) -1 }
    # The boards break 40 frames after a step, and come back after 3 s.
    foreach k [array names crumb $g(scene),*] {
        set n [lindex [split $k ,] 1]
        set t [expr {[lindex $crumb($k) 0] + 1}]
        set crumb($k) $t
        if {$t == 40} { sfx crash; .nb.s$g(scene) itemconfigure cr$n -state hidden; lassign [lindex [data crumbles] $n] x0 y x1; burst [expr {($x0 + $x1) / 2}] $y 10 #8a6a4a }
        if {$t > 220} { unset crumb($k); .nb.s$g(scene) itemconfigure cr$n -state normal }
        if {$t < 40 && $t % 6 < 3} { .nb.s$g(scene) move cr$n [expr {$t % 2 ? 1 : -1}] 0 }
    }
    # A spring sends you high.
    foreach s [data springs] {
        lassign $s sx sy
        if {$h(ground) && abs($h(x) - $sx) < 10 && abs($h(y) + 7 - $sy) < 3} {
            set h(vy) -9.6; set h(ground) 0; set h(sx) 0.6; set h(sy) 1.5; sfx pop; burst $sx $sy 6 #a6e6b2 1
        }
    }
    # The lamps.
    set k 0
    foreach l [data lamps] {
        lassign $l lx ly
        if {![info exists lit($g(scene),$k)] && abs($h(x) - $lx) < 11 && abs($h(y) - 4 - $ly) < 22} {
            set lit($g(scene),$k) 1
            $c itemconfigure lamp$k -fill #ffd27a
            $c itemconfigure glow$k -state normal
            $c raise glow$k window
            $c lower glow$k post
            set g(dark) [expr {max(0.0, $g(dark) - 0.22)}]
            paint $g(scene)
            burst $lx $ly 16 #ffd27a 0.5
            set g(freeze) 4; set g(shake) 3; sfx light
            tabtext
            if {[allLit]} { sfx win; say "The gate is open" "Walk on to the right" }
        }
        incr k
    }
    # The edges of a street.
    set last [expr {[llength [lvl]] - 1}]
    if {$h(x) > $::W - 4} {
        if {$g(scene) < $last} {
            set n [expr {$g(scene) + 1}]
            .nb tab $n -state normal
            set h(spawnS) $n; set h(spawnX) 20; set h(spawnY) 150
            enter $n 8; sfx select
        } elseif {[allLit]} { finish; return } else {
            set h(x) [expr {$::W - 4}]
        }
    }
    if {$g(scene) == $last && ![allLit] && $h(x) > 436} { set h(x) 436; set h(vx) 0 }
    if {$h(x) < 5} {
        if {$g(scene) > 0} { enter [expr {$g(scene) - 1}] [expr {$::W - 10}] } else { set h(x) 5 }
    }
    if {$h(y) > $::H + 10} { hurt }
    # Steps on the ground.
    if {$h(ground) && abs($h(vx)) > 1 && [incr h(step)] % 14 == 0} { sfx step }
}

proc allLit {} {
    global lit g
    set i 0
    foreach s [lvl] { for {set k 0} {$k < [llength [lindex $s 3]]} {incr k} { if {![info exists lit($i,$k)]} { return 0 } }; incr i }
    return 1
}

proc finish {} {
    global g best toy
    set secs [expr {$g(frames) / 60.0}]
    set n $g(level)
    set new [expr {![info exists best($n)] || $secs < $best($n)}]
    if {$new} { set best($n) [format %.1f $secs] }
    set g(unlocked) [expr {max($g(unlocked), min(5, $n + 2))}]
    save
    set g(state) clear; set toy(music) ""; sfx win
    set g(shake) 0
    say "[lindex $::levels $n 0] is lit" "[format %.1f $secs] s[expr {$new ? "  new best" : "  best $best($n) s"}]   A: next"
}

proc ending {} {
    set c .nb.s$::g(scene)
    say "The town is lit" "Thank you for the light. A: title"
    set ::toy(music) title
}

# Moves the items of the street to the state of the frame.
proc draw {} {
    global g h parts ink
    set c .nb.s$g(scene)
    # The squash and the stretch go back to 1.
    set h(sx) [expr {$h(sx) + (1 - $h(sx)) * 0.25}]
    set h(sy) [expr {$h(sy) + (1 - $h(sy)) * 0.25}]
    set ox 0; set oy 0
    if {$g(shake) > 0 && !$::toy(calm)} {
        set ox [expr {int((rand() - 0.5) * $g(shake))}]; set oy [expr {int((rand() - 0.5) * $g(shake))}]
    }
    if {$g(shake) > 0} { incr g(shake) -1 }
    set x [expr {$h(x) + $ox}]; set y [expr {$h(y) + 7 + $oy}]
    set w [expr {6.5 * $h(sx)}]; set hh [expr {19 * $h(sy)}]
    set bob [expr {$h(ground) && abs($h(vx)) > 0.5 ? sin($g(frames) * 0.5) : 0}]
    $c coords hcloak [expr {$x - $w}] [expr {$y - $hh * 0.72}] [expr {$x + $w}] $y
    $c coords hface [expr {$x - $w * 0.7}] [expr {$y - $hh}] [expr {$x + $w * 0.7}] [expr {$y - $hh * 0.68 + $bob}]
    $c coords hhat [expr {$x - $w - 1}] [expr {$y - $hh - 2}] [expr {$x + $w + 1}] [expr {$y - $hh}]
    set px [expr {$x + $h(face) * 7}]; set py [expr {$y - $hh - 6}]
    $c coords hpole [expr {$x + $h(face) * 3}] [expr {$y - 4}] $px $py
    set fl [expr {2.4 + sin($g(frames) * 0.4) * 0.8}]
    $c coords hflame [expr {$px - $fl - 1}] [expr {$py - $fl - 3}] [expr {$px + $fl + 1}] [expr {$py + $fl}]
    $c coords hcore [expr {$px - 1.2}] [expr {$py - 2}] [expr {$px + 1.2}] [expr {$py + 1}]
    if {$g(frames) % 5 == 0 && $g(state) eq "play"} { lappend parts [list $px [expr {$py - 2}] [expr {(rand() - 0.5) * 0.4}] -0.6 30 #ffb35c] }
    # The particles: embers, dust, and sparks.
    set keep {}
    set k 0
    foreach p $parts {
        lassign $p px py vx vy life color
        if {[incr life -1] <= 0 || $k >= 20} continue
        set px [expr {$px + $vx}]; set py [expr {$py + $vy}]; set vy [expr {$vy + 0.05}]
        set s [expr {$life > 12 ? 2 : 1}]
        $c coords p$k $px $py [expr {$px + $s}] [expr {$py + $s}]
        if {$::pcolor($k) ne $color} { $c itemconfigure p$k -fill $color; set ::pcolor($k) $color }
        lappend keep [list $px $py $vx $vy $life $color]
        incr k
    }
    for {} {$k < 20} {incr k} { $c coords p$k -9 -9 -8 -8 }
    set parts $keep
    # The boats swing.
    set n 0
    foreach bt [data boats] {
        lassign $bt x0 y x1 dx per
        set off [expr {$dx * sin($g(frames) * 6.283 / $per)}]
        $c coords bt$n [expr {$x0 + $off}] $y [expr {$x1 + $off}] $y [expr {$x1 + $off - 6}] [expr {$y + 8}] [expr {$x0 + $off + 6}] [expr {$y + 8}]
        incr n
    }
    if {[allLit]} { foreach id [$c find withtag bars] { lassign [$c coords $id] a b cc d; if {$b > 60} { $c coords $id $a [expr {$b - 2}] $cc [expr {$d - 2}] } } }
    if {$g(state) eq "title"} return
    $c itemconfigure hud -text "[lindex $::levels $g(level) 0]   [format %02d:%02d [expr {$g(frames) / 3600}] [expr {($g(frames) / 60) % 60}]]"
    set left [expr {1 - $g(dark)}]
    $c coords hudfill 361 10 [expr {361 + 102 * $left}] 14
    $c itemconfigure hudfill -fill [expr {$left < 0.25 && $g(frames) % 30 < 15 && !$::toy(calm) ? "#ff6a5c" : "#ffd27a"}]
    if {$g(msgT) > 0 && $g(state) eq "play" && [incr g(msgT) -1] == 0} { say "" "" }
}

# The title screen: the first street of the picked level, with its name.
proc title {} {
    global g levels toy ink best
    set g(state) title
    set toy(music) title
    foreach t [.nb tabs] { .nb forget $t }
    set g(level) $g(pick); set g(scene) 0; set g(dark) 0.15
    loadStreet
    .nb add .nb.s0 -text "Lamplighter"
    street 0
    set c .nb.s0
    $c itemconfigure hero -state normal
    $c itemconfigure hud -text ""
    $c itemconfigure hudbar -state hidden; $c itemconfigure hudfill -state hidden
    $c create text 236 70 -text "LAMPLIGHTER" -fill $ink(gold) -font {TkFixedFont 30 bold} -tags title
    set n $g(pick)
    set b [expr {[info exists best($n)] ? "best $best($n) s" : "not lit yet"}]
    $c create text 236 104 -text "◀  [expr {$n + 1}]. [lindex $levels $n 0]  ▶" -fill $ink(text) -font {TkFixedFont 12 bold} -tags title
    $c create text 236 124 -text $b -fill $ink(dim) -font {TkFixedFont 10} -tags title
    $c create text 236 222 -text "A or Enter: start      Left and Right: level" -fill $ink(dim) -font {TkFixedFont 9 bold} -tags "title blink"
    for {set k 1} {$k < 5} {incr k} {
        set fill [expr {$k < $g(unlocked) ? $ink(gold) : "#4c4466"}]
        $c create oval [expr {206 + $k * 12}] 136 [expr {212 + $k * 12}] 142 -width 0 -fill $fill -tags title
    }
    $c create oval 206 136 212 142 -width 0 -fill $ink(gold) -tags title
    array set ::h {x 60 y 189 vx 0.8 vy 0 face 1 sx 1 sy 1 ground 1}
    # The lamp of the title is lit.
    $c itemconfigure lamp0 -fill $ink(gold)
    $c itemconfigure glow0 -state normal
    $c raise glow0 window
    $c lower glow0 post
}
proc titleTick {} {
    global g h
    incr g(frames)
    set h(x) [expr {$h(x) + 0.8}]
    if {$h(x) > 500} { set h(x) -20 }
    set h(vx) 0.8; set h(ground) 1
    if {$g(frames) % 40 == 0} { .nb.s0 itemconfigure blink -state [expr {$g(frames) % 80 ? "hidden" : "normal"}] }
    draw
}

title
tick
