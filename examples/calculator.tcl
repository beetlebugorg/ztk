# A calculator: a keypad of buttons in a grid. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load calculator.css
}
wm title . "Calculator"
set expr "12 * (7 + 5)"
set display "144"

proc press {key} {
    global expr display
    switch -- $key {
        C { set expr ""; set display 0 }
        = {
            if {[catch {expr $expr} value]} { set display Error } else { set display $value }
        }
        default { append expr $key; set display $expr }
    }
}

frame .f -padx 10 -pady 10
grid .f -sticky nsew
label .f.expr -textvariable expr -anchor e
label .f.display -textvariable display -anchor e
grid .f.expr    - - - -sticky ew -padx 6 -pady {6 0}
grid .f.display - - - -sticky ew -padx 6 -pady {0 8}

set keys {
    {C ( ) /}
    {7 8 9 *}
    {4 5 6 -}
    {1 2 3 +}
    {0 . =}
}
set n 0
foreach row $keys {
    set line {}
    foreach key $row {
        set b .f.k[incr n]
        button $b -text $key -width 3 -command [list press $key]
        lappend line $b
        set kind($b) [expr {[string is digit $key] || $key eq "." ? "digit" : "op"}]
        if {$key eq "C"} { set kind($b) clear }
        if {$key eq "="} { set kind($b) equals }
    }
    if {[llength $line] == 3} {
        # The 0 key is two columns wide.
        grid [lindex $line 0] - [lindex $line 1] [lindex $line 2] -sticky nsew -padx 3 -pady 3
    } else {
        grid {*}$line -sticky nsew -padx 3 -pady 3
    }
}
grid columnconfigure .f {0 1 2 3} -weight 1 -uniform k

if {[llength [info commands ::ztk::class]]} {
    ::ztk::class .f.display add display
    ::ztk::class .f.expr add expr
    foreach b [array names kind] { ::ztk::class $b add $kind($b) }
}
