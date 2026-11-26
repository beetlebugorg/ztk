//! Calls to the Objective-C runtime of macOS from Zig, for the AppKit
//! backend and the Metal renderer. A message send is `objc_msgSend` cast
//! to a function pointer of the type that the caller gives, with the
//! receiver and the selector as the first two arguments. On arm64 the same
//! entry point returns each type, a structure too. On x86-64 a structure
//! that is larger than 16 bytes needs `objc_msgSend_stret`: `call` stops
//! the build for that case, and `callStruct` sends a message with no
//! arguments that gives such a structure, such as an `NSRect`. A class that the backend defines at run
//! time is a subclass with methods that are Zig functions of the C calling
//! convention, made with `objc_allocateClassPair`, `class_addMethod`, and
//! `objc_registerClassPair`. An instance keeps a pointer to Zig data in an
//! instance variable of the class.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");

pub const Id = *opaque {};
pub const Class = *opaque {};
pub const Sel = *opaque {};
pub const Ivar = *opaque {};
/// The YES and NO of Objective-C on arm64 and x86-64.
pub const BOOL = bool;

extern "objc" fn objc_getClass(name: [*:0]const u8) ?Class;
extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
extern "objc" fn objc_msgSend() void;
extern "objc" fn objc_msgSend_stret() void;
extern "objc" fn objc_allocateClassPair(super: Class, name: [*:0]const u8, extra: usize) ?Class;
extern "objc" fn objc_registerClassPair(cls: Class) void;
extern "objc" fn objc_disposeClassPair(cls: Class) void;
extern "objc" fn class_addMethod(cls: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) BOOL;
extern "objc" fn class_addIvar(cls: Class, name: [*:0]const u8, size: usize, alignment: u8, types: [*:0]const u8) BOOL;
extern "objc" fn class_getInstanceVariable(cls: Class, name: [*:0]const u8) ?Ivar;
extern "objc" fn ivar_getOffset(ivar: Ivar) isize;
extern "objc" fn object_getClass(obj: Id) Class;
extern "objc" fn objc_getProtocol(name: [*:0]const u8) ?*anyopaque;
extern "objc" fn class_addProtocol(cls: Class, protocol: *anyopaque) BOOL;
extern "objc" fn objc_autoreleasePoolPush() *anyopaque;
extern "objc" fn objc_autoreleasePoolPop(pool: *anyopaque) void;

pub fn class(name: [*:0]const u8) ?Class {
    return objc_getClass(name);
}

pub fn sel(name: [*:0]const u8) Sel {
    return sel_registerName(name);
}

/// Sends `selector` to `target` with `args`. `Fn` is the type of the
/// method as a C function: its first two parameters are the receiver and
/// the selector, and its return type is the result.
pub fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    const Ret = @typeInfo(Fn).@"fn".return_type.?;
    if (builtin.cpu.arch == .x86_64 and @typeInfo(Ret) == .@"struct" and @sizeOf(Ret) > 16)
        @compileError("a structure result larger than 16 bytes needs objc_msgSend_stret on x86-64");
    const f: *const Fn = @ptrCast(&objc_msgSend);
    // The receiver has the type of the first parameter of `Fn`: an Id for
    // an instance method, a Class for a class method.
    const Receiver = @typeInfo(Fn).@"fn".param_types[0].?;
    switch (@TypeOf(target)) {
        Id, Class => {},
        else => @compileError("the receiver must be an Id or a Class"),
    }
    const receiver: Receiver = @ptrCast(target);
    return @call(.auto, f, .{ receiver, sel_registerName(selector) } ++ args);
}

/// Sends `selector` with no arguments to `target` and gives the structure
/// of type `Ret` that it returns, on arm64 and on x86-64.
pub fn callStruct(comptime Ret: type, target: Id, selector: [*:0]const u8) Ret {
    if (builtin.cpu.arch == .x86_64 and @sizeOf(Ret) > 16) {
        // The caller gives the memory of the result as a hidden first argument.
        const f: *const fn (*Ret, Id, Sel) callconv(.c) void = @ptrCast(&objc_msgSend_stret);
        var out: Ret = undefined;
        f(&out, target, sel_registerName(selector));
        return out;
    }
    const f: *const fn (Id, Sel) callconv(.c) Ret = @ptrCast(&objc_msgSend);
    return f(target, sel_registerName(selector));
}

/// `[[cls alloc] init]`.
pub fn new(cls: Class) Id {
    const obj = call(fn (Id, Sel) callconv(.c) Id, cls, "alloc", .{});
    return call(fn (Id, Sel) callconv(.c) Id, obj, "init", .{});
}

pub fn release(obj: Id) void {
    call(fn (Id, Sel) callconv(.c) void, obj, "release", .{});
}

