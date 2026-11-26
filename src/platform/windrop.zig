//! The drops of other apps on a window of Windows (ztk#62): an OLE
//! `IDropTarget` for each window that accepts drops.
//!
//! `enable` calls `OleInitialize` once and `RegisterDragDrop` with a new
//! target. The shell calls `DragEnter` with the data of the drag, and
//! the target asks the data with `QueryGetData` for `CF_HDROP` (files)
//! and `CF_UNICODETEXT` (text), as the window accepts them. It answers
//! `DROPEFFECT_COPY` when the data has one of them, and
//! `DROPEFFECT_NONE` when it has none. `DragOver`, `DragLeave`, and
//! `Drop` give the same answer. Each call gives the backend a phase and
//! the point in the client area, in logical pixels. `Drop` reads the
//! files with `DragQueryFileW` from the `HGLOBAL` of `GetData`, or the
//! text, and the backend queues them in one `drop` event. A window accepts
//! the drop as a whole, because the answer of `DragOver` comes before
//! the app sees the event; the app finds the widget at the point.
//!
//! The target is a COM object of this file: a table of seven methods
//! and a count of references. `RegisterDragDrop` holds a reference, and
//! `RevokeDragDrop` drops it, so the last `Release` frees the target.
//! The slots of `IDataObject` are from `objidl.h` of the Windows SDK.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const com = @import("../sys/com.zig");
const plat = @import("platform.zig");
const event = @import("../event.zig");
const GUID = com.GUID;
const HRESULT = com.HRESULT;

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn RegisterDragDrop(hwnd: w32.HWND, target: *Target) callconv(.winapi) HRESULT;
extern "ole32" fn RevokeDragDrop(hwnd: w32.HWND) callconv(.winapi) HRESULT;
extern "ole32" fn ReleaseStgMedium(m: *STGMEDIUM) callconv(.winapi) void;
extern "shell32" fn DragQueryFileW(h: *anyopaque, i: u32, buf: ?[*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn GlobalLock(h: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(h: *anyopaque) callconv(.winapi) i32;
extern "user32" fn ScreenToClient(hwnd: w32.HWND, pt: *POINTL) callconv(.winapi) i32;

pub const CF_UNICODETEXT: u16 = 13;
pub const CF_HDROP: u16 = 15;
const DROPEFFECT_NONE: u32 = 0;
const DROPEFFECT_COPY: u32 = 1;
const slot_get_data = 3;
const slot_query_get_data = 5;

pub const POINTL = extern struct { x: i32, y: i32 };
pub const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque = null,
    dwAspect: u32 = 1, // DVASPECT_CONTENT
    lindex: i32 = -1,
    tymed: u32 = 1, // TYMED_HGLOBAL
};
pub const STGMEDIUM = extern struct {
    tymed: u32 = 0,
    data: ?*anyopaque = null,
    release: ?*anyopaque = null,
};

const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
const IID_IDropTarget = GUID.parse("00000122-0000-0000-c000-000000000046");

/// What the target gives the backend: the phase, the point, the files
/// (separated by 0), and the text. The strings live during the call.
pub const Sink = *const fn (ctx: *anyopaque, phase: event.DropPhase, x: f32, y: f32, files: [*]const u8, files_len: usize, text: [*]const u8, text_len: usize) callconv(.c) void;

const Vtbl = extern struct {
    QueryInterface: *const fn (*Target, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*Target) callconv(.winapi) u32,
    Release: *const fn (*Target) callconv(.winapi) u32,
    DragEnter: *const fn (*Target, ?*anyopaque, u32, POINTL, *u32) callconv(.winapi) HRESULT,
    DragOver: *const fn (*Target, u32, POINTL, *u32) callconv(.winapi) HRESULT,
    DragLeave: *const fn (*Target) callconv(.winapi) HRESULT,
    Drop: *const fn (*Target, ?*anyopaque, u32, POINTL, *u32) callconv(.winapi) HRESULT,
};

const vtbl: Vtbl = .{
    .QueryInterface = queryInterface,
    .AddRef = addRef,
    .Release = release,
    .DragEnter = dragEnter,
    .DragOver = dragOver,
    .DragLeave = dragLeave,
    .Drop = drop,
};

pub const Target = extern struct {
    vtbl: *const Vtbl = &vtbl,
    refs: u32 = 1,
    gpa: *const std.mem.Allocator,
    hwnd: w32.HWND,
    scale: *const f32,
    types: plat.DropTypes,
    /// True when the data of the drag has a type of the window.
    accept: bool = false,
    ctx: *anyopaque,
    sink: Sink,
};

var ole_done = false;

/// Registers a new target on `hwnd`. Gives null when OLE refuses.
pub fn enable(gpa: *const std.mem.Allocator, hwnd: w32.HWND, scale: *const f32, types: plat.DropTypes, ctx: *anyopaque, sink: Sink) ?*Target {
    if (!ole_done) {
        if (OleInitialize(null) < 0) return null;
        ole_done = true;
    }
    const t = gpa.create(Target) catch return null;
    t.* = .{ .gpa = gpa, .hwnd = hwnd, .scale = scale, .types = types, .ctx = ctx, .sink = sink };
    if (RegisterDragDrop(hwnd, t) < 0) {
        gpa.destroy(t);
        return null;
    }
    // RegisterDragDrop holds its own reference.
    _ = release(t);
    return t;
}

pub fn disable(hwnd: w32.HWND) void {
    _ = RevokeDragDrop(hwnd);
}

fn queryInterface(t: *Target, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IDropTarget)) {
        out.* = t;
        _ = addRef(t);
        return 0;
    }
    out.* = null;
    return @bitCast(@as(u32, 0x80004002)); // E_NOINTERFACE
}

