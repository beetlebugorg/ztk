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

The target is an app that AppKit draws: Finder, Notes, Mail, System Settings, and a reference app of the AppKit controls. These apps have the controls of AppKit in the current macOS, the SF Pro font with its optical sizes, the scroll physics of `NSScrollView`, the text system of `NSTextView`, and the accessibility of `NSAccessibility`.

### Theme: Aqua, drawn by AppKit

- A theme sheet `aqua.css` and a platform sheet `macos.css`, the default on macOS. The sheet gives the layout of each control (the sizes, the margins, and the paddings). The pixels of each control part come from AppKit itself, as the aqua theme of Tk gets them from the system: the backend draws the cell of the matching AppKit control into a bitmap with the `NSAppearance` of the window, and the Metal renderer draws the bitmap as an image. No pixel of a control comes from a value that ztk measured.
- A new scene item, the system part: a kind (button, check box, radio button, switch, slider track and knob, pop-up button, combo box, segmented control, stepper, text field and search field bezel, progress bar, spinner, level indicator, scroll bar track and knob, table header, disclosure triangle, group box, tab, and the focus ring of a shape), a state, a size, and a value. The backend draws it with an `NSCell` or `NSView` of that kind (`NSButtonCell` with its bezel style, `NSSliderCell`, `NSSegmentedCell`, `NSStepperCell`, `NSTextFieldCell`, `NSScroller`, `NSTableHeaderCell`, `NSSwitch`, and the others) into a `CGBitmapContext` at the backing scale, with `NSAppearance.current` set to the appearance of the window during the draw.
- The states of AppKit: normal, pressed (`highlighted`), disabled, the on, off, and mixed values, the default button (the accent fill), the focus ring, and the inactive look of a window that is not the key window, where AppKit draws the controls without the accent. Hover changes only the controls that change in AppKit.
- The sizes come from AppKit too: `cellSize` and `intrinsicContentSize` of each control for each control size (`mini`, `small`, `regular`, and `large`), and `alignmentRectInsets` for the layout, so a ttk button has the size of an `NSButton` with the same title.
- A cache of the part images, keyed by the kind, the state, the size, the value, the scale, the appearance, and the accent, in the atlas of the renderer. A change of the appearance, the accent, or the contrast setting empties it, with the `appearance` event that ztk has now.
- The `modern` and `classic` themes stay, so an app can choose the look of ztk.

### Text: Core Text

- A Core Text backend of the text interface: the system font from `CTFontCreateUIFontForLanguage` (SF Pro, with the optical size that Core Text picks for each point size), the fallback list of `CTFontCopyDefaultCascadeListForLanguages`, shaping, bidi, and line breaks from `CTTypesetter` and `CTLine`, and the metrics of Core Text for the layout.
- The sizes of AppKit: the system font at 13 points (`NSFont.systemFontSize`), 11 for the small controls and 9 for the mini ones, 10 for a label of the menu bar style, and the text styles of `NSFont.preferredFont(forTextStyle:)` for `ztk::font` names such as `body`, `headline`, and `title1`. TkDefaultFont maps to the system font, as in Tk on macOS.
- Glyph images from `CTFontDrawGlyphs` into a gray `CGBitmapContext` with the font smoothing of the system (grayscale since macOS 10.14, no subpixel order), and the stem darkening that AppKit applies, so the coverage in the atlas equals what AppKit puts on the same background. The harness below checks it glyph by glyph.

### Window chrome

- The window is an `NSWindow` with the title bar, the traffic lights, full screen, and the tabs of the system since PR 5 and ztk#65. New: the toolbar styles of `NSWindow.toolbarStyle` (`unified` and `unifiedCompact`), a full size content view with a transparent title bar for an app that asks for it, and the window background of `NSColor.windowBackgroundColor`.
- Vibrancy: an `NSVisualEffectView` behind the Metal layer, with the material that the theme gives a region (sidebar, menu, popover, HUD, header view, and window background). The Metal layer is not opaque there, and the toplevel is clear where the theme has a material. With reduced transparency on, the material is the solid color of the system, as AppKit draws it.
- Tooltips are the tooltips of AppKit (`toolTip` of a tracking area of the view). Menus are `NSMenu` since PR 10.

### Behavior

