# The shape of a widget page

The user asked on 2026-11-25 that each widget page be interactive. Each widget that a task adds from task 12 on gets this shape in its section of `docs/widgets/`. A later docs pass gives the older widgets the same shape and builds the overview grid.

1. A screenshot of the widget at one fixed size: 360 by 240 logical pixels, drawn at scale 2, so the PNG files are 720 by 480 pixels. Each widget has a light shot and a dark shot in `docs/site/shots`, with the names `widget-<name>-light.png` and `widget-<name>-dark.png`.
2. A short Tcl snippet that runs alone in a window of 360 by 240 logical pixels. The site shows it as a live demo that the reader can edit, next to the running widget, with the playground of `play/` (the ztk web build). The snippet is the first `tcl` block of the section.
3. The text of the section: the options, the behavior, the animations, and the additions of ztk.

The line `<!-- widget: NAME; shot: SCRIPT -->` before the block marks the snippet. `tools/shots.sh` draws the shots from it, and `tools/build-docs.py` makes it a live snippet (`docs/site/live.js`). SCRIPT runs after the snippet for the shot only. Use `update` for a shot of the first frame, and `tests/docs-live.sh` then compares that shot with the first frame in the browser. A line `<!-- live -->` makes a live snippet with no shot.

A snippet uses only the commands of ztk, packs or grids its widgets into `.`, and has no `exit`. It shows the widget in a state that a reader can try: a menu bar with a menu that opens, a list with rows.
