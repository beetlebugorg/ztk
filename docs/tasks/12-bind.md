# Task 12: Events, `bind`, and `event generate`

This task uses the loop of task 04 for `update`. It does not depend on the loop of ztcl.

## Goal

Pointer and key events of the backend go to widgets. A script reacts with `bind`. `event generate` makes events for tests. The state bits `hover` and `pressed` follow the pointer.

## Files

- `src/bind.zig`: patterns, the binding table, matching, `%` fields, the `bind` and `bindtags` commands
- `src/dispatch.zig`: from a backend `Event` to widget events, `event generate`
- `src/widget.zig`: `Widget.bindtags`
- `src/app.zig`

## Interfaces

```zig
// src/bind.zig
pub const EventType = enum(u8) {
    key_press = 2, key_release = 3, button_press = 4, button_release = 5,
    motion = 6, enter = 7, leave = 8, focus_in = 9, focus_out = 10,
    destroy = 17, unmap = 18, map = 19, configure = 22, virtual = 35,
};
pub const Pattern = struct {
    type: EventType,
    mods: event.Mods = .{},     // the modifiers that the pattern needs
    count: u8 = 1,              // 2 for Double, 3 for Triple, 4 for Quadruple
    detail: u32 = 0,            // a button number or a key symbol; 0 is any
    virtual: []const u8 = "",   // the name of a virtual event
};
/// Parses one event pattern: "<Control-Button-1>", "<<Copy>>", "a".
pub fn parsePattern(it: *ztcl.Interp, text: []const u8) ztcl.Error!Pattern;
/// The canonical text of a pattern, as `bind tag` lists it.
pub fn formatPattern(p: Pattern, buf: []u8) []const u8;
/// One event for a widget, with the data of the `%` fields.
pub const WidgetEvent = struct {
    type: EventType,
    widget: *Widget,
    x: i32 = 0, y: i32 = 0,            // in the widget
    root_x: i32 = 0, root_y: i32 = 0,
    button: u8 = 0,
    keysym: u32 = 0, keycode: u32 = 0,
    text: []const u8 = "",             // %A
    mods: event.Mods = .{},
    time_ms: u32 = 0,
    width: i32 = 0, height: i32 = 0,   // configure
    count: u8 = 1,                     // the click count
    serial: u32 = 0,                   // %#
    virtual: []const u8 = "",
    data: []const u8 = "",             // %d of a virtual event
};
pub const Table = struct {
    pub fn init(gpa: std.mem.Allocator) Table;
    pub fn deinit(t: *Table) void;
    /// Sets, appends to ("+script"), or deletes ("") a binding.
    pub fn set(t: *Table, tag: []const u8, p: Pattern, script: []const u8) !void;
    pub fn get(t: *const Table, tag: []const u8, p: Pattern) ?[]const u8;
    /// The patterns of a tag, in the order of `wish`.
    pub fn list(t: *const Table, tag: []const u8, gpa: std.mem.Allocator) ![]Pattern;
    /// The script of the most specific pattern of the tag that matches.
    pub fn match(t: *const Table, tag: []const u8, ev: *const WidgetEvent) ?[]const u8;
    pub fn removeTag(t: *Table, tag: []const u8) void;
};
/// Replaces the `%` fields of a script.
pub fn substitute(gpa: std.mem.Allocator, script: []const u8, ev: *const WidgetEvent) ![]u8;
/// Runs the bindings of an event for each tag of the widget.
pub fn deliver(app: *App, ev: *const WidgetEvent) void;

// src/dispatch.zig
/// Turns one backend event into widget events and delivers them.
pub fn handle(app: *App, ev: event.Event) void;
/// The widget at a point of a toplevel: the top mapped widget that has it.
pub fn widgetAt(top: *Widget, x: i32, y: i32) *Widget;
```

## Steps

