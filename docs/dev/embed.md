# Plan: a child interpreter in a pane (`ztk::embed`)

This plan is for item 5 of the ztk features that dockyard needs: a child interpreter that owns a widget tree inside a pane of the parent app, with the sandbox of the child. Tk has `-container` and `-use` for X11 windows of other programs. This plan embeds an interpreter of the same program, and draws its scene in the scene of the parent.

## The interface

```tcl
interp create -safe app            ;# or a child with the capabilities of the project
frame .pane -container 1
ztk::embed create .pane app        ;# the child gets ztk, and its "." is .pane
ztk::limit -compute 5000000 -memory 64000000 {interp eval app {source /main.tcl}}
ztk::embed reset .pane             ;# destroys each widget of the child, keeps the interpreter
ztk::embed destroy .pane           ;# ends the App of the child
```

- The child is a ztcl child interpreter. The parent sets its capabilities with `interp create` and its limits with `ztk::limit`. The child gets no capability from the embed.
- In the child, `.` is a frame with the size of `.pane`. `wm` commands on `.` have no effect in the parent and give no error. A `toplevel` in the child is a pane in the same rectangle, above `.`.
- `ztk::embed create` gives an error when the pane is not a container, or when the interpreter already has ztk.

## The mechanism

1. A new backend, `src/platform/embed.zig`, implements `Platform` for the child. `createWindow` makes a virtual window with the rectangle of the pane. `requestFrame` asks the parent App for a frame. `poll` gives the events that the parent sends to the child. `nowUs` is the clock of the parent. The window has no surface and no renderer.
2. The child `App` uses the fonts and the atlas of the parent (a new field in `App.Options`). So the `uv` of a glyph or an image quad of the child is valid in the scene of the parent.
3. When the parent paints the pane, it runs the frame of the child App, and copies the quads of the child scene into the parent scene. Each quad moves by the origin of the pane, and its clip is the intersection with the clip of the pane. A quad has no pointer, so the copy is plain (`scene.zig`).
4. Input: the parent sends a pointer event inside the pane, and a key event when the pane has the focus, to the queue of the embed backend, with the coordinates of the pane.
5. An error in a script of the child goes to `bgerror` of the child, and then to the `-errorcommand` script of the embed in the parent, with the message and `errorInfo`.

## The order of the PRs

1. The embed backend and `App.Options.shared` (fonts and atlas), with unit tests on the headless backend: a child label shows in the scene of the parent at the origin of the pane.
2. `ztk::embed` and the copy of the scene in the paint of a container frame. Tests: geometry, clip, `reset`, `destroy`, and a child that runs out of its compute limit.
3. Input to the child, the focus, and the `-errorcommand`.
4. The docs (`docs/widgets/embed.md`, a line in `docs/differences.md`).

## Limits

- The child runs in the thread of the parent. A loop in the child stops the parent until `ztk::limit` ends it.
- The child shares the font cache of the parent. A child can grow the atlas. The memory limit of the child does not count the atlas.
- The out-of-process form (a child program that sends its scene and its atlas changes over a pipe) is out of this plan. It gives a stronger sandbox, and it can use the same scene copy.
