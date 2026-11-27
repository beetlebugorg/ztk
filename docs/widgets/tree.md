# Tree

**Live:** the [playground](https://beetlebug.org/ztk/play/index.html) runs the example below.

## ttk::treeview

![A tree of files with the columns Name, Size, and Modified, an open folder, and a selected row](../site/shots/widget-treeview-light.png)

<!-- widget: treeview; shot: update -->
```tcl
ttk::treeview .t -columns {size modified} -height 6
.t heading #0 -text Name -anchor w
.t heading size -text Size -anchor w
.t heading modified -text Modified -anchor w
.t column #0 -width 150
.t column size -width 70 -anchor e
.t column modified -width 100
.t insert {} end -id docs -text Documents -open 1
.t insert docs end -text Report.pdf -values {"1.2 MB" "Nov 24"}
.t insert docs end -text Budget.ods -values {"88 KB" "Nov 20"}
.t insert {} end -id pics -text Pictures -values {"" "Nov 18"}
.t insert pics end -text beach.png -values {"2.4 MB" "Nov 18"}
.t insert {} end -text notes.txt -values {"4 KB" Today}
.t selection set [lindex [.t children docs] 0]
pack .t -fill both -expand 1 -padx 8 -pady 8
focus .t
```


<!-- more: The details of ttk::treeview -->

- The tree has the options, the item options, the column options, the heading options, the tag options, and the subcommands of `ttk_treeview.n`: `bbox`, `children`, `column`, `delete`, `detach`, `exists`, `focus`, `heading`, `identify`, `index`, `insert`, `item`, `move`, `next`, `parent`, `prev`, `see`, `selection`, `set`, `tag`, `xview`, and `yview`.
- A click selects a row, Shift extends the selection, and Control toggles a row with `-selectmode extended`. A click on the arrow or a double click opens and closes an item. The arrow keys move the focus, Right opens an item, and Left closes it. `<<TreeviewSelect>>`, `<<TreeviewOpen>>`, and `<<TreeviewClose>>` come as in `wish`.
- An item opens and closes with a move of the rows below it, and its arrow turns.
- A drag of the border at the right of a heading changes the width of the column. A click on a heading runs its `-command`.
- `tag configure` gives rows colors and fonts, and `tag bind` runs a script for the events of the rows with the tag.
- `-emptytext` shows a text when the tree has no items. The style class `sidebar` (`ztk::class .t sidebar`) gives a tree with no border, for the side of a window.

<!-- end more -->
