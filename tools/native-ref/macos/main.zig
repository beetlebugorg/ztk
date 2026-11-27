//! The reference renders of AppKit for the native look of macOS (step 2
//! of the macOS section of `docs/dev/native-look.md`).
//!
//!   zig build native-ref -- OUTDIR
//!
//! For each control, size, and state of the list below, and for the light
//! and the dark appearance, the tool makes the AppKit control in a window
//! that it never puts on the screen, and writes:
//!   OUTDIR/NAME.png     the render of the control by AppKit
//!                       (`cacheDisplayInRect:toBitmapImageRep:`), at the
//!                       scale of the main screen
//!   OUTDIR/measures.json the frame, `fittingSize`, `intrinsicContentSize`,
//!                       and `alignmentRectInsets` of each, in points
//! NAME is `control-size-state-appearance`, with `-inactive` for the
//! controls of a window that is not the key window. A window of a class
//! of the tool says it is the key window, so the active state draws with
//! no window on the screen. The app has the activation
//! policy Prohibited, so it has no Dock icon, no menu bar, and no window.
//! The renders are references for the pixel harness and the measures are
//! the sources of `aqua-macos.css`; neither goes into the repository. The
//! accent is the accent of the machine (blue on a CI runner).
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("ztk").objc;
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };
const NSEdgeInsets = extern struct { top: f64, left: f64, bottom: f64, right: f64 };

fn cls(name: [*:0]const u8) Class {
    return objc.class(name).?;
}

fn str(text: []const u8) Id {
    return objc.call(fn (Id, Sel) callconv(.c) Id, objc.nsString(text), "autorelease", .{});
}

fn newWith(class_name: [*:0]const u8, frame: NSRect) Id {
    const raw = objc.call(fn (Class, Sel) callconv(.c) Id, cls(class_name), "alloc", .{});
    return objc.call(fn (Id, Sel, NSRect) callconv(.c) Id, raw, "initWithFrame:", .{frame});
}

fn set(target: Id, sel: [*:0]const u8, arg: anytype) void {
    objc.call(fn (Id, Sel, @TypeOf(arg)) callconv(.c) void, target, sel, .{arg});
}

fn yes(_: Id, _: Sel) callconv(.c) bool {
    return true;
}

/// The window that the tool draws in, which NSApp gives as its key and
/// main window.
var current: ?Id = null;

fn currentWindow(_: Id, _: Sel) callconv(.c) ?Id {
    return current;
}

