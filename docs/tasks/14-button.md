# Task 14: `button`

## Goal

The `button` widget works with the pointer and the keyboard, runs its `-command`, and shows its states through the style.

## Files

- `src/widgets/button.zig`
- `src/cmds.zig`: the registration and the class bindings
- `src/themes/modern.css`: the `Button` rules, if task 09 left them open

## Interfaces

```zig
// src/widgets/button.zig
pub const class: Class;   // command "button", type name "Button", focusable
/// Runs the -command of the button. Returns the result of the script.
pub fn invoke(w: *Widget, it: *ztcl.Interp) ztcl.Error!ztcl.Value;
```

The native commands of the class bindings:

| Command | Effect |
|---|---|
| `::ztk::priv::button enter path` | No effect. Task 12 sets the `hover` bit. |
| `::ztk::priv::button leave path` | Clears the armed flag |
| `::ztk::priv::button down path` | Arms the button and gives it the focus |
| `::ztk::priv::button up path` | When armed and the pointer is on the button: `invoke` |
| `::ztk::priv::button key path` | `invoke` |

## Steps

1. Read `doc/button.n`.
2. The options of Stage 1: all options of `label` in task 11, and `-command`, `-activebackground`, `-activeforeground`, `-disabledforeground`. The default of `-takefocus` is empty, and the class is `focusable`. The default `-anchor` is `center`. Each other option of the Tk button gives `unknown option`. Add them to `docs/stage1-limits.md`.
3. Measure and paint are those of `label`: the box and the text. Share the code with `label`.
4. The states. `-state disabled` sets the `disabled` bit. `-state active` sets the `hover` bit, as Tk shows the active colors. The `pressed` bit is on while the button is armed and the pointer is on it.
5. The options `-activebackground`, `-activeforeground`, and `-disabledforeground`, when the script set them, are declarations of the origin `widget` that apply only in that state: `background-color` and `color` with `hover`, and `color` with `disabled`.
6. The class bindings, on the tag `Button`. `wish` has the same six patterns: `<Enter>`, `<Leave>`, `<Button-1>`, `<ButtonRelease-1>`, `<Key-space>`, and `<<Invoke>>`. Each script is one call of `::ztk::priv::button` with `%W`.
7. `down` on a disabled button has no effect. `down` gives the focus to the button when `focus.accepts` is true for it.
8. `up` invokes only when the button was armed by `down` and the pointer is on the button at the release. A release outside the button does not invoke.
9. `invoke` runs the `-command` script at the global level and returns its result. An error of the script is the error of `invoke`. From a class binding, that error goes to the background error handler. A disabled button returns an empty string and runs no script. `wish` gives `wrong # args: should be ".b invoke"` for an extra argument.
10. The widget subcommands are `cget`, `configure`, and `invoke`. `flash` gives the error `flash is not supported in this stage`. A wrong name gives the `bad option` message of `wish` for a button.
11. A widget that is deleted by its own command gives no crash. `invoke` checks `destroyed` after the script.
12. The `Button` rules of the modern theme: a background, a 1 pixel border, the radius variable, the padding `6px 12px`, a `:hover` background, an `:active` background, a `:focus` outline of 2 pixels in the focus ring color with an offset of 1 pixel, and a `:disabled` color and opacity. A second style class `primary` uses the accent color.

## Tests

```sh
zig build test -Dtest-filter=button
```

Script tests with a `Harness`. `.b` is `button .b -text OK -command {incr n}` in a grid.

- `.b invoke` two times: `n` is `2`. The result of `invoke` is the result of the script.
- `button .r -command {return 7}`: `.r invoke` gives `7`.
- `.b configure -state disabled; .b invoke` gives an empty string and does not change `n`.
- `.b invoke extra` gives the message of `wish`.
- `h.head.click` on the center of `.b`: `n` goes up by 1.
- A press on `.b`, a move outside, and a release: `n` does not change. A press, a move outside, a move back, and a release: `n` goes up by 1.
- A press and a release on a disabled button: `n` does not change.
- A click gives the focus to `.b`: `focus` gives `.b`.
- `focus .b` and `h.head.press("space")`: `n` goes up by 1.
- `bind Button` gives the six patterns.
- `bind .b <1> break` and a click: `n` does not change.
- `button .d -text X -command {destroy .d}` and a click gives no crash, and `winfo exists .d` gives `0`.
- A command with an error, run by a click, calls `bgerror` one time. Run by `.b invoke`, it gives the error to the caller.
- While button 1 is down on `.b`, the widget has the `pressed` and `hover` bits. After a move outside it has neither.
- `.b configure -activebackground red`: the computed background is red only with the `hover` bit.

Golden images and scene dumps, with the modern theme, 260 by 80. Each image has three buttons in a row: `Save`, `Cancel`, and a `primary` button.

- `button-normal`
- `button-hover`: the pointer is on the first button.
- `button-pressed`: button 1 is down on the first button.
- `button-focus`: the first button has the focus.
- `button-disabled`: the first button is disabled.

In this task a transition has no duration yet (task 18), so each image shows the end state.

## Acceptance

- All tests pass.
- The reviewer opens the five images. Each state is clearly different from the normal state, the text is in the center, and the focus outline is complete on all four sides.
- `src/widgets/button.zig` has no layout code and no drawing code that `label` also has.

## Out of scope

- `checkbutton`, `radiobutton`, `-image`, `-compound`, `-underline`, `-default`, `-overrelief`, `-repeatdelay`, and `flash`.
- `ttk::button`. Stage 6.
- The `Return` key. Tk does not bind it for a button.
