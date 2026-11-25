# Scale and scrollbar

**Live:** the Scale and Scrollbar cards of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## scale

```tcl
set vol 40
scale .vol -orient horizontal -from 0 -to 100 -variable vol -tickinterval 25 -length 260
pack .vol -fill x -padx 12 -pady 8
```

- The slider follows the pointer on the render thread, so a drag stays smooth while the script is busy.
- The parts `::trough`, `::fill`, `::slider`, and `::value` accept CSS rules.

## scrollbar

```tcl
entry .e -width 22 -xscrollcommand {.s set}
scrollbar .s -orient horizontal -command {.e xview}
.e insert 0 "A long line of text that is wider than its entry, so the scrollbar under it moves the view."
pack .e .s -fill x -padx 12
```

- The modern scrollbar is an overlay. Its thumb shows while the view scrolls, on hover, and during a drag, and then fades out. The `classic` theme draws the scrollbar of Tk.
- A scroll by units or pages eases over 160 ms. A touchpad step adds momentum.
- The mouse wheel sends `<MouseWheel>` with `%D` (120 for one step), and `<Shift-MouseWheel>` for a horizontal step, as in Tk 8.7. A touchpad gives fractions of 120.
- The parts `::trough` and `::thumb` and the pseudo-class `:scrolling` accept CSS rules.
