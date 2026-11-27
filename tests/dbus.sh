#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs the D-Bus tests on a private session bus of dbus-run-session:
# the SASL lines, Hello, a call, a match, and an error reply.
# Use: tests/dbus.sh
# Exit status: 0 passed, 1 failed, 77 when dbus-run-session is missing.
set -u
command -v dbus-run-session >/dev/null 2>&1 || { echo "SKIP: dbus-run-session is not on the path"; exit 77; }
cd "$(dirname "$0")/.."
log="$(mktemp /tmp/ztkdbus.XXXX)"
status=0
dbus-run-session -- sh -c 'ZTK_TEST_BUS="$DBUS_SESSION_BUS_ADDRESS" exec zig build test -Dtest-filter=dbus --summary all' >"$log" 2>&1 || status=$?
grep -E "tests passed|failed|error|skipped" "$log"
rm -f "$log"
exit "$status"
