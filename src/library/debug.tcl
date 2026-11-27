# SPDX-License-Identifier: BSD-2-Clause
# The short answers of `ztk::debug explain`, `ran`, `click`, and
# `changes`, and the MCP tools of `ztk --mcp`. Each answer is lines of
# text with a limit on the count of lines, for agents and for people.
# The data comes from `ztk::debug why`, `geometry`, `trace records`, and
# `diff` (src/debug.zig).

namespace eval ::ztk::priv::dbg {
    # The longest answer in lines, and the longest value in characters.
    variable max_lines 24
    variable max_text 80
}

# The first max_text characters of a value on one line.
proc ::ztk::priv::dbg::short {s} {
    variable max_text
    set s [string map {\n { } \t { }} $s]
    if {[string length $s] > $max_text} {
        set s "[string range $s 0 [expr {$max_text - 4}]]..."
    }
    return $s
}

# The lines, with one line for the count of the lines past the limit.
proc ::ztk::priv::dbg::lines {list} {
    variable max_lines
    if {[llength $list] > $max_lines} {
        set more [expr {[llength $list] - $max_lines + 1}]
        set list [lrange $list 0 [expr {$max_lines - 2}]]
        lappend list "... $more more lines"
    }
    return [join $list \n]
}

# The text of a source: "line 2 of proc lock" or "line 3".
proc ::ztk::priv::dbg::where {d} {
    set at "line [dict get $d line]"
    # The file of `info script` is the file of a call at the global
    # level. The line of a call in a proc counts from the body of the proc.
    if {[dict get $d proc] ne ""} {
        append at " of proc [dict get $d proc]"
    } elseif {[dict get $d file] ne ""} {
        append at " in [file tail [dict get $d file]]"
    }
    return $at
}

proc ::ztk::priv::dbg::styleText {s} {
    set t "[dict get $s sheet] ([dict get $s origin]) line [dict get $s line]: [dict get $s decl]"
    if {[dict exists $s inherited]} { set t "inherited from [dict get $s inherited], $t" }
    return $t
}

# One option: its value and the reason for it.
proc ::ztk::priv::dbg::explainOption {path opt} {
    set d [ztk::debug why $path $opt]
    set opt [dict get $d option]
    set v [short [dict get $d value]]
    set out {}
    switch -- [dict get $d source] {
        create - configure {
            lappend out "$path $opt is \"$v\": set by [short [dict get $d code]] at [where $d]."
            lappend out "Before: \"[short [dict get $d prev]]\". Writes: [dict get $d count]."
            if {[llength [dict get $d stack]]} {
                lappend out "Stack: [join [lmap f [dict get $d stack] {short $f}] { < }]"
            }
        }
        animate { lappend out "$path $opt is \"$v\": set by a step of ztk::animate." }
        internal { lappend out "$path $opt is \"$v\": the widget keeps it equal to its state." }
        variable { lappend out "$path $opt is \"$v\": the value of the variable [dict get $d variable]." }
        call {
            lappend out "$path $opt is \"$v\": a call set it while the record was off."
            lappend out "Run ztk::debug sources on before the code to get the call."
        }
        style { lappend out "$path $opt is \"$v\": from the style." }
        default { lappend out "$path $opt is \"$v\": the default. No call set it." }
    }
    if {[dict exists $d style]} {
        lappend out "Style: [styleText [dict get $d style]]"
    }
    if {[dict exists $d overrides]} {
        lappend out "The option overrides the style: [styleText [dict get $d overrides]]"
    }
    if {$opt eq "-state" && [dict get $d value] eq "disabled"} {
        lappend out "A click on $path runs no -command while it is disabled."
    }
    return $out
}

# `ztk::debug explain path ?option?`
proc ::ztk::priv::dbg::explain {path {opt ""}} {
    if {$opt ne ""} { return [lines [explainOption $path $opt]] }
    set g [lindex [ztk::debug geometry $path] 0]
    lassign [dict get $g box] x y w h
    set head "$path [dict get $g class], box $x,$y ${w}x$h"
    if {[dict exists $g manager]} {
        if {[dict get $g manager] eq ""} { append head ", no manager" } else { append head ", [dict get $g manager]" }
    }
    if {![dict get $g mapped]} { append head ", not mapped" }
    set out [list $head]
    if {[dict exists $g notes]} {
        foreach n [dict get $g notes] { lappend out "  $n" }
    }
    foreach d [ztk::debug why $path] {
        set s [dict get $d source]
        if {$s eq "style"} continue
        set line "  [dict get $d option] \"[short [dict get $d value]]\": $s"
        if {$s in {create configure}} { append line " at [where $d]" }
        if {$s eq "variable"} { append line " [dict get $d variable]" }
        lappend out $line
    }
    return [lines $out]
}

