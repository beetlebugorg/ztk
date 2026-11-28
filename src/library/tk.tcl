# The names that a Tk script expects at the start: the package Tk, the
# variables tk_version and tk_patchLevel, and the small commands of the
# Tk library that a well-known app calls. src/cmds.zig evaluates this
# file after the commands of ztk. The Tk release follows the Tcl
# release of the interp: Tk 9.1.0 with Tcl 9.1 (the default of the ztk
# program), and Tk 8.6.16 with Tcl 8.6 (ztk --tcl 8.6). Tk 9 also gives
# the package under the name tk.
# SPDX-License-Identifier: BSD-2-Clause

if {[string match 9.* [info tclversion]]} {
    set ::tk_version 9.1
    set ::tk_patchLevel 9.1.0
    package provide Tk 9.1.0
    package provide tk 9.1.0
} else {
    set ::tk_version 8.6
    set ::tk_patchLevel 8.6.16
    package provide Tk 8.6.16
}

namespace eval ::tk {}

# Gives the text with no ampersand and the index of the character after
# the first single ampersand, or -1. A double ampersand is one literal
# ampersand. For example, "&File" gives {File 0}.
proc ::tk::UnderlineAmpersand {text} {
    set out ""
    set idx -1
    set n [string length $text]
    for {set i 0} {$i < $n} {incr i} {
        set c [string index $text $i]
        if {$c eq "&"} {
            if {[string index $text [expr {$i + 1}]] eq "&"} {
                append out &
                incr i
                continue
            }
            if {$idx < 0} {set idx [string length $out]}
            continue
        }
        append out $c
    }
    return [list $out $idx]
}

# Sets -text and -underline of a widget from a text with an ampersand.
proc ::tk::SetAmpText {widget text} {
    lassign [UnderlineAmpersand $text] t idx
    $widget configure -text $t -underline $idx
}

# Makes a widget of a class with a -text that has an ampersand. Alt and
# the underlined letter invoke the widget. Gives the path.
proc ::tk::AmpWidget {class path args} {
    set opts {}
    foreach {k v} $args {
        if {$k eq "-text"} {
            lassign [UnderlineAmpersand $v] t idx
            lappend opts -text $t -underline $idx
        } else {
            lappend opts $k $v
        }
    }
    $class $path {*}$opts
    if {$class in {button ttk::button checkbutton ttk::checkbutton radiobutton ttk::radiobutton}} {
        bind $path <<AltUnderlined>> [list $path invoke]
    }
    return $path
}

# Runs a menu command with a -label that has an ampersand: for example
# `::tk::AmpMenuArgs .m add command -label &Open`.
proc ::tk::AmpMenuArgs {widget add type args} {
    set opts {}
    foreach {k v} $args {
        if {$k eq "-label"} {
            lassign [UnderlineAmpersand $v] t idx
            lappend opts -label $t -underline $idx
        } else {
            lappend opts $k $v
        }
    }
    $widget $add $type {*}$opts
}

proc ::tk::mc {args} {
    uplevel 1 [list ::msgcat::mc {*}$args]
}

# Puts a toplevel at the center of the screen, at the pointer
# (place "pointer"), or at the center of a widget (place "widget").
proc ::tk::PlaceWindow {w {place ""} {anchor ""}} {
    update idletasks
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    if {$place eq "pointer"} {
        set x [expr {[winfo pointerx $w] - $ww / 2}]
        set y [expr {[winfo pointery $w] - $wh / 2}]
    } elseif {$place eq "widget" && [winfo exists $anchor] && [winfo ismapped $anchor]} {
        set x [expr {[winfo rootx $anchor] + ([winfo width $anchor] - $ww) / 2}]
        set y [expr {[winfo rooty $anchor] + ([winfo height $anchor] - $wh) / 2}]
    } else {
        set x [expr {([winfo screenwidth $w] - $ww) / 2}]
        set y [expr {([winfo screenheight $w] - $wh) / 2}]
    }
    wm geometry $w +[expr {max($x, 0)}]+[expr {max($y, 0)}]
    wm deiconify $w
}

