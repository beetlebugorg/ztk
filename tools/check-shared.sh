#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
#
# Checks the files that ztk shares with ztcl (tools/shared.sha256): each
# copy must have the SHA-256 of that file. With --remote it also fetches
# each file of ztcl at the commit of tools/shared.sha256 and compares it,
# so a copy that differs from ztcl fails. With no flag it needs no
# network.
#
#     sh tools/check-shared.sh [--remote]
set -eu
cd "$(dirname "$0")/.."
list=tools/shared.sha256
commit=$(sed -n 's/^# ztcl commit: *//p' "$list")
fail=0
grep -v '^#' "$list" | while read -r sum path; do
    # sha256sum on Windows marks a binary file with a * before its name.
    path=${path#\*}
    [ -n "$path" ] || continue
    have=$(sha256sum "$path" | cut -d' ' -f1)
    if [ "$have" != "$sum" ]; then
        echo "FAIL $path: SHA-256 $have, and $list has $sum"
        exit 1
    fi
    if [ "${1:-}" = --remote ]; then
        url="https://raw.githubusercontent.com/beetlebugorg/ztcl/$commit/$path"
        theirs=$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)
        if [ "$theirs" != "$sum" ]; then
            echo "FAIL $path: the file of ztcl at $commit has the SHA-256 $theirs"
            exit 1
        fi
    fi
    echo "ok $path"
done || fail=1
exit $fail
