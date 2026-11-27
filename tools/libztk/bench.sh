#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs start.py and widgets.py 5 times each in a private Xvfb, on libztk
# or, with the argument "tk", on the Tk of the system. Prints each time
# and the largest resident set. docs/python-tkinter.md has the medians.
# Use: tools/libztk/bench.sh LIBDIR|tk
set -u
here="$(cd "$(dirname "$0")" && pwd)"
command -v xvfb-run >/dev/null 2>&1 || { echo "SKIP: xvfb-run is not on the path"; exit 77; }
runs='for i in 1 2 3 4 5; do python3 -I "$0/start.py"; done; for i in 1 2 3 4 5; do python3 -I "$0/widgets.py" --exit; done'
if [ "$1" = tk ]; then
    env -u WAYLAND_DISPLAY xvfb-run -a sh -c "$runs" "$here" 2>&1
else
    env -u WAYLAND_DISPLAY LD_LIBRARY_PATH="$1" xvfb-run -a sh -c "$runs" "$here" 2>&1
fi
