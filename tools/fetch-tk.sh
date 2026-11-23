#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Downloads one release of the Tk source into the ignored folder
# .tk-src/<tag>. The repository has no copy of Tk.
# Use: tools/fetch-tk.sh [tag]      (default: core-8-6-16)
set -eu
tag="${1:-core-8-6-16}"
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.tk-src/$tag"
if [ -d "$dest/tests" ]; then
    echo "$dest"
    exit 0
fi
mkdir -p "$root/.tk-src"
git clone -q --depth 1 --branch "$tag" -c advice.detachedHead=false \
    https://github.com/tcltk/tk "$dest"
echo "$dest"
