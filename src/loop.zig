//! The event loop adapter. It keeps the timers and the idle list of ztk
//! and registers `after`, `update`, `vwait`, and `tkwait`. No other file
//! has a timer list or registers these commands, so a later change to the
//! loop of ztcl touches only this file.
//!
//! Timers are in a list sorted by due time. Timers with the same due time
//! keep the order of their creation. Each entry has a sequence number.
//! `runTimers` and `runIdle` run only the entries that existed when the
//! call started, so a timer that a timer makes waits for the next call.
//! A script entry has the id `after#N`. Native entries have ids from
//! 2^32, so they do not change the numbers of script entries.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const host = @import("sys/host.zig");
const ztcl = @import("ztcl");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Value = ztcl.Value;

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

fn sysNow(_: ?*anyopaque) i64 {
    return host.nowUs();
}

fn sysWait(_: ?*anyopaque, micros: ?i64) void {
    const us = micros orelse return;
    host.sleepUs(us);
}

/// The monotonic clock of the system, with a sleep for the wait.
pub const system_clock: Clock = .{ .now = sysNow, .wait = sysWait };

const Entry = struct {
    id: TimerId,
    seq: u64,
    idle: bool,
    due: i64 = 0,
    /// Owned by the App allocator. Empty for a native entry.
    script: []u8 = &.{},
    native: ?Native = null,
    ctx: ?*anyopaque = null,
};

const Wait = struct { id: u64, done: bool = false };

/// A wait of the main script that runs with no script on the stack.
const Parked = union(enum) {
    /// The id in `waits` and the variable name. Owned by the App allocator.
    variable: struct { id: u64, name: []u8 },
    /// The path of the widget. Owned by the App allocator.
    window: []u8,
};

