#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs a script in wish 8.6.16 and in ztk, and prints the difference.
# Use: tools/oracle.sh script.tcl [args...]
# Build the ztk side first: zig build
# Exit status: 0 equal, 1 different, 77 when wish or xvfb-run is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$1"
shift
for tool in wish xvfb-run; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not on the path"; exit 77; }
done
runner="$root/zig-out/bin/ztk"
[ -x "$runner" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
$cap xvfb-run -a wish "$script" "$@" >"$work/wish.txt" 2>"$work/wish.err"
$cap "$runner" --headless "$script" "$@" >"$work/ztk.txt" 2>"$work/ztk.err"
if diff -u "$work/wish.txt" "$work/ztk.txt" >"$work/diff.txt"; then
    echo "equal: $(wc -l <"$work/wish.txt") lines"
    exit 0
fi
head -60 "$work/diff.txt"
echo "wish errors:"; head -5 "$work/wish.err"
echo "ztk errors:"; head -5 "$work/ztk.err"
exit 1
