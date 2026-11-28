# SPDX-License-Identifier: BSD-2-Clause
#
# The entries of the command reference in Tcl (docs/dev/reference-format.md).
#
# ztcl and ztk have the same copy of this file. Each repository has its
# settings in docs/reference/_settings.tcl, and each other .tcl file of
# that folder is one entry: one command, or one ztk widget.
#
# An entry is a script in a small vocabulary of declarations: command,
# subcommand, option, argument, synopsis, summary, description, example,
# error, since, see, and the others of KEYS below. The loader runs each
# file in a safe child interpreter with no command of its own: each
# global command and each namespace is gone, and each word of the
# vocabulary is an alias to a proc of this file. A file that calls exec,
# open, source, set, or any other command fails with "invalid command
# name". selftest checks that.
#
# Subcommands:
#   lint                 checks the shape of each entry and the coverage
#                        rules: a one-sentence summary, a description,
#                        an example, and an error of each command,
#                        subcommand, and option.
#   check RUNNER ?NAME?  runs the examples and the errors with RUNNER in
#                        each Tcl release of the settings, and compares
#                        the result, the output, the message, and the
#                        -errorcode.
#   pages FILE           writes the pages of the entries as JSON: the
#                        folder, the title, the meta description, the
#                        JSON-LD, and the HTML body of each page. A link
#                        of a page is href="refdoc:TARGET", for the site
#                        build to resolve.
#   legacy FILE          writes each entry as JSON in the shape of an
#                        entry of docs/reference/AREA.txt (ztcl only).
#   convert RUNNER NAME ?-remove?
#                        writes the text entry NAME of AREA.txt as
#                        docs/reference/SLUG.tcl, and checks that each
#                        fact of the old entry is in the new file.
#   selftest             checks that a file cannot run a command.
#
# Run it with the capabilities interp, file, channels, and exec:
#   zig-out/bin/ztcl --tclsh --allow interp,file,channels,exec tools/refdoc.tcl lint
#   zig-out/bin/ztk --headless --allow interp,exec tools/refdoc.tcl lint

namespace eval refdoc {
    variable root [file dirname [file dirname [file normalize [info script]]]]
    variable folder [file join $root docs reference]

    # The words of an entry file and what each one does:
    #   block    NAME BODY: a new node, with BODY run inside it
    #   prose    one text: dedented, a paragraph is split by an empty line
    #   text     one text, as it is
    #   repeat   one text, added to a list
    #   list     one list, added to a list
    #   flag     no argument
    #   special  example, error, choice
    variable KEYS {
        command block subcommand block option block argument block
        summary prose description prose returns prose noerrors prose
        since text tcl text capability text cost text page text area text kind text setup text
        type text default text value text dbname text dbclass text
        synopsis repeat release repeat difference repeat
        see list names list flags list values list
        optional flag repeats flag
        example special error special choice special
    }
    # The keys of each kind of node. A key in REQUIRED must be there.
    variable ALLOWED
    array set ALLOWED {
        command {area kind since setup synopsis summary description returns tcl capability flags cost names page see release difference noerrors argument option example error subcommand}
        subcommand {since synopsis summary description returns tcl capability flags cost see release difference noerrors argument option example error}
        option {value type default values choice summary description since tcl see noerrors dbname dbclass example error}
        argument {type summary description default optional repeats values choice}
    }
    variable REQUIRED
    array set REQUIRED {
        command {area since synopsis summary description}
        subcommand {synopsis summary description returns}
        option {type summary description}
        argument {type summary}
    }
    # The plural name of each child list in a node.
    variable CHILD {subcommand subs option options argument args example examples error errors choice choices}

    variable N
    variable stack {}
    variable seq 0
    variable runs 0
}

# ---------------------------------------------------------------------------
# Files and text.

proc refdoc::readfile {path} {
    set fh [open $path r]
    fconfigure $fh -encoding utf-8
    set text [read $fh]
    close $fh
    return $text
}

proc refdoc::writefile {path text} {
    set fh [open $path w]
    fconfigure $fh -encoding utf-8 -translation lf
    puts -nonewline $fh $text
    close $fh
}

# The text of a block with no empty first and last lines, and with the
# indent of its least indented line removed. A text of one line stays
# as it is.
proc refdoc::dedent {text} {
    if {[string first "\n" $text] < 0} { return $text }
    set lines [split $text "\n"]
    while {[llength $lines] && [string trim [lindex $lines 0]] eq ""} { set lines [lrange $lines 1 end] }
    while {[llength $lines] && [string trim [lindex $lines end]] eq ""} { set lines [lrange $lines 0 end-1] }
    set indent -1
    foreach l $lines {
        if {[string trim $l] eq ""} continue
        set n [expr {[string length $l] - [string length [string trimleft $l " "]]}]
        if {$indent < 0 || $n < $indent} { set indent $n }
    }
    set out {}
    foreach l $lines { lappend out [string trimright [string range $l $indent end]] }
    return [join $out "\n"]
}

proc refdoc::slug {name} {
    set s [string trim [regsub -all {[^A-Za-z0-9_-]+} [string trim $name :] -] -]
    expr {$s eq "" ? "op" : $s}
}

# ---------------------------------------------------------------------------
# The loader.

proc refdoc::new {kind name} {
    variable N
    variable seq
    set id [incr seq]
    set N($id) [dict create node $kind name $name]
    return $id
}

proc refdoc::get {id key {default ""}} {
    variable N
    if {[dict exists $N($id) $key]} { return [dict get $N($id) $key] }
    return $default
}

proc refdoc::has {id key} {
    variable N
    dict exists $N($id) $key
}

proc refdoc::put {id key value} {
    variable N
    dict set N($id) $key $value
}

proc refdoc::add {id key value} {
    variable N
    dict lappend N($id) $key $value
}

