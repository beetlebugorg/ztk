# Task 13: Focus

## Goal

One widget has the keyboard focus. Key events go to it. `focus` sets and reads it. `Tab` and `Shift-Tab` move it. The `focus` state bit drives the style.

## Files

- `src/focus.zig`: the focus state, the `focus`, `tk_focusNext`, and `tk_focusPrev` commands
- `src/dispatch.zig`: key events, focus events of the window
- `src/cmds.zig`: the registration, the bindings of `all`

## Interfaces

```zig
// src/focus.zig
pub const Focus = struct {
    /// The widget with the focus in the toplevel, or null.
    current: ?*Widget = null,
    /// True when the platform window has the keyboard.
    window_focused: bool = false,
};
/// Gives the focus to a widget. Sends FocusOut and FocusIn and changes
/// the state bits.
pub fn set(app: *App, w: ?*Widget) void;
/// The next widget in the traversal order that accepts the focus.
pub fn next(app: *App, w: *Widget) *Widget;
pub fn prev(app: *App, w: *Widget) *Widget;
/// True when a traversal can stop at the widget.
pub fn accepts(w: *const Widget) bool;
/// Clears the focus of a widget that is deleted.
pub fn forget(app: *App, w: *Widget) void;
```

## Steps

1. Read `doc/focus.n` and `doc/focusNext.n`.
2. The App has one `Focus` for `.` in Stage 1.
3. `focus` returns the path of the focus widget, or an empty string when the window does not have the keyboard. `focus path` sets it. `focus -force path` sets it too (Stage 1 cannot take the keyboard from another program). `focus -displayof path` is `focus`. `focus -lastfor path` gives the focus widget of the toplevel of the path, also when the window does not have the keyboard, and the toplevel when no widget had the focus. A path that does not exist gives `bad window path name ".zz"`.
4. `set` delivers `FocusOut` to the old widget and `FocusIn` to the new one, changes the `focus` state bits, and sets the style flags.
5. A `focus` event of the backend with `focused == false` delivers `FocusOut` to the focus widget and clears its `focus` bit. `current` stays. With `focused == true`, it delivers `FocusIn` to `current`, or to the toplevel when `current` is null. The toplevel gets the `background` state bit while the window does not have the keyboard.
6. A `key` event goes to `current`, or to the toplevel when `current` is null. It becomes `KeyPress` or `KeyRelease` with the key symbol, the key code, the text, and the modifiers. `x` and `y` are the pointer position in the widget.
7. The traversal order is the order of `focusNext.n`: the widget tree in depth-first order, children in stacking order, starting after the widget and going around through the toplevel. `accepts` is true when the widget is mapped, is not disabled, and:
   - `-takefocus` is `1`, or
   - `-takefocus` is empty and the class has `focusable`, or the widget has a key binding on its own path.
   - `-takefocus` `0` is false. A script value of `-takefocus` is Stage 2 and counts as an empty value.
   When no widget accepts, `next` returns the widget itself.
8. `tk_focusNext path` and `tk_focusPrev path` return the path. `wish` gives `.e` for `tk_focusNext .b` when `.e` is the next entry.
9. The bindings of the tag `all`: `<Key-Tab>` runs `::ztk::priv::focus_move %W next` and `<Shift-Key-Tab>` and `<Key-ISO_Left_Tab>` run `::ztk::priv::focus_move %W prev`. The native command sets the focus to the next widget. Tk uses the virtual events `<<NextWindow>>` and `<<PrevWindow>>` for this. Stage 2 changes to them when `event add` exists.
10. `focus.forget` runs in `destroy`. When the deleted widget had the focus, `current` becomes null and no event runs.
11. The headless window starts with the keyboard (`window_focused = true`).

## Tests

```sh
zig build test -Dtest-filter=focus
```

Script tests with a `Harness`. `.a`, `.b`, and `.c` are frames with `-takefocus 1`, and `.n` is a frame with `-takefocus 0`, in a grid.

- `focus .a; focus` gives `.a`.
- `focus .zz` gives the error.
- `focus .a; focus .b` runs `<FocusOut>` on `.a` and then `<FocusIn>` on `.b`.
- `.a` has the `focus` state bit, and a `Frame:focus` rule changes its style.
- `h.head.press("x")` runs a `<Key>` binding of the focus widget with `%K` equal to `x` and `%A` equal to `x`.
- A key with no focus widget goes to `.`.
- `tk_focusNext .a` gives `.b`. `tk_focusNext .c` gives `.a`. `tk_focusPrev .a` gives `.c`. `.n` is never a result.
- `h.head.press("Tab")` moves the focus from `.a` to `.b`. With `shift` it moves back.
- A widget binding for `<Key-Tab>` with `break` stops the move.
- `h.head.setFocused(false)`: `focus` gives an empty string, `focus -lastfor .` gives `.b`, and `.` has the `background` bit. `setFocused(true)` gives `.b` again with one `<FocusIn>`.
- `destroy .b` while it has the focus: `focus -lastfor .` gives `.`, and the next key goes to `.`.
- A disabled widget and a widget that is not mapped are not results of `tk_focusNext`.

## Acceptance

- All tests pass.
- The key path does not search the tree: `current` is a pointer.

## Out of scope

- `grab`, `tk_focusFollowsMouse`, and a script value of `-takefocus`.
- Focus on a click. Each class binding does that (tasks 14 and 15).
- `:focus-visible` as a separate state.
- More than one toplevel.
