#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks `wm iconphoto` on Wayland: ztk runs on the small server of
# tests/wayland/icon-server.py, which has xdg-toplevel-icon-v1, and the
# test compares the icon buffers with the photos. A photo of 3 by 2
# pixels goes in the middle of a clear square of 3 pixels.
# Use: tests/wayland-icon.sh [ztk]
# Exit status: 0 passed, 1 failed, 77 when ztk is not built.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
rt="$(mktemp -d /tmp/ztkrt.XXXX)"
chmod 700 "$rt"
srv=""
cleanup() {
    [ -n "$srv" ] && kill "$srv" 2>/dev/null
    rm -rf "$rt"
}
trap cleanup EXIT
python3 -I "$root/tests/wayland/icon-server.py" "$rt/wayland-icon" "$rt/icons.json" &
srv=$!
n=0
while [ ! -S "$rt/wayland-icon" ] && [ "$n" -lt 50 ]; do
    sleep 0.1
    n=$((n + 1))
done
cat >"$rt/icon.tcl" <<'EOF'
image create photo big -width 4 -height 4
big put #ff0000 -to 0 0 4 4
image create photo small -width 3 -height 2
small put {{#00ff00 #0000ff #ffffff} {#00ff00 #0000ff #ffffff}}
wm iconphoto . -default big small
update
after 300 exit
EOF
env -u DISPLAY XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-icon ZTK_RENDERER=cpu ZTK_NO_ANIMATION=1 \
    timeout 20 "$ztk" "$rt/icon.tcl" >"$rt/ztk.log" 2>&1 || { cat "$rt/ztk.log"; echo "FAIL: ztk"; exit 1; }
wait "$srv"
srv=""
python3 -I - "$rt/icons.json" <<'PY' || exit 1
import json, sys
calls = json.load(open(sys.argv[1]))
assert len(calls) == 1, calls
c = calls[0]
assert c["toplevel"], c
red = "0000ffff" * 16
clear = "00000000"
small = ("00ff00ff" + "ff0000ff" + "ffffffff") * 2 + clear * 3
want = [(4, red), (3, small)]
got = [(b["width"], b["pixels"]) for b in c["buffers"]]
for b in c["buffers"]:
    assert b["width"] == b["height"] and b["format"] == 0 and b["scale"] == 1 and b["stride"] == 4 * b["width"], b
assert got == want, got
print("PASS: wm iconphoto sets 2 square ARGB8888 buffers with xdg-toplevel-icon-v1")
PY
