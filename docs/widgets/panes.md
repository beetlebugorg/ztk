# Panes and tabs

**Live:** the Panes and Tabs cards of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## panedwindow and ttk::panedwindow

![A window with a list of mail folders on the left and two panes on the right, one above the other, with a thin line between each pair of panes](../site/shots/widget-panedwindow-light.png)

<!-- widget: panedwindow; shot: update -->
```tcl
panedwindow .p
listbox .p.list -width 10
.p.list insert end Inbox Drafts Sent Archive Trash
.p.list selection set 0
ttk::panedwindow .p.right -orient vertical
label .p.right.mail -text "Drag a sash"
label .p.right.info -text "This pane gets twice the space"
.p.right add .p.right.mail -weight 1
.p.right add .p.right.info -weight 2
.p add .p.list -stretch never
.p add .p.right -stretch always
pack .p -fill both -expand 1 -padx 8 -pady 8
```

- `panedwindow` puts its panes in a row (`-orient horizontal`) or a column, with a sash between two panes. It has the options, the pane options, and the subcommands of Tk 8.6: `add`, `forget`, `identify`, `panecget`, `paneconfigure`, `panes`, `proxy`, and `sash` with `coord`, `dragto`, `mark`, and `place`.
- A pane has the size of its widget, or its `-width` or `-height`, plus `-padx` or `-pady`. `-sticky` places the widget in its pane. `-stretch` picks the panes that get the extra space, or lose space, when the panedwindow changes size. A sash move stops at the `-minsize` of the panes.
- `ttk::panedwindow` has `add`, `forget`, `identify`, `insert`, `pane`, `panes`, and `sashpos`. A change of the size goes to the panes in proportion to their `-weight`. `sashpos` puts a sash between its neighbors and pushes them when it must.
- A press on a sash and a drag move it. The panes follow the pointer in each frame, and the render thread moves the sash with the pointer while a script is busy. With `-opaqueresize 0`, a drag moves a line, and the release moves the sash. `-showhandle` draws a handle on each sash.
- The pointer shape is a resize arrow over a sash, or the shape of `-sashcursor`.
- The modern theme draws a sash as a thin line in the part `::sash`. The sash under the pointer or in a drag fades to the part `::sash-active` in 120 ms.

### Play: Twin Lanes

Twin Lanes is a race on a split screen: your red car on the left and a robot car on the right. Each pane of the `panedwindow` is a canvas, and the width of a canvas is the width of its road. Drag the sash: a wide road is easy to drive and gets more rocks, and a narrow road is hard. The robot steers away from rocks, and a rock slows a car down. Press Left or Right to start, then steer with them, or with B and A on the handheld. The first car to 300 m wins. A gold ramp gives 5 m. With "Play on the page" on, a ramp throws your car out over the page, and each heading or code block that it hits gives 30 m when it comes back.

