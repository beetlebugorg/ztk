# ztk

Tk, rebuilt in Zig. ztk runs Tk scripts on the [ztcl](https://github.com/beetlebugorg/ztcl) interpreter, with a GPU renderer, a modern look from CSS, smooth animation, and a WebAssembly build for the browser.

**Docs and live demos:** https://beetlebug.org/ztk/

![The widget gallery drawn by ztk: buttons, switches, radio buttons, entries, a scale, ttk widgets, and a canvas in cards](docs/site/shots/gallery-light.png)

- **Tk scripts.** The widgets of Tk 8.6, among them `text`, `canvas`, `listbox`, `menu`, `ttk::notebook`, `ttk::treeview`, and the other `ttk` widgets, with `pack`, `grid`, `place`, `bind`, and the option database. Each example also runs in `wish` 8.6, and [well-known Tk apps](docs/apps.md) run with no change.
- **Native on each desktop.** Its own Wayland and X11 clients on Linux, AppKit with Metal on macOS, and Win32 with Direct3D 12 on Windows, with the tray, drag and drop, and the dialogs of each system. `ztk bundle` makes one program for each platform from any host.
- **A modern look.** A stylesheet in a subset of CSS styles each widget, with a dark scheme, transitions, and a classic theme with the look of Tk.
- **Fluid.** A frame with 1,000 widgets uses 0.85 ms of CPU time at the 99th percentile, and a render thread draws animations while the script is busy.
- **On the web.** The same scripts run in the browser with WebGPU, WebGL 2, or a 2D canvas.
- **No third-party library.** ztk uses the platform, ztcl, and the Zig standard library. `ztk::terminal` uses libghostty-vt through ztcl.

## Install

```sh
npm install @beetlebug/ztk     # for the web
```

[Install](docs/install.md) has the release binaries and the build from source.

## Example

```tcl
ttk::label .title -text "Hello from ztk"
ttk::entry .name -textvariable name
ttk::button .greet -text "Greet" -style Accent.TButton -command {set msg "Hello, $name!"}
ttk::label .msg -textvariable msg
pack .title .name .greet .msg -padx 12 -pady 4 -anchor w
ttk::style configure Accent.TButton -foreground white -background #2563eb
```

```sh
ztk hello.tcl
```

## Documentation

- [Quick start](docs/quickstart.md) and [the widgets](docs/widgets/README.md)
- [Styling and themes](docs/styling.md) and [animation](docs/animation.md)
- [On the web](docs/web.md), [On Linux](docs/linux.md), [On macOS](docs/macos.md), [On Windows](docs/windows.md), and [embed in Zig](docs/embedding.md)
- [The ztk:: commands](docs/commands/README.md) and [debugging](docs/debugging.md)
- [Performance](docs/performance.md) and [differences from Tk](docs/differences.md)
- For contributors: [docs/dev/](docs/dev/README.md) has the plan, the task lists, and the reports.

## Status

ztk is experimental, and it is not yet a drop-in Tk. [Differences from Tk](docs/differences.md) lists what is missing, such as `send` and the selections and clipboard of the system. The code and the docs were written largely with AI coding agents, under human direction. Review the code before you depend on it. The [plan](docs/dev/plan.md#11-stages) has the roadmap, and the [issues](https://github.com/beetlebugorg/ztk/issues) take bug reports and requests.

## Contact

Write to [opensource@beetlebug.org](mailto:opensource@beetlebug.org) about ztk. Open an [issue](https://github.com/beetlebugorg/ztk/issues) for a bug or a request, and report a security problem as [SECURITY.md](SECURITY.md) says.

## License

BSD-2-Clause. See [LICENSE](LICENSE). ztk has no code of Tk. [References](docs/references/README.md) credits Tk and the other sources.
