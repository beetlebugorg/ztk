# title: Tin Moon
# widget: ttk::scale
# page: docs/widgets/ttk.md
# pitch: Fly a tin balloon over a small moon. You steer only with height: each layer of the sky has its own wind, and the ttk::scale is your burner.
# order: 3

# Tin Moon. The ttk::scale on the right is the burner. More heat makes
# the balloon rise, slowly, as warm air does. You cannot steer left or
# right: each layer of the sky has a wind, and the streaks show its way.
# Climb or sink into the wind that you need, and land softly on the
# lit pad. The ttk::progressbar is the fuel. Moon motes on the way are
# extra points. Up and Down move the scale, or drag it.

array set toy {sfx {} music title save {} calm 0}
proc sfx {name} { lappend ::toy(sfx) $name }
set VW 420; set VH 236

# The levels: the width of the world, the winds of the layers from the
# top {top bottom speed}, the ground {x y ...}, the start, the pad
# {x0 x1 y}, the motes {x y}, and the fuel.
set levels {
    {"Drift" 900 {{0 236 1.1}}
        {0 200 160 200 260 190 420 205 600 196 700 200 900 200} {80 200} {700 780 200} {{300 140} {460 120} {560 150}} 100}
    {"Two Winds" 1100 {{0 110 1.6} {110 236 -0.6}}
        {0 205 180 205 300 170 380 200 560 186 760 200 880 200 1100 205} {90 205} {880 960 200} {{260 80} {520 60} {700 140}} 100}
    {"Back Home" 1000 {{0 90 -1.4} {90 160 0.0} {160 236 1.2}}
        {0 200 120 200 240 180 420 200 640 192 800 200 1000 200} {700 200} {120 200 200} {{560 60} {380 120} {240 70}} 90}
    {"Spires" 1300 {{0 80 1.8} {80 170 0.4} {170 236 -0.5}}
        {0 205 150 205 260 205 300 120 330 205 520 205 560 100 600 205 820 205 860 130 890 205 1060 205 1300 205} {80 205} {1100 1180 205} {{300 70} {560 50} {870 80} {700 180}} 90}
    {"Long Night" 1600 {{0 70 -1.0} {70 140 1.6} {140 236 -0.4}}
        {0 205 200 205 330 160 420 205 640 190 720 120 780 205 1000 205 1080 150 1150 205 1400 205 1600 205} {100 205} {1420 1500 205} {{420 100} {720 60} {1000 120} {1300 50} {560 160}} 85}
}

set ink(sky0) #0d1726; set ink(sky1) #1a2c47; set ink(sky2) #2a4266; set ink(moon) #f3e6c0
set ink(ground) #1b2333; set ink(ridge) #33415c; set ink(text) #f1ead8; set ink(dim) #8fa3bf
set ink(env1) #f2a541; set ink(env2) #f6e7c8; set ink(basket) #8a5a2b; set ink(pad) #6fd3a8; set ink(mote) #b9f0ff

