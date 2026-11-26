# The ztk plan

ztk is a Tk replacement in Zig. It uses the ztcl interpreter. This page is the master plan. [Tasks](tasks/README.md) has the work of Stage 1. [Review](review.md) has the checklist of the reviewer. [The size of Tk](tk-size.md) has the measured counts and the commands that made them. [Lessons from Printdeck](../references/printdeck.md) has what an earlier UI framework of the same author taught.

The repository has no toolkit code yet. Each statement about ztk in this page is a plan.

## 1. Goal

A script that runs in `wish` 8.6 runs in ztk with no change. That is the long-term goal.

- ztk implements the script commands of Tk 8.6: the widgets, the geometry managers, `bind`, `wm`, `winfo`, `font`, `image`, and `ttk`.
- The test files of Tk 8.6.16 measure compatibility, the same way that the test files of Tcl measure ztcl.
- The default look is a modern theme. A CSS stylesheet defines it, with one more stylesheet for each platform.
- A classic theme gives the default sizes, colors, and borders of Tk 8.6 on X11. The compatibility counts use the classic theme.
- A GPU draws each frame. The targets are 60 frames in each second, a fast start, and low memory. Section 7 has the numbers.
- ztk runs on Linux, macOS, Windows, and the web (WebAssembly).
- ztk also runs on a Linux device with no display server. It draws directly on the display: with the GPU through Vulkan when the device has it, and on the CPU to the framebuffer, as Printdeck does, when it does not.
- ztk needs no third-party library on any platform. It uses the interfaces of the platform, ztcl, and the Zig standard library. Section 6 has the rule.

## 2. Non-goals

- **The C API of Tk.** Tk 8.6.16 has 87 manual pages for C functions. A C extension of Tk (for example `Tktable` or `Img`) does not load in ztk.
- **The same pixels as Tk.** The classic theme has the same geometry as Tk where a test checks geometry. The glyph shapes and the anti-aliasing differ.
- **X11 visuals and colormaps.** ztk accepts `-visual`, `-colormap`, and the related `winfo` subcommands, and gives fixed true-color answers.
- **Window embedding** (`-use`, `-container`) and `send`. They stay out of the plan until Stage 9, and Stage 9 can decide to omit them.
- **A copy of Tk code.** ztk has its own code for each algorithm and each default binding. Section 9 gives the rules.
- **Tk 9 before Tk 8.6.** ztcl follows Tcl 8.6.16, so ztk follows Tk 8.6.16. Stage 9 adds the commands of Tk 9.

## 3. The size of Tk

All numbers are from `core-8-6-16` on 2026-11-23. [The size of Tk](tk-size.md) gives the method and the table for each file.

| What | Count |
|---|---|
| Manual pages for script commands (`doc/*.n`) | 87 pages, 25 088 lines |
| Manual pages for C functions (`doc/*.3`), out of scope | 87 pages |
| Global commands that `wish` adds to `tclsh` | 55 |
| Classic widget classes | 18, with 542 options and 174 widget subcommands |
| `ttk` widget classes | 18, with 226 options and 170 widget subcommands |
| Standard options (`options.n`), standard `ttk` options (`ttk_widget.n`) | 42, 16 |
| Canvas item types | 9, with 160 item options |
| Menu entry types | 5, with 73 entry options |
| Text tag options | 27 |
| `wm` subcommands, `winfo` subcommands | 32, 49 |
| `grid`, `pack`, `place` subcommands | 13, 6, 5 |
| Event types of `bind`, `%` fields of `bind` | 28, 32 |
| Predefined virtual events | 32 |
| Default class bindings: classic, `ttk` | 378, 281 |
| Named colors (`colors.n`), key symbols (`keysyms.n`) | 760, 1 615 |
| `ttk` themes on X11, elements of the default theme | 4, 39 |
| Test files | 109 |
| Tests, by a count of `test` lines | 10 080 |
| Tests that a real `wish` 8.6.16 counted | 10 221: 8 781 pass, 1 383 skip, 57 fail |
| Source lines of Tk (C, headers, Objective-C, and Tcl) | 322 187 |

Tk 9.1.0 has 93 manual pages, 119 test files, and 12 016 `test` lines.

The 1 383 skipped tests are mostly for another platform (`win` 336, `nt` 62, `aqua` 29), or they need a test command of the Tk test binary (`testobjconfig` 215, `testImageType` 145, `testwrapper` 54, `testsend` 54), or they need exact X fonts (`fonts` 126).

Three widgets have a large part of the work. The eight `text*.test` files have 1 776 tests, and `text.n` has 2 293 lines. The seven `canv*.test` files have 395 tests, and `canvas.n` has 1 930 lines. The `ttk` files have 505 tests.

## 4. Architecture

```
                         Tcl script
                             |
              ztcl interpreter, with the commands of ztk
                             |
  +------------------------------------------------------------------+
  | widget tree | options | geometry managers | bind | focus         |
  +------------------------------------------------------------------+
  | style system (CSS subset)       | text (font engine, layout)     |
  +------------------------------------------------------------------+
  | paint: widgets to a scene (a list of quads)                      |
  +------------------------------------------------------------------+
  | renderer: CPU | Vulkan | Metal | Direct3D 12 | WebGL 2           |
  +------------------------------------------------------------------+
  | backend: headless | direct | Wayland | X11 | AppKit | Win32 | web |
  +------------------------------------------------------------------+
```

Two threads do the work. The UI thread runs the interpreter, the widget tree, the style, the layout, and the paint, and makes a scene. The render thread draws the scene and shows it. The hand-over is the scene: plain data with no pointer into the widget tree. Decision D23 has the reason.

The core (the widget tree, the layout, the style system, the scene, the text code, and the CPU renderer) is Zig only and links no library. Each backend links only the interfaces of its platform. The same core runs on Linux, macOS, Windows, and the web. A build for a small device has the core and the direct backend, and is one static program.

### 4.1 The ztcl binding

