//! The `clipboard` command: `append`, `clear`, and `get`, with the options
//! and the messages of `wish` 8.6.16. The App keeps the data of each type
//! in a `Store`. The clipboard is local to the App: no backend gives the
//! clipboard of the system yet.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const Value = ztcl.Value;

pub const Store = struct {
    /// One entry for each type, in the order of the first append.
    items: std.ArrayListUnmanaged(Item) = .empty,
    /// True after `clear` or `append`. An append to a clipboard that the
    /// App does not own clears it first, as in Tk.
    owned: bool = false,

    pub const Item = struct { type: []u8, data: std.ArrayListUnmanaged(u8) = .empty };

    pub fn deinit(s: *Store, gpa: std.mem.Allocator) void {
        s.clear(gpa);
        s.items.deinit(gpa);
    }

    pub fn clear(s: *Store, gpa: std.mem.Allocator) void {
        for (s.items.items) |*i| {
            gpa.free(i.type);
            i.data.deinit(gpa);
        }
        s.items.clearRetainingCapacity();
        s.owned = true;
    }

    pub fn append(s: *Store, gpa: std.mem.Allocator, typ: []const u8, data: []const u8) !void {
        if (!s.owned) s.clear(gpa);
        for (s.items.items) |*i| if (std.mem.eql(u8, i.type, typ)) return i.data.appendSlice(gpa, data);
        const t = try gpa.dupe(u8, typ);
        errdefer gpa.free(t);
        var item: Item = .{ .type = t };
        try item.data.appendSlice(gpa, data);
        errdefer item.data.deinit(gpa);
        try s.items.append(gpa, item);
    }

    pub fn get(s: *const Store, typ: []const u8) ?[]const u8 {
        for (s.items.items) |i| if (std.mem.eql(u8, i.type, typ)) return i.data.items;
        return null;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The index of an option name or its unique prefix in `names`, or the message of `wish`.
fn option(it: *ztcl.Interp, text: []const u8, names: []const []const u8, list: []const u8) ztcl.Error!usize {
    var found: ?usize = null;
    for (names, 0..) |n, i| {
        if (eq(n, text)) return i;
        if (text.len > 1 and std.mem.startsWith(u8, n, text)) {
            if (found != null) return it.fail("ambiguous option \"{s}\": must be {s}", .{ text, list });
            found = i;
        }
    }
    return found orelse it.fail("bad option \"{s}\": must be {s}", .{ text, list });
}

fn checkWindow(app: *App, it: *ztcl.Interp, path: []const u8) ztcl.Error!void {
    if (app.find(path) == null) return it.fail("bad window path name \"{s}\"", .{path});
}

pub fn command(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    const app = App.of(it);
    if (argv.len < 2) return it.wrongArgs("clipboard option ?arg ...?");
    const sub = try it.str(argv[1]);
    const gpa = app.gpa;
    const subs = [_][]const u8{ "append", "clear", "get" };
    const which = option(it, sub, &subs, "append, clear, or get") catch return it.fail("bad option \"{s}\": must be append, clear, or get", .{sub});
    switch (which) {
        0 => {
            var typ: []const u8 = "STRING";
            var i: usize = 2;
            while (i + 1 < argv.len) : (i += 1) {
                const s = try it.str(argv[i]);
                if (s.len == 0 or s[0] != '-') break;
                if (eq(s, "--")) {
                    i += 1;
                    break;
                }
                const o = try option(it, s, &.{ "-displayof", "-format", "-type" }, "-displayof, -format, or -type");
                i += 1;
                if (i >= argv.len) return it.fail("value for \"{s}\" missing", .{s});
                const v = try it.str(argv[i]);
                switch (o) {
                    0 => try checkWindow(app, it, v),
                    2 => typ = v,
                    else => {},
                }
            }
            if (argv.len - i != 1) return it.wrongArgs("clipboard append ?-option value ...? data");
            app.clipboard.append(gpa, typ, try it.str(argv[i])) catch return error.OutOfMemory;
            return Value.empty;
        },
        1 => {
            if (argv.len != 2 and argv.len != 4) return it.wrongArgs("clipboard clear ?-displayof window?");
            if (argv.len == 4) {
                _ = try option(it, try it.str(argv[2]), &.{"-displayof"}, "-displayof");
                try checkWindow(app, it, try it.str(argv[3]));
            }
            app.clipboard.clear(gpa);
            return Value.empty;
        },
        else => {
            var typ: []const u8 = "STRING";
            var i: usize = 2;
            while (i < argv.len) : (i += 1) {
                const s = try it.str(argv[i]);
                const o = try option(it, s, &.{ "-displayof", "-type" }, "-displayof or -type");
                i += 1;
                if (i >= argv.len) return it.fail("value for \"{s}\" missing", .{s});
                const v = try it.str(argv[i]);
                if (o == 0) try checkWindow(app, it, v) else typ = v;
            }
            const data = app.clipboard.get(typ) orelse
                return it.fail("CLIPBOARD selection doesn't exist or form \"{s}\" not defined", .{typ});
            return .{ .str = try it.alloc().dupe(u8, data) };
        },
    }
}
