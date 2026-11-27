//! The native dialogs of macOS: `NSOpenPanel` for an open and a folder,
//! `NSSavePanel` for a save, `NSAlert` for `tk_messageBox`, and
//! `NSColorPanel` for `tk_chooseColor`. The call blocks until the dialog
//! ends, as `tk_getOpenFile` needs. With a parent window, the panel is a
//! sheet of it: `beginSheetModalForWindow:completionHandler:` starts it,
//! `runModalForWindow:` runs until the completion handler stops the modal
//! loop, and the call returns. The handler is a global block of the block
//! ABI of clang, with no captured value.
//!
//! The filters of `-filetypes` become the allowed extensions of the
//! panel, the union of each filter. A pattern `*` or `*.*` allows each
//! file. A save with a default extension and no filter allows that
//! extension and others, so the panel adds it to a name with none.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const plat = @import("platform.zig");
const geom = @import("../base/geom.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

/// NSModalResponseOK.
const response_ok: isize = 1;

fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    return objc.call(Fn, target, selector, args);
}

fn nsApp() Id {
    return call(fn (Class, Sel) callconv(.c) Id, objc.class("NSApplication").?, "sharedApplication", .{});
}

// ---- The block of the completion handler ----

extern "c" var _NSConcreteGlobalBlock: anyopaque;

const BlockDescriptor = extern struct { reserved: c_ulong, size: c_ulong };
const Block = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const Block, isize) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

/// BLOCK_IS_GLOBAL.
const block_is_global: c_int = 1 << 28;

fn onEnd(_: *const Block, response: isize) callconv(.c) void {
    call(fn (Id, Sel, isize) callconv(.c) void, nsApp(), "stopModalWithCode:", .{response});
}

const end_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(Block) };
var end_block: Block = undefined;

fn endBlock() *const Block {
    end_block = .{ .isa = &_NSConcreteGlobalBlock, .flags = block_is_global, .reserved = 0, .invoke = onEnd, .descriptor = &end_descriptor };
    return &end_block;
}

// ---- The filters ----

/// The extension of a pattern such as `*.txt` or `.txt`, or "" for a
/// pattern that allows each file, or null for a pattern with no plain
/// extension.
fn extensionOf(pattern: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, pattern, "*") or std.mem.eql(u8, pattern, "*.*")) return "";
    var p = pattern;
    if (std.mem.startsWith(u8, p, "*")) p = p[1..];
    if (!std.mem.startsWith(u8, p, ".") or p.len < 2) return null;
    const ext = p[1..];
    if (std.mem.indexOfAny(u8, ext, "*?[]/") != null) return null;
    return ext;
}

/// The allowed extensions of a dialog, or null to allow each file.
pub fn extensions(gpa: std.mem.Allocator, opts: *const plat.FileDialog) !?[][]const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    for (opts.filters) |f| for (f.patterns) |pat| {
        const ext = extensionOf(pat) orelse continue;
        if (ext.len == 0) {
            list.deinit(gpa);
            return null;
        }
        for (list.items) |x| {
            if (std.mem.eql(u8, x, ext)) break;
        } else try list.append(gpa, ext);
    };
    if (list.items.len == 0 and opts.kind == .save and opts.default_ext.len > 0)
        try list.append(gpa, std.mem.trimStart(u8, opts.default_ext, "."));
    if (list.items.len == 0) {
        list.deinit(gpa);
        return null;
    }
    return try list.toOwnedSlice(gpa);
}

// ---- The dialog ----

fn str(text: []const u8) Id {
    const s = objc.nsString(text);
    return call(fn (Id, Sel) callconv(.c) Id, s, "autorelease", .{});
}

