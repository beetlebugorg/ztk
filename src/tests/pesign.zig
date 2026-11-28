//! Tests of `pesign.zig`. The keys and the certificates of
//! `tests/pesign/` are test data from `openssl req -x509`: self-signed,
//! with the name `ztk-test-signer`, and of no use outside these tests.
//!
//! The first test signs a small file with the headers of a PE32+ image
//! and reads the result back. The second test runs on Windows: it signs a
//! copy of the test program and gives it to `WinVerifyTrust`. Windows
//! trusts no test certificate, so the answer for a good signature is
//! CERT_E_UNTRUSTEDROOT. A bad hash gives TRUST_E_BAD_DIGEST, and a file
//! with no signature gives TRUST_E_NOSIGNATURE.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const builtin = @import("builtin");
const pesign = @import("../pesign.zig");
const t = std.testing;

const Pair = struct { name: []const u8, cert: []const u8, key: []const u8 };
const pairs = [_]Pair{
    .{ .name = "p256", .cert = @embedFile("pesign/p256-cert.pem"), .key = @embedFile("pesign/p256-key.pem") },
    .{ .name = "p384", .cert = @embedFile("pesign/p384-cert.pem"), .key = @embedFile("pesign/p384-key.pem") },
    .{ .name = "rsa", .cert = @embedFile("pesign/rsa-cert.pem"), .key = @embedFile("pesign/rsa-key.pem") },
    .{ .name = "rsa-pkcs1", .cert = @embedFile("pesign/rsa-cert.pem"), .key = @embedFile("pesign/rsa1-key.pem") },
};

/// A file of 1,029 bytes with the headers of a PE32+ image and 16 empty
/// data directories. The length is no multiple of 8.
fn smallImage() [1029]u8 {
    var b: [1029]u8 = undefined;
    for (&b, 0..) |*c, i| c.* = @truncate(i *% 7 +% 3);
    @memset(b[0..0x200], 0);
    b[0] = 'M';
    b[1] = 'Z';
    std.mem.writeInt(u32, b[0x3c..][0..4], 0x80, .little);
    @memcpy(b[0x80..][0..4], "PE\x00\x00");
    const opt = 0x80 + 24;
    std.mem.writeInt(u16, b[opt..][0..2], 0x20b, .little);
    std.mem.writeInt(u32, b[opt + 108 ..][0..4], 16, .little);
    return b;
}

test "pesign: a signed image has the certificate table at its end, and the hash does not change" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = smallImage();
    const hash = try pesign.digest(&image);
    const cert_dir = 0x80 + 24 + 112 + 4 * 8;
    const checksum_at = 0x80 + 24 + 64;
    for (pairs) |p| {
        const out = try pesign.sign(a, &image, p.cert, p.key);
        // The image, the padding to 1,032 bytes, and then the table.
        // The bytes before the checksum field stay, and the field has the
        // checksum of the file.
        try t.expectEqualSlices(u8, image[0..checksum_at], out[0..checksum_at]);
        try t.expectEqual(@import("../peres.zig").checksum(out, checksum_at), std.mem.readInt(u32, out[checksum_at..][0..4], .little));
        try t.expectEqual(@as(u32, 1032), std.mem.readInt(u32, out[cert_dir..][0..4], .little));
        const size = std.mem.readInt(u32, out[cert_dir + 4 ..][0..4], .little);
        try t.expectEqual(out.len, 1032 + size);
        try t.expectEqual(@as(usize, 0), size % 8);
        try t.expectEqual(size, std.mem.readInt(u32, out[1032..][0..4], .little));
        try t.expectEqual(@as(u16, 0x0200), std.mem.readInt(u16, out[1036..][0..2], .little));
        try t.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[1038..][0..2], .little));
        // The SignedData starts with a SEQUENCE and has the hash of the image.
        try t.expectEqual(@as(u8, 0x30), out[1040]);
        try t.expect(std.mem.indexOf(u8, out[1040..], &hash) != null);
        // The hash of the signed file is the hash of the file before.
        try t.expectEqualSlices(u8, &hash, &(try pesign.digest(out)));
        // A second signature replaces the first.
        const again = try pesign.sign(a, out, p.cert, p.key);
        try t.expectEqualSlices(u8, &hash, &(try pesign.digest(again)));
        try t.expectEqual(@as(u32, 1032), std.mem.readInt(u32, again[cert_dir..][0..4], .little));
        if (std.mem.startsWith(u8, p.name, "rsa")) try t.expectEqualSlices(u8, out, again);
    }
    // A change of one byte of the image changes the hash.
    var other = image;
    other[900] ^= 1;
    try t.expect(!std.mem.eql(u8, &hash, &(try pesign.digest(&other))));
}

