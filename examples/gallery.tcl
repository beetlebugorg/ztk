# A gallery of the widgets of ztk, laid out with pack and grid. Each
# widget task adds its widgets here. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load gallery.css
}
wm title . "Widget gallery"
set ztk [llength [info commands ::ztk::class]]
proc cls {w args} {
    if {$::ztk} { ::ztk::class $w add {*}$args }
}

label .title -text "Widget gallery"
label .sub -text "Every widget of ztk, with the modern theme."
pack .title -anchor w -padx 20 -pady {18 0}
pack .sub -anchor w -padx 20 -pady {2 10}
cls .sub muted

frame .cols
pack .cols -fill both -expand 1 -padx 14 -pady {0 16}

# A card: a heading over a frame with a border.
proc card {w title} {
    frame $w
    label $w.head -text $title
    frame $w.body -padx 14 -pady 12
    pack $w.head -anchor w -padx 6 -pady {6 4}
    pack $w.body -fill both -expand 1
    cls $w.head heading
    cls $w.body group
    return $w.body
}

frame .cols.left
frame .cols.right
pack .cols.left .cols.right -side left -fill both -expand 1 -padx 6

# Buttons.
set b [card .cols.left.buttons "Buttons"]
button $b.save -text "Save" -command {set status "Saved."}
button $b.cancel -text "Cancel"
button $b.off -text "Disabled" -state disabled
pack $b.save $b.cancel $b.off -side left -padx 4
cls $b.save primary
pack .cols.left.buttons -fill x -pady 4

# Check buttons and switches.
set c [card .cols.left.checks "Check buttons and switches"]
set opts(sync) 1
set opts(notify) 0
set opts(mixed) x
set opts(wifi) 1
set opts(air) 0
checkbutton $c.sync -text "Sync files" -variable opts(sync) -anchor w
checkbutton $c.notify -text "Show notifications" -variable opts(notify) -anchor w
checkbutton $c.mixed -text "Some of the folders" -variable opts(mixed) -tristatevalue x -anchor w
checkbutton $c.locked -text "Locked option" -state disabled -anchor w
checkbutton $c.wifi -text "Wi-Fi" -variable opts(wifi) -anchor w
checkbutton $c.air -text "Airplane mode" -variable opts(air) -anchor w
grid $c.sync $c.wifi -sticky w -padx 4 -pady 2
grid $c.notify $c.air -sticky w -padx 4 -pady 2
grid $c.mixed -sticky w -padx 4 -pady 2
grid $c.locked -sticky w -padx 4 -pady 2
cls $c.wifi switch
cls $c.air switch
pack .cols.left.checks -fill x -pady 4

# Radio buttons and a segmented control.
set r [card .cols.right.radios "Radio buttons"]
set quality high
set view list
foreach {v t} {low "Draft" normal "Normal" high "Fine detail"} {
    radiobutton $r.q$v -text $t -variable quality -value $v -anchor w
    pack $r.q$v -anchor w -padx 4 -pady 1
}
frame $r.seg
foreach {v t} {list "List" grid "Grid" columns "Columns"} {
    radiobutton $r.seg.$v -text $t -variable view -value $v -indicatoron 0
    pack $r.seg.$v -side left
    cls $r.seg.$v segmented
}
pack $r.seg -anchor w -padx 4 -pady {10 2}
pack .cols.right.radios -fill x -pady 4

