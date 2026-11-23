#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs examples/demo.tcl in wish and in ztk, and compares the values that do
# not depend on the theme: the widgets, the grid, and the variables after the
# same commands. Use: tests/demo.sh      (after: zig build)
# Exit status: 0 equal, 1 different, 77 when wish or xvfb-run is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
for tool in wish xvfb-run; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
[ -x "$root/zig-out/bin/ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$root/examples/demo.tcl" "$root/examples/demo.css" "$work/"
cat "$root/tests/scripts/demo-values.tcl" >>"$work/demo.tcl"
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
$cap xvfb-run -a wish "$work/demo.tcl" >"$work/wish.txt" 2>"$work/wish.err"
$cap "$root/zig-out/bin/ztk" --headless "$work/demo.tcl" >"$work/ztk.txt" 2>"$work/ztk.err"
if diff -u "$work/wish.txt" "$work/ztk.txt"; then
    echo "equal: $(wc -l <"$work/wish.txt") lines"
    exit 0
fi
echo "wish errors:"; head -5 "$work/wish.err"
echo "ztk errors:"; head -5 "$work/ztk.err"
exit 1