- ztk is a Zig module. `ztk.App.init(gpa, &interp, platform)` adds the commands of Tk to one `ztcl.Interp`.
- Each command is a `ztcl.interp.NativeFn`. The `ctx` field of the `ztcl.interp.Command` holds the `*App` or the `*Widget`.
- Each widget has a command with the name of its path (`.f.ok`). The delete of the widget removes the command.
- ztk keeps all its state in its own allocator. It keeps no `ztcl.Value` after a command returns, because `compact` and `reset` of ztcl make old values invalid.
- A callback script (`-command`, a binding, `after`) runs at the global level. ztk sets `it.frame = &it.global` and `it.ns = ""` for the call and puts them back after it.
- An error in a callback goes to `bgerror`, as in Tk. With no `bgerror` command, ztk writes the error trace to the error output.
- The `ztk` program is the replacement for `wish`. It makes an interpreter, turns on the capabilities that its flags name, and runs a script file.
- The sandbox rules of ztcl stay. The ztk library turns on no capability of ztcl. Only the embedder or the `ztk` program does that.

Section 10 lists what ztk needs from ztcl.

### 4.2 The widget tree

- A widget is one node: a path, a class, a parent, and children in stacking order.
- A class is a table: the option specs, the measure function (the requested size), the paint function, and the widget subcommands.
- An option spec has the option name, the database name, the database class, the type, and the default. One function implements `configure` and `cget` for all classes, with the result forms and the error messages of Tk.
- A toplevel is a widget with a platform window. `.` is the first toplevel.
- Each widget has a set of state bits (hover, pressed, focus, disabled, selected, and the other `ttk` states). The style system reads them.
- Dirty flags drive the work of a frame: style, measure, layout, and paint. A change sets the smallest flag that is correct.

### 4.3 Layout

- Tk has no CSS layout. The geometry managers of Tk place the widgets: `grid`, `pack`, and `place`. ztk implements them from the manual pages and from the behavior of `wish`.
- Each widget has a requested size. A manager reads the requested sizes of its content and sets the requested size of the container, unless `propagate` is off.
- A manager gives each widget a position and a size inside its parent.
- The unit is the logical pixel, as an integer. `winfo width` gives logical pixels.
- CSS gives the box of a widget (padding, border, minimum size) and so changes its requested size. CSS does not place widgets.
- Stage 1 has `grid`. Stage 2 has `pack` and `place`, and the same managers for a canvas, a text widget, and a paned window later.

### 4.4 Events and `bind`

- A backend gives events in one form: pointer motion, button, wheel, key, text, focus, resize, scale change, close request, and frame.
- The dispatcher finds the widget under the pointer, makes `Enter` and `Leave` events, keeps the pointer grab during a button press, and sends key events to the focus widget.
- `bind` keeps a table from a tag and an event pattern to a script. A widget has a list of tags (`bindtags`): its path, its class, its toplevel, and `all`.
- For each tag, the most specific pattern that matches runs. `break` stops the later tags. The rules are in `bind.n`.
- A script gets its `%` fields before it runs.
- The default behavior of a class is a set of bindings on the class tag. Each binding is a short Tcl script that calls a native command in `::ztk::priv`. So `bind Button`, `bindtags`, and `break` work as in Tk.
- `event generate` makes a synthetic event. The tests use it to simulate input.
- Virtual events (`<<Copy>>`) map to key patterns for each platform.
- One pass handles all waiting events and then draws at most one frame. Motion events with no other event between them collapse to the last one. A button, a key, or a text event is never dropped.
- A touch becomes pointer events of button 1. The limits for a tap, a scroll, and a fling are the measured ones of Printdeck.

### 4.5 Focus

- One widget in each toplevel has the focus. `focus`, `focus -force`, `focus -lastfor`, and `-takefocus` follow `focus.n`.
- `Tab` and `Shift-Tab` move the focus in tree order (`tk_focusNext`, `tk_focusPrev`).
- A click gives the focus to a widget whose class binding asks for it.
- Pointer focus (`tk_focusFollowsMouse`) and `grab` are in Stage 2.

### 4.6 The scene and the renderer

- The paint pass writes a scene: a flat list of quads in paint order.
- One quad form draws all things. A quad has a rectangle, a clip rectangle, four corner radii, a fill (one color or a two-color gradient), four border widths, a border color, and a kind. The kinds are: box, shadow, glyph, and image.
- The fragment program computes the distance to a rounded rectangle. That one function gives the corners, the borders, and the soft shadows.
- A glyph quad reads its coverage from an atlas texture.
- The renderer draws the scene with one instanced draw call for each atlas page. A clip is data of the quad, so a clip does not split the batch.
- Colors blend in sRGB space, as CSS does. So a color in a stylesheet looks the same as in a browser.
- The CPU renderer draws the same scene with the same math. It is the reference for the tests, the renderer of the direct backend on a device with no GPU, and the fallback when a machine has no usable GPU.
- A backend that shows CPU images writes only the rows that changed after the last frame. Printdeck measured 22 % of one core of a Raspberry Pi 5 before this rule and an image cache, and 3.5 % after them.
- The render thread draws. The UI thread gives it each scene and never waits for a draw or for the display.
- The scene is data with no pointers. It can go over a connection to another program that draws it (decision D22).
- The scene is retained. ztk paints again only the toplevel that changed. A window with no change draws no frame.
- The frame clock of the backend (the frame callback of Wayland, the display link of macOS) starts each frame. Animations (a CSS transition, the caret) ask for the next frame.

### 4.7 Text

- ztk has its own font engine in Zig. It reads the font file, makes the glyph images, and places the glyphs. It is the same code on all platforms, so a line of text has the same size and the same pixels on all platforms.
- Stage 1 reads TrueType outlines and the kerning of the GPOS table, for left-to-right text. Stage 4 adds CFF outlines, variable fonts, color glyphs, ligatures, and marks.
- Scripts that need complex shaping (for example Arabic and the Indic scripts) can use HarfBuzz as an optional shaper in Stage 4. HarfBuzz reads the font tables itself, so it needs no FreeType. A build with no HarfBuzz still draws these scripts, with no shaping.
- The platform finds the fonts of the system, from Stage 2: Core Text on macOS, DirectWrite on Windows, and the font folders on Linux (with fontconfig at run time when the machine has it). The web build and the direct backend use the fonts in the package and the fonts that the program adds.
- Font fallback: when the font has no glyph for a character, ztk asks the platform for a font that has it.
- Bidirectional text follows UAX #9. Line breaks follow UAX #14. Caret stops follow UAX #29. ztk has its own code for these, and the conformance files of Unicode test them.
- A text layout is cached by its text, its font, and its width.
- The glyph atlas keeps one image for each glyph, size, and quarter-pixel offset.
- Input methods use the protocol of the platform: `text-input-v3` on Wayland, XIM on X11, `NSTextInputClient` on macOS, TSF on Windows, and a hidden input element on the web. ztk draws the preedit text in the widget.

