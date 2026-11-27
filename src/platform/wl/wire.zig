//! The Wayland wire protocol over the Unix socket of the compositor, with
//! no C library. A message is the object id (32 bits), then the size in
//! bytes (high 16 bits) and the opcode (low 16 bits), then the arguments.
//! Each argument is 32 bits, or for a string and an array a length and the
//! bytes padded to 32 bits. A file descriptor goes in the ancillary data of
//! the socket (SCM_RIGHTS), in the order of the messages.
//!
//! `Conn` keeps the table of objects: for each id, its interface (a number
//! that the backend gives), its queue, and the opcodes of its events that
//! have a file descriptor. The read puts each event in the queue of its
//! object. The backend reads the events of a queue with `next`. Two
//! threads can each have a queue: a lock guards the socket, the buffers,
//! and the table.
//!
//! The source of the format is the Wayland protocol documentation
//! (the section "Wire Format") and the
//! protocol XML files (MIT license). docs/references/wayland.md has the
//! list.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const linux = std.os.linux;

pub const Error = error{ ConnectFailed, Disconnected, ProtocolError, OutOfMemory, TooManyObjects };

/// A 24.8 signed fixed-point number.
pub const Fixed = i32;

pub fn fixedToF32(v: Fixed) f32 {
    return @as(f32, @floatFromInt(v)) / 256.0;
}

pub fn f32ToFixed(v: f32) Fixed {
    return @intFromFloat(@round(v * 256.0));
}

/// A file descriptor argument of a request.
pub const Fd = struct { fd: i32 };
/// A string argument of a request. `null` is the null string.
pub const Str = struct { s: ?[]const u8 };
/// An array argument of a request.
pub const Arr = struct { bytes: []const u8 };

pub const Queue = enum(u1) { main, input };

/// A lock that spins and yields. Each holder keeps it for a short copy or
/// one system call.
const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(l: *Lock) void {
        while (l.held.swap(true, .acquire)) _ = linux.sched_yield();
    }
    fn unlock(l: *Lock) void {
        l.held.store(false, .release);
    }
};

const max_fds = 28;

const Obj = struct {
    iface: u16 = 0,
    queue: Queue = .main,
    /// A bit for each event opcode that has one file descriptor.
    fd_events: u32 = 0,
    /// The event (and the interface of its new object) whose first argument is a `new_id`.
    creates_op: u8 = 0xff,
    creates_iface: u16 = 0,
    /// The client destroyed the object and waits for its `delete_id`.
    zombie: bool = false,
    used: bool = false,
};

/// One event in a queue.
pub const Event = struct {
    id: u32,
    iface: u16,
    op: u16,
    data: []u8,
    fds: [2]i32 = .{ -1, -1 },
    nfds: u8 = 0,

    /// A reader of the arguments.
    pub fn args(e: *const Event) Args {
        return .{ .data = e.data, .fds = e.fds[0..e.nfds] };
    }
};

/// Reads the arguments of an event in order. A short message reads as zeros.
pub const Args = struct {
    data: []const u8,
    pos: usize = 0,
    fds: []const i32,
    fd_pos: usize = 0,

    pub fn uint(a: *Args) u32 {
        if (a.pos + 4 > a.data.len) return 0;
        const v = std.mem.readInt(u32, a.data[a.pos..][0..4], .little);
        a.pos += 4;
        return v;
    }
    pub fn int(a: *Args) i32 {
        return @bitCast(a.uint());
    }
    pub fn fixed(a: *Args) f32 {
        return fixedToF32(a.int());
    }
    /// The bytes of a string without its terminating zero, or null.
    pub fn string(a: *Args) ?[]const u8 {
        const b = a.array();
        if (b.len == 0) return null;
        return b[0 .. b.len - 1];
    }
    pub fn array(a: *Args) []const u8 {
        const n = a.uint();
        if (a.pos + n > a.data.len) {
            a.pos = a.data.len;
            return &.{};
        }
        const b = a.data[a.pos..][0..n];
        a.pos += (n + 3) & ~@as(usize, 3);
        return b;
    }
    pub fn fd(a: *Args) i32 {
        if (a.fd_pos >= a.fds.len) return -1;
        a.fd_pos += 1;
        return a.fds[a.fd_pos - 1];
    }
};

