//! The tasks of the jump list of the app on Windows (ztk#66): the items
//! that the menu of the taskbar button shows under "Tasks".
//!
//! `build` makes an `ICustomDestinationList`, begins a list, and adds one
//! `IShellLinkW` for each task: this program with the arguments of the
//! task, its title (`PKEY_Title` through `IPropertyStore`), its
//! description, and its icon. `commit` writes the list for the app, and
//! `abort` drops it. An empty list of tasks deletes the list of the app.
//! Each call needs COM on the thread, so the list opens COM
//! (single-threaded) and closes it when it opened it.
//!
//! The slots, the IDs, and the property key follow `ShObjIdl_core.h`,
//! `ObjectArray.h`, `propsys.h`, and `propkey.h` of the Windows SDK
//! 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const plat = @import("platform.zig");
const GUID = com.GUID;
const HRESULT = com.HRESULT;
const call = com.call;

const CLSID_DestinationList = GUID.parse("77f10cf0-3db5-4966-b520-b7c54fd35ed6");
const CLSID_EnumerableObjectCollection = GUID.parse("2d3468c1-36a7-43b6-ac24-d3f02fd9607a");
const CLSID_ShellLink = GUID.parse("00021401-0000-0000-c000-000000000046");
const IID_ICustomDestinationList = GUID.parse("6332debf-87b5-4670-90c0-5e57b408a49e");
const IID_IObjectCollection = GUID.parse("5632b1a4-e38a-400a-928a-d4cd63230295");
const IID_IObjectArray = GUID.parse("92ca9dcd-5622-4bba-a805-5e9f541bd8c9");
const IID_IShellLinkW = GUID.parse("000214f9-0000-0000-c000-000000000046");
const IID_IPropertyStore = GUID.parse("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99");

const PROPERTYKEY = extern struct { fmtid: GUID, pid: u32 };
const PKEY_Title: PROPERTYKEY = .{ .fmtid = GUID.parse("f29f85e0-4ff9-1068-ab91-08002b27b3d9"), .pid = 2 };
/// PROPVARIANT: 24 bytes on x64, with the value at 8. VT_LPWSTR is 31.
const PROPVARIANT = extern struct { vt: u16 = 31, r1: u16 = 0, r2: u16 = 0, r3: u16 = 0, ptr: ?[*:0]const u16 = null, pad: u64 = 0 };

const slot = struct {
    // ICustomDestinationList
    const begin_list = 4;
    const add_user_tasks = 7;
    const commit_list = 8;
    const delete_list = 10;
    const abort_list = 11;
    // IObjectCollection
    const add_object = 5;
    // IShellLinkW
    const set_description = 7;
    const set_arguments = 11;
    const set_icon_location = 17;
    const set_path = 20;
    // IPropertyStore
    const set_value = 6;
    const commit = 7;
    // IUnknown
    const query_interface = 0;
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;

const CLSCTX_INPROC_SERVER: u32 = 0x1;

fn create(clsid: *const GUID, iid: *const GUID) ?*anyopaque {
    var out: ?*anyopaque = null;
    if (CoCreateInstance(clsid, null, CLSCTX_INPROC_SERVER, iid, &out) < 0) return null;
    return out;
}

fn wide(a: std.mem.Allocator, s: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, s) catch |e| switch (e) {
        error.InvalidUtf8 => std.unicode.utf8ToUtf16LeAllocZ(a, ""),
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// A list of tasks that began and waits for `commit` or `abort`.
pub const List = struct {
    dest: *anyopaque,
    com_hr: HRESULT,
    /// The number of tasks in the list.
    count: usize,

    pub fn commit(l: List) bool {
        defer l.close();
        return call(HRESULT, l.dest, slot.commit_list, .{}) >= 0;
    }

    pub fn abort(l: List) void {
        _ = call(HRESULT, l.dest, slot.abort_list, .{});
        l.close();
    }

    fn close(l: List) void {
        com.release(l.dest);
        if (l.com_hr == 0 or l.com_hr == 1) CoUninitialize();
    }
};

/// One link of a task: this program with the arguments of the task.
fn link(a: std.mem.Allocator, program: [*:0]const u16, t: *const plat.JumpTask) !*anyopaque {
    const l = create(&CLSID_ShellLink, &IID_IShellLinkW) orelse return error.ComCall;
    errdefer com.release(l);
    try com.check(call(HRESULT, l, slot.set_path, .{program}));
    const args = try wide(a, t.args);
    try com.check(call(HRESULT, l, slot.set_arguments, .{args.ptr}));
    if (t.description.len > 0) {
        const d = try wide(a, t.description);
        try com.check(call(HRESULT, l, slot.set_description, .{d.ptr}));
    }
    if (t.icon.len > 0) {
        const i = try wide(a, t.icon);
        try com.check(call(HRESULT, l, slot.set_icon_location, .{ i.ptr, @as(c_int, t.icon_index) }));
    }
    // The title of the item is a property of the link.
    var store: ?*anyopaque = null;
    try com.check(call(HRESULT, l, slot.query_interface, .{ &IID_IPropertyStore, &store }));
    defer com.release(store.?);
    const title = try wide(a, t.title);
    const v: PROPVARIANT = .{ .ptr = title.ptr };
    try com.check(call(HRESULT, store.?, slot.set_value, .{ &PKEY_Title, &v }));
    try com.check(call(HRESULT, store.?, slot.commit, .{}));
    return l;
}

/// Begins a list with the tasks. `commit` or `abort` ends it.
pub fn build(gpa: std.mem.Allocator, tasks: []const plat.JumpTask) !List {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE
    const hr = CoInitializeEx(null, 0x2 | 0x4);
    errdefer if (hr == 0 or hr == 1) CoUninitialize();
    const dest = create(&CLSID_DestinationList, &IID_ICustomDestinationList) orelse return error.ComCall;
    errdefer com.release(dest);
    var slots: u32 = 0;
    var removed: ?*anyopaque = null;
    try com.check(call(HRESULT, dest, slot.begin_list, .{ &slots, &IID_IObjectArray, &removed }));
    if (removed) |r| com.release(r);
    errdefer _ = call(HRESULT, dest, slot.abort_list, .{});
    var program: [32768]u16 = undefined;
    const n = GetModuleFileNameW(null, &program, program.len);
    if (n == 0 or n >= program.len) return error.ComCall;
    program[n] = 0;
    const coll = create(&CLSID_EnumerableObjectCollection, &IID_IObjectCollection) orelse return error.ComCall;
    defer com.release(coll);
    for (tasks) |*t| {
        const l = try link(a, program[0..n :0].ptr, t);
        defer com.release(l);
        try com.check(call(HRESULT, coll, slot.add_object, .{l}));
    }
    // An IObjectCollection is an IObjectArray.
    try com.check(call(HRESULT, dest, slot.add_user_tasks, .{coll}));
    return .{ .dest = dest, .com_hr = hr, .count = tasks.len };
}

/// Sets the tasks of the jump list of the app; an empty list deletes it.
pub fn set(gpa: std.mem.Allocator, tasks: []const plat.JumpTask) bool {
    if (tasks.len == 0) {
        const hr = CoInitializeEx(null, 0x2 | 0x4);
        defer if (hr == 0 or hr == 1) CoUninitialize();
        const dest = create(&CLSID_DestinationList, &IID_ICustomDestinationList) orelse return false;
        defer com.release(dest);
        return call(HRESULT, dest, slot.delete_list, .{@as(?[*:0]const u16, null)}) >= 0;
    }
    const l = build(gpa, tasks) catch return false;
    return l.commit();
}
