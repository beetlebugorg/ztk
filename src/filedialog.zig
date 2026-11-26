//! The file dialogs of Tk on the native dialogs of the backend:
//! `tk_getOpenFile`, `tk_getSaveFile`, and `tk_chooseDirectory`, with the
//! options and the results of their manual pages. The commands exist
//! when the backend has `fileDialog`. The dialogs that ztk draws for the
//! other backends are task 17 of the widget stage.
//!
//! A dialog gives paths, so it needs the file capability of ztcl, as
//! decision D19 of the plan says. `-filetypes` becomes the filters of the
//! backend: a pattern `.txt` is `*.txt`, and `*` stays. An open gives a
//! path, or a list of paths with `-multiple`, and a cancel gives an empty
//! string. `-typevariable` gets the name of the filter that was chosen.
//! `-message` and `-mustexist` exist for the scripts of Tk: the dialogs of
//! Windows show no message, and a folder that a dialog gives exists.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const ztcl = @import("ztcl");
const App = @import("app.zig").App;
const plat = @import("platform/platform.zig");
const Value = ztcl.Value;

const open_options = [_][]const u8{ "-defaultextension", "-filetypes", "-initialdir", "-initialfile", "-message", "-multiple", "-parent", "-title", "-typevariable" };
const save_options = [_][]const u8{ "-confirmoverwrite", "-defaultextension", "-filetypes", "-initialdir", "-initialfile", "-message", "-parent", "-title", "-typevariable" };
const dir_options = [_][]const u8{ "-initialdir", "-mustexist", "-parent", "-title" };

pub fn register(app: *App) !void {
    if (!app.platform.hasFileDialog()) return;
    const it = app.it;
    try it.register("tk_getOpenFile", cmdOpen);
    try it.register("tk_getSaveFile", cmdSave);
    try it.register("tk_chooseDirectory", cmdDir);
}

fn cmdOpen(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    return run(it, argv, .open, &open_options);
}

fn cmdSave(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    return run(it, argv, .save, &save_options);
}

fn cmdDir(it: *ztcl.Interp, argv: []const Value, _: ?*ztcl.interp.Cmd) ztcl.Error!Value {
    return run(it, argv, .folder, &dir_options);
}

/// The text of the list of options for the message of a bad option.
fn optionList(a: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (names, 0..) |n, i| {
        if (i > 0) try out.appendSlice(a, if (i + 1 == names.len) ", or " else ", ");
        try out.appendSlice(a, n);
    }
    return out.items;
}

/// The filters of a value of `-filetypes`: a list of {name patterns ?mactypes?}.
fn parseFilters(it: *ztcl.Interp, a: std.mem.Allocator, v: Value) ztcl.Error![]plat.FileDialog.Filter {
    const types = try it.list(v);
    var out = a.alloc(plat.FileDialog.Filter, types.len) catch return error.OutOfMemory;
    for (types, 0..) |tv, i| {
        const parts = try it.list(tv);
        if (parts.len < 2 or parts.len > 3) return it.fail("bad file type \"{s}\", should be \"typeName {{extension ?extensions ...?}} ?{{macType ?macTypes ...?}}?\"", .{try it.str(tv)});
        const pats = try it.list(parts[1]);
        var list = a.alloc([]const u8, pats.len) catch return error.OutOfMemory;
        for (pats, 0..) |pv, k| {
            const p = try it.str(pv);
            list[k] = if (p.len > 0 and p[0] == '.') (std.fmt.allocPrint(a, "*{s}", .{p}) catch return error.OutOfMemory) else p;
        }
        out[i] = .{ .name = try it.str(parts[0]), .patterns = list };
    }
    return out;
}

fn run(it: *ztcl.Interp, argv: []const Value, kind: plat.FileDialog.Kind, names: []const []const u8) ztcl.Error!Value {
    const app = App.of(it);
    const a = it.alloc();
    var opts: plat.FileDialog = .{ .kind = kind };
    var typevar: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 2) {
        const name = try it.str(argv[i]);
        const which = for (names, 0..) |n, k| {
            if (std.mem.eql(u8, n, name)) break k;
        } else return it.fail("bad option \"{s}\": must be {s}", .{ name, optionList(a, names) catch return error.OutOfMemory });
        if (i + 1 >= argv.len) return it.fail("value for \"{s}\" missing", .{name});
        const v = argv[i + 1];
        const s = try it.str(v);
        const opt = names[which];
        if (std.mem.eql(u8, opt, "-defaultextension")) {
            opts.default_ext = if (s.len > 0 and s[0] == '.') s[1..] else s;
        } else if (std.mem.eql(u8, opt, "-filetypes")) {
            opts.filters = try parseFilters(it, a, v);
        } else if (std.mem.eql(u8, opt, "-initialdir")) {
            opts.initial_dir = s;
        } else if (std.mem.eql(u8, opt, "-initialfile")) {
            opts.initial_file = s;
        } else if (std.mem.eql(u8, opt, "-multiple")) {
            opts.multiple = @import("options.zig").parseBool(s) orelse return it.fail("expected boolean value but got \"{s}\"", .{s});
        } else if (std.mem.eql(u8, opt, "-confirmoverwrite")) {
            opts.confirm_overwrite = @import("options.zig").parseBool(s) orelse return it.fail("expected boolean value but got \"{s}\"", .{s});
        } else if (std.mem.eql(u8, opt, "-mustexist")) {
            _ = @import("options.zig").parseBool(s) orelse return it.fail("expected boolean value but got \"{s}\"", .{s});
        } else if (std.mem.eql(u8, opt, "-parent")) {
            const w = app.find(s) orelse return it.fail("bad window path name \"{s}\"", .{s});
            opts.parent = app.winOf(w.toplevel());
        } else if (std.mem.eql(u8, opt, "-title")) {
            opts.title = s;
        } else if (std.mem.eql(u8, opt, "-typevariable")) {
            typevar = s;
        }
        // -message has no place in the dialogs of Windows.
    }
    if (it.capabilities & @intFromEnum(ztcl.interp.Capability.file) == 0) return it.fail("the file dialogs need the file capability", .{});
    if (opts.parent == null) opts.parent = app.window;
    const result = app.platform.fileDialog(app.gpa, &opts) orelse return Value.empty;
    defer result.deinit(app.gpa);
    if (typevar) |name| if (result.filter) |f| if (f < opts.filters.len) {
        _ = try it.setVar(name, .{ .str = try a.dupe(u8, opts.filters[f].name) });
    };
    if (kind == .open and opts.multiple) {
        const list = a.alloc(Value, result.paths.len) catch return error.OutOfMemory;
        for (result.paths, list) |p, *lv| lv.* = .{ .str = try a.dupe(u8, p) };
        return ztcl.value.newList(a, list);
    }
    if (result.paths.len == 0) return Value.empty;
    return .{ .str = try a.dupe(u8, result.paths[0]) };
}
