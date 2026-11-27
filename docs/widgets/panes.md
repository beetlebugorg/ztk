# Panes and tabs

**Live:** the Panes and Tabs cards of the [gallery](https://beetlebug.org/ztk/play/index.html?example=gallery).

## panedwindow and ttk::panedwindow

![A window with a list of mail folders on the left and two panes on the right, one above the other, with a thin line between each pair of panes](../site/shots/widget-panedwindow-light.png)

<!-- widget: panedwindow; shot: update -->
```tcl
panedwindow .p
listbox .p.list -width 10
.p.list insert end Inbox Drafts Sent Archive Trash
.p.list selection set 0
ttk::panedwindow .p.right -orient vertical
label .p.right.mail -text "Drag a sash"
label .p.right.info -text "This pane gets twice the space"
.p.right add .p.right.mail -weight 1
.p.right add .p.right.info -weight 2
.p add .p.list -stretch never
.p add .p.right -stretch always
pack .p -fill both -expand 1 -padx 8 -pady 8
```


<!-- more: The details of panedwindow and ttk::panedwindow -->

- `panedwindow` puts its panes in a row (`-orient horizontal`) or a column, with a sash between two panes. It has the options, the pane options, and the subcommands of Tk 8.6: `add`, `forget`, `identify`, `panecget`, `paneconfigure`, `panes`, `proxy`, and `sash` with `coord`, `dragto`, `mark`, and `place`.
- A pane has the size of its widget, or its `-width` or `-height`, plus `-padx` or `-pady`. `-sticky` places the widget in its pane. `-stretch` picks the panes that get the extra space, or lose space, when the panedwindow changes size. A sash move stops at the `-minsize` of the panes.
- `ttk::panedwindow` has `add`, `forget`, `identify`, `insert`, `pane`, `panes`, and `sashpos`. A change of the size goes to the panes in proportion to their `-weight`. `sashpos` puts a sash between its neighbors and pushes them when it must.
- A press on a sash and a drag move it. The panes follow the pointer in each frame, and the render thread moves the sash with the pointer while a script is busy. With `-opaqueresize 0`, a drag moves a line, and the release moves the sash. `-showhandle` draws a handle on each sash.
- The pointer shape is a resize arrow over a sash, or the shape of `-sashcursor`.
- The modern theme draws a sash as a thin line in the part `::sash`. The sash under the pointer or in a drag fades to the part `::sash-active` in 120 ms.

<!-- end more -->

## ttk::notebook

![A notebook with the tabs General, Network, and Advanced, the General tab selected with a blue line under it, and a page with two check buttons](../site/shots/widget-notebook-light.png)

<!-- widget: notebook; shot: update -->
```tcl
ttk::notebook .n
foreach {page title} {general General network Network advanced Advanced} {
    ttk::frame .n.$page -padding 12
    .n add .n.$page -text $title -underline 0
}
set login 1
set menubar 0
ttk::checkbutton .n.general.a -text "Open at login" -variable login
ttk::checkbutton .n.general.b -text "Show in the menu bar" -variable menubar
pack .n.general.a .n.general.b -anchor w -pady 2
ttk::label .n.network.l -text "Proxy: none"
pack .n.network.l -anchor w
.n tab .n.advanced -state disabled
ttk::notebook::enableTraversal .n
pack .n -fill both -expand 1 -padx 8 -pady 8
```

<!-- toy-card: lamplighter -->

<!-- more: The details of ttk::notebook -->

- `ttk::notebook` has the subcommands of Tk 8.6: `add`, `forget`, `hide`, `identify`, `index`, `insert`, `select`, `tab`, and `tabs`, with `instate` and `state`. A tab is `normal`, `disabled`, or `hidden`, and it has `-text`, `-underline`, `-padding`, and `-sticky`.
- A click on a tab selects it. `Left` and `Right` move to the next tab that is not disabled, and `Control-Tab` and `Control-Shift-Tab` cycle the tabs. `ttk::notebook::enableTraversal` adds these keys to the whole window, with `Control-Page Up`, `Control-Page Down`, and `Alt` with the letter of `-underline`.
- Each change of the selected tab sends `<<NotebookTabChanged>>` after the script that made the change.
- The line under the selected tab slides to the new tab in 200 ms, and the new page fades in over 150 ms. A change during the slide starts from the shown place.
- The parts `::tab`, `::tab-selected`, `::tab-hover`, `::tab-disabled`, `::indicator`, and `::client` of `TNotebook` accept CSS rules.

<!-- end more -->
