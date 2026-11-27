# CI times

This file records the wall times of the CI workflow (`.github/workflows/ci.yml`) for pull requests, before and after each change of ztcl issue #270. The wall time of a pull request is the time from the start of the run to the end of its last job. It includes the time that jobs wait for a free runner.

## Before (2026-11-26)

Runs of three pull requests, in minutes:

| Job | debug-inspect (code) | wayland-wire (code) | gitattributes-lf (repository files) |
|---|---|---|---|
| Test (Linux) | 3.5 | 2.6 | 3.6 |
| WebAssembly | 2.4 | 1.5 | 1.6 |
| Build (aarch64-linux-musl) | 5.2 | 5.1 | 3.3 |
| Build (x86_64-macos) | 4.8 | 2.0 | 3.5 |
| Build (x86_64-windows) | 3.7 | 3.5 | 3.1 |
| Build (aarch64-macos) | 3.2 | 3.3 | 3.3 |
| Build (x86_64-linux-musl) | 1.7 | 0.6 | 0.9 |
| Run wall time | 10.0 | 7.7 | 5.8 |

Facts from these runs:

- A pull request ran 10 jobs. The account runs a limited number of jobs at the same time for all its repositories, so jobs wait for a runner when many pull requests are open. The wall time of debug-inspect was 10.0 minutes, and its slowest job took 5.2 minutes.
- `mlugg/setup-zig` caches the Zig toolchain and the Zig cache. The Actions cache of the repository is at its limit of 10 GB, so GitHub deletes the oldest caches first.
- The concurrency group cancelled old runs for each event. A push to main cancelled the run of the push before it and the scheduled full run.

## Changes

1. Pull requests build two cross targets (aarch64-macos and x86_64-windows) in place of five. The scheduled run builds all five. The Test job builds the program and the tests with one `zig build`. Runs on main and the scheduled run are no longer cancelled by a later push.

## After

| Change | Pull request | Slowest job | Run wall time |
|---|---|---|---|
| 1 (two cross targets, one `zig build`) | #245 (CI files) | Build (aarch64-macos) and Build (x86_64-windows), 4.0 | 4.5 |

The #245 run had 6 jobs that ran, in place of 10.