# Text input.
set e [card .cols.right.input "Text input"]
set name "Ada Lovelace"
label $e.l -text "Name" -anchor w
entry $e.e -textvariable name -width 22
label $e.l2 -text "Read only" -anchor w
entry $e.e2 -width 22
$e.e2 insert 0 "SP-0092-1187"
$e.e2 configure -state disabled
label $e.l3 -text "Search" -anchor w
entry $e.s -width 17
if {$ztk} {
    $e.s configure -placeholder "Search files"
    cls $e.s search
}
label $e.l4 -text "Copies" -anchor w
spinbox $e.n -from 1 -to 99 -width 6
label $e.l5 -text "Size" -anchor w
spinbox $e.z -values {Small Medium Large} -state readonly -width 10
$e.z set Medium
grid $e.l $e.e -sticky ew -padx 4 -pady 3
grid $e.l2 $e.e2 -sticky ew -padx 4 -pady 3
grid $e.l3 $e.s -sticky ew -padx 4 -pady 3
grid $e.l4 $e.n -sticky w -padx 4 -pady 3
grid $e.l5 $e.z -sticky w -padx 4 -pady 3
grid columnconfigure $e 1 -weight 1
pack .cols.right.input -fill x -pady 4

# Scales.
set vol 40
labelframe .cols.right.scales -text "Scale" -padx 12 -pady 4
scale .cols.right.scales.s -orient horizontal -from 0 -to 100 -variable vol -tickinterval 25 -length 260
pack .cols.right.scales.s -fill x
pack .cols.right.scales -fill x -pady {10 4} -padx 6

# A scrollbar: an entry with a long text scrolls with the scrollbar under it.
set sc .cols.right.scroll
labelframe $sc -text "Scrollbar" -padx 12 -pady 6
entry $sc.e -width 22 -xscrollcommand [list $sc.s set]
scrollbar $sc.s -orient horizontal -command [list $sc.e xview]
$sc.e insert 0 "A long line of text that is wider than its entry, so the scrollbar under it moves the view."
pack $sc.e $sc.s -fill x
pack $sc -fill x -pady {10 4} -padx 6
$sc.e xview moveto 0.3
$sc.s set {*}[$sc.e xview]

