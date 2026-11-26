//! The recent documents of the app on Windows (ztk#64).
//!
//! `add` gives the full path to `SHAddToRecentDocs` with `SHARD_PATHW`.
//! The shell puts the file in the recent items of the user and in the
//! jump list of the app, when the app is a handler of the type of the
//! file. `clear` calls `RemoveAllDestinations` of
//! `IApplicationDestinations`, which empties the recent and frequent
//! items of the jump list of this app only, and leaves the recent
//! items of other apps alone. Both calls need COM on the thread, so
//! each one opens COM (single-threaded) and closes it when it opened it.
//! The COM slots are from `shobjidl_core.h` of the Windows SDK.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const GUID = com.GUID;

const SHARD_PATHW = 3;
extern "shell32" fn SHAddToRecentDocs(flags: u32, pv: ?*const anyopaque) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) com.HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) com.HRESULT;

const CLSID_ApplicationDestinations = GUID.parse("86c14003-4d6b-4ef3-a7b4-0506663b2e68");
const IID_IApplicationDestinations = GUID.parse("12337d35-94c6-48a0-bce7-6a9c69d4d600");
/// IUnknown (0-2), SetAppID, RemoveDestination, RemoveAllDestinations.
const slot_remove_all = 5;

/// COM on the thread for one call. S_OK and S_FALSE need the close; a
/// thread in another mode keeps its COM.
const ComScope = struct {
    hr: com.HRESULT,
    fn open() ComScope {
        // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE
        return .{ .hr = CoInitializeEx(null, 0x2 | 0x4) };
    }
    fn close(s: ComScope) void {
        if (s.hr == 0 or s.hr == 1) CoUninitialize();
    }
};

/// The wide form of a path, with `\` between the parts.
fn widePath(buf: []u16, path: []const u8) ?[:0]const u16 {
    const n = std.unicode.utf8ToUtf16Le(buf[0 .. buf.len - 1], path) catch return null;
    for (buf[0..n]) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    buf[n] = 0;
    return buf[0..n :0];
}

pub fn add(path: []const u8) bool {
    var buf: [32768]u16 = undefined;
    if (path.len >= buf.len) return false;
    const wide = widePath(&buf, path) orelse return false;
    const scope = ComScope.open();
    defer scope.close();
    SHAddToRecentDocs(SHARD_PATHW, wide.ptr);
    return true;
}

pub fn clear() void {
    const scope = ComScope.open();
    defer scope.close();
    var obj: ?*anyopaque = null;
    // CLSCTX_INPROC_SERVER
    if (CoCreateInstance(&CLSID_ApplicationDestinations, null, 0x1, &IID_IApplicationDestinations, &obj) < 0) return;
    const d = obj orelse return;
    defer com.release(d);
    _ = com.call(com.HRESULT, d, slot_remove_all, .{});
}

test "winrecent: a path becomes a wide path with backslashes" {
    var buf: [64]u16 = undefined;
    const w = widePath(&buf, "C:/a/b.txt").?;
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("C:\\a\\b.txt"), w);
}

test "winrecent: clear empties the list of the test program" {
    // The list belongs to the test program, so the clear touches no other app.
    clear();
}
