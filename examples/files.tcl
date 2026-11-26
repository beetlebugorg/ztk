# A file browser: a tree of folders, a list of files in columns, a
# combobox filter, and a paned window. It runs in ztk and in wish 8.6.
wm title . "Files"
ttk::frame .bar -padding {10 8}
ttk::label .bar.l -text "Show:"
ttk::combobox .bar.f -state readonly -width 14 -values {"All files" Documents Images} -textvariable show
set show "All files"
pack .bar.l -side left
pack .bar.f -side left -padx 6
pack .bar -fill x
ttk::panedwindow .p -orient horizontal
ttk::treeview .p.dirs -show tree -height 12
.p.dirs column #0 -width 160
foreach {id parent text} {home {} Home docs home Documents pics home Pictures trips pics Trips work docs Work src {} Projects} {
    .p.dirs insert $parent end -id $id -text $text -open 1
}
.p.dirs selection set docs
ttk::treeview .p.list -columns {size kind} -height 12
.p.list heading #0 -text Name -anchor w
.p.list heading size -text Size -anchor w
.p.list heading kind -text Kind -anchor w
.p.list column #0 -width 170
.p.list column size -width 70 -anchor e
.p.list column kind -width 110
foreach {name size kind} {Report.pdf "1.2 MB" PDF Budget.ods "88 KB" Spreadsheet Notes.txt "4 KB" Text Plan.odt "42 KB" Document} {
    .p.list insert {} end -text $name -values [list $size $kind]
}
.p.list selection set [lindex [.p.list children {}] 0]
.p add .p.dirs -weight 1
.p add .p.list -weight 3
pack .p -fill both -expand 1 -padx 10 -pady {0 10}
