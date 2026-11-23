#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs each test file of a Tk source tree with a real `wish` and prints
# one line for each file: file, total, passed, skipped, failed.
# Use: xvfb-run -a tools/tk-run.sh <tk source folder> <work folder>
# It copies the tests to the work folder, because the tests write files.
set -eu
src="$1"
work="$2"
mkdir -p "$work"
cp -r "$src/tests" "$work/tests"
cat > "$work/wrap.tcl" <<'WRAP'
set f [lindex $argv 0]
set argv [list -loadfile [file normalize constraints.tcl]]
set argc 2
after 170000 {puts "WRAP-TIMEOUT"; exit 3}
if {[catch {source $f} m]} {puts "WRAP-ERROR $m"}
exit 0
WRAP
cd "$work/tests"
for f in *.test ttk/*.test; do
    out="$(timeout -k 5 180 wish "$work/wrap.tcl" "$f" 2>&1 </dev/null || true)"
    line="$(printf '%s\n' "$out" | grep -E 'Total[[:space:]]+[0-9]+' | tail -1 || true)"
    if [ -z "$line" ]; then
        printf '%s\tno summary\n' "$f"
    else
        printf '%s\n' "$line" | awk -v f="$f" '{print f "\t" $3 "\t" $5 "\t" $7 "\t" $9}'
    fi
done
