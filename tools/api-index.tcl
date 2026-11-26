# SPDX-License-Identifier: BSD-2-Clause
# Writes the API index of ztk as JSON to stdout: the commands of each
# namespace, and each widget command with its options and their
# defaults. The values come from a new widget of each class, so the
# index matches the build that runs it.
# Use: ztk --headless --exit-after-frames 1 tools/api-index.tcl > api.json
proc json {s} {
    return "\"[string map {\\ \\\\ \" \\\" \n \\n \t \\t \r \\r} $s]\""
}
proc jlist {items} {
    set out {}
    foreach i $items { lappend out [json $i] }
    return "\[[join $out ,]\]"
}
set widgets {
    frame label button checkbutton radiobutton entry spinbox scale scrollbar
    listbox canvas labelframe message panedwindow menubutton menu toplevel
    ttk::frame ttk::label ttk::button ttk::checkbutton ttk::radiobutton
    ttk::entry ttk::combobox ttk::spinbox ttk::scale ttk::scrollbar
    ttk::progressbar ttk::separator ttk::sizegrip ttk::labelframe
    ttk::notebook ttk::panedwindow ttk::menubutton ttk::treeview
    ztk::terminal text
}
set rows {}
set n 0
foreach cmd $widgets {
    if {[llength [info commands $cmd]] == 0} continue
    set w .api[incr n]
    if {[catch {$cmd $w} err]} continue
    set opts {}
    foreach o [$w configure] {
        if {[llength $o] == 5} {
            lappend opts "\{\"name\":[json [lindex $o 0]],\"default\":[json [lindex $o 3]]\}"
        } else {
            lappend opts "\{\"name\":[json [lindex $o 0]],\"alias\":[json [lindex $o 1]]\}"
        }
    }
    lappend rows "\{\"command\":[json $cmd],\"class\":[json [winfo class $w]],\"options\":\[[join $opts ,]\]\}"
    destroy $w
}
set ns {}
foreach space {:: ::ttk ::ztk} {
    set names {}
    foreach c [lsort [info commands ${space}::*]] {
        if {![string match ::api* $c] && $c ni {::json ::jlist}} { lappend names [string trimleft $c :] }
    }
    lappend ns "[json [string trimleft $space :]]:[jlist $names]"
}
puts "\{\"version\":1,\"commands\":\{[join $ns ,]\},\"widgets\":\[[join $rows ,]\]\}"
exit