# One declaration of an entry file. KEY is the word, and the stack has
# the node that the word is in.
proc refdoc::decl {key args} {
    variable KEYS
    variable ALLOWED
    variable CHILD
    variable stack
    variable doc
    set how [dict get $KEYS $key]
    if {$key eq "command"} {
        if {[llength $stack]} { error "command inside a [get [lindex $stack end] node]" }
    } else {
        if {![llength $stack]} { error "$key outside of command" }
        set id [lindex $stack end]
        set kind [get $id node]
        if {$key ni $ALLOWED($kind)} { error "$key is not a key of $kind [get $id name]" }
    }
    switch -- $how {
        block {
            if {[llength $args] != 2} { error "wrong # args: should be \"$key NAME BODY\"" }
            lassign $args name body
            set child [new $key $name]
            if {$key eq "command"} {
                variable top $child
            } else {
                add $id [dict get $CHILD $key] $child
            }
            lappend stack $child
            try {
                interp eval $doc $body
            } finally {
                set stack [lrange $stack 0 end-1]
            }
        }
        prose - text {
            if {[llength $args] != 1} { error "wrong # args: should be \"$key TEXT\"" }
            if {[has $id $key]} { error "a second $key in [get $id name]" }
            put $id $key [expr {$how eq "prose" ? [dedent [lindex $args 0]] : [lindex $args 0]}]
        }
        repeat {
            if {[llength $args] != 1} { error "wrong # args: should be \"$key TEXT\"" }
            add $id $key [lindex $args 0]
        }
        list {
            if {[llength $args] != 1} { error "wrong # args: should be \"$key LIST\"" }
            put $id $key [concat [get $id $key] [lindex $args 0]]
        }
        flag {
            if {[llength $args] != 0} { error "wrong # args: should be \"$key\"" }
            put $id $key 1
        }
        special {
            switch -- $key {
                example { set pos {code result}; set opts {-output -tcl -note} }
                error { set pos {code message errorcode}; set opts {-tcl -note} }
                choice { set pos {name summary}; set opts {-tcl} }
            }
            if {[llength $args] < [llength $pos] || ([llength $args] - [llength $pos]) % 2} {
                error "wrong # args: should be \"$key [string toupper [join $pos { }]] ?OPTION VALUE ...?\""
            }
            set item {}
            foreach p $pos v [lrange $args 0 [llength $pos]-1] {
                dict set item $p [expr {$p eq "code" ? [dedent $v] : $v}]
            }
            foreach {o v} [lrange $args [llength $pos] end] {
                if {$o ni $opts} { error "bad option \"$o\" of $key: must be [join $opts {, }]" }
                dict set item [string range $o 1 end] $v
            }
            add $id [dict get $CHILD $key] $item
        }
    }
    return
}

# A safe interpreter with only the words of the vocabulary.
proc refdoc::sandbox {} {
    variable KEYS
    set i [interp create -safe]
    interp eval $i {foreach ns [namespace children ::] {namespace delete $ns}}
    foreach c [interp eval $i {info commands}] {
        if {$c ne "rename"} { interp eval $i [list rename $c {}] }
    }
    interp eval $i {rename rename {}}
    foreach key [dict keys $KEYS] {
        interp alias $i $key {} ::refdoc::decl $key
    }
    return $i
}

# Runs one file in a sandbox. Gives the node of its command.
proc refdoc::loadfile {path} {
    variable doc
    variable top
    variable stack {}
    set top ""
    set doc [sandbox]
    try {
        interp eval $doc [readfile $path]
    } on error {msg} {
        error "[file tail $path]: $msg"
    } finally {
        interp delete $doc
    }
    if {$top eq ""} { error "[file tail $path]: no command" }
    put $top file "docs/reference/[file tail $path]"
    return $top
}

proc refdoc::settings {} {
    variable folder
    variable S
    if {[info exists S]} { return $S }
    set S [dict create prefix reference/ index_label Commands flags {} epilog {} shell {} release {}]
    set i [interp create -safe]
    interp eval $i {foreach ns [namespace children ::] {namespace delete $ns}}
    foreach c [interp eval $i {info commands}] { if {$c ne "rename"} { interp eval $i [list rename $c {}] } }
    interp eval $i {rename rename {}}
    interp alias $i setting {} ::refdoc::setting
    interp alias $i release {} ::refdoc::release
    try {
        interp eval $i [readfile [file join $folder _settings.tcl]]
    } on error {msg} {
        error "_settings.tcl: $msg"
    } finally {
        interp delete $i
    }
    if {![dict exists $S index]} { dict set S index [dict get $S prefix] }
    return $S
}

proc refdoc::setting {key value} {
    variable S
    dict set S $key $value
    return
}

proc refdoc::release {name flags} {
    variable S
    dict lappend S release [dict create name $name flags $flags]
    return
}

proc refdoc::releases {} {
    set out {}
    foreach r [dict get [settings] release] { lappend out [dict get $r name] }
    return $out
}

# The entries in the order of their area and of their file name. Each
# subcommand gets `full`, its full name. Errors in the files stop the
# run with each message.
proc refdoc::loadall {{only {}}} {
    variable folder
    set entries {}
    set problems {}
    foreach path [lsort [glob -nocomplain -directory $folder *.tcl]] {
        if {[file tail $path] eq "_settings.tcl"} continue
        if {[catch {loadfile $path} id]} {
            lappend problems $id
            continue
        }
        if {[llength $only] && [get $id name] ni $only} continue
        put $id full [get $id name]
        foreach s [get $id subs] { put $s full "[get $id name] [get $s name]" }
        lappend entries $id
    }
    set names {}
    foreach e $entries {
        if {[get $e name] in $names} { lappend problems "two entries for [get $e name]" }
        lappend names [get $e name]
    }
    if {[llength $problems]} { error [join $problems "\n"] }
    set areas [dict get [settings] areas]
    set keyed {}
    foreach e $entries {
        set a [lsearch -exact $areas [get $e area]]
        lappend keyed [list [expr {$a < 0 ? [llength $areas] : $a}] [get $e file] $e]
    }
    set out {}
    foreach k [lsort -index 0 -integer [lsort -index 1 $keyed]] { lappend out [lindex $k 2] }
    return $out
}

# ---------------------------------------------------------------------------
# lint: the shape and the coverage rules.

proc refdoc::one_sentence {text} {
    set plain [regsub -all {`[^`]*`} $text x]
    expr {[string index $plain end] eq "." && ![regexp {[.!?] +[A-Z0-9`]} [string range $plain 0 end-1]]}
}