/// Runs the dialog. `parent` is the `NSWindow` of the parent, or null.
pub fn run(gpa: std.mem.Allocator, opts: *const plat.FileDialog, parent: ?Id) ?plat.FileDialogResult {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = switch (opts.kind) {
        .save => call(fn (Class, Sel) callconv(.c) Id, objc.class("NSSavePanel").?, "savePanel", .{}),
        .open, .folder => call(fn (Class, Sel) callconv(.c) Id, objc.class("NSOpenPanel").?, "openPanel", .{}),
    };
    if (opts.kind != .save) {
        call(fn (Id, Sel, bool) callconv(.c) void, panel, "setCanChooseFiles:", .{opts.kind == .open});
        call(fn (Id, Sel, bool) callconv(.c) void, panel, "setCanChooseDirectories:", .{opts.kind == .folder});
        call(fn (Id, Sel, bool) callconv(.c) void, panel, "setAllowsMultipleSelection:", .{opts.multiple and opts.kind == .open});
    }
    call(fn (Id, Sel, bool) callconv(.c) void, panel, "setCanCreateDirectories:", .{true});
    if (opts.title.len > 0) {
        call(fn (Id, Sel, Id) callconv(.c) void, panel, "setTitle:", .{str(opts.title)});
        call(fn (Id, Sel, Id) callconv(.c) void, panel, "setMessage:", .{str(opts.title)});
    }
    if (opts.initial_dir.len > 0) {
        const url = call(fn (Class, Sel, Id, bool) callconv(.c) Id, objc.class("NSURL").?, "fileURLWithPath:isDirectory:", .{ str(opts.initial_dir), true });
        call(fn (Id, Sel, Id) callconv(.c) void, panel, "setDirectoryURL:", .{url});
    }
    if (opts.kind == .save and opts.initial_file.len > 0)
        call(fn (Id, Sel, Id) callconv(.c) void, panel, "setNameFieldStringValue:", .{str(opts.initial_file)});
    if (extensions(gpa, opts) catch null) |exts| {
        defer gpa.free(exts);
        const arr = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMutableArray").?, "array", .{});
        for (exts) |e| call(fn (Id, Sel, Id) callconv(.c) void, arr, "addObject:", .{str(e)});
        // The list of extensions works on each macOS of the plan, with no
        // UniformTypeIdentifiers framework.
        call(fn (Id, Sel, Id) callconv(.c) void, panel, "setAllowedFileTypes:", .{arr});
        call(fn (Id, Sel, bool) callconv(.c) void, panel, "setAllowsOtherFileTypes:", .{opts.kind == .save});
    }

    const app = nsApp();
    const response: isize = if (parent) |win| blk: {
        call(fn (Id, Sel, Id, *const Block) callconv(.c) void, panel, "beginSheetModalForWindow:completionHandler:", .{ win, endBlock() });
        const r = call(fn (Id, Sel, Id) callconv(.c) isize, app, "runModalForWindow:", .{panel});
        // An abort of the modal loop leaves the sheet open.
        if (call(fn (Id, Sel) callconv(.c) ?Id, win, "attachedSheet", .{}) == panel)
            call(fn (Id, Sel, Id) callconv(.c) void, win, "endSheet:", .{panel});
        break :blk r;
    } else call(fn (Id, Sel) callconv(.c) isize, panel, "runModal", .{});
    if (response != response_ok) return null;

    var paths: std.ArrayList([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    if (opts.kind == .save) {
        const url = call(fn (Id, Sel) callconv(.c) ?Id, panel, "URL", .{}) orelse return null;
        paths.append(gpa, pathOf(gpa, url) orelse return null) catch return null;
    } else {
        const urls = call(fn (Id, Sel) callconv(.c) Id, panel, "URLs", .{});
        const n = call(fn (Id, Sel) callconv(.c) usize, urls, "count", .{});
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const url = call(fn (Id, Sel, usize) callconv(.c) Id, urls, "objectAtIndex:", .{i});
            const p = pathOf(gpa, url) orelse continue;
            paths.append(gpa, p) catch {
                gpa.free(p);
                return null;
            };
        }
    }
    if (paths.items.len == 0) return null;
    return .{ .paths = paths.toOwnedSlice(gpa) catch return null };
}

// ---- The message box ----

const Button = plat.MessageBox.Button;

/// The buttons of a box in the order of `addButtonWithTitle:`: the first
/// is the default of the Return key and is on the right. The default of
/// the box comes first, then the others in the order of Tk.
pub fn buttonOrder(opts: *const plat.MessageBox, out: *[3]Button) []const Button {
    const all: []const Button = switch (opts.buttons) {
        .ok => &.{.ok},
        .okcancel => &.{ .ok, .cancel },
        .yesno => &.{ .yes, .no },
        .yesnocancel => &.{ .yes, .no, .cancel },
        .retrycancel => &.{ .retry, .cancel },
        .abortretryignore => &.{ .abort, .retry, .ignore },
    };
    var n: usize = 0;
    for (all) |b| if (b == opts.default) {
        out[n] = b;
        n += 1;
    };
    if (n == 0) {
        out[0] = all[0];
        n = 1;
    }
    for (all) |b| if (b != out[0]) {
        out[n] = b;
        n += 1;
    };
    return out[0..n];
}

fn label(b: Button) []const u8 {
    return switch (b) {
        .abort => "Abort",
        .retry => "Retry",
        .ignore => "Ignore",
        .ok => "OK",
        .cancel => "Cancel",
        .no => "No",
        .yes => "Yes",
    };
}

/// NSAlertFirstButtonReturn.
const first_button: isize = 1000;

/// Runs an alert to its end and gives the button. With a parent, the
/// alert is a sheet of it, as for the file dialogs.
pub fn messageBox(opts: *const plat.MessageBox, parent: ?Id) ?Button {
    const pool = objc.Pool.push();
    defer pool.pop();
    const alert = call(fn (Id, Sel) callconv(.c) Id, call(fn (Class, Sel) callconv(.c) Id, objc.class("NSAlert").?, "alloc", .{}), "init", .{});
    defer call(fn (Id, Sel) callconv(.c) void, alert, "release", .{});
    // NSAlertStyleWarning 0, Informational 1, Critical 2.
    const style: usize = switch (opts.icon) {
        .@"error" => 2,
        .warning => 0,
        .info, .question => 1,
    };
    call(fn (Id, Sel, usize) callconv(.c) void, alert, "setAlertStyle:", .{style});
    call(fn (Id, Sel, Id) callconv(.c) void, alert, "setMessageText:", .{str(if (opts.message.len > 0) opts.message else opts.title)});
    if (opts.detail.len > 0) call(fn (Id, Sel, Id) callconv(.c) void, alert, "setInformativeText:", .{str(opts.detail)});
    var buf: [3]Button = undefined;
    const order = buttonOrder(opts, &buf);
    for (order) |b| _ = call(fn (Id, Sel, Id) callconv(.c) Id, alert, "addButtonWithTitle:", .{str(label(b))});
    const window = call(fn (Id, Sel) callconv(.c) Id, alert, "window", .{});
    if (opts.title.len > 0) call(fn (Id, Sel, Id) callconv(.c) void, window, "setTitle:", .{str(opts.title)});
    const response: isize = if (parent) |win| blk: {
        call(fn (Id, Sel, Id, *const Block) callconv(.c) void, alert, "beginSheetModalForWindow:completionHandler:", .{ win, endBlock() });
        const r = call(fn (Id, Sel, Id) callconv(.c) isize, nsApp(), "runModalForWindow:", .{window});
        if (call(fn (Id, Sel) callconv(.c) ?Id, win, "attachedSheet", .{}) == window)
            call(fn (Id, Sel, Id) callconv(.c) void, win, "endSheet:", .{window});
        break :blk r;
    } else call(fn (Id, Sel) callconv(.c) isize, alert, "runModal", .{});
    const i = response - first_button;
    if (i < 0 or i >= @as(isize, @intCast(order.len))) return null;
    return order[@intCast(i)];
}

// ---- The color panel ----

const NoteBlock = extern struct {
    isa: *anyopaque,
    flags: c_int,
    reserved: c_int,
    invoke: *const fn (*const NoteBlock, Id) callconv(.c) void,
    descriptor: *const BlockDescriptor,
};

fn onClose(_: *const NoteBlock, _: Id) callconv(.c) void {
    call(fn (Id, Sel) callconv(.c) void, nsApp(), "stopModal", .{});
}

const note_descriptor: BlockDescriptor = .{ .reserved = 0, .size = @sizeOf(NoteBlock) };
var close_block: NoteBlock = undefined;

/// Runs the shared color panel as a modal window until it closes, and
/// gives its color in sRGB. The panel of macOS has no Cancel: its color
/// at the close is the answer, as Tk on macOS gives it.
pub fn colorDialog(opts: *const plat.ColorDialog) ?geom.Color {
    const pool = objc.Pool.push();
    defer pool.pop();
    const panel = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSColorPanel").?, "sharedColorPanel", .{});
    const c = opts.initial;
    const first = call(fn (Class, Sel, f64, f64, f64, f64) callconv(.c) Id, objc.class("NSColor").?, "colorWithSRGBRed:green:blue:alpha:", .{
        @as(f64, @floatFromInt(c.r)) / 255.0, @as(f64, @floatFromInt(c.g)) / 255.0, @as(f64, @floatFromInt(c.b)) / 255.0, 1.0,
    });
    call(fn (Id, Sel, bool) callconv(.c) void, panel, "setShowsAlpha:", .{false});
    call(fn (Id, Sel, Id) callconv(.c) void, panel, "setColor:", .{first});
    if (opts.title.len > 0) call(fn (Id, Sel, Id) callconv(.c) void, panel, "setTitle:", .{str(opts.title)});
    close_block = .{ .isa = &_NSConcreteGlobalBlock, .flags = block_is_global, .reserved = 0, .invoke = onClose, .descriptor = &note_descriptor };
    const center = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSNotificationCenter").?, "defaultCenter", .{});
    const observer = call(fn (Id, Sel, Id, Id, ?Id, *const NoteBlock) callconv(.c) Id, center, "addObserverForName:object:queue:usingBlock:", .{ str("NSWindowWillCloseNotification"), panel, null, &close_block });
    defer call(fn (Id, Sel, Id) callconv(.c) void, center, "removeObserver:", .{observer});
    call(fn (Id, Sel, ?Id) callconv(.c) void, panel, "makeKeyAndOrderFront:", .{null});
    _ = call(fn (Id, Sel, Id) callconv(.c) isize, nsApp(), "runModalForWindow:", .{panel});
    const chosen = call(fn (Id, Sel) callconv(.c) Id, panel, "color", .{});
    const srgb = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSColorSpace").?, "sRGBColorSpace", .{});
    const rgb = call(fn (Id, Sel, Id) callconv(.c) ?Id, chosen, "colorUsingColorSpace:", .{srgb}) orelse return null;
    const comp = struct {
        fn of(col: Id, sel: [*:0]const u8) u8 {
            const v = call(fn (Id, Sel) callconv(.c) f64, col, sel, .{});
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255.0));
        }
    };
    return .{ .r = comp.of(rgb, "redComponent"), .g = comp.of(rgb, "greenComponent"), .b = comp.of(rgb, "blueComponent") };
}