# Moves the focus to a widget, and selects all the text of an entry.
proc ::tk::TabToWindow {w} {
    focus $w
    if {[winfo class $w] in {Entry TEntry Spinbox TSpinbox TCombobox}} {
        $w selection range 0 end
        $w icursor end
    }
}

proc ::tk_textCopy {w} {event generate $w <<Copy>>}
proc ::tk_textCut {w} {event generate $w <<Cut>>}
proc ::tk_textPaste {w} {event generate $w <<Paste>>}

# The bell of the display. ztk has no sound, so it does nothing.
proc ::bell {args} {
    foreach {k v} $args {
        if {$k ni {-displayof -nice}} {
            return -code error "bad option \"$k\": must be -displayof or -nice"
        }
    }
}

namespace eval ::ttk {}

# The cursor of a name of ttk: busy, text, link, and the other names of
# the ttk::cursor manual page. Other names are cursors of Tk already.
proc ::ttk::cursor {name} {
    set map {
        standard left_ptr busy watch wait watch text xterm link hand2
        crosshair crosshair hresize sb_h_double_arrow vresize sb_v_double_arrow
        nresize top_side sresize bottom_side eresize right_side wresize left_side
        neresize top_right_corner nwresize top_left_corner
        seresize bottom_right_corner swresize bottom_left_corner
        move fleur none none
    }
    if {[dict exists $map $name]} {return [dict get $map $name]}
    return $name
}

proc ::ttk::setCursor {w name} {
    $w configure -cursor [::ttk::cursor $name]
}

proc ::ttk::saveCursor {w var name} {
    upvar 1 $var saved
    set saved [$w cget -cursor]
    $w configure -cursor [::ttk::cursor $name]
}

# The state array of the Tk library. Old scripts reach it as the global
# tkPriv after ::tk::unsupported::ExposePrivateVariable.
namespace eval ::tk {
    variable Priv
    array set Priv {}
}
namespace eval ::tk::unsupported {}

proc ::tk::unsupported::ExposePrivateVariable {args} {
    foreach name $args {
        if {$name eq "tkPriv"} {
            uplevel #0 [list upvar #0 ::tk::Priv tkPriv]
        }
    }
}

proc ::tk::unsupported::ExposePrivateCommand {args} {}

# The subcommands of `tk` that are Tcl: appname, busy, caret,
# fontchooser, inactive, and useinputmethods. The command of ztk has
# scaling and windowingsystem, and it gives the message for a bad name.
namespace eval ::ztk::priv {
    variable tkstate
    array set tkstate {appname ztk useinputmethods 0}
    variable busy {}
    variable fontchooser
    array set fontchooser {-parent . -title {} -font {} -command {} -visible 0}
}
rename ::tk ::ztk::priv::tk_core

proc ::tk {args} {
    set names {appname busy caret fontchooser inactive scaling useinputmethods windowingsystem}
    set sub [lindex $args 0]
    set full [lsearch -inline -all -glob $names $sub*]
    if {$sub in $names} {set full [list $sub]}
    if {$full eq "windowingsystem" && [llength $args] == 1 && [info exists ::ztk::priv::windowingsystem]} {
        return $::ztk::priv::windowingsystem
    }
    if {[llength $full] != 1 || [lindex $full 0] in {scaling windowingsystem}} {
        return [uplevel 1 [list ::ztk::priv::tk_core {*}$args]]
    }
    set rest [lrange $args 1 end]
    return [uplevel 1 [list ::ztk::priv::tk_[lindex $full 0] {*}$rest]]
}

proc ::ztk::priv::tk_appname {args} {
    variable tkstate
    if {[llength $args] > 1} {return -code error "wrong # args: should be \"tk appname ?newName?\""}
    if {[llength $args] == 1} {set tkstate(appname) [lindex $args 0]}
    return $tkstate(appname)
}

