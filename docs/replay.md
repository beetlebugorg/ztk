# Watch it get built

A person asks for an app, and an agent builds it in steps. Move the bar to a step: the window under the chat runs the app of that step, and you can click and type in it. Then the window runs the check of the step, a short Tcl script that the agent used to test its work with `ztk::tree` and `ztk::inject`.

<!-- replay: todo -->

This replay is a sample that a person wrote by hand, in the format that dockyard is to record. `tests/replay.sh` runs the script and the check of each step in `ztk --headless`, so each step of a replay works.

## The format

A replay is a JSON file with `version`, `title`, and `steps`. Each step has `who` (`person` or `agent`) and `say`. A step of the agent can also have `script`, the full Tcl text of the app after the step, and `check`, a Tcl script that gives 1 when the step works.
