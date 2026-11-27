# Runs gitk of git 2.56.0 (gitk-git/gitk of the release) in a new git
# repository with three commits, and uses it as a person does: the list
# shows the commits, a click on the oldest commit shows its diff, and a
# key moves the selection. gitk has the GPL, so this script only runs it
# and reads its widgets at run time.
# Use: ztk --headless --windowingsystem x11 --allow package,clock,event,env,exec tests/apps/gitk.tcl SRC REPO ?SHOTS?
# SRC is the folder of the git release (git-2.56.0). REPO is an empty
# folder for the test repository.
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
lassign $argv src repo app::shots
set argv {}

cd $repo
exec git init -q -b main
exec git config user.email test@example.com
exec git config user.name Test
foreach i {1 2 3} {
    set f [open a.txt a]
    chan puts $f "line $i"
    close $f
    exec git add a.txt
    exec git commit -q -m "Commit $i"
}

app::try "gitk starts" {
    uplevel #0 [list source [file join $src gitk-git gitk]]
}
app::settle 2000

# The widgets of gitk, found by their class at run time.
proc widgetsOf {class} {
    set out {}
    foreach row [ztk::tree .] {
        lassign $row path c x y w h mapped
        if {$c eq $class && $mapped} {lappend out $path}
    }
    return $out
}
set canvases [widgetsOf Canvas]
set list [lindex $canvases 0]
set texts {}
foreach t [widgetsOf Text] {
    if {[string match *Author:* [$t get 1.0 end]]} {lappend texts $t}
}
app::check [expr {[llength $texts] == 1}] "a text shows the commit: $texts"
set diff [lindex $texts 0]
set items {}
foreach id [$list find withtag all] {
    if {[$list type $id] eq "text" && [string match "Commit *" [$list itemcget $id -text]]} {
        lappend items $id
    }
}
app::check [expr {[llength $items] == 3}] "the commit list shows [llength $items] commits"
app::check [string match "*+line 3*" [$diff get 1.0 end]] "the newest commit is selected and shows its diff"
app::shot . gitk

# A click on the text of the oldest commit.
foreach id $items {
    if {[$list itemcget $id -text] eq "Commit 1"} {set oldest $id}
}
lassign [$list bbox $oldest] x1 y1 x2 y2
app::click $list [expr {($x1 + $x2) / 2 - round([$list canvasx 0])}] [expr {($y1 + $y2) / 2 - round([$list canvasy 0])}]
app::settle 500
set body [$diff get 1.0 end]
app::check [expr {[string match "*Commit 1*" $body] && [string match "*+line 1*" $body]}] "a click on Commit 1 shows its diff"

# The key Up selects the commit above, Commit 2.
focus $list
app::key . Up
app::settle 500
app::check [string match "*+line 2*" [$diff get 1.0 end]] "the key Up shows the diff of Commit 2"
app::shot . gitk-commit2
app::noErrors "gitk"
app::done
