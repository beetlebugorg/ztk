//! A client of the D-Bus wire protocol on a Unix socket, with no library.
//! It connects to the session bus of DBUS_SESSION_BUS_ADDRESS (`unix:path=`
//! or `unix:abstract=`), authenticates with EXTERNAL and the user id, and
//! sends `Hello`. `call` sends a method call and reads messages until its
//! reply. The signals that arrive in the meantime go to a list, and
//! `waitSignal` reads that list and then the socket. Each message is little
//! endian, and a big-endian message from the bus gives `error.BadMessage`.
//! The code follows the D-Bus specification (docs/references/dbus.md):
//! the marshaling of each type, the header fields, and the SASL lines.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ ConnectFailed, AuthFailed, Disconnected, BadMessage, Timeout, CallFailed, OutOfMemory };

pub const MsgType = enum(u8) { invalid = 0, method_call = 1, method_return = 2, @"error" = 3, signal = 4, _ };

/// The header field codes.
const F = struct {
    const path = 1;
    const interface = 2;
    const member = 3;
    const error_name = 4;
    const reply_serial = 5;
    const destination = 6;
    const sender = 7;
    const signature = 8;
};

fn isErr(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

// ---- Marshaling ----

/// Writes the values of a body or a header. Each value is aligned to its
/// size from the start of the buffer, and a message body starts at a
/// multiple of 8, so the alignment is the same as in the message.
pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    /// Set after an allocation failure. `bytes` then gives `error.OutOfMemory`.
    failed: bool = false,

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.gpa);
    }

    pub fn bytes(w: *const Writer) Error![]const u8 {
        if (w.failed) return error.OutOfMemory;
        return w.buf.items;
    }

    pub fn alignTo(w: *Writer, n: usize) void {
        while (w.buf.items.len % n != 0) w.raw(&.{0});
    }

    pub fn raw(w: *Writer, b: []const u8) void {
        w.buf.appendSlice(w.gpa, b) catch {
            w.failed = true;
        };
    }

    pub fn byte(w: *Writer, v: u8) void {
        w.raw(&.{v});
    }

    pub fn uint(w: *Writer, v: u32) void {
        w.alignTo(4);
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        w.raw(&b);
    }

    pub fn boolean(w: *Writer, v: bool) void {
        w.uint(@intFromBool(v));
    }

    /// A string or an object path: the length, the bytes, and a 0.
    pub fn string(w: *Writer, s: []const u8) void {
        w.uint(@intCast(s.len));
        w.raw(s);
        w.raw(&.{0});
    }

    /// A signature: a one-byte length, the bytes, and a 0.
    pub fn signature(w: *Writer, s: []const u8) void {
        w.byte(@intCast(s.len));
        w.raw(s);
        w.raw(&.{0});
    }

    /// Starts an array of elements with the alignment `elem_align`. Give
    /// the result to `endArray`. The length leaves out the padding before
    /// the first element.
    pub fn beginArray(w: *Writer, elem_align: usize) [2]usize {
        w.uint(0);
        const at = w.buf.items.len - 4;
        w.alignTo(elem_align);
        return .{ at, w.buf.items.len };
    }

    pub fn endArray(w: *Writer, a: [2]usize) void {
        if (w.failed) return;
        std.mem.writeInt(u32, w.buf.items[a[0]..][0..4], @intCast(w.buf.items.len - a[1]), .little);
    }

    /// A struct or a dict entry starts at a multiple of 8.
    pub fn beginStruct(w: *Writer) void {
        w.alignTo(8);
    }

    /// A variant: its signature. The value follows.
    pub fn variant(w: *Writer, sig: []const u8) void {
        w.signature(sig);
    }

    /// An array of bytes with a 0 at the end, as the portals give paths (`ay`).
    pub fn byteString(w: *Writer, s: []const u8) void {
        const a = w.beginArray(1);
        w.raw(s);
        w.raw(&.{0});
        w.endArray(a);
    }

    /// One entry `{sv}` of a dictionary, with a string value.
    pub fn dictString(w: *Writer, key: []const u8, v: []const u8) void {
        w.beginStruct();
        w.string(key);
        w.variant("s");
        w.string(v);
    }

    pub fn dictBool(w: *Writer, key: []const u8, v: bool) void {
        w.beginStruct();
        w.string(key);
        w.variant("b");
        w.boolean(v);
    }
};

