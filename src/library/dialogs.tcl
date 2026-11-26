# The dialogs of Tk, drawn by ztk with its own widgets: tk_messageBox,
# tk_dialog, tk_chooseColor, tk_getOpenFile, tk_getSaveFile, and
# tk_chooseDirectory, with ztk::toast. src/dialogs.zig evaluates this
# file at the start. A backend with native dialogs registers its own
# commands first, and this file keeps them.
#
# Each dialog is a toplevel of the class Dialog with a grab. The script
# waits in vwait until a button sets the answer, then deletes the dialog
# and gives the answer.
# SPDX-License-Identifier: BSD-2-Clause

namespace eval ::ztk::dialog {
    variable answer ""
}

# Parses the options of a dialog: argv is a list of -option value pairs.
# Gives a dict of the options with their defaults. The message of a bad
# option lists the names of the defaults in their order.
proc ::ztk::dialog::Options {defaults argv} {
    set names [dict keys $defaults]
    set opts $defaults
    foreach {k v} $argv {
        if {![dict exists $defaults $k]} {
            set last [lindex $names end]
            set list [join [lrange $names 0 end-1] ", "]
            return -code error "bad option \"$k\": must be $list, or $last"
        }
    }
    if {[llength $argv] % 2} {
        return -code error "value for \"[lindex $argv end]\" missing"
    }
    foreach {k v} $argv { dict set opts $k $v }
    if {[dict exists $opts -parent] && ![winfo exists [dict get $opts -parent]]} {
        return -code error "bad window path name \"[dict get $opts -parent]\""
    }
    return $opts
}

# Makes the toplevel of a dialog over its parent.
proc ::ztk::dialog::Toplevel {w parent title} {
    catch {destroy $w}
    toplevel $w -class Dialog
    wm title $w $title
    catch {wm transient $w [winfo toplevel $parent]}
    wm protocol $w WM_DELETE_WINDOW [list $w.__cancel invoke]
    button $w.__cancel -command [list set ::ztk::dialog::answer ""]
    return $w
}

# Shows a dialog: the grab, the focus, and the wait for the answer.
# Gives the answer, and deletes the dialog.
proc ::ztk::dialog::Wait {w focus} {
    variable answer
    set answer "\0"
    set old [focus]
    catch {grab $w}
    if {$focus ne "" && [winfo exists $focus]} { focus $focus }
    while {$answer eq "\0"} {
        vwait ::ztk::dialog::answer
        if {![winfo exists $w]} { break }
    }
    if {$answer eq "\0"} { set answer "" }
    set result $answer
    catch {grab release $w}
    catch {destroy $w}
    if {$old ne "" && [winfo exists $old]} { catch {focus $old} }
    return $result
}

# The row of buttons at the bottom right. Each item is {name label}.
# The default button has the style class primary.
proc ::ztk::dialog::Buttons {w items default} {
    frame $w.bot
    ::ztk::class $w.bot add dialog-buttons
    set first ""
    foreach {name text} $items {
        button $w.bot.$name -text $text -command [list set ::ztk::dialog::answer $name]
        if {$name eq $default} { ::ztk::class $w.bot.$name add primary }
        if {$first eq ""} { set first $w.bot.$name }
    }
    foreach name [lreverse [dict keys $items]] {
        pack $w.bot.$name -side right -padx {6 0}
    }
    pack $w.bot -side bottom -fill x -padx 16 -pady {8 14}
    bind $w <Key-Return> {
        set f [focus]
        if {[winfo class $f] eq "Button"} { $f invoke }
    }
    return $first
}

# ---- tk_messageBox ----

