# Install

## In the browser

The quickest way to try ztk is the [playground](https://beetlebug.org/ztk/play/index.html). It runs each example, and you can edit the script.

For your own page, install the npm package. [On the web](web.md) has the API.

```sh
npm install @beetlebug/ztk
```

## Build from source

Use the build from source to get a window on the Linux desktop. Install [Zig 0.17.0](https://ziglang.org/download/). On Linux the default build also needs `glslc`, the Wayland client library, `wayland-protocols`, and `libxkbcommon`.

```sh
git clone https://github.com/beetlebugorg/ztk
cd ztk
zig build -Doptimize=ReleaseFast      # makes zig-out/bin/ztk
zig-out/bin/ztk examples/gallery.tcl  # opens a window in a Wayland session
```

`zig build test` runs the tests. `zig build wasm` makes the web build in `zig-out/web`.

On Windows, the build has the native Win32 backend with Direct3D 12: [On Windows](windows.md) has the steps and the limits. On macOS, the build has the native AppKit backend with Metal: [On macOS](macos.md) has the steps and how to make an app.

## Release binaries

Each [release](https://github.com/beetlebugorg/ztk/releases) has `ztk` for Linux (x86-64 and arm64), macOS (x86-64 and arm64), and Windows (x86-64). These programs have the headless backend, on Linux also the direct backend, and on Windows also the Win32 backend. With `--headless`, they draw a script to a PNG file:

```sh
ztk --headless --scale 2 --exit-after-frames 1 --screenshot gallery.png examples/gallery.tcl
```

## The ztk program

```
ztk [flags] script.tcl [arguments]
```

| Flag | Use |
|---|---|
| `--headless` | Draws with the CPU renderer and no window. |
| `--screenshot FILE.png` | With `--headless`: writes the last frame at the exit. |
| `--scale N` | With `--headless`: the scale of the window. |
| `--exit-after-frames N` | Exits after N frames. |
| `--dark` | Uses the dark color scheme. |
| `--allow a,b` | Turns on more capabilities of ztcl, with the names of the `ztcl` runner: `package`, `interp`, `clock`, `event`, `socket`, `exec`, `random`, `env`, `sqlite`, and `thread`. `hotkey` lets `ztk::hotkey` add global shortcuts. |
| `--root DIR` | Keeps the file commands in one folder, which a script sees as `/`. With no `--root`, they use the real paths of the host. |
| `--cpu` | Uses the CPU renderer on Wayland. |

`ZTK_NO_ANIMATION=1` turns the animations off and shows each end state at once. The program gives a script the file commands and the file channels of ztcl (`file`, `open`, `read`, `puts` to a file) by default, with the real paths of the host, as in `wish`. A relative path counts from the current folder. `--root DIR` keeps the file commands in one folder, which a script sees as `/`. The other host access (`socket`, `exec`, and the others) needs `--allow`. `ztk::style load` reads style sheets from the folder of the script.
