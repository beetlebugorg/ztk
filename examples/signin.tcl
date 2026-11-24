# A sign-in form in a card. It runs in ztk and in wish 8.6.
if {[llength [info commands ::ztk::style]]} {
    ::ztk::style load signin.css
}
wm title . "Sign in"
set email "ada@example.com"
set password "analytical"
set status "Use the account of your workspace."

frame .card -padx 24 -pady 20
label .card.title -text "Welcome back"
label .card.sub -text "Sign in to continue to the build farm."
label .card.lemail -text "Email"
entry .card.email -textvariable email -width 28
label .card.lpass -text "Password"
entry .card.pass -textvariable password -show "*" -width 28
button .card.cancel -text "Cancel" -command {destroy .}
button .card.ok -text "Sign in" -command {set status "Signed in as $email."}
label .card.status -textvariable status

grid .card.title  -          -sticky w  -pady {0 2}
grid .card.sub    -          -sticky w  -pady {0 14}
grid .card.lemail -          -sticky w
grid .card.email  -          -sticky ew -pady {2 10}
grid .card.lpass  -          -sticky w
grid .card.pass   -          -sticky ew -pady {2 16}
grid .card.cancel .card.ok   -sticky ew
grid .card.status -          -sticky w  -pady {12 0}
grid columnconfigure .card {0 1} -weight 1 -uniform b
grid configure .card.cancel -padx {0 6}
grid configure .card.ok -padx {6 0}
grid .card -padx 28 -pady 28 -sticky nsew

if {[llength [info commands ::ztk::class]]} {
    ::ztk::class .card add card
    ::ztk::class .card.ok add primary
    ::ztk::class .card.sub add muted
    ::ztk::class .card.status add muted
}
bind .card.pass <Return> {.card.ok invoke}
focus .card.pass
.card.pass icursor end