test "pesign: the errors of a key, a certificate, and a file" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const image = smallImage();
    try t.expectError(error.KeyMismatch, pesign.sign(a, &image, pairs[2].cert, pairs[0].key));
    try t.expectError(error.KeyMismatch, pesign.sign(a, &image, pairs[0].cert, pairs[1].key));
    try t.expectError(error.BadCertificate, pesign.sign(a, &image, pairs[0].key, pairs[0].key));
    try t.expectError(error.BadKey, pesign.sign(a, &image, pairs[0].cert, pairs[0].cert));
    try t.expectError(error.EncryptedKey, pesign.sign(a, &image, pairs[0].cert, "-----BEGIN ENCRYPTED PRIVATE KEY-----\nAAAA\n-----END ENCRYPTED PRIVATE KEY-----\n"));
    try t.expectError(error.BadPem, pesign.sign(a, &image, "-----BEGIN CERTIFICATE-----\nAAAA", pairs[0].key));
    try t.expectError(error.NotPe, pesign.sign(a, "not a program", pairs[0].cert, pairs[0].key));
    try t.expectError(error.NotPe, pesign.digest(image[0..0x90]));
}

const WinTrust = struct {
    const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
    const FileInfo = extern struct {
        size: u32 = @sizeOf(FileInfo),
        path: [*:0]const u16,
        file: ?*anyopaque = null,
        subject: ?*const Guid = null,
    };
    const Data = extern struct {
        size: u32 = @sizeOf(Data),
        policy: ?*anyopaque = null,
        sip: ?*anyopaque = null,
        /// WTD_UI_NONE
        ui: u32 = 2,
        /// WTD_REVOKE_NONE
        revocation: u32 = 0,
        /// WTD_CHOICE_FILE
        choice: u32 = 1,
        file: *const FileInfo,
        state_action: u32 = 0,
        state: ?*anyopaque = null,
        url: ?[*:0]const u16 = null,
        /// WTD_CACHE_ONLY_URL_RETRIEVAL: no request to the network.
        flags: u32 = 0x1000,
        ui_context: u32 = 0,
        settings: ?*anyopaque = null,
    };
    /// WINTRUST_ACTION_GENERIC_VERIFY_V2
    const action: Guid = .{ .a = 0x00AAC56B, .b = 0xCD44, .c = 0x11d0, .d = .{ 0x8C, 0xC2, 0x00, 0xC0, 0x4F, 0xC2, 0x95, 0xEE } };
    extern "wintrust" fn WinVerifyTrust(hwnd: ?*anyopaque, action: *const Guid, data: *Data) callconv(.winapi) i32;

    fn verify(a: std.mem.Allocator, path: []const u8) !u32 {
        const wpath = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        const info: FileInfo = .{ .path = wpath };
        var data: Data = .{ .file = &info };
        return @bitCast(WinVerifyTrust(null, &action, &data));
    }
};

test "pesign: WinVerifyTrust reads the signature of a signed copy of the test program" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cert_e_untrustedroot: u32 = 0x800B0109;
    const trust_e_nosignature: u32 = 0x800B0100;
    const trust_e_bad_digest: u32 = 0x80096010;
    const self_path = try std.process.executablePathAlloc(t.io, a);
    const exe = try std.Io.Dir.cwd().readFileAlloc(t.io, self_path, a, .limited(512 << 20));
    const cwd = std.Io.Dir.cwd();
    const path = ".zig-cache/pesign-test.exe";
    defer cwd.deleteFile(t.io, path) catch {};
    try cwd.writeFile(t.io, .{ .sub_path = path, .data = exe });
    try t.expectEqual(trust_e_nosignature, try WinTrust.verify(a, path));
    for (pairs) |p| {
        const out = try pesign.sign(a, exe, p.cert, p.key);
        try cwd.writeFile(t.io, .{ .sub_path = path, .data = out });
        const got = try WinTrust.verify(a, path);
        if (got != cert_e_untrustedroot) std.debug.print("{s}: WinVerifyTrust gave 0x{x}\n", .{ p.name, got });
        try t.expectEqual(cert_e_untrustedroot, got);
        // One changed byte of the code: the hash of the signature is wrong.
        out[0x400] ^= 1;
        try cwd.writeFile(t.io, .{ .sub_path = path, .data = out });
        try t.expectEqual(trust_e_bad_digest, try WinTrust.verify(a, path));
    }
}