ztk::style add {
    TScale::trough { background-color: #22324d; }
    TScale::slider { background-color: #f2a541; }
    TProgressbar::trough { background-color: #22324d; }
    TProgressbar::bar { background-color: #6fd3a8; }
}
. configure -background $ink(sky0)
canvas .c -width $VW -height $VH -background $ink(sky0) -highlightthickness 0
frame .side -background $ink(sky0)
label .side.heatT -text HEAT -background $ink(sky0) -foreground $ink(dim) -font {TkFixedFont 8 bold}
ttk::scale .side.heat -orient vertical -from 1 -to 0 -variable heat -length 150
label .side.fuelT -text FUEL -background $ink(sky0) -foreground $ink(dim) -font {TkFixedFont 8 bold}
ttk::progressbar .fuel -orient horizontal -maximum 100 -variable fuel -length $VW
grid .c -row 0 -column 0 -padx {6 4} -pady {6 2}
grid .side -row 0 -column 1 -rowspan 2 -sticky ns -pady 6
grid .fuel -row 1 -column 0 -sticky ew -padx {6 4} -pady {0 6}
pack .side.heatT -pady {4 2}
pack .side.heat -fill y -expand 1
label .side.score -background $ink(sky0) -foreground $ink(text) -font {TkFixedFont 9 bold} -text ""
pack .side.score -pady 4
set heat 0.45; set fuel 100

array set g {state title level 0 pick 0 unlocked 1 frames 0 shake 0 cam 0 hold 0 motes 0 layer -1 t 0}
array set best {}
array set b {x 80 y 180 vx 0 vy 0 temp 0.45 sway 0 swayV 0 landed 1}
set parts {}

proc toy_restore {data} {
    global g best
    if {[catch {dict get $data unlocked} u]} return
    set g(unlocked) [expr {max(1, min([llength $::levels], $u))}]
    if {![catch {dict get $data best} v]} { array set best $v }
    title
}
proc save {} { set ::toy(save) [list unlocked $::g(unlocked) best [array get ::best]] }

proc toy_input {key state} {
    global g
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
            # Up and Down hold the scale: it moves while the key is down.
            if {$key in {up a}} { set g(hold) [expr {$on ? 1 : 0}] }
            if {$key in {down b}} { set g(hold) [expr {$on ? -1 : 0}] }
            if {$key eq "start" && $on} { start $g(level) }
        }
        landed - crashed {
            if {$on && $key in {a start}} {
                if {$g(state) eq "crashed"} { start $g(level) } \
                elseif {$g(level) + 1 < [llength $::levels]} { sfx start; start [expr {$g(level) + 1}] } \
                else { set g(pick) 0; title }
            } elseif {$on && $key eq "b"} { start $g(level) }
        }
    }
}

proc level {what} {
    set k [lsearch {name width winds ground start pad motes fuel} $what]
    lindex $::levels $::g(level) $k
}

# The height of the ground at x, from the points of the level.
proc groundY {x} {
    set pts [level ground]
    foreach {x0 y0} [lrange $pts 0 end-2] {x1 y1} [lrange $pts 2 end] {
        if {$x1 eq ""} break
        if {$x >= $x0 && $x <= $x1} { return [expr {$y0 + ($y1 - $y0) * ($x - $x0) / double($x1 - $x0)}] }
    }
    return [lindex $pts end]
}
# The wind at a height: the layers blend over 14 pixels.
proc wind {y} {
    set w 0.0
    foreach l [level winds] {
        lassign $l top bot speed
        if {$y >= $top && $y < $bot} { set w $speed }
    }
    return $w
}

proc world {} {
    global ink VW VH g
    .c delete all
    set W [level width]
    .c configure -scrollregion [list 0 0 $W $VH]
    # The sky: bands, stars, and the moon, which move with the camera.
    for {set k 0} {$k < 12} {incr k} {
        set t [expr {$k / 11.0}]
        .c create rectangle -40 [expr {$k * 20}] [expr {$VW + 40}] [expr {($k + 1) * 20}] -width 0 -fill [mixc $ink(sky0) $ink(sky2) $t] -tags sky
    }
    for {set k 0} {$k < 40} {incr k} {
        set x [expr {($k * 97) % $VW}]; set y [expr {($k * 53) % 150}]
        .c create rectangle $x $y [expr {$x + 1 + $k % 2}] [expr {$y + 1 + $k % 2}] -width 0 -fill [expr {$k % 3 ? "#7f93b8" : "#dfe8ff"}] -tags sky
    }
    .c create oval 300 18 352 70 -width 0 -fill $ink(moon) -tags sky
    .c create oval 312 30 322 40 -width 0 -fill #e2d3a8 -tags sky
    .c create oval 330 46 340 54 -width 0 -fill #e2d3a8 -tags sky
    # The far hills at half speed.
    set pts {}; for {set x 0} {$x <= $W / 2 + $VW} {incr x 30} { lappend pts $x [expr {175 + 18 * sin($x / 47.0) + 10 * sin($x / 13.0)}] }
    .c create polygon 0 $VH {*}$pts [expr {$W / 2 + $VW}] $VH -width 0 -fill #16213a -tags far
    # The layers of wind: a faint line at each border, and an arrow.
    foreach l [level winds] {
        lassign $l top bot speed
        if {$top > 0} { .c create line 0 $top $W $top -fill #243756 -dash {4 6} -tags layer }
        set mid [expr {($top + $bot) / 2}]
        for {set x 60} {$x < $W} {incr x 240} {
            set a [expr {$speed > 0.05 ? "▶" : $speed < -0.05 ? "◀" : "●"}]
            .c create text $x $mid -text $a -fill #2f4770 -font {TkFixedFont 9 bold} -tags layer
        }
    }
    .c create polygon 0 $VH {*}[level ground] $W $VH -width 0 -fill $ink(ground) -tags ground
    .c create line {*}[level ground] -fill $ink(ridge) -width 2 -tags ground
    lassign [level pad] x0 x1 y
    .c create rectangle $x0 [expr {$y - 4}] $x1 $y -width 0 -fill $ink(pad) -tags pad
    .c create rectangle [expr {$x0 + 4}] [expr {$y - 12}] [expr {$x0 + 6}] [expr {$y - 4}] -width 0 -fill $ink(pad) -tags pad
    .c create rectangle [expr {$x1 - 6}] [expr {$y - 12}] [expr {$x1 - 4}] [expr {$y - 4}] -width 0 -fill $ink(pad) -tags pad
    .c create oval [expr {$x0 + 2}] [expr {$y - 17}] [expr {$x0 + 8}] [expr {$y - 11}] -width 0 -fill #c8ffe6 -tags "pad padlight"
    .c create oval [expr {$x1 - 8}] [expr {$y - 17}] [expr {$x1 - 2}] [expr {$y - 11}] -width 0 -fill #c8ffe6 -tags "pad padlight"
    set k 0
    foreach m [level motes] {
        lassign $m x y
        .c create oval [expr {$x - 7}] [expr {$y - 7}] [expr {$x + 7}] [expr {$y + 7}] -width 0 -fill #1f3a55 -tags "mote m$k"
        .c create oval [expr {$x - 3}] [expr {$y - 3}] [expr {$x + 3}] [expr {$y + 3}] -width 0 -fill $ink(mote) -tags "mote m$k"
        incr k
    }
    # The wind streaks: short lines that move with the wind of their layer.
    for {set k 0} {$k < 26} {incr k} { .c create line 0 0 1 1 -fill #4c6a96 -width 1 -tags "streak s$k" }
    # The balloon: the envelope in two stripes, ropes, a basket, a flame.
    .c create oval 0 0 1 1 -width 0 -fill $ink(env1) -tags "bal benv"
    .c create polygon 0 0 1 1 2 2 -width 0 -fill $ink(env2) -tags "bal bstripe"
    .c create polygon 0 0 1 1 2 2 -width 0 -fill $ink(env1) -tags "bal bneck"
    .c create line 0 0 1 1 -fill #c9b48a -tags "bal brope1"
    .c create line 0 0 1 1 -fill #c9b48a -tags "bal brope2"
    .c create rectangle 0 0 1 1 -width 0 -fill $ink(basket) -tags "bal bbasket"
    .c create oval 0 0 1 1 -width 0 -fill #ffcf5c -state hidden -tags "bal bflame"
    for {set k 0} {$k < 18} {incr k} { .c create rectangle -9 -9 -8 -8 -width 0 -fill #ffcf5c -tags "part p$k" }
    set g(motes) 0
    set g(skyX) 0
}
proc mixc {a b t} {
    scan $a #%2x%2x%2x r1 g1 b1; scan $b #%2x%2x%2x r2 g2 b2
    format #%02x%02x%02x [expr {int($r1 + ($r2 - $r1) * $t)}] [expr {int($g1 + ($g2 - $g1) * $t)}] [expr {int($b1 + ($b2 - $b1) * $t)}]
}

proc start {n} {
    global g b heat fuel toy streaks
    array set g [list state play level $n frames 0 shake 0 hold 0 layer -1 cam 0]
    set toy(music) play
    world
    lassign [level start] x y
    array set b [list x $x y [expr {$y - 1}] vx 0 vy 0 temp 0.3 sway 0 swayV 0 landed 1]
    set heat 0.3; set fuel [level fuel]
    set streaks {}
    for {set k 0} {$k < 26} {incr k} { lappend streaks [list [expr {rand() * $::VW}] [expr {10 + rand() * 190}]] }
    .side.score configure -text "[expr {$n + 1}]/5"
    say [level name] "Up: more heat. Land on the green pad."
}

proc say {a b2} {
    global VW
    .c delete msg
    if {$a eq "" && $b2 eq ""} return
    set x [expr {([info exists ::g(skyX)] ? $::g(skyX) : 0) + $VW / 2}]
    .c create rectangle [expr {$x - 150}] 74 [expr {$x + 150}] 136 -width 1 -outline #2f4770 -fill $::ink(sky0) -tags msg
    .c create text $x 94 -text $a -fill $::ink(text) -font {TkFixedFont 15 bold} -tags msg
    .c create text $x 120 -text $b2 -fill $::ink(dim) -font {TkFixedFont 9 bold} -tags msg
    set ::g(msgT) 180
}

proc burst {x y n color {vy 0}} {
    global parts
    for {set k 0} {$k < $n} {incr k} {
        set a [expr {rand() * 6.283}]; set s [expr {0.4 + rand() * 1.4}]
        lappend parts [list $x $y [expr {cos($a) * $s}] [expr {sin($a) * $s + $vy}] [expr {18 + int(rand() * 16)}] $color]
    }
    set parts [lrange $parts end-17 end]
}

proc tick {} {
    global g
    after 16 tick
    incr g(frames)
    if {$g(state) eq "title"} { titleTick; draw; return }
    if {$g(state) eq "play"} { step }
    draw
}

proc step {} {
    global g b heat fuel VW VH
    # The keys move the scale; the scale sets the burner.
    if {$g(hold)} { set heat [expr {max(0.0, min(1.0, $heat + $g(hold) * 0.025))}] }
    if {$fuel <= 0} { set heat 0 }
    # Warm air follows the burner with a lag: the balloon is slow to answer.
    set b(temp) [expr {$b(temp) + ($heat - $b(temp)) * 0.025}]
    set lift [expr {($b(temp) - 0.42) * 0.09}]
    set b(vy) [expr {($b(vy) - $lift + 0.0) * 0.985}]
    set b(vy) [expr {max(-1.6, min(2.2, $b(vy)))}]
    set fuel [expr {max(0, $fuel - $heat * 0.045)}]
    if {$heat > 0.55 && $g(frames) % 9 == 0} { sfx burn; burst $b(x) [expr {$b(y) - 22}] 1 #ffcf5c -0.6 }
    # The wind of the layer moves the balloon; it takes a moment to change.
    set w [wind $b(y)]
    set ax [expr {($w - $b(vx)) * 0.03}]
    if {$b(landed)} { set ax [expr {-$b(vx) * 0.3}] }
    set b(vx) [expr {$b(vx) + $ax}]
    # The basket swings when the balloon speeds up.
    set b(swayV) [expr {($b(swayV) - $ax * 2.2 - $b(sway) * 0.04) * 0.96}]
    set b(sway) [expr {$b(sway) + $b(swayV)}]
    set layer [lsearch -exact [lmap l [level winds] {expr {$b(y) >= [lindex $l 0] && $b(y) < [lindex $l 1]}}] 1]
    if {$layer != $g(layer)} { if {$g(layer) >= 0} { sfx gust }; set g(layer) $layer }
    set b(x) [expr {$b(x) + $b(vx)}]
    set b(y) [expr {$b(y) + $b(vy)}]
    set W [level width]
    if {$b(x) < 14} { set b(x) 14; set b(vx) 0 }
    if {$b(x) > $W - 14} { set b(x) [expr {$W - 14}]; set b(vx) 0 }
    # The envelope stays in the view: the sky has a ceiling.
    if {$b(y) < 72} { set b(y) 72; set b(vy) [expr {max(0, $b(vy))}] }
    # The ground: a soft touch lands, a fast one crashes.
    set gy [groundY $b(x)]
    if {$b(y) >= $gy} {
        # A wall of the ground, such as a spire, is a crash too.
        if {$b(vy) > 1.5 || abs($b(sway)) > 12 || $b(y) - $gy > 6} { set b(y) $gy; crash; return }
        set b(y) $gy
        if {!$b(landed) && $b(vy) > 0.3} { sfx land; burst $b(x) $gy 6 #8fa3bf; if {$b(vy) > 0.8} { set g(shake) 4 } }
        set b(vy) 0; set b(landed) 1
        lassign [level pad] x0 x1 py
        if {$b(x) > $x0 + 4 && $b(x) < $x1 - 4 && abs($gy - $py) < 3 && $g(frames) > 60} { landed; return }
    } elseif {$b(y) < $gy - 2} { set b(landed) 0 }
    # The motes.
    set k 0
    foreach m [level motes] {
        lassign $m mx my
        if {[.c itemcget m$k -state] ne "hidden" && hypot($mx - $b(x), $my - ($b(y) - 24)) < 18} {
            .c itemconfigure m$k -state hidden
            incr g(motes); sfx pickup; burst $mx $my 10 #b9f0ff
        }
        incr k
    }
    # The camera follows the balloon, a third of the view ahead of it.
    set want [expr {max(0, min($W - $VW, $b(x) - $VW / 2 + $b(vx) * 40))}]
    set g(cam) [expr {$g(cam) + ($want - $g(cam)) * 0.08}]
    if {[info exists g(msgT)] && $g(msgT) > 0 && [incr g(msgT) -1] == 0} { say "" "" }
}

proc crash {} {
    global g b toy
    set g(state) crashed; set toy(music) ""
    sfx crash; set g(shake) 12
    burst $b(x) [expr {$b(y) - 20}] 18 #f2a541
    say "Too fast" "Touch down slowly.  A: try again"
}
proc landed {} {
    global g b fuel best toy
    set n $g(level)
    set score [expr {int($fuel) * 10 + $g(motes) * 250}]
    set new [expr {![info exists best($n)] || $score > $best($n)}]
    if {$new} { set best($n) $score }
    set g(unlocked) [expr {max($g(unlocked), min([llength $::levels], $n + 2))}]
    save
    set g(state) landed; set toy(music) ""; sfx win
    burst $b(x) [expr {$b(y) - 30}] 16 #6fd3a8
    say "Delivered: $score" "[expr {$new ? "New best" : "Best $best($n)"}].  A: next   B: again"
}

proc draw {} {
    global g b parts VW streaks heat
    set ox 0; set oy 0
    if {$g(shake) > 0} { if {!$::toy(calm)} { set ox [expr {(rand() - 0.5) * $g(shake)}]; set oy [expr {(rand() - 0.5) * $g(shake)}] }; incr g(shake) -1 }
    set W [level width]
    set cam [expr {$g(cam) + $ox}]
    # The left edge of the view, as xview sets it from the fraction.
    set cx [expr {max(0.0, min($W - $VW, $cam))}]
    .c xview moveto [expr {$cx / double($W)}]
    # The sky stays; the far hills move at half the speed.
    set d [expr {$cx - $g(skyX)}]
    .c move sky $d 0
    .c move far [expr {$d * 0.5}] 0
    set g(skyX) $cx
    .c move msg [expr {$cx - [expr {[info exists g(msgX)] ? $g(msgX) : $cx}]}] 0
    set g(msgX) $cx
    # The streaks of wind.
    set out {}; set k 0
    foreach s $streaks {
        lassign $s sx sy
        set sx [expr {$sx + [wind $sy] * 1.6}]
        if {$sx > $VW + 20} { set sx -20 } elseif {$sx < -20} { set sx [expr {$VW + 20}] }
        set len [expr {abs([wind $sy]) * 9}]
        .c coords s$k [expr {$cx + $sx}] $sy [expr {$cx + $sx + ($len < 1 ? 1 : $len)}] $sy
        lappend out [list $sx $sy]; incr k
    }
    set streaks $out
    # The balloon.
    set x $b(x); set y [expr {$b(y) + $oy}]
    set top [expr {$y - 62}]
    set inflate [expr {$g(state) eq "crashed" ? 0.6 : 1.0}]
    set r [expr {19 * $inflate}]
    .c coords benv [expr {$x - $r}] $top [expr {$x + $r}] [expr {$top + 2 * $r + 4}]
    .c coords bstripe [expr {$x - 5}] [expr {$top + 1}] [expr {$x + 5}] [expr {$top + 1}] [expr {$x + 4}] [expr {$top + 2 * $r + 3}] [expr {$x - 4}] [expr {$top + 2 * $r + 3}]
    set nb [expr {$top + 2 * $r + 2}]
    .c coords bneck [expr {$x - 9}] [expr {$nb - 4}] [expr {$x + 9}] [expr {$nb - 4}] [expr {$x + 4}] [expr {$nb + 6}] [expr {$x - 4}] [expr {$nb + 6}]
    set bx [expr {$x + $b(sway)}]; set by [expr {$y - 9}]
    .c coords brope1 [expr {$x - 4}] [expr {$nb + 6}] [expr {$bx - 5}] $by
    .c coords brope2 [expr {$x + 4}] [expr {$nb + 6}] [expr {$bx + 5}] $by
    .c coords bbasket [expr {$bx - 6}] $by [expr {$bx + 6}] [expr {$y - 1}]
    set fl [expr {$heat * 6 + sin($g(frames) * 0.6) * 1.2}]
    if {$g(state) eq "play" && $heat > 0.05} {
        .c itemconfigure bflame -state normal
        .c coords bflame [expr {$x - 2.5}] [expr {$nb + 6 - $fl}] [expr {$x + 2.5}] [expr {$nb + 8}]
    } else { .c itemconfigure bflame -state hidden }
    set keep {}; set k 0
    foreach p $parts {
        lassign $p px py vx vy life color
        if {[incr life -1] <= 0 || $k >= 18} continue
        set px [expr {$px + $vx}]; set py [expr {$py + $vy}]; set vy [expr {$vy + 0.03}]
        .c coords p$k $px $py [expr {$px + 2}] [expr {$py + 2}]
        .c itemconfigure p$k -fill $color
        lappend keep [list $px $py $vx $vy $life $color]; incr k
    }
    for {} {$k < 18} {incr k} { .c coords p$k -9 -9 -8 -8 }
    set parts $keep
    if {$g(frames) % 30 == 0} { .c itemconfigure padlight -fill [expr {$g(frames) % 60 ? "#c8ffe6" : "#3c8a6a"}] }
    if {$g(state) ne "title"} { .side.score configure -text "● $g(motes)" }
}

# The title: the balloon drifts over the first level, with the picker.
proc title {} {
    global g best toy ink VW
    set g(state) title; set toy(music) title
    set lv $g(pick); set g(level) 0
    world
    array set ::b {x 200 y 150 vx 0 vy 0 sway 0 swayV 0 landed 0}
    set ::streaks {}
    for {set k 0} {$k < 26} {incr k} { lappend ::streaks [list [expr {rand() * $VW}] [expr {10 + rand() * 190}]] }
    set g(cam) 0
    .c create text 210 70 -text "TIN MOON" -fill $ink(text) -font {TkFixedFont 26 bold} -tags title
    .c create text 210 104 -text "◀  [expr {$lv + 1}]. [lindex $::levels $lv 0]  ▶" -fill $ink(text) -font {TkFixedFont 11 bold} -tags title
    .c create text 210 124 -text [expr {[info exists best($lv)] ? "best $best($lv)" : "not flown yet"}] -fill $ink(dim) -font {TkFixedFont 9} -tags title
    .c create text 210 222 -text "A: fly     Left, Right: level" -fill $ink(dim) -font {TkFixedFont 9 bold} -tags "title blink"
    .side.score configure -text "[expr {$g(unlocked)}]/5"
}
proc titleTick {} {
    global g b
    set b(x) [expr {290 + 60 * sin($g(frames) * 0.01)}]
    set b(y) [expr {176 + 8 * sin($g(frames) * 0.03)}]
    set b(sway) [expr {3 * sin($g(frames) * 0.05)}]
    set ::heat [expr {0.5 + 0.3 * sin($g(frames) * 0.03)}]
    if {$g(frames) % 40 == 0} { .c itemconfigure blink -state [expr {$g(frames) % 80 ? "hidden" : "normal"}] }
}

title
tick