pub const Loop = struct {
    app: *App,
    clock: Clock,
    timers: std.ArrayListUnmanaged(Entry) = .empty,
    idles: std.ArrayListUnmanaged(Entry) = .empty,
    next_seq: u64 = 0,
    next_script_id: u64 = 0,
    next_native_id: u64 = 1 << 32,
    waits: std.ArrayListUnmanaged(Wait) = .empty,
    next_wait: u64 = 0,
    /// Set by a top-level `vwait` or `tkwait window`. `App.runScript` runs it.
    parked: ?Parked = null,
    /// True when a compact dropped the trace of the parked `vwait` and it could not come back.
    parked_lost: bool = false,

    pub fn init(app: *App, clock: Clock) Loop {
        return .{ .app = app, .clock = clock };
    }

    pub fn deinit(l: *Loop) void {
        const gpa = l.app.gpa;
        for (l.timers.items) |e| gpa.free(e.script);
        for (l.idles.items) |e| gpa.free(e.script);
        l.clearParked();
        l.timers.deinit(gpa);
        l.idles.deinit(gpa);
        l.waits.deinit(gpa);
    }

    fn insertTimer(l: *Loop, e: Entry) !void {
        var i = l.timers.items.len;
        while (i > 0 and l.timers.items[i - 1].due > e.due) i -= 1;
        try l.timers.insert(l.app.gpa, i, e);
    }

    fn newEntry(l: *Loop, idle: bool, script: []const u8) !Entry {
        const owned = try l.app.gpa.dupe(u8, script);
        const e: Entry = .{ .id = l.next_script_id, .seq = l.next_seq, .idle = idle, .script = owned };
        l.next_script_id += 1;
        l.next_seq += 1;
        return e;
    }

    /// `after ms script`. The script text is copied.
    pub fn addTimer(l: *Loop, delay_ms: i64, script: []const u8) !TimerId {
        var e = try l.newEntry(false, script);
        errdefer l.app.gpa.free(e.script);
        e.due = l.clock.now(l.clock.ctx) +| @max(delay_ms, 0) *| 1000;
        try l.insertTimer(e);
        return e.id;
    }

    /// `after idle script`.
    pub fn addIdle(l: *Loop, script: []const u8) !TimerId {
        const e = try l.newEntry(true, script);
        errdefer l.app.gpa.free(e.script);
        try l.idles.append(l.app.gpa, e);
        return e.id;
    }

    fn nativeEntry(l: *Loop, idle: bool, f: Native, ctx: ?*anyopaque) Entry {
        const e: Entry = .{ .id = l.next_native_id, .seq = l.next_seq, .idle = idle, .native = f, .ctx = ctx };
        l.next_native_id += 1;
        l.next_seq += 1;
        return e;
    }

    /// A timer for Zig code, for example the caret.
    pub fn addNative(l: *Loop, delay_us: i64, f: Native, ctx: ?*anyopaque) !TimerId {
        var e = l.nativeEntry(false, f, ctx);
        e.due = l.clock.now(l.clock.ctx) +| @max(delay_us, 0);
        try l.insertTimer(e);
        return e.id;
    }

    /// A native idle call, for example "draw the frame".
    pub fn addNativeIdle(l: *Loop, f: Native, ctx: ?*anyopaque) !TimerId {
        const e = l.nativeEntry(true, f, ctx);
        try l.idles.append(l.app.gpa, e);
        return e.id;
    }

    pub fn cancel(l: *Loop, id: TimerId) bool {
        const gpa = l.app.gpa;
        for (l.timers.items, 0..) |e, i| if (e.id == id) {
            gpa.free(e.script);
            _ = l.timers.orderedRemove(i);
            return true;
        };
        for (l.idles.items, 0..) |e, i| if (e.id == id) {
            gpa.free(e.script);
            _ = l.idles.orderedRemove(i);
            return true;
        };
        return false;
    }

    /// Microseconds to the next timer. 0 when a timer is due or an idle
    /// entry exists. Null when no timer and no idle entry exists.
    pub fn nextTimeoutUs(l: *Loop) ?i64 {
        if (l.idles.items.len > 0) return 0;
        if (l.timers.items.len == 0) return null;
        return @max(0, l.timers.items[0].due - l.clock.now(l.clock.ctx));
    }

    fn run(l: *Loop, e: Entry) void {
        if (e.native) |f| {
            f(e.ctx);
        } else {
            defer l.app.gpa.free(e.script);
            l.app.callback(e.script);
        }
    }

    fn clearParked(l: *Loop) void {
        const gpa = l.app.gpa;
        const p = l.parked orelse return;
        switch (p) {
            .variable => |v| {
                dropWait(l, v.id);
                gpa.free(v.name);
            },
            .window => |path| gpa.free(path),
        }
        l.parked = null;
    }

    /// Adds the trace of the parked `vwait` again after a compact.
    pub fn retraceParked(l: *Loop) void {
        const p = l.parked orelse return;
        if (p == .variable) waitTrace(l.app.it, "add", p.variable.name, p.variable.id) catch {
            l.parked_lost = true;
        };
    }

    /// Runs the event loop for the parked wait. It compacts at each step.
    /// Gives false when the program ends before the wait does.
    pub fn runParked(l: *Loop) ztcl.Error!bool {
        const app = l.app;
        const it = app.it;
        defer {
            if (l.parked) |p| if (p == .variable) {
                const saved = it.result;
                waitTrace(it, "remove", p.variable.name, p.variable.id) catch {};
                it.result = saved;
            };
            l.clearParked();
        }
        while (true) {
            const p = l.parked.?;
            const done = switch (p) {
                .variable => |v| waitDone(l, v.id),
                .window => |path| app.find(path) == null,
            };
            if (done) return true;
            // With no trace, a write cannot end this wait.
            if (l.parked_lost) {
                l.parked_lost = false;
                return it.fail("can't wait for variable \"{s}\": its trace was lost", .{p.variable.name});
            }
            if (app.root == null) return false;
            if (app.max_frames) |m| if (app.frames >= m) return false;
            _ = app.maybeCompact();
            const worked = try app.doOneEvent(true);
            if (!worked and !app.canWait()) return switch (p) {
                .variable => |v| waitForever(it, "variable", v.name),
                .window => |path| waitForever(it, "window", path),
            };
        }
    }

    /// Runs the timers that are due. Gives true when one ran.
    pub fn runTimers(l: *Loop) ztcl.Error!bool {
        const limit = l.next_seq;
        const now = l.clock.now(l.clock.ctx);
        var ran = false;
        while (true) {
            var pick: ?usize = null;
            for (l.timers.items, 0..) |e, i| {
                if (e.due > now) break;
                if (e.seq < limit) {
                    pick = i;
                    break;
                }
            }
            const i = pick orelse break;
            const e = l.timers.orderedRemove(i);
            l.run(e);
            ran = true;
        }
        return ran;
    }

    /// Runs the idle entries that existed at the start of the call.
    pub fn runIdle(l: *Loop) ztcl.Error!bool {
        const limit = l.next_seq;
        var ran = false;
        while (l.idles.items.len > 0 and l.idles.items[0].seq < limit) {
            const e = l.idles.orderedRemove(0);
            l.run(e);
            ran = true;
        }
        return ran;
    }
};

// ---- commands ----

fn wrongOption(it: *ztcl.Interp, comptime what: []const u8, got: []const u8) ztcl.Error {
    return it.fail("bad " ++ what ++ " \"{s}\": must be cancel, idle, info, or an integer", .{got});
}

