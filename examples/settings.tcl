# A settings page: sections of fields, a read-only field, and a disabled
# button. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load settings.css
}
wm title . "Printer settings"
array set cfg {
    name "Shop printer"
    host "printer.local"
    port 7125
    nozzle 0.4
    bed 220
    serial "SP-0092-1187"
}
set status "Saved 2 minutes ago."

label .title -text "Printer settings"
label .sub -text "The changes apply at the next print."
grid .title - -sticky w -padx 20 -pady {18 0}
grid .sub - -sticky w -padx 20 -pady {2 12}

# One section: a heading and a frame with rows of a label and an entry.
proc section {w heading rows} {
    label $w-head -text $heading
    frame $w -padx 14 -pady 10
    grid $w-head - -sticky w -padx 20 -pady {6 4}
    grid $w - -sticky ew -padx 16 -pady {0 8}
    set r 0
    foreach {key text} $rows {
        label $w.l$r -text $text -width 10 -anchor w
        entry $w.e$r -textvariable cfg($key) -width 22
        grid $w.l$r $w.e$r -sticky ew -pady 4 -padx 4
        incr r
    }
    grid columnconfigure $w 1 -weight 1
}
section .net "Network" {name "Name" host "Host" port "Port"}
section .hw "Hardware" {nozzle "Nozzle (mm)" bed "Bed (mm)" serial "Serial"}
.hw.e2 configure -state disabled

frame .bar
button .bar.reset -text "Reset" -state disabled
button .bar.save -text "Save" -command {set status "Saved."}
label .bar.status -textvariable status
grid .bar.status .bar.reset .bar.save -padx 4
grid configure .bar.status -sticky w
grid columnconfigure .bar 0 -weight 1
grid .bar - -sticky ew -padx 16 -pady {4 18}
grid columnconfigure . 0 -weight 1

if {[llength [info commands ::ztk::class]]} {
    foreach w {.net .hw} { ::ztk::class $w add group; ::ztk::class $w-head add heading }
    ::ztk::class .sub add muted
    ::ztk::class .bar.status add muted
    ::ztk::class .bar.save add primary
}
focus .net.e1
.net.e1 selection range 0 end