/// An `NSString` with a copy of `text`, with a retain count of one.
pub fn nsString(text: []const u8) Id {
    const cls = class("NSString").?;
    const obj = call(fn (Id, Sel) callconv(.c) Id, cls, "alloc", .{});
    // NSUTF8StringEncoding is 4.
    return call(fn (Id, Sel, [*]const u8, usize, usize) callconv(.c) Id, obj, "initWithBytes:length:encoding:", .{ text.ptr, text.len, 4 });
}

/// The UTF-8 bytes of an `NSString`. The memory belongs to the string and
/// to the autorelease pool around the call.
pub fn utf8(str: Id) []const u8 {
    const p = call(fn (Id, Sel) callconv(.c) ?[*:0]const u8, str, "UTF8String", .{}) orelse return "";
    return std.mem.span(p);
}

/// A pool that frees the autoreleased objects of the calls between `push`
/// and `pop`.
pub const Pool = struct {
    handle: *anyopaque,
    pub fn push() Pool {
        return .{ .handle = objc_autoreleasePoolPush() };
    }
    pub fn pop(p: Pool) void {
        objc_autoreleasePoolPop(p.handle);
    }
};

/// A class that the program defines at run time. Each instance has one
/// instance variable, `ztk`, with a pointer to Zig data.
pub const ClassBuilder = struct {
    cls: Class,

    /// Starts a subclass of `super`. Gives null when a class has the name.
    pub fn begin(super: [*:0]const u8, name: [*:0]const u8) ?ClassBuilder {
        const parent = class(super) orelse return null;
        const cls = objc_allocateClassPair(parent, name, 0) orelse return null;
        // "^v" is the type encoding of `void *`.
        _ = class_addIvar(cls, "ztk", @sizeOf(usize), std.math.log2_int(usize, @alignOf(usize)), "^v");
        return .{ .cls = cls };
    }

    /// Adds a method. `types` is its type encoding, such as "v@:@" for a
    /// method with one object argument and no result.
    pub fn method(b: ClassBuilder, name: [*:0]const u8, imp: *const anyopaque, types: [*:0]const u8) void {
        _ = class_addMethod(b.cls, sel_registerName(name), imp, types);
    }

    /// Declares that the class adopts a protocol, such as
    /// `NSTextInputClient`. False when the system has no such protocol.
    pub fn protocol(b: ClassBuilder, name: [*:0]const u8) bool {
        const p = objc_getProtocol(name) orelse return false;
        return class_addProtocol(b.cls, p);
    }

    pub fn finish(b: ClassBuilder) Class {
        objc_registerClassPair(b.cls);
        return b.cls;
    }
};

fn ivarSlot(obj: Id) *?*anyopaque {
    const iv = class_getInstanceVariable(object_getClass(obj), "ztk").?;
    const base: [*]u8 = @ptrCast(obj);
    return @ptrCast(@alignCast(base + @as(usize, @intCast(ivar_getOffset(iv)))));
}

/// Sets the Zig data of an instance of a class of `ClassBuilder`.
pub fn setData(obj: Id, data: ?*anyopaque) void {
    ivarSlot(obj).* = data;
}

/// The Zig data of an instance of a class of `ClassBuilder`.
pub fn getData(obj: Id) ?*anyopaque {
    return ivarSlot(obj).*;
}

test "objc: an NSString keeps its UTF-8 text" {
    const pool = Pool.push();
    defer pool.pop();
    const s = nsString("zig ✓ text");
    defer release(s);
    try std.testing.expectEqualStrings("zig ✓ text", utf8(s));
    const len = call(fn (Id, Sel) callconv(.c) usize, s, "length", .{});
    // UTF-16 code units: 8 ASCII characters, one check mark, and a space.
    try std.testing.expectEqual(@as(usize, 10), len);
}

const Counter = struct { hits: i64 = 0 };

fn addHits(self: Id, _: Sel, n: i64) callconv(.c) i64 {
    const c: *Counter = @ptrCast(@alignCast(getData(self).?));
    c.hits += n;
    return c.hits;
}

test "objc: a class made at run time calls a Zig method with its data" {
    const pool = Pool.push();
    defer pool.pop();
    // "q@:q": a long long result, the receiver, the selector, and a long long.
    const b = ClassBuilder.begin("NSObject", "ZtkTestCounter") orelse return error.SkipZigTest;
    b.method("addHits:", @ptrCast(&addHits), "q@:q");
    const cls = b.finish();
    var counter: Counter = .{};
    const obj = new(cls);
    defer release(obj);
    setData(obj, &counter);
    try std.testing.expectEqual(@as(i64, 3), call(fn (Id, Sel, i64) callconv(.c) i64, obj, "addHits:", .{3}));
    try std.testing.expectEqual(@as(i64, 7), call(fn (Id, Sel, i64) callconv(.c) i64, obj, "addHits:", .{4}));
    try std.testing.expectEqual(@as(i64, 7), counter.hits);
    // A second class of the same name does not exist.
    try std.testing.expect(ClassBuilder.begin("NSObject", "ZtkTestCounter") == null);
}