/// Reads the values of a body. A value past the end gives `error.BadMessage`.
pub const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn alignTo(r: *Reader, n: usize) Error!void {
        const p = std.mem.alignForward(usize, r.pos, n);
        if (p > r.data.len) return error.BadMessage;
        r.pos = p;
    }

    fn take(r: *Reader, n: usize) Error![]const u8 {
        if (r.pos + n > r.data.len) return error.BadMessage;
        defer r.pos += n;
        return r.data[r.pos..][0..n];
    }

    pub fn byte(r: *Reader) Error!u8 {
        return (try r.take(1))[0];
    }

    pub fn uint(r: *Reader) Error!u32 {
        try r.alignTo(4);
        return std.mem.readInt(u32, (try r.take(4))[0..4], .little);
    }

    pub fn boolean(r: *Reader) Error!bool {
        return try r.uint() != 0;
    }

    pub fn double(r: *Reader) Error!f64 {
        try r.alignTo(8);
        return @bitCast(std.mem.readInt(u64, (try r.take(8))[0..8], .little));
    }

    pub fn string(r: *Reader) Error![]const u8 {
        const n = try r.uint();
        const s = try r.take(n);
        _ = try r.take(1);
        return s;
    }

    pub fn signature(r: *Reader) Error![]const u8 {
        const n = try r.byte();
        const s = try r.take(n);
        _ = try r.take(1);
        return s;
    }

    /// Reads the length of an array and gives the end of its elements.
    pub fn beginArray(r: *Reader, elem_align: usize) Error!usize {
        const n = try r.uint();
        try r.alignTo(elem_align);
        if (r.pos + n > r.data.len) return error.BadMessage;
        return r.pos + n;
    }

    /// Skips one complete type of a signature, from `sig[i.*]`.
    pub fn skip(r: *Reader, sig: []const u8, i: *usize) Error!void {
        if (i.* >= sig.len) return error.BadMessage;
        const ch = sig[i.*];
        i.* += 1;
        switch (ch) {
            'y' => _ = try r.take(1),
            'b', 'i', 'u', 'h' => _ = try r.uint(),
            'n', 'q' => {
                try r.alignTo(2);
                _ = try r.take(2);
            },
            'x', 't', 'd' => {
                try r.alignTo(8);
                _ = try r.take(8);
            },
            's', 'o' => _ = try r.string(),
            'g' => _ = try r.signature(),
            'v' => {
                const vs = try r.signature();
                var k: usize = 0;
                try r.skip(vs, &k);
            },
            'a' => {
                const elem_align = alignOf(sig, i.*);
                const end = try r.beginArray(elem_align);
                const start_sig = i.*;
                var j = start_sig;
                // Find the end of the element type with an empty walk.
                try skipSig(sig, &j);
                while (r.pos < end) {
                    var k = start_sig;
                    try r.skip(sig, &k);
                }
                if (r.pos != end) return error.BadMessage;
                i.* = j;
            },
            '(', '{' => {
                try r.alignTo(8);
                const close: u8 = if (ch == '(') ')' else '}';
                while (i.* < sig.len and sig[i.*] != close) try r.skip(sig, i);
                if (i.* >= sig.len) return error.BadMessage;
                i.* += 1;
            },
            else => return error.BadMessage,
        }
    }
};

