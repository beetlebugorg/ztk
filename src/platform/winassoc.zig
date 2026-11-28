//! The file associations of the Win32 backend, for `ztk::win::fileassoc`
//! (ztk#66): the keys of the registry of the user that make this program
//! a handler of a file extension.
//!
//! `plan` gives the values as text, with no call of the system, so a test
//! checks them with no change of the machine. Each key is under
//! `Software\Classes` of the user:
//!
//!   .ext\OpenWithProgids   PROGID = ""              the extension names the handler
//!   PROGID                 (default) = the name of the file type
//!   PROGID\DefaultIcon     (default) = FILE,INDEX
//!   PROGID\shell\open\command (default) = "PROGRAM" ARGS "%1"
//!
//! `OpenWithProgids` adds the program to the "Open with" list of the
//! extension and does not replace the default handler that the user
//! chose. The ProgID is `ztk.NAME.EXT`, with the letters and digits of
//! the file name of the program and the extension with no dot, so two
//! programs keep their own keys.
//!
//! `write` makes the keys under a base key, and `erase` removes the value
//! of the extension and the key of the ProgID. `set` runs one of them
//! under `Software\Classes` for this program and then tells the shell
//! that the associations changed (`SHChangeNotify`). The tests use a base
//! key of their own, which they delete.
//!
//! The functions and the constants follow `winreg.h` and `ShlObj_core.h`
//! of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const plat = @import("platform.zig");

pub const HKEY = *opaque {};
/// HKEY_CURRENT_USER: 0x80000001 with its sign in the high bits.
pub const current_user: HKEY = @ptrFromInt(0xFFFF_FFFF_8000_0001);
pub const classes = "Software\\Classes";

const KEY_WRITE: u32 = 0x20006;
const REG_SZ: u32 = 1;
const SHCNE_ASSOCCHANGED: i32 = 0x0800_0000;