proc refdoc::lint_node {id where} {
    variable REQUIRED
    set kind [get $id node]
    set problems {}
    foreach k $REQUIRED($kind) {
        if {![has $id $k]} { lappend problems "$where: no `$k`" }
    }
    if {[has $id summary] && ![one_sentence [get $id summary]]} {
        lappend problems "$where: the summary is not one sentence: [get $id summary]"
    }
    if {$kind in {command subcommand option}} {
        if {$kind eq "command" && ![llength [get $id subs]] && ![has $id returns]} {
            lappend problems "$where: no `returns`"
        }
        if {![llength [get $id examples]]} { lappend problems "$where: no example" }
        if {![llength [get $id errors]] && ![has $id noerrors]} { lappend problems "$where: no error, and no `noerrors`" }
        foreach key {examples errors} {
            foreach x [get $id $key] {
                if {[dict exists $x tcl] && [dict get $x tcl] ni [releases]} {
                    lappend problems "$where: a $key item of the release [dict get $x tcl]: no such release in _settings.tcl"
                }
            }
        }
    }
    if {[has $id tcl] && [get $id tcl] ni [releases]} {
        lappend problems "$where: the release [get $id tcl] is not in _settings.tcl"
    }
    variable N
    if {[string match *TODO* $N($id)]} { lappend problems "$where: TODO" }
    foreach s [get $id subs] { lappend problems {*}[lint_node $s "$where subcommand [get $s name]"] }
    foreach o [get $id options] { lappend problems {*}[lint_node $o "$where option [get $o name]"] }
    foreach a [get $id args] { lappend problems {*}[lint_node $a "$where argument [get $a name]"] }
    return $problems
}

proc refdoc::lint {} {
    set entries [loadall]
    set problems {}
    foreach e $entries {
        if {[get $e area] ni [dict get [settings] areas]} {
            lappend problems "[get $e file]: the area [get $e area] is not in _settings.tcl"
        }
        lappend problems {*}[lint_node $e [get $e file]]
    }
    if {[llength $problems]} {
        puts [join $problems "\n"]
        return 1
    }
    set subs 0
    foreach e $entries { incr subs [llength [get $e subs]] }
    puts "[llength $entries] entries, $subs subcommands, all in shape"
    return 0
}

# ---------------------------------------------------------------------------
# check: the examples and the errors, in a runner.

proc refdoc::tclword {text} {
    return "\"[string map {\\ \\\\ \" \\\" $ \\$ [ \\[ ] \\] \n \\n} $text]\""
}

# The groups of examples that run in one process: the command, then each
# subcommand with the examples of its options. Each item is
# {where kind dict}.
# An example of an option of one release runs only in that release.
proc refdoc::inherit {x o} {
    if {[has $o tcl] && ![dict exists $x tcl]} { dict set x tcl [get $o tcl] }
    return $x
}

proc refdoc::groups {e} {
    set out {}
    foreach t [list $e {*}[get $e subs]] {
        set items {}
        set where [get $t full]
        set n 0
        foreach x [get $t examples] { lappend items [list "$where example [incr n]" example $x] }
        foreach o [get $t options] {
            set n 0
            foreach x [get $o examples] { lappend items [list "$where [get $o name] example [incr n]" example [inherit $x $o]] }
        }
        set n 0
        foreach x [get $t errors] { lappend items [list "$where error [incr n]" error $x] }
        foreach o [get $t options] {
            set n 0
            foreach x [get $o errors] { lappend items [list "$where [get $o name] error [incr n]" error [inherit $x $o]] }
        }
        set tcl [get $t tcl [get $e tcl]]
        set flags [concat [get $e flags] [expr {$t eq $e ? {} : [get $t flags]}]]
        lappend out [list $where $tcl $flags $items]
    }
    return $out
}

proc refdoc::run {runner flags release items {setup {}}} {
    # The setup of the entry, such as `package require`, runs first.
    set script "$setup\n"
    foreach item $items {
        append script "puts -nonewline \"\\x1d\"\n"
        append script "set ::__s [tclword [dict get [lindex $item 2] code]]\n"
        append script "set ::__c \[catch {uplevel #0 \$::__s} ::__v ::__o\]\n"
        append script "puts -nonewline \"\\x1f\$::__c\\x1f\$::__v\\x1f\[expr {\[dict exists \$::__o -errorcode\] ? \[dict get \$::__o -errorcode\] : {}}\]\\x1e\"\n"
    }
    append script [dict get [settings] epilog] "\n"
    # Each run has a new empty folder of zig-out/ as its working folder, so
    # an example that makes files, also with `--root .`, makes them there.
    variable root
    variable runs
    # On Windows a program that an example started, such as a shell of
    # ztcl::pty, can hold its folder for a moment after the runner ends,
    # so a folder that cannot be deleted stays, and the run uses the next one.
    set dir [file join $root zig-out refdoc-run [incr runs]]
    while {[catch {file delete -force $dir}]} {
        set dir [file join $root zig-out refdoc-run [incr runs]]
    }
    file mkdir $dir
    set path [file join $dir examples.tcl]
    writefile $path $script
    set args [concat [dict get [settings] flags] [dict get $release flags] $flags [list $path]]
    set here [pwd]
    cd $dir
    try {
        catch {exec -ignorestderr -- $runner {*}$args} out
    } finally {
        cd $here
        catch {file delete -force $dir}
    }
    set got {}
    foreach chunk [lrange [split $out "\x1d"] 1 end] {
        if {[regexp {^(.*)\x1f(\d+)\x1f(.*)\x1f(.*)\x1e} $chunk -> o c v ec]} {
            lappend got [list $o $c $v $ec]
        } else {
            lappend got {}
        }
    }
    return [list $out $got]
}

