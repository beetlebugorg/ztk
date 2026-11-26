# Toys

Each toy is a small arcade game in ztk, and the widget of its page drives it. Pick a game in the handheld below: Up and Down or the arrow keys move the cursor, and A, Return, or a click starts the game. Its Tcl code shows under the handheld, and an edit runs it again. Menu or Escape goes back to the list. The address of the page keeps the game, so a link opens that game.

A click on the handheld gives it the keys: the arrow keys or W, A, S, and D for the pad and the sides, Z or J for A, X or K for B, P to pause, and Escape to leave. A toy runs in the page as WebAssembly. It starts only on a key or a click, its sound is off until you turn it on, and it stops when it is off the screen.

<!-- widget: toy-console; shot: update -->
```tcl
# The game list of the handheld. A pick sets toy(pick), and the page
# then runs the code of that game in the same handheld.
array set toy {out {} sfx {} spill 0 pick {}}
set games {
    mothlamp   "MOTH LAMP"   checkbutton
    backspin   "BACKSPIN"    scale
    tinmoon    "TIN MOON"    ttk::scale
    skatepond  "SKATE POND"  listbox
    cellardoor "CELLAR DOOR" entry
    puffshot   "PUFFSHOT"    menu
    lamplighter "LAMPLIGHTER" ttk::notebook
    twinlanes  "TWIN LANES"  panedwindow
    pixelpad   "PIXEL PAD"   text
}
. configure -background #1d1a33
canvas .sky -width 360 -height 32 -background #1d1a33 -highlightthickness 0
# A moth of pixel squares, and the name of the handheld.
foreach {x y} {0 0 4 0 2 2 0 4 2 4 4 4 2 6} {
    .sky create rectangle [expr {14 + $x * 3}] [expr {3 + $y * 3}] \
        [expr {20 + $x * 3}] [expr {9 + $y * 3}] -fill #ffcf5c -outline {}
}
.sky create text 44 16 -anchor w -text "ZTK PLAY" -fill #f2e6c4 \
    -font {TkFixedFont 15 bold}
.sky create text 344 16 -anchor e -text "SELECT A GAME" -fill #ef5b5b \
    -font {TkFixedFont 10 bold}
listbox .games -height 8 -font {TkFixedFont 10 bold} -activestyle none \
    -background #1d1a33 -foreground #f2e6c4 -selectbackground #ffcf5c \
    -selectforeground #1d1a33 -borderwidth 0 -highlightthickness 0
foreach {id name widget} $games {
    .games insert end $name
}
.games selection set 0
.games activate 0
label .hint -font {TkFixedFont 9 bold} -background #1d1a33 -foreground #8b86b8
pack .sky -fill x
pack .hint -side bottom -fill x
pack .games -fill both -expand 1 -padx 12
focus .games
# The hint names the widget that drives the selected game.
proc hint {} {
    set i [lindex [.games curselection] 0]
    set widget [lindex $::games [expr {$i * 3 + 2}]]
    .hint configure -text "[string toupper $widget]   A: PLAY"
}
hint
bind .games <<ListboxSelect>> hint
proc pick {} {
    set i [lindex [.games curselection] 0]
    if {$i ne ""} { set ::toy(pick) [lindex $::games [expr {$i * 3}]] }
}
proc move {d} {
    set i [lindex [.games curselection] 0]
    set i [expr {max(0, min([.games size] - 1, $i + $d))}]
    .games selection clear 0 end
    .games selection set $i
    .games activate $i
    .games see $i
    hint
    lappend ::toy(sfx) hit
}
proc toy_press {key} {
    switch $key { up { move -1 } down { move 1 } default pick }
}
bind .games <Return> pick
bind .games <space> pick
bind .games <ButtonRelease-1> pick
```
