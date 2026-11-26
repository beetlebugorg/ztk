//! The native file dialogs of macOS: `NSOpenPanel` for an open and a
//! folder, `NSSavePanel` for a save. The call blocks until the dialog
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
