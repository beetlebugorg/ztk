//! Tests of the text store of the Text Services Framework. A fake sink
//! in Zig stands in for TSF: it grants the locks and runs, in each
//! lock, the calls that an input method makes. The tests call the store
//! through its COM tables, so the slots and the calling convention are
//! the ones that TSF uses. The last test makes the thread manager of
//! Windows, and prints SKIP when the session has no TSF.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const tsf = @import("../platform/tsf.zig");
const t = std.testing;

const HRESULT = com.HRESULT;
const call = com.call;

const Sink = struct {
    vt: *const [11]*const anyopaque = &table,
    store: ?*tsf.Store = null,
    script: ?*const fn (s: *anyopaque) void = null,
    text_changes: u32 = 0,
    layout_changes: u32 = 0,

    fn of(this: *anyopaque) *Sink {
        const p: *@FieldType(Sink, "vt") = @ptrCast(@alignCast(this));
        return @fieldParentPtr("vt", p);
    }
    fn query(this: *anyopaque, _: *const com.GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        out.* = this;
        return 0;
    }
    fn ref(_: *anyopaque) callconv(.winapi) u32 {
        return 1;
    }
    fn textChange(this: *anyopaque, _: u32, _: *const tsf.TS_TEXTCHANGE) callconv(.winapi) HRESULT {
        of(this).text_changes += 1;
        return 0;
    }
    fn layoutChange(this: *anyopaque, _: i32, _: u32) callconv(.winapi) HRESULT {
        of(this).layout_changes += 1;
        return 0;
    }
    fn ok() callconv(.winapi) HRESULT {
        return 0;
    }
    fn lockGranted(this: *anyopaque, _: u32) callconv(.winapi) HRESULT {
        const k = of(this);
        if (k.script) |f| f(k.store.?.unknown());
        return 0;
    }
    const table = [11]*const anyopaque{
        @ptrCast(&query),       @ptrCast(&ref), @ptrCast(&ref),
        @ptrCast(&textChange),  @ptrCast(&ok), // OnSelectionChange
        @ptrCast(&layoutChange), @ptrCast(&ok), // OnStatusChange
        @ptrCast(&ok), // OnAttrsChange
        @ptrCast(&lockGranted), @ptrCast(&ok), @ptrCast(&ok),
    };
};

const Seen = struct {
    preedit: std.ArrayListUnmanaged(u8) = .empty,
    caret: u32 = 0,
    preedits: u32 = 0,
    commit: std.ArrayListUnmanaged(u8) = .empty,
    commits: u32 = 0,

    fn onPreedit(ctx: *anyopaque, text: []const u8, caret: u32) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.preedit.clearRetainingCapacity();
        s.preedit.appendSlice(t.allocator, text) catch {};
        s.caret = caret;
        s.preedits += 1;
    }
    fn onCommit(ctx: *anyopaque, text: []const u8) void {
        const s: *Seen = @ptrCast(@alignCast(ctx));
        s.commit.clearRetainingCapacity();
        s.commit.appendSlice(t.allocator, text) catch {};
        s.commits += 1;
    }
};

const u16s = std.unicode.utf8ToUtf16LeStringLiteral;

// Slots of ITextStoreACP2 and ITfContextOwnerCompositionSink.
const advise = 3;
const request_lock = 5;
const get_selection = 8;
const get_text = 10;
const set_text = 11;
const insert_at_selection = 16;
const start_composition = 3;
const end_composition = 5;

fn startAndType(store: *anyopaque) void {
    const s: *tsf.Store = @fieldParentPtr("acp", @as(*@FieldType(tsf.Store, "acp"), @ptrCast(@alignCast(store))));
    var ok: c_int = 0;
    _ = call(HRESULT, s.compositionSink(), start_composition, .{ @as(?*anyopaque, null), &ok });
    const text = u16s("\u{306B}");
    var a: i32 = 0;
    var b: i32 = 0;
    var change: tsf.TS_TEXTCHANGE = undefined;
    _ = call(HRESULT, store, insert_at_selection, .{ @as(u32, 0), @as([*]const u16, text), @as(u32, text.len), &a, &b, &change });
}

fn convertAndEnd(store: *anyopaque) void {
    const s: *tsf.Store = @fieldParentPtr("acp", @as(*@FieldType(tsf.Store, "acp"), @ptrCast(@alignCast(store))));
    const text = u16s("\u{65E5}\u{672C}");
    var change: tsf.TS_TEXTCHANGE = undefined;
    _ = call(HRESULT, store, set_text, .{ @as(u32, 0), @as(i32, 0), @as(i32, 1), @as([*]const u16, text), @as(u32, text.len), &change });
    _ = call(HRESULT, s.compositionSink(), end_composition, .{@as(?*anyopaque, null)});
}

fn typeWithNoComposition(store: *anyopaque) void {
    const text = u16s("\u{2014}");
    var change: tsf.TS_TEXTCHANGE = undefined;
    _ = call(HRESULT, store, insert_at_selection, .{ @as(u32, 0), @as([*]const u16, text), @as(u32, text.len), @as(?*i32, null), @as(?*i32, null), &change });
}