/// The id number of the text "after#N", or null.
fn parseId(text: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, text, "after#")) return null;
    return std.fmt.parseInt(u64, text["after#".len..], 10) catch null;
}

fn joinScripts(it: *ztcl.Interp, words: []const Value) ztcl.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const a = it.alloc();
    for (words, 0..) |w, i| {
        if (i > 0) try out.append(a, ' ');
        try out.appendSlice(a, try it.str(w));
    }
    return out.items;
}

fn idName(it: *ztcl.Interp, id: u64) ![]const u8 {
    return std.fmt.allocPrint(it.alloc(), "after#{d}", .{id});
}

fn startsWith(word: []const u8, text: []const u8) bool {
    return text.len > 0 and std.mem.startsWith(u8, word, text);
}

fn cmdAfter(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const l = &app.loop;
    if (argv.len < 2) return it.wrongArgs("after option ?arg ...?");
    const first = try it.str(argv[1]);
    if (argv[1].asInt() orelse std.fmt.parseInt(i64, std.mem.trim(u8, first, " "), 0) catch null) |ms| {
        if (argv.len == 2) {
            l.clock.wait(l.clock.ctx, @max(ms, 0) *| 1000);
            return Value.empty;
        }
        const script = try joinScripts(it, argv[2..]);
        const id = l.addTimer(ms, script) catch return error.OutOfMemory;
        return .{ .str = try idName(it, id) };
    }
    if (startsWith("idle", first) and first.len >= 2) {
        if (argv.len < 3) return it.wrongArgs("after idle script ?script ...?");
        const id = l.addIdle(try joinScripts(it, argv[2..])) catch return error.OutOfMemory;
        return .{ .str = try idName(it, id) };
    }
    if (startsWith("cancel", first)) {
        if (argv.len < 3) return it.wrongArgs("after cancel id|command");
        const arg = try it.str(argv[2]);
        if (argv.len == 3) if (parseId(arg)) |id| {
            _ = l.cancel(id);
            return Value.empty;
        };
        const script = try joinScripts(it, argv[2..]);
        // Newest first, as the list of `after info`.
        var best: ?u64 = null;
        for ([_][]const Entry{ l.timers.items, l.idles.items }) |list| {
            for (list) |e| {
                if (e.native == null and std.mem.eql(u8, e.script, script) and (best == null or e.id > best.?)) best = e.id;
            }
        }
        if (best) |id| _ = l.cancel(id);
        return Value.empty;
    }
    if (startsWith("info", first) and first.len >= 2) {
        if (argv.len > 3) return it.wrongArgs("after info ?id?");
        const a = it.alloc();
        if (argv.len == 3) {
            const name = try it.str(argv[2]);
            const id = parseId(name);
            for ([_][]const Entry{ l.timers.items, l.idles.items }) |list| {
                for (list) |e| if (e.native == null and id != null and e.id == id.?) {
                    const kind: []const u8 = if (e.idle) "idle" else "timer";
                    return ztcl.value.newList(a, &.{ .{ .str = try a.dupe(u8, e.script) }, .{ .str = kind } });
                };
            }
            return it.fail("event \"{s}\" doesn't exist", .{name});
        }
        var ids: std.ArrayList(u64) = .empty;
        for ([_][]const Entry{ l.timers.items, l.idles.items }) |list| {
            for (list) |e| if (e.native == null) try ids.append(a, e.id);
        }
        std.mem.sort(u64, ids.items, {}, std.sort.desc(u64));
        const items = try a.alloc(Value, ids.items.len);
        for (ids.items, items) |id, *slot| slot.* = .{ .str = try idName(it, id) };
        return ztcl.value.wrapList(a, items);
    }
    return wrongOption(it, "argument", first);
}

fn cmdUpdate(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len > 2) return it.wrongArgs("update ?idletasks?");
    if (argv.len == 2) {
        const sub = try it.str(argv[1]);
        if (!startsWith("idletasks", sub)) return it.fail("bad option \"{s}\": must be idletasks", .{sub});
        while (try app.loop.runIdle()) {}
        if (app.root) |r| _ = app.frame(r) catch |e| app.frameError(e);
        app.flushRender();
        return Value.empty;
    }
    while (try app.doOneEvent(false)) {}
    try app.flush();
    app.flushRender();
    return Value.empty;
}

/// The command that a variable trace calls. It marks the wait as done.
fn cmdVwaitMark(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("::ztk::priv::vwait id");
    const id: u64 = std.math.cast(u64, argv[1].asInt() orelse return Value.empty) orelse return Value.empty;
    for (app.loop.waits.items) |*w| if (w.id == id) {
        w.done = true;
    };
    return Value.empty;
}

