//! The file dialogs of the Win32 backend, on the Common Item Dialog of
//! Windows: `IFileOpenDialog` for an open and a folder (with
//! `FOS_PICKFOLDERS`), and `IFileSaveDialog` for a save. `configure` sets
//! the options of the dialog, and `show` runs it to its end with the
//! owner window, and reads the paths of the chosen items with
//! `SIGDN_FILESYSPATH`. A cancel gives null. The paths come back with `/`
//! between the parts, as Tk gives them on Windows.
//!
//! The slots, the interface IDs, and the constants follow the C forms in
//! `ShObjIdl_core.h` of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const w32 = @import("win32.zig");
const plat = @import("platform.zig");

const HRESULT = com.HRESULT;
const GUID = com.GUID;
const call = com.call;

const CLSID_FileOpenDialog = GUID.parse("dc1c5a9c-e88a-4dde-a5a1-60f82a20aef7");
const CLSID_FileSaveDialog = GUID.parse("c0b4e2f3-ba21-4773-8dba-335ec946eb8b");
const IID_IFileOpenDialog = GUID.parse("d57c7288-d4ad-4768-be02-9d969532d960");
const IID_IFileSaveDialog = GUID.parse("84bccd23-5fde-4cdb-aea4-af64b83d78ab");
const IID_IShellItem = GUID.parse("43826d1e-e718-42ee-bc55-a1e261c37bfe");

const FOS_OVERWRITEPROMPT: u32 = 0x2;
const FOS_NOCHANGEDIR: u32 = 0x8;
const FOS_PICKFOLDERS: u32 = 0x20;
const FOS_FORCEFILESYSTEM: u32 = 0x40;
const FOS_ALLOWMULTISELECT: u32 = 0x200;
const FOS_PATHMUSTEXIST: u32 = 0x800;
const FOS_FILEMUSTEXIST: u32 = 0x1000;
const SIGDN_FILESYSPATH: i32 = @bitCast(@as(u32, 0x80058000));
/// HRESULT_FROM_WIN32(ERROR_CANCELLED).
const E_CANCELLED: HRESULT = @bitCast(@as(u32, 0x800704C7));

// The slots of IFileDialog, IFileOpenDialog, IShellItem, and IShellItemArray.
const slot = struct {
    const show = 3;
    const set_file_types = 4;
    const get_file_type_index = 6;
    const set_options = 9;
    const get_options = 10;
    const set_folder = 12;
    const get_folder = 13;
    const set_file_name = 15;
    const get_file_name = 16;
    const set_title = 17;
    const get_result = 20;
    const set_default_extension = 22;
    const get_results = 27;
    const item_get_display_name = 5;
    const array_get_count = 7;
    const array_get_item_at = 8;
};

const COMDLG_FILTERSPEC = extern struct { pszName: [*:0]const u16, pszSpec: [*:0]const u16 };

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn CoTaskMemFree(p: ?*anyopaque) callconv(.winapi) void;
extern "shell32" fn SHCreateItemFromParsingName(path: [*:0]const u16, ctx: ?*anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

/// A dialog object with its options set, before it shows.
pub const Dialog = struct {
    obj: *anyopaque,
    kind: plat.FileDialog.Kind,
    multiple: bool,
    /// The memory of the strings and the filters, freed with the dialog.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(d: *Dialog) void {
        com.release(d.obj);
        d.arena.deinit();
        CoUninitialize();
    }
};

