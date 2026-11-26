# FAQ

## Is ztk a drop-in replacement for Tk?

Not yet. ztk has the widgets on [the widgets page](widgets/README.md), and a script that uses only those runs in ztk and in `wish` 8.6. [Differences from Tk](differences.md) lists what is missing.

## Does it use the code of Tk?

No. ztk has no code of Tk, and it links no third-party library. It runs on [ztcl](https://beetlebug.org/ztcl/), a Tcl 8.6 interpreter in Zig. [References](references/README.md) credits Tk and the other sources.

## Can I keep my look of Tk?

Yes. `ztk::style theme classic` or `ttk::style theme use classic` gives the reliefs and the gray of Tk on X11. [Styling and themes](styling.md) shows both themes.

## Which platforms does it run on?

Linux with Wayland, Windows with Win32 and Direct3D 12 ([On Windows](windows.md)), the browser, and a headless backend on Linux, macOS, and Windows. Native windows on macOS (Metal) are planned.

## Why does my script fail with `invalid command name "open"`?

The `ztk` program gives a script no file or network access. A script can read style sheets from its folder with `ztk::style load`. An app that embeds ztk can turn on capabilities of ztcl.

## Does it work with screen readers?

In the browser, ztk keeps a hidden tree of elements with ARIA roles and names over the canvas. Native accessibility is planned.

## Who wrote ztk?

ztk is a project of [beetlebug](https://github.com/beetlebugorg). The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it.

## Where is the roadmap?

The [plan](dev/plan.md#11-stages) has the stages. Report bugs and requests in the [issues](https://github.com/beetlebugorg/ztk/issues).