/// A window that says it is the key window, so AppKit draws its controls
/// in the active state (the accent of the default button, the switch, and
/// the check box) with no window on the screen.
fn keyWindowClass() Class {
    if (objc.class("ZtkRefKeyWindow")) |c| return c;
    const b = objc.ClassBuilder.begin("NSWindow", "ZtkRefKeyWindow").?;
    b.method("isKeyWindow", @ptrCast(&yes), "c@:");
    b.method("isMainWindow", @ptrCast(&yes), "c@:");
    // AppKit asks these when it draws, and a window that is not on the
    // screen says no to them. The private names come from the runtime
    // (class_copyMethodList), and only this tool answers them, never ztk.
    for ([_][*:0]const u8{ "_hasActiveAppearance", "_hasKeyAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "_hasActiveControls", "isOnActiveSpace", "isVisible", "_isKeyWindow", "_isKeyWindowIgnoringFocus", "hasKeyAppearance", "_hostWindowIsKey", "_isOnActiveScreen" }) |n|
        b.method(n, @ptrCast(&yes), "c@:");
    return b.finish();
}

const ReplaceMethod = *const fn (c: Class, name: Sel, imp: *const anyopaque, types: [*:0]const u8) callconv(.c) ?*const anyopaque;

const Size = enum(usize) { regular = 0, small = 1, mini = 2, large = 3 };
const State = enum { rest, disabled, on, default };

const Kind = enum { push, check, radio, toggle, slider, popup, field, segmented, progress, stepper };

/// The control of a kind, made for the state.
fn make(kind: Kind, state: State) Id {
    const frame: NSRect = .{ .origin = .{ .x = 20, .y = 20 }, .size = .{ .w = 120, .h = 24 } };
    const c = switch (kind) {
        .push, .check, .radio => blk: {
            const b = newWith("NSButton", frame);
            // NSButtonTypeMomentaryPushIn 7, Switch 3, Radio 4; bezel rounded 1.
            set(b, "setButtonType:", @as(usize, switch (kind) {
                .push => 7,
                .check => 3,
                else => 4,
            }));
            if (kind == .push) set(b, "setBezelStyle:", @as(usize, 1));
            set(b, "setTitle:", str(switch (kind) {
                .push => "Button",
                .check => "Check box",
                else => "Radio",
            }));
            if (state == .on) set(b, "setState:", @as(isize, 1));
            if (state == .default) set(b, "setKeyEquivalent:", str("\r"));
            break :blk b;
        },
        .toggle => blk: {
            const sw = newWith("NSSwitch", frame);
            if (state == .on) set(sw, "setState:", @as(isize, 1));
            break :blk sw;
        },
        .slider => blk: {
            const sl = newWith("NSSlider", frame);
            set(sl, "setDoubleValue:", @as(f64, if (state == .on) 0.75 else 0.5));
            break :blk sl;
        },
        .popup => blk: {
            const raw = objc.call(fn (Class, Sel) callconv(.c) Id, cls("NSPopUpButton"), "alloc", .{});
            const p = objc.call(fn (Id, Sel, NSRect, bool) callconv(.c) Id, raw, "initWithFrame:pullsDown:", .{ frame, false });
            set(p, "addItemWithTitle:", str("Pop-up"));
            break :blk p;
        },
        .field => blk: {
            const f = newWith("NSTextField", frame);
            set(f, "setStringValue:", str("Text"));
            break :blk f;
        },
        .segmented => blk: {
            const sg = newWith("NSSegmentedControl", frame);
            set(sg, "setSegmentCount:", @as(isize, 3));
            for ([_][]const u8{ "One", "Two", "Three" }, 0..) |t, i|
                objc.call(fn (Id, Sel, Id, isize) callconv(.c) void, sg, "setLabel:forSegment:", .{ str(t), @as(isize, @intCast(i)) });
            set(sg, "setSelectedSegment:", @as(isize, if (state == .on) 1 else 0));
            break :blk sg;
        },
        .progress => blk: {
            const pr = newWith("NSProgressIndicator", frame);
            set(pr, "setIndeterminate:", false);
            set(pr, "setDoubleValue:", @as(f64, 40));
            break :blk pr;
        },
        .stepper => newWith("NSStepper", frame),
    };
    if (state == .disabled and objc.call(fn (Id, Sel, Sel) callconv(.c) bool, c, "respondsToSelector:", .{objc.sel("setEnabled:")}))
        set(c, "setEnabled:", false);
    return c;
}

fn sizeName(s: Size) []const u8 {
    return @tagName(s);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: native-ref OUTDIR\n", .{});
        std.process.exit(2);
    }
    const out_dir = args[1];
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    const pool = objc.Pool.push();
    defer pool.pop();
    const app = objc.call(fn (Class, Sel) callconv(.c) Id, cls("NSApplication"), "sharedApplication", .{});
    // NSApplicationActivationPolicyProhibited.
    set(app, "setActivationPolicy:", @as(isize, 2));
    // AppKit draws the accent only in the key window of an active app. The
    // tool is never active (it has no window on the screen), so NSApp says
    // it is, and gives the window of the tool as its key window, in this
    // process only and with no activation that takes the focus of the
    // user. The stubs of ztk link no class_replaceMethod: dlsym finds it.
    const default_handle: *anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    if (std.c.dlsym(default_handle, "class_replaceMethod")) |f| {
        const replace: ReplaceMethod = @ptrCast(@alignCast(f));
        _ = replace(cls("NSApplication"), objc.sel("isActive"), @ptrCast(&yes), "c@:");
        _ = replace(cls("NSApplication"), objc.sel("_isActiveApp"), @ptrCast(&yes), "c@:");
        _ = replace(cls("NSApplication"), objc.sel("_hasKeyFocus"), @ptrCast(&yes), "c@:");
        _ = replace(cls("NSApplication"), objc.sel("keyWindow"), @ptrCast(&currentWindow), "@@:");
        _ = replace(cls("NSApplication"), objc.sel("mainWindow"), @ptrCast(&currentWindow), "@@:");
    }

    var json: std.ArrayList(u8) = .empty;
    defer json.deinit(gpa);
    try json.appendSlice(gpa, "{\n");
    var first = true;

    const appearances = [_]struct { name: []const u8, ns: []const u8 }{
        .{ .name = "light", .ns = "NSAppearanceNameAqua" },
        .{ .name = "dark", .ns = "NSAppearanceNameDarkAqua" },
    };
    for (appearances) |ap| for ([_]bool{ true, false }) |key| {
        const appearance = objc.call(fn (Class, Sel, Id) callconv(.c) ?Id, cls("NSAppearance"), "appearanceNamed:", .{str(ap.ns)}) orelse continue;
        for (std.enums.values(Kind)) |kind| for (std.enums.values(State)) |state| {
            if (state == .default and kind != .push) continue;
            if (state == .on and (kind == .field or kind == .progress or kind == .stepper or kind == .popup)) continue;
            if (state == .disabled and kind == .progress) continue;
            for (std.enums.values(Size)) |size| {
                const inner = objc.Pool.push();
                defer inner.pop();
                // A borderless window that is never ordered front.
                const raw = objc.call(fn (Class, Sel) callconv(.c) Id, if (key) keyWindowClass() else cls("NSWindow"), "alloc", .{});
                const win = objc.call(fn (Id, Sel, NSRect, usize, usize, bool) callconv(.c) Id, raw, "initWithContentRect:styleMask:backing:defer:", .{ NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = 240, .h = 80 } }, @as(usize, 0), @as(usize, 2), false });
                set(win, "setReleasedWhenClosed:", false);
                current = if (key) win else null;
                set(win, "setAppearance:", appearance);
                const content = objc.call(fn (Id, Sel) callconv(.c) Id, win, "contentView", .{});
                const c = make(kind, state);
                if (objc.call(fn (Id, Sel, Sel) callconv(.c) bool, c, "respondsToSelector:", .{objc.sel("setControlSize:")}))
                    set(c, "setControlSize:", @as(usize, @backingInt(size)));
                objc.call(fn (Id, Sel, Id) callconv(.c) void, content, "addSubview:", .{c});
                if (kind != .slider and kind != .progress and kind != .field)
                    objc.call(fn (Id, Sel) callconv(.c) void, c, "sizeToFit", .{});
                objc.call(fn (Id, Sel) callconv(.c) void, content, "layoutSubtreeIfNeeded", .{});
                const frame = objc.callStruct(NSRect, c, "frame");
                const fitting = objc.call(fn (Id, Sel) callconv(.c) NSSize, c, "fittingSize", .{});
                const intrinsic = objc.call(fn (Id, Sel) callconv(.c) NSSize, c, "intrinsicContentSize", .{});
                const insets = objc.callStruct(NSEdgeInsets, c, "alignmentRectInsets");
                const bounds = objc.callStruct(NSRect, c, "bounds");
                const name = try std.fmt.allocPrint(gpa, "{s}-{s}-{s}-{s}{s}", .{ @tagName(kind), sizeName(size), @tagName(state), ap.name, if (key) "" else "-inactive" });
                defer gpa.free(name);
                // The render of AppKit, as a PNG of NSBitmapImageRep.
                const rep = objc.call(fn (Id, Sel, NSRect) callconv(.c) ?Id, c, "bitmapImageRepForCachingDisplayInRect:", .{bounds});
                if (rep) |r| {
                    objc.call(fn (Id, Sel, NSRect, Id) callconv(.c) void, c, "cacheDisplayInRect:toBitmapImageRep:", .{ bounds, r });
                    const dict = objc.call(fn (Class, Sel) callconv(.c) Id, cls("NSDictionary"), "dictionary", .{});
                    // NSBitmapImageFileTypePNG 4.
                    if (objc.call(fn (Id, Sel, usize, Id) callconv(.c) ?Id, r, "representationUsingType:properties:", .{ @as(usize, 4), dict })) |data| {
                        const len = objc.call(fn (Id, Sel) callconv(.c) usize, data, "length", .{});
                        const bytes = objc.call(fn (Id, Sel) callconv(.c) [*]const u8, data, "bytes", .{});
                        const file = try std.fmt.allocPrint(gpa, "{s}/{s}.png", .{ out_dir, name });
                        defer gpa.free(file);
                        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = bytes[0..len] });
                    }
                }
                const pixels_wide = if (rep) |r| objc.call(fn (Id, Sel) callconv(.c) isize, r, "pixelsWide", .{}) else 0;
                if (!first) try json.appendSlice(gpa, ",\n");
                first = false;
                try json.print(gpa, "  \"{s}\": {{\"frame\": [{d}, {d}], \"fitting\": [{d}, {d}], \"intrinsic\": [{d}, {d}], \"insets\": [{d}, {d}, {d}, {d}], \"pixels_wide\": {d}}}", .{
                    name,       frame.size.w, frame.size.h,  fitting.w,    fitting.h,   intrinsic.w, intrinsic.h,
                    insets.top, insets.left,  insets.bottom, insets.right, pixels_wide,
                });
                objc.call(fn (Id, Sel) callconv(.c) void, c, "release", .{});
                objc.call(fn (Id, Sel) callconv(.c) void, win, "release", .{});
            }
        };
    };
    try json.appendSlice(gpa, "\n}\n");
    const jpath = try std.fmt.allocPrint(gpa, "{s}/measures.json", .{out_dir});
    defer gpa.free(jpath);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = jpath, .data = json.items });
    std.debug.print("native-ref: wrote the renders and measures.json to {s}\n", .{out_dir});
}
