# A text editor: a menu bar, a text widget with tags, an embedded
# button, and a scrollbar. It runs in ztk and in wish 8.6.
wm title . "Notes"
menu .mb
. configure -menu .mb
menu .mb.file -tearoff 0
.mb add cascade -label File -menu .mb.file
.mb.file add command -label New -accelerator Ctrl+N -command {.t delete 1.0 end}
.mb.file add separator
.mb.file add command -label Quit -command exit
menu .mb.edit -tearoff 0
.mb add cascade -label Edit -menu .mb.edit
.mb.edit add command -label Undo -accelerator Ctrl+Z -command {catch {.t edit undo}}
.mb.edit add command -label Redo -accelerator Ctrl+Y -command {catch {.t edit redo}}
.mb.edit add separator
.mb.edit add checkbutton -label "Word wrap" -variable wrap -command {.t configure -wrap [expr {$wrap ? "word" : "none"}]}
set wrap 1

text .t -width 56 -height 16 -wrap word -undo 1 -yscrollcommand {.sb set} -padx 10 -pady 8
scrollbar .sb -command {.t yview}
.t tag configure h1 -font {TkDefaultFont 16 bold} -spacing3 6
.t tag configure h2 -font {TkDefaultFont 12 bold} -spacing1 8 -spacing3 4
.t tag configure em -foreground #2563eb -underline 1
.t tag configure code -font TkFixedFont -background #eef2ff
.t tag configure item -lmargin1 12 -lmargin2 26
.t insert end "Meeting notes\n" h1
.t insert end "The text widget has tags, marks, undo, and smooth scrolling. A " {} "link" em " has a color and a line under it.\n"
.t insert end "Tasks\n" h2
.t insert end "• Print the bracket in PETG and check the fit.\n" item
.t insert end "• Measure the slot with " item "calipers" {item code} ".\n" item
.t insert end "• Send the photos. " item
button .t.done -text "Mark done" -padx 6 -pady 0 -command {.t insert insert " ✓"}
.t window create end -window .t.done -align center
.t insert end "\n"
.t insert end "Notes\n" h2
for {set i 1} {$i <= 12} {incr i} { .t insert end "Line $i of the notes. Type here to add text.\n" }
.t mark set insert 2.0
pack .sb -side right -fill y
pack .t -side left -fill both -expand 1
focus .t
