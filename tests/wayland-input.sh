#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Sends keys, a resize, a scale change, and the clipboard to ztk on a
# private headless sway, and checks what tests/scripts/input.tcl reports.
# wtype types through the virtual keyboard of sway with a key map of its
# own, so the test also reads a key map that is not the one of sway.
# Use: tests/wayland-input.sh [ztk program]
# Exit status: 0 passed, 1 failed, 77 when a tool is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
for tool in sway swaymsg dbus-run-session wtype wl-copy wl-paste; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
rt="$(mktemp -d /tmp/ztkrt.XXXX)"
chmod 700 "$rt"
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
printf 'output HEADLESS-1 resolution 800x600\n' >"$rt/sway.conf"
$cap env XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    dbus-run-session -- sway -c "$rt/sway.conf" >"$rt/sway.log" 2>&1 &
pid=$!
cleanup() {
    for p in $(pgrep -f "sway -c $rt/sway.conf"); do kill "$p" 2>/dev/null; done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$rt"
}
trap cleanup EXIT
n=0
while [ ! -S "$rt/wayland-1" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -S "$rt/wayland-1" ] || { echo "FAIL: the compositor has no socket"; exit 1; }
export XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1
sock=$(ls "$rt"/sway-ipc.*.sock 2>/dev/null | head -n 1)
msg() { swaymsg -s "$sock" "$@" >/dev/null; }
cmd="$rt/cmd"
timeout 40 "$ztk" "$root/tests/scripts/input.tcl" "$cmd" >"$rt/out" 2>"$rt/err" &
zpid=$!
# A virtual keyboard that lives for 6 seconds gives the seat a keyboard,
# so the client has the key map before the keys of the next wtype come.
sleep 1
wtype -s 6000 x &
sleep 2
wtype 'ab'
wtype -M shift c -m shift
wtype 'é€'
sleep 1
msg resize set width 400 px height 300 px
msg floating enable
msg resize set width 400 px height 300 px
sleep 1
msg output HEADLESS-1 scale 1.5
sleep 1
wl-copy "from outside"
sleep 0.5
echo paste >"$cmd"
sleep 1
echo "copy from-ztk" >"$cmd"
sleep 1
got=$(timeout 5 wl-paste -n 2>/dev/null)
echo quit >"$cmd"
wait "$zpid"
cat "$rt/out"
fail=0
check() { grep -q "$1" "$rt/out" || { echo "FAIL: no line with: $1"; fail=1; }; }
check '^text abcé€ '
check 'pixels'
check '^clipboard from outside$'
[ "$got" = "from-ztk" ] || { echo "FAIL: wl-paste gave \"$got\""; fail=1; }
[ -s "$rt/err" ] && { echo "stderr:"; cat "$rt/err"; }
[ "$fail" -eq 0 ] && echo "PASS: keys, a resize, the scale 1.5, and the clipboard"
exit "$fail"
