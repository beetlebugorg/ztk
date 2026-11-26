# Plan: a native look and feel on each platform (ztk#154)

The goal of ztk#154: on each platform a ztk app looks and acts as if the native toolkit drew it, and a user cannot tell the two apart. This plan has the parts that the platforms share, then one section for each platform. The Windows session writes and builds the Windows part, and the macOS session writes and builds the macOS part.

## Shared parts

Each platform fills the same five layers. The core gets the interfaces, and each backend fills them.

1. **A native theme.** A theme sheet for each platform (`src/themes/`), the default on that platform, with light, dark, high contrast, and the accent color of the system. The current look stays as the theme `modern`, and `classic` stays. The sheets get their sizes, radii, colors, and timings from the design resources of the platform, and each value names its source.
2. **Text of the system.** A text backend in the platform interface: font lookup and fallback, shaping, metrics, and glyph images from the text engine of the system, with its font and its rendering. The current TrueType code stays for the headless backend, the web, and Linux.
3. **Window chrome of the system.** The title bar, the frame, the corners, the shadow, the backdrop, and the window commands of the system.
4. **Behavior of the platform.** Scroll physics, motion curves and durations, the key bindings of text, the focus visuals, the context menus, and the system settings (reduced motion, larger text, reduced transparency).
5. **Accessibility.** A tree of accessible nodes in the core (the role of each class, as `docs/dev/plan.md` says, with the name, the value, the states, the bounds, the actions, and the events of change), and one adapter for each platform.

**Proof.** For each platform: a reference app in the native toolkit with the same controls in each state, a harness that renders both apps and compares the pixels of each control, behavior tests from the guidelines of the platform, and a blind test with people.

## Windows

The target is an app of Windows 11 that the system and WinUI 3 draw: Settings, File Explorer, Notepad, and the WinUI 3 Gallery. These apps have the Fluent design: the Segoe UI Variable font, Mica, rounded corners, the control shapes of WinUI, and its motion.

### Theme: Fluent

- A theme sheet `fluent.css` and a platform sheet `windows.css`, the default on Windows. The values come from the theme resources of WinUI 3 (`microsoft-ui-xaml`, MIT license): the colors of light, dark, and high contrast (`Common_themeresources_any.xaml` and the resources of each control), the corner radii (`ControlCornerRadius` 4, `OverlayCornerRadius` 8), the sizes and paddings of each control, the stroke of each state (the bottom stroke of a text box, the elevation border of a button), and the focus visual (a ring of 2 px with an inner ring of 1 px). Each value has its resource name in a comment, and `docs/references/` credits the repository.
- The accent comes from `UISettings.GetColorValue` (the accent and its light and dark shades), as WinUI reads it, and changes when the system accent changes.
- The controls and states of the WinUI Gallery: button, accent button, hyperlink button, toggle button, check box (with the indeterminate state), radio button, toggle switch, slider, combo box, text box, password box, number box (spinbox), progress bar and ring, scroll bar, list view, tree view, tab view (notebook), menu bar and menu flyout, tooltip, and the dialog. Each state: rest, pointer over, pressed, disabled, focused, and checked.
- UxTheme draws the look of the common controls of Win32, which differs from the apps of Windows 11, so the Fluent sheet draws each part from the WinUI values. UxTheme stays for the classic look of the `winnative` theme of Tk, if a user asks for it.

### Text: DirectWrite

- A DirectWrite text backend: the system font collection, `IDWriteFontFallback` of the system for each script, `IDWriteTextAnalyzer` for shaping, bidi, and line breaks, and the metrics of DirectWrite for layout.
- The UI font is Segoe UI Variable with its optical sizes (Small, Text, Display) and the type ramp of Fluent: Caption 12, Body 14, Body Strong 14 semibold, Subtitle 20, Title 28, Title Large 40, Display 68 (pixels at a scale of 1). Windows 10 has Segoe UI, and the backend uses it there.
- Glyph images from `IDWriteGlyphRunAnalysis` with the rendering mode of the system for the font and size, grayscale as WinUI 3 draws text, and the gamma and contrast of the rendering parameters of the monitor, applied in the blend of the atlas. The atlas keeps 8-bit coverage, so the renderers do not change.
- The text scale of the accessibility settings (`UISettings.TextScaleFactor`) scales the type ramp, as WinUI does.

### Window chrome