# The fields of a record after the common keys, as "key value" text.
proc ::ztk::priv::dbg::fields {r} {
    set out {}
    dict for {k v} [lrange $r 10 end] {
        if {$v eq "" || $k in {x y text by}} continue
        lappend out "$k [short $v]"
    }
    return [join $out {, }]
}

# One line for a record that a binding made.
proc ::ztk::priv::dbg::recordLine {r} {
    set w [dict get $r widget]
    switch -- [dict get $r kind] {
        event { return "event [dict get $r event] on $w" }
        binding { return "binding [dict get $r tag] [dict get $r pattern]: [short [dict get $r script]]" }
        command {
            if {[dict get $r ran]} { return "command $w: [short [dict get $r script]]" }
            return "command $w did not run: [dict get $r why]"
        }
        option {
            if {[dict get $r prev] eq [dict get $r value]} {
                set t "option $w [dict get $r option]: \"[short [dict get $r value]]\" again"
            } else {
                set t "option $w [dict get $r option]: \"[short [dict get $r prev]]\" -> \"[short [dict get $r value]]\""
            }
            if {[dict get $r line]} {
                append t " (line [dict get $r line]"
                if {[dict get $r proc] ne ""} { append t " of proc [dict get $r proc]" }
                append t ")"
            }
            return $t
        }
        dirty { return "dirty $w: [dict get $r flags]" }
        geometry {
            set moved [lmap c [dict get $r changed] {lindex $c 0}]
            return "geometry $w ([dict get $r manager]): moved [join $moved {, }]"
        }
        frame { return "frame [dict get $r frame]: redrew [join [dict get $r dirty] {, }]" }
        focus {
            set from [dict get $r from]
            set to [dict get $r to]
            return "focus [expr {$from eq {} ? {(none)} : $from}] -> [expr {$to eq {} ? {(none)} : $to}]"
        }
        grab { return "grab [dict get $r action] $w" }
    }
    return "[dict get $r kind] $w: [fields $r]"
}

# The lines for one event: the event, each record of its bindings, and
# the geometry passes and the frame after it.
proc ::ztk::priv::dbg::eventLines {e {quiet 0}} {
    set seq [dict get $e seq]
    set out [list "#$seq [dict get $e event] on [dict get $e widget] at [dict get $e x],[dict get $e y]"]
    set n 0
    foreach r [ztk::debug trace records -cause $seq] {
        if {[dict get $r seq] == $seq} continue
        lappend out "  [recordLine $r]"
        incr n
    }
    if {!$n} {
        # With `quiet`, an event that ran no binding gives no line.
        if {$quiet} { return {} }
        lappend out "  no binding ran"
    }
    return $out
}

# The geometry passes and the frames after record `seq`. With `stop`,
# only up to the next event.
proc ::ztk::priv::dbg::afterLines {seq {stop 1}} {
    set out {}
    foreach r [ztk::debug trace records -since $seq -kind {event geometry frame}] {
        if {[dict get $r kind] eq "event"} {
            if {$stop && [dict get $r cause] == 0} break
            continue
        }
        if {[dict get $r cause] != 0} continue
        lappend out "  then [recordLine $r]"
    }
    return $out
}

# `ztk::debug ran ?seq?`: what ran for the event `seq`, or for the last
# event that ran a binding.
proc ::ztk::priv::dbg::ran {{seq ""}} {
    if {$seq eq ""} {
        foreach e [lreverse [ztk::debug trace records -kind event]] {
            if {[dict get $e cause] != 0} continue
            if {[llength [ztk::debug trace records -cause [dict get $e seq] -kind {binding command}]]} {
                set seq [dict get $e seq]
                break
            }
        }
        if {$seq eq ""} {
            if {![dict get [ztk::debug trace status] on]} { return "The trace is off. Run ztk::debug trace start first." }
            return "No event ran a binding yet."
        }
    }
    set e [lindex [ztk::debug trace records -kind event -since [expr {$seq - 1}] -last 1000] 0]
    if {$e eq "" || [dict get $e seq] != $seq} { return "No event #$seq in the trace." }
    return [lines [concat [eventLines $e] [afterLines $seq]]]
}

