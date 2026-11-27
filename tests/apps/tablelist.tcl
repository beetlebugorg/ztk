# Runs a demo of Tablelist 7.12 (demos/NAME.tcl of the release) and uses
# its first tablelist as a person does: a click on a row selects it, a
# click on a column label sorts by that column, and in the demo dirViewer
# a double click on the folder row shows the content of the folder.
# Use: ztk --headless --windowingsystem x11 --allow package,clock,event,env tests/apps/tablelist.tcl SRC NAME ?SHOTS?
# SRC is the folder of the Tablelist release (tablelist7.12).
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
lassign $argv src demo app::shots
set argv {}
lappend auto_path $src

# The demo embeddedWindows lists the Tcl files of $tk_library. ztk has no
# library folder, so the folder of the demos takes its place.
if {$::tk_library eq ""} {set ::tk_library [file join $src demos]}

# The demos config and browse are for an interactive wish: a person
# sources them and calls a command with a widget.
set interactive {config displayConfig browse displayChildren browseTree displayChildren}
if {[dict exists $interactive $demo]} {set ::tcl_interactive 1}
app::answerDialogs
app::try "the demo $demo starts" {
    uplevel #0 [list source [file join $src demos $demo.tcl]]
    if {[dict exists $interactive $demo]} {
        uplevel #0 [list demo::[dict get $interactive $demo] .]
    }
}
app::settle 300
app::answerDialogs 0
set tables {}
foreach top [concat . [app::toplevels]] {
    foreach row [ztk::tree $top] {
        lassign $row path class x y w h mapped
        if {$class eq "Tablelist" && $mapped} {lappend tables $path}
    }
}
app::check [expr {[llength $tables] > 0}] "the demo shows [llength $tables] tablelists"
set tbl [lindex $tables 0]
app::shot [winfo toplevel $tbl] tablelist-$demo
app::check [expr {[$tbl size] > 0}] "$tbl has [$tbl size] rows"

# A click in the middle of a row, away from the expand arrow of a tree.
proc clickRow {tbl row} {
    $tbl see $row
    update
    lassign [$tbl bbox $row] x y w h
    app::click $tbl [expr {$x + $w / 2}] [expr {$y + $h / 2}]
}

clickRow $tbl 0
app::check [expr {[$tbl curselection] eq "0"}] "a click on row 0 selects it: [$tbl curselection]"

# A demo with a -labelcommand sorts by a column on a click of its label.
if {[$tbl cget -labelcommand] ne ""} {
    set label [$tbl labelpath 0]
    app::click $label
    app::settle
    app::check [expr {[$tbl sortcolumn] == 0}] "a click on the label of column 0 sorts by it: [$tbl sortcolumn] [$tbl sortorder]"
    set before [$tbl sortorder]
    # A person waits a moment, so the second click is not a double click.
    app::settle 700
    app::click $label
    app::settle
    app::check [expr {[$tbl sortorder] ne $before}] "a second click changes the order from $before to [$tbl sortorder]"
}

if {$demo eq "dirViewer"} {
    $tbl see 0
    update
    lassign [$tbl bbox 0] x y w h
    lassign [app::box $tbl] tx ty
    set px [expr {$tx + $x + $w / 2}]
    set py [expr {$ty + $y + $h / 2}]
    set top [winfo toplevel $tbl]
    ztk::inject $top motion $px $py
    foreach i {1 2} {
        ztk::inject $top press 1 $px $py
        ztk::inject $top release 1 $px $py
    }
    app::settle 300
    app::check [expr {[$tbl size] > 1}] "a double click on the folder row shows [$tbl size] rows of the folder"
    app::shot [winfo toplevel $tbl] tablelist-$demo-open
}
app::noErrors "the demo $demo"
app::done
