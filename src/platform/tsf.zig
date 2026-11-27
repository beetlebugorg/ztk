//! Input methods with the Text Services Framework (TSF). `Tsf` makes the
//! thread manager of the UI thread and activates it. Each window has a
//! `Store`: a COM object in Zig with two interfaces, `ITextStoreACP2` and
//! `ITfContextOwnerCompositionSink`, in one document manager with one
//! context. `focus` gives the document manager to the window with
//! `AssociateFocus`, or removes it.
//!
//! The store has the text of the current composition only, in UTF-16,
//! and a selection. An input method reads and writes it in edit sessions
//! that `RequestLock` grants at once through the sink of TSF, or after
//! the current session ends. After each session, the store gives its
//! owner a `preedit` with the text and the caret while a composition
//! runs. When the composition ends, or when text arrives with no
//! composition, the store gives a `commit` with the text, empties, and
//! tells the sink of the change. The caret rectangle of `GetTextExt` is
//! the rectangle of the last `focus`, in screen pixels, so the candidate
//! window shows next to the widget.
//!
//! The slots, the interface IDs, and the structures follow the C forms
//! in `textstor.h` and `msctf.h` of the Windows SDK 10.0.26100.0.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const com = @import("../sys/com.zig");
const w32 = @import("win32.zig");
const geom = @import("../base/geom.zig");

const HRESULT = com.HRESULT;
const GUID = com.GUID;
const call = com.call;

const S_OK: HRESULT = 0;
const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));
const CONNECT_E_ADVISELIMIT: HRESULT = @bitCast(@as(u32, 0x80040201));
const TS_E_NOLOCK: HRESULT = @bitCast(@as(u32, 0x80040201));
const TS_E_INVALIDPOS: HRESULT = @bitCast(@as(u32, 0x80040200));
const TS_E_SYNCHRONOUS: HRESULT = @bitCast(@as(u32, 0x80040208));
const TS_S_ASYNC: HRESULT = 0x00040300;

pub const TS_LF_SYNC: u32 = 0x1;
pub const TS_LF_READ: u32 = 0x2;
pub const TS_LF_READWRITE: u32 = 0x6;
const TS_SS_NOHIDDENTEXT: u32 = 0x8;
const TS_DEFAULT_SELECTION: u32 = 0xffffffff;
const TS_AE_END: i32 = 2;
const TS_RT_PLAIN: i32 = 0;
const TS_LC_CHANGE: i32 = 1;
const TF_IAS_QUERYONLY: u32 = 0x1;
const TF_POPF_ALL: u32 = 0x1;
const view_cookie: u32 = 1;

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
pub const IID_ITextStoreACP2 = GUID.parse("f86ad89f-5fe4-4b8d-bb9f-ef3797a84f1f");
pub const IID_ITextStoreACPSink = GUID.parse("22d44c94-a419-4542-a272-ae26093ececf");
pub const IID_ITfContextOwnerCompositionSink = GUID.parse("5f20aa40-b57a-4f34-96ab-3576f377cc79");
const IID_ITfThreadMgr = GUID.parse("aa80e801-2021-11d2-93e0-0060b067b86e");
const CLSID_TF_ThreadMgr = GUID.parse("529a9e6b-6587-4f23-ab9e-9c7d683e3c50");

pub const TS_SELECTION_ACP = extern struct { acpStart: i32, acpEnd: i32, ase: i32 = TS_AE_END, fInterimChar: w32.BOOL = 0 };
pub const TS_TEXTCHANGE = extern struct { acpStart: i32, acpOldEnd: i32, acpNewEnd: i32 };
pub const TS_STATUS = extern struct { dwDynamicFlags: u32, dwStaticFlags: u32 };
pub const TS_RUNINFO = extern struct { uCount: u32, type: i32 };

// The slots of the methods that ztk calls.
const slot = struct {
    const unknown_query = 0;
    const unknown_release = 2;
    const sink_text_change = 3;
    const sink_selection_change = 4;
    const sink_layout_change = 5;
    const sink_lock_granted = 8;
    const mgr_activate = 3;
    const mgr_deactivate = 4;
    const mgr_create_document = 5;
    const mgr_associate_focus = 9;
    const doc_create_context = 3;
    const doc_push = 4;
    const doc_pop = 5;
};

