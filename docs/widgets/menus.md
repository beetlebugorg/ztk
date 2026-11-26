# Menus

**Live:** the Menus card of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## menu, menubutton, and ttk::menubutton

![A window with a menu bar of File, Edit, and View, and the File menu open with New, Open, a separator, and Close, each with its key](../site/shots/widget-menu-light.png)

<!-- widget: menu; shot: event generate . <Key-F10> -->
```tcl
menu .bar
. configure -menu .bar
foreach {name text} {file File edit Edit view View} {
    menu .bar.$name -tearoff 0
    .bar add cascade -label $text -menu .bar.$name -underline 0
}
.bar.file add command -label New -accelerator Ctrl+N -command {set status New}
.bar.file add command -label Open... -accelerator Ctrl+O -command {set status Open}
.bar.file add separator
.bar.file add command -label Close -accelerator Ctrl+W -command {set status Close}
.bar.edit add command -label Undo -accelerator Ctrl+Z -command {set status Undo}
.bar.edit add command -label Redo -state disabled
.bar.view add checkbutton -label "Show grid" -variable grid
.bar.view add radiobutton -label Small -variable size -value small
.bar.view add radiobutton -label Large -variable size -value large
set grid 1
set size small
set status "Click File, press F10, or right-click"
ttk::menubutton .mb -text Size -menu .bar.view
label .status -textvariable status
pack .mb -pady {24 8}
pack .status
bind . <Button-3> {tk_popup .bar.edit %X %Y}
```

### Play: Puffshot

Puffshot is a shooter, and its menus run the game. The Game menu has New game, a Pause `checkbutton` entry with `-variable paused`, and Fire a comet. The Speed menu has three `radiobutton` entries on `-variable speed`, and the puffs fall at that speed. A right-click on the sky runs `tk_popup` with a second menu: a comet, three shots at once, and Pause. Press Space or click the canvas, then use Left and Right to move and Space to shoot, or B, A, and Up on the handheld. A comet clears the sky. With "Play on the page" on, the comet flies out over the page first and bounces off the headings and the code, and each one that it hits gives 100 points when it comes back.