- Scrolling: the system gives the momentum in the events (the `momentumPhase` of `scrollWheel:` events), and ztk keeps it. The rubber band follows `NSScrollView`: past the edge, the content moves by `(1 - 1 / (x * 0.55 / d + 1)) * d` for a pull of `x` in a view of size `d`, and it springs back when the gesture and its momentum end, with the duration of AppKit. The setting "Show scroll bars" (`NSScroller.preferredScrollerStyle` and its notification) picks overlay or legacy scroll bars. An overlay scroll bar draws the knob of `NSScroller` over the content, shows it while the content scrolls, hides it after the delay of AppKit, and grows it when the pointer is over it.
- Motion: the timings of AppKit, such as 0.25 s with ease in and ease out for `NSAnimationContext`, the transition of a switch, and the focus ring that shrinks onto a control. With reduced motion on (`accessibilityDisplayShouldReduceMotion`), each motion is a cross fade or has the duration 0.
- Text: each key of a text widget goes through `interpretKeyEvents:`, and `doCommandBySelector:` maps each selector of the text system (`moveWordForward:`, `deleteToBeginningOfLine:`, `transpose:`, `yank:`, `pageDownAndModifySelection:`, and the others) to the edit of the text widget. So the key bindings of `StandardKeyBinding.dict`, the Emacs keys, and the `DefaultKeyBinding.dict` of a user work as in every Cocoa app. Word boundaries come from the system (`CFStringTokenizer`), a double click selects a word and a triple click a paragraph.
- The context menu of text has the items of `NSTextView`: Look Up, Translate, Search With, Cut, Copy, Paste, Spelling and Grammar, Substitutions, Transformations, Speech, and Services. The view adopts `NSServicesMenuRequestor`, so Services read and write the selection. Spell check and autocorrect come from `NSSpellChecker` (the check of the text after each edit, the red dotted line of AppKit, and the correction panel). Dictation and the input methods come through `NSTextInputClient`, which ztk has since PR 8.
- Focus: the focus ring of AppKit around the shape of the control, in the keyboard focus color, with its motion. The setting Keyboard Navigation (`NSApp.isFullKeyboardAccessEnabled`) decides what Tab reaches: each control, or only the text fields and lists, as in AppKit. Return presses the default button, and Escape and Command-period press the cancel button.
- Sounds: `bell` plays the alert sound of the system (`NSBeep`).
- Settings: increase contrast (the appearances `accessibilityHighContrastAqua` and `accessibilityHighContrastDarkAqua`), reduce transparency, reduce motion, and differentiate without color, each from `NSWorkspace` with its notification, so a change shows at once.

### Accessibility: NSAccessibility

- The view of each window gives the accessible tree of the core to VoiceOver: `accessibilityChildren` of the view are the nodes of the toplevel, and each node is an object of a class made at run time that adopts the `NSAccessibility` protocols of its role (`NSAccessibilityButton`, `NSAccessibilityCheckBox`, `NSAccessibilitySlider`, `NSAccessibilityStaticText`, `NSAccessibilityNavigableStaticText`, `NSAccessibilityTable`, `NSAccessibilityOutline`, `NSAccessibilityList`, and the others). Each node gives its role, label, value, help, frame on the screen, parent, children, focus, and the actions of its role (`accessibilityPerformPress`, `accessibilityPerformIncrement`, and the others), which call the core.
- The text widgets give the text range attributes of `NSAccessibilityNavigableStaticText` and of a text area (the value, the selected range, the insertion line, `accessibilityString(for:)`, `accessibilityFrame(for:)`, and `accessibilityLine(for:)`), so VoiceOver reads by word and line, and a braille display follows the caret.
- The changes of the core post the notifications of AppKit: focus changed, value changed, selected text changed, layout changed, created, and destroyed.
- The test of each control reads the tree of the ztk window and of the reference app in the process, with the methods of `NSAccessibility` on each object, and compares the roles, the labels, the values, and the actions. A run with VoiceOver on is a manual check of each release.

### Proof

- A reference app in Swift with AppKit, in `tools/native-ref/macos/`, built with `swiftc` on the macOS CI job, with the controls and states of the theme at fixed places, in light, dark, and increase contrast. A ztk script shows the same controls at the same places.
- Each app draws its own window into an image, with no capture of the screen, so CI needs no Screen Recording permission: the reference app with `cacheDisplay(in:to:)` of its content view, and ztk with the readback of the Metal renderer that the tests use now. The harness crops each control and compares the pixels. A control passes when each channel of each pixel is within a small difference. Vibrancy depends on the wallpaper, so the harness turns it off in both apps and checks it on its own.
- The text check draws strings of each script at each size with Core Text in ztk and with an `NSTextField` in the reference app, and compares them.
- The behavior tests follow the Human Interface Guidelines for each control: the keys, the pointer, the focus, the timings of the motion, the curve of the rubber band, and the selectors of the key bindings.

### Steps

1. This plan.
2. The system part item of the scene and its drawing with AppKit cells, with the push button, the check box, and the radio button first, each against the reference app.
3. The other controls of the aqua theme, and the cache of the part images.
4. The Core Text backend, with the glyph check against AppKit.
5. Scrolling: momentum, the rubber band, and the overlay scroll bars.
6. The text system: the selectors of `doCommandBySelector:`, the context menu, Services, spell check, and autocorrect.
7. Focus rings, Keyboard Navigation, the default and cancel buttons, and the settings of accessibility.
8. Vibrancy and the toolbar styles.
9. The NSAccessibility adapter of the accessible tree (the tree is shared with Windows).
10. The reference app and the pixel harness in CI.
