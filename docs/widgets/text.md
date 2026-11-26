# Text

**Live:** the [playground](https://beetlebug.org/ztk/play/index.html) runs the example below.

## text

![A text widget with a heading in bold, a line with a blue link, a selected word, and a list of steps with a hanging indent](../site/shots/widget-text-light.png)

<!-- widget: text; shot: update -->
```tcl
text .t -wrap word -undo 1 -width 30 -height 8 -yscrollcommand {.sb set}
scrollbar .sb -command {.t yview}
.t tag configure title -font {TkDefaultFont 14 bold} -spacing3 6
.t tag configure link -foreground #2563eb -underline 1
.t tag configure step -lmargin1 8 -lmargin2 24
.t insert end "Release notes\n" title
.t insert end "The text widget has tags, marks, undo, and smooth scrolling. See the " {} "manual page" link ".\n\n"
.t insert end "1. Type in the text. Control-z undoes a change.\n" step
.t insert end "2. Drag to select. A double click selects a word.\n" step
.t insert end "3. The wheel scrolls by pixels, with momentum on a touchpad.\n" step
.t tag bind link <Enter> {.t configure -cursor hand2}
.t tag bind link <Leave> {.t configure -cursor xterm}
.t tag add sel 2.4 2.8
pack .sb -side right -fill y
pack .t -side left -fill both -expand 1 -padx 8 -pady 8
focus .t
```

<!-- more: The details of text -->

- The text widget has the options, the indexes, and the subcommands of Tk 8.6: `bbox`, `compare`, `count`, `delete`, `dlineinfo`, `dump`, `edit`, `get`, `image`, `index`, `insert`, `mark`, `replace`, `search`, `see`, `tag`, `window`, `xview`, and `yview`. `peer` has no peers in ztk. An index has the forms and the modifiers of `text.n`, such as `insert wordend`, `end - 1 chars`, and `insert + 1 display lines`.
- Tags give text colors, fonts, underlines, margins, spacing, justification, and elided text. `tag bind` runs a script for the events of the tagged text, with `<Enter>` and `<Leave>` as the pointer moves between tags.
- `window create` puts a widget in the text, and `image create` puts a photo image in it. Each one has one place in the index space and moves with the text. `-align`, `-padx`, `-pady`, and `-stretch` place it in its line, and `-create` makes a window when the embed has none. `dump -window` and `dump -image` list them. A delete of the range of a window deletes the window.
- `search` finds exact text or a regular expression, forwards or backwards, with `-all`, `-count`, and `-nocase`. `dump` lists the text, the marks, and the tag edges of a range.
- Marks keep a place in the text with their gravity. `insert` is the caret and `current` is the character under the pointer.
- `-wrap char`, `word`, and `none` wrap the lines, and tabs go to the stops of `-tabs`. A buffer of 1 MB scrolls at the full frame rate: the widget lays out only the lines in the window.
- `-undo 1` turns on undo and redo, with `edit undo`, `edit redo`, `edit separator`, and Control-z. `<<Modified>>` comes when the text changes.
- The keys and the pointer edit the text as in `wish`. A scroll eases, and a touchpad scrolls by pixels with momentum. The caret blinks while the widget has the focus. Text from an input method shows at the caret until it is committed.
- The part `::selection` gives the colors of the tag `sel` in the modern theme.

<!-- end more -->

### Play: Pixel Pad

Pixel Pad is a game of stars and bombs, and the text widget holds its rules. The text under the screen is the body of a proc that runs in each frame and sets `x`, the place of the paddle. The paddle moves 5 pixels in each frame at most. Click the screen or press A to start, then click the text and edit the rule while the game runs: `set x $sx` follows the lowest star. A change of the text sends `<<Modified>>`, and the handler makes the proc again from `.code get`. When the rule gives an error, its line turns red, the message shows on the screen, and the last rule that ran with no error keeps the paddle going. Catch 6 stars on each of the 4 levels in 90 seconds. Level 1 is practice. From level 2 a missed star costs one of 3 lives. On level 2 the stars fall faster and drift to the sides. On levels 3 and 4 a bomb falls from the place of each new star, faster than the star. A caught bomb costs a life too, so the rule needs an `if` that moves the paddle away from `bx`. Level 4 drops two stars at a time.

<!-- widget: toy-pixelpad; shot: update -->
```tcl
# Pixel Pad: catch the stars and dodge the bombs. The text widget holds
# the rule of the paddle, and the game runs it in each frame. Edit it as
# the game runs.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560 #8b86b8}
set W 360; set H 124
canvas .c -width $W -height $H -bg [lindex $ink 0] -highlightthickness 0
text .code -height 6 -font {TkFixedFont 9} -undo 1 -wrap none \
    -background [lindex $ink 4] -foreground [lindex $ink 1] \
    -insertbackground [lindex $ink 3] -borderwidth 0 \
    -highlightthickness 0 -padx 6 -pady 4
.code tag configure err -background [lindex $ink 2]
pack .c -fill x
pack .code -fill both -expand 1
.code insert end {# Set x: the paddle goes there. The game gives
# sx sy (the lowest star), bx by (the lowest
# bomb), px (the paddle), and t (the frame).
set x [expr {180 + 150 * sin($t / 40.0)}]}
.code edit modified 0
focus .code
# Each level: the fall speed, the side speed, bombs, and stars at once.
set levels {
    {vy 1.0 vx 0   bomb 0 at 1}
    {vy 1.6 vx 1.2 bomb 0 at 1}
    {vy 1.4 vx 0   bomb 1 at 1}
    {vy 1.6 vx 1.0 bomb 1 at 2}
}
set NEED 6
array set toy {spill 0 out {} back {} sfx {}}
# A change of the text makes the proc rule again. When the rule fails,
# its line turns red and the last rule that ran with no error runs.
proc load {} {
    .code tag remove err 1.0 end
    proc rule {t sx sy bx by px} "[.code get 1.0 end-1c]\nreturn \$x"
    .code edit modified 0
}
bind .code <<Modified>> { if {[.code edit modified]} load }
load
proc good {t sx sy bx by px} { return $px }
# A pixel sprite: a list of rows, with one character for each 4 pixels.
proc sprite {tag x y color rows} {
    set x [expr {int($x) / 4 * 4}]; set y [expr {int($y) / 4 * 4}]
    foreach row $rows {
        foreach c [split $row ""] {
            if {$c eq "#"} {
                .c create rectangle $x $y [expr {$x + 4}] [expr {$y + 4}] \
                    -fill $color -width 0 -tags $tag
            }
            incr x 4
        }
        incr x [expr {-4 * [string length $row]}]
        incr y 4
    }
}
proc start {} {
    global g stars bombs
    if {$g(run)} return
    array set g {run 1 lvl 0 got 0 lives 3 frames 5400 px 180 t 0 err {}}
    set stars {}; set bombs {}
}
array set g {run 0 lvl 0 got 0 lives 3 frames 5400 px 180 t 0 err {}}
set stars {}; set bombs {}
set g(msg) "CLICK OR PRESS A TO START"
bind .c <ButtonPress-1> start
proc toy_press {key} { if {$key in {a b}} start }
# A new star, and on a bomb level a bomb above it that falls faster.
proc spawn {} {
    global stars bombs levels g W
    set L [lindex $levels $g(lvl)]
    set x [expr {20 + int(rand() * ($W - 48))}]
    # A second star falls near the first, so that one paddle can get both.
    if {[llength $stars]} {
        set x [expr {[lindex $stars 0 0] + int(rand() * 200) - 100}]
        set x [expr {max(20, min($W - 28, $x))}]
    }
    set vx [expr {[dict get $L vx] * (rand() < 0.5 ? -1 : 1)}]
    lappend stars [list $x 0 $vx [dict get $L vy]]
    if {[dict get $L bomb] && [llength $bombs] == 0} {
        lappend bombs [list $x -8 0 [expr {[dict get $L vy] * 1.7}]]
    }
}
# Moves the falling things. A thing that reaches the paddle row is
# caught or missed, and the proc gives the list of the others.
proc fall {list kind} {
    global g W H toy
    set keep {}
    foreach s $list {
        lassign $s x y vx vy
        set x [expr {$x + $vx}]; set y [expr {$y + $vy}]
        if {$x < 4 || $x > $W - 12} { set vx [expr {-$vx}] }
        if {$y < $H - 16} { lappend keep [list $x $y $vx $vy]; continue }
        set hit [expr {abs($x + 4 - $g(px)) <= 22}]
        switch $kind,$hit {
            star,1 { incr g(got); lappend toy(sfx) point }
            star,0 {
                # Level 1 is practice: a miss there costs no life.
                if {$g(lvl) > 0} { incr g(lives) -1 }
                lappend toy(sfx) wall
            }
            bomb,1 { incr g(lives) -1; lappend toy(sfx) smash }
        }
    }
    return $keep
}
# The lowest thing of a list, as {x y}, or a point far away.
proc lowest {list} {
    set best {-100 -100}
    foreach s $list { if {[lindex $s 1] > [lindex $best 1]} { set best $s } }
    return [lrange $best 0 1]
}
proc step {} {
    global g stars bombs levels NEED W
    if {!$g(run)} return
    incr g(t)
    incr g(frames) -1
    set L [lindex $levels $g(lvl)]
    if {[llength $stars] < [dict get $L at] &&
        ([llength $stars] == 0 || [lindex [lowest $stars] 1] > 50)} spawn
    set stars [fall $stars star]
    set bombs [fall $bombs bomb]
    lassign [lowest $stars] sx sy
    if {$sy < 0} { set sx $g(px) }
    lassign [lowest $bombs] bx by
    set args [list $g(t) $sx $sy $bx $by $g(px)]
    if {[catch {rule {*}$args} x]} {
        set g(err) $x
        if {[regexp {"rule" line (\d+)} $::errorInfo -> n]} {
            .code tag add err $n.0 "$n.0 lineend"
        }
        set x [good {*}$args]
    } else {
        set g(err) {}
        if {[info body rule] ne [info body good]} {
            proc good {t sx sy bx by px} [info body rule]
        }
    }
    if {![string is double -strict $x]} { set x $g(px) }
    set x [expr {max(18, min($W - 18, $x))}]
    set d [expr {max(-5, min(5, $x - $g(px)))}]
    set g(px) [expr {$g(px) + $d}]
    if {$g(got) >= $NEED * ($g(lvl) + 1)} {
        if {$g(lvl) == [llength $levels] - 1} {
            set g(run) 0
            set g(msg) "YOU WIN WITH [expr {$g(frames) / 60}] S LEFT"
            return
        }
        incr g(lvl)
    }
    if {$g(lives) <= 0 || $g(frames) <= 0} {
        set g(run) 0
        set g(msg) "GAME OVER - CLICK TO PLAY AGAIN"
    }
}
proc paint {} {
    global g stars bombs ink W H
    .c delete all
    foreach s $stars {
        sprite star [lindex $s 0] [lindex $s 1] [lindex $ink 3] {.#. ###}
    }
    foreach b $bombs {
        sprite bomb [lindex $b 0] [lindex $b 1] [lindex $ink 2] {.#. ### ###}
    }
    sprite pad [expr {$g(px) - 20}] [expr {$H - 12}] [lindex $ink 1] \
        {##########}
    for {set i 0} {$i < $g(lives)} {incr i} {
        sprite life [expr {$W - 20 - $i * 16}] 6 [lindex $ink 2] {#.# ### .#.}
    }
    set secs [expr {$g(frames) / 60}]
    set top "LEVEL [expr {$g(lvl) + 1}]  STARS $g(got)  $secs S"
    .c create text 8 8 -anchor nw -text $top -fill [lindex $ink 5] \
        -font {TkFixedFont 9 bold}
    if {!$g(run)} {
        .c create text [expr {$W / 2}] 62 -text $g(msg) \
            -fill [lindex $ink 3] -font {TkFixedFont 12 bold}
    }
    if {$g(err) ne ""} {
        .c create text 8 [expr {$H - 26}] -anchor nw -width [expr {$W - 16}] \
            -text $g(err) -fill [lindex $ink 2] -font {TkFixedFont 8}
    }
}
proc tick {} {
    step
    paint
    after 16 tick
}
tick
```