pub const Conn = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    mutex: Lock = .{},
    objects: std.ArrayListUnmanaged(Obj) = .empty,
    /// The objects that the compositor made (ids from 0xff000000), such as a `wl_data_offer`.
    server_objects: std.AutoHashMapUnmanaged(u32, Obj) = .empty,
    free_ids: std.ArrayListUnmanaged(u32) = .empty,
    out: std.ArrayListUnmanaged(u8) = .empty,
    out_fds: std.ArrayListUnmanaged(i32) = .empty,
    in: std.ArrayListUnmanaged(u8) = .empty,
    in_fds: std.ArrayListUnmanaged(i32) = .empty,
    queues: [2]std.ArrayListUnmanaged(Event) = .{ .empty, .empty },
    /// The read position in each queue.
    heads: [2]usize = .{ 0, 0 },
    /// The error event of the display, when one came.
    failed: bool = false,
    dead: bool = false,

    /// The interface number of `wl_display`, object 1.
    pub const display_iface: u16 = 0;

    /// Connects to `display`: a socket name in `runtime_dir`, or an absolute path.
    pub fn connect(gpa: std.mem.Allocator, runtime_dir: ?[]const u8, display: ?[]const u8) Error!*Conn {
        const name = display orelse "wayland-0";
        var addr: linux.sockaddr.un = .{ .path = @splat(0) };
        var n: usize = 0;
        if (name.len > 0 and name[0] == '/') {
            if (name.len >= addr.path.len) return error.ConnectFailed;
            @memcpy(addr.path[0..name.len], name);
            n = name.len;
        } else {
            const dir = runtime_dir orelse return error.ConnectFailed;
            if (dir.len + 1 + name.len >= addr.path.len) return error.ConnectFailed;
            @memcpy(addr.path[0..dir.len], dir);
            addr.path[dir.len] = '/';
            @memcpy(addr.path[dir.len + 1 ..][0..name.len], name);
            n = dir.len + 1 + name.len;
        }
        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (isErr(rc)) return error.ConnectFailed;
        const fd: i32 = @intCast(rc);
        errdefer _ = linux.close(fd);
        const len: linux.socklen_t = @intCast(@sizeOf(linux.sa_family_t) + n + 1);
        if (isErr(linux.connect(fd, &addr, len))) return error.ConnectFailed;
        return fromFd(gpa, fd);
    }

    /// A connection on a socket that is open already (WAYLAND_SOCKET).
    pub fn fromFd(gpa: std.mem.Allocator, fd: i32) Error!*Conn {
        const c = try gpa.create(Conn);
        c.* = .{ .gpa = gpa, .fd = fd };
        errdefer gpa.destroy(c);
        // Id 0 is the null object and id 1 is the display.
        try c.objects.appendNTimes(gpa, .{}, 2);
        c.objects.items[1] = .{ .iface = display_iface, .used = true };
        return c;
    }

    pub fn deinit(c: *Conn) void {
        c.flush() catch {};
        _ = linux.close(c.fd);
        for (c.queues, c.heads) |q, h| for (q.items[h..]) |e| c.freeEvent(e);
        for (c.in_fds.items) |f| _ = linux.close(f);
        for (c.out_fds.items) |f| _ = linux.close(f);
        for (&c.queues) |*q| q.deinit(c.gpa);
        c.objects.deinit(c.gpa);
        c.server_objects.deinit(c.gpa);
        c.free_ids.deinit(c.gpa);
        c.out.deinit(c.gpa);
        c.out_fds.deinit(c.gpa);
        c.in.deinit(c.gpa);
        c.in_fds.deinit(c.gpa);
        c.gpa.destroy(c);
    }

    fn isErr(rc: usize) bool {
        return @as(isize, @bitCast(rc)) < 0;
    }

    fn errno(rc: usize) linux.E {
        return linux.errno(rc);
    }

    /// A new client object of an interface. `fd_events` has a bit for each
    /// event opcode with a file descriptor.
    pub fn newObject(c: *Conn, iface: u16, queue: Queue, fd_events: u32) Error!u32 {
        c.mutex.lock();
        defer c.mutex.unlock();
        const id = c.free_ids.pop() orelse blk: {
            if (c.objects.items.len >= 0xff000000) return error.TooManyObjects;
            try c.objects.append(c.gpa, .{});
            break :blk @as(u32, @intCast(c.objects.items.len - 1));
        };
        c.objects.items[id] = .{ .iface = iface, .queue = queue, .fd_events = fd_events, .used = true };
        return id;
    }

    /// Marks the event of an object whose first argument is a new object of
    /// the compositor. The read records the new object at once, because
    /// its own events can come in the same read.
    pub fn setCreates(c: *Conn, id: u32, op: u8, iface: u16) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (id < c.objects.items.len) {
            c.objects.items[id].creates_op = op;
            c.objects.items[id].creates_iface = iface;
        }
    }

    /// Records an object that the compositor made with a `new_id` argument of an event.
    pub fn serverObject(c: *Conn, id: u32, iface: u16, queue: Queue) Error!void {
        c.mutex.lock();
        defer c.mutex.unlock();
        try c.server_objects.put(c.gpa, id, .{ .iface = iface, .queue = queue, .used = true });
    }

    /// Forgets an object of the compositor after its destructor request.
    pub fn forget(c: *Conn, id: u32) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        _ = c.server_objects.remove(id);
    }

    /// Moves an object to another queue. Its events that wait stay in the old queue.
    pub fn setQueue(c: *Conn, id: u32, queue: Queue) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (id < c.objects.items.len) c.objects.items[id].queue = queue;
    }

    /// Marks an object as destroyed after its destructor request. The id
    /// is free after the `delete_id` of the compositor.
    pub fn destroyed(c: *Conn, id: u32) void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (id < c.objects.items.len) c.objects.items[id].zombie = true;
    }

    /// Writes a request. `args` is a tuple of u32, i32, `Fd`, `Str`, and `Arr`.
    pub fn send(c: *Conn, id: u32, op: u16, args: anytype) Error!void {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.dead) return error.Disconnected;
        var size: usize = 8;
        inline for (args) |a| size += argSize(a);
        if (c.out.items.len + size > 4096 or c.out_fds.items.len + 2 > max_fds) try c.flushLocked();
        const start = c.out.items.len;
        try c.out.ensureUnusedCapacity(c.gpa, size);
        c.put(id);
        c.put(@as(u32, @intCast(size)) << 16 | op);
        inline for (args) |a| {
            const T = @TypeOf(a);
            if (T == Fd) {
                try c.out_fds.append(c.gpa, a.fd);
            } else if (T == Str) {
                if (a.s) |s| {
                    c.put(@intCast(s.len + 1));
                    c.out.appendSliceAssumeCapacity(s);
                    c.out.appendAssumeCapacity(0);
                    c.pad(s.len + 1);
                } else c.put(0);
            } else if (T == Arr) {
                c.put(@intCast(a.bytes.len));
                c.out.appendSliceAssumeCapacity(a.bytes);
                c.pad(a.bytes.len);
            } else if (T == i32) {
                c.put(@bitCast(a));
            } else {
                c.put(@intCast(a));
            }
        }
        std.debug.assert(c.out.items.len - start == size);
    }

    fn argSize(a: anytype) usize {
        const T = @TypeOf(a);
        if (T == Fd) return 0;
        if (T == Str) return if (a.s) |s| 4 + ((s.len + 1 + 3) & ~@as(usize, 3)) else 4;
        if (T == Arr) return 4 + ((a.bytes.len + 3) & ~@as(usize, 3));
        return 4;
    }

    fn put(c: *Conn, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        c.out.appendSliceAssumeCapacity(&b);
    }

    fn pad(c: *Conn, n: usize) void {
        const p = ((n + 3) & ~@as(usize, 3)) - n;
        c.out.appendNTimesAssumeCapacity(0, p);
    }

    /// Sends the requests that wait in the buffer.
    pub fn flush(c: *Conn) Error!void {
        c.mutex.lock();
        defer c.mutex.unlock();
        try c.flushLocked();
    }

    fn flushLocked(c: *Conn) Error!void {
        var sent: usize = 0;
        while (sent < c.out.items.len) {
            var iov = [1]std.posix.iovec_const{.{ .base = c.out.items[sent..].ptr, .len = c.out.items.len - sent }};
            var cbuf: [cmsgSpace(max_fds * 4)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            var msg: linux.msghdr_const = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
            const nfds = c.out_fds.items.len;
            if (nfds > 0) {
                const h: *linux.cmsghdr = @ptrCast(&cbuf);
                h.* = .{ .len = cmsgLen(nfds * 4), .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
                @memcpy(cbuf[@sizeOf(linux.cmsghdr)..][0 .. nfds * 4], std.mem.sliceAsBytes(c.out_fds.items));
                msg.control = &cbuf;
                msg.controllen = cmsgSpace(nfds * 4);
            }
            const rc = linux.sendmsg(c.fd, &msg, linux.MSG.NOSIGNAL);
            if (isErr(rc)) {
                switch (errno(rc)) {
                    .INTR => continue,
                    .AGAIN => {
                        var pfd = [1]linux.pollfd{.{ .fd = c.fd, .events = linux.POLL.OUT, .revents = 0 }};
                        _ = linux.poll(&pfd, 1, 1000);
                        continue;
                    },
                    else => {
                        c.dead = true;
                        return error.Disconnected;
                    },
                }
            }
            // The kernel duplicated the descriptors: close the copies of the client.
            for (c.out_fds.items) |f| _ = linux.close(f);
            c.out_fds.clearRetainingCapacity();
            sent += rc;
        }
        c.out.clearRetainingCapacity();
    }

    fn cmsgLen(n: usize) usize {
        return @sizeOf(linux.cmsghdr) + n;
    }

    fn cmsgSpace(n: usize) usize {
        const a = @sizeOf(usize);
        return @sizeOf(linux.cmsghdr) + ((n + a - 1) & ~@as(usize, a - 1));
    }

    /// Reads what waits on the socket with no block and puts the events in
    /// their queues. It returns a bit for each queue that got an event.
    pub fn read(c: *Conn) Error!u2 {
        c.mutex.lock();
        defer c.mutex.unlock();
        if (c.dead) return error.Disconnected;
        var got: u2 = 0;
        while (true) {
            var buf: [4096]u8 = undefined;
            var iov = [1]std.posix.iovec{.{ .base = &buf, .len = buf.len }};
            var cbuf: [cmsgSpace(max_fds * 4)]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            var msg: linux.msghdr = .{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &cbuf, .controllen = cbuf.len, .flags = 0 };
            const rc = linux.recvmsg(c.fd, &msg, linux.MSG.DONTWAIT | linux.MSG.CMSG_CLOEXEC);
            if (isErr(rc)) switch (errno(rc)) {
                .INTR => continue,
                .AGAIN => break,
                else => {
                    c.dead = true;
                    return error.Disconnected;
                },
            };
            if (rc == 0) {
                c.dead = true;
                return error.Disconnected;
            }
            // The descriptors of the control messages.
            var off: usize = 0;
            while (off + @sizeOf(linux.cmsghdr) <= msg.controllen) {
                const h: *align(1) const linux.cmsghdr = @ptrCast(cbuf[off..].ptr);
                if (h.len < @sizeOf(linux.cmsghdr)) break;
                if (h.level == linux.SOL.SOCKET and h.type == linux.SCM.RIGHTS) {
                    const n = (h.len - @sizeOf(linux.cmsghdr)) / 4;
                    for (0..n) |k| {
                        const f = std.mem.readInt(i32, cbuf[off + @sizeOf(linux.cmsghdr) + k * 4 ..][0..4], .little);
                        try c.in_fds.append(c.gpa, f);
                    }
                }
                off += cmsgSpace(h.len - @sizeOf(linux.cmsghdr));
            }
            try c.in.appendSlice(c.gpa, buf[0..rc]);
        }
        // Each whole message goes to its queue.
        var pos: usize = 0;
        while (c.in.items.len - pos >= 8) {
            const id = std.mem.readInt(u32, c.in.items[pos..][0..4], .little);
            const word = std.mem.readInt(u32, c.in.items[pos + 4 ..][0..4], .little);
            const size: usize = word >> 16;
            const op: u16 = @truncate(word);
            if (size < 8) {
                c.dead = true;
                return error.ProtocolError;
            }
            if (c.in.items.len - pos < size) break;
            const body = c.in.items[pos + 8 .. pos + size];
            pos += size;
            if (id == 1) {
                try c.displayEvent(op, body);
                continue;
            }
            const obj: Obj = if (id < c.objects.items.len) c.objects.items[id] else c.server_objects.get(id) orelse .{};
            var e: Event = .{ .id = id, .iface = obj.iface, .op = op, .data = &.{} };
            if (op < 32 and obj.fd_events & (@as(u32, 1) << @intCast(op)) != 0) {
                if (c.in_fds.items.len > 0) {
                    e.fds[0] = c.in_fds.orderedRemove(0);
                    e.nfds = 1;
                }
            }
            if (!obj.used or obj.zombie) {
                // An event of an object that the client destroyed.
                if (e.nfds > 0) _ = linux.close(e.fds[0]);
                continue;
            }
            if (op == obj.creates_op and body.len >= 4) {
                const nid = std.mem.readInt(u32, body[0..4], .little);
                try c.server_objects.put(c.gpa, nid, .{ .iface = obj.creates_iface, .queue = obj.queue, .used = true });
            }
            e.data = try c.gpa.dupe(u8, body);
            try c.queues[@intFromEnum(obj.queue)].append(c.gpa, e);
            got |= @as(u2, 1) << @intFromEnum(obj.queue);
        }
        if (pos > 0) {
            std.mem.copyForwards(u8, c.in.items[0 .. c.in.items.len - pos], c.in.items[pos..]);
            c.in.shrinkRetainingCapacity(c.in.items.len - pos);
        }
        return got;
    }

    fn displayEvent(c: *Conn, op: u16, body: []const u8) Error!void {
        var a: Args = .{ .data = body, .fds = &.{} };
        switch (op) {
            0 => {
                const obj = a.uint();
                const code = a.uint();
                const text = a.string() orelse "";
                std.log.err("wayland: protocol error {d} on object {d}: {s}", .{ code, obj, text });
                c.failed = true;
                c.dead = true;
                return error.ProtocolError;
            },
            1 => {
                const id = a.uint();
                if (id > 1 and id < c.objects.items.len and c.objects.items[id].used) {
                    c.objects.items[id] = .{};
                    try c.free_ids.append(c.gpa, id);
                }
            },
            else => {},
        }
    }

    /// The next event of a queue, or null. The caller gives it to `release`.
    pub fn next(c: *Conn, queue: Queue) ?Event {
        c.mutex.lock();
        defer c.mutex.unlock();
        const q = &c.queues[@intFromEnum(queue)];
        const h = &c.heads[@intFromEnum(queue)];
        while (h.* < q.items.len) {
            const e = q.items[h.*];
            h.* += 1;
            // The object can be destroyed after the read of its event.
            const gone = if (e.id < c.objects.items.len) c.objects.items[e.id].zombie else e.id >= 0xff000000 and !c.server_objects.contains(e.id);
            if (gone) {
                c.freeEvent(e);
                continue;
            }
            return e;
        }
        q.clearRetainingCapacity();
        h.* = 0;
        return null;
    }

    /// Frees an event of `next`. A file descriptor that the backend kept is its own.
    pub fn release(c: *Conn, e: Event) void {
        c.gpa.free(e.data);
    }

    fn freeEvent(c: *Conn, e: Event) void {
        if (e.nfds > 0) _ = linux.close(e.fds[0]);
        c.gpa.free(e.data);
    }

    /// True when a queue has events that wait.
    pub fn pending(c: *Conn, queue: Queue) bool {
        c.mutex.lock();
        defer c.mutex.unlock();
        return c.heads[@intFromEnum(queue)] < c.queues[@intFromEnum(queue)].items.len;
    }
};

test "a request has the size, the opcode, and the padded string" {
    const gpa = std.testing.allocator;
    var fds: [2]i32 = undefined;
    try std.testing.expect(!Conn.isErr(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    defer _ = linux.close(fds[1]);
    const c = try Conn.fromFd(gpa, fds[0]);
    defer c.deinit();
    const id = try c.newObject(5, .main, 0);
    try std.testing.expectEqual(@as(u32, 2), id);
    try c.send(id, 2, .{Str{ .s = "abc" }});
    try c.flush();
    var buf: [64]u8 = undefined;
    const n = linux.read(fds[1], &buf, buf.len);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, buf[0..4], .little));
    try std.testing.expectEqual(@as(u32, 16 << 16 | 2), std.mem.readInt(u32, buf[4..8], .little));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, buf[8..12], .little));
    try std.testing.expectEqualSlices(u8, "abc\x00", buf[12..16]);
}

