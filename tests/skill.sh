#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs the check script of skills/ztk-app/SKILL.md and of docs/agents.md
# in ztk --headless. Each must print "n = 1".
# Use: tests/skill.sh      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when the build is missing.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
script="$(mktemp)"
trap 'rm -f "$script"' EXIT
fail=0
for doc in skills/ztk-app/SKILL.md docs/agents.md; do
    awk '/^```tcl/{on=1;next} on&&/^```/{exit} on' "$root/$doc" >"$script"
    got="$(timeout 30 "$ztk" --headless "$script" 2>&1 | grep '^n = ')"
    if [ "$got" = "n = 1" ]; then
        echo "ok: the check script of $doc prints n = 1"
    else
        echo "FAIL: the check script of $doc printed: $got"
        fail=1
    fi
done
exit $fail