fn waitDone(l: *Loop, id: u64) bool {
    for (l.waits.items) |w| if (w.id == id) return w.done;
    return true;
}

fn waitForever(it: *ztcl.Interp, what: []const u8, name: []const u8) ztcl.Error {
    return it.fail("can't wait for {s} \"{s}\": would wait forever", .{ what, name });
}

fn dropWait(l: *Loop, id: u64) void {
    for (l.waits.items, 0..) |w, i| if (w.id == id) {
        _ = l.waits.orderedRemove(i);
        return;
    };
}

/// Adds or removes the write trace of a wait.
fn waitTrace(it: *ztcl.Interp, verb: []const u8, name: []const u8, id: u64) ztcl.Error!void {
    const a = it.alloc();
    const script = try std.fmt.allocPrint(a, "::ztk::priv::vwait {d}", .{id});
    const words = [_]Value{ .{ .str = "trace" }, .{ .str = verb }, .{ .str = "variable" }, .{ .str = try a.dupe(u8, name) }, .{ .str = "write" }, .{ .str = script } };
    _ = try App.of(it).callTrace(&words);
}

/// True for a command that is a top-level command of the main script:
/// no script, proc, or substitution is on the stack around it.
fn atScriptTop(it: *ztcl.Interp) bool {
    const app = App.of(it);
    return app.script_top and it.nest == 1 and it.depth == 0 and it.frame == &it.global and app.callback_depth == 0;
}

fn vwait(it: *ztcl.Interp, name: []const u8) ztcl.Error!Value {
    const app = App.of(it);
    const l = &app.loop;
    const id = l.next_wait;
    l.next_wait += 1;
    try l.waits.append(app.gpa, .{ .id = id });
    errdefer dropWait(l, id);
    try waitTrace(it, "add", name, id);
    if (atScriptTop(it)) {
        errdefer waitTrace(it, "remove", name, id) catch {};
        l.parked = .{ .variable = .{ .id = id, .name = try app.gpa.dupe(u8, name) } };
        return Value.empty;
    }
    defer dropWait(l, id);
    // The trace goes away at the end, also after an error.
    defer {
        const saved = it.result;
        waitTrace(it, "remove", name, id) catch {};
        it.result = saved;
    }
    while (!waitDone(l, id)) {
        const worked = try app.doOneEvent(true);
        if (!worked and !app.canWait()) return waitForever(it, "variable", name);
    }
    return Value.empty;
}

fn cmdVwait(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    if (argv.len != 2) return it.wrongArgs("vwait name");
    return vwait(it, try it.str(argv[1]));
}

fn cmdTkwait(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    const usage = "tkwait variable|visibility|window name";
    if (argv.len != 3) return it.wrongArgs(usage);
    const sub = try it.str(argv[1]);
    if (sub.len >= 2 and startsWith("variable", sub)) return vwait(it, try it.str(argv[2]));
    if (sub.len >= 2 and startsWith("visibility", sub)) {
        // The wait ends when the widget and its ancestors are mapped, as
        // after the first VisibilityNotify of Tk.
        const path = try it.str(argv[2]);
        if (app.find(path) == null) return it.fail("bad window path name \"{s}\"", .{path});
        while (true) {
            app.flush() catch {};
            const w = app.find(path) orelse return it.fail("window \"{s}\" was deleted before its visibility changed", .{path});
            var shown = true;
            var x: ?*@import("widget.zig").Widget = w;
            while (x) |p| : (x = p.parent) {
                if (!p.mapped) shown = false;
                if (p.isToplevel()) {
                    if (app.wmOf(p).withdrawn) shown = false;
                    break;
                }
            }
            if (shown) return Value.empty;
            const worked = try app.doOneEvent(true);
            if (!worked and !app.canWait()) return waitForever(it, "visibility", path);
        }
    }
    if (startsWith("window", sub)) {
        const path = try it.str(argv[2]);
        if (app.find(path) == null) return it.fail("bad window path name \"{s}\"", .{path});
        if (atScriptTop(it)) {
            app.loop.parked = .{ .window = try app.gpa.dupe(u8, path) };
            return Value.empty;
        }
        while (app.find(path) != null) {
            const worked = try app.doOneEvent(true);
            if (!worked and !app.canWait()) return waitForever(it, "window", path);
        }
        return Value.empty;
    }
    return it.wrongArgs(usage);
}

/// Registers `after`, `update`, `vwait`, `tkwait`, and the trace helper.
pub fn register(app: *App) !void {
    const it = app.it;
    try it.register("after", cmdAfter);
    try it.register("update", cmdUpdate);
    try it.register("vwait", cmdVwait);
    try it.register("tkwait", cmdTkwait);
    try it.register("ztk::priv::vwait", cmdVwaitMark);
}
