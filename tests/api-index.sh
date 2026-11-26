#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Checks that docs/site/api.json, the API index of the docs site for
# agents, equals the output of tools/api-index.tcl on this build. After a
# change of a command or an option, write the file again:
#   zig-out/bin/ztk --headless --exit-after-frames 1 tools/api-index.tcl \
#     | python3 -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=1); print()' > docs/site/api.json
# Use: tests/api-index.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
new="$(mktemp)"
trap 'rm -f "$new"' EXIT
timeout 60 "$ztk" --headless --exit-after-frames 1 "$root/tools/api-index.tcl" \
    | python3 -I -c 'import json,sys; json.dump(json.load(sys.stdin), sys.stdout, indent=1); print()' > "$new" || { echo "FAIL: tools/api-index.tcl"; exit 1; }
if cmp -s "$new" "$root/docs/site/api.json"; then
    echo "ok: docs/site/api.json equals the API of this build"
else
    echo "FAIL: docs/site/api.json differs from the API of this build. Write it again (see the top of this file)."
    diff "$root/docs/site/api.json" "$new" | head -20
    exit 1
fi
