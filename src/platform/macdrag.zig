//! A drag of files or text out of a window of macOS to other apps
//! (`ztk::dnd drag`, ztk#62): an `NSDraggingSession` of the view, with
//! the source of this file.
//!
//! `run` makes one `NSDraggingItem` for each file (an `NSURL` of the
//! file, which Finder takes) and one for the text (an `NSString`), and
//! begins the session with the current mouse event, which a binding of
//! `<B1-Motion>` has. A session of AppKit runs in the event loop after
//! the call, so `run` turns the loop itself until the source hears the
//! end (`draggingSession:endedAtPoint:operation:`), and gives the action
//! of the target, as `dragStart` asks. The source offers a copy, and a
//! move too with `allow_move`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const plat = @import("platform.zig");
const Id = objc.Id;
const Sel = objc.Sel;
const Class = objc.Class;

/// NSDragOperationCopy and NSDragOperationMove.
const op_copy: usize = 1;
const op_move: usize = 16;

const NSPoint = extern struct { x: f64, y: f64 };
const NSSize = extern struct { w: f64, h: f64 };
const NSRect = extern struct { origin: NSPoint, size: NSSize };

fn call(comptime Fn: type, target: anytype, selector: [*:0]const u8, args: anytype) @typeInfo(Fn).@"fn".return_type.? {
    return objc.call(Fn, target, selector, args);
}

fn temp(text: []const u8) Id {
    return call(fn (Id, Sel) callconv(.c) Id, objc.nsString(text), "autorelease", .{});
}

/// The state of a drag that the source updates.
const Session = struct {
    allow_move: bool,
    ended: bool = false,
    op: usize = 0,
};

fn onMask(src: Id, _: Sel, _: Id, _: isize) callconv(.c) usize {
    const s: *Session = @ptrCast(@alignCast(objc.getData(src) orelse return op_copy));
    return if (s.allow_move) op_copy | op_move else op_copy;
}

fn onEnded(src: Id, _: Sel, _: Id, _: NSPoint, op: usize) callconv(.c) void {
    const s: *Session = @ptrCast(@alignCast(objc.getData(src) orelse return));
    s.op = op;
    s.ended = true;
}

fn sourceClass() Class {
    if (objc.class("ZtkDragSource")) |c| return c;
    const b = objc.ClassBuilder.begin("NSObject", "ZtkDragSource").?;
    _ = b.protocol("NSDraggingSource");
    b.method("draggingSession:sourceOperationMaskForDraggingContext:", @ptrCast(&onMask), "Q@:@q");
    b.method("draggingSession:endedAtPoint:operation:", @ptrCast(&onEnded), "v@:@{CGPoint=dd}Q");
    return b.finish();
}

/// The pasteboard writers of a drag: an `NSURL` for each file, then an
/// `NSString` for the text. Autoreleased objects of the current pool.
pub fn writers(d: plat.DragData, out: *std.ArrayList(Id), gpa: std.mem.Allocator) !void {
    const url_class = objc.class("NSURL").?;
    for (d.files) |f| try out.append(gpa, call(fn (Class, Sel, Id) callconv(.c) Id, url_class, "fileURLWithPath:", .{temp(f)}));
    if (d.text.len > 0) try out.append(gpa, temp(d.text));
}

/// The action of an operation of the target.
pub fn actionOf(op: usize) plat.DragAction {
    if (op & op_move != 0) return .move;
    if (op & op_copy != 0) return .copy;
    return .none;
}