proc refdoc::check {runner {only {}}} {
    set entries [loadall $only]
    set rels [dict get [settings] release]
    if {![llength $rels]} { set rels [list [dict create name {} flags {}]] }
    set count 0
    set fails {}
    foreach e $entries {
        foreach group [groups $e] {
            lassign $group label tcl flags items
            foreach r $rels {
                set rel [dict get $r name]
                if {$tcl ne "" && $rel ne "" && $tcl ne $rel} continue
                set run {}
                foreach item $items {
                    set x [lindex $item 2]
                    if {$rel eq "" || ![dict exists $x tcl] || [dict get $x tcl] eq $rel} { lappend run $item }
                }
                if {![llength $run]} continue
                lassign [run $runner $flags $r $run [get $e setup]] out got
                set tag [expr {$rel eq "" ? "" : " (Tcl $rel)"}]
                if {[llength $got] != [llength $run]} {
                    lappend fails "[get $e file]: $label$tag: [llength $got] of [llength $run] examples ran: [string trim $out]"
                    continue
                }
                foreach item $run g $got {
                    lassign $item where kind x
                    incr count
                    if {![llength $g]} {
                        lappend fails "[get $e file]: $where$tag: no record"
                        continue
                    }
                    lassign $g output code value ecode
                    set c [dict get $x code]
                    if {$kind eq "example"} {
                        set want [dict get $x result]
                        set wout [expr {[dict exists $x output] ? [dict get $x output] : ""}]
                        if {$code ne "0"} {
                            lappend fails "[get $e file]: $where$tag: [list $c] gave the error [list $value]"
                        } elseif {$value ne $want} {
                            lappend fails "[get $e file]: $where$tag: [list $c] gave [list $value], want [list $want]"
                        } elseif {$output ne $wout} {
                            lappend fails "[get $e file]: $where$tag: [list $c] printed [list $output], want [list $wout]"
                        }
                    } else {
                        if {$code ne "1"} {
                            lappend fails "[get $e file]: $where$tag: [list $c] gave no error: [list $value]"
                        } elseif {$value ne [dict get $x message]} {
                            lappend fails "[get $e file]: $where$tag: [list $c] gave the message [list $value], want [list [dict get $x message]]"
                        } elseif {$ecode ne [dict get $x errorcode]} {
                            lappend fails "[get $e file]: $where$tag: [list $c] gave -errorcode [list $ecode], want [list [dict get $x errorcode]]"
                        }
                    }
                }
            }
        }
    }
    foreach f $fails { puts "FAIL $f" }
    puts "$count examples and errors, [expr {[llength $fails] ? [llength $fails] : "no"}] failures"
    return [expr {[llength $fails] ? 1 : 0}]
}

# ---------------------------------------------------------------------------
# JSON.

proc refdoc::jstr {s} {
    variable JMAP
    if {![info exists JMAP]} {
        set JMAP [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t]
        for {set c 0} {$c < 32} {incr c} {
            if {$c in {9 10 13}} continue
            lappend JMAP [format %c $c] [format \\u%04x $c]
        }
    }
    return "\"[string map $JMAP $s]\""
}

proc refdoc::jobj {args} {
    set out {}
    foreach {k v} $args { lappend out "[jstr $k]: $v" }
    return "{[join $out {, }]}"
}

proc refdoc::jlist {items} {
    return "\[[join $items {, }]\]"
}

proc refdoc::jstrs {items} {
    set out {}
    foreach i $items { lappend out [jstr $i] }
    return [jlist $out]
}

# ---------------------------------------------------------------------------
# The pages.

proc refdoc::esc {s} {
    string map {& &amp; < &lt; > &gt; \" &quot; ' &#x27;} $s
}

# A link target of the text as an href that the site build resolves.
proc refdoc::href {target} {
    return "refdoc:[esc $target]"
}

# The HTML of one paragraph: `code`, *emphasis*, and [text](target).
proc refdoc::inline {text} {
    set out {}
    set pos 0
    set re {`([^`]+)`|\[([^\]]+)\]\(([^)\s]+)\)|\*([^*\s][^*]*)\*}
    while {[regexp -indices -start $pos $re $text all code ltext ltarget em]} {
        lassign $all s e
        append out [esc [string range $text $pos $s-1]]
        if {[lindex $code 0] >= 0} {
            append out "<code>[esc [string range $text {*}$code]]</code>"
        } elseif {[lindex $ltext 0] >= 0} {
            append out "<a href=\"[href [string range $text {*}$ltarget]]\">[inline [string range $text {*}$ltext]]</a>"
        } else {
            append out "<em>[esc [string range $text {*}$em]]</em>"
        }
        set pos [expr {$e + 1}]
    }
    append out [esc [string range $text $pos end]]
    return $out
}

# The HTML of a text: paragraphs split by an empty line, and lists with
# a line `- ` for each item.
proc refdoc::blocks {text} {
    set out {}
    set paras [split [string map [list "\n\n" "\x00"] [regsub -all {\n[ \t]*\n} [string trim $text] "\n\n"]] "\x00"]
    foreach para $paras {
        set lines [split [string trim $para] "\n"]
        if {[string match "- *" [lindex $lines 0]]} {
            set items {}
            set cur {}
            foreach l $lines {
                if {[string match "- *" $l] && [llength $cur]} {
                    lappend items [join $cur " "]
                    set cur {}
                }
                lappend cur [expr {[string match "- *" $l] ? [string range $l 2 end] : [string trim $l]}]
            }
            lappend items [join $cur " "]
            set lis {}
            foreach i $items { append lis "<li>[inline $i]</li>" }
            lappend out "<ul>$lis</ul>"
        } else {
            set words {}
            foreach l $lines { lappend words [string trim $l] }
            lappend out "<p>[inline [join $words " "]]</p>"
        }
    }
    return [join $out "\n"]
}

proc refdoc::plain {text} {
    set text [regsub -all {\[([^\]]+)\]\([^)]+\)} $text {\1}]
    set text [string map {` "" * ""} $text]
    return [join [regexp -all -inline {\S+} $text] " "]
}

# A synopsis line: the words in capitals are placeholders.
proc refdoc::synopsis_html {line} {
    set out {}
    set pos 0
    while {[regexp -indices -start $pos {[A-Z][A-Z0-9_]*} $line m]} {
        lassign $m s e
        append out [esc [string range $line $pos $s-1]] "<var>[esc [string range $line $s $e]]</var>"
        set pos [expr {$e + 1}]
    }
    append out [esc [string range $line $pos end]]
    return $out
}

proc refdoc::tag {tcl} {
    expr {$tcl eq "" ? "" : "<span class=\"ref-tag\">Tcl [esc $tcl] only</span>"}
}

# One example as lines of a session of the shell: a comment with its
# release and its note, the command after a prompt, the output, and the
# result or the error with its -errorcode. On a site with a shell, the
# command of an example of the release of the shell is a Run link
# (class zrun of docs/site/shell.js): a click runs it in the shell.
proc refdoc::session {x kind} {
    set out {}
    if {[dict exists $x tcl]} { append out "<span class=\"ref-c\"># Tcl [esc [dict get $x tcl]] only</span>\n" }
    if {[dict exists $x note]} { append out "<span class=\"ref-c\"># [esc [dict get $x note]]</span>\n" }
    set code [string trimright [dict get $x code] "\n"]
    set lines {}
    set i 0
    foreach l [split $code "\n"] {
        lappend lines "<span class=\"ref-p\">[expr {[incr i] == 1 ? "%" : ">"}] </span>[esc $l]"
    }
    set html [join $lines "\n"]
    set shell [dict get [settings] shell]
    if {$shell ne "" && (![dict exists $x tcl] || [dict get $x tcl] eq $shell)} {
        set html "<span class=\"zrun ref-run\" role=\"button\" tabindex=\"0\" data-cmd=\"[esc $code]\" aria-label=\"Run in the shell: [esc $code]\">$html</span>"
    }
    append out $html "\n"
    if {[dict exists $x output]} { append out [esc [dict get $x output]] }
    if {$kind eq "example"} {
        set r [dict get $x result]
        append out [esc $r] [expr {$r eq "" ? "" : "\n"}]
    } else {
        append out "<span class=\"ref-err\">[esc [dict get $x message]]</span>\n"
        append out "<span class=\"ref-ec\">-errorcode [esc [dict get $x errorcode]]</span>\n"
    }
    return $out
}