<!-- widget: toy-twinlanes; shot: update -->
```tcl
# Twin Lanes: a race on a split screen. The sash of the panedwindow sets the width of each road.
set ink {#1d1a33 #f2e6c4 #ef5b5b #ffcf5c #3a3560}
panedwindow .pw -orient horizontal -sashwidth 6 -showhandle 0
foreach {side color} {you 2 bot 1} {
    canvas .pw.$side -width 180 -height 230 -bg [lindex $ink 0] -highlightthickness 0
    .pw add .pw.$side -minsize 80
    .pw.$side create text 8 10 -anchor w -tags dist -fill [lindex $ink 1] -font {TkFixedFont 10 bold}
    foreach {x y} {2 0 4 0 0 2 2 2 4 2 6 2 2 4 4 4 0 6 2 6 4 6 6 6 2 8 4 8} {
        .pw.$side create rectangle [expr {$x*2}] [expr {$y*2}] [expr {$x*2+4}] [expr {$y*2+4}] -tags car -fill [lindex $ink $color] -width 0
    }
    array set car [list $side,x 60 $side,dist 0 $side,slow 0 $side,rocks {} $side,air 0]
}
pack .pw -fill both -expand 1
array set toy {spill 0 out {} back {} sfx {}}
array set hold {left 0 right 0}
set run 0
proc toy_press {key} {
    global run hold
    if {!$run} { set run 1; .pw.you delete msg; array unset ::car *,win; foreach s {you bot} { set ::car($s,dist) 0 } }
    switch $key { b { set hold(left) 6 } a { set hold(right) 6 } }
}
foreach {k v} {Left left Right right} { bind . <KeyPress-$k> "set hold($v) 999; toy_press x"; bind . <KeyRelease-$k> "set hold($v) 0" }
bind . <ButtonPress-1> {toy_press x}
# One step of one road: rocks and ramps come down, and the car steers.
proc road {s} {
    global car toy ink hold run
    set c .pw.$s
    set w [winfo width $c]
    set h [winfo height $c]
    set y [expr {$h - 30}]
    set speed [expr {$car($s,slow) > 0 ? 1 : 3}]
    if {$car($s,slow) > 0} { incr car($s,slow) -1 }
    if {$s eq "you"} {
        set dx [expr {($hold(right) > 0) * 3 - ($hold(left) > 0) * 3}]
        foreach k {left right} { if {$hold($k) > 0 && $hold($k) < 999} { incr hold($k) -1 } }
    } else {
        # The bot steers away from the nearest rock in front of it.
        set dx 0
        foreach r $car($s,rocks) {
            lassign $r id kind
            lassign [$c coords $id] rx ry
            if {$kind eq "rock" && $ry > $y - 70 && $ry < $y && abs($rx + 8 - $car($s,x) - 8) < 20} { set dx [expr {$rx + 8 > $car($s,x) + 8 ? -3 : 3}] }
        }
    }
    set car($s,x) [expr {max(0, min($w - 16, $car($s,x) + $dx))}]
    if {rand() < 0.04 * $w / 180.0} {
        set kind [expr {rand() < 0.15 ? "ramp" : "rock"}]
        set rx [expr {int(rand() * ($w - 16))}]
        set id [$c create rectangle $rx -16 [expr {$rx + 16}] [expr {$kind eq "ramp" ? -10 : 0}] -fill [lindex $ink [expr {$kind eq "ramp" ? 3 : 4}]] -width 0]
        lappend car($s,rocks) [list $id $kind]
    }
    set keep {}
    foreach r $car($s,rocks) {
        lassign $r id kind
        $c move $id 0 $speed
        lassign [$c coords $id] rx ry
        if {$ry > $h} { $c delete $id; continue }
        if {$car($s,air) == 0 && $ry + 16 > $y && $ry < $y + 16 && $rx < $car($s,x) + 16 && $rx + 16 > $car($s,x)} {
            $c delete $id
            if {$kind eq "rock"} { set car($s,slow) 40; lappend toy(sfx) wall; continue }
            # A ramp: with play on the page, your car jumps out of the road.
            lappend toy(sfx) smash
            if {$s eq "you" && $toy(spill)} {
                set toy(out) [list [expr {[winfo rootx $c] - [winfo rootx .] + $car($s,x)}] [expr {[winfo rooty $c] - [winfo rooty .] + $y}] 3 -12 0.4]
                set car($s,air) 1
            } else { incr car($s,dist) 50 }
            continue
        }
        lappend keep $r
    }
    set car($s,rocks) $keep
    if {$run && !$car($s,air)} { incr car($s,dist) $speed }
    $c moveto car [expr {$car($s,air) ? -40 : $car($s,x)}] $y
    if {$car($s,dist) >= 3000} { set run 0; set car($s,win) 1; lappend toy(sfx) point }
}
proc tick {} {
    global toy car run
    if {$run} { road you; road bot }
    foreach s {you bot} { .pw.$s itemconfigure dist -text "[string toupper $s] [expr {[info exists car($s,win)] ? "WINS" : "[expr {$car($s,dist) / 10}] M"}]" }
    # The page gives the car back: each wall that it hit is 30 m.
    if {$toy(back) ne ""} { incr car(you,dist) [expr {300 * [lindex $toy(back) 3]}]; set car(you,air) 0; set toy(back) {} }
    after 16 tick
}
foreach s {you bot} { .pw.$s moveto car 60 200 }
.pw.you create text 90 100 -tags msg -text "PRESS A KEY" -fill [lindex $ink 3] -font {TkFixedFont 11 bold}
tick
```

## ttk::notebook

![A notebook with the tabs General, Network, and Advanced, the General tab selected with a blue line under it, and a page with two check buttons](../site/shots/widget-notebook-light.png)

<!-- widget: notebook; shot: update -->
```tcl
ttk::notebook .n
foreach {page title} {general General network Network advanced Advanced} {
    ttk::frame .n.$page -padding 12
    .n add .n.$page -text $title -underline 0
}
set login 1
set menubar 0
ttk::checkbutton .n.general.a -text "Open at login" -variable login
ttk::checkbutton .n.general.b -text "Show in the menu bar" -variable menubar
pack .n.general.a .n.general.b -anchor w -pady 2
ttk::label .n.network.l -text "Proxy: none"
pack .n.network.l -anchor w
.n tab .n.advanced -state disabled
ttk::notebook::enableTraversal .n
pack .n -fill both -expand 1 -padx 8 -pady 8
```

- `ttk::notebook` has the subcommands of Tk 8.6: `add`, `forget`, `hide`, `identify`, `index`, `insert`, `select`, `tab`, and `tabs`, with `instate` and `state`. A tab is `normal`, `disabled`, or `hidden`, and it has `-text`, `-underline`, `-padding`, and `-sticky`.
- A click on a tab selects it. `Left` and `Right` move to the next tab that is not disabled, and `Control-Tab` and `Control-Shift-Tab` cycle the tabs. `ttk::notebook::enableTraversal` adds these keys to the whole window, with `Control-Page Up`, `Control-Page Down`, and `Alt` with the letter of `-underline`.
- Each change of the selected tab sends `<<NotebookTabChanged>>` after the script that made the change.
- The line under the selected tab slides to the new tab in 200 ms, and the new page fades in over 150 ms. A change during the slide starts from the shown place.
- The parts `::tab`, `::tab-selected`, `::tab-hover`, `::tab-disabled`, `::indicator`, and `::client` of `TNotebook` accept CSS rules.