<!-- widget: toy-puffshot; shot: update -->
```tcl
# Puffshot: the menu bar runs the game, and a right-click on the sky opens a menu.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
menu .bar
. configure -menu .bar
foreach {m t} {game Game speed Speed} {
    menu .bar.$m -tearoff 0
    .bar add cascade -label $t -menu .bar.$m -underline 0
}
.bar.game add command -label "New game" -accelerator N -command new
.bar.game add checkbutton -label Pause -accelerator P -variable paused
.bar.game add separator
.bar.game add command -label "Fire a comet" -accelerator C -command comet
foreach {t v} {Slow 0.5 Normal 1 Fast 1.8} { .bar.speed add radiobutton -label $t -variable speed -value $v }
menu .pop -tearoff 0
.pop add command -label "Fire a comet" -command comet
.pop add command -label "Three shots" -command {fire -2; fire 0; fire 2}
.pop add checkbutton -label Pause -variable paused
set paused 1; set speed 1
canvas .c -width 360 -height 200 -bg [lindex $ink 0] -highlightthickness 0
pack .c -fill both -expand 1
bind .c <Button-3> {tk_popup .pop %X %Y}
array set toy {spill 0 out {} back {} sfx {}}
proc sprite {tags rows color x0 y0} {
    foreach row $rows {
        set x $x0
        foreach ch [split $row ""] {
            if {$ch eq "#"} { .c create rectangle $x $y0 [expr {$x+2}] [expr {$y0+2}] -tags $tags -fill $color -width 0 }
            incr x 2
        }
        incr y0 2
    }
}
sprite ship {...#... ..###.. .#####. ##.#.## #.....#} [lindex $ink 2] 170 180
.c create text 8 10 -anchor w -tags score -fill [lindex $ink 1] -font {TkFixedFont 11 bold}
.c create text 180 100 -tags msg -text "PRESS SPACE" -fill [lindex $ink 3] -font {TkFixedFont 12 bold}
set shots {}
proc new {} {
    global puffs score ship
    .c delete puff
    set puffs {}
    for {set i 0} {$i < 5} {incr i} {
        set x [expr {20 + $i*68}]; set y [expr {-20 - $i*30}]
        sprite "puff p$i" {.#.#. ##### .###. ##### .#.#.} [lindex $::ink 1] $x $y
        lappend puffs [list $x $y]
    }
    set score 0
    .c moveto ship 170 180
    set ::paused 0
    .c itemconfigure msg -text ""
}
proc fire {dx} {
    global shots paused
    if {$paused} return
    lassign [.c bbox ship] x
    lappend shots [list [.c create rectangle [expr {$x+6}] 172 [expr {$x+8}] 178 -tags shot -fill [lindex $::ink 3] -width 0] $dx]
    lappend ::toy(sfx) hit
}
# A comet clears the sky. With play on the page, it flies over the page first.
proc comet {} {
    global toy
    if {$::paused} return
    if {$toy(spill)} {
        lassign [.c bbox ship] x
        set toy(out) [list [expr {$x+6}] [expr {[winfo y .c] + 170}] [expr {rand()*6-3}] -13 0.3]
        lappend toy(sfx) smash
    } else { clear 0 }
}
proc clear {hits} {
    global puffs score
    for {set i 0} {$i < [llength $puffs]} {incr i} { respawn $i }
    incr score [expr {50 * [llength $puffs] + 100 * $hits}]
    lappend ::toy(sfx) point
}
proc respawn {i} {
    global puffs
    lassign [lindex $puffs $i] x y
    set nx [expr {10 + int(rand()*330)}]
    .c move p$i [expr {$nx - $x}] [expr {-20 - $y}]
    lset puffs $i [list $nx -20]
}
proc toy_press {key} {
    if {$::paused && $key in {up a b}} { if {[.c itemcget msg -text] ne ""} new; set ::paused 0; return }
    switch $key { up { fire 0 } down { comet } a { .c move ship 8 0 } b { .c move ship -8 0 } }
    lassign [.c bbox ship] x
    if {$x < 0 || $x > 346} { .c moveto ship [expr {max(0, min(346, $x))}] 180 }
}
foreach {k v} {<space> up <Left> b <Right> a <Key-c> down} { bind .c $k [list toy_press $v] }
bind .c <Key-n> new
bind .c <Key-p> {set paused [expr {!$paused}]}
focus .c
set tick 0
proc tick {} {
    global puffs shots score paused speed toy tick
    incr tick
    if {!$paused} {
        # Each puff falls and sways. A puff that reaches the ground goes back to the top.
        for {set i 0} {$i < [llength $puffs]} {incr i} {
            lassign [lindex $puffs $i] x y
            set ny [expr {$y + 0.6 * $speed}]
            set nx [expr {$x + sin(($tick + $i*40) / 20.0) * 0.6}]
            .c move p$i [expr {int($nx) - int($x)}] [expr {int($ny) - int($y)}]
            lset puffs $i [list $nx $ny]
            if {$ny > 190} { respawn $i; set score [expr {max(0, $score - 10)}] }
        }
        set keep {}
        foreach s $shots {
            lassign $s id dx
            .c move $id $dx -6
            lassign [.c coords $id] sx sy
            if {$sy < -6} { .c delete $id; continue }
            set hit 0
            for {set i 0} {$i < [llength $puffs]} {incr i} {
                lassign [lindex $puffs $i] x y
                if {$sx >= $x - 2 && $sx <= $x + 10 && $sy >= $y && $sy <= $y + 10} { set hit 1; respawn $i; incr score 10; lappend toy(sfx) wall; break }
            }
            if {$hit} { .c delete $id } else { lappend keep $s }
        }
        set shots $keep
    }
    # The page gives the comet back as {x vx vy hits}: each wall gives 100 more.
    if {$toy(back) ne ""} { clear [lindex $toy(back) 3]; set toy(back) {} }
    .c itemconfigure score -text "SCORE $score"
    after 16 tick
}
set score 0
set puffs {}
tick
```

<!-- more: The details of menu, menubutton, and ttk::menubutton -->

- `menu` has the five entry types of Tk 8.6 (`command`, `cascade`, `checkbutton`, `radiobutton`, and `separator`), the tearoff entry, and the subcommands and the messages of `wish` 8.6.16. `invoke` sets the variable of a check or radio entry and then runs `-command`. A change of the active entry sends `<<MenuSelect>>`.
- `toplevel -menu` gives the window a menu bar. On Linux and the web, ztk draws the bar as a row at the top of the window, as Tk on X11 does. The content of the window goes below the row. macOS and Windows show their own menus.
- `tk_popup` and `post` show a menu at a point of the window. A cascade opens on the right of its entry. On Wayland, each posted menu and each cascade is a popup surface (`xdg_popup`) that can extend past the window: the compositor flips a cascade to the left and slides a menu when the screen has no room. On the web, each one is a canvas in a layer above the page, and the viewport is the screen.
- `menubutton` and `ttk::menubutton` post their `-menu` on the side of `-direction`. A drag from the button to an entry and a release there invokes the entry.
- The pointer: motion activates an entry and opens a cascade, a release invokes the entry, and a press outside the menus closes them.
- The keys: `Up` and `Down` move the active entry, `Right` opens a cascade, `Left` closes it, and `Return` or `space` invokes the entry. `Escape` closes the menu. The letter of `-underline` invokes its entry. On the menu bar, `F10` opens the first menu, `Alt` with a letter opens the menu with that `-underline` letter, and `Left` and `Right` move along the bar.
- A menu opens with a fade and a slide of 6 logical pixels in 150 ms, and fades out in 150 ms after it closes. The moves run on the render thread. The highlight of the active entry eases from one entry to the next in 120 ms.
- The parts `::item`, `::item-active`, `::separator`, `::accelerator`, and `::indicator` of the class `Menu` accept CSS rules, and so do `::bar`, `::bar-item`, and `::bar-item-active` for the menu bar row. `Menubutton::indicator` is the chevron of a menu button.

<!-- end more -->
