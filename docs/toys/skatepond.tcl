# title: Skate Pond
# widget: listbox
# page: docs/widgets/listbox.md
# pitch: A sliding puzzle on a frozen pond. The listbox is your bag: pick up a plank or a pick on the ice, select it, and use it.
# order: 2

# Skate Pond. A push sends the skater over the ice until something stops
# it: a snowbank, a rock, or a patch of snow. Open water ends the run.
# Reach the flag. The listbox on the right is the bag: a plank on the ice
# goes in it, and A lays the selected plank on the water in front of
# you. A pick breaks the rock in front of you. B takes back a move.
# Each level has three stars: the flag, the flag within par, and each
# snowflake on the way.

array set toy {sfx {} music title save {} calm 0}
proc sfx {name} { lappend ::toy(sfx) $name }
set T 28; set COLS 12; set ROWS 9

# The levels, checked with a solver: each one has a way to the flag.
set levels {
    {"First Ice" 2 {
        ############
        #S........##
        #.........##
        #.........##
        #.........##
        #.........##
        #.........##
        #........F##
        ############
    }}
    {"Snow Stops" 2 {
        ############
        #S....=....#
        #..........#
        #..........#
        #..........#
        #.....F....#
        #..........#
        #..........#
        ############
    }}
    {"Thin Spot" 3 {
        ############
        #S.......#.#
        #..........#
        #.ooooo....#
        #.........##
        #*.#.......#
        #..........#
        #......#..F#
        ############
    }}
    {"A Plank" 6 {
        ############
        #S..P....#.#
        #........#.#
        #.......=#.#
        #oooooooo#.#
        #..........#
        #.*.....=..#
        #F.........#
        ############
    }}
    {"The Pick" 6 {
        ############
        #S..K...#..#
        #.##.......#
        #..........#
        #......#...#
        #..*.......#
        #RRRRRRRRRR#
        #....F.....#
        ############
    }}
    {"Crossing" 5 {
        ############
        #S......P.R#
        #..........#
        #.#......=.#
        #oooooooooo#
        #........*.#
        #....#.....#
        #.....F....#
        ############
    }}
    {"Long Night" 7 {
        ############
        #S.#......P#
        #.......#..#
        #=...#.....#
        #..........#
        #.#..*....=#
        #oooooooooo#
        #RRRRRRRRRF#
        ############
    }}
}

set ink(bg) #0f1b2d; set ink(panel) #14233a; set ink(text) #eef5fb; set ink(dim) #8fa9c4
set ink(ice) #d4ebf7; set ink(ice2) #c6e2f2; set ink(crack) #a9cde4; set ink(snow) #f6fafd
set ink(shadow) #9dbad2; set ink(rock) #6f7d90; set ink(rock2) #9aa8ba; set ink(water) #1b3a66
set ink(red) #e5484d; set ink(gold) #ffc93c; set ink(flake) #3f8fd8