# The center of a widget in its toplevel.
proc ::ztk::priv::dbg::center {path} {
    set row [lsearch -inline -index 0 [ztk::tree [winfo toplevel $path]] $path]
    if {$row eq ""} { error "bad window path name \"$path\"" }
    lassign [lrange $row 2 5] x y w h
    if {![lindex $row 6]} { error "$path is not mapped" }
    return [list [expr {$x + $w / 2}] [expr {$y + $h / 2}]]
}

# Runs `script` with the trace on and gives what ran for each event that
# it made. A trace that was off stops again after.
proc ::ztk::priv::dbg::traced {script} {
    set was [dict get [ztk::debug trace status] on]
    if {!$was} { ztk::debug trace start }
    set from [lindex [ztk::debug trace records -last 1] 0]
    set from [expr {$from eq "" ? 0 : [dict get $from seq]}]
    set code [catch {uplevel #0 $script} msg]
    update
    # An event whose records equal the records of the event before it
    # gives no lines of its own: one line counts these events.
    set out {}
    set last {}
    set same {}
    foreach e [ztk::debug trace records -kind event -since $from] {
        if {[dict get $e cause] != 0} continue
        set lines [eventLines $e 1]
        if {![llength $lines]} continue
        if {[llength $last] && [lrange $lines 1 end] eq [lrange $last 1 end]} {
            lappend same [dict get $e event]
            continue
        }
        if {[llength $same]} { lappend out "  the same for [llength $same] more: [short [join $same { }]]" }
        set same {}
        set out [concat $out $lines]
        set last $lines
    }
    if {[llength $same]} { lappend out "  the same for [llength $same] more: [short [join $same { }]]" }
    set out [concat $out [afterLines $from 0]]
    if {!$was} { ztk::debug trace stop }
    if {$code} { lappend out "error: $msg" }
    if {![llength $out]} { lappend out "No event reached a widget." }
    return [lines $out]
}

# `ztk::debug click path ?button?`: a click at the center of the widget,
# through the hit test, and what ran for it.
proc ::ztk::priv::dbg::click {path {button 1}} {
    update
    lassign [center $path] x y
    set top [winfo toplevel $path]
    return [traced [list apply {{top b x y} {
        ztk::inject $top motion $x $y
        ztk::inject $top press $b $x $y
        ztk::inject $top release $b $x $y
    }} $top $button $x $y]]
}

# `ztk::debug type text ?path?`: text into the widget with the focus, or
# into `path` after a click on it.
proc ::ztk::priv::dbg::type {text {path ""}} {
    update
    set top .
    set script {}
    if {$path ne ""} {
        lassign [center $path] x y
        set top [winfo toplevel $path]
        append script [list ztk::inject $top motion $x $y]\n
        append script [list ztk::inject $top press 1 $x $y]\n
        append script [list ztk::inject $top release 1 $x $y]\n
    }
    append script [list ztk::inject $top text $text]
    return [traced $script]
}

# `ztk::debug changes name ?path?`: the diff with the mark as lines.
proc ::ztk::priv::dbg::changes {name} {
    set d [ztk::debug diff $name]
    set out {}
    if {[dict exists $d size]} {
        lassign [dict get $d size] a b
        lappend out "size [join $a x] -> [join $b x]"
    }
    if {[dict get $d pixels]} {
        lassign [dict get $d box] x y w h
        lappend out "[dict get $d pixels] pixels changed in $x,$y ${w}x$h"
    } else {
        lappend out "no pixel changed"
    }
    foreach k {added removed} {
        if {[dict exists $d $k]} { lappend out "$k [join [dict get $d $k] {, }]" }
    }
    if {[dict exists $d moved]} {
        foreach m [dict get $d moved] {
            lassign $m p a b
            lappend out "moved $p [join [lrange $a 0 1] ,] [join [lrange $a 2 3] x] -> [join [lrange $b 0 1] ,] [join [lrange $b 2 3] x]"
        }
    }
    if {[dict exists $d mapped]} {
        foreach m [dict get $d mapped] {
            lassign $m p a b
            lappend out [expr {$b ? "mapped $p" : "unmapped $p"}]
        }
    }
    if {[dict exists $d options]} {
        foreach o [dict get $d options] {
            lassign $o p opt a b
            lappend out "$p $opt: \"[short $a]\" -> \"[short $b]\""
        }
    }
    return [lines $out]
}

# `ztk::debug tree ?path?`: one line for each widget.
proc ::ztk::priv::dbg::tree {{path .}} {
    update
    set out {}
    foreach row [ztk::tree $path] {
        lassign $row p cls x y w h m
        set line "$p $cls $x,$y ${w}x$h"
        if {!$m} { append line " unmapped" }
        lappend out $line
    }
    return [lines $out]
}

# ---- MCP (ztk --mcp) ----
#
# `ztk --mcp script.tcl` runs the script on the headless backend, then
# reads one JSON-RPC message from each line of stdin and writes each
# answer on one line of stdout. The script's own output goes to stderr.
# The app runs only in the calls of the tools, so each answer is the same
# for the same input.

namespace eval ::ztk::priv::dbg {
    # name, description, properties {name type description}, required names
    variable tools {
        ui_tree "The widgets: path, class, box in the toplevel, and map state, one line each." {{path string "The root of the walk (default .)"}} {}
        ui_explain "Why a widget is like this: with an option, its value and the call, the line, the stack, or the style that set it; with no option, the box, the geometry notes, and each option that a call set." {{path string "A widget path"} {option string "An option, for example -state"}} {path}
        ui_geometry "The geometry chain of a widget up to its toplevel: requested size, box, manager and its info, propagation, notes." {{path string "A widget path"}} {path}
        ui_click "Click the center of a widget through the hit test, and give what ran: events, bindings, commands, option changes, geometry, frames." {{path string "A widget path"} {button integer "The button (default 1)"}} {path}
        ui_type "Type text into the widget with the focus, or into path after a click on it, and give what ran." {{text string "The text"} {path string "A widget to click first"}} {text}
        ui_ran "What ran for the last event that ran a binding, or for the event with the number seq." {{seq integer "The number of an event record"}} {}
        ui_trace "The trace records, one line each. The trace is on from the start." {{kind string "A list of kinds: event binding command option geometry dirty frame focus grab"} {widget string "A glob pattern for the widget"} {last integer "The count of the last records (default 20)"}} {}
        ui_mark "Keep the image and the widgets of the window under a name, for ui_diff." {{name string "The name of the mark"}} {name}
        ui_diff "What changed since ui_mark: pixels with their box, added and removed widgets, moved boxes, and option changes." {{name string "The name of the mark"} {image boolean "Also give the image with the changed pixels in red"}} {name}
        ui_snapshot "A PNG image of a widget." {{path string "A widget path (default .)"}} {}
        tcl_eval "Evaluate a Tcl script at the global level of the app, then update, and give the result." {{script string "The script"}} {script}
    }
}

proc ::ztk::priv::dbg::schema {props required} {
    set ps {}
    foreach p $props {
        lassign $p name type desc
        lappend ps $name [ztcl::json object type [ztcl::json string $type] description [ztcl::json string $desc]]
    }
    return [ztcl::json object type [ztcl::json string object] properties [ztcl::json object {*}$ps] \
        required [ztcl::json array {*}[lmap r $required {ztcl::json string $r}]]]
}

proc ::ztk::priv::dbg::toolList {} {
    variable tools
    set out {}
    foreach {name desc props required} $tools {
        lappend out [ztcl::json object name [ztcl::json string $name] description [ztcl::json string $desc] inputSchema [schema $props $required]]
    }
    return [ztcl::json object tools [ztcl::json array {*}$out]]
}

proc ::ztk::priv::dbg::text {s {error 0}} {
    return [ztcl::json object content [ztcl::json array [ztcl::json object type [ztcl::json string text] text [ztcl::json string $s]]] \
        isError [ztcl::json bool $error]]
}

proc ::ztk::priv::dbg::image {b64 {caption ""}} {
    set items [list [ztcl::json object type [ztcl::json string image] data [ztcl::json string $b64] mimeType [ztcl::json string image/png]]]
    if {$caption ne ""} { lappend items [ztcl::json object type [ztcl::json string text] text [ztcl::json string $caption]] }
    return [ztcl::json object content [ztcl::json array {*}$items] isError [ztcl::json bool 0]]
}

# One argument of a call, or the default. `msg` is the JSON of the call.
proc ::ztk::priv::dbg::arg {msg name {default ""}} {
    if {[ztcl::json exists $msg params arguments $name]} { return [ztcl::json get $msg params arguments $name] }
    return $default
}

proc ::ztk::priv::dbg::call {name a} {
    switch -- $name {
        ui_tree { return [text [tree [arg $a path .]]] }
        ui_explain {
            set opt [arg $a option]
            return [text [explain [arg $a path] {*}[expr {$opt eq "" ? {} : [list $opt]}]]]
        }
        ui_geometry {
            set out {}
            foreach d [ztk::debug geometry [arg $a path]] {
                set line "[dict get $d widget] [dict get $d class] req [join [dict get $d req] x] box [join [dict get $d box] { }]"
                if {![dict get $d mapped]} { append line " unmapped" }
                if {[dict exists $d manager]} { append line " [dict get $d manager] [dict get $d info]" }
                if {[dict exists $d propagate]} { append line " propagate [dict get $d propagate]" }
                lappend out $line
                if {[dict exists $d notes]} { foreach n [dict get $d notes] { lappend out "  $n" } }
            }
            return [text [lines $out]]
        }
        ui_click { return [text [click [arg $a path] [arg $a button 1]]] }
        ui_type {
            set p [arg $a path]
            return [text [type [arg $a text] {*}[expr {$p eq "" ? {} : [list $p]}]]]
        }
        ui_ran {
            set s [arg $a seq]
            return [text [ran {*}[expr {$s eq "" ? {} : [list $s]}]]]
        }
        ui_trace {
            set f [list -last [arg $a last 20]]
            if {[arg $a kind] ne ""} { lappend f -kind [arg $a kind] }
            if {[arg $a widget] ne ""} { lappend f -widget [arg $a widget] }
            set out [lmap r [ztk::debug trace records {*}$f] {string cat "#[dict get $r seq] " [recordLine $r]}]
            if {![llength $out]} { set out [list "No records."] }
            return [text [lines $out]]
        }
        ui_mark { update; ztk::debug mark [arg $a name]; return [text "Marked [arg $a name]."] }
        ui_diff {
            set t [changes [arg $a name]]
            if {[arg $a image false]} { return [image [dict get [ztk::debug diff [arg $a name] -image] image] $t] }
            return [text $t]
        }
        ui_snapshot { update; return [image [ztk::snapshot [arg $a path .]]] }
        tcl_eval {
            set code [catch {uplevel #0 [arg $a script]} r]
            catch update
            return [text [short $r] $code]
        }
    }
    error "unknown tool \"$name\""
}

# One message: the answer as one line of JSON, or "" for a notification.
proc ::ztk::priv::dbg::mcp {line} {
    package require json
    if {[string trim $line] eq ""} { return "" }
    if {![ztcl::json valid $line]} {
        return [ztcl::json object jsonrpc [ztcl::json string 2.0] id [ztcl::json null] error [ztcl::json object code [ztcl::json number -32700] message [ztcl::json string "parse error"]]]
    }
    if {![ztcl::json exists $line id]} { return "" }
    set idv [ztcl::json get $line id]
    set id [expr {[regexp {"id"\s*:\s*"} $line] ? [ztcl::json string $idv] : [ztcl::json number $idv]}]
    set method [ztcl::json get $line method]
    set code [catch {
        switch -- $method {
            initialize {
                ztcl::json object protocolVersion [ztcl::json string 2025-06-18] \
                    capabilities [ztcl::json object tools [ztcl::json object]] \
                    serverInfo [ztcl::json object name [ztcl::json string ztk] version [ztcl::json string [info patchlevel]]]
            }
            ping { ztcl::json object }
            tools/list { toolList }
            tools/call {
                set name [ztcl::json get $line params name]
                if {[catch {call $name $line} r]} { text $r 1 } else { set r }
            }
            default { error "method not found: $method" }
        }
    } result]
    if {$code} {
        return [ztcl::json object jsonrpc [ztcl::json string 2.0] id $id error [ztcl::json object code [ztcl::json number -32601] message [ztcl::json string $result]]]
    }
    return [ztcl::json object jsonrpc [ztcl::json string 2.0] id $id result $result]
}
