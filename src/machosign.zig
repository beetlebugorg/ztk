//! The ad hoc signature of a macOS app folder, on any host.
//!
//! `codesign` exists only on macOS, so `ztk bundle` signs an app from
//! Linux and Windows with this file. The steps:
//!
//! 1. `codeResources` makes `Contents/_CodeSignature/CodeResources`: a
//!    plist with the SHA-1 and the SHA-256 hash of each file below
//!    `Contents` except the program, `Info.plist`, and `PkgInfo`, and the
//!    default rules of an app.
//! 2. `sign` gives a copy of the program (a thin 64-bit Mach-O file) with
//!    a new signature in place of the signature of the linker. The
//!    signature is a SuperBlob with a CodeDirectory, an empty
//!    requirement set, the entitlements as XML, and the entitlements as
//!    DER. The CodeDirectory (version 0x20400) has the SHA-256 hash of
//!    each 4 KiB page up to the signature and 7 special slots: the hash of
//!    `Info.plist` (-1), of the requirements (-2), of `CodeResources`
//!    (-3), of the XML entitlements (-5), and of the DER entitlements
//!    (-7). Slots -4 and -6 are zero. The flags are `CS_ADHOC`.
//!
//! The layouts follow the code signing notes of Apple and the signer of
//! `ztcl build` (docs/references/macos-signature.md). The numbers of a
//! signature are big endian, and the numbers of the load commands are
//! little endian. The code uses byte slices only.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Sha1 = std.crypto.hash.Sha1;

pub const Error = error{ BadMachO, FatMachO } || Allocator.Error;

const lc_segment_64 = 0x19;
const lc_code_signature = 0x1d;
const page = 4096;

const magic_superblob = 0xfade0cc0;
const magic_codedirectory = 0xfade0c02;
const magic_requirements = 0xfade0c01;
const magic_entitlements = 0xfade7171;
const magic_der_entitlements = 0xfade7172;

const slot_codedirectory = 0;
const slot_requirements = 2;
const slot_entitlements = 5;
const slot_der_entitlements = 7;
const special_slots = 7;

fn rd32(b: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, b[i..][0..4], .little);
}

fn rd64(b: []const u8, i: usize) u64 {
    return std.mem.readInt(u64, b[i..][0..8], .little);
}

fn wr32(b: []u8, i: usize, v: u32) void {
    std.mem.writeInt(u32, b[i..][0..4], v, .little);
}

fn wr64(b: []u8, i: usize, v: u64) void {
    std.mem.writeInt(u64, b[i..][0..8], v, .little);
}

fn be32(b: []u8, i: usize, v: u32) void {
    std.mem.writeInt(u32, b[i..][0..4], v, .big);
}

const Layout = struct {
    linkedit: usize,
    text_off: u64,
    text_size: u64,
    sig: usize,
};

/// The load commands that the signature changes. The program must have
/// an `LC_CODE_SIGNATURE`: the linker of Zig and of Apple adds one for
/// arm64, and for x86_64 with `-headerpad` space.
fn layout(bin: []const u8) Error!Layout {
    if (bin.len >= 4 and std.mem.readInt(u32, bin[0..4], .big) == 0xcafebabe) return error.FatMachO;
    if (bin.len < 32 or rd32(bin, 0) != 0xfeedfacf) return error.BadMachO;
    const ncmds = rd32(bin, 16);
    const end = 32 + @as(usize, rd32(bin, 20));
    if (end > bin.len) return error.BadMachO;
    var l: Layout = .{ .linkedit = 0, .text_off = 0, .text_size = 0, .sig = 0 };
    var o: usize = 32;
    for (0..ncmds) |_| {
        if (o + 8 > end) return error.BadMachO;
        const cmd = rd32(bin, o);
        const cs = rd32(bin, o + 4);
        if (cs < 8 or o + cs > end) return error.BadMachO;
        if (cmd == lc_segment_64) {
            if (cs < 72) return error.BadMachO;
            const name = std.mem.sliceTo(bin[o + 8 .. o + 24], 0);
            if (std.mem.eql(u8, name, "__LINKEDIT")) l.linkedit = o;
            if (std.mem.eql(u8, name, "__TEXT")) {
                l.text_off = rd64(bin, o + 40);
                l.text_size = rd64(bin, o + 48);
            }
        }
        if (cmd == lc_code_signature) l.sig = o;
        o += cs;
    }
    if (l.linkedit == 0 or l.sig == 0) return error.BadMachO;
    return l;
}

