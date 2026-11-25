# The window of examples/themes.tcl in the classic theme, with the sizes
# and colors of Tk on X11. It runs in ztk and in wish 8.6.
set theme classic
set ztk [llength [info commands ::ztk::style]]
if {![info exists theme]} { set theme modern }
if {$ztk} { ::ztk::style theme $theme }
wm title . "ttk widgets: $theme theme"

# A style of the script: Accent.TButton is the CSS selector TButton.Accent.
ttk::style configure Accent.TButton -foreground white -background #2563eb
ttk::style map Accent.TButton -background {active #1d4ed8}

set opt(wifi) 1
set opt(notify) 0
set opt(size) M
ttk::frame .f -padding 16
pack .f -fill both -expand 1

ttk::label .f.title -text "Themed widgets ($theme)"
ttk::labelframe .f.lf -text "ttk::labelframe" -padding 10
ttk::button .f.lf.ok -text "Apply" -style Accent.TButton
ttk::button .f.lf.cancel -text "Cancel"
ttk::button .f.lf.off -text "Disabled"
.f.lf.off state disabled
ttk::checkbutton .f.lf.notify -text "Notify me" -variable opt(notify)
ttk::checkbutton .f.lf.wifi -text "Wi-Fi" -style Switch.TCheckbutton -variable opt(wifi)
ttk::radiobutton .f.lf.s -text "Small" -variable opt(size) -value S
ttk::radiobutton .f.lf.m -text "Medium" -variable opt(size) -value M
ttk::radiobutton .f.lf.l -text "Large" -variable opt(size) -value L
ttk::separator .f.lf.sep
ttk::entry .f.lf.name -width 24
.f.lf.name insert 0 "ttk::entry"
ttk::entry .f.lf.ro -width 24
.f.lf.ro insert 0 "read-only entry"
.f.lf.ro state readonly

grid .f.lf.ok .f.lf.cancel .f.lf.off -sticky w -padx 4 -pady 4
grid .f.lf.notify .f.lf.wifi - -sticky w -padx 4 -pady 4
grid .f.lf.s .f.lf.m .f.lf.l -sticky w -padx 4 -pady 4
grid .f.lf.sep - - -sticky ew -padx 4 -pady 6
grid .f.lf.name - - -sticky ew -padx 4 -pady 4
grid .f.lf.ro - - -sticky ew -padx 4 -pady 4

ttk::sizegrip .f.grip
pack .f.title -anchor w -pady {0 8}
pack .f.lf -fill both -expand 1
pack .f.grip -side right -anchor se
