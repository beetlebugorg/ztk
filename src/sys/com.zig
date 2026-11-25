//! The helpers for COM objects: a GUID with its parse from the text form,
//! and a call of a method by its slot. A COM object starts with a pointer
//! to its table of functions. `call` reads the function at a slot of that
//! table and casts it to the type of the method, with the object first
//! and then the arguments. The Direct3D 12 renderer and the text store of
//! the Text Services Framework use it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const HRESULT = i32;

pub const GUID = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,

    pub fn parse(comptime s: []const u8) GUID {
        @setEvalBranchQuota(10_000);
        const hex = struct {
            fn n(comptime t: []const u8) u64 {
                return std.fmt.parseInt(u64, t, 16) catch unreachable;
            }
        }.n;
        var d: [8]u8 = undefined;
        d[0] = @intCast(hex(s[19..21]));
        d[1] = @intCast(hex(s[21..23]));
        inline for (0..6) |i| d[2 + i] = @intCast(hex(s[24 + 2 * i ..][0..2]));
        return .{ .a = @intCast(hex(s[0..8])), .b = @intCast(hex(s[9..13])), .c = @intCast(hex(s[14..18])), .d = d };
    }
};

/// The function at `index` of the table of `obj`, with the type `F`.
fn method(comptime F: type, obj: anytype, comptime index: usize) F {
    const table: *const [*]const *const anyopaque = @ptrCast(@alignCast(obj));
    return @ptrCast(table.*[index]);
}

/// The pointer type of a method: the object, then the types of `Args`.
fn Fn(comptime Args: type, comptime R: type) type {
    const info = @typeInfo(Args).@"struct";
    var types: [info.fields.len + 1]type = undefined;
    types[0] = *anyopaque;
    for (info.fields, 0..) |f, i| types[i + 1] = f.type;
    const attrs: [types.len]std.builtin.Type.Fn.Param.Attributes = @splat(.{});
    return *const @Fn(&types, &attrs, R, .{ .@"callconv" = .winapi });
}

/// Calls the method at `index` of `obj` with `args`.
pub fn call(comptime R: type, obj: anytype, comptime index: usize, args: anytype) R {
    const f = method(Fn(@TypeOf(args), R), obj, index);
    return @call(.auto, f, .{@as(*anyopaque, @ptrCast(obj))} ++ args);
}

pub fn release(obj: anytype) void {
    _ = call(u32, obj, 2, .{});
}

pub fn check(hr: HRESULT) !void {
    if (hr < 0) return error.ComCall;
}

test "com: a GUID parses in the byte order of the C form" {
    const g = GUID.parse("189819f1-1db6-4b57-be54-1821339b85f7");
    try std.testing.expectEqual(@as(u32, 0x189819f1), g.a);
    try std.testing.expectEqual(@as(u16, 0x1db6), g.b);
    try std.testing.expectEqual(@as(u16, 0x4b57), g.c);
    try std.testing.expectEqualSlices(u8, &.{ 0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7 }, &g.d);
}
