#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Bundles a script for each target that has a runtime in
# zig-out/lib/ztk/runtime (`zig build runtimes`), and checks that each
# program file has the full GUI backend of its platform:
#   Linux: a static program with Wayland, X11, the direct backend, and
#   Vulkan with dma-bufs.
#   macOS: AppKit and Metal, linked as frameworks, in a program file and
#   in a .app folder.
#   Windows: Win32 and Direct3D 12.
# The check reads the names that each backend has in the file: the
# Wayland interfaces, the X11 atoms, the Vulkan functions, the framework
# paths, and the DLL names.
# Use: tests/bundle-backends.sh [ztk] [target ...]
# Exit status: 0 passed, 1 failed, 77 when no runtime is built.
set -u
root="$(cd "$(dirname "$0")/.." && pwd)"
ztk="${1:-$root/zig-out/bin/ztk}"
[ $# -gt 0 ] && shift
[ -x "$ztk" ] || { echo "SKIP: build ztk first: zig build"; exit 77; }
rtdir="$(dirname "$ztk")/../lib/ztk/runtime"
targets="$*"
[ -n "$targets" ] || targets=$(ls "$rtdir" 2>/dev/null)
[ -n "$targets" ] || { echo "SKIP: no runtime in $rtdir: zig build runtimes"; exit 77; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
printf 'label .l -text hi\npack .l\nafter 100 exit\n' >"$tmp/app.tcl"
fail=0
for t in $targets; do
    case "$t" in
        *windows) out="$tmp/app-$t.exe" ;;
        *) out="$tmp/app-$t" ;;
    esac
    "$ztk" bundle -o "$out" --target "$t" "$tmp/app.tcl" >"$tmp/log" 2>&1 || { cat "$tmp/log"; echo "FAIL: ztk bundle --target $t"; fail=1; continue; }
    files="$out"
    case "$t" in
        *macos)
            "$ztk" bundle -o "$tmp/App-$t.app" --target "$t" "$tmp/app.tcl" >"$tmp/log" 2>&1 || { cat "$tmp/log"; echo "FAIL: ztk bundle -o App.app --target $t"; fail=1; continue; }
            files="$files $tmp/App-$t.app/Contents/MacOS/App-$t"
            ;;
    esac
    for f in $files; do
        python3 -I - "$t" "$f" <<'PY' || fail=1
import struct, sys
target, path = sys.argv[1], sys.argv[2]
data = open(path, "rb").read()
def has(s):
    return s.encode() in data or s.encode("utf-16-le") in data
need = {
    "linux": {
        "Wayland": ["xdg_wm_base", "wl_compositor"],
        "X11": ["_NET_WM_NAME", "WM_DELETE_WINDOW"],
        "direct": ["/dev/fb0"],
        "Vulkan": ["vkCreateInstance", "libvulkan.so.1"],
        "dma-bufs": ["zwp_linux_dmabuf_v1"],
    },
    "macos": {
        "AppKit": ["/System/Library/Frameworks/AppKit.framework/", "NSApplication"],
        "Metal": ["/System/Library/Frameworks/Metal.framework/", "/System/Library/Frameworks/QuartzCore.framework/", "CAMetalLayer"],
    },
    "windows": {
        "Win32": ["CreateWindowExW", "RegisterClassExW"],
        "Direct3D 12": ["d3d12.dll", "dxgi.dll"],
    },
}[target.split("-")[1]]
missing = [f"{b} ({s})" for b, names in need.items() for s in names if not has(s)]
if target.endswith("-linux"):
    # A static program has no PT_INTERP (3) in its program headers.
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    kinds = [struct.unpack_from("<I", data, phoff + i * phentsize)[0] for i in range(phnum)]
    if 3 in kinds:
        missing.append("a static program (it has an interpreter)")
name = path.rsplit("/", 1)[1]
if missing:
    print(f"FAIL: {target} {name}: no " + ", no ".join(missing))
    sys.exit(1)
print(f"PASS: {target} {name}: " + ", ".join(need))
PY
    done
done
exit "$fail"
