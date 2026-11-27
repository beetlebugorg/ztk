# The input test of tests/wayland-input.sh. An entry with the focus gets
# the keys, and a line on stdout reports each change of the text, the
# size, the scale, and the clipboard. A file of commands from the test
# sets the clipboard and ends the script. The script ends after 30
# seconds without a command.
# SPDX-License-Identifier: BSD-2-Clause
set cmdfile [lindex $argv 0]
entry .e -width 30
pack .e -padx 10 -pady 10
focus .e
set last {}
proc state {} {
    set pw 0
    set ph 0
    if {![catch {ztk::snapshot .} b64]} {
        binary scan [binary decode base64 $b64] @16IuIu pw ph
    }
    return [list text [.e get] size [winfo width .] [winfo height .] pixels $pw $ph]
}
proc tick {} {
    global last cmdfile
    set s [state]
    if {$s ne $last} {
        puts $s
        flush stdout
        set last $s
    }
    if {[file exists $cmdfile]} {
        set f [open $cmdfile]
        set cmd [read -nonewline $f]
        close $f
        file delete $cmdfile
        switch -- [lindex $cmd 0] {
            copy {clipboard clear; clipboard append [lindex $cmd 1]; puts "copied"}
            paste {puts "clipboard [clipboard get]"}
            quit {exit}
        }
        flush stdout
    }
    after 100 tick
}
after 100 tick
after 30000 exit