/// The inputs of a signature.
pub const Input = struct {
    /// The identifier, the bundle identifier of the app.
    ident: []const u8,
    /// The bytes of `Contents/Info.plist`.
    info_plist: []const u8,
    /// The bytes of `Contents/_CodeSignature/CodeResources`.
    code_resources: []const u8,
    /// The entitlements: keys with the value true.
    entitlements: []const []const u8,
};

/// The entitlements as an XML plist.
pub fn entitlementsXml(a: Allocator, keys: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, plist_head);
    for (keys) |k| {
        try out.appendSlice(a, "\t<key>");
        try out.appendSlice(a, k);
        try out.appendSlice(a, "</key>\n\t<true/>\n");
    }
    try out.appendSlice(a, "</dict>\n</plist>\n");
    return out.toOwnedSlice(a);
}

const plist_head =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\
;

/// A DER header: the tag and the length of `len` bytes of content.
fn derHead(a: Allocator, out: *std.ArrayList(u8), tag: u8, len: usize) !void {
    try out.append(a, tag);
    if (len < 0x80) {
        try out.append(a, @intCast(len));
    } else if (len < 0x100) {
        try out.appendSlice(a, &.{ 0x81, @intCast(len) });
    } else {
        try out.appendSlice(a, &.{ 0x82, @intCast(len >> 8), @intCast(len & 0xff) });
    }
}

fn derLen(len: usize) usize {
    return 2 + @as(usize, if (len < 0x80) 0 else if (len < 0x100) 1 else 2);
}