fn pathOf(gpa: std.mem.Allocator, url: Id) ?[]u8 {
    const p = call(fn (Id, Sel) callconv(.c) ?Id, url, "path", .{}) orelse return null;
    return gpa.dupe(u8, objc.utf8(p)) catch null;
}

const t = std.testing;

test "macdialog: the filters become the allowed extensions" {
    const F = plat.FileDialog.Filter;
    const filters = [_]F{
        .{ .name = "Text", .patterns = &.{ "*.txt", ".md" } },
        .{ .name = "Tcl", .patterns = &.{ "*.tcl", "*.txt", "Makefile" } },
    };
    const exts = (try extensions(t.allocator, &.{ .kind = .open, .filters = &filters })).?;
    defer t.allocator.free(exts);
    try t.expectEqual(@as(usize, 3), exts.len);
    try t.expectEqualStrings("txt", exts[0]);
    try t.expectEqualStrings("md", exts[1]);
    try t.expectEqualStrings("tcl", exts[2]);

    const all = [_]F{ .{ .name = "Tcl", .patterns = &.{"*.tcl"} }, .{ .name = "All", .patterns = &.{"*"} } };
    try t.expect((try extensions(t.allocator, &.{ .kind = .open, .filters = &all })) == null);
    try t.expect((try extensions(t.allocator, &.{ .kind = .open })) == null);

    const save = (try extensions(t.allocator, &.{ .kind = .save, .default_ext = ".csv" })).?;
    defer t.allocator.free(save);
    try t.expectEqualStrings("csv", save[0]);
    try t.expect(extensionOf("*.tar.*") == null);
}

test "macdialog: the buttons of a box, the default first" {
    var buf: [3]Button = undefined;
    const ync = buttonOrder(&.{ .buttons = .yesnocancel, .default = .no }, &buf);
    try t.expectEqualSlices(Button, &.{ .no, .yes, .cancel }, ync);
    const ok = buttonOrder(&.{ .buttons = .okcancel, .default = .ok }, &buf);
    try t.expectEqualSlices(Button, &.{ .ok, .cancel }, ok);
    // A default that the box does not have: the first of Tk.
    const ari = buttonOrder(&.{ .buttons = .abortretryignore, .default = .ok }, &buf);
    try t.expectEqualSlices(Button, &.{ .abort, .retry, .ignore }, ari);
}