proc refdoc::examples_html {items kind} {
    if {![llength $items]} { return "" }
    set parts {}
    foreach x $items { lappend parts [session $x $kind] }
    set cls [expr {$kind eq "error" ? "ref-ex ref-ex-err" : "ref-ex"}]
    return "<pre class=\"$cls\"><code>[string trimright [join $parts "\n"] "\n"]</code></pre>"
}

proc refdoc::values_html {id} {
    set out {}
    if {[llength [get $id values]]} {
        set vs {}
        foreach v [get $id values] { lappend vs "<code>[esc $v]</code>" }
        append out "<p>Values: [join $vs {, }].</p>"
    }
    if {[llength [get $id choices]]} {
        set rows {}
        foreach c [get $id choices] {
            set t [expr {[dict exists $c tcl] ? " [tag [dict get $c tcl]]" : ""}]
            append rows "<tr><td><code>[esc [dict get $c name]]</code></td><td>[inline [dict get $c summary]]$t</td></tr>"
        }
        append out "<div class=\"table\"><table><thead><tr><th>Value</th><th>Meaning</th></tr></thead><tbody>$rows</tbody></table></div>"
    }
    return $out
}

proc refdoc::default_html {id missing} {
    if {![has $id default]} { return $missing }
    set d [get $id default]
    expr {$d eq "" ? "empty" : "<code>[esc $d]</code>"}
}

proc refdoc::arguments_html {t} {
    set args [get $t args]
    if {![llength $args]} { return "" }
    set rows {}
    foreach a $args {
        set text [inline [get $a summary]]
        if {[has $a description]} { append text " " [inline [get $a description]] }
        set d [default_html $a [expr {[has $a optional] ? "none" : "required"}]]
        append rows "<tr id=\"arg-[string tolower [slug [get $a name]]]\"><td><var>[esc [get $a name]]</var></td><td>[esc [get $a type]]</td><td>$d</td><td>$text[values_html $a]</td></tr>"
    }
    return "<h2 id=\"arguments\">Arguments</h2><div class=\"table\"><table class=\"ref-args\"><thead><tr><th>Argument</th><th>Type</th><th>Default</th><th>Description</th></tr></thead><tbody>$rows</tbody></table></div>"
}

# The table of the options, and a section for each option with its
# anchor (#-nocase), its description, its examples, and its errors.
proc refdoc::options_html {t widget} {
    set opts [get $t options]
    if {![llength $opts]} { return "" }
    set db $widget
    foreach o $opts { if {[has $o dbname]} { set db 1 } }
    set head "<th>Option</th><th>Type</th><th>Default</th>[expr {$db ? "<th>Database name</th>" : ""}]<th>Summary</th>"
    set rows {}
    set parts {}
    foreach o $opts {
        set name [get $o name]
        set t [tag [get $o tcl]]
        set t [expr {$t eq "" ? "" : " $t"}]
        set dbcell [expr {$db ? "<td>[esc [get $o dbname]]</td>" : ""}]
        append rows "<tr><td><a href=\"#[esc $name]\"><code>[esc $name]</code></a></td><td>[esc [get $o type]]</td><td>[default_html $o none]</td>$dbcell<td>[inline [get $o summary]]$t</td></tr>"
        set value [expr {[has $o value] ? " [esc [get $o value]]" : ""}]
        set body "<h3 id=\"[esc $name]\"><code>[esc $name]$value</code>$t</h3>"
        append body "<p class=\"ref-lead\">[inline [get $o summary]]</p>" [blocks [get $o description]] [values_html $o]
        append body [examples_html [get $o examples] example] [examples_html [get $o errors] error]
        if {![llength [get $o errors]] && [has $o noerrors]} { append body [blocks [get $o noerrors]] }
        if {[llength [get $o see]]} {
            set links {}
            foreach s [get $o see] { lappend links "<a href=\"[href cmd:$s]\"><code>[esc $s]</code></a>" }
            append body "<p>See also: [join $links {, }].</p>"
        }
        append parts "<section class=\"ref-opt\">$body</section>"
    }
    return "<h2 id=\"options\">Options</h2><div class=\"table\"><table class=\"ref-opts\"><thead><tr>$head</tr></thead><tbody>$rows</tbody></table></div>$parts"
}

proc refdoc::facts_html {t e} {
    set cfg [settings]
    set rows {}
    set cap [get $t capability [get $e capability]]
    lappend rows Capability [expr {$cap ne "" ? "<code>[esc $cap]</code>. A new interpreter does not have it until the host turns it on." : "None."}]
    set tcl [get $t tcl [get $e tcl]]
    if {[llength [releases]]} {
        lappend rows "Tcl release" [expr {$tcl ne "" ? "Tcl [esc $tcl] only." : "Tcl [join [releases] { and }]."}]
    }
    lappend rows Since "[esc [dict get $cfg product]] [esc [get $t since [get $e since]]]"
    set cost [get $t cost [get $e cost]]
    if {$cost ne ""} { lappend rows "Compute cost" [inline $cost] }
    set out {}
    foreach {k v} $rows { append out "<dt>$k</dt><dd>$v</dd>" }
    return "<dl class=\"ref-facts\">$out</dl>"
}

proc refdoc::list_section {title anchor items} {
    if {![llength $items]} { return "" }
    set lis {}
    foreach i $items { append lis "<li>[inline $i]</li>" }
    return "<h2 id=\"$anchor\">$title</h2><ul>$lis</ul>"
}