/// The alignment of the type at `sig[i]`.
fn alignOf(sig: []const u8, i: usize) usize {
    if (i >= sig.len) return 1;
    return switch (sig[i]) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// Moves `i` past one complete type of a signature.
fn skipSig(sig: []const u8, i: *usize) Error!void {
    if (i.* >= sig.len) return error.BadMessage;
    const ch = sig[i.*];
    i.* += 1;
    switch (ch) {
        'a' => try skipSig(sig, i),
        '(', '{' => {
            const close: u8 = if (ch == '(') ')' else '}';
            while (i.* < sig.len and sig[i.*] != close) try skipSig(sig, i);
            if (i.* >= sig.len) return error.BadMessage;
            i.* += 1;
        },
        else => {},
    }
}

// ---- Messages ----

/// One message from the bus. The strings point into `raw`.
pub const Message = struct {
    raw: []u8,
    type: MsgType,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    sender: []const u8 = "",
    signature: []const u8 = "",
    body: []const u8 = "",

    pub fn deinit(m: Message, gpa: std.mem.Allocator) void {
        gpa.free(m.raw);
    }

    pub fn reader(m: *const Message) Reader {
        return .{ .data = m.body };
    }

    /// Parses a complete message. The message keeps `raw`.
    pub fn parse(raw: []u8) Error!Message {
        if (raw.len < 16 or raw[0] != 'l' or raw[3] != 1) return error.BadMessage;
        var m: Message = .{ .raw = raw, .type = @enumFromInt(raw[1]), .serial = std.mem.readInt(u32, raw[8..12], .little) };
        const body_len = std.mem.readInt(u32, raw[4..8], .little);
        var r: Reader = .{ .data = raw, .pos = 12 };
        const end = try r.beginArray(8);
        while (r.pos < end) {
            try r.alignTo(8);
            const code = try r.byte();
            const sig = try r.signature();
            if (sig.len != 1) {
                var k: usize = 0;
                try r.skip(sig, &k);
                continue;
            }
            switch (sig[0]) {
                's', 'o' => {
                    const s = try r.string();
                    switch (code) {
                        F.path => m.path = s,
                        F.interface => m.interface = s,
                        F.member => m.member = s,
                        F.error_name => m.error_name = s,
                        F.sender => m.sender = s,
                        else => {},
                    }
                },
                'g' => {
                    const s = try r.signature();
                    if (code == F.signature) m.signature = s;
                },
                'u' => {
                    const v = try r.uint();
                    if (code == F.reply_serial) m.reply_serial = v;
                },
                else => {
                    var k: usize = 0;
                    try r.skip(sig, &k);
                },
            }
        }
        try r.alignTo(8);
        if (r.pos + body_len != raw.len) return error.BadMessage;
        m.body = raw[r.pos..];
        return m;
    }
};

/// The size of a complete message from its first 16 bytes.
pub fn messageSize(head: *const [16]u8) Error!usize {
    if (head[0] != 'l') return error.BadMessage;
    const body_len = std.mem.readInt(u32, head[4..8], .little);
    const fields_len = std.mem.readInt(u32, head[12..16], .little);
    if (body_len > 1 << 27 or fields_len > 1 << 26) return error.BadMessage;
    return std.mem.alignForward(usize, 16 + fields_len, 8) + body_len;
}

/// The fields of a message to send.
pub const Call = struct {
    type: MsgType = .method_call,
    destination: []const u8 = "",
    path: []const u8 = "",
    interface: []const u8 = "",
    member: []const u8 = "",
    error_name: []const u8 = "",
    reply_serial: u32 = 0,
    signature: []const u8 = "",
    body: []const u8 = "",
    /// No reply: the flag NO_REPLY_EXPECTED.
    no_reply: bool = false,
};

/// Writes a whole message: the header, its fields, the padding, and the body.
pub fn encode(gpa: std.mem.Allocator, serial: u32, c: Call) Error![]u8 {
    var w: Writer = .{ .gpa = gpa };
    errdefer w.deinit();
    w.byte('l');
    w.byte(@intFromEnum(c.type));
    w.byte(if (c.no_reply) 1 else 0);
    w.byte(1);
    w.uint(@intCast(c.body.len));
    w.uint(serial);
    const a = w.beginArray(8);
    const strs = [_]struct { u8, u8, []const u8 }{
        .{ F.path, 'o', c.path },
        .{ F.interface, 's', c.interface },
        .{ F.member, 's', c.member },
        .{ F.error_name, 's', c.error_name },
        .{ F.destination, 's', c.destination },
    };
    for (strs) |f| if (f[2].len > 0) {
        w.beginStruct();
        w.byte(f[0]);
        w.signature(&.{f[1]});
        w.string(f[2]);
    };
    if (c.reply_serial != 0) {
        w.beginStruct();
        w.byte(F.reply_serial);
        w.signature("u");
        w.uint(c.reply_serial);
    }
    if (c.signature.len > 0) {
        w.beginStruct();
        w.byte(F.signature);
        w.signature("g");
        w.signature(c.signature);
    }
    w.endArray(a);
    w.alignTo(8);
    w.raw(c.body);
    _ = try w.bytes();
    return w.buf.toOwnedSlice(gpa) catch error.OutOfMemory;
}

// ---- The connection ----

pub const Conn = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    serial: u32 = 0,
    /// The unique name of the connection, from `Hello`.
    unique: []u8 = &.{},
    /// The signals that `call` read before its reply.
    pending: std.ArrayListUnmanaged(Message) = .empty,

    /// Connects to the first address of a bus address list that works.
    pub fn connect(gpa: std.mem.Allocator, address: []const u8) Error!*Conn {
        var it = std.mem.splitScalar(u8, address, ';');
        while (it.next()) |a| {
            const fd = connectOne(a) catch continue;
            return fromFd(gpa, fd);
        }
        return error.ConnectFailed;
    }

    fn connectOne(a: []const u8) Error!i32 {
        if (!std.mem.startsWith(u8, a, "unix:")) return error.ConnectFailed;
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        var len: usize = 0;
        var kv = std.mem.splitScalar(u8, a[5..], ',');
        while (kv.next()) |p| {
            const eq = std.mem.indexOfScalar(u8, p, '=') orelse continue;
            const key = p[0..eq];
            const val = p[eq + 1 ..];
            const abstract = std.mem.eql(u8, key, "abstract");
            if (!abstract and !std.mem.eql(u8, key, "path")) continue;
            // An abstract name starts with a 0 byte. A value has no escapes here.
            const off: usize = @intFromBool(abstract);
            if (off + val.len >= addr.path.len or std.mem.indexOfScalar(u8, val, '%') != null) return error.ConnectFailed;
            @memcpy(addr.path[off..][0..val.len], val);
            len = off + val.len + @intFromBool(!abstract);
        }
        if (len == 0) return error.ConnectFailed;
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (isErr(rc)) return error.ConnectFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const slen: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + len);
        if (isErr(linux.connect(fd, &addr, slen))) return error.ConnectFailed;
        return fd;
    }

    /// Authenticates on a connected socket and sends `Hello`.
    pub fn fromFd(gpa: std.mem.Allocator, fd: i32) Error!*Conn {
        const c = try gpa.create(Conn);
        c.* = .{ .gpa = gpa, .fd = fd };
        errdefer {
            _ = linux.close(fd);
            gpa.destroy(c);
        }
        try c.auth();
        const reply = try c.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello" }, 5000);
        defer reply.deinit(gpa);
        var r = reply.reader();
        c.unique = try gpa.dupe(u8, try r.string());
        return c;
    }

    pub fn deinit(c: *Conn) void {
        _ = linux.close(c.fd);
        for (c.pending.items) |m| m.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.gpa.free(c.unique);
        c.gpa.destroy(c);
    }

    fn writeAll(c: *Conn, b: []const u8) Error!void {
        var off: usize = 0;
        while (off < b.len) {
            const rc = linux.sendto(c.fd, b[off..].ptr, b.len - off, linux.MSG.NOSIGNAL, null, 0);
            if (isErr(rc)) {
                if (linux.errno(rc) == .INTR) continue;
                return error.Disconnected;
            }
            off += rc;
        }
    }

    /// Reads exactly `out.len` bytes, waiting at most `timeout_ms` for each read (-1: no limit).
    fn readAll(c: *Conn, out: []u8, timeout_ms: i32) Error!void {
        var off: usize = 0;
        while (off < out.len) {
            if (!try c.readable(timeout_ms)) return error.Timeout;
            const rc = linux.read(c.fd, out[off..].ptr, out.len - off);
            if (isErr(rc)) {
                if (linux.errno(rc) == .INTR) continue;
                return error.Disconnected;
            }
            if (rc == 0) return error.Disconnected;
            off += rc;
        }
    }

    pub fn readable(c: *Conn, timeout_ms: i32) Error!bool {
        var pfd = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.IN, .revents = 0 }};
        while (true) {
            const rc = linux.poll(&pfd, 1, timeout_ms);
            if (isErr(rc)) {
                if (linux.errno(rc) == .INTR) continue;
                return error.Disconnected;
            }
            return rc > 0;
        }
    }

    /// The SASL lines: a 0 byte, AUTH EXTERNAL with the user id in hex, and BEGIN.
    fn auth(c: *Conn) Error!void {
        var uid_buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{linux.getuid()}) catch unreachable;
        var line: [64]u8 = undefined;
        var n: usize = 0;
        const head = "\x00AUTH EXTERNAL ";
        @memcpy(line[0..head.len], head);
        n = head.len;
        for (uid) |ch| {
            _ = std.fmt.bufPrint(line[n..][0..2], "{x:0>2}", .{ch}) catch unreachable;
            n += 2;
        }
        @memcpy(line[n..][0..2], "\r\n");
        n += 2;
        try c.writeAll(line[0..n]);
        var resp: [128]u8 = undefined;
        var got: usize = 0;
        while (got < 2 or !std.mem.eql(u8, resp[got - 2 .. got], "\r\n")) {
            if (got == resp.len) return error.AuthFailed;
            try c.readAll(resp[got..][0..1], 5000);
            got += 1;
        }
        if (!std.mem.startsWith(u8, resp[0..got], "OK ")) return error.AuthFailed;
        try c.writeAll("BEGIN\r\n");
    }

    /// Reads one message, waiting at most `timeout_ms` (-1: no limit).
    pub fn read(c: *Conn, timeout_ms: i32) Error!Message {
        var head: [16]u8 = undefined;
        try c.readAll(&head, timeout_ms);
        const size = try messageSize(&head);
        const raw = try c.gpa.alloc(u8, size);
        errdefer c.gpa.free(raw);
        @memcpy(raw[0..16], &head);
        try c.readAll(raw[16..], 5000);
        return Message.parse(raw);
    }

    /// Sends a message and gives its serial.
    pub fn send(c: *Conn, m: Call) Error!u32 {
        c.serial +%= 1;
        if (c.serial == 0) c.serial = 1;
        const b = try encode(c.gpa, c.serial, m);
        defer c.gpa.free(b);
        try c.writeAll(b);
        return c.serial;
    }

    /// Sends a method call and gives its reply. An error reply gives
    /// `error.CallFailed`. A method call to us gets an error reply, as the
    /// specification asks of a client with no objects.
    pub fn call(c: *Conn, m: Call, timeout_ms: i32) Error!Message {
        const serial = try c.send(m);
        while (true) {
            const msg = try c.read(timeout_ms);
            if ((msg.type == .method_return or msg.type == .@"error") and msg.reply_serial == serial) {
                if (msg.type == .@"error") {
                    msg.deinit(c.gpa);
                    return error.CallFailed;
                }
                return msg;
            }
            c.other(msg);
        }
    }

    /// A message that is not the reply of a call: a signal waits in
    /// `pending`, and a method call gets an error reply.
    pub fn other(c: *Conn, msg: Message) void {
        if (msg.type == .signal) {
            c.pending.append(c.gpa, msg) catch msg.deinit(c.gpa);
            return;
        }
        if (msg.type == .method_call and msg.raw[2] & 1 == 0) {
            _ = c.send(.{ .type = .@"error", .destination = msg.sender, .error_name = "org.freedesktop.DBus.Error.UnknownObject", .reply_serial = msg.serial, .no_reply = true }) catch {};
        }
        msg.deinit(c.gpa);
    }

    /// Gives the first signal with this path, interface, and member, from
    /// the pending list or the socket. `idle` runs each `idle_ms` while
    /// the wait goes on, so the caller can read its other sockets.
    pub fn waitSignal(c: *Conn, path: []const u8, interface: []const u8, member: []const u8, idle: ?Idle) Error!Message {
        while (true) {
            for (c.pending.items, 0..) |m, k| if (matches(m, path, interface, member)) {
                _ = c.pending.orderedRemove(k);
                return m;
            };
            if (idle) |f| {
                while (!try c.readable(f.ms)) f.run(f.ctx);
            }
            c.other(try c.read(-1));
        }
    }

    pub const Idle = struct { ctx: *anyopaque, run: *const fn (ctx: *anyopaque) void, ms: i32 = 50 };

    fn matches(m: Message, path: []const u8, interface: []const u8, member: []const u8) bool {
        return m.type == .signal and std.mem.eql(u8, m.path, path) and std.mem.eql(u8, m.interface, interface) and std.mem.eql(u8, m.member, member);
    }

    /// Asks the bus to send the signals of a match rule (`AddMatch`).
    pub fn addMatch(c: *Conn, rule: []const u8) Error!void {
        var w: Writer = .{ .gpa = c.gpa };
        defer w.deinit();
        w.string(rule);
        const reply = try c.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "AddMatch", .signature = "s", .body = try w.bytes() }, 5000);
        reply.deinit(c.gpa);
    }
};