fn wide(a: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.InvalidUtf8 => std.unicode.utf8ToUtf16LeAllocZ(a, ""),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Makes a dialog of Windows and sets its options.
pub fn configure(gpa: std.mem.Allocator, opts: *const plat.FileDialog) !Dialog {
    // S_FALSE (1): COM was on for the thread already, and the call still counts.
    if (CoInitializeEx(null, 0x2) < 0) return error.NoCom;
    errdefer CoUninitialize();
    var obj: ?*anyopaque = null;
    const save = opts.kind == .save;
    try com.check(CoCreateInstance(if (save) &CLSID_FileSaveDialog else &CLSID_FileOpenDialog, null, 0x1, if (save) &IID_IFileSaveDialog else &IID_IFileOpenDialog, &obj));
    var d: Dialog = .{ .obj = obj.?, .kind = opts.kind, .multiple = opts.multiple and opts.kind == .open, .arena = .init(gpa) };
    errdefer {
        com.release(d.obj);
        d.arena.deinit();
    }
    const a = d.arena.allocator();
    var flags: u32 = 0;
    _ = call(HRESULT, d.obj, slot.get_options, .{&flags});
    flags |= FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR;
    switch (opts.kind) {
        .open => flags |= FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | (if (d.multiple) FOS_ALLOWMULTISELECT else 0),
        .folder => flags |= FOS_PICKFOLDERS | FOS_PATHMUSTEXIST,
        .save => flags = if (opts.confirm_overwrite) flags | FOS_OVERWRITEPROMPT else flags & ~FOS_OVERWRITEPROMPT,
    }
    try com.check(call(HRESULT, d.obj, slot.set_options, .{flags}));
    if (opts.title.len > 0) _ = call(HRESULT, d.obj, slot.set_title, .{@as([*:0]const u16, try wide(a, opts.title))});
    if (opts.initial_file.len > 0) _ = call(HRESULT, d.obj, slot.set_file_name, .{@as([*:0]const u16, try wide(a, opts.initial_file))});
    if (opts.default_ext.len > 0) _ = call(HRESULT, d.obj, slot.set_default_extension, .{@as([*:0]const u16, try wide(a, opts.default_ext))});
    if (opts.initial_dir.len > 0) {
        var item: ?*anyopaque = null;
        // A folder that does not exist leaves the folder of the system.
        if (SHCreateItemFromParsingName(try wide(a, opts.initial_dir), null, &IID_IShellItem, &item) >= 0) {
            _ = call(HRESULT, d.obj, slot.set_folder, .{item.?});
            com.release(item.?);
        }
    }
    if (opts.filters.len > 0 and opts.kind != .folder) {
        const specs = try a.alloc(COMDLG_FILTERSPEC, opts.filters.len);
        for (opts.filters, specs) |f, *s| {
            const joined = try std.mem.join(a, ";", f.patterns);
            s.* = .{ .pszName = try wide(a, f.name), .pszSpec = try wide(a, joined) };
        }
        try com.check(call(HRESULT, d.obj, slot.set_file_types, .{ @as(u32, @intCast(specs.len)), specs.ptr }));
    }
    return d;
}

/// A path of an item in UTF-8, with `/` between the parts.
fn itemPath(gpa: std.mem.Allocator, item: *anyopaque) ?[]u8 {
    var name: ?[*:0]u16 = null;
    if (call(HRESULT, item, slot.item_get_display_name, .{ SIGDN_FILESYSPATH, &name }) < 0) return null;
    defer CoTaskMemFree(name);
    const path = std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(name.?)) catch return null;
    for (path) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return path;
}

/// Shows the dialog with its owner window and gives the chosen paths, or null for a cancel.
pub fn show(d: *Dialog, gpa: std.mem.Allocator, owner: ?w32.HWND) ?plat.FileDialogResult {
    const hr = call(HRESULT, d.obj, slot.show, .{owner});
    if (hr == E_CANCELLED or hr < 0) return null;
    var paths: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    if (d.multiple) {
        var array: ?*anyopaque = null;
        if (call(HRESULT, d.obj, slot.get_results, .{&array}) < 0) return null;
        defer com.release(array.?);
        var count: u32 = 0;
        _ = call(HRESULT, array.?, slot.array_get_count, .{&count});
        for (0..count) |i| {
            var item: ?*anyopaque = null;
            if (call(HRESULT, array.?, slot.array_get_item_at, .{ @as(u32, @intCast(i)), &item }) < 0) continue;
            defer com.release(item.?);
            if (itemPath(gpa, item.?)) |p| paths.append(gpa, p) catch gpa.free(p);
        }
    } else {
        var item: ?*anyopaque = null;
        if (call(HRESULT, d.obj, slot.get_result, .{&item}) < 0) return null;
        defer com.release(item.?);
        if (itemPath(gpa, item.?)) |p| paths.append(gpa, p) catch gpa.free(p);
    }
    var index: u32 = 0;
    const filter: ?u32 = if (d.kind != .folder and call(HRESULT, d.obj, slot.get_file_type_index, .{&index}) >= 0 and index > 0) index - 1 else null;
    return .{ .paths = paths.toOwnedSlice(gpa) catch return null, .filter = filter };
}

/// The options and the file name of a dialog, for the tests: they read
/// the dialog back with no `Show`, so no dialog opens on the desktop.
pub fn readBack(d: *Dialog, gpa: std.mem.Allocator) !struct { flags: u32, file_name: []u8 } {
    var flags: u32 = 0;
    try com.check(call(HRESULT, d.obj, slot.get_options, .{&flags}));
    var name: ?[*:0]u16 = null;
    var file_name: []u8 = try gpa.dupe(u8, "");
    if (call(HRESULT, d.obj, slot.get_file_name, .{&name}) >= 0) if (name) |n| {
        defer CoTaskMemFree(n);
        gpa.free(file_name);
        file_name = try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(n));
    };
    return .{ .flags = flags, .file_name = file_name };
}

pub const flag = struct {
    pub const overwrite_prompt = FOS_OVERWRITEPROMPT;
    pub const pick_folders = FOS_PICKFOLDERS;
    pub const multiselect = FOS_ALLOWMULTISELECT;
    pub const file_must_exist = FOS_FILEMUSTEXIST;
};
