# Toys of the widget pages (issue 175)

This file is the state of the toys and the rules for the next ones. It is not on the site.

## Rules (user, 2026-11-26)

1. A real game: a clear goal, a challenge that ramps, a way to win and to lose, a score or a timer, and rounds of 30 seconds to 2 minutes.
2. The widget of the page is the core control or the core display of the game, used the way that the widget is meant to be used. The game cannot be played without it.
3. Play on the page (toys.js) stays only where it fits the game.
4. Original names, sprites, and rules. The handheld frame, sound off by default, no start without a key or a click, pause off the screen, reduced motion respected.

## State

| Toy | Page | Widget | Meets the rules |
|---|---|---|---|
| Backspin | range | `scale` is the paddle, match to 7 | Yes (#194) |
| Moth Lamp | toggles, landing | `checkbutton` flippers and lamps | Yes (#196) |
| Tin Moon | ttk | `ttk::scale` throttle, `ttk::progressbar` fuel | Yes (#194) |
| Cellar Door | entry | `entry` prompt with history and Tab completion | Yes (#189, #197) |
| Puffshot | menus | menu bar and `tk_popup` run a shooter | Yes. Next: a Sound entry and a Difficulty cascade. |
| Lamplighter | panes | `ttk::notebook` tabs are scenes | Mostly. Next: a timer and a way to lose. |
| Twin Lanes | panes | `panedwindow` sash sets the road widths | Yes |
| Skate Pond | listbox | `listbox` with `-selectmode multiple` is the bag of an ice puzzle: rock, plank, and rope with a plank as a bridge; 5 ponds in 90 s | Yes (#203) |

## The Toys page (user, 2026-11-26)

The Toys page is one handheld and the code (#204): a game list in a listbox, a pick runs the game and puts its code in the editor, Menu or Escape goes back, and `?game=SLUG` keeps the game. A new toy needs a heading `### Play: NAME` before its marker on its widget page, and a row in the list of `docs/toys.md` (its name without `toy-`, its title, and its widget). The list has 8 rows that fit in 240 pixels: a ninth game needs a smaller font or a scroll.

Since then (2026-11-26): the keys of each handheld on a click, P to pause, and one molded shell (#207); the Inspect panel in view (#208); a page-wide fallback from a blank WebGPU to WebGL 2 (#206, #209). The code column of the Toys page wraps long lines at a width of about 200 pixels: give the Toys page a wider main column or a smaller code font.

## Next, in order

1. Pixel Pad on the text page: a game whose rules are Tcl in a `text` widget. The draft below runs: `<<Modified>>` makes the proc `frame` again, and an error tags its line `err`. It needs a goal: for example, keep a falling ball out of a hole for 60 seconds by editing the rules.
2. treeview (tree page): a pretend disk; open folders, find the files, follow the clues.
3. buttons (basic page): a rhythm or reaction game with the buttons as pads, with the active state as feedback.
4. spinbox or combobox (entry page): dial in a code to open a safe.
5. canvas page: the playfield itself.

6. Puffshot: a Sound entry and a Difficulty cascade. Lamplighter: a timer and a way to lose. Twin Lanes: check the rules again.

Each toy is one PR: write the code, run it in `ztk --headless`, check that each level can be won (a breadth-first search, as for Skate Pond), write the shots for its snippet (the awk of `tools/shots.sh` for one name), run `tests/docs-live.sh widgets/PAGE`, check it in a headless Chromium, add its row to the game list of docs/toys.md, merge, and check the deployed page. Use a git worktree for each branch, so that a test run keeps its files.

## Draft: Pixel Pad

```tcl
# Pixel Pad: the text widget holds Tcl, and the canvas runs it in each frame.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
canvas .c -width 360 -height 112 -bg [lindex $ink 0] -highlightthickness 0
text .code -height 7 -font {TkFixedFont 9} -undo 1 -wrap none
.code tag configure err -background [lindex $ink 2] -foreground white
pack .c -fill x
pack .code -fill both -expand 1
.code insert end {# Edit me. t counts the frames, and Up and Down change k.
set x [expr {180 + 140 * sin($t / 50.0)}]
box 0 96 360 16 #3a3560
for {set i 0} {$i < 4 + $k} {incr i} {
    dot [expr {$x + $i * 10 - 20}] [expr {50 + 24 * sin(($t + $i * 9) / 9.0)}] #ffcf5c
}
kick $x 40}
.code edit modified 0
# The helpers of the pad. Each one draws pixels that snap to a grid of 2.
proc dot {x y color} { set x [expr {int($x) / 2 * 2}]; set y [expr {int($y) / 2 * 2}]; .c create rectangle $x $y [expr {$x+6}] [expr {$y+6}] -tags pad -fill $color -width 0 }
proc box {x y w h color} { .c create rectangle $x $y [expr {$x+$w}] [expr {$y+$h}] -tags pad -fill $color -width 0 }
# kick sends a ball out over the page, once for each press of A.
proc kick {x y} { if {$::armed && $::toy(spill)} { set ::toy(out) [list $x $y 4 -10 0.4]; lappend ::toy(sfx) smash }; set ::armed 0 }
array set toy {spill 0 out {} back {} sfx {}}
set k 0; set t 0; set armed 0
# A change of the text sends <<Modified>>. The handler makes the proc again.
proc load {} {
    .code tag remove err 1.0 end
    proc frame {t k} [.code get 1.0 end]
    .code edit modified 0
}
bind .code <<Modified>> { if {[.code edit modified]} load }
load
proc toy_press {key} {
    switch $key { up { incr ::k } down { set ::k [expr {max(-3, $::k - 1)}] } a - b { set ::armed 1; lappend ::toy(sfx) hit } }
}
proc tick {} {
    global t k toy
    incr t
    .c delete pad
    # An error marks its line in red and shows its message on the canvas.
    if {[catch {frame $t $k} msg]} {
        if {[regexp {"frame" line (\d+)} $::errorInfo -> n]} { .code tag add err $n.0 "$n.0 lineend" }
        .c create text 8 8 -anchor nw -tags pad -text $msg -fill [lindex $::ink 2] -font {TkFixedFont 9} -width 340
    }
    if {$toy(back) ne ""} { incr k [lindex $toy(back) 3]; set toy(back) {} }
    after 16 tick
}
tick
```
