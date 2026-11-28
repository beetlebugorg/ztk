# Install

## With Homebrew

```sh
brew install beetlebugorg/tap/ztk
```

Homebrew installs the `ztk` program on macOS and Linux (arm64 and x86-64) from the release binaries.

## In the browser

The quickest way to try ztk is the [playground](https://beetlebug.org/ztk/play/index.html). It runs each example, and you can edit the script.

For your own page, install the npm package. [On the web](web.md) has the API.

```sh
npm install @beetlebug/ztk
```

## Build from source

Use the build from source to get a window on the Linux desktop. Install [Zig 0.17.0](https://ziglang.org/download/). On Linux the default build also needs `glslc`. The Wayland backend links no library, so the static Linux programs of a release open a window too.

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
| `--windowingsystem NAME` | Sets the result of `tk windowingsystem`: `x11`, `win32`, `aqua`, or `ztk` (the default). A Tk app that tests for `x11`, `win32`, or `aqua` can then choose its path. The look of ztk does not change. |
| `--allow a,b` | Turns on more capabilities of ztcl, with the names of the `ztcl` runner: `package`, `interp`, `clock`, `event`, `socket`, `exec`, `random`, `env`, `sqlite`, and `thread`. `hotkey` lets `ztk::hotkey` add global shortcuts. |
| `--root DIR` | Keeps the file commands in one folder, which a script sees as `/`. With no `--root`, they use the real paths of the host. |
| `--cpu` | Uses the CPU renderer on Wayland, as `ZTK_RENDERER=cpu` does. |

On Wayland, ztk renders the main window with Vulkan into dma-bufs when the GPU and the compositor share them (`zwp_linux_dmabuf_v1` with linear XBGR8888), and else with the CPU renderer into shared memory. With the CPU renderer, ztk writes the cause to stderr once, for example `ztk: the CPU renderer: the compositor has no zwp_linux_dmabuf_v1 version 3`. `ZTK_RENDERER=cpu` selects the CPU renderer, and `ZTK_RENDERER=vulkan` makes ztk exit when it cannot use Vulkan. Menus and other popups use the CPU renderer.

`ZTK_NO_ANIMATION=1` turns the animations off and shows each end state at once. The program gives a script the file commands and the file channels of ztcl (`file`, `open`, `read`, `puts` to a file) by default, with the real paths of the host, as in `wish`. A relative path counts from the current folder. `--root DIR` keeps the file commands in one folder, which a script sees as `/`. The other host access (`socket`, `exec`, and the others) needs `--allow`. `ztk::style load` reads style sheets from the folder of the script.

## An app in one file

`ztk bundle` with an output name that has no `.app` writes one program file: a copy of the `ztk` program with the app in it.

```sh
ztk bundle -o notes notes.tcl lib/ images/
ztk bundle -o notes.exe --target x86_64-windows --runner ztk.exe notes.tcl
```

The first file is the main script. Each file keeps its path relative to the main script, so a script that finds a file next to it in the source folder finds it in the app too. The top folder of the app is the deepest folder that has the main script and each other file and folder. For example, `ztk bundle -o demo examples/demo.tcl examples/demo.css` gives `//zipfs:/app/demo.tcl` and `//zipfs:/app/demo.css`, and `ztk bundle -o notes app/notes.tcl lib/` gives `//zipfs:/app/app/notes.tcl` and `//zipfs:/app/lib/`. `ztk::style load` reads style sheets from the folder of the main script in the app too. `--allow` sets the capabilities of the app, and the default is `file,channels`. The program reads no flag: each word of its command line goes to `$argv`. `ZTK_HEADLESS=1` in the environment runs the app with the headless backend and the CPU renderer, as `--headless` does for `ztk`.

A program file for Windows (`--target x86_64-windows` or `aarch64-windows`, or this computer on Windows) gets the resources of a Windows app: the icon of `--icon` (an `.ico`, or a `.png` of 256 pixels or less), a manifest with per-monitor DPI and version 6 of the common controls, and the version information of `--name` and `--version`, which Explorer shows in the properties of the file. It uses the GUI subsystem, so it opens no console window. Started from a terminal, it writes `puts` and its errors to that terminal. `--console` gives a program with a console window of its own.

`--sign-cert FILE` with `--sign-key FILE` gives a Windows program an Authenticode signature, from any host and with no `signtool`. The certificate file is PEM, with the certificate of the signer first and then the rest of its chain. The key file is PEM with no password, with a P-256, P-384, or RSA key. The signature has no timestamp, so Windows accepts it only while the certificate is valid.

```sh
ztk bundle -o notes.exe --target x86_64-windows --sign-cert signer.pem --sign-key signer-key.pem notes.tcl
```

On Linux, `--desktop` also writes a desktop entry and an icon next to the program file: `ztk bundle -o notes --desktop --name "My Notes" --icon notes.png notes.tcl` gives `notes`, `notes.desktop`, and `notes.png` (256 pixels or less). The entry has `Exec=notes`, so put the program in a folder of `PATH` such as `~/.local/bin`, the entry in `~/.local/share/applications`, and the icon in `~/.local/share/icons/hicolor/256x256/apps`. A bundled program gives its file name as the app id of its Wayland window, so the desktop finds the entry and its icon. A renamed program needs an entry of the new name.

`wm iconphoto` sets the icon of the window on Linux. On X11 the photos go in the property `_NET_WM_ICON`. On Wayland they go to the compositor with the protocol `xdg-toplevel-icon-v1`, and a compositor without the protocol shows the icon of the desktop entry.

With `--target` and an output name that ends in `.app`, the target is `aarch64-macos` or `x86_64-macos`, and `ztk bundle` writes a macOS app folder (see [macOS](macos.md#make-an-app)).

The default target is the computer that runs `ztk bundle`, with the `ztk` program itself as the copy. For another target, give the `ztk` program of that target with `--runner`, or put it in `lib/ztk/runtime/TARGET/` next to the folder of `ztk`. `zig build runtimes` builds the program of each target into `zig-out/lib/ztk/runtime/`, so `zig-out/bin/ztk bundle --target T` finds it. Each one has the full GUI backend of its platform: Wayland, X11, the direct backend, and Vulkan on Linux (a static program), AppKit and Metal on macOS, and Win32 and Direct3D 12 on Windows. `-Druntime-targets=x86_64-linux,aarch64-macos` builds a part of them. The targets are `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows`, and `aarch64-windows`. A macOS file gets an ad hoc signature. The form of the file is the form of `ztcl build` of ztcl.

## A smaller app

`ztk bundle --strip` writes one program file with a ztk program that has only the parts the scripts use. It is the strip mode of `ztcl build` ([Strip a program](https://github.com/beetlebugorg/ztcl/blob/main/docs/strip.md)) with the widget classes of ztk as features too: `text`, `terminal`, `canvas`, `treeview`, and `notebook`. The build scans the scripts, maps each command and `package require` to a feature, and runs `zig build runtimes -Ddrop=...` in the source folder of ztk, into a cache folder.

```sh
ztk bundle --strip --trust-scan -o notes notes.tcl lib/
```

- The source folder is `--src DIR`, or the folder of `ZTK_SRC`, or the folder two levels above the `ztk` program. Zig is `ZIG` or `zig` on the `PATH`.
- A Tk program calls each widget through its path, such as `$w configure`, so the scan finds computed command names in most programs. By default each such site keeps every widget class and command group. `--trust-scan` keeps a class only when a literal word of the scripts names it, such as `canvas` or `ttk::treeview`.
- `--keep LIST`, `--drop-module LIST`, `--check`, `--test FILE`, and `--profile` work as in `ztcl build`. The manifest is `ztk-strip.txt` in the current folder.
- A call of a widget class that the build left out gives the error `command "canvas" is not in this build`, with the flag that keeps it.
- The strip mode writes one program file: an output name with no `.app`.

On x86-64 Linux, the full ztk program is 11,224,360 bytes. With `--strip --trust-scan`, the counter example (`examples/counter.tcl`) is 7,337,022 bytes, and 11,225,390 bytes with the full program. The gallery (`examples/gallery.tcl`) is 7,902,337 bytes, and 11,237,105 bytes with the full program: it keeps `text`, `canvas`, `treeview`, and `notebook`. A test of the counter (the window, one `update`, a click, and `exit`, with `ZTK_HEADLESS=1`) starts in 16.6 ms stripped and in 19.5 ms with the full program, as the mean of 50 runs.