proc tk_messageBox {args} {
    set opts [::ztk::dialog::Options {-default "" -detail "" -icon info -message "" -parent . -title "" -type ok} $args]
    dict with opts {}
    set types {
        abortretryignore {abort Abort retry Retry ignore Ignore}
        ok {ok OK}
        okcancel {ok OK cancel Cancel}
        retrycancel {retry Retry cancel Cancel}
        yesno {yes Yes no No}
        yesnocancel {yes Yes no No cancel Cancel}
    }
    if {![dict exists $types ${-type}]} {
        return -code error "bad -type value \"${-type}\": must be abortretryignore, ok, okcancel, retrycancel, yesno, or yesnocancel"
    }
    if {${-icon} ni {error info question warning}} {
        return -code error "bad -icon value \"${-icon}\": must be error, info, question, or warning"
    }
    set items [dict get $types ${-type}]
    if {${-default} ne ""} {
        if {![dict exists $items ${-default}]} {
            return -code error "bad -default value \"${-default}\": must be abort, retry, ignore, ok, cancel, no, or yes"
        }
    } else {
        set -default [lindex $items 0]
    }
    # A backend with native message boxes shows its own.
    if {[info commands ::ztk::priv::nativemessagebox] ne ""} {
        return [::ztk::priv::nativemessagebox ${-type} ${-icon} ${-title} ${-message} ${-detail} ${-default} ${-parent}]
    }
    set w [::ztk::dialog::MessageBox ${-parent} ${-title} ${-icon} ${-message} ${-detail} $items ${-default}]
    return [::ztk::dialog::Wait $w $w.bot.${-default}]
}

# Builds the window of a message box and gives its path. The Escape key
# and the close button give the cancel answer of the type: cancel, or
# no, abort, or ok when the type has no cancel button.
proc ::ztk::dialog::MessageBox {parent title icon message detail items default} {
    set w [::ztk::dialog::Toplevel .__tk__messagebox $parent $title]
    set names [dict keys $items]
    foreach c {cancel no abort ok} {
        if {$c in $names} { $w.__cancel configure -command [list set ::ztk::dialog::answer $c]; break }
    }
    bind $w <Key-Escape> [list $w.__cancel invoke]
    ::ztk::dialog::Buttons $w $items $default
    frame $w.top
    set glyph [dict get {error ! info i question ? warning !} $icon]
    label $w.top.icon -text $glyph
    ::ztk::class $w.top.icon add dialog-icon $icon
    ttk::label $w.top.msg -text $message -justify left -anchor w -wraplength 320
    ::ztk::class $w.top.msg add dialog-message
    pack $w.top.icon -side left -anchor n -padx {0 14}
    pack $w.top.msg -side top -anchor w -fill x
    if {$detail ne ""} {
        ttk::label $w.top.dtl -text $detail -justify left -anchor w -wraplength 320
        ::ztk::class $w.top.dtl add dialog-detail
        pack $w.top.dtl -side top -anchor w -fill x -pady {6 0}
    }
    pack $w.top -side top -fill both -expand 1 -padx 18 -pady {18 4}
    return $w
}

# ---- tk_dialog ----

proc tk_dialog {w title text bitmap default args} {
    ::ztk::dialog::Toplevel $w . $title
    $w.__cancel configure -command [list set ::ztk::dialog::answer -1]
    set items {}
    set i 0
    foreach s $args { lappend items $i $s; incr i }
    ::ztk::dialog::Buttons $w $items $default
    frame $w.top
    ttk::label $w.top.msg -text $text -justify left -anchor w -wraplength 320
    ::ztk::class $w.top.msg add dialog-message
    pack $w.top.msg -side top -anchor w -fill x
    pack $w.top -side top -fill both -expand 1 -padx 18 -pady {18 4}
    bind $w <Key-Return> {
        set f [focus]
        if {[winfo class $f] eq "Button"} { $f invoke }
    }
    set focus ""
    if {$default >= 0 && [winfo exists $w.bot.$default]} { set focus $w.bot.$default }
    if {$focus eq ""} { set focus $w }
    return [::ztk::dialog::Wait $w $focus]
}

# ---- tk_chooseColor ----

