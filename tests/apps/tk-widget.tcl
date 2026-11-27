# Runs the widget demo of Tk 8.6.16 (library/demos/widget) and opens each
# of its demos with a click on its line in the text, as a person does.
# Each demo must open a toplevel with no error. The script closes each
# demo window before the next one.
# Use: ztk --headless --allow package,clock,event,env tests/apps/tk-widget.tcl SRC ?SHOTS?
# SRC is the folder of the Tk source release (tk8.6.16).
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
set src [lindex $argv 0]
set app::shots [lindex $argv 1]
set argv {}
set demos [file join $src library demos]

app::try "the widget demo starts" {
    uplevel #0 [list source [file join $demos widget]]
}
update
app::check [winfo exists .t] "the text of the demo list exists"
app::shot . tk-widget
set ::app::opened 0
set names {}
foreach tag [.t tag names] {
    if {[string match demo-* $tag]} {lappend names [string range $tag 5 end]}
}
app::check [expr {[llength $names] >= 60}] "the list has [llength $names] demos"
app::answerDialogs
foreach name $names {
    chan puts stdout "demo: $name"
    set before [app::toplevels]
    set first [lindex [.t tag ranges demo-$name] 0]
    app::clickText .t "$first + 2 chars"
    update
    set new [app::newToplevels $before]
    app::check [expr {[llength $new] > 0}] "the demo $name opens a window ($new)"
    app::noErrors "the demo $name"
    if {[llength $new] > 0} {incr ::app::opened}
    foreach w $new {destroy $w}
    update
}
chan puts stdout "demos that open: $::app::opened of [llength $names]"
app::done