### 4.8 The style system

A stylesheet is a subset of CSS. The widget tree is the document.

| CSS | ztk |
|---|---|
| Type selector `Button` | The class of the widget (`winfo class`). `TButton` is the `ttk` button. |
| `#name` | The last part of the path. `#ok` matches `.f.ok`. |
| `.name` | A style class of the widget. See below. |
| `A B`, `A > B` | The widget tree. |
| `:hover` | The pointer is on the widget. This is the `active` state of `ttk`. |
| `:active` | A button is down on the widget. This is the `pressed` state of `ttk`. |
| `:focus`, `:disabled`, `:checked`, `:read-only`, `:invalid` | The states `focus`, `disabled`, `selected`, `readonly`, `invalid`. |
| `:indeterminate`, `:window-inactive` | The states `alternate` and `background`. |
| `:state(name)` | Each other state, for example `user1`. |
| `::part` | A part of a widget: `::selection`, and later the elements of `ttk` such as `::thumb` and `::trough`. |
| `--name`, `var()` | Variables. They inherit down the tree. |
| `@media` | `prefers-color-scheme`, and `-ztk-platform: linux`, `macos`, `windows`, or `web`. |

The properties are the box and the paint of a widget: `color`, `background`, `border`, `border-radius`, `padding`, `font`, `opacity`, `box-shadow`, `outline`, `min-width`, `min-height`, `transition`, `caret-color`, `cursor`, and `text-align`. The layout properties of CSS (`display`, `position`, `flex`, `grid`, `margin`) are not in the subset, because the geometry managers of Tk do that work.

The cascade has these origins, from the lowest to the highest:

1. The base sheet of ztk.
2. The theme sheet (`modern.css` or `classic.css`).
3. The platform sheet of the theme (`modern-linux.css`).
4. The option database (`option add`), in the priority order of Tk.
5. The settings of `ttk::style configure` and `ttk::style map`.
6. The stylesheets of the application (`ztk::style load`, `ztk::style add`).
7. The options that the script set on the widget (`-background red`).

Inside one origin, the specificity and then the order decide, as in CSS.

How Tk maps onto it:

- A widget option that has a style meaning is a declaration of origin 7. `-background` is `background-color`, `-foreground` is `color`, `-font` is the font properties, `-borderwidth` is `border-width`, and `-padx` and `-pady` are the padding.
- `cget` of an option that the script did not set gives the computed value, in the form of Tk (`#rrggbb`, a font description, a pixel count).
- The `ttk` style name `Accent.TButton` is the type `TButton` with the style class `Accent`. The lookup order of `ttk` (first `Accent.TButton`, then `TButton`, then the root style `.`) is the specificity order of the selectors `TButton.Accent`, `TButton`, and `*`.
- `ttk::style configure TButton -background red` adds the rule `TButton { background-color: red }` to origin 5.
- `ttk::style map TButton -background {active blue}` adds the rule `TButton:hover { background-color: blue }`. The first entry of a map has the highest priority, so ztk writes the entries in reverse order.
- `ttk::style lookup` reads the computed style.
- `ttk::style layout` and `ttk::style element create` change the list of parts of a class. A part is a box inside the widget with its own selector (`TScrollbar::thumb`).
- `ttk::style theme use name` changes the theme sheet. The names `clam`, `alt`, `default`, and `classic` are stylesheets in ztk.
- A classic widget gets style classes with the new command `ztk::class path ?add|remove|set? ?names?`.

The style system computes a style only for a widget with the style flag. A change of state on one widget does not compute the style of its siblings. A change of a variable on `:root` computes all.

### 4.9 Accessibility

- ztk draws its own widgets, so the platform does not see them. ztk gives the platform a tree of accessible nodes: role, name, value, state, bounds, and actions.
- The platform API reads that tree: AT-SPI on Linux, `NSAccessibility` on macOS, UI Automation on Windows, and ARIA elements on the web.
- Each widget class gives its role and its actions. The tree updates when a widget changes.
- Stage 8 has this work. Each widget class has its role from Stage 2, so Stage 8 changes no widget class.

### 4.10 Clipboard, selection, and drag and drop

- `clipboard` and `selection` follow the manual pages. The backend maps them to the platform: the data device of Wayland, the selections of X11, `NSPasteboard`, the clipboard of Windows, and the async clipboard of the web.
- The primary selection exists on Linux only. On other platforms it is private to the process.
- Tk 8.6 has no drag and drop command. ztk adds `ztk::dnd` for files and text from other programs, in Stage 7.

### 4.11 HiDPI

- Layout uses logical pixels. A toplevel has a scale (1, 1.25, 2, and so on).
- The scene has device pixels. The paint pass multiplies by the scale and rounds each box edge to a device pixel.
- Text gets its glyph images at the device size, so text is sharp at each scale.
- `tk scaling` gives the count of logical pixels in one point (1/72 inch). The default is 96/72.
- A toplevel that moves to a monitor with another scale gets a paint, and no layout change.
- On the direct backend, the scale comes from a setting or from the physical size of the panel. Printdeck found that the size of a pixel in millimeters decides if text is readable: text of 12 to 17 pixels was hard to read at 0.13 mm for each pixel.
- A stylesheet can make all text larger with the font size of `:root`. The scene checks run at 1.5 times the font size, so that no label is cut with large text.

### 4.12 Backends

| Platform | Window and input | GPU | Stage |
|---|---|---|---|
| Headless | Memory only, events from the tests | CPU renderer | 1 |
| Linux, Wayland | `libwayland-client`, `xdg-shell`, `libxkbcommon` | Vulkan, or the CPU renderer | 1 |
| Linux, direct | The kernel only: `evdev`, the framebuffer device, own key map | Vulkan on the display (`VK_KHR_display`), or the CPU renderer | 1 |
| Linux, X11 | `libxcb` | Vulkan | 2 |
| macOS | AppKit | Metal | 3 |
| Windows | Win32 | Direct3D 12 | 3 |
| Web | A canvas element, DOM events | WebGL 2 | 3 |
| Remote | A browser that draws the scenes of a ztk program on another machine | The web renderer | 3 |

A backend implements one interface: make and delete a window, set its title and size, wait for events with a timeout, give the time, give the clipboard, and give the surface for the renderer.

