# ztk

An experimental Tk replacement in Zig, on the [ztcl](https://github.com/beetlebugorg/ztcl) interpreter. The plan has a GPU renderer and stylesheets in a subset of CSS.

> [!WARNING]
> **Experimental.** The `main` branch has a plan and no toolkit code yet. ztk has no release, and it is not a drop-in Tk. The plan, the commands, and the behavior can change at any time.

> [!IMPORTANT]
> **AI disclaimer.** The docs, and later the code, are written largely with AI coding agents, under human direction. Review the work before you depend on it. ztk comes with no warranty. See [LICENSE](LICENSE).

**Docs:** https://beetlebug.org/ztk/

## Status

- **Stage 0, the plan.** [The plan](docs/plan.md) has the goal, the architecture, the decisions, the performance targets, the verification strategy, and the stages.
- **Stage 1, the first demo, is in progress.** [The Stage 1 tasks](docs/tasks/README.md) are 21 small tasks. The work is on a development branch, and no task is on `main` yet.
- **No release exists.** The repository has release workflows for later use.
- [The review checklist](docs/review.md) is what a reviewer checks for each task.
- [The size of Tk](docs/tk-size.md) has the measured size of the job.

## Relationship to ztcl

[ztcl](https://github.com/beetlebugorg/ztcl) is a separate project: an experimental Tcl interpreter in Zig. ztk adds the Tk commands to ztcl and uses it as a Zig package. ztk does not change ztcl.

## The goal

These are the long-term goals. ztk does not do these things yet.

A script that runs in `wish` 8.6 runs in ztk with no change. The test files of Tk 8.6.16 measure that.

- The default look is a modern theme from a stylesheet, with one more stylesheet for each platform. A classic theme has the sizes and the colors of Tk.
- A GPU draws each frame. The target is 60 frames in each second.
- ztk runs on Linux, macOS, Windows, and the web. On a Linux device with no display server, it draws directly on the display.
- ztk needs no third-party library on any platform. It uses the interfaces of the platform, ztcl, and the Zig standard library.

## The size of the job

Measured on Tk 8.6.16 (2026-11-23):

| What | Count |
|---|---|
| Manual pages for script commands | 87 |
| Widget classes, classic and `ttk` | 18 and 18 |
| Options of these classes | 542 and 226 |
| Test files | 109 |
| Tests that a real `wish` counted | 10 221 |
| Source lines of Tk | 322 187 |

The plan estimates two and a quarter to three and a half years of work for one engineer, in nine stages after the plan. Stage 1 is the first demo: a Tcl script with `grid`, labels, buttons, and an entry in a styled window on Linux.

## The demo of Stage 1

This script is the target. It also runs in `wish` 8.6.

```tcl
label .title -text "Hello from ztk"
entry .name -textvariable name -width 24
button .greet -text "Greet" -command {set msg "Hello, $name!"}
label .msg -textvariable msg
grid .title -sticky w -padx 12 -pady 6
grid .name .greet -sticky ew -padx 12 -pady 4
grid .msg - -sticky w -padx 12 -pady 6
bind .name <Return> {.greet invoke}
```

```css
Button { border-radius: 6px; padding: 6px 12px; transition: all 120ms }
Button:hover { background: var(--accent); color: var(--accent-fg) }
```

## Documentation

- [The plan](docs/plan.md)
- [The Stage 1 tasks](docs/tasks/README.md)
- [The review checklist](docs/review.md)
- [The size of Tk](docs/tk-size.md)
- [References](docs/references/README.md)
- [Changelog](CHANGELOG.md), [contributing](CONTRIBUTING.md), [security](SECURITY.md), and [releases](docs/release.md)
- [Lessons from Printdeck](docs/references/printdeck.md)
- [Writing rules](WRITING.md) and [agent instructions](AGENTS.md)

## License

ztk is licensed under [BSD-2-Clause](LICENSE). ztk has no code of Tk. It credits Tk and its other sources in [References](docs/references/README.md).
