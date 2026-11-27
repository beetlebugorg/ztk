# The helpers of the app scripts in tests/apps. Each script sources this
# file, starts an app from its pinned source folder, drives it with
# ztk::inject as a person does, and checks the result. A check prints
# "ok: text" or "FAIL: text". At the end, `app::done` prints the count
# of failures and exits with status 1 when a check failed.
# SPDX-License-Identifier: BSD-2-Clause

# The real exit, kept before an app replaces the command `exit`.
rename ::exit ::app::RealExit
proc ::exit {{code 0}} {::app::RealExit $code}

namespace eval app {
    variable fails 0
    variable checks 0
    variable errors {}
    variable shots ""
    # The dialogs that answerDialogs closed.
    variable answered {}
}

# Records the background errors of the app, for example an error in a
# binding, so a check can report them.
proc bgerror {msg} {
    lappend ::app::errors $msg
    chan puts stdout "bgerror: $msg"
    chan puts stdout "  [join [lrange [split $::errorInfo \n] 0 6] "\n  "]"
}

proc app::check {ok text} {
    variable fails
    variable checks
    incr checks
    if {$ok} {
        chan puts stdout "ok: $text"
    } else {
        chan puts stdout "FAIL: $text"
        incr fails
    }
    chan flush stdout
}

# Runs a script and checks that it gives no error.
proc app::try {text script} {
    if {[catch {uplevel 1 $script} e]} {
        check 0 "$text: $e"
        chan puts stdout "  [string map {\n "\n  "} $::errorInfo]"
        return 0
    }
    check 1 $text
    return 1
}

# Checks that no background error came since the last call.
proc app::noErrors {text} {
    variable errors
    check [expr {[llength $errors] == 0}] "$text, with no background error"
    set errors {}
}

# The box of a widget in its toplevel: x y w h, or an empty list.
proc app::box {w} {
    foreach row [ztk::tree [winfo toplevel $w]] {
        lassign $row path class x y bw bh mapped
        if {$path eq $w} {return [list $x $y $bw $bh]}
    }
    return {}
}

# Clicks a point of a toplevel with button 1 (or another button).
proc app::clickAt {top x y {button 1}} {
    ztk::inject $top motion $x $y
    ztk::inject $top press $button $x $y
    ztk::inject $top release $button $x $y
    settle
}

# Runs the pending events, the idle callbacks, and the timers of the next
# 50 ms, so the work that a click starts ends before a check.
proc app::settle {{ms 50}} {
    update
    set ::app::tick 0
    after $ms {set ::app::tick 1}
    vwait ::app::tick
    update
}

# Clicks the center of a widget, or a point at dx dy in the widget.
proc app::click {w {dx ""} {dy ""}} {
    update
    lassign [box $w] x y bw bh
    if {$x eq ""} {
        check 0 "click $w: the widget is not in the tree"
        return
    }
    if {$dx eq ""} {set dx [expr {$bw / 2}]}
    if {$dy eq ""} {set dy [expr {$bh / 2}]}
    clickAt [winfo toplevel $w] [expr {$x + $dx}] [expr {$y + $dy}]
}

# Clicks a character of a text widget.
proc app::clickText {w index} {
    $w see $index
    update
    lassign [$w bbox $index] cx cy cw ch
    if {$cx eq ""} {
        check 0 "click $w at $index: the index is not visible"
        return
    }
    click $w [expr {$cx + $cw / 2}] [expr {$cy + $ch / 2}]
}

# Presses and releases a key in a toplevel, with a list of modifiers.
proc app::key {top keysym {state ""}} {
    if {$state ne ""} {
        ztk::inject $top key $keysym press -state $state
        ztk::inject $top key $keysym release -state $state
    } else {
        ztk::inject $top key $keysym
    }
    update
}

# Types text into the widget with the focus.
proc app::type {top text} {
    ztk::inject $top text $text
    update
}

# The toplevels that are not in a list of old ones.
proc app::toplevels {} {
    set out {}
    foreach w [winfo children .] {
        if {[winfo toplevel $w] eq $w} {lappend out $w}
    }
    return $out
}

proc app::newToplevels {old} {
    set out {}
    foreach w [toplevels] {
        if {$w ni $old} {lappend out $w}
    }
    return $out
}

# Writes a PNG image of a widget into the folder of the shots, when the
# script got one.
proc app::shot {w name} {
    variable shots
    if {$shots eq ""} return
    update
    set f [open [file join $shots $name.png] wb]
    chan puts -nonewline $f [binary decode base64 [ztk::snapshot $w]]
    close $f
}

# Answers a modal dialog, as a person does: every 300 ms, it looks for a
# toplevel with a grab or of the class Dialog, and clicks its button OK,
# Cancel, Yes, Close, or Dismiss, or else its first button. The script
# turns it on before a click that can open a dialog that waits.
proc app::answerDialogs {{on 1}} {
    variable answering
    if {[info exists answering]} {after cancel $answering; unset answering}
    if {!$on} return
    set answering [after 300 app::answerDialogs]
    set tops {}
    set g [grab current]
    if {$g ne ""} {lappend tops [winfo toplevel $g]}
    foreach w [toplevels] {
        if {[winfo class $w] eq "Dialog" && $w ni $tops} {lappend tops $w}
    }
    variable seen
    set now [clock milliseconds]
    foreach top $tops {
        # A person reads a dialog first: the answer comes 600 ms after
        # the dialog shows.
        if {![info exists seen($top)]} {set seen($top) $now}
        if {$now - $seen($top) < 600} continue
        unset seen($top)
        set pick ""
        set first ""
        foreach row [ztk::tree $top] {
            lassign $row path class x y bw bh mapped
            if {!$mapped || $class ni {Button TButton}} continue
            if {$first eq ""} {set first $row}
            if {[$path cget -text] in {OK Ok Cancel Yes Close Dismiss}} {set pick $row; break}
        }
        if {$pick eq ""} {set pick $first}
        if {$pick eq ""} continue
        lassign $pick path class x y bw bh
        chan puts stdout "answer: $top with [$path cget -text]"
        lappend ::app::answered $top
        set cx [expr {$x + $bw / 2}]
        set cy [expr {$y + $bh / 2}]
        ztk::inject $top motion $cx $cy
        ztk::inject $top press 1 $cx $cy
        ztk::inject $top release 1 $cx $cy
    }
}

proc app::done {} {
    variable fails
    variable checks
    chan puts stdout "checks: $checks"
    chan puts stdout "fails: $fails"
    ::app::RealExit [expr {$fails > 0}]
}
