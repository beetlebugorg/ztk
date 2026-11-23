# SPDX-License-Identifier: BSD-2-Clause
# Counts the commands, options, and subcommands of a real Tk.
# Use: xvfb-run -a wish tools/tk-introspect.tcl
# It needs `tclsh8.6` on the path for the list of plain Tcl commands.

set plain [exec tclsh8.6 << {puts [info commands]}]
set added {}
foreach c [lsort [info commands]] {
    if {$c ni $plain} { lappend added $c }
}
puts "global commands that Tk adds: [llength $added]"
puts "  $added"
puts "commands in ::ttk: [llength [info commands ::ttk::*]]"

# The subcommands of a command, from the error message of a bad one.
proc subs {cmd} {
    catch {{*}$cmd __bogus__} m
    if {![regexp {must be (.*)$} $m -> l]} { return {} }
    return [string map {", or " " " "," "" " or " " "} $l]
}

set classic {button canvas checkbutton entry frame label labelframe
    listbox menu menubutton message panedwindow radiobutton scale
    scrollbar spinbox text toplevel}
set themed {button checkbutton combobox entry frame label labelframe
    menubutton notebook panedwindow progressbar radiobutton scale
    scrollbar separator sizegrip spinbox treeview}

foreach {label prefix list} [list classic {} $classic ttk ttk:: $themed] {
    set no 0
    set ns 0
    foreach w $list {
        ${prefix}$w .x
        set o [llength [.x configure]]
        set s [llength [subs .x]]
        puts "$label $w: $o options, $s subcommands"
        incr no $o
        incr ns $s
        destroy .x
    }
    puts "$label total: [llength $list] widgets, $no options, $ns subcommands"
}

foreach c {wm winfo font image event clipboard selection tk grab option
           ttk::style} {
    puts "$c: [llength [subs $c]] subcommands"
}
# A geometry manager reports its subcommands only with a window argument.
foreach c {grid pack place} {
    catch {$c __bogus__ .} m
    regexp {must be (.*)$} $m -> l
    set l [string map {", or " " " "," "" " or " " "} $l]
    puts "$c: [llength $l] subcommands"
}

canvas .c
set n 0
foreach {t coords} {arc {0 0 1 1} bitmap {0 0} image {0 0} line {0 0 1 1}
        oval {0 0 1 1} polygon {0 0 1 1 2 2} rectangle {0 0 1 1}
        text {0 0} window {0 0}} {
    set id [.c create $t {*}$coords]
    incr n [llength [.c itemconfigure $id]]
}
puts "canvas: 9 item types, $n item options"

menu .m
set n 0
foreach t {cascade checkbutton command radiobutton separator} {
    .m add $t
    incr n [llength [.m entryconfigure end]]
}
puts "menu: 5 entry types, $n entry options"

text .t
.t tag configure x
puts "text: [llength [.t tag configure x]] tag options"

set n 0
foreach c {Button Checkbutton Radiobutton Entry Text Listbox Canvas Scale
        Scrollbar Menu Menubutton Spinbox Panedwindow Label Frame
        Labelframe Message Toplevel all} {
    incr n [llength [bind $c]]
}
puts "classic class bindings: $n"
set n 0
foreach c {TButton TCheckbutton TRadiobutton TEntry TCombobox TFrame TLabel
        TLabelframe TMenubutton TNotebook TPanedwindow TProgressbar TScale
        TScrollbar TSeparator TSizegrip TSpinbox Treeview ComboboxListbox
        ComboboxPopdown} {
    incr n [llength [bind $c]]
}
puts "ttk class bindings: $n"
puts "virtual events: [llength [event info]]"
puts "ttk themes: [ttk::style theme names]"
puts "image types: [image types]"
exit
