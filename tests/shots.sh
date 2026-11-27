#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks the examples and their screenshots. tools/shots.sh draws each
# example again into a temporary folder, and each file must equal the file
# in docs/site/shots. When wish and xvfb-run are on the path, each example
# also runs in wish with no error.
# Use: tests/shots.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when ztk is not built.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$root/zig-out/bin/ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
if ! $cap "$root/tools/shots.sh" "$work/shots" >/dev/null; then
    echo "FAIL: tools/shots.sh"
    exit 1
fi
for file in "$root"/docs/site/shots/*.png; do
    name="$(basename "$file")"
    # The screenshots of the famous apps come from tests/famous-apps.sh.
    case "$name" in app-*) continue ;; esac
    if cmp -s "$file" "$work/shots/$name"; then
        echo "ok: $name"
    else
        echo "FAIL: $name differs from a new shot (run tools/shots.sh)"
        fail=1
    fi
done
for file in "$work"/shots/*.png; do
    [ -f "$root/docs/site/shots/$(basename "$file")" ] || { echo "FAIL: $(basename "$file") is not in docs/site/shots"; fail=1; }
done
if command -v wish >/dev/null 2>&1 && command -v xvfb-run >/dev/null 2>&1; then
    for script in "$root"/examples/*.tcl; do
        name="$(basename "$script")"
        out="$(cd "$root/examples" && printf 'source %s\nupdate\nputs done\nexit\n' "$name" | $cap timeout 60 xvfb-run -a wish 2>&1)"
        if [ "$out" = done ]; then echo "ok: wish runs $name"; else echo "FAIL: wish runs $name: $out"; fail=1; fi
    done
else
    echo "SKIP: wish or xvfb-run is not on the path, so no example ran in wish"
fi
exit "$fail"