/// The entitlements in the DER form of Apple: `[APPLICATION 16] {
/// INTEGER 1, [CONTEXT 16] { SEQUENCE { UTF8String key, BOOLEAN true
/// } ... } }`. The keys are in sorted order.
pub fn entitlementsDer(a: Allocator, keys: []const []const u8) ![]u8 {
    const sorted = try a.dupe([]const u8, keys);
    defer a.free(sorted);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    var dict: std.ArrayList(u8) = .empty;
    defer dict.deinit(a);
    for (sorted) |k| {
        const inner = derLen(k.len) + k.len + 3;
        try derHead(a, &dict, 0x30, inner);
        try derHead(a, &dict, 0x0c, k.len);
        try dict.appendSlice(a, k);
        try dict.appendSlice(a, &.{ 0x01, 0x01, 0xff });
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    const body = 3 + derLen(dict.items.len) + dict.items.len;
    try derHead(a, &out, 0x70, body);
    try out.appendSlice(a, &.{ 0x02, 0x01, 0x01 });
    try derHead(a, &out, 0xb0, dict.items.len);
    try out.appendSlice(a, dict.items);
    return out.toOwnedSlice(a);
}

/// A blob: the magic, the length, and the data.
fn blob(a: Allocator, magic: u32, data: []const u8) ![]u8 {
    const b = try a.alloc(u8, 8 + data.len);
    be32(b, 0, magic);
    be32(b, 4, @intCast(b.len));
    @memcpy(b[8..], data);
    return b;
}

/// A copy of the program `bin` with an ad hoc signature for an app.
pub fn sign(a: Allocator, bin: []const u8, in: Input) Error![]u8 {
    const l = try layout(bin);
    const le_off = rd64(bin, l.linkedit + 40);
    const cut: u64 = rd32(bin, l.sig + 8);
    if (cut < le_off or cut > bin.len) return error.BadMachO;
    const s_off = std.mem.alignForward(u64, cut, 16);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const ar = arena_state.allocator();
    const reqs = try blob(ar, magic_requirements, &.{ 0, 0, 0, 0 });
    const ents = try blob(ar, magic_entitlements, try entitlementsXml(ar, in.entitlements));
    const der = try blob(ar, magic_der_entitlements, try entitlementsDer(ar, in.entitlements));

    const n_pages = (s_off + page - 1) / page;
    const ident_len = in.ident.len + 1;
    const hash_off = 88 + ident_len + special_slots * 32;
    const cd_len = hash_off + n_pages * 32;
    const n_blobs = 4;
    const index_len = 12 + n_blobs * 8;
    const sig_len = index_len + cd_len + reqs.len + ents.len + der.len;
    const total = s_off + sig_len;
    if (total > std.math.maxInt(u32)) return error.BadMachO;

    const out = try a.alloc(u8, @intCast(total));
    errdefer a.free(out);
    @memset(out, 0);
    @memcpy(out[0..@intCast(cut)], bin[0..@intCast(cut)]);
    // __LINKEDIT ends at the end of the new signature.
    const le_size = total - le_off;
    wr64(out, l.linkedit + 48, le_size);
    wr64(out, l.linkedit + 32, std.mem.alignForward(u64, le_size, 0x4000));
    wr32(out, l.sig + 8, @intCast(s_off));
    wr32(out, l.sig + 12, @intCast(sig_len));

    const sig = out[@intCast(s_off)..];
    be32(sig, 0, magic_superblob);
    be32(sig, 4, @intCast(sig_len));
    be32(sig, 8, n_blobs);
    var at: usize = index_len;
    const order = [_]struct { u32, usize }{
        .{ slot_codedirectory, cd_len },
        .{ slot_requirements, reqs.len },
        .{ slot_entitlements, ents.len },
        .{ slot_der_entitlements, der.len },
    };
    var offsets: [n_blobs]usize = undefined;
    for (order, 0..) |o, k| {
        be32(sig, 12 + k * 8, o[0]);
        be32(sig, 16 + k * 8, @intCast(at));
        offsets[k] = at;
        at += o[1];
    }
    @memcpy(sig[offsets[1]..][0..reqs.len], reqs);
    @memcpy(sig[offsets[2]..][0..ents.len], ents);
    @memcpy(sig[offsets[3]..][0..der.len], der);

    const cd = sig[offsets[0]..][0..cd_len];
    be32(cd, 0, magic_codedirectory);
    be32(cd, 4, @intCast(cd_len));
    be32(cd, 8, 0x20400);
    be32(cd, 12, 0x2); // CS_ADHOC
    be32(cd, 16, @intCast(hash_off));
    be32(cd, 20, 88); // identOffset
    be32(cd, 24, special_slots);
    be32(cd, 28, @intCast(n_pages));
    be32(cd, 32, @intCast(s_off)); // codeLimit
    cd[36] = 32; // hashSize
    cd[37] = 2; // CS_HASHTYPE_SHA256
    cd[38] = 0; // platform
    cd[39] = 12; // log2 of the page size
    // spare2, scatterOffset, teamOffset, spare3, and codeLimit64 are 0.
    std.mem.writeInt(u64, cd[64..72], l.text_off, .big); // execSegBase
    std.mem.writeInt(u64, cd[72..80], l.text_size, .big); // execSegLimit
    std.mem.writeInt(u64, cd[80..88], 1, .big); // CS_EXECSEG_MAIN_BINARY
    @memcpy(cd[88..][0..in.ident.len], in.ident);
    // The special slots: slot -n is at hash_off - 32 * n.
    const specials = [_]struct { usize, []const u8 }{
        .{ 1, in.info_plist },
        .{ 2, reqs },
        .{ 3, in.code_resources },
        .{ 5, ents },
        .{ 7, der },
    };
    for (specials) |s| Sha256.hash(s[1], cd[hash_off - 32 * s[0] ..][0..32], .{});
    for (0..@intCast(n_pages)) |i| {
        const start = i * page;
        const end = @min(start + page, @as(usize, @intCast(s_off)));
        Sha256.hash(out[start..end], cd[hash_off + i * 32 ..][0..32], .{});
    }
    return out;
}

/// One file of the app for `CodeResources`: its path below `Contents`
/// with `/` and its bytes.
pub const Resource = struct { path: []const u8, data: []const u8 };

/// The text of `CodeResources` for the files of an app. The caller
/// leaves out the program, `Info.plist`, `PkgInfo`, and
/// `_CodeSignature`. `files` lists only the files below `Resources/`, as
/// the rules of version 1 cover only them.
pub fn codeResources(a: Allocator, res: []const Resource) ![]u8 {
    const sorted = try a.dupe(Resource, res);
    defer a.free(sorted);
    std.mem.sort(Resource, sorted, {}, struct {
        fn lt(_: void, x: Resource, y: Resource) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    var out: std.Io.Writer.Allocating = .init(a);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(plist_head);
    try w.writeAll("\t<key>files</key>\n\t<dict>\n");
    for (sorted) |r| {
        if (!std.mem.startsWith(u8, r.path, "Resources/")) continue;
        var h1: [20]u8 = undefined;
        Sha1.hash(r.data, &h1, .{});
        try w.writeAll("\t\t<key>");
        try xmlText(w, r.path);
        try w.writeAll("</key>\n\t\t<data>\n\t\t");
        try base64(w, &h1);
        try w.writeAll("\n\t\t</data>\n");
    }
    try w.writeAll("\t</dict>\n\t<key>files2</key>\n\t<dict>\n");
    for (sorted) |r| {
        var h1: [20]u8 = undefined;
        var h2: [32]u8 = undefined;
        Sha1.hash(r.data, &h1, .{});
        Sha256.hash(r.data, &h2, .{});
        try w.writeAll("\t\t<key>");
        try xmlText(w, r.path);
        try w.writeAll("</key>\n\t\t<dict>\n\t\t\t<key>hash</key>\n\t\t\t<data>\n\t\t\t");
        try base64(w, &h1);
        try w.writeAll("\n\t\t\t</data>\n\t\t\t<key>hash2</key>\n\t\t\t<data>\n\t\t\t");
        try base64(w, &h2);
        try w.writeAll("\n\t\t\t</data>\n\t\t</dict>\n");
    }
    try w.writeAll("\t</dict>\n");
    try w.writeAll(rules);
    try w.writeAll("</dict>\n</plist>\n");
    return out.toOwnedSlice();
}

fn base64(w: *std.Io.Writer, bytes: []const u8) !void {
    var buf: [64]u8 = undefined;
    try w.writeAll(std.base64.standard.Encoder.encode(&buf, bytes));
}

fn xmlText(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(c),
    };
}

/// The default rules of an app bundle.
const rules =
    \\    <key>rules</key>
    \\    <dict>
    \\        <key>^Resources/</key>
    \\        <true/>
    \\        <key>^Resources/.*\.lproj/</key>
    \\        <dict>
    \\            <key>optional</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>1000</real>
    \\        </dict>
    \\        <key>^Resources/.*\.lproj/locversion.plist$</key>
    \\        <dict>
    \\            <key>omit</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>1100</real>
    \\        </dict>
    \\        <key>^Resources/Base\.lproj/</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>1010</real>
    \\        </dict>
    \\        <key>^version.plist$</key>
    \\        <true/>
    \\    </dict>
    \\    <key>rules2</key>
    \\    <dict>
    \\        <key>.*\.dSYM($|/)</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>11</real>
    \\        </dict>
    \\        <key>^(.*/)?\.DS_Store$</key>
    \\        <dict>
    \\            <key>omit</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>2000</real>
    \\        </dict>
    \\        <key>^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/</key>
    \\        <dict>
    \\            <key>nested</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>10</real>
    \\        </dict>
    \\        <key>^.*</key>
    \\        <true/>
    \\        <key>^Info\.plist$</key>
    \\        <dict>
    \\            <key>omit</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>20</real>
    \\        </dict>
    \\        <key>^PkgInfo$</key>
    \\        <dict>
    \\            <key>omit</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>20</real>
    \\        </dict>
    \\        <key>^Resources/</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>20</real>
    \\        </dict>
    \\        <key>^Resources/.*\.lproj/</key>
    \\        <dict>
    \\            <key>optional</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>1000</real>
    \\        </dict>
    \\        <key>^Resources/.*\.lproj/locversion.plist$</key>
    \\        <dict>
    \\            <key>omit</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>1100</real>
    \\        </dict>
    \\        <key>^Resources/Base\.lproj/</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>1010</real>
    \\        </dict>
    \\        <key>^[^/]+$</key>
    \\        <dict>
    \\            <key>nested</key>
    \\            <true/>
    \\            <key>weight</key>
    \\            <real>10</real>
    \\        </dict>
    \\        <key>^embedded\.provisionprofile$</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>20</real>
    \\        </dict>
    \\        <key>^version\.plist$</key>
    \\        <dict>
    \\            <key>weight</key>
    \\            <real>20</real>
    \\        </dict>
    \\    </dict>
    \\
;

const t = std.testing;

test "machosign: the DER entitlements of allow-jit" {
    const der = try entitlementsDer(t.allocator, &.{"com.apple.security.cs.allow-jit"});
    defer t.allocator.free(der);
    const key = "com.apple.security.cs.allow-jit";
    // 70 L 02 01 01 b0 L 30 L 0c L key 01 01 ff
    try t.expectEqual(@as(u8, 0x70), der[0]);
    try t.expectEqual(@as(usize, der.len - 2), der[1]);
    try t.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x01, 0xb0, @intCast(key.len + 7), 0x30, @intCast(key.len + 5), 0x0c, @intCast(key.len) }, der[2..11]);
    try t.expectEqualStrings(key, der[11..][0..key.len]);
    try t.expectEqualSlices(u8, &.{ 0x01, 0x01, 0xff }, der[der.len - 3 ..]);
}

