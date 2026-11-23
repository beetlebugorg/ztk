#!/bin/sh
# SPDX-License-Identifier: BSD-2-Clause
# Builds the release archives of ztk into a folder.
# Use: tools/release-build.sh <version> <dist folder>
# The version is the tag with no v (0.1.0-alpha).
set -eu
version=${1:?usage: release-build.sh <version> <dist>}
dist=${2:?usage: release-build.sh <version> <dist>}
cd "$(dirname "$0")/.."

if [ ! -f build.zig ]; then
    echo "error: the repository has no build.zig" >&2
    exit 1
fi
if ! grep -q "\.version = \"$version\"" build.zig.zon; then
    echo "error: the version in build.zig.zon is not $version" >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$dist"
options=$(zig build -h)

# Prints the build flags for a target, if the build has the options.
flags() {
    case "$1" in
        *linux*) backends=direct,headless ;;
        *) backends=headless ;;
    esac
    case "$options" in *-Dbackends*) printf ' -Dbackends=%s' "$backends" ;; esac
    case "$options" in *-Dvulkan*) printf ' -Dvulkan=false' ;; esac
    # Debug sections have the paths of the build machine.
    case "$options" in *-Dstrip*) printf ' -Dstrip=true' ;; esac
}

ztcl_dir=$(ls -d zig-pkg/ztcl-* 2>/dev/null | head -n 1)
if [ -z "$ztcl_dir" ] || [ ! -f "$ztcl_dir/LICENSE" ]; then
    echo "error: the ztcl package has no LICENSE in zig-pkg" >&2
    exit 1
fi

for t in x86_64-linux-musl aarch64-linux-musl x86_64-macos aarch64-macos x86_64-windows; do
    # shellcheck disable=SC2046
    zig build -Dtarget="$t" -Doptimize=ReleaseFast --prefix "$work/out/$t" $(flags "$t")
    name="ztk-$version-$t"
    pkg="$work/pkg/$name"
    mkdir -p "$pkg/licenses/ztcl"
    cp LICENSE README.md "$pkg/"
    cp "$ztcl_dir/LICENSE" "$pkg/licenses/ztcl/"
    if [ -d "$ztcl_dir/licenses" ]; then
        cp "$ztcl_dir"/licenses/* "$pkg/licenses/ztcl/"
    fi
    if [ -d licenses ]; then
        cp -r licenses/. "$pkg/licenses/"
    fi
    if [ -d assets/fonts ]; then
        find assets/fonts -name 'LICENSE*' -exec cp {} "$pkg/licenses/" \;
    fi
    case "$t" in
        *windows*)
            cp "$work/out/$t/bin/ztk.exe" "$pkg/"
            abs=$(cd "$dist" && pwd)
            (cd "$work/pkg" && zip -qr "$abs/$name.zip" "$name")
            ;;
        *)
            cp "$work/out/$t/bin/ztk" "$pkg/"
            tar -C "$work/pkg" -czf "$dist/$name.tar.gz" "$name"
            ;;
    esac
done
