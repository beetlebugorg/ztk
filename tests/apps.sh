#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Drives the two canvas apps on the headless backend. For each app it
# runs examples/NAME.tcl with tests/scripts/NAME-test.tcl after it, and
# each check of the test prints "ok" or "FAIL". The SVG export of the
# vector tool must also parse as XML, with one element for each shape.
# Use: tests/apps.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when ztk is not built.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
cap="systemd-run --user --scope -q -p MemoryMax=2G -p MemorySwapMax=0 --"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0
for app in spreadsheet vector; do
    # The program has no `source` by default (D19), so the test is one file.
    cp "$root/examples/$app.css" "$work/"
    cat "$root/examples/$app.tcl" "$root/tests/scripts/$app-test.tcl" > "$work/$app.tcl"
    (cd "$work" && $cap timeout 120 "$ztk" --headless "$app.tcl" > "$work/$app.out" 2>&1)
    code=$?
    sed '/^--svg--$/,/^--end--$/d' "$work/$app.out" | grep -v '^frames: '
    if [ "$code" -ne 0 ] || ! grep -q '^fails: 0$' "$work/$app.out"; then
        echo "FAIL: the test of examples/$app.tcl (status $code)"
        fail=1
    fi
done
sed -n '/^--svg--$/,/^--end--$/p' "$work/vector.out" | sed '1d;$d' > "$work/drawing.svg"
python3 -I - "$work/drawing.svg" <<'PY' || fail=1
import sys, xml.etree.ElementTree as ET
ns = "{http://www.w3.org/2000/svg}"
try:
    root = ET.parse(sys.argv[1]).getroot()
except Exception as e:
    print(f"FAIL: the SVG export does not parse: {e}"); sys.exit(1)
kinds = sorted({e.tag.replace(ns, "") for e in root if e.get("id")})
ok = root.tag == ns + "svg" and kinds == ["ellipse", "line", "polygon", "polyline", "rect", "text"]
print(("ok" if ok else "FAIL") + f": the SVG export parses as XML, {len(root)} elements of the kinds {kinds}")
sys.exit(0 if ok else 1)
PY
exit "$fail"