const t = std.testing;

test "dbus: a message encodes and parses again" {
    var w: Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    w.string("title");
    const a = w.beginArray(8);
    w.dictBool("multiple", true);
    w.dictString("handle_token", "ztk1");
    w.endArray(a);
    const raw = try encode(t.allocator, 7, .{ .destination = "org.freedesktop.portal.Desktop", .path = "/org/freedesktop/portal/desktop", .interface = "org.freedesktop.portal.FileChooser", .member = "OpenFile", .signature = "sa{sv}", .body = try w.bytes() });
    const m = try Message.parse(raw);
    defer m.deinit(t.allocator);
    try t.expectEqual(MsgType.method_call, m.type);
    try t.expectEqual(@as(u32, 7), m.serial);
    try t.expectEqualStrings("OpenFile", m.member);
    try t.expectEqualStrings("/org/freedesktop/portal/desktop", m.path);
    try t.expectEqualStrings("sa{sv}", m.signature);
    // The body starts at a multiple of 8.
    try t.expectEqual(@as(usize, 0), (@intFromPtr(m.body.ptr) - @intFromPtr(raw.ptr)) % 8);
    var r = m.reader();
    try t.expectEqualStrings("title", try r.string());
    const end = try r.beginArray(8);
    try r.alignTo(8);
    try t.expectEqualStrings("multiple", try r.string());
    try t.expectEqualStrings("b", try r.signature());
    try t.expect(try r.boolean());
    try r.alignTo(8);
    try t.expectEqualStrings("handle_token", try r.string());
    var k: usize = 0;
    try r.skip("v", &k);
    try t.expectEqual(end, r.pos);
}

