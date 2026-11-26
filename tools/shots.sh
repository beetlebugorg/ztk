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
for name in demo signin calculator settings dashboard gallery spreadsheet vector themes themes-classic counter; do
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

# The shot of the live snippet of the landing page: docs/site/hero.tcl in
# a window of 360 by 240 logical pixels, as widget-hero-light.png and
# widget-hero-dark.png.
hero="$(mktemp)"
trap 'rm -f "$log" "$hero"' EXIT
{ echo 'wm geometry . 360x240'; cat "$root/docs/site/hero.tcl"; echo update; } >"$hero"
for scheme in light dark; do
    flag=""
    [ "$scheme" = dark ] && flag="--dark"
    file="$out/widget-hero-$scheme.png"
    if ! ZTK_NO_ANIMATION=1 timeout 60 "$ztk" --headless $flag --scale 2 \
        --exit-after-frames 2 --screenshot "$file" "$hero" >/dev/null 2>"$log" || grep -qv '^frames: ' "$log"; then
        echo "error: docs/site/hero.tcl failed:" >&2
        cat "$log" >&2
        exit 1
    fi
    echo "wrote $file ($(wc -c <"$file") bytes)"
done

# The shots of the widget pages (docs/dev/widget-pages.md). A line
# `<!-- widget: NAME; shot: SCRIPT -->` in a page of docs/widgets marks
# the next `tcl` block. The shot runs that block in a window of 360 by
# 240 logical pixels, runs SCRIPT, and writes widget-NAME-light.png and
# widget-NAME-dark.png.
snippet="$(mktemp)"
trap 'rm -f "$log" "$hero" "$snippet"' EXIT
for page in "$root"/docs/widgets/*.md; do
    grep -o '<!-- widget: [a-z0-9-]*' "$page" | sed 's/<!-- widget: //' | while read -r name; do
        {
            echo 'wm geometry . 360x240'
            awk -v name="$name" '
                index($0, "<!-- widget: " name ";") == 1 { on = 1; shot = $0; sub(/.*shot: /, "", shot); sub(/ -->.*/, "", shot); next }
                on == 1 && /^```tcl/ { on = 2; next }
                on == 2 && /^```/ { print "update"; print shot; exit }
                on == 2 { print }
            ' "$page"
        } >"$snippet"
        for scheme in light dark; do
            flag=""
            [ "$scheme" = dark ] && flag="--dark"
            file="$out/widget-$name-$scheme.png"
            if ! ZTK_NO_ANIMATION=1 timeout 60 "$ztk" --headless $flag --scale 2 \
                --exit-after-frames 2 --screenshot "$file" "$snippet" >/dev/null 2>"$log" || grep -qv '^frames: ' "$log"; then
                echo "error: the widget $name of $page failed:" >&2
                cat "$log" >&2
                exit 1
            fi
            echo "wrote $file ($(wc -c <"$file") bytes)"
        done
    done
done
