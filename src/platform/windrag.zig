//! The drags out of a window of Windows to other apps (ztk#62): an OLE
//! data object and a drop source for `DoDragDrop`.
//!
//! `run` makes a data object with the files or the text of the drag and
//! a drop source, and calls `DoDragDrop`, which runs a modal loop until
//! the user drops or cancels. The data object gives `CF_HDROP` for the
//! files (a `DROPFILES` with the paths in UTF-16, each with `\` between
//! the parts) and `CF_UNICODETEXT` for the text, each in a new `HGLOBAL`
//! that the receiver frees with `ReleaseStgMedium`. `EnumFormatEtc` is
//! `SHCreateStdEnumFmtEtc` of the formats that the drag has. The drop
//! source ends the drag with a drop when the button goes up, and with a
//! cancel at Escape. The answer of the target gives the action: copy,
//! move, or none.
//!
//! Each object is a COM object of this file: a table of methods and a
//! count of references, and the last `Release` frees it. The slots of
//! `IDataObject` and `IDropSource` are from `objidl.h` and `oleidl.h` of
//! the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const w32 = @import("win32.zig");
const com = @import("../sys/com.zig");
const plat = @import("platform.zig");
const windrop = @import("windrop.zig");
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const FORMATETC = windrop.FORMATETC;
const STGMEDIUM = windrop.STGMEDIUM;

extern "ole32" fn OleInitialize(reserved: ?*anyopaque) callconv(.winapi) HRESULT;
extern "ole32" fn DoDragDrop(data: *DataObject, source: *DropSource, ok: u32, effect: *u32) callconv(.winapi) HRESULT;
extern "shell32" fn SHCreateStdEnumFmtEtc(n: u32, formats: [*]const FORMATETC, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "kernel32" fn GlobalAlloc(flags: u32, size: usize) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalLock(h: *anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(h: *anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GlobalFree(h: *anyopaque) callconv(.winapi) ?*anyopaque;

const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
const IID_IDataObject = GUID.parse("0000010e-0000-0000-c000-000000000046");
const IID_IDropSource = GUID.parse("00000121-0000-0000-c000-000000000046");

const S_OK: HRESULT = 0;
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007000E));
const DV_E_FORMATETC: HRESULT = @bitCast(@as(u32, 0x80040064));
const OLE_E_ADVISENOTSUPPORTED: HRESULT = @bitCast(@as(u32, 0x80040003));
pub const DRAGDROP_S_DROP: HRESULT = 0x40100;
pub const DRAGDROP_S_CANCEL: HRESULT = 0x40101;
const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = 0x40102;
const DROPEFFECT_COPY: u32 = 1;
const DROPEFFECT_MOVE: u32 = 2;
const TYMED_HGLOBAL: u32 = 1;
const GMEM_MOVEABLE: u32 = 0x2;
const MK_LBUTTON: u32 = 0x1;
const MK_RBUTTON: u32 = 0x2;
const MK_MBUTTON: u32 = 0x10;

// ---- The data object ----

const DataVtbl = extern struct {
    QueryInterface: *const fn (*DataObject, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*DataObject) callconv(.winapi) u32,
    Release: *const fn (*DataObject) callconv(.winapi) u32,
    GetData: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    GetDataHere: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(.winapi) HRESULT,
    QueryGetData: *const fn (*DataObject, *const FORMATETC) callconv(.winapi) HRESULT,
    GetCanonicalFormatEtc: *const fn (*DataObject, *const FORMATETC, *FORMATETC) callconv(.winapi) HRESULT,
    SetData: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM, i32) callconv(.winapi) HRESULT,
    EnumFormatEtc: *const fn (*DataObject, u32, *?*anyopaque) callconv(.winapi) HRESULT,
    DAdvise: *const fn (*DataObject, *const FORMATETC, u32, ?*anyopaque, *u32) callconv(.winapi) HRESULT,
    DUnadvise: *const fn (*DataObject, u32) callconv(.winapi) HRESULT,
    EnumDAdvise: *const fn (*DataObject, *?*anyopaque) callconv(.winapi) HRESULT,
};

const data_vtbl: DataVtbl = .{
    .QueryInterface = dataQI,
    .AddRef = dataAddRef,
    .Release = dataRelease,
    .GetData = getData,
    .GetDataHere = getDataHere,
    .QueryGetData = queryGetData,
    .GetCanonicalFormatEtc = canonical,
    .SetData = setData,
    .EnumFormatEtc = enumFormatEtc,
    .DAdvise = dAdvise,
    .DUnadvise = dUnadvise,
    .EnumDAdvise = enumDAdvise,
};