# The ttk widgets, with the switch style and a style of a script.
set tk [card .cols.right.ttk "Themed widgets (ttk)"]
set ttkopt(dark) 1
set ttkopt(size) M
ttk::style configure Accent.TButton -foreground white -background #2563eb
ttk::style map Accent.TButton -background {active #1d4ed8}
ttk::button $tk.ok -text "Apply" -style Accent.TButton
ttk::button $tk.reset -text "Reset"
ttk::checkbutton $tk.dark -text "Dark mode" -style Switch.TCheckbutton -variable ttkopt(dark)
ttk::separator $tk.sep
ttk::radiobutton $tk.s -text "Small" -variable ttkopt(size) -value S
ttk::radiobutton $tk.m -text "Medium" -variable ttkopt(size) -value M
ttk::entry $tk.e -width 14
if {$ztk} { $tk.e configure -placeholder "ttk::entry" }
grid $tk.ok $tk.reset $tk.dark -sticky w -padx 4 -pady 3
grid $tk.sep -columnspan 3 -sticky ew -padx 4 -pady 4
grid $tk.s $tk.m $tk.e -sticky w -padx 4 -pady 3
# The range widgets: the scale and the progress bar share a variable.
set ttkopt(level) 60
ttk::combobox $tk.cb -values {Apple Banana Cherry Date} -width 10 -state readonly
$tk.cb current 1
ttk::spinbox $tk.sp -from 1 -to 10 -width 4
$tk.sp set 3
ttk::scale $tk.sc -from 0 -to 100 -variable ttkopt(level)
ttk::progressbar $tk.pb -maximum 100 -variable ttkopt(level)
grid $tk.cb $tk.sp $tk.sc -sticky w -padx 4 -pady 3
grid $tk.pb -columnspan 3 -sticky ew -padx 4 -pady {3 6}
pack .cols.right.ttk -fill x -pady 4

# Panes: a panedwindow with a list and a vertical ttk::panedwindow. A drag of a sash resizes the panes.
set pn [card .cols.right.panes "Panes"]
panedwindow $pn.p -height 116
listbox $pn.p.l -width 8 -height 3 -activestyle none -exportselection 0
$pn.p.l insert end Inbox Drafts Sent
$pn.p.l selection set 0
cls $pn.p.l sidebar
ttk::panedwindow $pn.p.r -orient vertical
label $pn.p.r.top -text "Drag a sash"
label $pn.p.r.bottom -text "Preview"
cls $pn.p.r.bottom muted
$pn.p.r add $pn.p.r.top -weight 1
$pn.p.r add $pn.p.r.bottom -weight 1
$pn.p add $pn.p.l -stretch never
$pn.p add $pn.p.r -stretch always
pack $pn.p -fill x
pack .cols.right.panes -fill x -pady 4

# Lists: a sidebar, and a list with a scrollbar and the extended selection mode.
set ls [card .cols.left.lists "Lists"]
listbox $ls.side -height 4 -width 12 -activestyle none -exportselection 0
$ls.side insert end Inbox Drafts Sent Archive
$ls.side selection set 0
cls $ls.side sidebar
listbox $ls.l -height 4 -width 16 -selectmode extended -exportselection 0 -yscrollcommand [list $ls.sb set]
scrollbar $ls.sb -command [list $ls.l yview]
$ls.l insert end Apple Apricot Banana Blueberry Cherry Date Fig Grape Kiwi Lemon Mango
$ls.l selection set 2
grid $ls.side $ls.l $ls.sb -sticky nsew -padx 4
pack .cols.left.lists -fill x -pady 4

# A labelframe with a message, and a tooltip on the Save button.
labelframe .cols.left.notes -text "Labelframe and message" -padx 12 -pady 6
message .cols.left.notes.m -width 300 -text "A message breaks its text into lines. A labelframe puts a title above a group of widgets."
pack .cols.left.notes.m -anchor w
pack .cols.left.notes -fill x -pady {10 4} -padx 6
if {$ztk} { ::ztk::tooltip $b.save "Saves the document" }

# A canvas: shapes that the mouse drags, with a hover color.
set cv [card .cols.left.canvas "Canvas"]
canvas $cv.c -width 300 -height 104 -highlightthickness 0
pack $cv.c -fill x
$cv.c create rectangle 8 10 88 66 -fill #2563eb -activefill #3b82f6 -outline {} -tags shape
$cv.c create oval 108 8 168 68 -fill #f59e0b -activefill #fbbf24 -outline {} -tags shape
$cv.c create polygon 188 68 218 8 248 68 -fill #10b981 -activefill #34d399 -tags shape
$cv.c create line 8 88 110 88 -arrow last -width 2 -fill #8e8e93
$cv.c create text 122 88 -text "Drag a shape" -anchor w
$cv.c bind shape <Button-1> {set ::dragxy [list %x %y]; %W raise current}
$cv.c bind shape <B1-Motion> {
    lassign $::dragxy x0 y0
    %W move current [expr {%x - $x0}] [expr {%y - $y0}]
    set ::dragxy [list %x %y]
}
pack .cols.left.canvas -fill x -pady 4

# Menus: two menu buttons, and a context menu on the hint.
set mn [card .cols.left.menus "Menus"]
menu .gedit -tearoff 0
.gedit add command -label Cut -accelerator Ctrl+X
.gedit add command -label Copy -accelerator Ctrl+C
.gedit add command -label Paste -accelerator Ctrl+V
.gedit add separator
.gedit add checkbutton -label "Word wrap" -variable gwrap
.gedit add cascade -label Insert -menu .gedit.ins
menu .gedit.ins -tearoff 0
.gedit.ins add command -label Date
.gedit.ins add command -label Time
menu .galign -tearoff 0
foreach a {Left Center Right} { .galign add radiobutton -label $a -variable galign -value $a }
set galign Left
menubutton $mn.mb -text Edit -menu .gedit
ttk::menubutton $mn.tb -textvariable galign -menu .galign
label $mn.hint -text "Right-click here"
cls $mn.hint muted
bind $mn.hint <Button-3> {tk_popup .gedit %X %Y}
grid $mn.mb $mn.tb $mn.hint -sticky w -padx 4 -pady 3
pack .cols.left.menus -fill x -pady 4

set status ""
