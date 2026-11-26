//! The parser of the byte stream of a terminal. It is the state machine
//! of the DEC ANSI parser that Paul Williams describes at vt100.net, with
//! the states ground, escape, escape intermediate, CSI entry, CSI param,
//! CSI intermediate, CSI ignore, OSC string, DCS string, and the string
//! of SOS, PM, and APC. The DCS states are one state: the parser drops
//! the body of a DCS string, because the terminal has no DCS function.
//!
//! In the ground state the bytes from 0x80 are UTF-8. The decoder gives
//! U+FFFD for a bad sequence and starts again at the byte that broke it.
//! CAN and SUB end each sequence. ESC starts a new sequence from each
//! state, and in a string ESC `\` is the string terminator (ST). BEL
//! also ends an OSC string, as in xterm.
//!
//! A CSI sequence has at most 16 parameters. Each parameter is a number
//! up to 65535 or empty (0). A `:` between two parameters marks the
//! second as a sub-parameter of the first, for the SGR forms
//! `38:2::r:g:b`. The parser gives each action to a handler: `print`,
//! `execute` (a C0 control), `esc`, `csi`, and `osc`.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub const max_params = 16;
/// The longest OSC string that the parser keeps. The rest is dropped.
pub const max_osc = 4096;

pub const Csi = struct {
    params: [max_params]u16 = @splat(0),
    /// Bit k is set when parameter k follows a `:`.
    sub: u16 = 0,
    count: u8 = 0,
    /// The private marker: `?`, `>`, `<`, `=`, or 0.
    private: u8 = 0,
    /// The intermediate byte (0x20 to 0x2f), or 0.
    inter: u8 = 0,
    final: u8 = 0,

    /// Parameter `k`, or `default` when it is absent or 0.
    pub fn get(c: *const Csi, k: usize, default: u16) u16 {
        if (k >= c.count or c.params[k] == 0) return default;
        return c.params[k];
    }
};

const State = enum { ground, escape, esc_inter, csi_entry, csi_param, csi_inter, csi_ignore, osc, dcs, sos };

pub const Parser = struct {
    state: State = .ground,
    csi: Csi = .{},
    /// The intermediate of an ESC sequence.
    esc_inter: u8 = 0,
    /// True after ESC inside a string, to find ESC `\`.
    string_esc: bool = false,
    osc_buf: [max_osc]u8 = undefined,
    osc_len: usize = 0,
    /// The UTF-8 decoder: the code point so far and the bytes left.
    utf_cp: u21 = 0,
    utf_left: u3 = 0,
    /// True while the current number of the CSI has a digit.
    digit: bool = false,

    /// Feeds bytes. `h` has the methods `print(u21)`, `execute(u8)`,
    /// `esc(inter, final)`, `csi(*const Csi)`, and `osc([]const u8)`.
    pub fn feed(p: *Parser, bytes: []const u8, h: anytype) void {
        for (bytes) |b| p.byte(b, h);
    }

    fn byte(p: *Parser, b: u8, h: anytype) void {
        // A UTF-8 sequence in the ground state.
        if (p.utf_left > 0) {
            if (b & 0xc0 == 0x80) {
                p.utf_cp = (p.utf_cp << 6) | @as(u21, b & 0x3f);
                p.utf_left -= 1;
                if (p.utf_left == 0) h.print(p.utf_cp);
                return;
            }
            p.utf_left = 0;
            h.print(0xfffd);
        }
        switch (b) {
            0x18, 0x1a => {
                p.state = .ground;
                return;
            },
            0x1b => {
                if (p.state == .osc or p.state == .dcs or p.state == .sos) {
                    p.string_esc = true;
                    return;
                }
                p.enterEscape();
                return;
            },
            else => {},
        }
        switch (p.state) {
            .ground => p.ground(b, h),
            .escape => p.escape(b, h),
            .esc_inter => {
                if (b < 0x20) return h.execute(b);
                if (b < 0x30) {
                    p.esc_inter = b;
                    return;
                }
                if (b < 0x7f) h.esc(p.esc_inter, b);
                p.state = .ground;
            },
            .csi_entry, .csi_param => p.csiByte(b, h),
            .csi_inter => {
                if (b < 0x20) return h.execute(b);
                if (b < 0x30) {
                    p.csi.inter = b;
                } else if (b < 0x40) {
                    p.state = .csi_ignore;
                } else if (b < 0x7f) {
                    p.dispatchCsi(b, h);
                }
            },
            .csi_ignore => {
                if (b < 0x20) return h.execute(b);
                if (b >= 0x40 and b < 0x7f) p.state = .ground;
            },
            .osc => {
                if (p.string_esc) {
                    p.string_esc = false;
                    h.osc(p.osc_buf[0..p.osc_len]);
                    p.state = .ground;
                    // ESC then a byte other than `\` starts a new sequence.
                    if (b != '\\') {
                        p.enterEscape();
                        p.escape(b, h);
                    }
                    return;
                }
                if (b == 0x07) {
                    h.osc(p.osc_buf[0..p.osc_len]);
                    p.state = .ground;
                    return;
                }
                if (b < 0x20) return;
                if (p.osc_len < max_osc) {
                    p.osc_buf[p.osc_len] = b;
                    p.osc_len += 1;
                }
            },
            .dcs, .sos => {
                if (p.string_esc) {
                    p.string_esc = false;
                    p.state = .ground;
                    if (b != '\\') {
                        p.enterEscape();
                        p.escape(b, h);
                    }
                }
            },
        }
    }

    fn enterEscape(p: *Parser) void {
        p.state = .escape;
        p.esc_inter = 0;
        p.string_esc = false;
    }

    fn ground(p: *Parser, b: u8, h: anytype) void {
        if (b < 0x20 or b == 0x7f) {
            if (b != 0x7f) h.execute(b);
            return;
        }
        if (b < 0x80) return h.print(b);
        if (b & 0xe0 == 0xc0 and b >= 0xc2) {
            p.utf_cp = b & 0x1f;
            p.utf_left = 1;
        } else if (b & 0xf0 == 0xe0) {
            p.utf_cp = b & 0x0f;
            p.utf_left = 2;
        } else if (b & 0xf8 == 0xf0 and b <= 0xf4) {
            p.utf_cp = b & 0x07;
            p.utf_left = 3;
        } else h.print(0xfffd);
    }

    fn escape(p: *Parser, b: u8, h: anytype) void {
        if (b < 0x20) return h.execute(b);
        switch (b) {
            '[' => {
                p.state = .csi_entry;
                p.csi = .{};
                p.digit = false;
            },
            ']' => {
                p.state = .osc;
                p.osc_len = 0;
            },
            'P' => p.state = .dcs,
            'X', '^', '_' => p.state = .sos,
            0x20...0x2f => {
                p.esc_inter = b;
                p.state = .esc_inter;
            },
            0x30...0x4f, 0x51...0x57, 0x59, 0x5a, 0x5c, 0x60...0x7e => {
                h.esc(0, b);
                p.state = .ground;
            },
            else => p.state = .ground,
        }
    }

    fn csiByte(p: *Parser, b: u8, h: anytype) void {
        const c = &p.csi;
        switch (b) {
            0x00...0x1f => h.execute(b),
            '0'...'9' => {
                p.state = .csi_param;
                if (c.count == 0) c.count = 1;
                const k = c.count - 1;
                const v = @as(u32, c.params[k]) * 10 + (b - '0');
                c.params[k] = @intCast(@min(v, 65535));
                p.digit = true;
            },
            ';', ':' => {
                p.state = .csi_param;
                if (c.count == 0) c.count = 1;
                if (c.count >= max_params) {
                    p.state = .csi_ignore;
                    return;
                }
                if (b == ':') c.sub |= @as(u16, 1) << @intCast(c.count);
                c.count += 1;
                p.digit = false;
            },
            '<', '=', '>', '?' => {
                if (p.state == .csi_entry) c.private = b else p.state = .csi_ignore;
            },
            0x20...0x2f => {
                c.inter = b;
                p.state = .csi_inter;
            },
            0x40...0x7e => p.dispatchCsi(b, h),
            else => p.state = .csi_ignore,
        }
    }

    fn dispatchCsi(p: *Parser, b: u8, h: anytype) void {
        p.csi.final = b;
        p.state = .ground;
        h.csi(&p.csi);
    }
};