ztk::style add {
    Listbox { background-color: #14233a; color: #eef5fb; border: 1px solid #2c4566; border-radius: 6px; }
}
. configure -background $ink(bg)
canvas .c -width [expr {$T * $COLS}] -height [expr {$T * $ROWS}] -background $ink(bg) -highlightthickness 0
frame .side -background $ink(bg)
label .side.name -background $ink(bg) -foreground $ink(text) -font {TkFixedFont 11 bold} -anchor w -justify left
label .side.moves -background $ink(bg) -foreground $ink(dim) -font {TkFixedFont 9 bold} -anchor w
label .side.stars -background $ink(bg) -foreground $ink(gold) -font {TkFixedFont 10 bold} -anchor w
label .side.bagT -text "BAG" -background $ink(bg) -foreground $ink(dim) -font {TkFixedFont 9 bold} -anchor w
listbox .side.bag -height 5 -width 12 -activestyle none -font {TkFixedFont 10 bold} -exportselection 0 \
    -selectbackground $ink(gold) -selectforeground $ink(bg) -highlightthickness 0
label .side.hint -background $ink(bg) -foreground $ink(dim) -font {TkFixedFont 8} -anchor nw -justify left
pack .c -side left -padx {6 4} -pady 9
pack .side -side left -fill both -expand 1 -pady 9 -padx {0 6}
pack .side.name .side.moves .side.stars .side.bagT -fill x
pack .side.bag -fill x -pady {2 6}
pack .side.hint -fill both -expand 1
bind .side.bag <<ListboxSelect>> hint

array set g {state title level 0 pick 0 unlocked 1 frames 0 moves 0 shake 0 dead 0 card 0}
set cardseq 0
array set stars {}
array set sk {x 1 y 1 dx 0 dy 1 px 0 py 0 fx 0 fy 0 t 1 n 1 sx 1 sy 1 queue {}}
set undo {}
set parts {}

proc toy_restore {data} {
    global g stars
    if {[catch {dict get $data unlocked} u]} return
    set g(unlocked) [expr {max(1, min([llength $::levels], $u))}]
    if {![catch {dict get $data stars} s]} { array set stars $s }
    title
}
proc save {} { set ::toy(save) [list unlocked $::g(unlocked) stars [array get ::stars]] }

proc tile {x y} { lindex $::grid $y $x }
proc setTile {x y c} { lset ::grid $y $x $c }

proc toy_input {key state} {
    global g sk
    if {$state ne "press"} return
    switch $g(state) {
        title {
            switch $key {
                left { if {$g(pick) > 0} { incr g(pick) -1; sfx move; title } }
                right { if {$g(pick) < $g(unlocked) - 1} { incr g(pick); sfx move; title } }
                a - start { sfx start; start $g(pick) }
            }
        }
        play {
            switch $key {
                up - down - left - right {
                    # A press during a slide waits for its end (the buffer).
                    if {$sk(t) < 1} { set sk(queue) $key } else { push $key }
                }
                a { use }
                b { back }
                start { start $g(level) }
            }
        }
        clear {
            if {$key in {a start}} {
                if {$g(level) + 1 < [llength $::levels]} { sfx start; start [expr {$g(level) + 1}] } else { set g(pick) 0; title }
            } elseif {$key eq "b"} { start $g(level) }
        }
    }
}

# Draws the pond of the level.
proc pond {} {
    global grid T COLS ROWS ink
    .c delete all
    for {set y 0} {$y < $ROWS} {incr y} {
        for {set x 0} {$x < $COLS} {incr x} {
            set x0 [expr {$x * $T}]; set y0 [expr {$y * $T}]; set x1 [expr {$x0 + $T}]; set y1 [expr {$y0 + $T}]
            set c [tile $x $y]
            set ice [expr {($x + $y) % 2 ? $ink(ice) : $ink(ice2)}]
            .c create rectangle $x0 $y0 $x1 $y1 -width 0 -fill $ice -tags "ice t$x,$y"
            if {($x * 7 + $y * 3) % 5 == 0} { .c create line [expr {$x0 + 5}] [expr {$y0 + 9}] [expr {$x0 + 14}] [expr {$y0 + 6}] [expr {$x0 + 20}] [expr {$y0 + 12}] -fill $ink(crack) -tags "t$x,$y" }
            switch $c {
                # {
                    .c create rectangle $x0 $y0 $x1 $y1 -width 0 -fill $ink(snow) -tags "t$x,$y"
                    .c create rectangle $x0 [expr {$y1 - 5}] $x1 $y1 -width 0 -fill $ink(shadow) -tags "t$x,$y"
                }
                o { water $x $y }
                = {
                    .c create rectangle [expr {$x0 + 2}] [expr {$y0 + 2}] [expr {$x1 - 2}] [expr {$y1 - 2}] -width 0 -fill $ink(snow) -tags "t$x,$y"
                    foreach {a b} {7 8 16 12 10 19 20 21} { .c create rectangle [expr {$x0 + $a}] [expr {$y0 + $b}] [expr {$x0 + $a + 2}] [expr {$y0 + $b + 2}] -width 0 -fill $ink(shadow) -tags "t$x,$y" }
                }
                R { rock $x $y }
                F {
                    .c create line [expr {$x0 + 9}] [expr {$y0 + 4}] [expr {$x0 + 9}] [expr {$y1 - 3}] -fill #3a4a60 -width 2 -tags "t$x,$y"
                    .c create polygon [expr {$x0 + 10}] [expr {$y0 + 4}] [expr {$x0 + 23}] [expr {$y0 + 9}] [expr {$x0 + 10}] [expr {$y0 + 14}] -fill $ink(red) -width 0 -tags "flag t$x,$y"
                    .c create oval [expr {$x0 + 5}] [expr {$y1 - 5}] [expr {$x0 + 14}] [expr {$y1 - 2}] -width 0 -fill $ink(shadow) -tags "t$x,$y"
                }
                * { flake $x $y }
                P { .c create rectangle [expr {$x0 + 5}] [expr {$y0 + 11}] [expr {$x1 - 5}] [expr {$y0 + 17}] -fill #a8743c -outline #6e4a22 -tags "item t$x,$y" }
                K {
                    .c create line [expr {$x0 + 14}] [expr {$y0 + 8}] [expr {$x0 + 14}] [expr {$y1 - 6}] -fill #6e4a22 -width 3 -tags "item t$x,$y"
                    .c create line [expr {$x0 + 6}] [expr {$y0 + 10}] [expr {$x0 + 14}] [expr {$y0 + 7}] [expr {$x0 + 22}] [expr {$y0 + 10}] -fill #5c6b7e -width 3 -tags "item t$x,$y"
                }
            }
        }
    }
    # The skater: skates, a coat, a scarf, and a face.
    .c create rectangle 0 0 1 1 -width 0 -fill #24324a -tags "sk skcoat"
    .c create rectangle 0 0 1 1 -width 0 -fill $ink(red) -tags "sk skscarf"
    .c create rectangle 0 0 1 1 -width 0 -fill $ink(red) -tags "sk sktail"
    .c create oval 0 0 1 1 -width 0 -fill #f2d2ac -tags "sk skface"
    .c create rectangle 0 0 1 1 -width 0 -fill #c9d4e0 -tags "sk skblade"
    for {set k 0} {$k < 16} {incr k} { .c create rectangle -9 -9 -8 -8 -width 0 -fill white -tags "part p$k" }
    .c create rectangle 40 86 296 168 -width 2 -outline #2c4566 -fill $ink(bg) -state hidden -tags msgbox
    .c create text [expr {$COLS * $T / 2}] [expr {$ROWS * $T / 2 - 12}] -fill $ink(text) -font {TkFixedFont 16 bold} -tags msg
    .c create text [expr {$COLS * $T / 2}] [expr {$ROWS * $T / 2 + 16}] -fill $ink(dim) -font {TkFixedFont 9 bold} -tags msg2
}
proc water {x y} {
    global T ink
    set x0 [expr {$x * $T}]; set y0 [expr {$y * $T}]
    .c create rectangle $x0 $y0 [expr {$x0 + $T}] [expr {$y0 + $T}] -width 0 -fill $ink(water) -tags "water t$x,$y"
    .c create line [expr {$x0 + 5}] [expr {$y0 + 10}] [expr {$x0 + 13}] [expr {$y0 + 10}] -fill #3f6aa8 -width 2 -tags "ripple t$x,$y"
    .c create line [expr {$x0 + 14}] [expr {$y0 + 19}] [expr {$x0 + 23}] [expr {$y0 + 19}] -fill #3f6aa8 -width 2 -tags "ripple t$x,$y"
}
proc rock {x y} {
    global T ink
    set x0 [expr {$x * $T}]; set y0 [expr {$y * $T}]
    .c create oval [expr {$x0 + 3}] [expr {$y0 + 6}] [expr {$x0 + 25}] [expr {$y0 + 26}] -width 0 -fill $ink(rock) -tags "rock t$x,$y"
    .c create oval [expr {$x0 + 7}] [expr {$y0 + 9}] [expr {$x0 + 15}] [expr {$y0 + 14}] -width 0 -fill $ink(rock2) -tags "rock t$x,$y"
}
proc flake {x y} {
    global T ink
    set cx [expr {$x * $T + 14}]; set cy [expr {$y * $T + 14}]
    foreach {a b} {0 7 6 4 6 -4} { .c create line [expr {$cx - $a}] [expr {$cy - $b}] [expr {$cx + $a}] [expr {$cy + $b}] -fill $ink(flake) -width 2 -tags "flake t$x,$y" }
}
# Puts plain ice on a tile.
proc clearTile {x y} {
    global T ink
    .c delete t$x,$y
    set x0 [expr {$x * $T}]; set y0 [expr {$y * $T}]
    .c create rectangle $x0 $y0 [expr {$x0 + $T}] [expr {$y0 + $T}] -width 0 -fill [expr {($x + $y) % 2 ? $ink(ice) : $ink(ice2)}] -tags "ice t$x,$y"
    .c lower t$x,$y sk
    .c lower t$x,$y part
}

proc start {n} {
    global g levels grid sk undo toy flakes bag
    array set g [list state play level $n moves 0 frames 0 dead 0]
    set toy(music) play
    lassign [lindex $levels $n] name par rows
    set grid {}
    set y 0
    foreach row $rows {
        set r [split $row ""]
        set x [lsearch $r S]
        if {$x >= 0} { set sk(x) $x; set sk(y) $y; lset r $x . }
        lappend grid $r
        incr y
    }
    array set sk {dx 0 dy 1 t 1 n 1 sx 1 sy 1 queue {}}
    set sk(fx) $sk(x); set sk(fy) $sk(y)
    set undo {}; set flakes 0; set bag {}
    .side.bag delete 0 end
    pond
    side
    say $name "Par $par"
    set g(card) [incr ::cardseq]
    after 900 [list cardOff $g(card)]
}

# Hides the level card: at the first action of the player, or after a
# short time. The number makes sure an old timer does not hide the card
# of a later level.
proc cardOff {id} {
    global g
    if {$g(state) eq "play" && $g(card) == $id} { say "" ""; set g(card) 0 }
}

proc say {a b} {
    .c itemconfigure msg -text $a; .c itemconfigure msg2 -text $b
    .c itemconfigure msgbox -state [expr {$a eq "" && $b eq "" ? "hidden" : "normal"}]
    .c delete msgstar
}
# Three stars on the canvas: gold for each one that you got.
proc stars {x y n tag} {
    for {set k 0} {$k < 3} {incr k} {
        set cx [expr {$x + ($k - 1) * 26}]; set pts {}
        for {set i 0} {$i < 10} {incr i} {
            set r [expr {$i % 2 ? 4.5 : 11}]; set a [expr {-1.5708 + $i * 0.6283}]
            lappend pts [expr {$cx + $r * cos($a)}] [expr {$y + $r * sin($a)}]
        }
        .c create polygon {*}$pts -fill [expr {$k < $n ? "#ffc93c" : "#2c4566"}] -outline [expr {$k < $n ? "#ffe08a" : "#4a6a90"}] -tags $tag
    }
}

# The labels and the hint of the side panel.
proc side {} {
    global g levels flakes
    lassign [lindex $levels $g(level)] name par rows
    .side.name configure -text "[expr {$g(level) + 1}]. $name"
    .side.moves configure -text "MOVES $g(moves)  PAR $par"
    set total [regexp -all {\*} [join $rows ""]]
    .side.stars configure -text [expr {$total ? "FLAKES $flakes/$total" : ""}]
    hint
}
proc hint {} {
    set i [.side.bag curselection]
    if {$i eq ""} {
        .side.hint configure -text "Arrows: push\nB: undo\nEnter: restart"
    } else {
        set item [.side.bag get $i]
        .side.hint configure -text [expr {$item eq "Plank" ? "A: lay the plank\non the water\nin front of you." : "A: break the rock\nin front of you."}]
    }
}

# A push: the skater slides to the first stop. The slide is a tween with
# an ease-out, so a long slide is fast and settles at the end.
proc push {dir} {
    global sk grid g undo flakes bag
    if {$g(card)} { cardOff $g(card) }
    lassign [dict get {up {0 -1} down {0 1} left {-1 0} right {1 0}} $dir] dx dy
    set sk(dx) $dx; set sk(dy) $dy
    set x $sk(x); set y $sk(y); set dist 0; set end stop
    while 1 {
        set nx [expr {$x + $dx}]; set ny [expr {$y + $dy}]
        set c [tile $nx $ny]
        if {$c in {# R}} break
        set x $nx; set y $ny; incr dist
        if {$c eq "o"} { set end water; break }
        if {$c eq "="} { set end snow; break }
        if {$c eq "F"} { set end flag; break }
    }
    if {$dist == 0} {
        # A push into a wall turns the skater and bumps.
        set sk(sx) 1.25; set sk(sy) 0.8; sfx bump; return
    }
    lappend undo [list $sk(x) $sk(y) $grid $flakes $bag $g(moves)]
    incr g(moves)
    set sk(fx) $sk(x); set sk(fy) $sk(y); set sk(x) $x; set sk(y) $y
    set sk(t) 0; set sk(n) [expr {max(7, min(26, 5 + $dist * 3))}]; set sk(end) $end
    sfx slide
    side
}

# The tiles that the skater crossed: snowflakes and items.
proc crossed {x y} {
    global flakes bag
    set c [tile $x $y]
    if {$c eq "*"} { setTile $x $y .; clearTile $x $y; incr flakes; sfx pickup; burst [expr {$x * $::T + 14}] [expr {$y * $::T + 14}] 8 #7ec8ff; side }
    if {$c in {P K}} {
        setTile $x $y .; clearTile $x $y
        set name [expr {$c eq "P" ? "Plank" : "Pick"}]
        lappend bag $c
        .side.bag insert end $name
        .side.bag itemconfigure end -foreground [expr {$c eq "P" ? "#e0a86a" : "#b8c6d8"}]
        .side.bag selection clear 0 end
        .side.bag selection set end
        .side.bag see end
        sfx pickup; burst [expr {$x * $::T + 14}] [expr {$y * $::T + 14}] 8 #ffc93c
        hint
    }
}

proc use {} {
    global sk bag grid g undo flakes
    if {$g(card)} { cardOff $g(card) }
    set i [.side.bag curselection]
    if {$i eq "" || $sk(t) < 1} { sfx bump; return }
    set item [lindex $bag $i]
    set x [expr {$sk(x) + $sk(dx)}]; set y [expr {$sk(y) + $sk(dy)}]
    set c [tile $x $y]
    if {($item eq "P" && $c ne "o") || ($item eq "K" && $c ne "R")} {
        set ::g(shake) 4; sfx bump
        .side.hint configure -text [expr {$item eq "P" ? "Face open water\nto lay the plank." : "Face a rock\nto break it."}]
        return
    }
    lappend undo [list $sk(x) $sk(y) $grid $flakes $bag $g(moves)]
    incr g(moves)
    setTile $x $y .; clearTile $x $y
    if {$item eq "P"} {
        .c create rectangle [expr {$x * $::T + 1}] [expr {$y * $::T + 4}] [expr {$x * $::T + 27}] [expr {$y * $::T + 24}] -fill #a8743c -outline #6e4a22 -tags "t$x,$y"
        .c lower t$x,$y sk
        sfx land
    } else { sfx crash; set g(shake) 6; burst [expr {$x * $::T + 14}] [expr {$y * $::T + 14}] 12 #9aa8ba }
    set bag [lreplace $bag $i $i]
    .side.bag delete $i
    if {[llength $bag]} { .side.bag selection set 0 }
    side
}

proc back {} {
    global undo sk grid flakes bag g
    if {![llength $undo] || $sk(t) < 1} return
    lassign [lindex $undo end] sk(x) sk(y) grid flakes bag g(moves)
    set undo [lrange $undo 0 end-1]
    set sk(fx) $sk(x); set sk(fy) $sk(y)
    pond
    .side.bag delete 0 end
    foreach c $bag { .side.bag insert end [expr {$c eq "P" ? "Plank" : "Pick"}]; .side.bag itemconfigure end -foreground [expr {$c eq "P" ? "#e0a86a" : "#b8c6d8"}] }
    if {[llength $bag]} { .side.bag selection set 0 }
    set g(dead) 0; set g(state) play
    say "" ""; sfx undo; side
}

proc burst {x y n color} {
    global parts
    for {set k 0} {$k < $n} {incr k} {
        set a [expr {rand() * 6.283}]; set s [expr {0.5 + rand() * 1.6}]
        lappend parts [list $x $y [expr {cos($a) * $s}] [expr {sin($a) * $s}] [expr {18 + int(rand() * 14)}] $color]
    }
    set parts [lrange $parts end-15 end]
}

proc tick {} {
    global g sk T
    after 16 tick
    incr g(frames)
    if {$g(state) eq "title"} { titleTick; draw; return }
    if {$sk(t) < 1} {
        set before [expr {int(($sk(fx) + ($sk(x) - $sk(fx)) * [easeOut $sk(t)]) + 0.5)}],[expr {int(($sk(fy) + ($sk(y) - $sk(fy)) * [easeOut $sk(t)]) + 0.5)}]
        set sk(t) [expr {min(1.0, $sk(t) + 1.0 / $sk(n))}]
        set e [easeOut $sk(t)]
        set cx [expr {int(($sk(fx) + ($sk(x) - $sk(fx)) * $e) + 0.5)}]; set cy [expr {int(($sk(fy) + ($sk(y) - $sk(fy)) * $e) + 0.5)}]
        # Each tile on the way: pick up what is on it.
        lassign [split $before ,] bx by
        while {$bx != $cx || $by != $cy} {
            if {$bx != $cx} { incr bx [expr {$cx > $bx ? 1 : -1}] } else { incr by [expr {$cy > $by ? 1 : -1}] }
            crossed $bx $by
        }
        if {$g(frames) % 2 == 0} { burst [expr {($sk(fx) + ($sk(x) - $sk(fx)) * $e) * $T + 14}] [expr {($sk(fy) + ($sk(y) - $sk(fy)) * $e) * $T + 24}] 1 #ffffff }
        if {$sk(t) >= 1} { arrive }
    } elseif {$sk(queue) ne "" && $g(state) eq "play"} {
        set k $sk(queue); set sk(queue) {}; push $k
    }
    if {$g(state) eq "dead" && [incr g(dead)] > 50} { back }
    draw
}
proc easeOut {t} { expr {1 - pow(1 - $t, 3)} }

proc arrive {} {
    global sk g T levels stars toy
    switch $sk(end) {
        stop { set sk(sx) [expr {$sk(dx) ? 0.75 : 1.25}]; set sk(sy) [expr {$sk(dy) ? 0.75 : 1.2}]; sfx bump; set g(shake) 3 }
        snow { set sk(sx) 1.15; set sk(sy) 0.85; sfx land; burst [expr {$sk(x) * $T + 14}] [expr {$sk(y) * $T + 22}] 8 #f6fafd }
        water {
            set g(state) dead; set g(dead) 0; set sk(queue) {}
            sfx hurt; set g(shake) 8
            burst [expr {$sk(x) * $T + 14}] [expr {$sk(y) * $T + 14}] 14 #7ec8ff
            say "Splash" "The run goes back one move"
        }
        flag {
            set lvl $g(level)
            lassign [lindex $levels $lvl] name par rows
            set total [regexp -all {\*} [join $rows ""]]
            set got [expr {1 + ($g(moves) <= $par) + ($::flakes == $total)}]
            if {![info exists stars($lvl)] || $got > $stars($lvl)} { set stars($lvl) $got }
            set g(unlocked) [expr {max($g(unlocked), min([llength $levels], $lvl + 2))}]
            save
            set g(state) clear; set toy(music) ""; sfx win
            burst [expr {$sk(x) * $T + 14}] [expr {$sk(y) * $T + 10}] 16 #ffc93c
            say "" "$g(moves) moves, par $par\nA: next    B: again"
            .c itemconfigure msgbox -state normal
            stars 168 114 $got msgstar
        }
    }
}

# Moves the skater and the particles to the state of the frame.
proc draw {} {
    global sk g T parts
    set e [easeOut $sk(t)]
    set ox 0; set oy 0
    if {$g(shake) > 0} { if {!$::toy(calm)} { set ox [expr {(rand() - 0.5) * $g(shake)}]; set oy [expr {(rand() - 0.5) * $g(shake)}] }; incr g(shake) -1 }
    set x [expr {($sk(fx) + ($sk(x) - $sk(fx)) * $e) * $T + 14 + $ox}]
    set y [expr {($sk(fy) + ($sk(y) - $sk(fy)) * $e) * $T + 25 + $oy}]
    if {$g(state) eq "dead"} { set y [expr {$y + min(10, $g(dead) / 3)}] }
    set sk(sx) [expr {$sk(sx) + (1 - $sk(sx)) * 0.2}]
    set sk(sy) [expr {$sk(sy) + (1 - $sk(sy)) * 0.2}]
    set w [expr {7 * $sk(sx)}]; set h [expr {20 * $sk(sy)}]
    # The skater leans into the slide.
    set lean [expr {$sk(t) < 1 ? $sk(dx) * 3 : 0}]
    .c coords skblade [expr {$x - $w - 1}] [expr {$y - 1}] [expr {$x + $w + 1}] $y
    .c coords skcoat [expr {$x - $w + $lean / 2}] [expr {$y - $h * 0.68}] [expr {$x + $w + $lean / 2}] [expr {$y - 2}]
    .c coords skscarf [expr {$x - $w + $lean}] [expr {$y - $h * 0.72}] [expr {$x + $w + $lean}] [expr {$y - $h * 0.6}]
    set tail [expr {$sk(t) < 1 ? -$sk(dx) * 9 : -3}]
    set wave [expr {sin($g(frames) * 0.4) * 2}]
    .c coords sktail [expr {$x + $lean + min(0, $tail)}] [expr {$y - $h * 0.72 + $wave}] [expr {$x + $lean + max(0, $tail)}] [expr {$y - $h * 0.62 + $wave}]
    .c coords skface [expr {$x - 5 + $lean}] [expr {$y - $h - 2}] [expr {$x + 5 + $lean}] [expr {$y - $h * 0.66}]
    set keep {}; set k 0
    foreach p $parts {
        lassign $p px py vx vy life color
        if {[incr life -1] <= 0 || $k >= 16} continue
        set px [expr {$px + $vx}]; set py [expr {$py + $vy}]; set vx [expr {$vx * 0.93}]; set vy [expr {$vy * 0.93}]
        .c coords p$k $px $py [expr {$px + 2}] [expr {$py + 2}]
        .c itemconfigure p$k -fill $color
        lappend keep [list $px $py $vx $vy $life $color]
        incr k
    }
    for {} {$k < 16} {incr k} { .c coords p$k -9 -9 -8 -8 }
    set parts $keep
    if {$g(frames) % 30 == 0} { .c move ripple [expr {$g(frames) % 60 ? 2 : -2}] 0 }
}

# The title: the first pond, the skater on a loop, and the level picker.
proc title {} {
    global g levels stars toy ink grid T COLS ROWS
    set g(state) title; set toy(music) title
    set grid {}
    foreach row [lindex $levels 0 2] { lappend grid [split [string map {S . F . o .} $row] ""] }
    pond
    .side.bag delete 0 end
    .c create rectangle 30 46 306 186 -width 0 -fill $ink(bg) -tags title
    .c create text 168 76 -text "SKATE POND" -fill $ink(text) -font {TkFixedFont 22 bold} -tags title
    set n $g(pick)
    set s [expr {[info exists stars($n)] ? $stars($n) : 0}]
    .c create text 168 110 -text "◀  [expr {$n + 1}]. [lindex $levels $n 0]  ▶" -fill $ink(text) -font {TkFixedFont 11 bold} -tags title
    stars 168 136 $s title
    .c create text 168 166 -text "A: skate      Left, Right: level" -fill $ink(dim) -font {TkFixedFont 9 bold} -tags "title blink"
    .c raise sk
    .side.name configure -text "Skate Pond"
    .side.moves configure -text "[expr {$g(unlocked)}] of [llength $levels] ponds open"
    set total 0; foreach k [array names stars] { incr total $stars($k) }
    .side.stars configure -text "STARS $total/[expr {3 * [llength $levels]}]"
    .side.hint configure -text "Ice stops only\nat snowbanks,\nrocks, and snow."
    array set ::sk {t 1 dx 1 dy 0 sx 1 sy 1 queue {}}
}
proc titleTick {} {
    global sk g
    # A slow loop around the box of the title.
    set a [expr {$g(frames) * 0.02}]
    set sk(fx) [expr {5.5 + 4.6 * cos($a)}]; set sk(fy) [expr {3.6 + 3.5 * sin($a) * cos($a)}]
    set sk(x) $sk(fx); set sk(y) $sk(fy); set sk(t) 1
    set sk(dx) [expr {-sin($a) > 0 ? 1 : -1}]
    if {$g(frames) % 40 == 0} { .c itemconfigure blink -state [expr {$g(frames) % 80 ? "hidden" : "normal"}] }
}

title
tick
