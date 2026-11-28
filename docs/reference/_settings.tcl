# The settings of tools/refdoc.tcl for ztk. Each other .tcl file of this
# folder is one entry of the widget reference. The format is the format
# of ztcl: docs/dev/reference-format.md in the ztcl repository, with the
# same copy of tools/refdoc.tcl.

setting product ztk
setting site https://beetlebug.org/ztk/
setting repo https://github.com/beetlebugorg/ztk
# The folder of the pages of the entries, from the root of the site.
setting prefix reference/
# The first link of the breadcrumb.
setting index widgets/
setting index_label Widgets
setting areas widgets
# The checks run each example with `ztk --headless`, and `exit` ends the
# event loop after the examples. ztk has one Tcl release, so the file has
# no release.
setting flags --headless
setting epilog exit