The GPU rule has one more part: each platform draws with its own native API and no translation layer between ztk and the driver. That is Vulkan on Linux, Metal on macOS, and Direct3D 12 on Windows. The Metal and Direct3D 12 renderers wait for Stage 3. The rule for each backend is the same on each platform: use the lowest interface that the platform gives to a program, and no library between ztk and it. That is the window system and Vulkan on a Linux desktop, AppKit and Metal on macOS, Win32 and Direct3D 12 on Windows, and the canvas and WebGL 2 in a browser. The direct backend is the same rule for a Linux device with no window system: the kernel and Vulkan. The core, the font engine, the scene, and the CPU renderer are the same code in all of them, and the CPU renderer works behind each backend.

## 5. Decisions

Each decision has the options, the recommendation, and the reason. The user decides the ones with **User** in the last line.

### D1. The Tk version

- Options: Tk 8.6. Tk 9.
- Recommendation: Tk 8.6.16 first.
- Why: ztcl follows Tcl 8.6.16. A machine with `wish` 8.6.16 is the oracle for the tests.

### D2. The dependency on ztcl

- Options: a path to a local copy. A pinned commit from the public repository.
- Recommendation: a pinned commit in `build.zig.zon`. Stage 1 pins the commit of `main` that the task names.
- Why: a build must not depend on a folder outside the repository, and another agent changes the local copy.

### D3. The GPU layer

- Options: (a) one small renderer for each platform API: Vulkan, Metal, Direct3D 12, WebGL 2. (b) `wgpu-native` or Dawn for all platforms. (c) OpenGL ES on all platforms.
- Recommendation: (a).
- Why: the renderer draws one quad form with one shader pair, so each renderer is small. (b) adds a large binary and a second toolchain. (c) is deprecated on macOS.
- Cost: four renderers to keep equal. The CPU reference and the golden images check each one.
- Decision of the user (2026-11-23): each platform uses its own GPU API with no translation layer. Linux uses Vulkan, macOS uses Metal, and Windows uses Direct3D 12. ztk does not use MoltenVK, ANGLE, DXVK, or a Vulkan layer on Direct3D. The Stage 3 renderers for Metal and Direct3D 12 are not built before Stage 3. Stage 1 has the Vulkan renderer and the CPU renderer only.

### D4. One quad form for all drawing

- Options: a path renderer (curves, strokes). A list of rounded boxes and glyphs.
- Recommendation: the list of rounded boxes and glyphs for the widgets. The canvas widget (Stage 5) adds a path stage that makes coverage masks on the CPU and draws them as image quads.
- Why: buttons, entries, and frames are boxes and glyphs. One form gives one draw call and simple tests.

### D5. A CPU reference renderer

- Options: test only on a GPU. Add a CPU renderer.
- Recommendation: add it, in Stage 1, before the Vulkan renderer. It is also a product path: the direct backend uses it on a device with no GPU.
- Why: the test machines have no GPU, and this machine has no software Vulkan driver (checked: only the Intel and NVIDIA drivers are in `/usr/share/vulkan/icd.d`). The CPU renderer gives the same image on each machine. Printdeck shows that a CPU renderer with the changed-rows rule is fast enough for a touch UI on a Raspberry Pi.

### D6. The text engine

- Options: (a) HarfBuzz and FreeType on all platforms. (b) the text stack of each platform (Core Text, DirectWrite, HarfBuzz). (c) a font engine in Zig, with HarfBuzz as an optional shaper for complex scripts.
- Recommendation: (c).
- Why: the direct backend and the web build must have no dependency. One rasterizer gives the same glyph images on each machine, so each golden image is exact. (a) adds two C libraries to each platform. (b) gives a different layout on each platform.
- Cost: the engine is real work. Stage 1 has TrueType outlines and kerning. Stage 4 has CFF outlines, variable fonts, color glyphs, and the layout tables. Until Stage 4, a font that the engine cannot read gives the font of the package.
- Limit: the glyphs do not look exactly like the text of native programs on macOS and Windows, which use the rasterizer of the platform.
- **User:** confirm. This follows the request for no dependency, and it replaces the earlier proposal of HarfBuzz and FreeType.

### D7. Bidi and line breaks

- Options: FriBidi (LGPL-2.1-or-later). ICU (large). Own code from the Unicode annexes.
- Recommendation: own code, in Stage 4.
- Why: the LGPL does not fit a static BSD-2-Clause library. ICU is larger than the rest of ztk. The Unicode conformance files test own code completely.

### D8. Windows on Linux

- Options: Wayland only. X11 only. Both. SDL or GLFW.
- Recommendation: Wayland in Stage 1 and X11 in Stage 2, with the system libraries.
- Why: SDL and GLFW hide the things that Tk needs: the stacking order, the window manager hints of `wm`, the selections, and the input methods.
- Window decorations: ztk asks the compositor for decorations (`xdg-decoration`). When the compositor has none (GNOME), ztk draws its own title bar from Stage 2.

### D9. Where ztk uses native UI

| Thing | Native | Drawn by ztk |
|---|---|---|
| All widgets, including scrollbars | | all platforms |
| Menu bar | macOS | Linux, Windows, web |
| Popup menus | | all platforms |
| File and folder dialogs | macOS, Windows, web, and Linux through the desktop portal | Linux with no portal |
| Message box, color dialog, font dialog | macOS | Linux, Windows, web |
| Window decorations | where the platform gives them | Wayland with no decoration protocol |
| Accessibility tree | all platforms | |
| Input methods, clipboard, drag and drop | all platforms | |
| System tray and notifications (Tk 9) | all platforms | |

Why: the user of a platform knows its file dialog and its menu bar, and the platform enforces them (the sandbox portals, the macOS menu bar). The widgets stay drawn so that one stylesheet styles them.

### D10. The style language

- Options: a new language. The `ttk::style` model only. A CSS subset.
- Recommendation: a CSS subset, with `ttk::style` mapped onto it (section 4.8).
- Why: people and tools know CSS. The cascade gives per-platform sheets and dark mode with no new idea.
- Limit: no layout properties. The stylesheet page of the docs must say that first.

### D11. The CSS names of the states

- Options: the `ttk` names (`:active` is hover). The CSS names (`:hover`, `:active` is pressed).
- Recommendation: the CSS names in stylesheets, and the `ttk` names in `ttk::style map` and `state`.
- Why: a stylesheet that reads as CSS must behave as CSS.

### D12. The unit of `winfo` and `-width`

- Options: device pixels (Tk on X11). Logical pixels (Tk on macOS).
- Recommendation: logical pixels.
- Why: a script with `-width 200` gets the same physical size on each monitor.

