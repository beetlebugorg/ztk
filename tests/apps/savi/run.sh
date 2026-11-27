#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Builds SaVi 1.6.0 (C and Tcl, a pinned release of tests/apps/pins.txt)
# with no change against libztk, and runs it with the headless backend:
# it loads Iridium, opens the coverage map, runs, and writes the images.
# Use: tests/apps/savi/run.sh SRC TCLINC [LIBDIR] [SHOTS]
#   SRC: the folder of the release (savi1.6.0), copied to a build folder
#   TCLINC: the include folder of the kit of libztcl (tcl.h)
#   LIBDIR: libtcl8.6.so and libtk8.6.so of zig build libztk (zig-out/lib)
# tclIndex of the Tcl files comes from a tclsh 8.6 of the host, because
# ztcl has no auto_mkindex yet.
# SaVi calls Tcl_GetCommandInfo, which ztcl has from ztcl#502 on.
# Exit status: 0 passed, 1 failed, 77 when cc or tclsh8.6 is missing.
set -u
root="$(cd "$(dirname "$0")/../../.." && pwd)"
src="$1"; inc="$2"; lib="${3:-$root/zig-out/lib}"; shots="${4:-}"
for tool in cc make tclsh8.6; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
work="$(mktemp -d /tmp/ztk-savi.XXXX)"
trap 'rm -rf "$work"' EXIT
cp -r "$src" "$work/savi"
(cd "$work/savi/src" && make ARCH=linux \
    TCL_INCLUDES="-I$inc -I$root/packaging/libztk/include" \
    TCL_LIBS="-L$lib -ltk8.6 -ltcl8.6" OTHER_LIBS="-ldl" >"$work/build.log" 2>&1) || { tail -20 "$work/build.log"; echo "FAIL: build"; exit 1; }
(cd "$work/savi/tcl" && make TCLSH=tclsh8.6 >>"$work/build.log" 2>&1) || { echo "FAIL: tclIndex"; exit 1; }
out="${shots:-$work/shots}"
mkdir -p "$out"
env -u WAYLAND_DISPLAY -u DISPLAY SAVI="$work/savi" TCL_LIBRARY="$work/savi" TK_LIBRARY="$work/savi" SHOTS="$out" LD_LIBRARY_PATH="$lib" \
    ZTK_HEADLESS=1 ZTK_NO_ANIMATION=1 ZTK_SCRIPT="$root/tests/apps/savi/shots.tcl" \
    timeout 120 "$work/savi/bin/SaVi-linux.bin" >"$work/run.log" 2>&1
status=$?
cat "$work/run.log"
[ "$status" -eq 0 ] || { echo "FAIL: status $status"; exit 1; }
for n in main coverage; do
    [ -s "$out/$n.png" ] || { echo "FAIL: no image $n.png"; exit 1; }
done
echo "PASS: SaVi ran on libztk and wrote main.png and coverage.png"
