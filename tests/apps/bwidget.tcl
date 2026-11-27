# Runs the demo of BWidget 1.10.1 (demo/demo.tcl of the release) and
# clicks each tab of its notebook, as a person does. The page of each
# tab must show with no error. On the page Basic it clicks a button and
# types into an entry.
# Use: ztk --headless --allow package,clock,event,env tests/apps/bwidget.tcl SRC ?SHOTS?
# SRC is the folder of the BWidget release (bwidget-1.10.1).
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
set src [lindex $argv 0]
set app::shots [lindex $argv 1]
set argv {}
lappend auto_path $src

app::try "the demo starts" {
    uplevel #0 [list source [file join $src demo demo.tcl]]
}
app::settle 200
set nb $::Demo::notebook
set pages [$nb pages]
app::check [expr {[llength $pages] >= 5}] "the notebook has [llength $pages] pages: $pages"
app::shot . bwidget

# Clicks a tab: the center of the text of the tab on the canvas of the notebook.
proc clickTab {nb page} {
    # The tabs scroll: the notebook shows the tab first, as its arrows do.
    $nb see $page
    app::settle
    lassign [$nb.c bbox $page:text] x1 y1 x2 y2
    if {$x1 eq ""} {
        app::check 0 "the tab $page has a box"
        return
    }
    # The box is in the coordinates of the canvas, which can scroll.
    set dx [$nb.c canvasx 0]
    set dy [$nb.c canvasy 0]
    app::click $nb.c [expr {round(($x1 + $x2) / 2 - $dx)}] [expr {round(($y1 + $y2) / 2 - $dy)}]
}

foreach page $pages {
    clickTab $nb $page
    app::settle 100
    app::check [expr {[$nb raise] eq $page}] "a click on the tab $page shows its page"
    app::noErrors "the page $page"
}
app::shot . bwidget-last

# The page Basic: a click on its first button, and text in an entry.
clickTab $nb demoBasic
app::settle 100
app::check [expr {[$nb raise] eq "demoBasic"}] "a click on the tab demoBasic shows its page again"
set page [$nb getframe demoBasic]
set buttons {}
set entries {}
foreach row [ztk::tree .] {
    lassign $row path class x y w h mapped
    if {!$mapped || ![string match $page* $path]} continue
    if {$class in {Button TButton}} {lappend buttons $path}
    if {$class in {Entry TEntry}} {lappend entries $path}
}
app::check [expr {[llength $buttons] > 0}] "the page Basic has [llength $buttons] buttons"
app::check [expr {[llength $entries] > 0}] "the page Basic has [llength $entries] entries"
if {[llength $entries]} {
    set e [lindex $entries 0]
    app::click $e
    $e delete 0 end
    app::type . "typed"
    app::check [string match *typed* [$e get]] "typing into $e gives [$e get]"
}
app::answerDialogs
if {[llength $buttons]} {
    app::click [lindex $buttons 0]
    app::settle 800
}
app::answerDialogs 0
app::noErrors "the page Basic"
app::done
