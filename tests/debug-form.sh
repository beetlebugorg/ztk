#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs the form of docs/debug-a-form.md in ztk --headless, with the bugs
# and with the fixes of the page, and checks the answers that the page
# shows.
# Use: tests/debug-form.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
awk '/^<!-- live -->/{m=1;next} m&&/^```tcl/{on=1;next} on&&/^```/{exit} on' "$root/docs/debug-a-form.md" >"$work/form.tcl"
fail=0
# check NAME SCRIPT PATTERN: the output of SCRIPT has a line that equals PATTERN.
check() {
    out="$(cd "$work" && timeout 30 "$ztk" --headless "$2" 2>&1)"
    if printf '%s\n' "$out" | grep -qxF -- "$3"; then
        echo "ok: $1"
    else
        echo "FAIL: $1: no line \"$3\" in:"
        printf '%s\n' "$out" | head -20
        fail=1
    fi
}
# The commands of the page run with no file, as in the console.
run() {
    { echo 'set f [open form.tcl]; set code [read $f]; close $f; info script ""; eval $code; update'; cat; echo exit; } >"$work/$1"
}
run bug1.tcl <<'T'
ztk::debug type Ada .f.name
ztk::debug type ada@example.com .f.email
puts [ztk::debug explain .f.save -state]
puts [ztk::debug explain .f.email -textvariable]
puts [ztk::debug explain .f.hint]
T
check "bug 1: the stack of check" bug1.tcl 'Stack: check ::mail {} write'
check "bug 1: the source of the variable" bug1.tcl '.f.email -textvariable is "mail": set by entry .f.email -textvariable mail at line 9.'
check "bug 2: the hint has no manager" bug1.tcl '  not mapped: no geometry manager (pack, grid, or place)'
# The fix of bug 1.
sed -i.bak 's/-textvariable mail/-textvariable email/; s/trace add variable mail write check/trace add variable email write check/' "$work/form.tcl"
run bug3.tcl <<'T'
ztk::debug type Ada .f.name
ztk::debug type ada@example.com .f.email
ztk::debug mark before
puts [ztk::debug click .f.save]
puts [ztk::debug changes before]
puts "status: [.f.status cget -text]"
T
check "bug 3: the binding of the toplevel" bug3.tcl '  binding . <ButtonRelease-1>: .f.status configure -text "Fill in both fields"'
check "bug 3: the command writes the welcome" bug3.tcl '  option .f.status -text: "Fill in both fields" -> "Welcome, Ada" (line 2 of proc save)'
check "bug 3: the status stays" bug3.tcl 'status: Fill in both fields'
# The fixes of bugs 2 and 3.
sed -i.bak 's/^grid .f.l2 .f.email -sticky w -pady 2$/&\ngrid .f.hint -column 1 -sticky w/; s/^bind \. <ButtonRelease-1>/bind .f <ButtonRelease-1>/' "$work/form.tcl"
check "fixed: the changes have the welcome" bug3.tcl '.f.status -text: "Fill in both fields" -> "Welcome, Ada"'
check "fixed: the status" bug3.tcl 'status: Welcome, Ada'
run hint.tcl <<'T'
puts "mapped: [winfo ismapped .f.hint]"
T
check "fixed: the hint is mapped" hint.tcl 'mapped: 1'
exit $fail