proc tk_chooseColor {args} {
    set opts [::ztk::dialog::Options {-initialcolor "" -parent . -title "Choose a color"} $args]
    dict with opts {}
    set rgb {128 128 128}
    if {${-initialcolor} ne ""} {
        if {[catch {winfo rgb . ${-initialcolor}} c]} {
            return -code error "unknown color name \"${-initialcolor}\""
        }
        set rgb {}
        foreach v $c { lappend rgb [expr {$v / 257}] }
    }
    set w [::ztk::dialog::ColorBox ${-parent} ${-title} $rgb]
    return [::ztk::dialog::Wait $w $w.bot.ok]
}

namespace eval ::ztk::dialog {
    variable swatches {
        #ef4444 #f97316 #f59e0b #eab308 #84cc16 #22c55e
        #10b981 #14b8a6 #06b6d4 #0ea5e9 #3b82f6 #6366f1
        #8b5cf6 #a855f7 #d946ef #ec4899 #f43f5e #78716c
        #000000 #404040 #808080 #c0c0c0 #e5e5e5 #ffffff
    }
}

proc ::ztk::dialog::ColorBox {parent title rgb} {
    variable swatches
    set w [::ztk::dialog::Toplevel .__tk__color $parent $title]
    bind $w <Key-Escape> [list $w.__cancel invoke]
    ::ztk::dialog::Buttons $w {cancel Cancel ok OK} ok
    $w.bot.ok configure -command [list ::ztk::dialog::ColorDone $w]
    $w.bot.cancel configure -command [list set ::ztk::dialog::answer ""]
    frame $w.top
    frame $w.top.sw
    set i 0
    foreach c $swatches {
        frame $w.top.sw.c$i -width 22 -height 22 -background $c
        ::ztk::class $w.top.sw.c$i add dialog-swatch
        bind $w.top.sw.c$i <Button-1> [list ::ztk::dialog::ColorSet $w $c]
        grid $w.top.sw.c$i -row [expr {$i / 6}] -column [expr {$i % 6}] -padx 2 -pady 2
        incr i
    }
    frame $w.top.pv -width 64 -height 64
    ::ztk::class $w.top.pv add dialog-swatch
    frame $w.top.rgb
    foreach n {r g b} label {Red Green Blue} v $rgb {
        set ::ztk::dialog::color($n) $v
        label $w.top.rgb.l$n -text $label
        ttk::scale $w.top.rgb.s$n -from 0 -to 255 -length 160 -variable ::ztk::dialog::color($n) \
            -command [list ::ztk::dialog::ColorScale $w]
        grid $w.top.rgb.l$n $w.top.rgb.s$n -sticky w -padx 2 -pady 2
    }
    label $w.top.rgb.lhex -text Hex
    entry $w.top.rgb.hex -width 9 -textvariable ::ztk::dialog::color(hex)
    grid $w.top.rgb.lhex $w.top.rgb.hex -sticky w -padx 2 -pady 2
    bind $w.top.rgb.hex <Key-Return> [list ::ztk::dialog::ColorHex $w]
    grid $w.top.sw $w.top.pv -sticky nw -padx 6
    grid $w.top.rgb - -sticky w -padx 6 -pady {10 0}
    pack $w.top -side top -fill both -expand 1 -padx 16 -pady {16 4}
    ::ztk::dialog::ColorScale $w
    return $w
}