test "dbus: skip walks nested arrays, structs, and variants" {
    var w: Writer = .{ .gpa = t.allocator };
    defer w.deinit();
    // a(sa(us)): one filter with two patterns, then a u.
    const a = w.beginArray(8);
    w.beginStruct();
    w.string("Text");
    const b = w.beginArray(8);
    for ([_][]const u8{ "*.txt", "text/plain" }, 0..) |p, i| {
        w.beginStruct();
        w.uint(@intCast(i));
        w.string(p);
    }
    w.endArray(b);
    w.endArray(a);
    w.uint(42);
    var r: Reader = .{ .data = try w.bytes() };
    var k: usize = 0;
    try r.skip("a(sa(us))u", &k);
    try t.expectEqual(@as(usize, 9), k);
    try t.expectEqual(@as(u32, 42), try r.uint());
    try t.expectEqual(r.data.len, r.pos);
}

test "dbus: a truncated message gives BadMessage" {
    const raw = try encode(t.allocator, 1, .{ .path = "/a", .member = "M" });
    defer t.allocator.free(raw);
    const copy = try t.allocator.dupe(u8, raw[0 .. raw.len - 1]);
    defer t.allocator.free(copy);
    try t.expectError(error.BadMessage, Message.parse(copy));
}

test "dbus: Hello and GetId on the bus of DBUS_SESSION_BUS_ADDRESS" {
    // tests/dbus.sh runs this test on a private bus of dbus-run-session.
    if (!@import("builtin").link_libc) return error.SkipZigTest;
    const addr = std.c.getenv("ZTK_TEST_BUS") orelse return error.SkipZigTest;
    const c = try Conn.connect(t.allocator, std.mem.span(addr));
    defer c.deinit();
    try t.expect(std.mem.startsWith(u8, c.unique, ":"));
    const reply = try c.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "GetId" }, 5000);
    defer reply.deinit(t.allocator);
    var r = reply.reader();
    try t.expectEqual(@as(usize, 32), (try r.string()).len);
    try c.addMatch("type='signal',interface='org.freedesktop.DBus',member='NameOwnerChanged'");
    try t.expectError(error.CallFailed, c.call(.{ .destination = "org.freedesktop.DBus", .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "NoSuchMethod" }, 5000));
}