test "an event goes to the queue of its object, and delete_id frees the id" {
    const gpa = std.testing.allocator;
    var fds: [2]i32 = undefined;
    try std.testing.expect(!Conn.isErr(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &fds)));
    defer _ = linux.close(fds[1]);
    const c = try Conn.fromFd(gpa, fds[0]);
    defer c.deinit();
    const a = try c.newObject(7, .main, 0);
    const b = try c.newObject(8, .input, 0);
    // Event 3 of b with one uint, event 0 of a with no argument, delete_id of a.
    var msg: [36]u8 = undefined;
    std.mem.writeInt(u32, msg[0..4], b, .little);
    std.mem.writeInt(u32, msg[4..8], 12 << 16 | 3, .little);
    std.mem.writeInt(u32, msg[8..12], 99, .little);
    std.mem.writeInt(u32, msg[12..16], a, .little);
    std.mem.writeInt(u32, msg[16..20], 8 << 16 | 0, .little);
    std.mem.writeInt(u32, msg[20..24], 1, .little);
    std.mem.writeInt(u32, msg[24..28], 12 << 16 | 1, .little);
    std.mem.writeInt(u32, msg[28..32], a, .little);
    _ = linux.write(fds[1], &msg, 32);
    c.destroyed(a);
    const got = try c.read();
    try std.testing.expectEqual(@as(u2, 2), got);
    const e = c.next(.input).?;
    defer c.release(e);
    var args = e.args();
    try std.testing.expectEqual(@as(u16, 8), e.iface);
    try std.testing.expectEqual(@as(u32, 99), args.uint());
    try std.testing.expect(c.next(.main) == null);
    try std.testing.expectEqual(a, try c.newObject(9, .main, 0));
}
