#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs ztk on a private headless compositor, and then a menu in popup
# surfaces. The compositor is sway with the
# headless backend and the pixman renderer. It has its own runtime folder and
# bus, so it never touches the desktop session of the user.
# Use: tests/wayland-smoke.sh
# Exit status: 0 passed, 1 failed, 77 when sway or dbus-run-session is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
for tool in sway dbus-run-session; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$root/zig-out/bin/ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
rt="$(mktemp -d /tmp/ztkrt.XXXX)"
chmod 700 "$rt"
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
echo "output HEADLESS-1 resolution 800x600" >"$rt/sway.conf"
$cap env XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    dbus-run-session -- sway -c "$rt/sway.conf" >"$rt/sway.log" 2>&1 &
pid=$!
cleanup() {
    # Stop the compositor by its process number. The path of the temporary folder is unique.
    for p in $(pgrep -f "sway -c $rt/sway.conf"); do kill "$p" 2>/dev/null; done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    rm -rf "$rt"
}
trap cleanup EXIT
n=0
while [ ! -S "$rt/wayland-1" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
done
[ -S "$rt/wayland-1" ] || { echo "FAIL: the compositor has no socket"; tail -3 "$rt/sway.log"; exit 1; }
out="$($cap env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1 timeout 60 "$root/zig-out/bin/ztk" --exit-after-frames 5 "$root/tests/scripts/smoke.tcl" 2>&1)"
status=$?
echo "$out"
[ "$status" -eq 0 ] || { echo "FAIL: status $status"; exit 1; }
echo "$out" | grep -q '^frames: 5$' || { echo "FAIL: no line 'frames: 5'"; exit 1; }
echo "PASS: ztk drew 5 frames on a private compositor with the CPU renderer"
out="$($cap env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1 timeout 60 "$root/zig-out/bin/ztk" --exit-after-frames 5 "$root/tests/scripts/popup.tcl" 2>&1)"
status=$?
echo "$out"
[ "$status" -eq 0 ] || { echo "FAIL: popup.tcl: status $status"; exit 1; }
echo "$out" | grep -q '^frames: 5$' || { echo "FAIL: popup.tcl: no line 'frames: 5'"; exit 1; }
if echo "$out" | grep -qi error; then echo "FAIL: popup.tcl printed an error"; exit 1; fi
echo "PASS: a menu and its cascade opened in xdg_popup surfaces"
if command -v swaymsg >/dev/null 2>&1; then
    env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1 timeout 60 "$root/zig-out/bin/ztk" "$root/tests/scripts/fullscreen.tcl" >/dev/null 2>&1 &
    app=$!
    sock="$(ls "$rt"/sway-ipc.*.sock 2>/dev/null | head -n 1)"
    n=0
    full=0
    while [ "$n" -lt 30 ] && [ "$full" -eq 0 ]; do
        sleep 0.1
        n=$((n + 1))
        SWAYSOCK="$sock" swaymsg -t get_tree 2>/dev/null | grep -q '"fullscreen_mode": 1' && full=1
    done
    kill "$app" 2>/dev/null
    wait "$app" 2>/dev/null
    [ "$full" -eq 1 ] || { echo "FAIL: wm attributes -fullscreen 1 gave no full screen window"; exit 1; }
    echo "PASS: wm attributes -fullscreen 1 made the window full screen (xdg_toplevel.set_fullscreen)"
fi