const Log = struct {
    out: std.ArrayList(u8) = .empty,
    a: std.mem.Allocator,
    fn print(l: *Log, cp: u21) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch 0;
        l.out.appendSlice(l.a, buf[0..n]) catch {};
    }
    fn execute(l: *Log, b: u8) void {
        l.out.print(l.a, "<x{d}>", .{b}) catch {};
    }
    fn esc(l: *Log, inter: u8, final: u8) void {
        l.out.print(l.a, "<e{c}{c}>", .{ if (inter == 0) '_' else inter, final }) catch {};
    }
    fn csi(l: *Log, c: *const Csi) void {
        l.out.print(l.a, "<c{c}", .{if (c.private == 0) '_' else c.private}) catch {};
        for (0..c.count) |k| l.out.print(l.a, "{s}{d}", .{ if (c.sub & (@as(u16, 1) << @intCast(k)) != 0) ":" else " ", c.params[k] }) catch {};
        l.out.print(l.a, " {c}>", .{c.final}) catch {};
    }
    fn osc(l: *Log, s: []const u8) void {
        l.out.print(l.a, "<o{s}>", .{s}) catch {};
    }
};

fn parsed(input: []const u8) ![]u8 {
    var p: Parser = .{};
    var l: Log = .{ .a = std.testing.allocator };
    p.feed(input, &l);
    return l.out.toOwnedSlice(std.testing.allocator);
}

fn expectParse(input: []const u8, want: []const u8) !void {
    const got = try parsed(input);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(want, got);
}

test "the parser splits text, controls, and sequences" {
    try expectParse("ab\r\n", "ab<x13><x10>");
    try expectParse("\x1b[1;31mX", "<c_ 1 31 m>X");
    try expectParse("\x1b[?1049h", "<c? 1049 h>");
    try expectParse("\x1b[38:2::10:20:30m", "<c_ 38:2:0:10:20:30 m>");
    try expectParse("\x1b[H", "<c_ H>");
    try expectParse("\x1b]0;title\x07z", "<o0;title>z");
    try expectParse("\x1b]2;t\x1b\\z", "<o2;t>z");
    try expectParse("\x1b(0q\x1b(B", "<e(0>q<e(B>");
    try expectParse("\x1b7\x1b8", "<e_7><e_8>");
    try expectParse("\x1bP1$qm\x1b\\ok", "ok");
    try expectParse("\x1b[1\x18x", "x");
    try expectParse("\x1b[ q", "<c_ q>");
}

test "the parser decodes UTF-8 and marks bad bytes" {
    try expectParse("\xc3\xa9\xe2\x94\x80\xf0\x9f\x98\x80", "é─😀");
    try expectParse("\xc3x", "\u{fffd}x");
    try expectParse("\xff", "\u{fffd}");
}
