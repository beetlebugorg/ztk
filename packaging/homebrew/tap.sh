#!/bin/sh
# Writes Formula/ztk.rb for a version into a checkout of the tap
# (beetlebugorg/homebrew-tap). The release workflow runs this script.
#
#   packaging/homebrew/tap.sh <version> <dist folder> <tap folder>
#
# The version is the tag with no v (0.1.0-alpha). The dist folder has
# the archives of the release.
# SPDX-License-Identifier: BSD-2-Clause
set -eu

version=${1:?usage: tap.sh <version> <dist> <tap>}
dist=${2:?usage: tap.sh <version> <dist> <tap>}
tap=${3:?usage: tap.sh <version> <dist> <tap>}
repo=${GITHUB_REPOSITORY:-beetlebugorg/ztk}
here=$(dirname "$0")
releases="https://github.com/$repo/releases/download/v$version"

sha() { sha256sum "$dist/ztk-$version-$1.tar.gz" | cut -d' ' -f1; }

mkdir -p "$tap/Formula"
sed -e "s|@VERSION@|$version|g" \
    -e "s|@RELEASES@|$releases|g" \
    -e "s|@SHA_AARCH64_MACOS@|$(sha aarch64-macos)|" \
    -e "s|@SHA_X86_64_MACOS@|$(sha x86_64-macos)|" \
    -e "s|@SHA_AARCH64_LINUX@|$(sha aarch64-linux-musl)|" \
    -e "s|@SHA_X86_64_LINUX@|$(sha x86_64-linux-musl)|" \
    "$here/ztk.rb.in" > "$tap/Formula/ztk.rb"