extern "advapi32" fn RegCreateKeyExW(key: HKEY, sub: [*:0]const u16, reserved: u32, class: ?[*:0]const u16, options: u32, access: u32, security: ?*anyopaque, out: *HKEY, disposition: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn RegSetValueExW(key: HKEY, name: [*:0]const u16, reserved: u32, kind: u32, data: [*]const u8, size: u32) callconv(.winapi) i32;
extern "advapi32" fn RegCloseKey(key: HKEY) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteKeyValueW(key: HKEY, sub: [*:0]const u16, name: [*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn RegDeleteTreeW(key: HKEY, sub: [*:0]const u16) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, size: u32) callconv(.winapi) u32;
extern "shell32" fn SHChangeNotify(event: i32, flags: u32, item1: ?*const anyopaque, item2: ?*const anyopaque) callconv(.winapi) void;

/// One value of the registry: the key under the base key, the name of the
/// value (empty for the default value), and its text.
pub const Entry = struct { key: []const u8, name: []const u8, data: []const u8 };

/// True for a dot and then letters, digits, `+`, `-`, or `_`.
pub fn validExt(ext: []const u8) bool {
    if (ext.len < 2 or ext[0] != '.') return false;
    for (ext[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '_') return false;
    }
    return true;
}

/// `ztk.NAME.EXT` for the program at `exe` and a valid extension. NAME
/// has the letters and digits of the file name with no `.exe`.
pub fn progId(a: std.mem.Allocator, exe: []const u8, ext: []const u8) ![]u8 {
    var base = exe;
    if (std.mem.lastIndexOfAny(u8, exe, "\\/")) |i| base = exe[i + 1 ..];
    if (std.ascii.endsWithIgnoreCase(base, ".exe")) base = base[0 .. base.len - 4];
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "ztk.");
    for (base) |c| {
        if (std.ascii.isAlphanumeric(c)) try out.append(a, c);
    }
    try out.append(a, '.');
    try out.appendSlice(a, ext[1..]);
    return out.toOwnedSlice(a);
}

/// The values of an association of the program at `exe`, in memory of
/// `a`, which is an arena of the caller. With no name the file type is
/// `EXT file`, and with no icon the icon is the first icon of the
/// program.
pub fn plan(a: std.mem.Allocator, assoc: plat.FileAssoc, exe: []const u8) ![4]Entry {
    const id = try progId(a, exe, assoc.ext);
    const name = if (assoc.name.len > 0) assoc.name else try std.fmt.allocPrint(a, "{s} file", .{assoc.ext[1..]});
    const icon = if (assoc.icon.len > 0)
        try std.fmt.allocPrint(a, "{s},{d}", .{ assoc.icon, assoc.icon_index })
    else
        try std.fmt.allocPrint(a, "{s},0", .{exe});
    const command = if (assoc.args.len > 0)
        try std.fmt.allocPrint(a, "\"{s}\" {s} \"%1\"", .{ exe, assoc.args })
    else
        try std.fmt.allocPrint(a, "\"{s}\" \"%1\"", .{exe});
    return .{
        .{ .key = try std.fmt.allocPrint(a, "{s}\\OpenWithProgids", .{assoc.ext}), .name = id, .data = "" },
        .{ .key = id, .name = "", .data = name },
        .{ .key = try std.fmt.allocPrint(a, "{s}\\DefaultIcon", .{id}), .name = "", .data = icon },
        .{ .key = try std.fmt.allocPrint(a, "{s}\\shell\\open\\command", .{id}), .name = "", .data = command },
    };
}

fn wide(a: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(a, text) catch |e| switch (e) {
        error.InvalidUtf8 => error.BadText,
        error.OutOfMemory => error.OutOfMemory,
    };
}

/// Writes the values under the key `base` of `root`. `a` is an arena.
pub fn write(a: std.mem.Allocator, root: HKEY, base: []const u8, entries: []const Entry) !void {
    for (entries) |e| {
        const path = try wide(a, try std.fmt.allocPrint(a, "{s}\\{s}", .{ base, e.key }));
        var key: HKEY = undefined;
        if (RegCreateKeyExW(root, path.ptr, 0, null, 0, KEY_WRITE, null, &key, null) != 0) return error.Registry;
        defer _ = RegCloseKey(key);
        const data = try wide(a, e.data);
        const bytes = std.mem.sliceAsBytes(data.ptr[0 .. data.len + 1]);
        if (RegSetValueExW(key, (try wide(a, e.name)).ptr, 0, REG_SZ, bytes.ptr, @intCast(bytes.len)) != 0) return error.Registry;
    }
}

/// Removes the value of the extension and the key of the ProgID of
/// `entries` under the key `base` of `root`. A key that does not exist
/// is no error. The key of the extension stays, because other programs
/// keep their values in it.
pub fn erase(a: std.mem.Allocator, root: HKEY, base: []const u8, entries: []const Entry) !void {
    const ext_key = try wide(a, try std.fmt.allocPrint(a, "{s}\\{s}", .{ base, entries[0].key }));
    _ = RegDeleteKeyValueW(root, ext_key.ptr, (try wide(a, entries[0].name)).ptr);
    const id_key = try wide(a, try std.fmt.allocPrint(a, "{s}\\{s}", .{ base, entries[1].key }));
    _ = RegDeleteTreeW(root, id_key.ptr);
}

/// Adds or removes the association of this program for the user, and
/// tells the shell. False when the registry refused a value.
pub fn set(gpa: std.mem.Allocator, assoc: plat.FileAssoc, remove: bool) bool {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var program: [1024]u16 = undefined;
    const n = GetModuleFileNameW(null, &program, program.len);
    if (n == 0 or n >= program.len) return false;
    const exe = std.unicode.utf16LeToUtf8Alloc(a, program[0..n]) catch return false;
    const entries = plan(a, assoc, exe) catch return false;
    if (remove) {
        erase(a, current_user, classes, &entries) catch return false;
    } else {
        write(a, current_user, classes, &entries) catch return false;
    }
    SHChangeNotify(SHCNE_ASSOCCHANGED, 0, null, null);
    return true;
}