extern "ole32" fn CoInitializeEx(reserved: ?*anyopaque, flags: u32) callconv(.winapi) HRESULT;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(clsid: *const GUID, outer: ?*anyopaque, ctx: u32, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

/// What the store tells its owner: the composition text and the committed text, in UTF-8.
pub const Owner = struct {
    ctx: *anyopaque,
    preedit: *const fn (ctx: *anyopaque, text: []const u8, caret: u32) void,
    commit: *const fn (ctx: *anyopaque, text: []const u8) void,
};

pub const Store = struct {
    /// The interface pointers. COM gives a method the address of one of them.
    acp: *const [28]*const anyopaque = &acp_table,
    comp: *const [6]*const anyopaque = &comp_table,
    refs: u32 = 1,
    gpa: std.mem.Allocator,
    owner: Owner,
    hwnd: ?w32.HWND = null,
    /// The scale of the window and the rectangle of the text widget, in logical pixels.
    scale: f32 = 1,
    rect: geom.Rect = .{},
    sink: ?*anyopaque = null,
    /// The flags of the lock that runs, and of a lock that waits for it.
    lock: u32 = 0,
    pending: u32 = 0,
    text: std.ArrayListUnmanaged(u16) = .empty,
    sel_start: i32 = 0,
    sel_end: i32 = 0,
    composing: bool = false,
    ended: bool = false,
    /// True when the last preedit had text, so an end with no commit clears it.
    shown: bool = false,
    // TSF objects of the window.
    doc: ?*anyopaque = null,
    context: ?*anyopaque = null,

    pub fn init(gpa: std.mem.Allocator, owner: Owner) !*Store {
        const s = try gpa.create(Store);
        s.* = .{ .gpa = gpa, .owner = owner };
        return s;
    }

    pub fn deinit(s: *Store) void {
        if (s.sink) |k| com.release(k);
        s.text.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    /// The `IUnknown` pointer of the store.
    pub fn unknown(s: *Store) *anyopaque {
        return @ptrCast(&s.acp);
    }

    /// The pointer of the composition sink interface.
    pub fn compositionSink(s: *Store) *anyopaque {
        return @ptrCast(&s.comp);
    }

    fn fromAcp(this: *anyopaque) *Store {
        const p: *@FieldType(Store, "acp") = @ptrCast(@alignCast(this));
        return @fieldParentPtr("acp", p);
    }

    fn fromComp(this: *anyopaque) *Store {
        const p: *@FieldType(Store, "comp") = @ptrCast(@alignCast(this));
        return @fieldParentPtr("comp", p);
    }

    fn len(s: *const Store) i32 {
        return @intCast(s.text.items.len);
    }

    /// Replaces the text from `start` to `end` with `with`.
    fn replace(s: *Store, start: i32, end: i32, with: []const u16) !void {
        const a: usize = @intCast(start);
        const b: usize = @intCast(end);
        try s.text.replaceRange(s.gpa, a, b - a, with);
    }

    /// The text in UTF-8 and the byte offset of a position in it.
    fn utf8(s: *Store, upto: i32) !struct { text: []u8, at: u32 } {
        const text = try std.unicode.utf16LeToUtf8Alloc(s.gpa, s.text.items);
        const head = try std.unicode.utf16LeToUtf8Alloc(s.gpa, s.text.items[0..@intCast(std.math.clamp(upto, 0, s.len()))]);
        defer s.gpa.free(head);
        return .{ .text = text, .at = @intCast(head.len) };
    }

    /// The work after an edit session: a preedit while a composition runs,
    /// and a commit at its end or for text with no composition.
    fn afterLock(s: *Store) void {
        if (s.ended or (!s.composing and s.text.items.len > 0)) {
            s.ended = false;
            const old = s.len();
            if (old > 0) {
                if (s.utf8(old)) |u| {
                    defer s.gpa.free(u.text);
                    s.owner.commit(s.owner.ctx, u.text);
                } else |_| {}
            } else if (s.shown) s.owner.preedit(s.owner.ctx, "", 0);
            s.shown = false;
            s.text.clearRetainingCapacity();
            s.sel_start = 0;
            s.sel_end = 0;
            // The sink hears of a change that it did not make.
            if (s.sink) |k| if (old > 0) {
                const change: TS_TEXTCHANGE = .{ .acpStart = 0, .acpOldEnd = old, .acpNewEnd = 0 };
                _ = call(HRESULT, k, slot.sink_text_change, .{ @as(u32, 0), &change });
                _ = call(HRESULT, k, slot.sink_selection_change, .{});
            };
            return;
        }
        if (s.composing) {
            const u = s.utf8(s.sel_end) catch return;
            defer s.gpa.free(u.text);
            s.owner.preedit(s.owner.ctx, u.text, u.at);
            s.shown = u.text.len > 0;
        }
    }

    /// Sets the rectangle of the text widget and tells the sink that the layout changed.
    pub fn setRect(s: *Store, hwnd: w32.HWND, scale: f32, rect: geom.Rect) void {
        const same = s.hwnd == hwnd and s.scale == scale and std.meta.eql(s.rect, rect);
        s.hwnd = hwnd;
        s.scale = scale;
        s.rect = rect;
        if (!same) if (s.sink) |k| {
            _ = call(HRESULT, k, slot.sink_layout_change, .{ TS_LC_CHANGE, view_cookie });
        };
    }

    fn screenRect(s: *const Store, r: geom.Rect) w32.RECT {
        var p: w32.POINT = .{
            .x = @intFromFloat(@round(@as(f32, @floatFromInt(r.x)) * s.scale)),
            .y = @intFromFloat(@round(@as(f32, @floatFromInt(r.y)) * s.scale)),
        };
        if (s.hwnd) |h| _ = w32.ClientToScreen(h, &p);
        return .{
            .left = p.x,
            .top = p.y,
            .right = p.x + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(r.w)) * s.scale))),
            .bottom = p.y + @as(i32, @intFromFloat(@round(@as(f32, @floatFromInt(r.h)) * s.scale))),
        };
    }

    // ---- IUnknown, for both interfaces ----

    fn query(s: *Store, iid: *const GUID, out: *?*anyopaque) HRESULT {
        if (std.meta.eql(iid.*, IID_IUnknown) or std.meta.eql(iid.*, IID_ITextStoreACP2)) {
            out.* = s.unknown();
        } else if (std.meta.eql(iid.*, IID_ITfContextOwnerCompositionSink)) {
            out.* = s.compositionSink();
        } else {
            out.* = null;
            return E_NOINTERFACE;
        }
        s.refs += 1;
        return S_OK;
    }

    fn acpQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        return fromAcp(this).query(iid, out);
    }
    fn acpAddRef(this: *anyopaque) callconv(.winapi) u32 {
        const s = fromAcp(this);
        s.refs += 1;
        return s.refs;
    }
    // The owner frees the store, so Release leaves it in memory at a count of 0.
    fn acpRelease(this: *anyopaque) callconv(.winapi) u32 {
        const s = fromAcp(this);
        if (s.refs > 0) s.refs -= 1;
        return s.refs;
    }
    fn compQuery(this: *anyopaque, iid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT {
        return fromComp(this).query(iid, out);
    }
    fn compAddRef(this: *anyopaque) callconv(.winapi) u32 {
        return acpAddRef(fromComp(this).unknown());
    }
    fn compRelease(this: *anyopaque) callconv(.winapi) u32 {
        return acpRelease(fromComp(this).unknown());
    }

    // ---- ITextStoreACP2 ----

    fn adviseSink(this: *anyopaque, iid: *const GUID, punk: ?*anyopaque, _: u32) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (!std.meta.eql(iid.*, IID_ITextStoreACPSink)) return E_INVALIDARG;
        const p = punk orelse return E_INVALIDARG;
        if (s.sink != null) return CONNECT_E_ADVISELIMIT;
        var sink: ?*anyopaque = null;
        if (call(HRESULT, p, slot.unknown_query, .{ &IID_ITextStoreACPSink, &sink }) < 0) return E_NOINTERFACE;
        s.sink = sink;
        return S_OK;
    }

    fn unadviseSink(this: *anyopaque, _: ?*anyopaque) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.sink) |k| com.release(k);
        s.sink = null;
        return S_OK;
    }

    fn requestLock(this: *anyopaque, flags: u32, session: *HRESULT) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        const sink = s.sink orelse return E_INVALIDARG;
        if (s.lock != 0) {
            if (flags & TS_LF_SYNC != 0) {
                session.* = TS_E_SYNCHRONOUS;
                return S_OK;
            }
            s.pending = flags;
            session.* = TS_S_ASYNC;
            return S_OK;
        }
        s.lock = flags & TS_LF_READWRITE;
        session.* = call(HRESULT, sink, slot.sink_lock_granted, .{s.lock});
        s.lock = 0;
        // A lock that the session asked for runs now. A session that asks
        // again each time stops after 16 runs, so the UI thread goes on.
        var runs: u32 = 0;
        while (s.pending != 0 and runs < 16) : (runs += 1) {
            const next = s.pending;
            s.pending = 0;
            s.lock = next & TS_LF_READWRITE;
            _ = call(HRESULT, sink, slot.sink_lock_granted, .{s.lock});
            s.lock = 0;
        }
        s.afterLock();
        return S_OK;
    }

    fn getStatus(_: *anyopaque, status: *TS_STATUS) callconv(.winapi) HRESULT {
        status.* = .{ .dwDynamicFlags = 0, .dwStaticFlags = TS_SS_NOHIDDENTEXT };
        return S_OK;
    }

    fn queryInsert(this: *anyopaque, start: i32, end: i32, _: u32, rs: *i32, re: *i32) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (start < 0 or start > end or end > s.len()) return E_INVALIDARG;
        rs.* = start;
        re.* = end;
        return S_OK;
    }

    fn getSelection(this: *anyopaque, index: u32, count: u32, sel: [*]TS_SELECTION_ACP, fetched: *u32) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock == 0) return TS_E_NOLOCK;
        if (index != 0 and index != TS_DEFAULT_SELECTION) return E_INVALIDARG;
        fetched.* = 0;
        if (count == 0) return S_OK;
        sel[0] = .{ .acpStart = s.sel_start, .acpEnd = s.sel_end };
        fetched.* = 1;
        return S_OK;
    }

    fn setSelection(this: *anyopaque, count: u32, sel: [*]const TS_SELECTION_ACP) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock & TS_LF_READWRITE != TS_LF_READWRITE) return TS_E_NOLOCK;
        if (count == 0) return E_INVALIDARG;
        const a = sel[0].acpStart;
        const b = sel[0].acpEnd;
        if (a < 0 or a > b or b > s.len()) return TS_E_INVALIDPOS;
        s.sel_start = a;
        s.sel_end = b;
        return S_OK;
    }

    fn getText(this: *anyopaque, start: i32, end_in: i32, plain: ?[*]u16, want: u32, got: *u32, runs: ?[*]TS_RUNINFO, runs_want: u32, runs_got: *u32, next: *i32) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock == 0) return TS_E_NOLOCK;
        const end = if (end_in == -1) s.len() else end_in;
        if (start < 0 or start > end or end > s.len()) return TS_E_INVALIDPOS;
        var n: u32 = @intCast(end - start);
        if (plain) |p| {
            n = @min(n, want);
            @memcpy(p[0..n], s.text.items[@intCast(start)..][0..n]);
        } else n = 0;
        got.* = n;
        runs_got.* = 0;
        if (runs_want > 0) if (runs) |r| {
            r[0] = .{ .uCount = n, .type = TS_RT_PLAIN };
            runs_got.* = 1;
        };
        next.* = start + @as(i32, @intCast(n));
        return S_OK;
    }

    fn setText(this: *anyopaque, _: u32, start: i32, end: i32, chars: ?[*]const u16, count: u32, change: *TS_TEXTCHANGE) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock & TS_LF_READWRITE != TS_LF_READWRITE) return TS_E_NOLOCK;
        if (start < 0 or start > end or end > s.len()) return TS_E_INVALIDPOS;
        const with: []const u16 = if (chars) |c| c[0..count] else &.{};
        s.replace(start, end, with) catch return E_INVALIDARG;
        const new_end = start + @as(i32, @intCast(count));
        change.* = .{ .acpStart = start, .acpOldEnd = end, .acpNewEnd = new_end };
        s.sel_start = new_end;
        s.sel_end = new_end;
        return S_OK;
    }

    // A method with fewer parameters than its slot is safe on x64 and ARM64,
    // where the caller removes the arguments.
    fn notImpl() callconv(.winapi) HRESULT {
        return E_NOTIMPL;
    }

    fn queryInsertEmbedded(_: *anyopaque, _: ?*const GUID, _: ?*const anyopaque, ok: *w32.BOOL) callconv(.winapi) HRESULT {
        ok.* = 0;
        return S_OK;
    }

    fn insertTextAtSelection(this: *anyopaque, flags: u32, chars: ?[*]const u16, count: u32, ps: ?*i32, pe: ?*i32, change: ?*TS_TEXTCHANGE) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock & TS_LF_READWRITE != TS_LF_READWRITE) return TS_E_NOLOCK;
        const a = s.sel_start;
        const b = s.sel_end;
        if (flags & TF_IAS_QUERYONLY != 0) {
            if (ps) |p| p.* = a;
            if (pe) |p| p.* = b;
            return S_OK;
        }
        const with: []const u16 = if (chars) |c| c[0..count] else &.{};
        s.replace(a, b, with) catch return E_INVALIDARG;
        const new_end = a + @as(i32, @intCast(count));
        if (ps) |p| p.* = a;
        if (pe) |p| p.* = new_end;
        if (change) |c| c.* = .{ .acpStart = a, .acpOldEnd = b, .acpNewEnd = new_end };
        s.sel_start = new_end;
        s.sel_end = new_end;
        return S_OK;
    }

    fn okNoAttrs() callconv(.winapi) HRESULT {
        return S_OK;
    }

    fn findNextAttrTransition(_: *anyopaque, _: i32, halt: i32, _: u32, _: ?*const anyopaque, _: u32, next: *i32, found: *w32.BOOL, offset: *i32) callconv(.winapi) HRESULT {
        next.* = halt;
        found.* = 0;
        offset.* = 0;
        return S_OK;
    }

    fn retrieveRequestedAttrs(_: *anyopaque, _: u32, _: ?*anyopaque, fetched: *u32) callconv(.winapi) HRESULT {
        fetched.* = 0;
        return S_OK;
    }

    fn getEndAcp(this: *anyopaque, acp: *i32) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        if (s.lock == 0) return TS_E_NOLOCK;
        acp.* = s.len();
        return S_OK;
    }

    fn getActiveView(_: *anyopaque, view: *u32) callconv(.winapi) HRESULT {
        view.* = view_cookie;
        return S_OK;
    }

    fn getTextExt(this: *anyopaque, _: u32, _: i32, _: i32, rc: *w32.RECT, clipped: *w32.BOOL) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        rc.* = s.screenRect(s.rect);
        clipped.* = 0;
        return S_OK;
    }

    fn getScreenExt(this: *anyopaque, _: u32, rc: *w32.RECT) callconv(.winapi) HRESULT {
        const s = fromAcp(this);
        var client: w32.RECT = .{};
        if (s.hwnd) |h| _ = w32.GetClientRect(h, &client);
        var p: w32.POINT = .{};
        if (s.hwnd) |h| _ = w32.ClientToScreen(h, &p);
        rc.* = .{ .left = p.x, .top = p.y, .right = p.x + client.right, .bottom = p.y + client.bottom };
        return S_OK;
    }

    // ---- ITfContextOwnerCompositionSink ----

    fn onStartComposition(this: *anyopaque, _: ?*anyopaque, ok: *w32.BOOL) callconv(.winapi) HRESULT {
        fromComp(this).composing = true;
        ok.* = 1;
        return S_OK;
    }

    fn onUpdateComposition(_: *anyopaque, _: ?*anyopaque, _: ?*anyopaque) callconv(.winapi) HRESULT {
        return S_OK;
    }

    fn onEndComposition(this: *anyopaque, _: ?*anyopaque) callconv(.winapi) HRESULT {
        const s = fromComp(this);
        s.composing = false;
        s.ended = true;
        return S_OK;
    }

    const acp_table = [28]*const anyopaque{
        @ptrCast(&acpQuery),               @ptrCast(&acpAddRef),              @ptrCast(&acpRelease),
        @ptrCast(&adviseSink),             @ptrCast(&unadviseSink),           @ptrCast(&requestLock),
        @ptrCast(&getStatus),              @ptrCast(&queryInsert),            @ptrCast(&getSelection),
        @ptrCast(&setSelection),           @ptrCast(&getText),                @ptrCast(&setText),
        @ptrCast(&notImpl), // GetFormattedText
        @ptrCast(&notImpl), // GetEmbedded
        @ptrCast(&queryInsertEmbedded),
        @ptrCast(&notImpl), // InsertEmbedded
        @ptrCast(&insertTextAtSelection),
        @ptrCast(&notImpl), // InsertEmbeddedAtSelection
        @ptrCast(&okNoAttrs), // RequestSupportedAttrs
        @ptrCast(&okNoAttrs), // RequestAttrsAtPosition
        @ptrCast(&okNoAttrs), // RequestAttrsTransitioningAtPosition
        @ptrCast(&findNextAttrTransition), @ptrCast(&retrieveRequestedAttrs), @ptrCast(&getEndAcp),
        @ptrCast(&getActiveView),
        @ptrCast(&notImpl), // GetACPFromPoint
        @ptrCast(&getTextExt),             @ptrCast(&getScreenExt),
    };

    const comp_table = [6]*const anyopaque{
        @ptrCast(&compQuery),          @ptrCast(&compAddRef),          @ptrCast(&compRelease),
        @ptrCast(&onStartComposition), @ptrCast(&onUpdateComposition), @ptrCast(&onEndComposition),
    };
};

