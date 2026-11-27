#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Runs the Vulkan tests as a static (musl) program, so the ELF loader
# (src/sys/elf/loader.zig) opens the Vulkan loader and the driver. A run
# that takes more than 600 seconds (the build and the tests) stops, and
# gdb prints the stack of each thread of the test program first.
# Use: tests/static-vulkan.sh
set -u
VK_LOADER_DEBUG=error,warn zig build test -Dtarget="$(uname -m)-linux-musl" -Dtest-filter=vulkan --summary all &
pid=$!
n=0
while kill -0 "$pid" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -gt 600 ]; then
        echo "static-vulkan: no end after 600 s; the stacks:" >&2
        t="$(pgrep -n -f '/test --cache-dir' || true)"
        if [ -n "$t" ]; then
            sudo gdb -p "$t" -batch -ex "thread apply all bt 30" 2>&1 | grep -E "^#|^Thread" | head -300 >&2 || true
            kill -9 "$t" || true
        fi
        kill "$pid" || true
        exit 1
    fi
    sleep 1
done
wait "$pid"