proc ::ztk::dialog::ColorHex {w} {
    variable color
    if {[catch {winfo rgb . $color(hex)} c]} { return }
    lassign $c r g b
    ColorSet $w [format #%02x%02x%02x [expr {$r / 257}] [expr {$g / 257}] [expr {$b / 257}]]
}

proc ::ztk::dialog::ColorSet {w c} {
    variable color
    scan $c #%2x%2x%2x color(r) color(g) color(b)
    ColorScale $w
}

proc ::ztk::dialog::ColorScale {w args} {
    variable color
    foreach n {r g b} { set color($n) [expr {int(round($color($n)))}] }
    set color(hex) [format #%02x%02x%02x $color(r) $color(g) $color(b)]
    if {[winfo exists $w.top.pv]} { $w.top.pv configure -background $color(hex) }
}

proc ::ztk::dialog::ColorDone {w} {
    variable color
    ColorHex $w
    set ::ztk::dialog::answer $color(hex)
}

# ---- The file dialogs ----

# The filters of -filetypes: a list of {name patterns}, with the patterns
# as glob patterns. A pattern ".txt" is "*.txt".
proc ::ztk::dialog::Filters {types} {
    set out {}
    foreach t $types {
        if {[llength $t] < 2 || [llength $t] > 3} {
            return -code error "bad file type \"$t\", should be \"typeName {extension ?extensions ...?} ?{macType ?macTypes ...?}?\""
        }
        set pats {}
        foreach p [lindex $t 1] {
            if {[string index $p 0] eq "."} { set p *$p }
            lappend pats $p
        }
        lappend out [lindex $t 0] $pats
    }
    return $out
}

proc ::ztk::dialog::NeedFiles {} {
    if {[info commands glob] eq "" || [catch {pwd}]} {
        return -code error "the file dialogs need the file capability"
    }
}

proc ::ztk::dialog::FileDialog {kind args} {
    switch -- $kind {
        open { set defaults {-defaultextension "" -filetypes "" -initialdir "" -initialfile "" -multiple 0 -parent . -title "Open" -typevariable ""} }
        save { set defaults {-confirmoverwrite 1 -defaultextension "" -filetypes "" -initialdir "" -initialfile "" -parent . -title "Save As" -typevariable ""} }
        dir { set defaults {-initialdir "" -mustexist 0 -parent . -title "Choose Directory"} }
    }
    set opts [Options $defaults $args]
    set filters {}
    if {[dict exists $opts -filetypes]} { set filters [Filters [dict get $opts -filetypes]] }
    NeedFiles
    variable fd
    array unset fd
    set fd(kind) $kind
    set fd(opts) $opts
    set fd(filters) $filters
    set dir [dict get $opts -initialdir]
    if {$dir eq "" || ![file isdirectory $dir]} { set dir [pwd] }
    set fd(dir) [file normalize $dir]
    set fd(name) [expr {[dict exists $opts -initialfile] ? [dict get $opts -initialfile] : ""}]
    set fd(filter) 0
    if {[dict exists $opts -typevariable] && [dict get $opts -typevariable] ne ""} {
        upvar #0 [dict get $opts -typevariable] tv
        if {[info exists tv]} {
            set k [lsearch -exact [dict keys $filters] $tv]
            if {$k >= 0} { set fd(filter) $k }
        }
    }
    set w [FileBox [dict get $opts -parent] [dict get $opts -title]]
    set r [Wait $w $w.name.e]
    if {$r ne "" && [dict exists $opts -typevariable] && [dict get $opts -typevariable] ne "" && [llength $filters]} {
        upvar #0 [dict get $opts -typevariable] tv
        set tv [lindex [dict keys $filters] $fd(filter)]
    }
    return $r
}

proc tk_getOpenFile {args} { return [::ztk::dialog::FileDialog open {*}$args] }
proc tk_getSaveFile {args} { return [::ztk::dialog::FileDialog save {*}$args] }
proc tk_chooseDirectory {args} { return [::ztk::dialog::FileDialog dir {*}$args] }

proc ::ztk::dialog::FileBox {parent title} {
    variable fd
    set w [Toplevel .__tk_filedialog $parent $title]
    bind $w <Key-Escape> [list $w.__cancel invoke]
    set ok [expr {$fd(kind) eq "save" ? "Save" : ($fd(kind) eq "dir" ? "Choose" : "Open")}]
    Buttons $w [list cancel Cancel ok $ok] ok
    $w.bot.ok configure -command [list ::ztk::dialog::FileOk $w]
    $w.bot.cancel configure -command [list set ::ztk::dialog::answer ""]
    frame $w.path
    button $w.path.up -text "↑" -command [list ::ztk::dialog::FileUp $w]
    label $w.path.l -textvariable ::ztk::dialog::fd(dir) -anchor w
    pack $w.path.up -side left
    pack $w.path.l -side left -fill x -expand 1 -padx 8
    pack $w.path -side top -fill x -padx 16 -pady {14 6}
    frame $w.name
    label $w.name.l -text [expr {$fd(kind) eq "dir" ? "Folder:" : "Name:"}]
    entry $w.name.e -textvariable ::ztk::dialog::fd(name)
    pack $w.name.l -side left
    pack $w.name.e -side left -fill x -expand 1 -padx {8 0}
    if {[llength $fd(filters)]} {
        set fd(filtername) [lindex [dict keys $fd(filters)] $fd(filter)]
        ttk::combobox $w.name.f -state readonly -width 14 -values [dict keys $fd(filters)] -textvariable ::ztk::dialog::fd(filtername)
        bind $w.name.f <<ComboboxSelected>> [list ::ztk::dialog::FileFilter $w]
        pack $w.name.f -side left -padx {8 0}
    }
    pack $w.name -side bottom -fill x -padx 16 -pady 6
    frame $w.list
    set mode [expr {$fd(kind) eq "open" && [dict get $fd(opts) -multiple] ? "extended" : "browse"}]
    listbox $w.list.l -height 12 -width 44 -selectmode $mode -exportselection 0 -yscrollcommand [list $w.list.s set]
    scrollbar $w.list.s -command [list $w.list.l yview]
    pack $w.list.s -side right -fill y
    pack $w.list.l -side left -fill both -expand 1
    pack $w.list -side top -fill both -expand 1 -padx 16
    bind $w.list.l <<ListboxSelect>> [list ::ztk::dialog::FilePick $w]
    bind $w.list.l <Double-Button-1> [list ::ztk::dialog::FileOpen $w]
    bind $w.name.e <Key-Return> [list ::ztk::dialog::FileOk $w]
    FileList $w
    return $w
}

# Fills the list: the folders with a "/" after the name, then the files
# that match the filter. A folder dialog lists folders only.
proc ::ztk::dialog::FileList {w} {
    variable fd
    set l $w.list.l
    $l delete 0 end
    set dirs [lsort -dictionary [glob -nocomplain -tails -types d -directory $fd(dir) *]]
    foreach d $dirs { $l insert end $d/ }
    if {$fd(kind) eq "dir"} { return }
    set pats *
    if {[llength $fd(filters)]} { set pats [lindex [dict values $fd(filters)] $fd(filter)] }
    set files {}
    foreach p $pats {
        foreach f [glob -nocomplain -tails -types f -directory $fd(dir) $p] { lappend files $f }
    }
    foreach f [lsort -dictionary -unique $files] { $l insert end $f }
}

proc ::ztk::dialog::FileFilter {w} {
    variable fd
    set fd(filter) [lsearch -exact [dict keys $fd(filters)] $fd(filtername)]
    FileList $w
}

proc ::ztk::dialog::FilePick {w} {
    variable fd
    set names {}
    foreach i [$w.list.l curselection] {
        set n [$w.list.l get $i]
        if {[string index $n end] eq "/"} {
            if {$fd(kind) eq "dir"} { lappend names [string range $n 0 end-1] }
            continue
        }
        lappend names $n
    }
    if {[llength $names] == 1} {
        set fd(name) [lindex $names 0]
    } elseif {[llength $names] > 1} {
        set fd(name) $names
    }
}

proc ::ztk::dialog::FileUp {w} {
    variable fd
    set fd(dir) [file dirname $fd(dir)]
    set fd(name) ""
    FileList $w
}

# A double click: a folder opens, and a file is the answer.
proc ::ztk::dialog::FileOpen {w} {
    variable fd
    set i [$w.list.l curselection]
    if {[llength $i] != 1} { return }
    set n [$w.list.l get $i]
    if {[string index $n end] eq "/"} {
        set fd(dir) [file join $fd(dir) [string range $n 0 end-1]]
        set fd(name) ""
        FileList $w
        return
    }
    set fd(name) $n
    FileOk $w
}

proc ::ztk::dialog::FileOk {w} {
    variable fd
    set opts $fd(opts)
    if {$fd(kind) eq "dir"} {
        set path $fd(dir)
        if {$fd(name) ne ""} { set path [file join $fd(dir) $fd(name)] }
        if {[dict get $opts -mustexist] && ![file isdirectory $path]} { return }
        set ::ztk::dialog::answer [file normalize $path]
        return
    }
    if {$fd(name) eq ""} { return }
    if {$fd(kind) eq "open" && [dict get $opts -multiple]} {
        set out {}
        foreach n $fd(name) { lappend out [file normalize [file join $fd(dir) $n]] }
        set ::ztk::dialog::answer $out
        return
    }
    set path [file join $fd(dir) $fd(name)]
    if {[file isdirectory $path]} {
        set fd(dir) [file normalize $path]
        set fd(name) ""
        FileList $w
        return
    }
    if {$fd(kind) eq "open" && ![file exists $path]} { return }
    if {$fd(kind) eq "save"} {
        set ext [dict get $opts -defaultextension]
        if {$ext ne "" && [file extension $path] eq ""} {
            if {[string index $ext 0] ne "."} { set ext .$ext }
            append path $ext
        }
        if {[file exists $path] && [dict get $opts -confirmoverwrite]} {
            # The question is a second dialog; it has its own answer.
            set keep $::ztk::dialog::answer
            set r [tk_messageBox -parent $w -icon warning -type yesno -default no \
                -message "[file tail $path] already exists." -detail "Do you want to replace it?"]
            set ::ztk::dialog::answer $keep
            if {$r ne "yes"} { return }
        }
    }
    set ::ztk::dialog::answer [file normalize $path]
}

# ---- ztk::toast ----

namespace eval ::ztk::dialog { variable toasts 0 }

# Shows a short message at the bottom of the main window. It slides in,
# stays for -duration ms, and slides out.
proc ::ztk::toast {text args} {
    set opts [::ztk::dialog::Options {-duration 2500} $args]
    set ms [dict get $opts -duration]
    if {![string is integer -strict $ms]} { return -code error "expected integer but got \"$ms\"" }
    set w .__ztk_toast[incr ::ztk::dialog::toasts]
    label $w -text $text
    ::ztk::class $w add toast
    place $w -relx 0.5 -rely 1.0 -anchor n -y 0
    ::ztk::dialog::Slide $w 0 [expr {-[winfo reqheight $w] - 24}] 0
    after [expr {$ms + 220}] [list ::ztk::dialog::Slide $w [expr {-[winfo reqheight $w] - 24}] 0 0 1]
    return $w
}

# Moves a toast from y0 to y1 in 220 ms with an ease out, one step for
# each frame. With `remove`, the toast goes away at the end.
proc ::ztk::dialog::Slide {w y0 y1 step {remove 0}} {
    if {![winfo exists $w]} { return }
    set n 13
    if {[::ztk::animate reduce]} { set step $n }
    set t [expr {min(1.0, double($step) / $n)}]
    set e [expr {1 - (1 - $t) ** 3}]
    place configure $w -y [expr {round($y0 + ($y1 - $y0) * $e)}]
    if {$step < $n} {
        after 16 [list ::ztk::dialog::Slide $w $y0 $y1 [expr {$step + 1}] $remove]
    } elseif {$remove} {
        destroy $w
    }
}
