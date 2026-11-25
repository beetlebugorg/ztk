#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Draws the screenshots of the examples for the docs site and the README.
# Each example draws in the light and the dark color scheme at scale 2 on
# the headless backend with the CPU renderer. The program writes the first
# frame with no transitions, so the same build gives the same files.
# Use: tools/shots.sh [output folder]     (after: zig build)
# The default folder is docs/site/shots. The files are NAME-light.png and
# NAME-dark.png for each name in the list below.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/docs/site/shots}"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "error: build ztk first: zig build" >&2; exit 1; }
mkdir -p "$out"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
for name in demo signin calculator settings dashboard gallery; do
    for scheme in light dark; do
        flag=""
        [ "$scheme" = dark ] && flag="--dark"
        file="$out/$name-$scheme.png"
        # A static window draws one frame, so the first frame is the shot.
        if ! ZTK_NO_ANIMATION=1 timeout 60 "$ztk" --headless $flag --scale 2 \
            --exit-after-frames 1 --screenshot "$file" "$root/examples/$name.tcl" >/dev/null 2>"$log"; then
            echo "error: examples/$name.tcl failed:" >&2
            cat "$log" >&2
            exit 1
        fi
        if grep -qv '^frames: ' "$log"; then
            echo "error: examples/$name.tcl printed an error:" >&2
            cat "$log" >&2
            exit 1
        fi
        echo "wrote $file ($(wc -c <"$file") bytes)"
    done
done