/// The thread manager of the UI thread.
pub const Tsf = struct {
    mgr: *anyopaque,
    client: u32,

    /// Starts COM for the thread and activates TSF. A machine or a
    /// session with no TSF gives an error, and the backend has no input
    /// method then.
    pub fn init() !Tsf {
        // S_FALSE (1) means COM was on for the thread already.
        if (CoInitializeEx(null, 0x2) < 0) return error.NoCom;
        errdefer CoUninitialize();
        var mgr: ?*anyopaque = null;
        try com.check(CoCreateInstance(&CLSID_TF_ThreadMgr, null, 0x1, &IID_ITfThreadMgr, &mgr));
        errdefer com.release(mgr.?);
        var client: u32 = 0;
        try com.check(call(HRESULT, mgr.?, slot.mgr_activate, .{&client}));
        return .{ .mgr = mgr.?, .client = client };
    }

    pub fn deinit(t: *Tsf) void {
        _ = call(HRESULT, t.mgr, slot.mgr_deactivate, .{});
        com.release(t.mgr);
        CoUninitialize();
    }

    /// Gives a store its document manager and context.
    pub fn attach(t: *Tsf, s: *Store) !void {
        var doc: ?*anyopaque = null;
        try com.check(call(HRESULT, t.mgr, slot.mgr_create_document, .{&doc}));
        errdefer com.release(doc.?);
        var context: ?*anyopaque = null;
        var cookie: u32 = 0;
        try com.check(call(HRESULT, doc.?, slot.doc_create_context, .{ t.client, @as(u32, 0), s.unknown(), &context, &cookie }));
        errdefer com.release(context.?);
        try com.check(call(HRESULT, doc.?, slot.doc_push, .{context.?}));
        s.doc = doc;
        s.context = context;
    }

    /// Pops the context of a store and frees its TSF objects. Turn its focus off first.
    pub fn detach(_: *Tsf, s: *Store) void {
        if (s.doc) |d| {
            _ = call(HRESULT, d, slot.doc_pop, .{TF_POPF_ALL});
            com.release(d);
        }
        if (s.context) |c| com.release(c);
        s.doc = null;
        s.context = null;
    }

    /// Gives the document manager of the store to the window, or none.
    pub fn focus(t: *Tsf, s: *Store, hwnd: w32.HWND, on: bool) void {
        var prev: ?*anyopaque = null;
        const doc: ?*anyopaque = if (on) s.doc else null;
        _ = call(HRESULT, t.mgr, slot.mgr_associate_focus, .{ hwnd, doc, &prev });
        if (prev) |p| com.release(p);
    }
};

test "tsf: the structures have the sizes of the C headers" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TS_SELECTION_ACP));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TS_TEXTCHANGE));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(TS_STATUS));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(TS_RUNINFO));
}
