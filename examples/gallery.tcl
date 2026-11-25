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
grid $e.l $e.e -sticky ew -padx 4 -pady 3
grid $e.l2 $e.e2 -sticky ew -padx 4 -pady 3
grid columnconfigure $e 1 -weight 1
pack .cols.right.input -fill x -pady 4

# Scales.
set vol 40
labelframe .cols.right.scales -text "Scale" -padx 12 -pady 4
scale .cols.right.scales.s -orient horizontal -from 0 -to 100 -variable vol -tickinterval 25 -length 260
pack .cols.right.scales.s -fill x
pack .cols.right.scales -fill x -pady {10 4} -padx 6

# A labelframe with a message, and a tooltip on the Save button.
labelframe .cols.left.notes -text "Labelframe and message" -padx 12 -pady 6
message .cols.left.notes.m -width 300 -text "A message breaks its text into lines. A labelframe puts a title above a group of widgets."
pack .cols.left.notes.m -anchor w
pack .cols.left.notes -fill x -pady {10 4} -padx 6
if {$ztk} { ::ztk::tooltip $b.save "Saves the document" }

set status ""