### D13. The default class bindings

- Options: copy the Tcl scripts of the Tk library. Write the behavior in Zig behind short binding scripts.
- Recommendation: Zig behind short binding scripts.
- Why: the rule against copies, and speed. The behavior follows the manual pages.
- Limit: a script that calls a private command of Tk (`tk::ButtonDown`) fails. Stage 9 adds the private commands that real programs use.

### D14. The event loop

- Options: the loop of ztcl only. A loop in ztk only. An adapter with both.
- Recommendation: an adapter (`src/loop.zig`). Stage 1 has its own timers and its own `after`, `update`, `vwait`, and `tkwait`. It changes to the loop of ztcl when ztcl has the hook of section 10.
- Why: the loop of ztcl is not on its `main` branch yet, and a GUI loop must also wait on the display connection.

### D15. Shaders

- Options: GLSL files that `glslc` compiles in the build. SPIR-V files in the repository.
- Recommendation: GLSL files, compiled by `glslc` in the build.
- Why: a reviewer can read the source of each binary. `glslc` is a build tool (Apache-2.0) and is not in the product.

### D16. The Vulkan headers

- Fact: this machine has the Vulkan loader and no Vulkan headers.
- Options: a system package. A pinned package of `KhronosGroup/Vulkan-Headers` in `build.zig.zon`. Hand-written declarations.
- Recommendation: the pinned package. The program opens the Vulkan loader at run time and does not link it.
- Why: the build then needs no system package for headers. The headers have the license "Apache-2.0 OR MIT". A program with no link to the loader also starts on a machine with no Vulkan, and uses the CPU renderer there.

### D17. Accessibility adapters

- Options: (a) AccessKit, a Rust library with a C interface and adapters for AT-SPI, UI Automation, and `NSAccessibility` (its repository states "MIT OR Apache-2.0"; check it at Stage 8). (b) own adapters for each platform.
- Recommendation: (a), as an optional build dependency.
- Why: (b) is three large pieces of work, and AT-SPI also needs a D-Bus client.
- **User:** confirm, because (a) adds a Rust build step or a prebuilt library.

### D18. The default font

- Options: the UI font of the platform only. A font in the package.
- Recommendation: the modern theme asks for the UI font of the platform (`system-ui`). The package has one open font as the last fallback and as the font of the tests.
- Proposal: Inter. Its repository states the SIL Open Font License 1.1. The implementer checks the license file in the release before the commit.
- **User:** confirm the font, because the file (about 400 KB for each style) goes in the repository.

### D19. What the `ztk` program allows

- Options: the sandbox of ztcl by default (no files, no processes). All host access by default, as `wish`.
- Recommendation: the sandbox by default in the library. The `ztk` program has an `--allow` flag as the `ztcl` runner does.
- **User:** decide the default of the `ztk` program before Stage 2. A drop-in `wish` needs `source`, `open`, and `exec`.
- Provisional (2026-11-24, the widget stage): the recommendation holds until the user decides. The library has the sandbox. The `ztk` program has the sandbox by default and turns on a capability only from its `--allow` flag. The file dialogs of the widget stage give an error when the file capability is off.

### D20. Image goldens in the repository

- Options: PNG files in the repository. Hashes only.
- Recommendation: PNG files, small (at most 400 by 300 pixels), with a text dump of the scene beside each one.
- Why: a reviewer can open the file. The text dump shows a difference as a text diff.

### D21. The display with no display server

The request of the user: use the GPU when possible, as directly as possible, with no dependency except Vulkan.

- Options for the GPU: (a) Vulkan with the extension `VK_KHR_display`, which gives a swapchain on a display with no window system. (b) EGL and OpenGL ES on GBM and KMS, which need the Mesa libraries. (c) Vulkan that draws to an image, and raw KMS `ioctl` calls that show the image.
- Options for the CPU: (d) the framebuffer device (`/dev/fb0`) with `mmap`. (e) KMS dumb buffers with raw `ioctl` calls and page flips.
- Recommendation: (a) and (d) in Stage 1. (a) needs only the Vulkan loader and uses the renderer and the swapchain code of the Wayland backend. (d) needs only the kernel, and Printdeck runs on it on a Raspberry Pi 5. The backend tries (a) first and uses (d) when Vulkan or a display for Vulkan is missing.
- Stage 2 adds (c) or (e) when a run on a device shows a need: a driver with no `VK_KHR_display`, or tearing on the framebuffer. They use raw `ioctl` calls and no `libdrm`.
- The input is `evdev` with raw `read` and `ioctl` calls, and a key map in ztk. The backend uses no `libinput`, no `libudev`, and no `libxkbcommon`.
- Result: the build with the CPU output is one static program with no library and no libc. The build with Vulkan adds only libc and opens the loader at run time. Both facts were checked for a small program on the development machine.
- Limit: `VK_KHR_display` is in the loader of the development machine. It was not checked on a Raspberry Pi. The kernel documents the framebuffer device as the old interface.
- **User:** confirm that the direct backend belongs in Stage 1. It adds one task. Its check on a real device needs a person.

### D23. The thread for drawing

The request of the user: drawing is not on the same thread as the calculations.

- Options: (a) one thread for all. (b) a UI thread and a render thread, with the scene as the hand-over. (c) more threads: layout, style, and one render thread for each window.
- Recommendation: (b), in Stage 1 (task 17b).
- Why: a present waits for the display, and a CPU draw or a write to a framebuffer is slow. On one thread, each of these stops the script, and a busy script stops a frame that is ready. The scene is already plain data, so the hand-over is a swap of pointers.
- How: three frames (fill, wait, draw). The UI thread never waits for the render thread, except in `update`, which returns after the frame shows. The render thread owns the renderer and all GPU calls. Glyph images go to it as patches in the frame.
- Limit: a script that is busy for a long time still makes no new scene, so the window shows the last one. In Stage 2 the render thread also computes transitions and the caret, so they move while the script is busy.
- The web build has one thread, and the tests can draw on the calling thread. Both modes give the same pixels.
- Tcl stays on one thread. ztcl has no threads, and Tk has the same rule.

### D22. A remote display

- Fact: Printdeck sends the drawing commands of each frame to a browser, which draws them. So a device with no screen, or with a small one, also has its UI in a browser.
- Options: no remote display. A remote display from the scene.
- Recommendation: plan it for Stage 3, after the web renderer exists. The program sends each scene and the glyph atlas changes over a WebSocket. The browser draws them with the web renderer and sends the input back. Real elements over the canvas give the links and the accessibility tree.
- Cost: a network server inside a UI toolkit needs an access rule. It is off by default, and the embedder turns it on.
- **User:** decide if ztk gets this. It is not part of Tk.