pub const DataObject = extern struct {
    vtbl: *const DataVtbl = &data_vtbl,
    refs: u32 = 1,
    gpa: *const std.mem.Allocator,
    /// The `DROPFILES` and the paths, or empty.
    hdrop: [*]const u8,
    hdrop_len: usize,
    /// The text in UTF-16 with its 0, or empty.
    text: [*]const u16,
    text_len: usize,

    pub fn create(gpa: *const std.mem.Allocator, d: plat.DragData) !*DataObject {
        const o = try gpa.create(DataObject);
        errdefer gpa.destroy(o);
        var files: []const u8 = &.{};
        if (d.files.len > 0) files = try dropFiles(gpa.*, d.files);
        errdefer gpa.free(files);
        var text: []const u16 = &.{};
        if (d.text.len > 0) text = try std.unicode.utf8ToUtf16LeAllocZ(gpa.*, d.text);
        o.* = .{ .gpa = gpa, .hdrop = files.ptr, .hdrop_len = files.len, .text = text.ptr, .text_len = text.len };
        return o;
    }

    fn formats(o: *const DataObject, out: *[2]FORMATETC) []const FORMATETC {
        var n: usize = 0;
        if (o.hdrop_len > 0) {
            out[n] = .{ .cfFormat = windrop.CF_HDROP };
            n += 1;
        }
        if (o.text_len > 0) {
            out[n] = .{ .cfFormat = windrop.CF_UNICODETEXT };
            n += 1;
        }
        return out[0..n];
    }

    fn bytesOf(o: *const DataObject, cf: u16) ?[]const u8 {
        if (cf == windrop.CF_HDROP and o.hdrop_len > 0) return o.hdrop[0..o.hdrop_len];
        // The text with its 0.
        if (cf == windrop.CF_UNICODETEXT and o.text_len > 0) return std.mem.sliceAsBytes(o.text[0 .. o.text_len + 1]);
        return null;
    }
};

/// A `DROPFILES` of 20 bytes, then each path in UTF-16 with `\` and a
/// 0, then one more 0.
pub fn dropFiles(a: std.mem.Allocator, files: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var head: [20]u8 = @splat(0);
    std.mem.writeInt(u32, head[0..4], 20, .little); // pFiles
    std.mem.writeInt(u32, head[16..20], 1, .little); // fWide
    try out.appendSlice(a, &head);
    for (files) |f| {
        const w = try std.unicode.utf8ToUtf16LeAlloc(a, f);
        defer a.free(w);
        for (w) |*c| if (c.* == '/') {
            c.* = '\\';
        };
        try out.appendSlice(a, std.mem.sliceAsBytes(w));
        try out.appendSlice(a, &.{ 0, 0 });
    }
    try out.appendSlice(a, &.{ 0, 0 });
    return out.toOwnedSlice(a);
}