test "machosign: a signature with special slots" {
    const a = t.allocator;
    // A small Mach-O: __TEXT, __LINKEDIT at 0x2000, and a signature of
    // the linker at 0x2080.
    var bin: [0x2100]u8 = @splat(0);
    wr32(&bin, 0, 0xfeedfacf);
    wr32(&bin, 16, 3);
    const text = 32;
    wr32(&bin, text, lc_segment_64);
    wr32(&bin, text + 4, 72);
    @memcpy(bin[text + 8 ..][0..6], "__TEXT");
    wr64(&bin, text + 48, 0x2000);
    const le = text + 72;
    wr32(&bin, le, lc_segment_64);
    wr32(&bin, le + 4, 72);
    @memcpy(bin[le + 8 ..][0..10], "__LINKEDIT");
    wr64(&bin, le + 40, 0x2000);
    wr64(&bin, le + 48, 0x100);
    const sc = le + 72;
    wr32(&bin, sc, lc_code_signature);
    wr32(&bin, sc + 4, 16);
    wr32(&bin, sc + 8, 0x2080);
    wr32(&bin, sc + 12, 0x80);
    wr32(&bin, 20, 72 + 72 + 16);
    const out = try sign(a, &bin, .{ .ident = "org.ztk.demo", .info_plist = "PLIST", .code_resources = "RES", .entitlements = &.{"com.apple.security.cs.allow-jit"} });
    defer a.free(out);
    const s_off = rd32(out, sc + 8);
    try t.expectEqual(@as(u32, 0x2080), s_off);
    try t.expectEqual(@as(usize, out.len - s_off), rd32(out, sc + 12));
    try t.expectEqual(@as(u64, out.len - 0x2000), rd64(out, le + 48));
    const sig = out[s_off..];
    try t.expectEqual(@as(u32, magic_superblob), std.mem.readInt(u32, sig[0..4], .big));
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, sig[8..12], .big));
    const cd = sig[std.mem.readInt(u32, sig[16..20], .big)..];
    try t.expectEqual(@as(u32, magic_codedirectory), std.mem.readInt(u32, cd[0..4], .big));
    try t.expectEqual(@as(u32, 7), std.mem.readInt(u32, cd[24..28], .big));
    const hash_off = std.mem.readInt(u32, cd[16..20], .big);
    var h: [32]u8 = undefined;
    Sha256.hash("PLIST", &h, .{});
    try t.expectEqualSlices(u8, &h, cd[hash_off - 32 ..][0..32]);
    Sha256.hash("RES", &h, .{});
    try t.expectEqualSlices(u8, &h, cd[hash_off - 96 ..][0..32]);
    // Slot -4 is zero.
    try t.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), cd[hash_off - 128 ..][0..32]);
    // The hash of the last page, up to the signature.
    Sha256.hash(out[0x2000..s_off], &h, .{});
    try t.expectEqualSlices(u8, &h, cd[hash_off + 2 * 32 ..][0..32]);
    // The entitlements blob and its hash in slot -5.
    const ent_at = std.mem.readInt(u32, sig[32..36], .big);
    const ent_len = std.mem.readInt(u32, sig[ent_at + 4 ..][0..4], .big);
    Sha256.hash(sig[ent_at..][0..ent_len], &h, .{});
    try t.expectEqualSlices(u8, &h, cd[hash_off - 160 ..][0..32]);
    try t.expectError(error.FatMachO, sign(a, "\xca\xfe\xba\xbe....", .{ .ident = "x", .info_plist = "", .code_resources = "", .entitlements = &.{} }));
}

test "machosign: CodeResources lists the resources with both hashes" {
    const text = try codeResources(t.allocator, &.{
        .{ .path = "Resources/app/demo.tcl", .data = "abc" },
        .{ .path = "Resources/ztk.conf", .data = "" },
    });
    defer t.allocator.free(text);
    // The SHA-1 of "abc" in base64.
    try t.expect(std.mem.indexOf(u8, text, "<key>Resources/app/demo.tcl</key>\n\t\t<data>\n\t\tqZk+NkcGgWq6PiVxeFDCbJzQ2J0=") != null);
    try t.expect(std.mem.indexOf(u8, text, "<key>hash2</key>") != null);
    try t.expect(std.mem.indexOf(u8, text, "<key>rules2</key>") != null);
}
