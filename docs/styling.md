# Styling and themes

A stylesheet in a subset of CSS gives each widget its look. The widget tree is the document. The default theme is `modern`, with a light and a dark scheme. The theme `classic` has the sizes and the colors of Tk on X11.

**Live:** the [status board](https://beetlebug.org/ztk/play/index.html?example=dashboard) and the [sign-in form](https://beetlebug.org/ztk/play/index.html?example=signin) each have a stylesheet. The playground shows it next to the script.

## Load a stylesheet

```tcl
ztk::style load app.css       ;# a file in the folder of the script
ztk::style add {
    Button.big { font-size: 18px; padding: 10px 20px; box-shadow: 0 2px 6px var(--shadow); }
    Frame.card { background: linear-gradient(135deg, #2563eb, #7c3aed); border-radius: 12px; }
}
button .go -text "Go"
ztk::class .go add big
```

## Selectors

| CSS | Matches |
|---|---|
| `Button` | The class of the widget (`winfo class`). `TButton` is the `ttk` button. |
| `#ok` | The last part of the path: `#ok` matches `.f.ok`. |
| `.big` | A style class. `ztk::class path add big` adds one to a classic widget. A `ttk` style `Big.TButton` is the selector `TButton.Big`. |
| `A B`, `A > B` | A descendant and a child in the widget tree. |
| `:hover`, `:active`, `:focus`, `:disabled`, `:checked`, `:read-only`, `:invalid`, `:indeterminate`, `:placeholder-shown`, `:scrolling` | The states of the widget. |
| `:state(user1)`, `:state(!hover)` | Any state flag of Tk, and its negation. |
| `::indicator`, `::thumb`, `::trough`, `::slider`, `::tooltip`, `::placeholder` | A part of a widget. Each widget page names its parts. |
| `--name` and `var(--name)` | Variables. They inherit down the tree. |
| `@media (prefers-color-scheme: dark)` | The dark scheme. |

## Properties

`color`, `background` (a color or a `linear-gradient`), `border`, `border-radius`, `border-style` (with `raised`, `sunken`, `groove`, and `ridge`), `padding`, `font-family`, `font-size`, `opacity`, `box-shadow`, `outline`, `min-width`, `min-height`, `caret-color`, `cursor`, `text-align`, `transition`, and `animation`. The geometry managers do the layout, so `display`, `margin`, `flex`, and `grid` are not in the subset.

The modern theme sets the variables `--bg`, `--fg`, `--muted`, `--accent`, `--accent-fg`, `--accent-hover`, `--border`, `--field-bg`, `--radius`, and `--shadow`. Set them on `:root` to change the colors of each widget at once.

## The order of the rules

From the lowest to the highest:

1. The theme sheet, and its sheet for the platform.
2. The settings of `ttk::style configure` and `ttk::style map`.
3. Your stylesheets (`ztk::style load` and `ztk::style add`).
4. The options that the script sets on a widget, such as `-background red`.

Inside one level, the specificity and then the order decide, as in CSS.

## Themes

```tcl
ztk::style theme classic      ;# or modern
ttk::style theme use classic  ;# the same for the ttk names
ztk::style scheme             ;# light or dark
```

| Theme | Look |
|---|---|
| `modern` | Round corners, an accent color, overlay scrollbars, and a dark scheme. `ttk::style theme use default`, `clam`, and `alt` select it. |
| `classic` | The reliefs and the gray of Tk on X11, with square corners. |

The [Themed widgets page](widgets/ttk.md) shows one window in both themes.

## ttk::style

`ttk::style` works as in `wish`, and each setting of a script becomes a CSS rule.

```tcl
ttk::style configure Accent.TButton -foreground white -background #2563eb -padding {12 6}
ttk::style map Accent.TButton -background {pressed #1e40af active #1d4ed8}
ttk::button .ok -text "Apply" -style Accent.TButton
```

These two commands act as these rules:

```css
TButton.Accent { color: white; background-color: #2563eb; padding: 6px 12px; }
TButton.Accent:active { background-color: #1e40af; }
TButton.Accent:hover { background-color: #1d4ed8; }
```

| Command | What it does in ztk |
|---|---|
| `configure style ?-option value ...?` | Adds a rule. `-foreground`, `-background`, `-fieldbackground`, `-bordercolor`, `-borderwidth`, `-relief`, `-padding`, `-font`, and `-indicatorcolor` change the look. Other options are stored for `lookup`. |
| `map style -option {states value ...}` | Adds one rule for each pair. The first pair that matches wins, as in Tk. |
| `lookup style -option ?state? ?default?` | Gives the value, as `wish` gives it. |
| `layout style ?spec?` | Gives the layout of `wish`. A new layout is stored and has no effect on the look. |
| `element create`, `element names`, `element options` | As in `wish`. A new element has no effect on the look. |
| `theme create name ?-parent p? ?-settings script?` | Makes a theme with the look of its parent. |
| `theme names`, `theme use ?name?`, `theme settings name script` | List, select, and set up themes: `clam`, `alt`, `default`, `classic`, and yours. |

The style `.` is the root: `ttk::style configure . -font {Inter 12}` applies to each `ttk` widget. [Differences from Tk](differences.md#styles-and-themes) has the rules that differ from `wish`.