- The title bar and frame of the system, with the dark title bar of the dark theme (`DWMWA_USE_IMMERSIVE_DARK_MODE`). Snap layouts on the maximize button, the resize borders, the shadow, and the rounded corners of Windows 11 come with it.
- Mica as the backdrop of the main window (`DWMWA_SYSTEMBACKDROP_TYPE` with `DWMSBT_MAINWINDOW`), and Mica Alt for a window with tabs. Mica needs a transparent client area, so the D3D12 backend draws into a swap chain for composition (`CreateSwapChainForComposition` with premultiplied alpha) on a DirectComposition visual of the window, and the background of a toplevel is clear where the theme gives Mica. With transparency off in the settings, or on Windows 10, the backdrop is the solid color of the theme.
- Menus, tooltips, and combo box lists are windows with the Acrylic backdrop (`DWMSBT_TRANSIENTWINDOW`), the corners of an overlay, and the shadow of the system.

### Behavior

- Motion: the durations and the curves of WinUI (`ControlFasterAnimationDuration` 83 ms, `ControlFastAnimationDuration` 167 ms, `ControlNormalAnimationDuration` 250 ms, and the key spline `ControlFastOutSlowInKeySpline`), for each transition of the Fluent sheet. With animations off in the settings (`SPI_GETCLIENTAREAANIMATION`), each transition has the duration 0.
- Scrolling: the lines of a wheel notch from `SPI_GETWHEELSCROLLLINES`, a smooth scroll of each notch as the ScrollViewer of WinUI does, and the pan with inertia of a touchpad and a touch screen from DirectManipulation, which gives the physics of the system. The scroll bar of WinUI: a thin indicator that grows into a bar with arrows when the pointer is over it.
- Text: the key bindings of a text box of Windows (the moves by word and by line, Ctrl+Backspace and Ctrl+Delete, Shift+Delete and Shift+Insert, Ctrl+Insert, the undo and redo of Ctrl+Z and Ctrl+Y, a double click for a word), the word boundaries of Windows, the context menu of a text box (cut, copy, paste, undo, select all), spell check through the Windows Spell Checking API (`ISpellCheckerFactory`) with the red wavy line of WinUI, and the input methods of TSF, which ztk already has.
- Focus: the focus visual shows after keyboard input and hides after pointer input, as in WinUI. Tab, Shift+Tab, the arrow keys in a group, Enter for the default button, Escape for the cancel button, and the access keys of Alt.
- High contrast: with a contrast theme on (`SPI_GETHIGHCONTRAST`), the Fluent sheet uses the system colors (`GetSysColor`) as the high contrast resources of WinUI do, and Mica is off.

### Accessibility: UI Automation

- A UI Automation provider for the accessible tree of the core: `WM_GETOBJECT` gives a root with `UiaReturnRawElementProvider`, and each node is an `IRawElementProviderFragment` with its control type, name, bounds, states, and the patterns of its role (Invoke, Toggle, Value, RangeValue, Selection, SelectionItem, ExpandCollapse, Scroll, Grid, and Text for the text widgets).
- The events of change go to `UiaRaiseAutomationEvent`, `UiaRaiseAutomationPropertyChangedEvent`, and `UiaRaiseStructureChangedEvent`, so Narrator follows the focus, the values, and the changes of the tree.
- The test of each control runs the UI Automation client of the system (`IUIAutomation`) on the ztk window and on the reference app, and compares the control types, the names, the patterns, and the values.

### Proof

- A reference app in WinUI 3 (C# with the Windows App SDK, unpackaged), in `tools/native-ref/windows/`, with the controls and states of the theme, each at a fixed place, in light, dark, and high contrast. A ztk script shows the same controls at the same places.
- The harness starts both apps on the desktop of the Windows CI job, captures each window with `Windows.Graphics.Capture`, crops each control, and compares the pixels. A control passes when each channel of each pixel is within a small difference. Mica depends on the wallpaper, so the harness turns it off in both apps and checks it on its own.
- The behavior tests follow the Fluent guidelines for each control: the keys, the pointer, the focus, the timings of the motion, and the scroll of a wheel notch.

### Steps

1. This plan.
2. The text backend in the platform interface, and DirectWrite on Windows, with a test that compares the glyph images with the images of DirectWrite.
3. The Fluent sheet with light and dark and the accent, control by control, each with its WinUI values.
4. The window chrome: the composition swap chain, Mica, the dark title bar, and the backdrops of the menus and tooltips.
5. The motion and scrolling: the WinUI timings, the wheel, and DirectManipulation.
6. The text bindings, the context menu of text, and spell check.
7. High contrast, the text scale, and reduced motion.
8. The accessible tree of the core (shared with macOS) and the UI Automation provider.
9. The reference app and the pixel harness in CI.

## macOS

The macOS session writes this section.
