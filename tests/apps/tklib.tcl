# Runs an example of tklib 0.9 (examples/NAME of the release), or the
# widgets check: a tooltip that shows on a hover, a ctext widget that
# colors a keyword as a person types it, and a datefield that takes a
# typed date. An example must draw on its canvases with no error.
# Use: ztk --headless --windowingsystem x11 --allow package,clock,event,env tests/apps/tklib.tcl SRC NAME|widgets ?SHOTS?
# SRC is the folder of the tklib release (tklib-0.9).
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
lassign $argv src name app::shots
set argv {}
lappend auto_path [file join $src modules]

if {$name ne "widgets"} {
    app::try "the example $name starts" {
        uplevel #0 [list source [file join $src examples $name]]
    }
    app::settle 200
    set items 0
    foreach top [concat . [app::toplevels]] {
        foreach row [ztk::tree $top] {
            lassign $row path class
            if {$class eq "Canvas"} {incr items [llength [$path find all]]}
        }
    }
    app::check [expr {$items > 0}] "the canvases of $name have $items items"
    app::shot . tklib-[file rootname [file tail $name]]
    app::noErrors "the example $name"
    app::done
}

app::try "the packages load" {
    package require tooltip
    package require ctext
    package require datefield
}
button .b -text "Hover me"
tooltip::tooltip .b "A tooltip of tklib"
ctext .t -width 40 -height 6
ctext::addHighlightClass .t keywords blue {proc set}
datefield::datefield .d -format "%Y-%m-%d"
pack .b .t .d -padx 8 -pady 4 -fill x
app::settle

# A hover on the button: tooltip shows its toplevel after its delay.
lassign [app::box .b] x y w h
ztk::inject . motion [expr {$x + $w / 2}] [expr {$y + $h / 2}]
app::settle 1200
set shown 0
foreach t [app::toplevels] {
    if {[winfo ismapped $t] && [string match *tooltip* $t]} {set shown 1}
}
app::check $shown "a hover on the button shows the tooltip"
ztk::inject . motion 1 1
app::settle 200

# Typing into the ctext widget colors the keyword.
app::click .t
app::type . "proc hello {} {set x 1}"
app::settle 300
app::check [string match "proc hello*" [.t get 1.0 end-1c]] "the ctext has the typed text"
app::check [expr {[llength [.t tag ranges keywords]] > 0}] "the keyword proc has the tag keywords: [.t tag ranges keywords]"

# The datefield takes a typed date.
app::click .d
.d icursor 0
app::type . "20261126"
app::settle
app::check [string match "2026-11-26" [.d get]] "the datefield shows the typed date: [.d get]"
app::shot . tklib-widgets
app::noErrors "the widgets"
app::done
