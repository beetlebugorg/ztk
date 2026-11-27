#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks `wm iconphoto` on X11: ztk runs on a private Xvfb, and the test
# reads `_NET_WM_ICON` with xprop. A photo of 256 by 300 pixels has more
# words than one request, so the property comes in parts.
# Use: tests/x11-icon.sh [ztk]
# Exit status: 0 passed, 1 failed, 77 when a tool is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
for tool in Xvfb xdotool xprop; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
tmp="$(mktemp -d /tmp/ztkx11.XXXX)"
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
cat >"$tmp/icon.tcl" <<'EOF'
image create photo big -width 256 -height 300
big put #ff0000 -to 0 0 256 300
image create photo small -width 3 -height 1
small put {{#00ff00 #0000ff #ffffff}}
wm iconphoto . -default big small
after 20000 exit
EOF
env -u WAYLAND_DISPLAY DISPLAY=":$n" XAUTHORITY="$tmp/none" "$ztk" "$tmp/icon.tcl" >"$tmp/out" 2>"$tmp/err" &
zpid=$!
export DISPLAY=":$n"
k=0
wid=""
while [ -z "$wid" ] && [ "$k" -lt 100 ]; do wid=$(xdotool search --name '^ztk$' 2>/dev/null | head -n 1); sleep 0.1; k=$((k + 1)); done
[ -n "$wid" ] || { echo "FAIL: no window"; cat "$tmp/err"; exit 1; }
# The property comes after the window: wait for it.
k=0
while ! xprop -id "$wid" _NET_WM_ICON | grep -q CARDINAL && [ "$k" -lt 100 ]; do sleep 0.1; k=$((k + 1)); done
sleep 0.5
xprop -len 1000000 -id "$wid" -notype 32x _NET_WM_ICON | tr -d ' ' | sed 's/^_NET_WM_ICON=//' | tr ',' '\n' >"$tmp/words"
python3 -I - "$tmp/words" <<'PY' || exit 1
import sys
w = [int(x, 16) for x in open(sys.argv[1]).read().split()]
want = [256, 300] + [0xFFFF0000] * (256 * 300) + [3, 1, 0xFF00FF00, 0xFF0000FF, 0xFFFFFFFF]
assert len(w) == len(want), len(w)
assert w == want, [i for i, (a, b) in enumerate(zip(w, want)) if a != b][:5]
print("PASS: wm iconphoto sets _NET_WM_ICON with 2 images (%d words)" % len(w))
PY