1. Read `doc/bind.n`. The sections "EVENT PATTERNS", "MODIFIERS", "EVENT TYPES", "BINDING SCRIPTS AND SUBSTITUTIONS", and "MULTIPLE MATCHES" define this task.
2. `parsePattern`:
   - `<mod-mod-type-detail>`. The types of Stage 1 and their short names: `ButtonPress` and `Button`, `ButtonRelease`, `Motion`, `Enter`, `Leave`, `KeyPress` and `Key`, `KeyRelease`, `FocusIn`, `FocusOut`, `Configure`, `Destroy`, `Map`, `Unmap`.
   - The modifiers: `Control`, `Shift`, `Lock`, `Alt`, `Meta` and `M`, `Mod1` to `Mod5` and `M1` to `M5`, `Button1` to `Button5` and `B1` to `B5`, `Double`, `Triple`, `Quadruple`, and `Any` (no effect). `Alt` is `mod1`. `Meta` is `mod1` in Stage 1, with a note in `docs/stage1-limits.md`.
   - `<1>` is `<Button-1>`. `<a>` and the plain character `a` are `<KeyPress-a>`. A detail with no type is a button when it is a digit from 1 to 5, and a key symbol in all other cases.
   - `<<Name>>` is a virtual event.
   - A sequence of two patterns (`<Control-x><Control-s>`) gives the error `event sequences are not supported in this stage`.
   - The errors of `wish`: `bad event type or keysym "Foo"` and `bad button number "9"`.
3. `formatPattern` gives the canonical text of `wish`: `<Button-1>`, `<Key>`, `<Control-Shift-Key-a>`, `<Key-b>`, and for a plain printable key with no modifier the character alone (`a`). `wish` lists `a <Key> b <Control-Shift-Key-a> <Button-1>` for the bindings of the tests below. Keep the list order of `wish` if it follows a clear rule (the newest first for these five). If no rule is clear, use the newest first and note it.
4. `Table.match`. A pattern matches an event when the type is equal, the detail is 0 or equal, each modifier of the pattern is in the event, and the click count of the event is at least the count of the pattern. Among the matches, the most specific wins, by the rules of "MULTIPLE MATCHES" in this order: a pattern with a detail before one with none, a higher count before a lower one, more modifiers before fewer, a physical pattern before a virtual one, and the newest binding last.
5. `deliver` runs the tags of `w.bindtags` in order. For each tag it runs the script of `match`. The result code `break` stops the later tags. `continue` stops the script and goes to the next tag. An error goes to the background error handler and stops the later tags. When the widget is deleted during a script, stop.
6. The default tags of a widget are its path, its class, the path of its toplevel (only when the widget is not the toplevel), and `all`. The order `widget class toplevel all` is from `wish`.
7. `substitute`. The fields of Stage 1: `%%`, `%W` (the path), `%x`, `%y`, `%X`, `%Y`, `%b`, `%k`, `%K` (the key symbol name), `%A` (the text), `%s` (the modifier state as a number with the X11 bit values: shift 1, lock 2, control 4, mod1 8, mod2 16, mod3 32, mod4 64, mod5 128, button1 256 to button5 4096), `%t`, `%T` (the type number), `%h`, `%w`, `%#`, and `%d`. A field that does not apply to the event type gives `??`. Each other letter after `%` stays as that letter. The value of `%A`, `%W`, and `%d` is quoted as a list element, as `bind.n` says.
8. A script with no `%` compiles one time (`it.compile`) and runs with `it.evalTop`. Keep the compiled script with the binding, and compile again after `App.script_gen` changes (task 18 changes it). A script with `%` is substituted and evaluated with `it.eval` at each event.
9. `bind tag`, `bind tag pattern`, `bind tag pattern script`, with `+script` and the empty script. `bindtags path ?list?`. An empty list puts the default tags back, as in `wish`.
10. `dispatch.handle`:
    - `motion`: find the widget under the pointer. When it differs from the last one, deliver `Leave` to the old widget and `Enter` to the new one, and change their `hover` bits. Then deliver `Motion`. Stage 1 sends no `Enter` or `Leave` to the ancestors.
    - `button` press: deliver `ButtonPress` to the widget under the pointer. That widget keeps the pointer until all buttons are up: `Motion` and `ButtonRelease` go to it. Set its `pressed` bit for button 1. When the pointer is outside it during the press, the `hover` bit is off.
    - A second press of the same button in 500 ms and at most 5 pixels from the first has the count 2, then 3, then 4.
    - `button` release: deliver `ButtonRelease`, clear `pressed`, then find the widget under the pointer again and send `Leave` and `Enter` when it changed.
    - `leave`: deliver `Leave` to the widget under the pointer and clear the hover.
    - `key`: task 13 sends it to the focus widget. In this task it goes to the toplevel.
    - `resize`: deliver `Configure` to the toplevel after the layout, and to each widget whose size or position changed.
    - A state bit change sets the style flag of the widget.
    - Motion events collapse. When the list of one `poll` has several `motion` events for one window with no other event between them, only the last one is handled. Each other event is handled, in order. No button event, key event, or text is ever dropped, also when a frame is slow. Printdeck lost keys when its event queue was full, before it had this rule.
