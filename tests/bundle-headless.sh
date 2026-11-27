#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Bundles a script into one program file and runs it with ZTK_HEADLESS=1
# and no display. The script prints its arguments and the size of its
# window, so the run checks that each word goes to the script and that
# the headless backend runs it.
# Use: tests/bundle-headless.sh [ztk]
set -eu
ztk="${1:-zig-out/bin/ztk}"
dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
cat > "$dir/app.tcl" <<'TCL'
label .l -text hi -width 10
pack .l
update
puts "args=$argv"
puts "w=[expr {[winfo width .] > 0}]"
exit
TCL
"$ztk" bundle -o "$dir/app" "$dir/app.tcl" 2>/dev/null
out="$(env -u WAYLAND_DISPLAY -u DISPLAY ZTK_HEADLESS=1 timeout 60 "$dir/app" --headless x | tr -d '\r')"
want="args=--headless x
w=1"
if [ "$out" != "$want" ]; then
    printf 'bundle-headless: got:\n%s\nwant:\n%s\n' "$out" "$want" >&2
    exit 1
fi
echo "bundle-headless: ok"