fn dataQI(o: *DataObject, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IDataObject)) {
        out.* = o;
        _ = dataAddRef(o);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn dataAddRef(o: *DataObject) callconv(.winapi) u32 {
    o.refs += 1;
    return o.refs;
}

fn dataRelease(o: *DataObject) callconv(.winapi) u32 {
    o.refs -= 1;
    const n = o.refs;
    if (n == 0) {
        const gpa = o.gpa.*;
        if (o.hdrop_len > 0) gpa.free(o.hdrop[0..o.hdrop_len]);
        if (o.text_len > 0) gpa.free(o.text[0 .. o.text_len + 1]);
        gpa.destroy(o);
    }
    return n;
}

fn queryGetData(o: *DataObject, f: *const FORMATETC) callconv(.winapi) HRESULT {
    if (f.tymed & TYMED_HGLOBAL == 0 or o.bytesOf(f.cfFormat) == null) return DV_E_FORMATETC;
    return S_OK;
}

fn getData(o: *DataObject, f: *const FORMATETC, m: *STGMEDIUM) callconv(.winapi) HRESULT {
    if (f.tymed & TYMED_HGLOBAL == 0) return DV_E_FORMATETC;
    const bytes = o.bytesOf(f.cfFormat) orelse return DV_E_FORMATETC;
    const h = GlobalAlloc(GMEM_MOVEABLE, bytes.len) orelse return E_OUTOFMEMORY;
    const p = GlobalLock(h) orelse {
        _ = GlobalFree(h);
        return E_OUTOFMEMORY;
    };
    @memcpy(@as([*]u8, @ptrCast(p))[0..bytes.len], bytes);
    _ = GlobalUnlock(h);
    m.* = .{ .tymed = TYMED_HGLOBAL, .data = h, .release = null };
    return S_OK;
}

fn getDataHere(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM) callconv(.winapi) HRESULT {
    return E_NOTIMPL;
}

fn canonical(_: *DataObject, _: *const FORMATETC, out: *FORMATETC) callconv(.winapi) HRESULT {
    out.ptd = null;
    return E_NOTIMPL;
}

fn setData(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM, _: i32) callconv(.winapi) HRESULT {
    return E_NOTIMPL;
}

fn enumFormatEtc(o: *DataObject, dir: u32, out: *?*anyopaque) callconv(.winapi) HRESULT {
    // DATADIR_GET is 1.
    if (dir != 1) {
        out.* = null;
        return E_NOTIMPL;
    }
    var buf: [2]FORMATETC = undefined;
    const list = o.formats(&buf);
    return SHCreateStdEnumFmtEtc(@intCast(list.len), list.ptr, out);
}

fn dAdvise(_: *DataObject, _: *const FORMATETC, _: u32, _: ?*anyopaque, _: *u32) callconv(.winapi) HRESULT {
    return OLE_E_ADVISENOTSUPPORTED;
}

fn dUnadvise(_: *DataObject, _: u32) callconv(.winapi) HRESULT {
    return OLE_E_ADVISENOTSUPPORTED;
}

fn enumDAdvise(_: *DataObject, out: *?*anyopaque) callconv(.winapi) HRESULT {
    out.* = null;
    return OLE_E_ADVISENOTSUPPORTED;
}

/// The data of a format through the table of the object, as a receiver
/// gets it, for the tests: the bytes of the `HGLOBAL`, in memory of `a`.
pub fn readFormat(a: std.mem.Allocator, o: *DataObject, cf: u16) !?[]u8 {
    var f: FORMATETC = .{ .cfFormat = cf };
    var m: STGMEDIUM = .{};
    if (o.vtbl.GetData(o, &f, &m) != S_OK) return null;
    const h = m.data.?;
    defer _ = GlobalFree(h);
    const p = GlobalLock(h) orelse return error.Lock;
    defer _ = GlobalUnlock(h);
    const size = GlobalSize(h);
    return try a.dupe(u8, @as([*]const u8, @ptrCast(p))[0..size]);
}
extern "kernel32" fn GlobalSize(h: *anyopaque) callconv(.winapi) usize;

// ---- The drop source ----

const SourceVtbl = extern struct {
    QueryInterface: *const fn (*DropSource, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*DropSource) callconv(.winapi) u32,
    Release: *const fn (*DropSource) callconv(.winapi) u32,
    QueryContinueDrag: *const fn (*DropSource, i32, u32) callconv(.winapi) HRESULT,
    GiveFeedback: *const fn (*DropSource, u32) callconv(.winapi) HRESULT,
};

const source_vtbl: SourceVtbl = .{
    .QueryInterface = sourceQI,
    .AddRef = sourceAddRef,
    .Release = sourceRelease,
    .QueryContinueDrag = queryContinueDrag,
    .GiveFeedback = giveFeedback,
};

pub const DropSource = extern struct {
    vtbl: *const SourceVtbl = &source_vtbl,
    refs: u32 = 1,
    /// For the tests: the first question ends the drag with a cancel.
    cancel_now: bool = false,
};

fn sourceQI(s: *DropSource, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
    if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_IDropSource)) {
        out.* = s;
        _ = sourceAddRef(s);
        return S_OK;
    }
    out.* = null;
    return E_NOINTERFACE;
}

fn sourceAddRef(s: *DropSource) callconv(.winapi) u32 {
    s.refs += 1;
    return s.refs;
}

/// The source lives on the stack of `run`, which outlives the drag.
fn sourceRelease(s: *DropSource) callconv(.winapi) u32 {
    s.refs -= 1;
    return s.refs;
}

fn queryContinueDrag(s: *DropSource, escape: i32, keys: u32) callconv(.winapi) HRESULT {
    if (escape != 0 or s.cancel_now) return DRAGDROP_S_CANCEL;
    if (keys & (MK_LBUTTON | MK_RBUTTON | MK_MBUTTON) == 0) return DRAGDROP_S_DROP;
    return S_OK;
}

fn giveFeedback(_: *DropSource, _: u32) callconv(.winapi) HRESULT {
    return DRAGDROP_S_USEDEFAULTCURSORS;
}

// ---- The drag ----

var ole_done = false;

/// Runs a drag to its end, with the source `src`, and gives the action
/// of the target.
pub fn runWith(gpa: *const std.mem.Allocator, d: plat.DragData, src: *DropSource) plat.DragAction {
    if (!ole_done) {
        if (OleInitialize(null) < 0) return .none;
        ole_done = true;
    }
    const o = DataObject.create(gpa, d) catch return .none;
    defer _ = dataRelease(o);
    var effect: u32 = 0;
    const ok: u32 = DROPEFFECT_COPY | if (d.allow_move) DROPEFFECT_MOVE else 0;
    if (DoDragDrop(o, src, ok, &effect) != DRAGDROP_S_DROP) return .none;
    if (effect & DROPEFFECT_MOVE != 0) return .move;
    if (effect & DROPEFFECT_COPY != 0) return .copy;
    return .none;
}

pub fn run(gpa: *const std.mem.Allocator, d: plat.DragData) plat.DragAction {
    var src: DropSource = .{};
    return runWith(gpa, d, &src);
}
