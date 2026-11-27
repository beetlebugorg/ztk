#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs Python programs of tkinter on libztk with the headless backend and
# compares their output with the files .want beside them.
# Use: tests/libztk.sh [libdir]   (default zig-out/lib, from zig build libztk)
# Exit status: 0 passed, 1 failed, 77 when python3 has no _tkinter.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
lib="${1:-$root/zig-out/lib}"
[ -e "$lib/libtk8.6.so" ] || { echo "SKIP: build libztk first: zig build libztk"; exit 77; }
python3 -c "import _tkinter" 2>/dev/null || { echo "SKIP: python3 has no _tkinter"; exit 77; }
fail=0
for py in "$root"/tests/libztk/*.py; do
    want="${py%.py}.want"
    got="$(env LD_LIBRARY_PATH="$lib" ZTK_HEADLESS=1 ZTK_NO_ANIMATION=1 timeout 60 python3 -I "$py" 2>&1)"
    if [ "$got" = "pillow absent" ]; then
        echo "SKIP: $(basename "$py"): no Pillow"
    elif [ "$got" = "$(cat "$want")" ]; then
        echo "PASS: $(basename "$py")"
    else
        echo "FAIL: $(basename "$py")"
        printf '%s\n' "$got" | diff "$want" - | head -20
        fail=1
    fi
done
exit $fail
