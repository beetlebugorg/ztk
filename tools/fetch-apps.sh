#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Downloads the pinned release archive of each app of tests/apps/pins.txt,
# checks its SHA-256, and unpacks it into .apps-src/NAME. An archive that
# is already unpacked stays. The archives are data: this script runs no
# file of them.
# Use: tools/fetch-apps.sh [name ...]      (no name: all apps)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
dest="$root/.apps-src"
mkdir -p "$dest"
grep -v '^#' "$root/tests/apps/pins.txt" | while read -r name version url sum; do
    [ -n "$name" ] || continue
    if [ $# -gt 0 ]; then
        case " $* " in *" $name "*) ;; *) continue ;; esac
    fi
    if [ -f "$dest/$name/.done" ]; then
        echo "$dest/$name"
        continue
    fi
    rm -rf "$dest/$name"
    mkdir -p "$dest/$name"
    file="$dest/$name.archive"
    curl -sSfL --retry 5 --retry-all-errors -o "$file" "$url"
    got="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$got" != "$sum" ]; then
        echo "fetch-apps: $name $version: the SHA-256 is $got, not $sum" >&2
        rm -f "$file"
        exit 1
    fi
    case "$url" in
        *.zip) (cd "$dest/$name" && unzip -q "$file") ;;
        *.tar.xz) tar -xJf "$file" -C "$dest/$name" ;;
        *) tar -xzf "$file" -C "$dest/$name" ;;
    esac
    rm -f "$file"
    echo "$version" > "$dest/$name/.done"
    echo "$dest/$name"
done
