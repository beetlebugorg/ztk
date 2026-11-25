# Embed in Zig

ztk is a Zig package. Your program makes a [ztcl](https://beetlebug.org/ztcl/) interpreter, a backend, and an `App`, and then runs a Tk script. To embed ztk in a web page, see [On the web](web.md).

> [!WARNING]
> The Zig API is the API of the `ztk` program, and it can change in any release.

## Add the package

```sh
zig fetch --save git+https://github.com/beetlebugorg/ztk
```

```zig
// build.zig
const dep = b.dependency("ztk", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ztk", dep.module("ztk"));
exe.root_module.addImport("ztcl", dep.builder.dependency("ztcl", .{
    .target = target,
    .optimize = optimize,
}).module("ztcl"));
```

The options `.backends = "headless"` and `.vulkan = false` give a build with no system library.

## Run a script

```zig
const std = @import("std");
const ztcl = @import("ztcl");
const ztk = @import("ztk");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var it: ztcl.Interp = undefined;
    try it.init(gpa);
    defer it.deinit();

    const head = try ztk.headless.Headless.init(gpa);
    defer head.deinit();
    const app = try ztk.App.init(gpa, &it, .{ .platform = head.platform() });
    defer app.deinit();
    app.max_frames = 1;

    try app.runScript(
        \\ttk::button .b -text "Hello from Zig" -command {puts clicked}
        \\pack .b -padx 20 -pady 20
    );
    try app.run();
}
```

`app.run()` runs the event loop until the window closes or `max_frames` frames are drawn. Add native commands to the interpreter with `it.register` before the script runs, and set `it.output` to get the text of `puts`.

## App options

| Option | Use |
|---|---|
| `platform` | The backend: `ztk.headless.Headless`, `ztk.wayland.Wayland`, or `ztk.direct.Direct`. |
| `dark` | True for the dark scheme. |
| `style_root`, `io` | The folder that `ztk::style load` reads. With no folder, the command gives an error. |
| `animations` | False shows each end state at once. |
| `render_mode` | `.threaded` draws on a render thread. The default draws on the thread of the script. |
| `on_exit` | What the command `exit` calls. |

The ztk library turns on no capability of ztcl, so a script has no file or network access unless your program gives it. [`src/main.zig`](../src/main.zig) is a complete program with each backend.
