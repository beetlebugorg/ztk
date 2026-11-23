# Task 04: The event loop adapter

**This task depends on the state of the ztcl event loop.** Read "The ztcl event loop" in [the task index](README.md) first.

## Goal

`after`, `update`, `vwait`, and `tkwait` work. All timer and idle work of ztk goes through one file, `src/loop.zig`, so that a later change to the loop of ztcl touches only that file.

## Files

- `src/loop.zig`
- `src/app.zig`: `doOneEvent`, `run`
- `src/cmds.zig`: the registration

## Interfaces

```zig
// src/loop.zig
/// The time source. A test gives a clock that it moves by hand.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Microseconds on a clock that does not go back.
    now: *const fn (ctx: ?*anyopaque) i64,
    /// Waits until `micros` passed or until the backend has an event.
    /// `micros` null means no limit.
    wait: *const fn (ctx: ?*anyopaque, micros: ?i64) void,
};
pub const TimerId = u64;
pub const Native = *const fn (ctx: ?*anyopaque) void;

pub const Loop = struct {
    pub fn init(app: *App, clock: Clock) Loop;
    pub fn deinit(l: *Loop) void;
    /// `after ms script`. The script text is copied.
    pub fn addTimer(l: *Loop, delay_ms: i64, script: []const u8) !TimerId;
    /// `after idle script`.
    pub fn addIdle(l: *Loop, script: []const u8) !TimerId;
    /// A timer for Zig code, for example the caret.
    pub fn addNative(l: *Loop, delay_us: i64, f: Native, ctx: ?*anyopaque) !TimerId;
    /// A native idle call, for example "draw the frame".
    pub fn addNativeIdle(l: *Loop, f: Native, ctx: ?*anyopaque) !TimerId;
    pub fn cancel(l: *Loop, id: TimerId) bool;
    /// Microseconds to the next timer. 0 when a timer is due or an idle
    /// entry exists. Null when no timer and no idle entry exists.
    pub fn nextTimeoutUs(l: *Loop) ?i64;
    /// Runs the timers that are due. Gives true when one ran.
    pub fn runTimers(l: *Loop) ztcl.Error!bool;
    /// Runs the idle entries that existed at the start of the call.
    pub fn runIdle(l: *Loop) ztcl.Error!bool;
};
```

```zig
// src/app.zig
/// One pass: window events, then due timers, then idle entries when the
/// first two did no work. With `wait`, it blocks until work exists.
/// Gives false when it did no work.
pub fn doOneEvent(app: *App, wait: bool) ztcl.Error!bool;
/// Runs passes until `.` is deleted.
pub fn run(app: *App) ztcl.Error!void;
/// Runs a callback script at the global level. An error goes to the
/// background error handler.
pub fn callback(app: *App, script: []const u8) void;
```

## Steps

1. Keep the timers in a list sorted by due time. Two timers with the same due time run in the order of their creation.
2. A timer that a script makes during `runTimers` does not run in the same call, even with a delay of 0.
3. `App.callback` sets `it.frame = &it.global` and `it.ns = ""`, evaluates the script, and puts both back. It counts the nesting of callbacks in `app.callback_depth`.
4. On `error.TclError` in a callback: when the command `bgerror` exists, call it with the message. In all other cases, write the value of `errorInfo` and a newline to the error output. `App.Options` gets `err_output: ?ztcl.Output = null`. With null, write to stderr.
5. The commands, with the result forms and the messages of `tclsh` 8.6:
   - `after ms`: waits. It runs no event. It uses `Clock.wait`.
   - `after ms script ?script ...?`: joins the scripts with a space (as `concat`), and returns `after#N`. N starts at 0 and counts up.
   - `after idle script ?script ...?`
   - `after cancel id` and `after cancel script ?script ...?`. An unknown id is not an error.
   - `after info` and `after info id`. The second form gives a list of the script and `timer` or `idle`. An unknown id gives `event "after#99" doesn't exist`.
   - A wrong first argument gives `bad argument "bogus": must be cancel, idle, info, or an integer`.
   - `update`: runs passes with no wait until a pass does no work.
   - `update idletasks`: runs only the idle entries.
   - `vwait name`: runs passes with a wait until the global variable is written. Set the flag with a script trace: `trace add variable <name> write {::ztk::priv::vwait <n>}`. Remove the trace at the end.
   - `tkwait variable name` is `vwait`. `tkwait window path` runs passes until the widget is deleted. `tkwait visibility` gives the error "not supported in this stage" and is Stage 2.
6. When a pass with a wait did no work and no timer and no idle entry exists, `vwait` gives the error `can't wait for variable "x": would wait forever`. That is the case on the headless backend with an empty queue. A backend with a real window always can give an event, so there `vwait` waits, as in `wish`. The text is the message of Tcl for this case. It was not seen in a run: `tclsh` 8.6.16 on the development machine waits with no end for `vwait x` in a script with no timer.
7. In this task no backend exists. `doOneEvent` handles timers and idle entries only. Task 05 adds the window events as the first step of the pass.
8. `run` returns when `app.root` is null.
9. First check the pinned ztcl: a test asserts that `it.findCommand("after") == null` before `App.init`. If it fails, stop and write `docs/tasks/BLOCKED.md`.

## Tests

```sh
zig build test -Dtest-filter=loop
```

All tests use a `Harness` with a manual clock: `h.clock.advance(ms)` moves the time, and `wait` moves the time to the next timer.

- `after 100 {set x 1}`, then `update` with no time change: `x` does not exist. After `advance(100)` and `update`: `x` is `1`.
- Three timers for 30, 10, and 20 ms that append to a list give the order `10 20 30`.
- Two timers for the same time run in creation order.
- `after cancel` by id and by script. The timer does not run.
- `after info` lists the ids. `after info <id>` gives `{set x 1} timer`.
- `after idle {lappend l i}; after 0 {lappend l t}; update` gives `t i`.
- An idle entry that adds an idle entry: the new entry runs in the next pass, and `update` still ends.
- `after 50 {set done 1}; vwait done` returns, and the manual clock is at 50 ms or later.
- `vwait nosuch` with no timer gives the `would wait forever` message.
- A timer script with an error calls `bgerror` with the message. With no `bgerror`, the error output gets the trace.
- `after 10 {after 0 {set y 1}}`: `y` is set after a second pass, and not in the pass of the first timer.
- `tkwait window .f` returns after a timer deletes `.f`.

## Acceptance

- All tests pass, with no real sleep in a test.
- No file other than `src/loop.zig` has a timer list.
- `grep -n '"after"' src/` shows the registration in one place.

## Out of scope

- `fileevent` and channels.
- The loop of ztcl. A later task changes the inside of this file.
- `tkwait visibility`.
- Window events. Task 05.
