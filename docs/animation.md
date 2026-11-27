# Animation

ztk moves a widget with CSS transitions, CSS keyframes, or the command `ztk::animate`. A render thread draws the frames, so a transition, a switch, or a scrollbar stays smooth while the script is busy.

**Live:** hover the buttons and toggle the switches of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery). Drag the slider of the scale.

## CSS transitions

A change of state moves each property in `transition` from its old value to its new value.

```css
Button { transition: background-color 150ms ease, color 150ms ease; }
Button:hover { background-color: var(--accent); color: var(--accent-fg); }
Checkbutton.switch::indicator { transition: all 320ms spring(260 20 1); }
```

The timing functions are those of CSS (`ease`, `linear`, `ease-in-out`, `cubic-bezier()`, `steps()`), and `spring(stiffness damping mass)`. A spring has its own duration: the time until it rests.

## CSS keyframes

```tcl
ztk::style add {
    @keyframes pulse { from { background-color: #dbeafe; } to { background-color: #2563eb; } }
    #badge { animation: pulse 800ms ease-in-out infinite alternate; border-radius: 10px; padding: 4px 10px; }
}
label .badge -text "Live"
pack .badge -padx 20 -pady 20
```

## ztk::animate

`ztk::animate` moves widget options of the types color, distance, and number from their current values to new values.

```tcl
label .l -text "Hello" -background #dbeafe
pack .l -padx 20 -pady 20
set id [ztk::animate .l -background #2563eb -foreground white -duration 400 -easing ease-out]
```

```
ztk::animate target ?-option value ...? ?-duration ms? ?-easing name? ?-delay ms? ?-repeat count? ?-command script?
ztk::animate cancel|pause|resume id
ztk::animate info ?id?
ztk::animate reduce ?bool?
```

- The command returns an id such as `anim#1`. `cancel` keeps the shown value.
- A new animation of the same option starts from the shown value, so a fast series of changes does not jump.
- `-command` runs after the frame that showed the end value.
- A canvas item is a target too: `ztk::animate {.c tagOrId} -coords {10 10 90 60} -fill red -duration 300`.

## Reduced motion

`ztk::animate reduce 1`, `ZTK_NO_ANIMATION=1`, the setting `prefers-reduced-motion` of a browser, and the setting of the system for less motion (on Windows, the animation effects of the visual effects) show each end state at once. The setting of the system applies until a script calls `ztk::animate reduce` with a value.

## How smooth

On the development machine, a hover transition beside 1,000 widgets uses 1.36 ms of CPU time for a frame at the 99th percentile, and 1,000 `ztk::animate` moves at once use 7.20 ms. [Performance](performance.md) has the method.
