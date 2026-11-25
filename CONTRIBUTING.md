# Contributing

ztk is experimental. Open an issue before a large change.

1. Read [WRITING.md](WRITING.md), [AGENTS.md](AGENTS.md), and [the plan](docs/dev/plan.md).
2. When the repository has a `build.zig`, run `zig build test` with Zig 0.16.0. The tests must pass.
3. Run `sh tools/check-repo.sh` and `python3 tools/build-docs.py site`.
4. Open a PR. PRs merge by rebase.

Contributions are licensed under BSD-2-Clause. Do not submit code copied from Tk or from a project with a GPL, LGPL, or AGPL license. Credit each source in [the references](docs/references/README.md).
