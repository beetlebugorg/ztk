#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs each step of each replay in docs/site/replays in ztk --headless:
# the script of the step, then its check, which must give 1.
# Use: tests/replay.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 -I - "$root/docs/site/replays" "$work" <<'PY'
import json, pathlib, sys
out = pathlib.Path(sys.argv[2])
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    for i, s in enumerate(json.load(open(f))["steps"]):
        if "script" in s:
            (out / f"{f.stem}-{i}.tcl").write_text("wm geometry . 360x240\n" + s["script"] + "\nputs \"check: [eval {" + s.get("check", "expr 1") + "}]\"\nexit\n")
PY
fail=0
for t in "$work"/*.tcl; do
    got="$(timeout 30 "$ztk" --headless "$t" 2>&1 | grep '^check: ')"
    name="$(basename "$t" .tcl)"
    if [ "$got" = "check: 1" ]; then echo "ok: $name"; else echo "FAIL: $name: $got"; fail=1; fi
done
exit $fail
