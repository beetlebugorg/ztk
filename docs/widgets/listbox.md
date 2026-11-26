# Listbox

**Live:** the Lists card of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery), and the layer list of the [vector tool](https://beetlebug.org/ztk/play/index.html?example=vector).

## listbox

![A listbox with four file names](../site/shots/widget-listbox-light.png)

<!-- widget: listbox; shot: update -->
```tcl
listbox .files -height 6 -selectmode extended -yscrollcommand {.sb set} -emptytext "No files"
scrollbar .sb -command {.files yview}
.files insert end report.pdf notes.txt photo.png budget.xlsx
bind .files <<ListboxSelect>> {puts [.files curselection]}
pack .files -side left -fill both -expand 1
pack .sb -side right -fill y

listbox .side -height 4 -activestyle none
.side insert end Inbox Drafts Sent Archive
ztk::class .side add sidebar
```

- The listbox has the options, the subcommands, and the four selection modes of Tk 8.6: `single`, `browse`, `multiple`, and `extended`. The pointer and the keys select rows as in `wish`, and a change by the user sends `<<ListboxSelect>>`.
- `-listvariable` links the rows to a list variable in both directions.
- When the selection moves from one row to another row, its background eases between the rows in 180 ms.
- A scroll eases, and a touchpad scrolls by pixels with momentum. A whole step of `yview scroll` or `yview moveto` puts a row at the top, as in Tk.
- The additions: `-emptytext` shows a text in an empty listbox, and the style class `sidebar` gives a list with no field and round accent rows.
- The parts `::item`, `::selection`, `::active`, and `::empty` accept CSS rules.