## 6. Dependencies

The rule: ztk needs only the interfaces of the platform, ztcl, and the Zig standard library. It needs no third-party library on any platform. Each optional library has a build option and a fallback.

| Platform | What ztk links or opens | Why |
|---|---|---|
| All | ztcl, the Zig standard library | The interpreter |
| Linux, direct, CPU | Nothing. One static program with no libc. | Kernel system calls only |
| Linux, direct, GPU | libc, and the Vulkan loader at run time | The loader is a shared library |
| Linux, Wayland | libc, `libwayland-client`, `libxkbcommon`, and the Vulkan loader at run time | Vulkan needs the Wayland client library for its surface. The compositor sends the key map in the XKB format. |
| Linux, X11 (Stage 2) | libc, `libxcb`, `libxkbcommon`, and the Vulkan loader at run time | The X11 protocol and its key maps |
| macOS (Stage 3) | The system frameworks: AppKit, Metal, Core Text | Windows, the GPU, the list of fonts |
| Windows (Stage 3) | The system libraries: `user32`, `d3d12`, `dxgi`, `dwrite` | Windows, the GPU, the list of fonts |
| Web (Stage 3) | The browser: a canvas, WebGL 2, DOM events | No library in the WebAssembly file |

| Optional | Use | License | Without it |
|---|---|---|---|
| Vulkan loader | The GPU on Linux | Apache-2.0 | The CPU renderer |
| fontconfig, opened at run time (Stage 2) | The font choices of the user on Linux | HPND | The font folders |
| HarfBuzz (Stage 4) | Shaping of complex scripts | Old MIT | No shaping for these scripts |
| AccessKit (Stage 8, D17) | Accessibility adapters | MIT OR Apache-2.0 | No accessibility tree |

| Data and build tools | Use | License |
|---|---|---|
| A font (D18) | The fallback font and the font of the tests | SIL OFL 1.1 |
| Vulkan headers | Declarations | Apache-2.0 OR MIT |
| `glslc`, `wayland-scanner` | Build tools | Apache-2.0, MIT |

The license names of the system libraries are from the package data of this machine (`pacman -Qi`). No dependency has a copyleft license.

## 7. Performance targets

The reference machine is the development machine: an Intel Core i7-6700K with an Intel GPU and an NVIDIA GPU. Each result in the docs names its machine and its date.

| Target | Number | How to measure |
|---|---|---|
| Frame rate | 60 frames in each second during a resize, a scroll, and a transition | `ZTK_FRAME_STATS=1` prints the time of each frame stage and the count of late frames |
| CPU time of one frame | At most 4 ms at the 99th percentile for a window with 1 000 widgets | `zig build bench`, on the headless backend, in `ReleaseFast` |
| GPU submit time | At most 2 ms for 10 000 quads | The same statistics, on the Vulkan renderer |
| Idle | No frame and no wake-up when no input and no timer exists | Count the frames in 5 seconds: the count is 0 |
| Start | First frame of the demo in at most 100 ms on Wayland, and at most 30 ms headless | `ZTK_FRAME_STATS=1` prints the time from process start to the first frame |
| Memory | At most 24 MB of private memory for the demo on the headless backend. At most 1 KB for each plain widget. | `Private_Dirty` of `/proc/self/smaps_rollup` at the first frame, and the difference after 10 000 labels |
| Interpreter memory | No growth after 100 000 events with a binding | The arena size of ztcl before and after, in a test |
| Direct backend, idle | No write to the panel and no timer | A test compares the panel memory. On a device: the CPU use of the process is 0 % |
| Direct backend, CPU output, small change | A frame that changes one line of text writes under 10 % of the rows | A test counts the rows |
| Direct backend, CPU output | Under 5 % of one core of a Raspberry Pi 5 while the caret blinks in the demo | `top` on the device, by a person |
| Direct backend, Vulkan output | 60 frames in each second during a transition on a Raspberry Pi 5 | The frame statistics on the device, by a person |
| Program size | The static program with the CPU output is under 3 MB in `ReleaseSmall`, without the fonts | `ls -l` |
| Slow frame | Each frame over 100 ms prints one line with the time of each stage | Always on |

For comparison, `wish` 8.6.16 on this machine, with a virtual X server and other load: the time to the first `update` of one button was 59 to 168 ms in seven runs, and the resident memory was 17 MB.

The GPU driver maps memory that ztk does not control. The memory target for a window on a GPU comes from a measurement in Stage 1.

## 8. Verification

This is the main risk. A toolkit can pass each unit test and still draw a wrong window. Seven layers check it.

1. **Unit tests** (`zig build test`). The parser of CSS, the cascade, the grid solver, the pattern parser of `bind`, the text edit model, and the option parser are pure functions with tables of cases.
2. **Script tests.** A Tcl script runs on the headless backend and a test checks the results of `winfo`, `cget`, and the variables. Input comes from `event generate` and from the test interface of the headless backend.
3. **Scene dumps.** The scene of a window prints as text: one line for each quad. The test compares the text with a file in `tests/golden/`. A dump has no dependence on a rasterizer.
4. **Golden images.** The CPU renderer makes a PNG. The test compares it with a file in `tests/golden/`. Each image must be equal in each byte, also with text, because the font engine and the rasterizer are ztk code. A failed test writes the actual image and a difference image.
5. **GPU against CPU.** The Vulkan renderer draws the same scene to an offscreen image, with no window. The test compares it with the CPU image: at most 2 levels in each channel, in at most 0.1 % of the pixels. This test needs a GPU and skips with a message when the machine has none.
6. **The oracle.** A machine with `wish` 8.6.16 and `Xvfb` runs the same script in `wish` and in ztk. `tools/oracle.sh` compares the geometry of each widget. With frames of fixed size, the geometry does not depend on fonts, so `grid`, `pack`, and `place` must be equal exactly.
7. **Scene checks.** After a frame, a check reads the scene and the widget tree. It reports text that its widget cuts, text with a contrast under 4.5 to 1, and a widget outside its window. It runs for the light and the dark scheme, at three scales, and at 1.5 times the font size. Printdeck has the same two rules: a label is never cut, and the theme colors have a tested contrast.

