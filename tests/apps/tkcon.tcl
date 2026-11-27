# Runs tkcon 2.5 (tkcon.tcl of the release) and types commands into its
# console, as a person does: a command with a result, a variable, an
# error, and a history recall with the Up key. Each check reads the text
# of the console.
# Use: ztk --headless --allow package,clock,event,env,interp tests/apps/tkcon.tcl SRC ?SHOTS?
# SRC is the folder of the tkcon release (tkcon-2.5).
# SPDX-License-Identifier: BSD-2-Clause

source [file join [file dirname [info script]] lib.tcl]
set src [lindex $argv 0]
set app::shots [lindex $argv 1]
set argv {}

app::try "tkcon starts" {
    uplevel #0 [list source [file join $src tkcon.tcl]]
    ::tkcon::Init
}
app::settle 200
set con $::tkcon::PRIV(console)
app::check [winfo exists $con] "the console text exists ($con)"
set top [winfo toplevel $con]
focus $con
app::settle

# Types a line and the Return key, and gives the new text of the console.
proc enter {line} {
    global con top
    set before [$con index end]
    app::type $top $line
    app::key $top Return
    app::settle 100
    return [$con get "$before linestart -1 line" end]
}

set out [enter {expr {6 * 7}}]
app::check [string match *42* $out] "expr gives 42 in the console: [string trim $out]"
set out [enter {set greeting hello}]
app::check [string match *hello* $out] "set gives hello"
set out [enter {nosuchcommand}]
app::check [string match {*invalid command name*} $out] "an unknown command gives an error"
app::key $top Up
app::key $top Up
app::settle
set line [$con get "end -1 line linestart" end]
app::check [string match {*set greeting hello*} $line] "Up recalls the command before: [string trim $line]"
app::shot $top tkcon
app::noErrors "tkcon"
app::done