proc ::ztk::priv::tk_inactive {args} {
    if {[lindex $args 0] eq "-displayof"} {set args [lrange $args 2 end]}
    if {$args eq "reset"} return
    return 0
}

proc ::ztk::priv::tk_useinputmethods {args} {
    variable tkstate
    if {[lindex $args 0] eq "-displayof"} {set args [lrange $args 2 end]}
    if {[llength $args] == 1} {set tkstate(useinputmethods) [expr {!![lindex $args 0]}]}
    return $tkstate(useinputmethods)
}

proc ::ztk::priv::tk_caret {w args} {
    variable caret
    if {![winfo exists $w]} {return -code error "bad window path name \"$w\""}
    if {![info exists caret($w)]} {set caret($w) {-height 0 -x 0 -y 0}}
    if {[llength $args] == 0} {return $caret($w)}
    if {[llength $args] == 1} {return [dict get $caret($w) [lindex $args 0]]}
    foreach {k v} $args {dict set caret($w) $k $v}
    return
}

# `tk busy`: the window keeps a busy mark that `status` and `current`
# give. ztk does not block the input of a busy window.
proc ::ztk::priv::tk_busy {args} {
    variable busy
    set sub [lindex $args 0]
    if {[winfo exists $sub]} {set args [linsert $args 0 hold]; set sub hold}
    set w [lindex $args 1]
    switch -- $sub {
        hold {
            if {$w ni $busy} {lappend busy $w}
            return
        }
        forget {
            set i [lsearch -exact $busy $w]
            if {$i >= 0} {set busy [lreplace $busy $i $i]}
            return
        }
        status {return [expr {$w in $busy}]}
        current {
            set pat [expr {[llength $args] > 1 ? [lindex $args 1] : "*"}]
            return [lsearch -all -inline -glob $busy $pat]
        }
        configure - cget {return}
        default {
            return -code error "unknown or ambiguous subcommand \"$sub\": must be cget, configure, current, forget, hold, or status"
        }
    }
}