test "tsf: a composition gives a preedit and then a commit" {
    var seen: Seen = .{};
    defer seen.preedit.deinit(t.allocator);
    defer seen.commit.deinit(t.allocator);
    const store = try tsf.Store.init(t.allocator, .{ .ctx = &seen, .preedit = Seen.onPreedit, .commit = Seen.onCommit });
    defer store.deinit();
    var sink: Sink = .{ .store = store };
    const unk = store.unknown();
    try t.expectEqual(@as(HRESULT, 0), call(HRESULT, unk, advise, .{ &tsf.IID_ITextStoreACPSink, @as(*anyopaque, @ptrCast(&sink.vt)), @as(u32, 0) }));

    // Outside a lock, a read fails.
    var buf: [8]u16 = undefined;
    var got: u32 = 0;
    var runs_got: u32 = 0;
    var next: i32 = 0;
    try t.expect(call(HRESULT, unk, get_text, .{ @as(i32, 0), @as(i32, -1), @as(?[*]u16, &buf), @as(u32, 8), &got, @as(?*anyopaque, null), @as(u32, 0), &runs_got, &next }) < 0);

    var session: HRESULT = 0;
    sink.script = startAndType;
    try t.expectEqual(@as(HRESULT, 0), call(HRESULT, unk, request_lock, .{ tsf.TS_LF_READWRITE | tsf.TS_LF_SYNC, &session }));
    try t.expectEqualStrings("\u{306B}", seen.preedit.items);
    try t.expectEqual(@as(u32, 3), seen.caret);
    try t.expectEqual(@as(u32, 0), seen.commits);

    sink.script = convertAndEnd;
    _ = call(HRESULT, unk, request_lock, .{ tsf.TS_LF_READWRITE | tsf.TS_LF_SYNC, &session });
    try t.expectEqual(@as(u32, 1), seen.commits);
    try t.expectEqualStrings("\u{65E5}\u{672C}", seen.commit.items);
    // The store emptied and told the sink.
    try t.expectEqual(@as(u32, 1), sink.text_changes);

    sink.script = typeWithNoComposition;
    _ = call(HRESULT, unk, request_lock, .{ tsf.TS_LF_READWRITE | tsf.TS_LF_SYNC, &session });
    try t.expectEqual(@as(u32, 2), seen.commits);
    try t.expectEqualStrings("\u{2014}", seen.commit.items);
}

fn readSelection(store: *anyopaque) void {
    var sel: [1]tsf.TS_SELECTION_ACP = undefined;
    var fetched: u32 = 0;
    _ = call(HRESULT, store, get_selection, .{ @as(u32, 0xffffffff), @as(u32, 1), @as([*]tsf.TS_SELECTION_ACP, &sel), &fetched });
    read_sel = sel[0];
}
var read_sel: tsf.TS_SELECTION_ACP = undefined;

test "tsf: a second lock in a session waits, and a sync one fails" {
    var seen: Seen = .{};
    defer seen.preedit.deinit(t.allocator);
    defer seen.commit.deinit(t.allocator);
    const store = try tsf.Store.init(t.allocator, .{ .ctx = &seen, .preedit = Seen.onPreedit, .commit = Seen.onCommit });
    defer store.deinit();
    var sink: Sink = .{ .store = store };
    const unk = store.unknown();
    _ = call(HRESULT, unk, advise, .{ &tsf.IID_ITextStoreACPSink, @as(*anyopaque, @ptrCast(&sink.vt)), @as(u32, 0) });
    const nested = struct {
        fn run(s: *anyopaque) void {
            calls += 1;
            // The waiting lock runs the script again, which then makes no request.
            if (calls > 1) return;
            var hr: HRESULT = 0;
            _ = call(HRESULT, s, request_lock, .{ tsf.TS_LF_READ | tsf.TS_LF_SYNC, &hr });
            sync_result = hr;
            _ = call(HRESULT, s, request_lock, .{ tsf.TS_LF_READ, &hr });
            async_result = hr;
        }
        var calls: u32 = 0;
        var sync_result: HRESULT = 0;
        var async_result: HRESULT = 0;
    };
    sink.script = nested.run;
    var session: HRESULT = 0;
    _ = call(HRESULT, unk, request_lock, .{ tsf.TS_LF_READWRITE, &session });
    try t.expect(nested.sync_result < 0);
    try t.expectEqual(@as(HRESULT, 0x00040300), nested.async_result);
    try t.expectEqual(@as(u32, 2), nested.calls);
    // The waiting lock ran after the first one, with the same script.
    sink.script = readSelection;
    _ = call(HRESULT, unk, request_lock, .{ tsf.TS_LF_READ | tsf.TS_LF_SYNC, &session });
    try t.expectEqual(@as(i32, 0), read_sel.acpStart);
}

test "tsf: the thread manager of Windows activates and accepts a store" {
    if (!(t.environ.contains(t.allocator, "ZTK_TEST_WINDOWS") catch false)) {
        std.debug.print("SKIP: set ZTK_TEST_WINDOWS=1 to run the TSF test\n", .{});
        return;
    }
    var mgr = tsf.Tsf.init() catch |e| {
        std.debug.print("SKIP: no TSF in this session ({s})\n", .{@errorName(e)});
        return;
    };
    defer mgr.deinit();
    var seen: Seen = .{};
    defer seen.preedit.deinit(t.allocator);
    defer seen.commit.deinit(t.allocator);
    const store = try tsf.Store.init(t.allocator, .{ .ctx = &seen, .preedit = Seen.onPreedit, .commit = Seen.onCommit });
    defer store.deinit();
    try mgr.attach(store);
    // TSF gave the store its sink when the context took the store.
    try t.expect(store.sink != null);
    try t.expect(store.doc != null);
    mgr.detach(store);
    try t.expect(store.doc == null);
}
