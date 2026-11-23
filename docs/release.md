# Release process

ztk has no release yet. The first release needs a `build.zig` on `main`.

## Versions

| Tag | GitHub release | Homebrew tap |
|---|---|---|
| `vX.Y.Z` | Release | Updated |
| `vX.Y.Z-beta` | Prerelease | Updated |
| `vX.Y.Z-alpha` | Prerelease | Updated |

## Steps

1. Update `CHANGELOG.md`.
2. Set the version in `build.zig.zon` to the tag with no `v`. The workflow stops if the two differ.
3. Run `zig build test`.
4. Push a tag. `.github/workflows/release.yml` runs.

The workflow runs `tools/release-build.sh`. The script builds `ztk` for Linux (x86_64, aarch64), macOS (x86_64, aarch64), and Windows (x86_64). The workflow publishes the archives and `SHA256SUMS`, then writes `Formula/ztk.rb` in `beetlebugorg/homebrew-tap`.

Each archive has the program, `LICENSE`, `README.md`, and the license files of ztcl and of the bundled font.

## Backends in a release

The Linux archives are static musl programs, and a cross build cannot link the Wayland libraries. When the build has the `-Dbackends` option, the script selects `direct,headless` on Linux and `headless` on macOS and Windows. Review this choice before the first release that has a window backend.

## Debug data in a release

A Zig release build keeps debug sections, and these sections have the paths of the build machine. When the build has a `-Dstrip` option, the script passes `-Dstrip=true`. Add this option to `build.zig` before the first release.

## Secrets

`HOMEBREW_TAP_TOKEN` is a token with write access to `beetlebugorg/homebrew-tap`. Without the secret, the workflow prints a warning, the release stays, and the tap keeps its version.

## Repository settings

The proposed description, website, and topics are in [`.github/repo.md`](../.github/repo.md).
