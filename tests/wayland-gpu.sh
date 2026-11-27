#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs ztk on a private headless sway with the GLES2 renderer of wlroots,
# which accepts dma-bufs. It runs tests/scripts/gpu.tcl with ZTK_RENDERER=vulkan
# (the dma-buf path) and with ZTK_RENDERER=cpu (wl_shm), makes a shot of the
# output with grim after each, and compares the two shots. The compositor
# has its own runtime folder and bus, so it never touches the desktop
# session of the user.
# Use: tests/wayland-gpu.sh [ztk] [render node]
# Exit status: 0 passed, 1 failed, 77 when a tool or the render node is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
node="${2:-/dev/dri/renderD128}"
for tool in sway grim dbus-run-session python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
[ -r "$node" ] || { echo "SKIP: no render node $node"; exit 77; }
rt="$(mktemp -d /tmp/ztkrt.XXXX)"
chmod 700 "$rt"
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
printf 'output HEADLESS-1 resolution 480x320\ndefault_border none\n' >"$rt/sway.conf"
$cap env XDG_RUNTIME_DIR="$rt" WLR_BACKENDS=headless WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$node" WLR_LIBINPUT_NO_DEVICES=1 \
    dbus-run-session -- sway -c "$rt/sway.conf" >"$rt/sway.log" 2>&1 &
pid=$!
app=""
cleanup() {
    [ -n "$app" ] && kill "$app" 2>/dev/null
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
shot() {
    env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1 ZTK_RENDERER="$1" ZTK_NO_ANIMATION=1 "$ztk" "$root/tests/scripts/gpu.tcl" >"$rt/$1.log" 2>&1 &
    app=$!
    sleep 2
    kill -0 "$app" 2>/dev/null || { cat "$rt/$1.log"; echo "FAIL: ztk with ZTK_RENDERER=$1 stopped"; exit 1; }
    env XDG_RUNTIME_DIR="$rt" WAYLAND_DISPLAY=wayland-1 grim -t ppm "$rt/$1.ppm" || { echo "FAIL: grim"; exit 1; }
    kill "$app"
    wait "$app" 2>/dev/null
    app=""
}
shot vulkan
shot cpu
if grep -q 'CPU renderer' "$rt/vulkan.log"; then cat "$rt/vulkan.log"; echo "FAIL: the Vulkan run used the CPU renderer"; exit 1; fi
python3 -I - "$rt/vulkan.ppm" "$rt/cpu.ppm" <<'PY' || exit 1
import sys
def load(p):
    d = open(p, "rb").read()
    parts = d.split(maxsplit=4)
    w, h = int(parts[1]), int(parts[2])
    return w, h, parts[4][: w * h * 3]
a, b = load(sys.argv[1]), load(sys.argv[2])
if a[:2] != b[:2]:
    sys.exit("FAIL: the shots differ in size: %s and %s" % (a[:2], b[:2]))
n = a[0] * a[1]
bad = sum(1 for i in range(n) if max(abs(a[2][3 * i + k] - b[2][3 * i + k]) for k in range(3)) > 2)
dark = sum(1 for i in range(n) if a[2][3 * i] < 128)
print("shots %dx%d: %d of %d pixels differ by more than 2, %d dark pixels" % (a[0], a[1], bad, n, dark))
if dark == 0:
    sys.exit("FAIL: the Vulkan shot has no dark pixel")
if bad * 1000 > n:
    sys.exit("FAIL: more than 0.1 %% of the pixels differ")
PY
echo "PASS: the dma-buf path of Vulkan and the CPU path give the same shot"
