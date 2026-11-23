#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Fails when a tracked file or a file name has a local path or the name
# of an AI model or vendor. The name list is base64, so that this script
# does not match its own pattern.
# Use: sh tools/check-repo.sh
set -eu
cd "$(dirname "$0")/.."
names=$(printf %s 'Y2xhdWRlfGFudGhyb3BpY3xmYWJsZXxvcHVzfHNvbm5ldHxoYWlrdXxvcGVuYWl8Y2hhdGdwdHxncHQtP1swLTldfGdlbWluaXxjb3BpbG90fGNvZGV4fGxsYW1hfG1pc3RyYWx8ZGVlcHNlZWt8cXdlbnxncm9r' | base64 -d)
paths='/(home|Users)/[A-Za-z0-9_.-]+|[A-Za-z]:\\Users\\'
rc=0
if git grep -nIE "$paths"; then
    echo "error: a tracked file has a local path" >&2
    rc=1
fi
if git grep -nIiE "\b($names)\b"; then
    echo "error: a tracked file names an AI model or vendor" >&2
    rc=1
fi
if git ls-files | grep -iE "\b($names)\b"; then
    echo "error: a file name has an AI model or vendor" >&2
    rc=1
fi
[ "$rc" -eq 0 ] && echo "check-repo: no local path and no restricted name"
exit "$rc"
