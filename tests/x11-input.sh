#!/bin/sh
# Sends keys, a click, and a resize to ztk on a private Xvfb server with
# the X11 client of ztk, and checks what tests/scripts/input.tcl reports
# and the pixels of a screenshot.
# Use: tests/x11-input.sh [ztk program]
# Exit status: 0 passed, 1 failed, 77 when a tool is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
for tool in Xvfb xdotool; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
tmp="$(mktemp -d /tmp/ztkx11.XXXX)"
# A free display number.
n=90
while [ -e "/tmp/.X11-unix/X$n" ] || [ -e "/tmp/.X$n-lock" ]; do n=$((n + 1)); done
Xvfb ":$n" -screen 0 800x600x24 -nolisten tcp >"$tmp/xvfb.log" 2>&1 &
xpid=$!
zpid=""
cleanup() {
    [ -n "$zpid" ] && kill "$zpid" 2>/dev/null
    kill "$xpid" 2>/dev/null
    wait "$xpid" 2>/dev/null
    rm -rf "$tmp"
}
trap cleanup EXIT
k=0
while [ ! -S "/tmp/.X11-unix/X$n" ] && [ "$k" -lt 50 ]; do sleep 0.1; k=$((k + 1)); done
[ -S "/tmp/.X11-unix/X$n" ] || { echo "FAIL: Xvfb has no socket"; exit 1; }
cmd="$tmp/cmd"
env -u WAYLAND_DISPLAY DISPLAY=":$n" XAUTHORITY="$tmp/none" timeout 40 "$ztk" "$root/tests/scripts/input.tcl" "$cmd" >"$tmp/out" 2>"$tmp/err" &
zpid=$!
export DISPLAY=":$n"
k=0
wid=""
while [ -z "$wid" ] && [ "$k" -lt 50 ]; do wid=$(xdotool search --name '^ztk$' 2>/dev/null | head -n 1); sleep 0.1; k=$((k + 1)); done
[ -n "$wid" ] || { echo "FAIL: no window"; cat "$tmp/err"; exit 1; }
sleep 0.5
xdotool windowfocus "$wid"
xdotool type --window "$wid" 'ab'
xdotool key --window "$wid" shift+c
sleep 0.5
xdotool windowsize "$wid" 400 300
sleep 1
echo quit >"$cmd"
wait "$zpid"
zpid=""
cat "$tmp/out"
fail=0
grep -q '^text abC ' "$tmp/out" || { echo "FAIL: no line with the text abC"; fail=1; }
grep -q 'size 400 300' "$tmp/out" || { echo "FAIL: no line with the size 400 300"; fail=1; }
grep -v '^frames:' "$tmp/err" | grep . && { echo "FAIL: stderr above"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: the X11 client: keys and a resize"
exit "$fail"
