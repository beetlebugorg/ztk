#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Builds the test library tests/elf/tls.c with zig cc for a glibc target
# and runs the ELF loader tests of a static (musl) build with it. A foreign
# target runs in qemu (-fqemu).
# Use: tests/elf-tls.sh [arch]   (default: the arch of this machine)
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
arch="${1:-$(uname -m)}"
dir="$(mktemp -d /tmp/ztkelf.XXXX)"
trap 'rm -rf "$dir"' EXIT
# On x86-64, -mtls-dialect=gnu2 gives TLS descriptors (R_X86_64_TLSDESC), as Mesa uses them.
dialect=""
[ "$arch" = x86_64 ] && dialect="-mtls-dialect=gnu2"
zig cc -target "$arch-linux-gnu" -shared -fPIC -O1 $dialect -o "$dir/libztktls.so.1" "$root/tests/elf/tls.c"
qemu=""
[ "$arch" = "$(uname -m)" ] || qemu="-fqemu"
cd "$root"
status=0
LD_LIBRARY_PATH="$dir" zig build test -Dtarget="$arch-linux-musl" $qemu -Dtest-filter=elf --summary all >"$dir/log" 2>&1 || status=$?
grep -E 'tests passed|failed|error|elf:' "$dir/log" || true
exit "$status"