The compatibility measure is the test suite of Tk:

- `tools/tksuite.sh` (Stage 2) runs the test files of Tk on ztk, with the classic theme and the headless backend. The repository has no copy of the tests.
- `docs/compatibility.md` (Stage 2) has one row for each of the 109 files: total, pass, fail, and blocked. A test that did not run is blocked. It is not a pass.
- The scopes are: in scope, another platform, and the C test commands. The `test*` commands of the Tk test binary (for example `testobjconfig`) get stand-ins only where they call real ztk code.
- The table gives the result of the real `wish` beside the result of ztk. The real `wish` on this machine passes 8 781 of 10 221.
- 126 tests need exact X fonts, and many more assert sizes that come from the default font. The classic theme and the test font decide how many of these can pass. The plan makes no promise for them before a measurement.

What still needs a real machine and a person:

- The look of the modern theme on each platform, beside native programs.
- Each compositor and window manager: GNOME, KDE, Hyprland, Sway, and X11 window managers.
- HiDPI with a fractional scale and with two monitors of different scale.
- Input methods with a real engine (for example for Japanese).
- Screen readers: Orca, VoiceOver, and Narrator.
- Touchpad scroll and pinch, a touch screen, and a pen.
- The smoothness of a resize, and the frame rate on a 120 Hz and a 144 Hz display.
- The macOS and Windows backends in full. The Linux machine cannot run them.
- The direct backend on a real device with a touch panel: the Vulkan output, the framebuffer output, the rotation, the touch limits, tearing, and the CPU use.
- The glyph quality of the font engine beside the text of native programs.
- GPU drivers other than the two of the reference machine.

Each stage has a short manual checklist for these. The result goes in the stage report with the date and the machine.

## 9. Rules for sources

- Copy no code from Tk. The Tk license permits it, and the project still forbids it, so that each line of ztk has one origin.
- Copy no code from a project with a GPL, LGPL, or AGPL license. zslice and Printdeck have the AGPL. The implementer does not open the zslice source or the Printdeck source for a ztk task. The ideas and the measured facts of Printdeck are in [Lessons from Printdeck](../references/printdeck.md), in new words.
- Read the manual pages, run `wish`, and read the expected results in the tests. That is the source of each behavior.
- Each idea, table, or method from another source gets an entry in `docs/references/`.

## 10. What ztk needs from ztcl

ztcl is a separate project. Each item is a request to its maintainers. Until an item exists, ztk uses the fallback.

| # | Request | Why | Fallback in ztk |
|---|---|---|---|
| 1 | The event loop (`after`, `vwait`, `update`) on `main` | Tk scripts use them | Own commands in `src/loop.zig` (task 04) |
| 2 | An event source for the embedder: a descriptor for the wait, a function for "work is ready", and a function that runs the work. Also the time to the next timer. | `vwait` and `update` must handle window events, and the wait must include the display connection | ztk keeps its own loop and does not turn on the `event` capability |
| 3 | `compact` for an interpreter that has capabilities, or a temporary arena for each callback | The arena of ztcl grows with each callback. A GUI runs callbacks for days. | ztk calls `compact` between events when no capability is on, and measures the growth |
| 4 | `register` with a `ctx` argument, and a callback when a command is deleted or renamed | A widget command belongs to a widget | ztk sets `Command.ctx` after `register`, and wraps `rename` |
| 5 | A native variable trace with a `ctx` | `-textvariable` and `-variable` | A script trace: `trace add variable` with a `::ztk::priv` command |
| 6 | A compiled script handle that stays valid across `compact` | A binding runs many times | ztk compiles again after each `compact` |
| 7 | `package provide Tk 8.6` works with the `package` capability | `package require Tk` is the first line of many scripts | The `ztk` program turns on `package` |
| 8 | TclOO | Many Tk programs use it | None. The programs that need it fail. |
| 9 | All features on ARM (aarch64) | The direct backend runs on ARM devices. The design page of ztcl says that the stack switch of coroutines is x86-64 code. | ztcl builds for `aarch64-linux` (checked). A script with `coroutine` on ARM was not run. |

Known facts about ztcl at commit `125392f` that the design depends on:

- `Interp.eval` copies the script text into the arena and parses it at each call. A binding must use `Interp.compile` one time and `Interp.evalTop` for each event.
- `Interp.compile` keeps a reference to the text. The text must live as long as the script.
- `compact` returns `error.InterpBusy` inside a running script, with a suspended coroutine, with a child interpreter, or with a capability on.

## 11. Stages

An estimate is in weeks of full-time work of one engineer who knows the field. It includes tests and review. No measurement of the speed of the agents on this project exists yet. Stage 1 records the time of each task, and the plan gets new estimates after it.

| Stage | Content | Exit criteria | Estimate |
|---|---|---|---|
| 0 | This plan | The user accepts the plan and the decisions | done |
| 1 | The demo on Linux: `frame`, `label`, `button`, `entry`, `.`, `grid`, `bind`, the CSS subset, the modern theme, the font engine, the CPU and Vulkan renderers, the render thread, and the headless, Wayland, and direct backends | `examples/demo.tcl` runs in ztk and in `wish`. All tests of the Stage 1 tasks pass. The frame statistics show no late frame in the demo at 60 Hz. The demo draws to a framebuffer in memory in the tests. The static build has no dependency. The stage report has the measured numbers. | 6 to 8 weeks, about 19 000 lines |
| 2 | The core of Tk on Linux: `pack`, `place`, the complete `bind` and `event`, `focus` and `grab`, `wm`, `winfo`, `option`, `font`, `image` (photo with PNG, GIF, and PPM; bitmap), the other simple classic widgets (`checkbutton`, `radiobutton`, `message`, `labelframe`, `scale`, `scrollbar`, `listbox`, `spinbox`, `panedwindow`, `menubutton`, `toplevel`), the classic theme, the X11 backend, own window decorations, the fonts of the system, touch scroll and fling, image caches, KMS for the direct backend if a device needs it, the Tk suite runner | The compatibility table exists for all 109 files. Each in-scope file of the Stage 2 commands has a pass rate of at least 70 %. The oracle test passes for 1 000 random layouts of each manager. | 18 to 26 weeks |
| 3 | The macOS and Windows backends at the level of Stage 2 (the web backend moved to the widget stage), and the remote display if the user wants it (D22) | The demo and the Stage 2 golden images pass on each platform, with the GPU test against the CPU reference. A person does the manual checklist on each platform. | 12 to 22 weeks |
| 4 | Complete text: CFF outlines, variable fonts, color glyphs, ligatures and marks, the optional HarfBuzz shaper, bidi, line breaks, font fallback, input methods, and the `text` widget | The Unicode conformance files pass. The eight `text*.test` files have a pass rate of at least 70 %. The fonts of a default install of each platform draw. | 24 to 36 weeks |
| 5 | The `canvas` widget: 9 item types, tags, bindings, scrolling | The seven `canv*.test` files have a pass rate of at least 70 %, without `canvPs.test`. | 10 to 16 weeks |
| 6 | `ttk`: 18 widgets, the complete `ttk::style`, and the four theme names | The 17 `ttk` test files have a pass rate of at least 80 %. | 14 to 22 weeks |
| 7 | Menus, dialogs, and platform services: `menu`, `tk_popup`, the native menu bar on macOS, the message box, the file dialogs, the color and font dialogs, all clipboard formats, drag and drop | `menu.test`, `msgbox.test`, `filebox.test`, `clipboard.test`, and `select.test` have a pass rate of at least 70 %. A person does the manual checklist. | 10 to 16 weeks |
| 8 | Accessibility and input methods on all platforms | A screen reader reads and operates the demo on each platform. | 8 to 14 weeks |
| 9 | Compatibility: the pass targets for all in-scope files, the commands of Tk 9, the private commands that real programs use, performance, and the docs | At least 90 % of the in-scope tests pass. Three real Tk programs that the user selects run with no change. | 16 to 30 weeks |

