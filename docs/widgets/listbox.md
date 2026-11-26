# Listbox

**Live:** the Lists card of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery), and the layer list of the [vector tool](https://beetlebug.org/ztk/play/index.html?example=vector).

## listbox

![A listbox with four file names](../site/shots/widget-listbox-light.png)

<!-- widget: listbox; shot: update -->
```tcl
listbox .files -height 6 -selectmode extended -yscrollcommand {.sb set} -emptytext "No files"
scrollbar .sb -command {.files yview}
.files insert end report.pdf notes.txt photo.png budget.xlsx
bind .files <<ListboxSelect>> {puts [.files curselection]}
pack .files -side left -fill both -expand 1
pack .sb -side right -fill y

listbox .side -height 4 -activestyle none
.side insert end Inbox Drafts Sent Archive
ztk::class .side add sidebar
```

### Play: Skate Pond

Skate Pond is a puzzle on ice. Cross 5 ponds before the ice melts in 90 seconds. The arrow keys, or the pad with B for left and A for right, push the skater, and the skater slides until a wall, a rock, or water stops it. The listbox is the bag, with `-selectmode multiple`: click the items, or move to them with the arrow keys and press Space, and then press Return or double-click to use them on the square ahead. A rock stops the skater, a plank covers one square of water, and rope with a plank is a bridge over a row of water. After each use, the game deletes the rows of the bag and inserts them again with the counts that are left. A gem gives 50 points, and a flag gives 100 points and 10 more seconds.

<!-- widget: toy-skatepond; shot: update -->
```tcl
# Skate Pond: slide to the flag of 5 ponds before the ice melts. The
# skater slides until a wall, a rock, or water stops it. The listbox is
# the bag: select items, and press Return or double-click to use them on
# the square ahead.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560 #6fc3df}
# # wall, . ice, o water, * gem, S start, F flag. The levels get harder.
set levels {
    {########### #S....#...# #.........# #...*.....# #.....o...# #.......F.# ###########} {rock 1}
    {########### #S.......*# #.oooo....# #.........# #....oo.o.# #.*..o..F## ###########} {plank 2 rope 1}
    {########### #S..o.....# #...o..*..# #...o.....# #...o...#.# #...o..#F.# ###########} {plank 1 rock 1}
    {########### #S.o.*.o..# #..o...o..# #.ooo.ooo.# #..o.*.o..# #..o...o.F# ###########} {plank 2 rope 1 rock 1}
    {########### #S..#.....# #...ooo...# #.*.ooo.*.# #...ooo...# #...#...F.# ###########} {plank 1 rope 1 rock 1}
}
. configure -background [lindex $ink 0]
canvas .c -width 220 -height 160 -bg [lindex $ink 0] -highlightthickness 0
listbox .bag -selectmode multiple -height 6 -width 9 -exportselection 0 -font {TkDefaultFont 10} -activestyle none \
    -background [lindex $ink 4] -foreground [lindex $ink 1] \
    -selectbackground [lindex $ink 3] -selectforeground [lindex $ink 0]
label .info -font {TkFixedFont 10 bold} -anchor w -background [lindex $ink 0] -foreground [lindex $ink 3]
grid .c .bag -padx 6 -pady {6 2} -sticky n
grid .info - -sticky ew -padx 8
array set toy {spill 0 out {} back {} sfx {}}
array set g {level 0 score 0 ticks 1800 run 0 dx 0 dy 1 sx 0 sy 0 moving 0 over 0}
proc cell {x y} { lindex [split [lindex $::board $y] ""] $x }
proc put {x y ch} {
    set row [lindex $::board $y]
    lset ::board $y [string replace $row $x $x $ch]
}
proc paint {} {
    global ink g
    .c delete all
    for {set y 0} {$y < 7} {incr y} {
        for {set x 0} {$x < 11} {incr x} {
            set ch [cell $x $y]
            set c [dict get {# 4 . 0 o 5 * 0 F 0 S 0 - 1 R 0} $ch]
            set x0 [expr {$x * 20}]; set y0 [expr {$y * 20 + 10}]
            .c create rectangle $x0 $y0 [expr {$x0 + 20}] [expr {$y0 + 20}] -fill [lindex $ink $c] -width 0
            if {$ch eq "*"} { .c create rectangle [expr {$x0+7}] [expr {$y0+7}] [expr {$x0+13}] [expr {$y0+13}] -fill [lindex $ink 2] -width 0 }
            if {$ch eq "F"} { .c create rectangle [expr {$x0+6}] [expr {$y0+3}] [expr {$x0+8}] [expr {$y0+17}] -fill [lindex $ink 1] -width 0
                .c create rectangle [expr {$x0+8}] [expr {$y0+3}] [expr {$x0+16}] [expr {$y0+9}] -fill [lindex $ink 3] -width 0 }
            if {$ch eq "R"} { .c create rectangle [expr {$x0+3}] [expr {$y0+5}] [expr {$x0+17}] [expr {$y0+17}] -fill #8b86b8 -width 0 }
        }
    }
    # The skater: a gold body and a red scarf, in squares of 2 pixels.
    set x0 [expr {$g(sx) * 20 + 6}]; set y0 [expr {$g(sy) * 20 + 12}]
    .c create rectangle $x0 $y0 [expr {$x0+8}] [expr {$y0+16}] -fill [lindex $ink 3] -width 0
    .c create rectangle $x0 [expr {$y0+6}] [expr {$x0+8}] [expr {$y0+8}] -fill [lindex $ink 2] -width 0
    .c create text 4 5 -anchor w -fill [lindex $ink 1] -font {TkFixedFont 8 bold} \
        -text "POND [expr {$g(level)+1}]/5  SCORE $g(score)  TIME [expr {$g(ticks) / 20}]"
}
proc bag {} {
    .bag delete 0 end
    dict for {item n} $::items { if {$n > 0} { .bag insert end "$item x$n" } }
    .bag insert end "bridge"
}
proc start {level} {
    global g levels items board
    set g(level) $level
    set board [lindex $levels [expr {$level * 2}]]
    set items [lindex $levels [expr {$level * 2 + 1}]]
    for {set y 0} {$y < 7} {incr y} {
        set x [string first S [lindex $board $y]]
        if {$x >= 0} { set g(sx) $x; set g(sy) $y; put $x $y . }
    }
    set g(moving) 0
    bag; paint
}
# A push slides the skater until a wall or a rock stops it.
proc push {dx dy} {
    global g
    if {!$g(run)} { set g(run) 1; tick }
    if {$g(moving) || $g(over)} return
    set g(dx) $dx; set g(dy) $dy; set g(moving) 1
    slide
}
proc slide {} {
    global g toy
    set nx [expr {$g(sx) + $g(dx)}]; set ny [expr {$g(sy) + $g(dy)}]
    set ch [cell $nx $ny]
    if {$ch in {# R}} { set g(moving) 0; lappend toy(sfx) wall; return }
    if {$ch eq "o"} { set g(moving) 0; lappend toy(sfx) wall; return [note "Water ahead: a plank or a bridge."] }
    set g(sx) $nx; set g(sy) $ny
    switch -- $ch {
        * { incr g(score) 50; put $nx $ny .; lappend toy(sfx) hit }
        F { incr g(score) [expr {100 + $g(ticks) / 20}]; incr g(ticks) 200; lappend toy(sfx) point
            set g(moving) 0
            if {$g(level) == 4} { over "You crossed the 5 ponds!" } else { start [expr {$g(level) + 1}]; note "Pond [expr {$g(level) + 1}]." }
            return }
    }
    paint
    after 40 slide
}
# Use the selected items on the square ahead of the skater, in the
# direction of the last push.
proc use {} {
    global g items toy
    set picked {}
    foreach i [.bag curselection] { lappend picked [lindex [.bag get $i] 0] }
    .bag selection clear 0 end
    set x [expr {$g(sx) + $g(dx)}]; set y [expr {$g(sy) + $g(dy)}]
    set have [expr {[dict exists $items rope] && [dict get $items rope] > 0 && [dict exists $items plank] && [dict get $items plank] > 0}]
    if {("bridge" in $picked || ("rope" in $picked && "plank" in $picked)) && $have} {
        # A bridge covers each square of water in a row ahead.
        set n 0
        while {[cell $x $y] eq "o"} { put $x $y -; incr x $g(dx); incr y $g(dy); incr n }
        if {$n == 0} { return [note "A bridge needs water ahead."] }
        dict incr items rope -1; dict incr items plank -1
    } elseif {"plank" in $picked && [dict get $items plank] > 0} {
        if {[cell $x $y] ne "o"} { return [note "A plank needs water ahead."] }
        put $x $y -; dict incr items plank -1
    } elseif {"rock" in $picked && [dict get $items rock] > 0} {
        if {[cell $x $y] ne "."} { return [note "A rock needs open ice ahead."] }
        put $x $y R; dict incr items rock -1
    } else { return [note "Select an item in the bag first."] }
    lappend toy(sfx) hit
    bag; paint
}
proc note {text} { .info configure -text $text }
proc over {text} {
    global g
    set g(run) 0; set g(over) 1
    note "$text Score $g(score). Space: a new game."
    paint
}
proc tick {} {
    global g
    if {!$g(run)} return
    incr g(ticks) -1
    if {$g(ticks) <= 0} { return [over "The ice melted."] }
    if {$g(ticks) % 20 == 0 && !$g(moving)} paint
    after 50 tick
}
proc newgame {} {
    global g
    array set g {score 0 ticks 1800 run 0 over 0}
    start 0
    note "Arrow keys push the skater."
}
bind .c <Up> {push 0 -1}
bind .c <Down> {push 0 1}
bind .c <Left> {push -1 0}
bind .c <Right> {push 1 0}
bind .c <space> { if {$g(over)} newgame }
bind .c <ButtonPress-1> {focus .c}
bind .bag <Return> use
bind .bag <Double-1> use
proc toy_press {key} {
    if {$::g(over)} { newgame; return }
    switch $key { up { push 0 -1 } down { push 0 1 } b { push -1 0 } a { push 1 0 } }
}
focus .c
newgame
```

- The listbox has the options, the subcommands, and the four selection modes of Tk 8.6: `single`, `browse`, `multiple`, and `extended`. The pointer and the keys select rows as in `wish`, and a change by the user sends `<<ListboxSelect>>`.
- `-listvariable` links the rows to a list variable in both directions.
- When the selection moves from one row to another row, its background eases between the rows in 180 ms.
- A scroll eases, and a touchpad scrolls by pixels with momentum. A whole step of `yview scroll` or `yview moveto` puts a row at the top, as in Tk.
- The additions: `-emptytext` shows a text in an empty listbox, and the style class `sidebar` gives a list with no field and round accent rows.
- The parts `::item`, `::selection`, `::active`, and `::empty` accept CSS rules.