/// Runs the drag from `view` to its end. `app` is `NSApp`.
pub fn run(gpa: std.mem.Allocator, app: Id, view: Id, d: plat.DragData) plat.DragAction {
    const pool = objc.Pool.push();
    defer pool.pop();
    const ev = call(fn (Id, Sel) callconv(.c) ?Id, app, "currentEvent", .{}) orelse return .none;
    var list: std.ArrayList(Id) = .empty;
    defer list.deinit(gpa);
    writers(d, &list, gpa) catch return .none;
    if (list.items.len == 0) return .none;
    // Each item starts at the pointer, in the coordinates of the view.
    const in_window = call(fn (Id, Sel) callconv(.c) NSPoint, ev, "locationInWindow", .{});
    const at = call(fn (Id, Sel, NSPoint, ?Id) callconv(.c) NSPoint, view, "convertPoint:fromView:", .{ in_window, null });
    const items = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSMutableArray").?, "array", .{});
    const item_class = objc.class("NSDraggingItem").?;
    const ws = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSWorkspace").?, "sharedWorkspace", .{});
    for (list.items, 0..) |w, i| {
        const raw = call(fn (Class, Sel) callconv(.c) Id, item_class, "alloc", .{});
        const item = call(fn (Id, Sel, Id) callconv(.c) Id, raw, "initWithPasteboardWriter:", .{w});
        _ = call(fn (Id, Sel) callconv(.c) Id, item, "autorelease", .{});
        // The image of a file is its icon; the text has a small frame.
        const icon: ?Id = if (i < d.files.len) call(fn (Id, Sel, Id) callconv(.c) ?Id, ws, "iconForFile:", .{temp(d.files[i])}) else null;
        const off: f64 = @floatFromInt(i * 4);
        const frame: NSRect = .{ .origin = .{ .x = at.x - 16 + off, .y = at.y - 16 + off }, .size = .{ .w = 32, .h = 32 } };
        call(fn (Id, Sel, NSRect, ?Id) callconv(.c) void, item, "setDraggingFrame:contents:", .{ frame, icon });
        call(fn (Id, Sel, Id) callconv(.c) void, items, "addObject:", .{item});
    }
    var session: Session = .{ .allow_move = d.allow_move };
    const src = objc.new(sourceClass());
    defer objc.release(src);
    objc.setData(src, &session);
    _ = call(fn (Id, Sel, Id, Id, Id) callconv(.c) ?Id, view, "beginDraggingSessionWithItems:event:source:", .{ items, ev, src }) orelse return .none;
    // The session runs in the event loop: turn it until the end.
    const mode = temp("kCFRunLoopDefaultMode");
    const distant = call(fn (Class, Sel) callconv(.c) Id, objc.class("NSDate").?, "distantFuture", .{});
    while (!session.ended) {
        const inner = objc.Pool.push();
        defer inner.pop();
        const next = call(fn (Id, Sel, u64, Id, Id, bool) callconv(.c) ?Id, app, "nextEventMatchingMask:untilDate:inMode:dequeue:", .{ std.math.maxInt(u64), distant, mode, true }) orelse continue;
        call(fn (Id, Sel, Id) callconv(.c) void, app, "sendEvent:", .{next});
    }
    objc.setData(src, null);
    return actionOf(session.op);
}

const t = std.testing;

test "macdrag: the writers of files and text, and the actions" {
    const pool = objc.Pool.push();
    defer pool.pop();
    var list: std.ArrayList(Id) = .empty;
    defer list.deinit(t.allocator);
    try writers(.{ .files = &.{ "/tmp/a b.txt", "/etc/hosts" }, .text = "hello" }, &list, t.allocator);
    try t.expectEqual(@as(usize, 3), list.items.len);
    const url0 = call(fn (Id, Sel) callconv(.c) Id, list.items[0], "path", .{});
    try t.expectEqualStrings("/tmp/a b.txt", objc.utf8(url0));
    try t.expect(call(fn (Id, Sel) callconv(.c) bool, list.items[1], "isFileURL", .{}));
    try t.expectEqualStrings("hello", objc.utf8(list.items[2]));
    try t.expectEqual(plat.DragAction.none, actionOf(0));
    try t.expectEqual(plat.DragAction.copy, actionOf(op_copy));
    try t.expectEqual(plat.DragAction.move, actionOf(op_copy | op_move));
}