Stage 1 measured (2026-11-23, the [report](stage1-report.md)): 19 800 lines of Zig and 303 tests. An agent run made tasks 10 to 21 in about 2.5 hours of wall clock time on a shared machine, after tasks 01 to 09 in an earlier run. The run needed no review round yet, so the estimates of the later stages stay as they are until a reviewer has read Stage 1.

The sum is 118 to 190 weeks, or two and a quarter to three and a half years for one engineer. Tk has 322 187 lines, and its first release was in 1991. A much smaller estimate is not credible.

### The widget stage

The user asked for all widgets of Tk 8.6 before the rest of Stage 2, so that the screenshots show each widget in use (2026-11-24). The [widget stage](stage2-tasks/README.md) takes the widget classes, `pack`, `place`, scrolling, `grab`, and focus traversal from Stage 2, the `text` widget from Stage 4, the canvas from Stage 5, the `ttk` widgets from Stage 6, the menus and the dialogs from Stage 7, and the web backend from Stage 3. The pass targets of the Tk test files stay in their stages. The user added four rules for this stage:

- Animation is part of the API: CSS transitions and keyframes, `ztk::animate`, and animated scrolling, tabs, sashes, menus, and tree items, moved by the render thread.
- Each widget is fluid: under 8 ms of ztk work for a frame at the 99th percentile, the answer to input in the next frame, drags and scrolls that follow the pointer from the render thread, and budgets for a large canvas and a large text.
- The look is modern by default. The classic look of Tk is a theme that a script selects. Modern extras (switches, segmented buttons, placeholders, tooltips, toasts, popovers) are options and styles on the Tk widgets.
- Each widget runs on the web. The web backend is task 06 of the widget stage, the live demos of the site are task 06b, and the WebGPU renderer, with WebGL 2 and the CPU renderer as fallbacks, is task 06c. WebGPU is the GPU API of the browser, so it keeps the rule of section 4.12.

Each stage after Stage 1 gets its own task list when it starts. The task list of a stage is small tasks in order, in the form of [Stage 1](tasks/README.md).

## 12. Risks

| Risk | Effect | Answer |
|---|---|---|
| The tests pass and the window is wrong | A broken release | The seven layers of section 8, and the manual checklist of each stage |
| The memory of ztcl grows with each callback | A long session runs out of memory | Request 3 of section 10. Task 18 measures the growth. |
| The direct backend has no test on a device in Stage 1 | It fails on real hardware | The tests use memory and a pipe. A person runs the demo on a device before Stage 2 depends on it. |
| The font engine draws worse glyphs than FreeType, or cannot read a font | Text looks wrong | Golden images that the reviewer opens, a comparison with `fontTools` in the tests, and the font of the package as the fallback |
| ztcl has no TclOO and has gaps in `info` and `namespace` | Real Tk programs fail in the interpreter before they reach ztk | The Stage 9 programs show the gaps. The requests go to ztcl. |
| The geometry of Tk depends on font metrics | Many tests of Tk cannot pass with another font | Measure in Stage 2 with the test font. Report the count honestly. |
| Four renderers differ | A platform shows a different image | One quad form, one shader source for each API, and the GPU test against the CPU reference |
| Two threads share a frame | A race draws a wrong frame or crashes | One mutex and three frames, no other shared state, a stress test in a loop, and a review of each shared field |
| The `text` widget and the canvas are large | Stages 4 and 5 are late | They come after the platform work, so the base is stable |
| A person must check each platform | The review of an agent cannot find a wrong look | The manual checklists, with the date and the machine in each report |
| Zig changes between releases | The build breaks | Pin Zig 0.17.0 in `build.zig.zon` and move in one commit |

## 13. Decisions for the user

1. D6: the font engine in Zig, with HarfBuzz only as an optional shaper. This is the largest change that the request for no dependency causes.
2. D17: AccessKit (a Rust library) for accessibility, or own adapters.
3. D18: Inter as the font in the package.
4. D19: the default host access of the `ztk` program.
5. D9: the list of native UI, in particular a drawn menu bar on Windows and Linux.
6. D12: logical pixels for `winfo` and `-width`. A script that reads `winfo screenwidth` on a HiDPI monitor gets a smaller number than in Tk on X11.
7. The order of Stages 3 to 7. The plan has the other platforms before the large widgets. The other order gives more of Tk on Linux sooner.
8. The three real Tk programs of Stage 9.
9. The requests to ztcl in section 10, in particular requests 2 and 3.
10. A software Vulkan driver (the Mesa `lavapipe` package) on the development machine. With it, the GPU tests also run with no GPU.
11. D21: the direct backend in Stage 1 (task 20), with Vulkan on the display and the framebuffer, and a person who runs it on a device.
12. D22: a remote display in a browser, as Printdeck has.
13. Printdeck has the AGPL, so ztk uses its ideas and no code. The author of Printdeck owns its code and can permit a copy under BSD-2-Clause. The plan does not assume that.
