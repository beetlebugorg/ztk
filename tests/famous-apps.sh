#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs the famous Tcl/Tk apps of tests/apps on the headless backend: the
# widget demo of Tk, tkcon, the BWidget demo, the Tablelist demos, the
# tklib examples, and gitk. Each script drives its app with ztk::inject
# and prints "ok" or "FAIL" for each check. tools/fetch-apps.sh downloads
# the pinned releases first. docs/dev/apps.md has the table of results.
# Use: tests/famous-apps.sh [shots folder]      (after: zig build)
# Exit status: 0 pass, 1 fail, 77 when ztk is not built.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="$root/zig-out/bin/ztk"
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
"$root/tools/fetch-apps.sh" > /dev/null || exit 1
src="$root/.apps-src"
shots="${1:-}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/home"
fail=0
# One app run: a name for the report, then the script and its arguments.
run() {
    name="$1"
    shift
    echo "== $name"
    (cd "$work" && HOME="$work/home" timeout 300 "$ztk" --headless --windowingsystem x11 \
        --allow package,clock,event,env,exec,interp "$@" > "$work/out" 2>&1)
    code=$?
    grep -v '^frames: \|slow frame' "$work/out"
    if [ "$code" -ne 0 ] || ! grep -q '^fails: 0$' "$work/out"; then
        echo "FAIL: $name (status $code)"
        fail=1
    fi
}
apps="$root/tests/apps"
run "Tk widget demo" "$apps/tk-widget.tcl" "$src/tk/tk8.6.16" "$shots"
run "tkcon" "$apps/tkcon.tcl" "$src/tkcon/tkcon-2.5" "$shots"
run "BWidget demo" "$apps/bwidget.tcl" "$src/bwidget/bwidget-1.10.1" "$shots"
for demo in dirViewer styles embeddedWindows config browse browseTree; do
    run "Tablelist $demo" "$apps/tablelist.tcl" "$src/tablelist/tablelist7.12" "$demo" "$shots"
done
run "tklib widgets" "$apps/tklib.tcl" "$src/tklib/tklib-0.9" widgets "$shots"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
    run "tklib plotdemos$n" "$apps/tklib.tcl" "$src/tklib/tklib-0.9" "plotchart/plotdemos$n.tcl" "$shots"
done
rm -rf "$work/repo" && mkdir "$work/repo"
run "gitk" "$apps/gitk.tcl" "$src/git/git-2.56.0" "$work/repo" "$shots"
exit "$fail"
