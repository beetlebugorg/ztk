#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the command line of the ztk program on the headless backend.
# Use: tests/cli.sh      (after: zig build)
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
check() {
    if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1 (got '$2', want '$3')"; fail=1; fi
}
check "version" "$($cap "$ztk" --version)" "ztk 0.0.0"
$cap "$ztk" --headless --exit-after-frames 1 --screenshot "$work/smoke.png" "$root/tests/scripts/smoke.tcl" >/dev/null 2>&1
check "screenshot equals the golden file" "$(cmp "$work/smoke.png" "$root/tests/golden/smoke.png" && echo same)" "same"
out="$($cap "$ztk" --headless --exit-after-frames 5 "$root/tests/scripts/smoke.tcl" 2>&1)"
check "five frames" "$out" "frames: 5"
out="$(env -u WAYLAND_DISPLAY $cap "$ztk" "$root/tests/scripts/smoke.tcl" 2>&1)"
check "no display" "$out" "ztk: no Wayland display. Use --headless, or run in a Wayland session."
out="$($cap "$ztk" --headless nosuch.tcl 2>&1)"; code=$?
check "missing file status" "$code" "1"
case "$out" in *nosuch.tcl*) echo "ok: the message names the file" ;; *) echo "FAIL: the message does not name the file: $out"; fail=1 ;; esac
echo 'puts [' >"$work/bad.tcl"
out="$($cap "$ztk" --headless "$work/bad.tcl" 2>&1)"; code=$?
check "syntax error status" "$code" "1"
case "$out" in *close-bracket*) echo "ok: the syntax error is printed" ;; *) echo "FAIL: no syntax error: $out"; fail=1 ;; esac
out="$(ZTK_FRAME_STATS=1 $cap "$ztk" --headless --exit-after-frames 3 "$root/tests/scripts/smoke.tcl" 2>&1)"
case "$out" in *"frames: 3"*"paint: count 3"*) echo "ok: the frame statistics" ;; *) echo "FAIL: no statistics: $out"; fail=1 ;; esac
echo 'exit 3' >"$work/exit.tcl"
$cap "$ztk" --headless "$work/exit.tcl" >/dev/null 2>&1; check "exit status" "$?" "3"
exit "$fail"