11. `destroy` delivers `Destroy` to each widget before it deletes it, children first. `Map` and `Unmap` go to a widget when its `mapped` flag changes.
12. `event generate path pattern ?option value ...?`. It builds a `WidgetEvent` and calls `deliver` at once (`-when now`). The options of Stage 1: `-x`, `-y`, `-rootx`, `-rooty`, `-button`, `-keysym`, `-keycode`, `-state`, `-time`, `-data`, and `-when` with only `now`. Each other option of the list of `wish` gives `event generate option "-warp" is not supported in this stage`. An unknown option gives the `bad option` message of `wish` with its complete list. For a key pattern, `%A` is the character of the key symbol when it is printable. For a button or a key event, `event generate` also updates the click count, and it changes no pointer position and no state bit.
13. `event add`, `event delete`, and `event info` are Stage 2. In Stage 1 a virtual event runs only from `event generate`.

## Tests

```sh
zig build test -Dtest-filter=bind
zig build test -Dtest-filter=dispatch
```

Unit tests:

- `parsePattern` of `<1>`, `<Button-1>`, and `<ButtonPress-1>` are equal. `a`, `<a>`, `<Key-a>`, and `<KeyPress-a>` are equal.
- `<Control-Shift-a>` has both modifiers. `<Double-1>` has the count 2. `<<Foo>>` is virtual.
- `<Foo-1>` and `<Button-9>` give the two error messages.
- `formatPattern(parsePattern(x))` for `<Button-1>`, `<Key>`, `<Control-Shift-Key-a>`, and `a`.
- `substitute("%x,%y,%b,%W,%T,%%", ...)` for a press of button 2 at (5, 6) on `.f` gives `5,6,2,.f,4,%`.
- `%W` of a path with a space is quoted as a list element.

Script tests with a `Harness`. The expected values are from `wish` 8.6.16. `.f` is a frame of 100 by 100 and `.b` is a label, both in a grid.

- Bindings for `<1>` on `.b` (`w`), its class (`c`), `.` (`t`), and `all` (`a`), then `event generate .b <1>`: the log is `w c t a`.
- With `break` in the widget binding: the log is `w`.
- `bind .b <1> {+lappend log w2}` appends: `bind .b <1>` gives two lines.
- `bind .b <1> {}` deletes: `bind .b` is empty.
- `bind .b <Button-1> x; bind .b <ButtonPress-1>` gives `x`.
- `<Key>`, `<Key-a>`, and `<Control-Key-a>` on `.f`, and the events `<Key-a>`, `<Control-Key-a>`, `<Key-b>`: the log is `a ca any`.
- `<1>` and `<Double-1>` on `.f`, and `event generate .f <1>` two times: the log has `S` and then `D`.
- `bind .f <<Foo>> {lappend log v%d}; event generate .f <<Foo>> -data hello` gives `vhello`.
- `bindtags .b` gives `.b Label . all`. `bindtags .b {.b all}` then gives `.b all`. `bindtags .b {}` gives the default again.
- `event generate .zz <1>` gives `bad window path name ".zz"`.
- Backend input: `h.head.pointerMove` from outside to inside `.f` runs `<Enter>` with the correct `%x`. A move to `.b` runs `<Leave>` on `.f` and `<Enter>` on `.b`.
- A press on `.f`, a move to `.b`, and a release: `.f` gets the `Motion` and the `ButtonRelease`, and `.b` gets an `Enter` after the release.
- `.f` has the `hover` bit while the pointer is on it, and the `pressed` bit while button 1 is down.
- A binding that deletes its own widget gives no crash, and the later tags do not run.
- A binding with an error calls `bgerror` one time.
- `bind .f <Destroy> {lappend log gone}; destroy .f` gives `gone`.
- A `resize` event runs a `<Configure>` binding of `.` with the new `%w` and `%h`.
- Five `pointerMove` calls before one `update` run a `<Motion>` binding one time, with the last position. A press between the third and the fourth move gives two `<Motion>` calls and the press at the third position.
- 200 key presses that are queued before one `update` all arrive, in order.

## Acceptance

- All tests pass.
- A `Motion` event with no binding for it allocates no memory (check with a counting allocator in a test).
- 100 000 `Motion` events with one binding that has no `%` field run in under 150 ms in `ReleaseFast`. Print the time in a test with the name `bind-speed`.

## Out of scope

- Event sequences, `event add`, the physical keys of virtual events, `-when tail`, and `-warp`.
- `Enter` and `Leave` for ancestors, with their detail field.
- The mouse wheel, `grab`, and the other event types.
- Focus. Task 13.