proc refdoc::jsonld {url title desc crumbs} {
    set cfg [settings]
    set items {}
    set n 0
    foreach {name u} $crumbs {
        lappend items [jobj @type [jstr ListItem] position [incr n] name [jstr $name] item [jstr $u]]
    }
    set article [jobj @type [jstr TechArticle] headline [jstr $title] description [jstr $desc] url [jstr $url] inLanguage [jstr en] \
        isPartOf [jobj @type [jstr WebSite] name [jstr [dict get $cfg product]] url [jstr [dict get $cfg site]]] \
        about [jobj @type [jstr SoftwareSourceCode] name [jstr [dict get $cfg product]] codeRepository [jstr [dict get $cfg repo]] programmingLanguage [jstr Tcl]]]
    set data [jobj @context [jstr https://schema.org] @graph [jlist [list $article [jobj @type [jstr BreadcrumbList] itemListElement [jlist $items]]]]]
    return "<script type=\"application/ld+json\">[string map {</ <\\/} $data]</script>"
}

# The pages of the entries as a JSON list: page (the folder from the
# root of the site), title, description, head, and body.
proc refdoc::pages {} {
    set cfg [settings]
    set prefix [dict get $cfg prefix]
    set index [dict get $cfg index]
    set label [dict get $cfg index_label]
    set site [dict get $cfg site]
    set out {}
    foreach e [loadall] {
        set top "$prefix[slug [get $e name]]/"
        set kind [get $e kind command]
        foreach t [list $e {*}[get $e subs]] {
            set sub [expr {$t ne $e}]
            set page [expr {$sub ? "$top[slug [get $t name]]/" : $top}]
            set title [get $t full]
            set desc [plain [get $t summary]]
            set crumbs [list $label $site$index [get $e name] $site$top]
            if {$sub} { lappend crumbs $title $site$page }
            set nav "<nav class=\"ref-crumbs\" aria-label=\"Breadcrumb\"><a href=\"[href $index]\">[esc $label]</a>"
            if {$sub} { append nav " <span aria-hidden=\"true\">/</span> <a href=\"../\">[esc [get $e name]]</a>" }
            append nav "</nav>"
            set tags [tag [get $t tcl]]
            if {[has $t capability]} { append tags "<span class=\"ref-tag ref-cap\">[esc [get $t capability]]</span>" }
            set syn {}
            foreach l [get $t synopsis] { lappend syn [synopsis_html $l] }
            set body [list $nav "<h1><code>[esc $title]</code>$tags</h1>" \
                "<p class=\"ref-lead\">[inline [get $t summary]]</p>" \
                "<pre class=\"ref-syn\"><code>[join $syn "\n"]</code></pre>" \
                "<h2 id=\"description\">Description</h2>" [blocks [get $t description]]]
            if {!$sub && [llength [get $e subs]]} {
                set rows {}
                foreach x [get $e subs] {
                    set tg [tag [get $x tcl]]
                    append rows "<tr><td><a href=\"[slug [get $x name]]/\"><code>[esc [get $x full]]</code></a></td><td>[inline [get $x summary]][expr {$tg eq "" ? "" : " $tg"}]</td></tr>"
                }
                set heading [expr {$kind eq "widget" ? "Widget commands" : "Subcommands"}]
                set col [expr {$kind eq "widget" ? "Command" : "Subcommand"}]
                lappend body "<h2 id=\"subcommands\">$heading</h2><div class=\"table\"><table class=\"ref-subs\"><thead><tr><th>$col</th><th>Summary</th></tr></thead><tbody>$rows</tbody></table></div>"
            }
            lappend body [arguments_html $t] [options_html $t [expr {$kind eq "widget" && !$sub}]]
            if {[has $t returns]} { lappend body "<h2 id=\"returns\">Returns</h2>[blocks [get $t returns]]" }
            set pre [expr {[has $e setup] ? "<p class=\"ref-setup\">Each example of this page runs after <code>[esc [get $e setup]]</code>.</p>" : ""}]
            if {[llength [get $t examples]]} { lappend body "<h2 id=\"examples\">Examples</h2>$pre[examples_html [get $t examples] example]" }
            if {[llength [get $t errors]]} {
                lappend body "<h2 id=\"errors\">Errors</h2>[examples_html [get $t errors] error]"
            } elseif {[has $t noerrors]} {
                lappend body "<h2 id=\"errors\">Errors</h2>[blocks [get $t noerrors]]"
            }
            lappend body [list_section "Tcl 8.6 and Tcl 9.1" releases [get $t release]]
            lappend body [list_section "Differences from Tcl" differences [get $t difference]]
            lappend body "<h2 id=\"facts\">Facts</h2>[facts_html $t $e]"
            if {!$sub && [has $e page]} {
                lappend body "<p>The full page: <a href=\"[href [get $e page]]\">[esc [get $e name]]</a>.</p>"
            }
            if {[llength [get $t see]]} {
                set lis {}
                foreach s [get $t see] { append lis "<li><a href=\"[href cmd:$s]\"><code>[esc $s]</code></a></li>" }
                lappend body "<h2 id=\"see-also\">See also</h2><ul class=\"ref-see\">$lis</ul>"
            }
            set parts {}
            foreach b $body { if {$b ne ""} { lappend parts $b } }
            lappend out [jobj page [jstr $page] title [jstr $title] description [jstr $desc] \
                head [jstr [jsonld $site$page $title $desc $crumbs]] body [jstr [join $parts "\n"]]]
        }
    }
    return [jlist $out]
}

# ---------------------------------------------------------------------------
# legacy: the shape of tools/reference.py (ztcl).

proc refdoc::legacy {} {
    set out {}
    foreach e [loadall] {
        set subs {}
        foreach s [get $e subs] {
            set tail [expr {[has $s tcl] ? " Tcl [get $s tcl] only." : ""}]
            set first [split [lindex [get $s synopsis] 0]]
            foreach syn [get $s synopsis] {
                # A form with an option of its own gets the summary of that
                # option: `string length -grapheme STRING`.
                set summary [get $s summary]
                foreach o [get $s options] {
                    if {[get $o name] in [split $syn] && [get $o name] ni $first} {
                        set summary [get $o summary]
                        break
                    }
                }
                lappend subs "$syn | $summary$tail"
            }
        }
        set opts {}
        foreach o [get $e options] {
            lappend opts "[get $o name][expr {[has $o value] ? " [get $o value]" : ""}] | [get $o summary]"
        }
        set ex {}
        set err {}
        foreach t [list $e {*}[get $e subs]] {
            foreach x [get $t examples] {
                if {[string first "\n" [dict get $x code]] < 0 && ![dict exists $x output] && ![dict exists $x tcl]} {
                    lappend ex "[dict get $x code] => [dict get $x result]"
                }
            }
            foreach x [get $t errors] {
                if {[string first "\n" [dict get $x code]] < 0 && ![dict exists $x tcl]} {
                    lappend err "[dict get $x code] | [dict get $x message]"
                }
            }
        }
        set fields [list name [jstr [get $e name]] area [jstr [get $e area]] file [jstr [get $e file]] \
            syn [jstrs [get $e synopsis]] does [jstr [get $e summary]]]
        foreach {k v} [list sub $subs opt $opts ex $ex err $err diff [get $e difference]] {
            if {[llength $v]} { lappend fields $k [jstrs $v] }
        }
        foreach {k key} {cap capability cost cost page page tcl tcl} {
            if {[has $e $key]} { lappend fields $k [jstr [get $e $key]] }
        }
        if {[llength [get $e flags]]} { lappend fields flags [jstr [join [get $e flags]]] }
        if {[llength [get $e names]]} { lappend fields names [jstrs [list [join [get $e names]]]] }
        lappend out [jobj {*}$fields]
    }
    return [jlist $out]
}

# ---------------------------------------------------------------------------
# convert: a text entry of docs/reference/AREA.txt to SLUG.tcl.

# A word of a .tcl entry for one text: in braces when the text reads the
# same there, else in quotes with escapes.
proc refdoc::word {text} {
    if {[regexp {^[A-Za-z0-9_.:/%+=,@-]+$} $text]} { return $text }
    if {$text ne "" && [info complete "list {$text}"] && ![regexp {\\|\n|^\s|\s$|[\x00-\x1f]} $text]} {
        return "{$text}"
    }
    if {$text eq ""} { return "{}" }
    set out [string map {\\ \\\\ \" \\\" $ \\$ [ \\[ ] \\] \{ \\\{ \} \\\} \n \\n \t \\t} $text]
    return "\"$out\""
}

# A block of prose or code: in braces when it reads the same there, and
# indented when it has more than one line.
proc refdoc::para {text indent} {
    if {![info complete "list {$text}"] || [string match {*\\} $text] || [string first "\\\n" $text] >= 0} {
        return [word $text]
    }
    if {[string first "\n" $text] < 0} { return "{$text}" }
    set pad [string repeat " " [expr {$indent + 4}]]
    set lines {}
    foreach l [split $text "\n"] { lappend lines [expr {$l eq "" ? "" : "$pad$l"}] }
    return "{\n[join $lines "\n"]\n[string repeat " " $indent]}"
}

# The first sentence of a text: up to the first period, question mark,
# or exclamation mark that has a space and a capital letter or a
# backtick after it.
proc refdoc::first_sentence {text} {
    if {[regexp -indices {[.!?] [A-Z`]} $text m]} {
        return [string range $text 0 [lindex $m 0]]
    }
    return $text
}

proc refdoc::split_sub {line} {
    set i [string first " | " $line]
    if {$i < 0} { return [list [string trim $line] ""] }
    return [list [string trim [string range $line 0 $i-1]] [string trim [string range $line $i+3 end]]]
}

# The entries of the text files: each a dict of key and a list of values.
proc refdoc::text_entries {} {
    variable folder
    set out {}
    foreach path [lsort [glob -nocomplain -directory $folder *.txt]] {
        set n 0
        set cur ""
        foreach line [split [readfile $path] "\n"] {
            incr n
            if {[string trim $line] eq "" || [string match "#*" $line]} continue
            if {[string match "== *" $line]} {
                if {$cur ne ""} { lappend out $cur }
                set cur [dict create name [string trim [string range $line 3 end]] file $path line $n area [file rootname [file tail $path]]]
                continue
            }
            set i [string first ": " $line]
            if {$i < 0 || $cur eq ""} { error "[file tail $path]:$n: a line is not `key: value`" }
            dict lappend cur [string range $line 0 $i-1] [string trim [string range $line $i+2 end]]
        }
        if {$cur ne ""} { lappend out $cur }
    }
    return $out
}

proc refdoc::convert {runner name {remove 0}} {
    variable folder
    set e ""
    foreach x [text_entries] { if {[dict get $x name] eq $name} { set e $x } }
    if {$e eq ""} { puts "no entry $name in docs/reference/*.txt"; return 1 }
    set v [lambda1 $e]
    set out [list "# Converted by tools/refdoc.tcl convert from [file tail [dict get $e file]]." ""]
    lappend out "command [word $name] \{"
    set does [lindex [{*}$v does] 0]
    lappend out "    area [word [dict get $e area]]" "    since TODO"
    foreach s [{*}$v syn] { lappend out "    synopsis [word $s]" }
    lappend out "    summary [word [first_sentence $does]]" "    description [para $does 4]"
    foreach {k key} {tcl tcl cap capability cost cost page page} {
        foreach x [{*}$v $k] { lappend out "    $key [para $x 4]" }
    }
    foreach x [{*}$v flags] { lappend out "    flags [word $x]" }
    foreach x [{*}$v names] { lappend out "    names [word $x]" }
    foreach x [{*}$v diff] { lappend out "    difference [para $x 4]" }
    foreach o [{*}$v opt] {
        lassign [split_sub $o] flag text
        set value [join [lrange [split $flag] 1 end]]
        lappend out "    option [word [lindex [split $flag] 0]] \{"
        if {$value ne ""} { lappend out "        value [word $value]" }
        lappend out "        type TODO" "        summary [word [first_sentence $text]]" "        description [para $text 8]" "    \}"
    }
    foreach x [{*}$v ex] {
        if {[regexp {^(.*?) =>(?: (.*))?$} $x -> code result]} {
            lappend out "    example [para [string trim $code] 4] [word $result]"
        } else {
            lappend out "    example [para [string trim $x] 4] TODO"
        }
    }
    set rel [lindex [concat [{*}$v tcl] [releases]] 0]
    set flags [split [join [{*}$v flags]]]
    foreach x [{*}$v err] {
        lassign [split_sub $x] code msg
        set r [lindex [dict get [settings] release] [lsearch -exact [releases] $rel]]
        if {$r eq ""} { set r [dict create name {} flags {}] }
        set g [lindex [lindex [run $runner $flags $r [list [list "" error [dict create code $code]]]] 1] 0]
        lappend out "    error [para $code 4] [word $msg] [word [lindex $g 3]]"
    }
    set groups {}
    foreach line [{*}$v sub] {
        lassign [split_sub $line] syn text
        set words [split $syn]
        # A subcommand of a module has no command name in front.
        set key [expr {[llength $words] > 1 && [lindex $words 0] eq $name ? [lindex $words 1] : [lindex $words 0]}]
        dict lappend groups $key [list $syn $text]
    }
    dict for {key lines} $groups {
        lappend out "    subcommand [word $key] \{"
        set texts {}
        set tcl ""
        set n 0
        foreach l $lines {
            lassign $l syn text
            lappend out "        synopsis [word $syn]"
            if {[regexp {^(.*?)\s*Tcl (9\.1|8\.6) only\.$} $text -> text tcl]} {}
            lappend texts [expr {[incr n] == 1 ? $text : "`$syn`: $text"}]
        }
        lappend out "        summary [word [first_sentence [lindex $texts 0]]]"
        lappend out "        description [para [join $texts "\n\n"] 8]"
        if {$tcl ne ""} { lappend out "        tcl [word $tcl]" }
        lappend out "    \}"
    }
    lappend out "\}"
    set path [file join $folder "[slug $name].tcl"]
    writefile $path "[join $out "\n"]\n"
    # Each text of the old entry must be in the new one.
    set id [loadfile $path]
    set have [join [texts $id] "\n"]
    set lost {}
    dict for {k vals} $e {
        if {$k in {name file line area}} continue
        foreach val $vals {
            if {$k eq "opt"} {
                # The flag and the placeholder of its value are two words.
                lassign [split_sub $val] flag text
                set parts [list {*}[split $flag] $text]
            } elseif {$k in {sub err}} {
                set parts [split_sub $val]
            } elseif {$k eq "ex"} {
                if {![regexp {^(.*?) =>(?: (.*))?$} $val -> c r]} { set c $val; set r "" }
                set parts [list [string trim $c] $r]
            } else {
                set parts [list $val]
            }
            foreach p $parts {
                set p [regsub {\s*Tcl (9\.1|8\.6) only\.$} $p ""]
                foreach w [expr {$k in {flags names} ? [split $p] : [list $p]}] {
                    if {$w ne "" && [string first $w $have] < 0} { lappend lost $w }
                }
            }
        }
    }
    foreach l $lost { puts "LOST: $l" }
    if {[llength $lost]} { return 1 }
    puts "wrote docs/reference/[file tail $path]: each fact of the old entry is in it"
    if {$remove} {
        set src [dict get $e file]
        set lines [split [readfile $src] "\n"]
        set start [expr {[dict get $e line] - 1}]
        set end [expr {$start + 1}]
        while {$end < [llength $lines] && ![string match "== *" [lindex $lines $end]]} { incr end }
        while {$end > $start + 1 && [string trim [lindex $lines $end-1]] eq ""} { incr end -1 }
        set lines [lreplace $lines $start $end-1]
        while {$start > 0 && $start < [llength $lines] && [string trim [lindex $lines $start]] eq "" && [string trim [lindex $lines $start-1]] eq ""} {
            set lines [lreplace $lines $start $start]
        }
        writefile $src [join $lines "\n"]
        puts "removed $name from [file tail $src]"
    }
    return 0
}

# Each text of a node and of the nodes in it, one item for each value.
proc refdoc::texts {id} {
    variable N
    set out {}
    dict for {k v} $N($id) {
        switch -- $k {
            subs - options - args { foreach c $v { lappend out {*}[texts $c] } }
            examples - errors - choices { foreach x $v { lappend out {*}[dict values $x] } }
            synopsis - release - difference - see - names - flags - values { lappend out {*}$v }
            default { lappend out $v }
        }
    }
    return $out
}

# The values of one key of a text entry, or an empty list.
proc refdoc::lambda1 {e} {
    return [list apply {{e k} { expr {[dict exists $e $k] ? [dict get $e $k] : {}} }} $e]
}

# ---------------------------------------------------------------------------
# selftest: a file of an entry cannot run a command.

proc refdoc::selftest {} {
    variable root
    file mkdir [file join $root zig-out]
    set path [file join $root zig-out refdoc-selftest.tcl]
    set fails 0
    set bad {
        exec {command x { summary [exec cmd.exe /c echo hi] }}
        open {command x { summary [open secret.txt] }}
        source {source evil.tcl}
        set {set x 1}
        puts {puts hi}
        namespace {::tcl::mathfunc::abs -1}
        nested {command x { subcommand y { description [file delete x] } }}
    }
    foreach {what script} $bad {
        writefile $path $script
        variable N
        if {[catch {loadfile $path} msg]} {
            if {[string match "*invalid command name*" $msg]} {
                puts "ok a file that calls $what fails: $msg"
            } else {
                puts "FAIL a file that calls $what fails with another error: $msg"
                incr fails
            }
        } else {
            puts "FAIL a file that calls $what loads"
            incr fails
        }
        file delete $path
    }
    writefile $path {command x { summary {A command.}; example {x} {} }}
    if {[catch {loadfile $path} id]} {
        puts "FAIL a file of declarations does not load: $id"
        incr fails
    } else {
        puts "ok a file of declarations loads"
    }
    file delete $path
    return [expr {$fails ? 1 : 0}]
}

# ---------------------------------------------------------------------------

proc refdoc::main {argv} {
    set usage "usage: refdoc.tcl lint | check RUNNER ?NAME ...? | pages FILE | legacy FILE | convert RUNNER NAME ?-remove? | selftest"
    set args [lrange $argv 1 end]
    switch -- [lindex $argv 0] {
        lint { return [lint] }
        check {
            if {![llength $args]} { puts $usage; return 2 }
            return [check [file normalize [lindex $args 0]] [lrange $args 1 end]]
        }
        pages - legacy {
            if {[llength $args] != 1} { puts $usage; return 2 }
            writefile [lindex $args 0] [[lindex $argv 0]]
            return 0
        }
        convert {
            if {[llength $args] < 2} { puts $usage; return 2 }
            return [convert [file normalize [lindex $args 0]] [lindex $args 1] [expr {"-remove" in $args}]]
        }
        selftest { return [selftest] }
        default { puts $usage; return 2 }
    }
}

if {[catch {refdoc::main $argv} code]} {
    puts "error: $code"
    exit 1
}
exit $code
