# Architecture: the module map and the layout of src/

This page has the map of the modules of `src/` by area, the target layout by folder, the rules of the layers, and the place of a new feature. Issue #304 has the findings and the plan of the moves. Phase 1 moves no file. The layout below is a target, and the moves of phase 2 make it true one area at a time.

## The tool

`tools/modmap.zig` reads each `.zig` file below `src/` and prints the map in Markdown. The areas file `tools/modmap.areas` gives the area of each file and the rules of the layers. The tool is the same file as `tools/modmap.zig` of ztcl.

```sh
zig run tools/modmap.zig -- --dot zig-out/modmap.dot --area-dot zig-out/modmap-areas.dot > zig-out/modmap.md
zig run tools/modmap.zig -- --only summary,areas,cycles,layers
zig test tools/modmap.zig
```

The report has these sections: `summary`, `areas`, `cycles`, `layers`, `unmapped`, `deadfiles`, `deadfns`, `dups`, and `map`. The `map` section gives the lines, the test blocks, the imports, the importers, and the test files of each file. The top of `tools/modmap.zig` has the method of each section and the format of the areas file. An import of the module `ztcl` is an external module, and the report lists it with the other modules of the build.

The CI job `Module map` runs the tool on each push and each pull request. It writes the summary to the page of the run and keeps the full report and the DOT files as the artifact `modmap`. The job is a report: a layering break does not fail it. A later PR makes the layer rules a check (phase 2 of #304).

Give a new file an area in `tools/modmap.areas` in the same PR. The section `unmapped` of the report lists each file with no area.

## The map today

The command `zig run tools/modmap.zig` gave these counts on main at `e8a3363` on 2026-11-27. The counts depend only on the files, so each machine gives the same counts.

| Item | Count |
|---|---|
| Files | 245 |
| Lines | 93,444 |
| Test blocks | 811 |
| Imports between files | 1,344 |
| Cycles (components of 2 or more files) | 5 |
| Layering breaks | 46 |
| Files that no build root reaches | 0 |

| Area | Files | Lines | What it owns |
|---|---|---|---|
| base | 8 | 2,365 | Types with no widget: points, sizes, and colors, checked numbers, the backend `Event`, key symbols, easing, PNG and GIF, and the color names of Tk. |
| sys | 6 | 3,545 | The host: COM, Objective-C, the Linux calls, and the ELF loader of a static program. |
| text | 7 | 2,093 | Fonts, TrueType, shaping, the glyph atlas, rasterization, and text editing. |
| style | 5 | 1,329 | The CSS tokenizer, the parser, the values, the color table, and the selectors. |
| scene | 2 | 752 | The scene: a flat list of quads in paint order, and the shapes that a quad has no kind for. |
| render | 9 | 3,177 | One renderer for each GPU API (Vulkan, Direct3D 12, Metal) and the CPU renderer, with the render thread. |
| iface | 1 | 711 | `platform/platform.zig`: the one interface of each backend. |
| core | 23 | 11,175 | The App, the widget tree, options and the option database, the computed style and its animations, events and bindings, the focus, grabs, the geometry managers, scrolling, the loop, images, and the paint helpers. |
| platform | 45 | 21,916 | The backends: Wayland, X11, the direct backend on DRM and evdev, AppKit, Win32, and the headless backend. |
| widgets | 28 | 14,310 | The classic widgets of Tk, with the text widget and its buffer. |
| ttk | 6 | 4,740 | The themed widgets and the `ttk::style` command. |
| canvas | 4 | 3,612 | The canvas widget and its items. |
| terminal | 4 | 1,570 | The terminal widget. |
| cmds | 13 | 2,347 | The registration of the commands, `wm`, `font`, `clipboard`, the dialogs, and the commands of the desktop: tray, taskbar, hotkeys, drops, recent documents. |
| debug | 6 | 1,706 | `ztk::debug`, `ztk::inject`, `ztk::snapshot`, and the checks after a frame. |
| bundle | 4 | 1,899 | `ztk bundle`: the app file, the macOS app folder, its signature, and the Windows resources. |
| api | 3 | 1,143 | The roots: `ztk.zig`, `main.zig`, and `web.zig`. |
| tests | 71 | 15,054 | `src/tests/` and the test harness `testing.zig`. |

The import graph has one large cycle of 75 files. `app.zig` imports the command files (`cmds.zig`, `wm.zig`, `clipboard.zig`, and others), some widgets, and `ttk/style.zig`, and each of those imports `app.zig`. The other four cycles have two files each: `text/font.zig` and `text/system.zig`, `scene.zig` and `text/atlas.zig`, `text_widget/buffer.zig` and `text_widget/tags.zig`, and `platform/vkdisplay.zig` and `ztk.zig`.

## The target layout

Each area is one folder. Phase 2 of #304 makes each move in a move-only PR.

| Folder | Area | Files today |
|---|---|---|
| `src/` | api | `ztk.zig`, `main.zig`, `web.zig` |
| `src/base/` | base | `geom.zig`, `num.zig`, `event.zig`, `keysym.zig`, `easing.zig`, `png.zig`, `gif.zig`, `tkcolors.zig` |
| `src/core/` | core | `app.zig`, `widget.zig`, `options.zig`, `optiondb.zig`, `varlink.zig`, `dispatch.zig`, `bind.zig`, `focus.zig`, `grab.zig`, `loop.zig`, `scroll.zig`, `compact.zig`, `stats.zig`, `image.zig`, `animate.zig`, `anim.zig`, `style.zig`, `textinput.zig`, `paint.zig` |
| `src/core/layout/` | core | `layout.zig`, `pack.zig`, `place.zig`, `grid.zig` |
| `src/css/` | style | `css/` with no change |
| `src/scene/` | scene | `scene.zig`, `path.zig` |
| `src/render/` | render | `render/` with no change |
| `src/text/` | text | `text/` with no change |
| `src/sys/` | sys | `sys/` with no change |
| `src/platform/` | iface, platform | `platform.zig` and `headless.zig` |
| `src/platform/linux/` | platform | `wayland.zig`, `wl/`, `x11.zig`, `direct.zig`, `direct_off.zig`, `vkdisplay.zig`, `evdev.zig`, `fbdev.zig`, `touch.zig`, `keymap.zig`, `console.zig`, `console_off.zig`, `dbus.zig`, `portal.zig`, `sni.zig` |
| `src/platform/macos/` | platform | `appkit.zig`, `coretext.zig`, `mac*.zig`, `nsmenu.zig`, `pasteboard.zig` |
| `src/platform/windows/` | platform | `win32.zig`, `windows.zig`, `win*.zig`, `dwrite.zig`, `tsf.zig` |
| `src/widgets/` | widgets | `widgets/` with no change |
| `src/widgets/text/` | widgets | `text_widget/` |
| `src/ttk/` | ttk | `ttk/` with no change |
| `src/canvas/` | canvas | `canvas/` with no change |
| `src/terminal/` | terminal | `term/` |
| `src/cmds/` | cmds | `cmds.zig`, `wm.zig`, `fontcmd.zig`, `clipboard.zig`, `dnd.zig`, `filedialog.zig`, `dialogs.zig`, `hotkey.zig`, `tray.zig`, `taskbar.zig`, `recent.zig`, `macapi.zig`, `winapi.zig` |
| `src/debug/` | debug | `debug.zig`, `debugdiff.zig`, `debugtrace.zig`, `checks.zig`, `inject.zig`, `snapshot.zig` |
| `src/bundle/` | bundle | `bundle.zig`, `appbin.zig`, `machosign.zig`, `peres.zig` |
| `src/tests/` | tests | `testing.zig`, and the tests of two or more modules (`review*.zig`, `stress.zig`, `demo.zig`, `lifetime.zig`) |

A test file of `src/tests/` with the tests of one module moves beside that module in the last batch of phase 2, for example `tests/grid.zig` to `core/layout/grid_tests.zig`.

The draft of #304 had the areas core, widgets/, ttk/, render/, platform/, text/, and terminal/. The graph gives four more layers. `base/` has the types that the renderers, the backends, and the core all use, and imports no other area. `scene/` is below `render/`, and `render/` is below `core/`. `iface` is the one file `platform/platform.zig`: the core and the widgets import it, and only `api` imports a backend. The computed style (`style.zig`, `anim.zig`) imports `widget.zig` and `app.zig`, and `app.zig` imports it, so the computed style is in core. The CSS parser imports no widget, except `css/select.zig`, so it stays a separate area.

## The rules of the layers

`tools/modmap.areas` has these rules as `area` lines. The section `layers` of the report lists each import that breaks one.

1. `base/` imports no other area.
2. `sys/` imports only `base/`.
3. `text/` imports `base/` and `sys/`. `css/` imports `base/`. `scene/` imports `base/` and `text/`.
4. `render/` imports `base/`, `sys/`, `text/`, and `scene/` only.
5. `core/` imports no widget, no command file, no backend, and no file of `debug/`. It uses the backend through `platform/platform.zig` only.
6. Platform code stays behind the one interface `platform/platform.zig`. Only the roots (`main.zig`, `web.zig`, `ztk.zig`) import a backend. A file of one OS stays in the folder of that OS.
7. `widgets/`, `ttk/`, `canvas/`, and `terminal/` are above `core/`, in that order. A classic widget does not import `ttk/`.
8. `cmds/` registers the commands and can import each widget area. A widget does not import a command file.
9. Nothing in `src/` imports an api root (`ztk.zig`), except the other roots.
10. No import cycle between two areas.
11. A test goes in the `test` blocks of its module or in `NAME_tests.zig` beside it. `src/tests/` has the tests of two or more modules.

Some breaks need new code: an import of `app.zig` to a command file or to a widget is a call that a registry above core can make, and the calls of `core/` to `debug.zig` can go through a hook interface in `core/`. Phase 3 of #304 has those changes.

## File size

Keep a file under about 2,000 lines. Split a larger file by concern, with one concern in each file. Generated tables have no limit, such as `platform/wl/keysyms.zig` (3,596 lines). Two files are above the limit today: `canvas/canvas.zig` (2,677 lines) and `platform/wayland.zig` (2,197 lines). A split of `canvas.zig` follows its sections: the size and the view (317 to 988), the subcommands (989 to 1,531), scrolling (1,532 to 1,726), window items (1,727 to 1,987), the painter (1,988 to 2,378), and the animations of items (2,379 to the end).

A method of a struct can live in another file. Write the function with the struct as its first parameter and add `pub const name = @import("file.zig").name;` in the struct. Calls such as `app.handleEvent(ev)` then stay the same.

The three largest files of the top of `src/` are below the limit. Each split below is a PR of its own after the moves of its area, with no change of behavior. The line numbers are of main at `e8a3363`.

### `style.zig` (1,367 lines)

| New file | Lines today | Concern |
|---|---|---|
| `core/style/types.zig` | 1 to 204 | `Origin`, `TransSpec`, `Relief`, `AnimationSpec`, `Env`, `Explained`, the order of the matches, and `sanitize`. |
| `core/style/set.zig` | 205 to 585 | `StyleSet`: the sheets, the rules, and the cascade. |
| `core/style/options.zig` | 586 to 662 | `parsePadding` and `applyOptions`: the widget options over the style. |
| `core/style/compute.zig` | 663 to 1,264 | `Ctx`: the computed value of each property. |
| `cmds/style.zig` | 1,265 to the end | The commands `ztk::style` and `ztk::class`. |

### `app.zig` (1,263 lines)

| New file | Lines today | Concern |
|---|---|---|
| `core/app.zig` | 1 to 499 | `Options`, `Top`, the fields of `App`, `init`, the render thread, and `of`. |
| `core/restyle.zig` | 500 to 594 | `ensureStyle`, `markAllStyle`, and `restyleNode`. |
| `core/windows.zig` | 595 to 679 | The platform windows of the toplevels: `winOf`, `topOfWindow`, and `setWindowSize`. |
| `core/frame.zig` | 680 to 1,046 | The paint of a frame, drag gains, compaction, and the last scene. |
| `core/run.zig` | 1,047 to the end | `handleEvent`, the pass of the loop, `runScript`, and background errors. |

The imports of command files and widgets at lines 13 to 240 go to the registry of `cmds/` (phase 3).

### `grid.zig` (1,182 lines)

| New file | Lines today | Concern |
|---|---|---|
| `core/layout/grid_solve.zig` | 1 to 298 | The solver of one axis: `Cell`, `Item`, `spread`, `solve`, and `shrink`. It has no Tcl and no widget. |
| `core/layout/grid.zig` | 299 to 556 | The container, the layout of a widget, `measure`, and the release of a cell. |
| `core/layout/grid_cmd.zig` | 557 to the end | The command `grid` and its subcommands. |

## Names

- A file name is a noun in snake case for the one thing that the file owns, such as `grid.zig` or `scene.zig`.
- In a folder, the command of a module goes in `cmd.zig` or `NAME_cmd.zig`. Today the top of `src/` has `fontcmd.zig`. After the moves, it is `cmds/font.zig`.
- A file of one OS goes in `platform/linux/`, `platform/macos/`, or `platform/windows/`. The prefixes `mac` and `win` then have no meaning, and new files in those folders do not use them.
- A form for a build with a feature off ends in `_off`, as `render/vulkan_off.zig` does.
- A test file is `NAME_tests.zig` beside its module.
- A file name does not repeat the name of its folder: use `debug/diff.zig` in place of `debug/debugdiff.zig` when a move renames it.

## Where a new feature goes

| Feature | Folder |
|---|---|
| A classic widget of Tk | `widgets/`, with its section in `docs/widgets/` and a line in `docs/differences.md` |
| A themed widget | `ttk/` |
| A canvas item | `canvas/` |
| A geometry manager or a change to layout | `core/layout/` |
| A CSS property or a theme value | `css/` and `core/style.zig` |
| A command of Tk or of `ztk::` on the core | `cmds/` |
| A desktop feature of one OS | the backend in `platform/OS/`, a function in `platform/platform.zig`, and its command in `cmds/` |
| A GPU API | `render/` |
| Fonts and shaping | `text/` |
| A debugger answer or a check | `debug/` |
| A format of `ztk bundle` | `bundle/` |
| A test of one module | the module's own `test` blocks or `NAME_tests.zig` beside it |

Add the file to `tools/modmap.areas` and check the section `layers` of the report before the PR.
