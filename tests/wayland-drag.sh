#!/bin/sh
# Sends real drags with a virtual pointer on a private headless sway: a
# file and text from one ztk window to another, then text that the first
# window drops on itself. The source window gives the answer of the
# target, and each target gives the data of the drop.
# Use: tests/wayland-drag.sh [ztk program]
# Build the pointer first: zig build test-pointer
# Exit status: 0 passed, 1 failed, 77 when a tool is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
pointer="$(dirname "$ztk")/ztk-test-pointer"
for tool in sway swaymsg dbus-run-session; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
[ -x "$pointer" ] || { echo "SKIP: build the pointer first: zig build test-pointer"; exit 77; }
rt="$(mktemp -d /tmp/ztkrt.XXXX)"
chmod 700 "$rt"
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
printf 'output HEADLESS-1 resolution 800x600\ndefault_border none\n' >"$rt/sway.conf"
$cap env XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    dbus-run-session -- sway -c "$rt/sway.conf" >"$rt/sway.log" 2>&1 &
pid=$!
spid=""
tpid=""
cleanup() {
    [ -n "$spid" ] && kill "$spid" 2>/dev/null
    [ -n "$tpid" ] && kill "$tpid" 2>/dev/null
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
# sway puts the source at the left half and the target at the right half.
timeout 40 "$ztk" "$root/tests/scripts/drag.tcl" source >"$rt/src" 2>"$rt/src.err" &
spid=$!
sleep 1
timeout 40 "$ztk" "$root/tests/scripts/drag.tcl" target >"$rt/dst" 2>"$rt/dst.err" &
tpid=$!
sleep 1.5
for to in 600 600 100; do
    "$pointer" move 200 300 wait 300 down wait 100 glide 260 300 wait 200 glide $to 300 wait 300 glide $((to + 20)) 300 wait 300 up wait 700 \
        || { echo "FAIL: the virtual pointer"; exit 1; }
done
sleep 1
kill "$spid" "$tpid" 2>/dev/null
wait "$spid" "$tpid" 2>/dev/null
spid=""
tpid=""
echo "source:"; cat "$rt/src"
echo "target:"; cat "$rt/dst"
fail=0
check() { grep -qx "$2" "$rt/$1" || { echo "FAIL: $1 has no line: $2"; fail=1; }; }
check dst 'files {{/tmp/ztk drag/a b.txt}}'
check dst 'text {drag text é}'
check src 'drag 1 copy'
check src 'drag 2 copy'
check src 'drag 3 copy'
check src 'text {own text}'
for f in src.err dst.err; do [ -s "$rt/$f" ] && { echo "$f:"; cat "$rt/$f"; }; done
[ "$fail" -eq 0 ] && echo "PASS: drags of a file and of text between two windows, and in one window"
exit "$fail"