# `tk fontchooser`: the options are stored, and `show` and `hide` set
# -visible and send <<TkFontchooserVisibility>>. With the font dialog of
# a backend (`::ztk::priv::nativefont`), `show` runs the dialog to its
# end, as the font dialog of Tk on Windows does. A chosen font goes in
# -font and at the end of the words of -command, and the parent gets
# <<TkFontchooserFontChanged>>. With no font dialog, the options are
# only stored.
proc ::ztk::priv::tk_fontshow {} {
    variable fontchooser
    set f $fontchooser(-font)
    if {$f eq "" || [catch {font actual $f} a]} {set a [font actual TkDefaultFont]}
    set size [dict get $a -size]
    # A size below 0 is in pixels.
    if {$size < 0} {set size [expr {round(-$size * 72.0 / [winfo fpixels . 1i])}]}
    set parent $fontchooser(-parent)
    set fontchooser(-visible) 1
    catch {event generate $parent <<TkFontchooserVisibility>>}
    set code [catch {::ztk::priv::nativefont $fontchooser(-title) [dict get $a -family] $size \
        [expr {[dict get $a -weight] eq "bold"}] [expr {[dict get $a -slant] eq "italic"}] \
        [dict get $a -underline] [dict get $a -overstrike] $parent} got opts]
    set fontchooser(-visible) 0
    catch {event generate $parent <<TkFontchooserVisibility>>}
    if {$code} {return -options $opts $got}
    if {$got eq ""} return
    set fontchooser(-font) $got
    if {$fontchooser(-command) ne ""} {uplevel #0 [linsert $fontchooser(-command) end $got]}
    catch {event generate $parent <<TkFontchooserFontChanged>>}
    return
}

proc ::ztk::priv::tk_fontchooser {{sub ""} args} {
    variable fontchooser
    switch -- $sub {
        configure {
            if {[llength $args] == 0} {return [array get fontchooser]}
            if {[llength $args] == 1} {return $fontchooser([lindex $args 0])}
            foreach {k v} $args {
                if {![info exists fontchooser($k)] || $k eq "-visible"} {
                    return -code error "bad option \"$k\": must be -command, -font, -parent, or -title"
                }
                set fontchooser($k) $v
            }
            return
        }
        show - hide {
            if {$sub eq "show" && [info commands ::ztk::priv::nativefont] ne ""} {
                return [::ztk::priv::tk_fontshow]
            }
            set fontchooser(-visible) [expr {$sub eq "show"}]
            catch {event generate $fontchooser(-parent) <<TkFontchooserVisibility>>}
            return
        }
        default {
            return -code error "unknown or ambiguous subcommand \"$sub\": must be configure, hide, or show"
        }
    }
}

# The names of the themes of ttk, and the command that selects one.
proc ::ttk::themes {{all 0}} {
    return [::ttk::style theme names]
}

proc ::ttk::setTheme {theme} {
    ::ttk::style theme use $theme
}

# The bytes of a file, for `image create photo -file`.
proc ::ztk::priv::readbinary {path} {
    set f [open $path rb]
    try {
        return [read $f]
    } finally {
        close $f
    }
}

# tk_optionMenu pathName varName value ?value ...?: a menubutton that
# shows the global variable, and a menu with a radio entry for each
# value. Gives the name of the menu.
proc ::tk_optionMenu {w varName first args} {
    upvar #0 $varName var
    if {![info exists var]} {set var $first}
    menubutton $w -textvariable $varName -indicatoron 1 -menu $w.menu \
        -relief raised -anchor c -direction flush
    menu $w.menu -tearoff 0
    foreach v [linsert $args 0 $first] {
        $w.menu add radiobutton -label $v -variable $varName -value $v
    }
    return $w.menu
}

# The folder of the Tk library. ztk has no files of the Tk library, so
# the variable is empty, as an app that only reads it expects.
if {![info exists ::tk_library]} {set ::tk_library ""}

# The order of the keyboard traversal, from the manual page focusNext.n:
# the widgets of a toplevel in depth-first order, the children of a
# widget in their stacking order, with no widget of another toplevel.
# Each command gives the next or the previous widget that can take the
# focus, or the window itself when no other can.
proc ::tk_focusNext {w} {
    set cur $w
    while 1 {
        # The first child that is not a toplevel, else the next sibling of
        # the widget or of an ancestor.
        set next ""
        foreach c [winfo children $cur] {
            if {[winfo toplevel $c] ne $c} {set next $c; break}
        }
        while {$next eq ""} {
            if {[winfo toplevel $cur] eq $cur} {set next $cur; break}
            set parent [winfo parent $cur]
            set sibs [winfo children $parent]
            set i [lsearch -exact $sibs $cur]
            foreach c [lrange $sibs [expr {$i + 1}] end] {
                if {[winfo toplevel $c] ne $c} {set next $c; break}
            }
            if {$next eq ""} {set cur $parent}
        }
        set cur $next
        if {$cur eq $w || [::tk::FocusOK $cur]} {return $cur}
    }
}

proc ::tk_focusPrev {w} {
    set cur $w
    while 1 {
        if {[winfo toplevel $cur] eq $cur} {
            set prev $cur
        } else {
            set parent [winfo parent $cur]
            set sibs [winfo children $parent]
            set i [lsearch -exact $sibs $cur]
            set prev $parent
            for {set k [expr {$i - 1}]} {$k >= 0} {incr k -1} {
                set c [lindex $sibs $k]
                if {[winfo toplevel $c] ne $c} {set prev $c; break}
            }
            if {$prev eq $parent} {
                set cur $prev
                if {$cur eq $w || [::tk::FocusOK $cur]} {return $cur}
                continue
            }
        }
        # The last descendant of the previous sibling, or of the toplevel.
        set cur $prev
        while 1 {
            set last ""
            foreach c [winfo children $cur] {
                if {[winfo toplevel $c] ne $c} {set last $c}
            }
            if {$last eq ""} break
            set cur $last
        }
        if {$cur eq $w || [::tk::FocusOK $cur]} {return $cur}
    }
}

# 1 when the keyboard traversal can stop at a widget: its -takefocus,
# or else a widget that is viewable, not disabled, and takes keys.
proc ::tk::FocusOK {w} {
    if {![catch {$w cget -takefocus} value] && $value ni {"" 0 1}} {
        set value [uplevel #0 $value [list $w]]
        if {$value ne ""} {return [expr {!!$value && [winfo viewable $w]}]}
    }
    return [::ztk::priv::focus_ok $w]
}

if {![info exists ::tcl_interactive]} {set ::tcl_interactive 0}

# The selection command of Tk, inside the app: `own` and `clear` keep the
# owner of each selection, `handle` keeps the handlers, and `get` calls
# the handler of the owner. With no owner, the selection CLIPBOARD gives
# the text of the clipboard.
namespace eval ::ztk::priv::sel {
    variable owner
    variable lost
    variable handler
    array set owner {}
    array set lost {}
    array set handler {}
}

proc ::ztk::priv::sel::Opts {argsVar names} {
    upvar 1 $argsVar a
    set opts [dict create -selection PRIMARY -type STRING -displayof . -format STRING -command {}]
    while {[llength $a] > 1 && [string match -* [lindex $a 0]]} {
        set k [lindex $a 0]
        set full [lsearch -inline -glob $names $k*]
        if {$full eq ""} {
            return -code error "bad option \"$k\": must be [join [lrange $names 0 end-1] {, }], or [lindex $names end]"
        }
        dict set opts $full [lindex $a 1]
        set a [lrange $a 2 end]
    }
    return $opts
}

proc ::selection {sub args} {
    variable ::ztk::priv::sel::owner
    variable ::ztk::priv::sel::lost
    variable ::ztk::priv::sel::handler
    switch -- $sub {
        own {
            set o [::ztk::priv::sel::Opts args {-command -displayof -selection}]
            set s [dict get $o -selection]
            if {[llength $args] == 0} {
                return [expr {[info exists owner($s)] && [winfo exists $owner($s)] ? $owner($s) : ""}]
            }
            set w [lindex $args 0]
            if {[info exists owner($s)] && $owner($s) ne $w && [info exists lost($s)] && $lost($s) ne ""} {
                set cmd $lost($s)
                unset lost($s)
                uplevel #0 $cmd
            }
            set owner($s) $w
            set lost($s) [dict get $o -command]
            return
        }
        clear {
            set o [::ztk::priv::sel::Opts args {-displayof -selection}]
            set s [dict get $o -selection]
            if {[info exists owner($s)]} {
                unset owner($s)
                if {[info exists lost($s)] && $lost($s) ne ""} {
                    set cmd $lost($s)
                    unset lost($s)
                    uplevel #0 $cmd
                }
            }
            return
        }
        handle {
            set o [::ztk::priv::sel::Opts args {-format -selection -type}]
            lassign $args w cmd
            set key [list $w [dict get $o -selection] [dict get $o -type]]
            if {$cmd eq ""} {unset -nocomplain handler($key)} else {set handler($key) $cmd}
            return
        }
        get {
            set o [::ztk::priv::sel::Opts args {-displayof -selection -type}]
            set s [dict get $o -selection]
            set t [dict get $o -type]
            if {[info exists owner($s)] && [winfo exists $owner($s)]} {
                foreach type [list $t UTF8_STRING STRING] {
                    set key [list $owner($s) $s $type]
                    if {![info exists handler($key)]} continue
                    set out ""
                    set offset 0
                    while 1 {
                        set part [uplevel #0 $handler($key) [list $offset 4000]]
                        append out $part
                        if {[string length $part] < 4000} break
                        incr offset 4000
                    }
                    return $out
                }
            }
            if {$s eq "CLIPBOARD"} {return [clipboard get -type $t]}
            return -code error "$s selection doesn't exist or form \"$t\" not defined"
        }
        default {
            return -code error "bad option \"$sub\": must be clear, get, handle, or own"
        }
    }
}

# The grid of `wm grid` for a toplevel: a text or a listbox with
# -setgrid 1 gives its size in characters and lines and the size of one
# character and one line. An empty list when no widget sets a grid.
proc ::ztk::priv::wmgrid {top} {
    set todo [winfo children $top]
    while {[llength $todo]} {
        set w [lindex $todo 0]
        set todo [lrange $todo 1 end]
        if {[winfo toplevel $w] ne $top} continue
        lappend todo {*}[winfo children $w]
        if {[winfo class $w] ni {Text Listbox}} continue
        if {[catch {$w cget -setgrid} g] || !$g} continue
        set f [$w cget -font]
        return [list [$w cget -width] [$w cget -height] [font measure $f 0] [font metrics $f -linespace]]
    }
    return {}
}

# tk_setPalette and tk_bisque of palette.n. With one argument, the
# argument is the background, and the other colors come from it: the
# foreground is black on a light background and white on a dark one,
# the active and trough colors are the background 10 percent lighter or
# darker, and the disabled foreground is between the two. Each color
# goes in the option database, and each widget that has the option
# gets it.
proc ::ztk::priv::shade {color pct} {
    lassign [winfo rgb . $color] r g b
    set out "#"
    foreach c [list $r $g $b] {
        set c [expr {$c / 257}]
        if {$pct >= 0} {
            set c [expr {$c + (255 - $c) * $pct / 100}]
        } else {
            set c [expr {$c * (100 + $pct) / 100}]
        }
        append out [format %02x [expr {max(0, min(255, int($c)))}]]
    }
    return $out
}

proc ::tk_setPalette {args} {
    if {[llength $args] == 1} {
        set bg [lindex $args 0]
        set new [list background $bg]
    } elseif {[llength $args] % 2 == 0 && [llength $args] > 0} {
        set new $args
    } else {
        return -code error "wrong # args: should be \"tk_setPalette ?option value ...?\""
    }
    array set p $new
    if {![info exists p(background)]} {
        return -code error "must specify a background color"
    }
    lassign [winfo rgb . $p(background)] r g b
    set light [expr {0.299 * $r + 0.587 * $g + 0.114 * $b > 32768}]
    if {![info exists p(foreground)]} {
        set p(foreground) [expr {$light ? "#000000" : "#ffffff"}]
    }
    set step [expr {$light ? -10 : 10}]
    foreach {name value} [list \
            activeBackground [::ztk::priv::shade $p(background) [expr {-$step}]] \
            activeForeground $p(foreground) \
            highlightBackground $p(background) \
            highlightColor $p(foreground) \
            insertBackground $p(foreground) \
            selectColor [::ztk::priv::shade $p(background) [expr {2 * $step}]] \
            selectBackground [::ztk::priv::shade $p(background) [expr {2 * $step}]] \
            selectForeground $p(foreground) \
            troughColor [::ztk::priv::shade $p(background) $step] \
            disabledForeground [::ztk::priv::shade $p(foreground) [expr {$light ? 60 : -40}]]] {
        if {![info exists p($name)]} {set p($name) $value}
    }
    foreach name [array names p] {
        option add *$name $p($name) widgetDefault
    }
    ::ztk::priv::paletteApply . p
    return
}

proc ::ztk::priv::paletteApply {w pVar} {
    upvar 1 $pVar p
    foreach name [array names p] {
        catch {$w configure -$name $p($name)}
    }
    foreach c [winfo children $w] {
        ::ztk::priv::paletteApply $c p
    }
}

proc ::tk_bisque {} {
    tk_setPalette activeBackground #e6ceb1 activeForeground black \
        background #ffe4c4 disabledForeground #b0b0b0 foreground black \
        highlightBackground #ffe4c4 highlightColor black \
        insertBackground black selectColor #b03060 \
        selectBackground #e6ceb1 selectForeground black \
        troughColor #cdb79e
}