fn addRef(t: *Target) callconv(.winapi) u32 {
    t.refs += 1;
    return t.refs;
}

fn release(t: *Target) callconv(.winapi) u32 {
    t.refs -= 1;
    const n = t.refs;
    if (n == 0) t.gpa.destroy(t);
    return n;
}

fn has(data: *anyopaque, cf: u16) bool {
    var f: FORMATETC = .{ .cfFormat = cf };
    return com.call(HRESULT, data, slot_query_get_data, .{&f}) == 0;
}

/// True when the data has a type that the window accepts.
pub fn accepts(types: plat.DropTypes, data: *anyopaque) bool {
    return (types.files and has(data, CF_HDROP)) or (types.text and has(data, CF_UNICODETEXT));
}

fn point(t: *Target, pt: POINTL) [2]f32 {
    var p = pt;
    _ = ScreenToClient(t.hwnd, &p);
    return .{ @as(f32, @floatFromInt(p.x)) / t.scale.*, @as(f32, @floatFromInt(p.y)) / t.scale.* };
}

fn answer(t: *Target, effect: *u32) void {
    effect.* = if (t.accept) effect.* & DROPEFFECT_COPY else DROPEFFECT_NONE;
}

fn dragEnter(t: *Target, data: ?*anyopaque, _: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
    t.accept = if (data) |d| accepts(t.types, d) else false;
    answer(t, effect);
    if (t.accept) {
        const p = point(t, pt);
        t.sink(t.ctx, .enter, p[0], p[1], "", 0, "", 0);
    }
    return 0;
}

fn dragOver(t: *Target, _: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
    answer(t, effect);
    if (t.accept) {
        const p = point(t, pt);
        t.sink(t.ctx, .over, p[0], p[1], "", 0, "", 0);
    }
    return 0;
}

fn dragLeave(t: *Target) callconv(.winapi) HRESULT {
    if (t.accept) t.sink(t.ctx, .leave, 0, 0, "", 0, "", 0);
    t.accept = false;
    return 0;
}

fn drop(t: *Target, data: ?*anyopaque, _: u32, pt: POINTL, effect: *u32) callconv(.winapi) HRESULT {
    answer(t, effect);
    const d = data orelse return 0;
    if (!t.accept) return 0;
    t.accept = false;
    const p = point(t, pt);
    var files: std.ArrayListUnmanaged(u8) = .empty;
    defer files.deinit(t.gpa.*);
    var text: std.ArrayListUnmanaged(u8) = .empty;
    defer text.deinit(t.gpa.*);
    if (t.types.files and readFiles(t.gpa.*, d, &files)) {
        t.sink(t.ctx, .drop, p[0], p[1], files.items.ptr, files.items.len, "", 0);
    } else if (t.types.text and readText(t.gpa.*, d, &text)) {
        t.sink(t.ctx, .drop, p[0], p[1], "", 0, text.items.ptr, text.items.len);
    } else {
        t.sink(t.ctx, .leave, 0, 0, "", 0, "", 0);
    }
    return 0;
}

/// The files of the data, in UTF-8 with `/` between the parts and 0
/// between the files.
pub fn readFiles(gpa: std.mem.Allocator, data: *anyopaque, out: *std.ArrayListUnmanaged(u8)) bool {
    var f: FORMATETC = .{ .cfFormat = CF_HDROP };
    var m: STGMEDIUM = .{};
    if (com.call(HRESULT, data, slot_get_data, .{ &f, &m }) != 0) return false;
    defer ReleaseStgMedium(&m);
    const g = m.data orelse return false;
    const h = GlobalLock(g) orelse return false;
    defer _ = GlobalUnlock(g);
    const n = DragQueryFileW(h, 0xffffffff, null, 0);
    var buf: [32768]u16 = undefined;
    for (0..n) |i| {
        const len = DragQueryFileW(h, @intCast(i), &buf, buf.len);
        if (len == 0 or len >= buf.len) continue;
        for (buf[0..len]) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        const s = std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]) catch continue;
        defer gpa.free(s);
        if (out.items.len > 0) out.append(gpa, 0) catch return false;
        out.appendSlice(gpa, s) catch return false;
    }
    return out.items.len > 0;
}

pub fn readText(gpa: std.mem.Allocator, data: *anyopaque, out: *std.ArrayListUnmanaged(u8)) bool {
    var f: FORMATETC = .{ .cfFormat = CF_UNICODETEXT };
    var m: STGMEDIUM = .{};
    if (com.call(HRESULT, data, slot_get_data, .{ &f, &m }) != 0) return false;
    defer ReleaseStgMedium(&m);
    const g = m.data orelse return false;
    const p: [*:0]const u16 = @ptrCast(@alignCast(GlobalLock(g) orelse return false));
    defer _ = GlobalUnlock(g);
    const s = std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(p)) catch return false;
    defer gpa.free(s);
    out.appendSlice(gpa, s) catch return false;
    return true;
}

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(FORMATETC) == 32);
        std.debug.assert(@sizeOf(STGMEDIUM) == 24);
    }
}
