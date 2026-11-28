//! The Authenticode signature of a Windows program, on any host, for
//! `ztk bundle --sign-cert` (ztk#59).
//!
//! `signtool` exists only on Windows and needs the Windows SDK, so this
//! file signs a program with the Zig standard library alone. The steps:
//!
//! 1. `digest` gives the SHA-256 hash of the image: each byte of the file
//!    except the `CheckSum` field of the optional header, the entry of
//!    the certificate table in the data directories, and a certificate
//!    table at the end of the file. The file counts as padded with zero
//!    bytes to a multiple of 8.
//! 2. `signedData` makes the PKCS #7 SignedData. Its content is an
//!    `SpcIndirectDataContent` with the hash. The one signer has three
//!    signed attributes: the content type, an empty `SpcSpOpusInfo`, and
//!    the SHA-256 hash of the content. The signature is over the DER form
//!    of the set of the attributes: ECDSA with SHA-256 for a P-256 or a
//!    P-384 key, and RSA PKCS #1 v1.5 with SHA-256 for an RSA key of 4,096
//!    bits or less. The certificates of the PEM file go in as they are,
//!    and the first one is the certificate of the signer.
//! 3. `sign` appends the `WIN_CERTIFICATE` table (revision 0x0200, type
//!    2) after the padding, writes its offset and its size in the data
//!    directory, and sets the checksum of the file.
//!
//! The key is a PEM file with no password: PKCS #8 (`PRIVATE KEY`), SEC 1
//! (`EC PRIVATE KEY`), or PKCS #1 (`RSA PRIVATE KEY`). `sign` checks that
//! the key is the key of the first certificate.
//!
//! The signature has no timestamp, so Windows accepts it only while the
//! certificate is valid. An RSA signature uses the modular power of
//! `std.crypto.ff` with the private exponent and no blinding.
//!
//! The layouts follow the Authenticode description of Microsoft, PKCS #7
//! (RFC 2315), PKCS #1 (RFC 8017), and X.509 (RFC 5280):
//! docs/references/authenticode.md.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const ecdsa = std.crypto.sign.ecdsa;
const P256 = ecdsa.Ecdsa(std.crypto.ecc.P256, Sha256);
const P384 = ecdsa.Ecdsa(std.crypto.ecc.P384, Sha256);
const Rsa = std.crypto.ff.Modulus(4096);

pub const Error = error{ NotPe, BadPem, BadCertificate, BadKey, EncryptedKey, UnsupportedKey, KeyMismatch } || Allocator.Error;

// The object identifiers, as the bytes of their DER value.
const oid_signed_data = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x07, 0x02 };
const oid_sha256 = [_]u8{ 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
const oid_spc_indirect_data = [_]u8{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04 };
const oid_spc_sp_opus_info = [_]u8{ 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x0C };
const oid_content_type = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03 };
const oid_message_digest = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04 };
const oid_rsa = [_]u8{ 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
const oid_ecdsa_sha256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02 };
const oid_ec_public_key = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
const oid_p256 = [_]u8{ 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07 };
const oid_p384 = [_]u8{ 0x2B, 0x81, 0x04, 0x00, 0x22 };

/// `SpcAttributeTypeAndOptionalValue` of a PE image: the type
/// SPC_PE_IMAGE_DATA (1.3.6.1.4.1.311.2.1.15), no flags, and an empty
/// file link.
const spc_pe_image_data = [_]u8{ 0x30, 0x17, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x0F, 0x30, 0x09, 0x03, 0x01, 0x00, 0xA0, 0x04, 0xA2, 0x02, 0x80, 0x00 };

/// `DigestInfo` of SHA-256 with no hash, for PKCS #1 v1.5.
const digest_info_sha256 = [_]u8{ 0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20 };

// ---- The image ----

/// The offsets of the fields of a PE file that the signature needs.
const Layout = struct {
    /// The `CheckSum` field, 4 bytes.
    checksum: usize,
    /// The entry of the certificate table, 8 bytes: an offset in the file
    /// and a size.
    cert_dir: usize,
    /// The end of the image: the start of the certificate table, or the
    /// end of the file.
    end: usize,
};

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn layout(pe: []const u8) Error!Layout {
    if (pe.len < 0x40 or pe[0] != 'M' or pe[1] != 'Z') return error.NotPe;
    const nt: usize = rd32(pe, 0x3c);
    if (nt + 24 + 2 > pe.len or !std.mem.eql(u8, pe[nt..][0..4], "PE\x00\x00")) return error.NotPe;
    const opt = nt + 24;
    // PE32 has its data directories at 96, and PE32+ at 112.
    const dirs: usize = switch (rd16(pe, opt)) {
        0x10b => opt + 96,
        0x20b => opt + 112,
        else => return error.NotPe,
    };
    if (dirs + 5 * 8 > pe.len or rd32(pe, dirs - 4) < 5) return error.NotPe;
    const cert_dir = dirs + 4 * 8;
    const at: usize = rd32(pe, cert_dir);
    const size: usize = rd32(pe, cert_dir + 4);
    var end = pe.len;
    if (at != 0 or size != 0) {
        // The table is the last part of the file.
        if (at < cert_dir + 8 or at + size != pe.len) return error.NotPe;
        end = at;
    }
    return .{ .checksum = opt + 64, .cert_dir = cert_dir, .end = end };
}

/// The Authenticode hash of a PE file, with or without a signature.
pub fn digest(pe: []const u8) Error![Sha256.digest_length]u8 {
    const l = try layout(pe);
    var h = Sha256.init(.{});
    h.update(pe[0..l.checksum]);
    h.update(pe[l.checksum + 4 .. l.cert_dir]);
    h.update(pe[l.cert_dir + 8 .. l.end]);
    const zeros: [8]u8 = @splat(0);
    h.update(zeros[0 .. (8 - l.end % 8) % 8]);
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

/// The checksum of a PE file: the sum of its 16-bit words with the
/// `CheckSum` field as zero, folded to 16 bits, plus the length.
fn checksum(b: []const u8, field: usize) u32 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i + 1 < b.len) : (i += 2) {
        if (i == field or i == field + 2) continue;
        sum += rd16(b, i);
        sum = (sum & 0xffff) + (sum >> 16);
    }
    if (i < b.len) sum += b[i];
    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(sum + b.len);
}

// ---- DER ----

/// One element of DER: its tag, its value, and the whole element.
const Tlv = struct { tag: u8, value: []const u8, all: []const u8 };

/// Reads the elements of a DER value in order.
const Reader = struct {
    b: []const u8,
    pos: usize = 0,

    fn next(r: *Reader) error{BadDer}!Tlv {
        const start = r.pos;
        if (r.b.len - r.pos < 2) return error.BadDer;
        const tag = r.b[r.pos];
        var len: usize = r.b[r.pos + 1];
        r.pos += 2;
        if (len & 0x80 != 0) {
            const n = len & 0x7f;
            if (n == 0 or n > 4 or r.b.len - r.pos < n) return error.BadDer;
            len = 0;
            for (r.b[r.pos..][0..n]) |c| len = len << 8 | c;
            r.pos += n;
        }
        if (r.b.len - r.pos < len) return error.BadDer;
        r.pos += len;
        return .{ .tag = tag, .value = r.b[r.pos - len .. r.pos], .all = r.b[start..r.pos] };
    }

    /// The next element, which has the tag `tag`.
    fn expect(r: *Reader, tag: u8) error{BadDer}!Tlv {
        const e = try r.next();
        if (e.tag != tag) return error.BadDer;
        return e;
    }
};

/// A DER element with the tag and the parts of its value, in memory of
/// `a`.
fn tlv(a: Allocator, tag: u8, parts: []const []const u8) Allocator.Error![]u8 {
    var len: usize = 0;
    for (parts) |p| len += p.len;
    var head: [6]u8 = undefined;
    head[0] = tag;
    var n: usize = 2;
    if (len < 0x80) {
        head[1] = @intCast(len);
    } else {
        var bytes: usize = 1;
        while (len >> @intCast(8 * bytes) != 0) bytes += 1;
        head[1] = 0x80 | @as(u8, @intCast(bytes));
        for (0..bytes) |k| head[2 + k] = @truncate(len >> @intCast(8 * (bytes - 1 - k)));
        n = 2 + bytes;
    }
    const out = try a.alloc(u8, n + len);
    @memcpy(out[0..n], head[0..n]);
    var at = n;
    for (parts) |p| {
        @memcpy(out[at..][0..p.len], p);
        at += p.len;
    }
    return out;
}

/// An INTEGER value with no leading zero byte.
fn unsigned(v: []const u8) []const u8 {
    var s = v;
    while (s.len > 1 and s[0] == 0) s = s[1..];
    return s;
}

// ---- PEM ----

/// One block of a PEM text: its label and its bytes.
pub const Block = struct { label: []const u8, der: []u8 };

/// The blocks of a PEM text, in memory of `a`.
pub fn pemBlocks(a: Allocator, text: []const u8) Error![]Block {
    var out: std.ArrayListUnmanaged(Block) = .empty;
    var rest = text;
    const decoder = std.base64.standard.decoderWithIgnore(" \t\r\n");
    while (std.mem.indexOf(u8, rest, "-----BEGIN ")) |b| {
        rest = rest[b + 11 ..];
        const label_end = std.mem.indexOf(u8, rest, "-----") orelse return error.BadPem;
        const label = rest[0..label_end];
        rest = rest[label_end + 5 ..];
        const body_end = std.mem.indexOf(u8, rest, "-----END ") orelse return error.BadPem;
        const buf = try a.alloc(u8, decoder.calcSizeUpperBound(body_end));
        const n = decoder.decode(buf, rest[0..body_end]) catch return error.BadPem;
        try out.append(a, .{ .label = label, .der = buf[0..n] });
        rest = rest[body_end + 9 ..];
    }
    return out.toOwnedSlice(a);
}

// ---- The key ----

pub const Key = union(enum) {
    p256: [32]u8,
    p384: [48]u8,
    /// The modulus and the private exponent, big endian with no leading
    /// zero byte.
    rsa: struct { n: []const u8, d: []const u8 },
};

/// The private key of a PEM text. The slices of an RSA key are in memory
/// of `a`.
pub fn parseKey(a: Allocator, text: []const u8) Error!Key {
    for (try pemBlocks(a, text)) |b| {
        if (std.mem.eql(u8, b.label, "ENCRYPTED PRIVATE KEY")) return error.EncryptedKey;
        if (std.mem.eql(u8, b.label, "PRIVATE KEY")) return pkcs8(b.der) catch |e| return keyError(e);
        if (std.mem.eql(u8, b.label, "EC PRIVATE KEY")) return sec1(b.der, null) catch |e| return keyError(e);
        if (std.mem.eql(u8, b.label, "RSA PRIVATE KEY")) return pkcs1(b.der) catch |e| return keyError(e);
    }
    return error.BadKey;
}

fn keyError(e: anyerror) Error {
    return switch (e) {
        error.UnsupportedKey => error.UnsupportedKey,
        else => error.BadKey,
    };
}

/// PKCS #8: `SEQUENCE { version, SEQUENCE { algorithm, parameters },
/// OCTET STRING key }`.
fn pkcs8(der: []const u8) !Key {
    var top: Reader = .{ .b = der };
    var r: Reader = .{ .b = (try top.expect(0x30)).value };
    _ = try r.expect(0x02);
    var alg: Reader = .{ .b = (try r.expect(0x30)).value };
    const oid = (try alg.expect(0x06)).value;
    const inner = (try r.expect(0x04)).value;
    if (std.mem.eql(u8, oid, &oid_rsa)) return pkcs1(inner);
    if (std.mem.eql(u8, oid, &oid_ec_public_key)) return sec1(inner, (try alg.expect(0x06)).value);
    return error.UnsupportedKey;
}

/// SEC 1: `SEQUENCE { version, OCTET STRING key, [0] curve, [1] public }`.
/// PKCS #8 gives the curve in `curve`.
fn sec1(der: []const u8, curve: ?[]const u8) !Key {
    var top: Reader = .{ .b = der };
    var r: Reader = .{ .b = (try top.expect(0x30)).value };
    _ = try r.expect(0x02);
    const secret = unsigned((try r.expect(0x04)).value);
    var oid = curve;
    while (oid == null and r.pos < r.b.len) {
        const e = try r.next();
        if (e.tag != 0xA0) continue;
        var p: Reader = .{ .b = e.value };
        oid = (try p.expect(0x06)).value;
    }
    const c = oid orelse return error.BadKey;
    if (std.mem.eql(u8, c, &oid_p256)) {
        if (secret.len > 32) return error.BadKey;
        var k: [32]u8 = @splat(0);
        @memcpy(k[32 - secret.len ..], secret);
        return .{ .p256 = k };
    }
    if (std.mem.eql(u8, c, &oid_p384)) {
        if (secret.len > 48) return error.BadKey;
        var k: [48]u8 = @splat(0);
        @memcpy(k[48 - secret.len ..], secret);
        return .{ .p384 = k };
    }
    return error.UnsupportedKey;
}

/// PKCS #1: `SEQUENCE { version, n, e, d, ... }`.
fn pkcs1(der: []const u8) !Key {
    var top: Reader = .{ .b = der };
    var r: Reader = .{ .b = (try top.expect(0x30)).value };
    _ = try r.expect(0x02);
    const n = unsigned((try r.expect(0x02)).value);
    _ = try r.expect(0x02);
    const d = unsigned((try r.expect(0x02)).value);
    if (n.len < 128 or n.len > 512) return error.UnsupportedKey;
    return .{ .rsa = .{ .n = n, .d = d } };
}

/// The public key of `key` as the certificate has it: the point of an
/// EC key as `04 X Y`, or the modulus of an RSA key.
fn publicOf(a: Allocator, key: Key) Error![]const u8 {
    switch (key) {
        .p256 => |k| {
            const kp = P256.KeyPair.fromSecretKey(P256.SecretKey.fromBytes(k) catch return error.BadKey) catch return error.BadKey;
            return a.dupe(u8, &kp.public_key.toUncompressedSec1());
        },
        .p384 => |k| {
            const kp = P384.KeyPair.fromSecretKey(P384.SecretKey.fromBytes(k) catch return error.BadKey) catch return error.BadKey;
            return a.dupe(u8, &kp.public_key.toUncompressedSec1());
        },
        .rsa => |k| return k.n,
    }
}

/// The signature of `msg` with SHA-256: the DER form of an ECDSA
/// signature, or the bytes of an RSA PKCS #1 v1.5 signature.
pub fn signBytes(a: Allocator, key: Key, msg: []const u8) Error![]u8 {
    switch (key) {
        .p256 => |k| {
            const kp = P256.KeyPair.fromSecretKey(P256.SecretKey.fromBytes(k) catch return error.BadKey) catch return error.BadKey;
            const sig = kp.sign(msg, null) catch return error.BadKey;
            var buf: [P256.Signature.der_encoded_length_max]u8 = undefined;
            return a.dupe(u8, sig.toDer(&buf));
        },
        .p384 => |k| {
            const kp = P384.KeyPair.fromSecretKey(P384.SecretKey.fromBytes(k) catch return error.BadKey) catch return error.BadKey;
            const sig = kp.sign(msg, null) catch return error.BadKey;
            var buf: [P384.Signature.der_encoded_length_max]u8 = undefined;
            return a.dupe(u8, sig.toDer(&buf));
        },
        .rsa => |k| {
            // EM = 00 01 FF ... FF 00 DigestInfo hash.
            const em = try a.alloc(u8, k.n.len);
            const tail = digest_info_sha256.len + Sha256.digest_length;
            if (em.len < tail + 11) return error.UnsupportedKey;
            @memset(em, 0xff);
            em[0] = 0;
            em[1] = 1;
            em[em.len - tail - 1] = 0;
            @memcpy(em[em.len - tail ..][0..digest_info_sha256.len], &digest_info_sha256);
            Sha256.hash(msg, em[em.len - Sha256.digest_length ..][0..Sha256.digest_length], .{});
            const m = Rsa.fromBytes(k.n, .big) catch return error.BadKey;
            const x = Rsa.Fe.fromBytes(m, em, .big) catch return error.BadKey;
            const s = m.powWithEncodedExponent(x, k.d, .big) catch return error.BadKey;
            s.toBytes(em, .big) catch return error.BadKey;
            return em;
        },
    }
}

// ---- The certificate ----

/// The parts of a certificate that a signer names: the issuer and the
/// serial number as DER elements, and the public key.
const Cert = struct { issuer: []const u8, serial: []const u8, public: []const u8 };

fn parseCert(der: []const u8) error{BadDer}!Cert {
    var top: Reader = .{ .b = der };
    var c: Reader = .{ .b = (try top.expect(0x30)).value };
    var tbs: Reader = .{ .b = (try c.expect(0x30)).value };
    var e = try tbs.next();
    // The version is optional.
    if (e.tag == 0xA0) e = try tbs.next();
    if (e.tag != 0x02) return error.BadDer;
    const serial = e.all;
    _ = try tbs.expect(0x30);
    const issuer = (try tbs.expect(0x30)).all;
    _ = try tbs.expect(0x30);
    _ = try tbs.expect(0x30);
    var spki: Reader = .{ .b = (try tbs.expect(0x30)).value };
    var alg: Reader = .{ .b = (try spki.expect(0x30)).value };
    const oid = (try alg.expect(0x06)).value;
    const bits = (try spki.expect(0x03)).value;
    if (bits.len < 2) return error.BadDer;
    var public = bits[1..];
    if (std.mem.eql(u8, oid, &oid_rsa)) {
        var rk: Reader = .{ .b = public };
        var seq: Reader = .{ .b = (try rk.expect(0x30)).value };
        public = unsigned((try seq.expect(0x02)).value);
    }
    return .{ .issuer = issuer, .serial = serial, .public = public };
}

// ---- The signature ----

fn lessBytes(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

/// The PKCS #7 SignedData of Authenticode for an image hash, in memory of
/// `a`, which is an arena of the caller. `certs` has the certificate of
/// the signer first.
pub fn signedData(a: Allocator, image_hash: [Sha256.digest_length]u8, certs: []const []const u8, key: Key) Error![]u8 {
    if (certs.len == 0) return error.BadCertificate;
    const cert = parseCert(certs[0]) catch return error.BadCertificate;
    if (!std.mem.eql(u8, cert.public, try publicOf(a, key))) return error.KeyMismatch;

    const null_der = [_]u8{ 0x05, 0x00 };
    const sha256_alg = try tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_sha256}), &null_der });
    // SpcIndirectDataContent: the image data, then the DigestInfo of the
    // hash. The hash of the signer covers the value with no tag.
    const digest_info = try tlv(a, 0x30, &.{ sha256_alg, try tlv(a, 0x04, &.{&image_hash}) });
    const content = try std.mem.concat(a, u8, &.{ &spc_pe_image_data, digest_info });
    var content_hash: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(content, &content_hash, .{});
    const indirect_oid = try tlv(a, 0x06, &.{&oid_spc_indirect_data});
    const content_info = try tlv(a, 0x30, &.{ indirect_oid, try tlv(a, 0xA0, &.{try tlv(a, 0x30, &.{content})}) });

    // The signed attributes, in the order of their DER forms.
    var attrs = [3][]const u8{
        try tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_content_type}), try tlv(a, 0x31, &.{indirect_oid}) }),
        try tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_spc_sp_opus_info}), try tlv(a, 0x31, &.{&[_]u8{ 0x30, 0x00 }}) }),
        try tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_message_digest}), try tlv(a, 0x31, &.{try tlv(a, 0x04, &.{&content_hash})}) }),
    };
    std.mem.sort([]const u8, &attrs, {}, lessBytes);
    // The signature covers the attributes as a SET, and the signer has
    // them with the tag [0].
    const signature = try signBytes(a, key, try tlv(a, 0x31, &attrs));
    const sig_alg = switch (key) {
        .rsa => try tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_rsa}), &null_der }),
        else => try tlv(a, 0x30, &.{try tlv(a, 0x06, &.{&oid_ecdsa_sha256})}),
    };
    const one = [_]u8{ 0x02, 0x01, 0x01 };
    const signer = try tlv(a, 0x30, &.{
        &one,
        try tlv(a, 0x30, &.{ cert.issuer, cert.serial }),
        sha256_alg,
        try tlv(a, 0xA0, &attrs),
        sig_alg,
        try tlv(a, 0x04, &.{signature}),
    });
    const signed = try tlv(a, 0x30, &.{
        &one,
        try tlv(a, 0x31, &.{sha256_alg}),
        content_info,
        try tlv(a, 0xA0, certs),
        try tlv(a, 0x31, &.{signer}),
    });
    return tlv(a, 0x30, &.{ try tlv(a, 0x06, &.{&oid_signed_data}), try tlv(a, 0xA0, &.{signed}) });
}

/// A copy of a PE file with a new Authenticode signature, in memory of
/// `gpa`. A signature that the file has goes away. `cert_pem` has the
/// certificate of the signer first and then the other certificates of
/// its chain, and `key_pem` has the private key.
pub fn sign(gpa: Allocator, pe: []const u8, cert_pem: []const u8, key_pem: []const u8) Error![]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layout(pe);
    var certs: std.ArrayListUnmanaged([]const u8) = .empty;
    for (try pemBlocks(a, cert_pem)) |b| {
        if (std.mem.eql(u8, b.label, "CERTIFICATE")) try certs.append(a, b.der);
    }
    if (certs.items.len == 0) return error.BadCertificate;
    const key = try parseKey(a, key_pem);
    const p7 = try signedData(a, try digest(pe), certs.items, key);

    const image = std.mem.alignForward(usize, l.end, 8);
    const table = std.mem.alignForward(usize, 8 + p7.len, 8);
    const out = try gpa.alloc(u8, image + table);
    @memset(out, 0);
    @memcpy(out[0..l.end], pe[0..l.end]);
    // WIN_CERTIFICATE: the length, the revision 0x0200, and the type 2
    // (PKCS #7 SignedData).
    std.mem.writeInt(u32, out[image..][0..4], @intCast(table), .little);
    std.mem.writeInt(u16, out[image + 4 ..][0..2], 0x0200, .little);
    std.mem.writeInt(u16, out[image + 6 ..][0..2], 0x0002, .little);
    @memcpy(out[image + 8 ..][0..p7.len], p7);
    std.mem.writeInt(u32, out[l.cert_dir..][0..4], @intCast(image), .little);
    std.mem.writeInt(u32, out[l.cert_dir + 4 ..][0..4], @intCast(table), .little);
    std.mem.writeInt(u32, out[l.checksum..][0..4], checksum(out, l.checksum), .little);
    return out;
}

/// The text of an error of `sign` for a person.
pub fn describe(e: Error) []const u8 {
    return switch (e) {
        error.NotPe => "the file is not a Windows program, or its certificate table is not at its end",
        error.BadPem => "a PEM block has no end or bad base64 text",
        error.BadCertificate => "the certificate file has no certificate that this signer reads",
        error.BadKey => "the key file has no private key that this signer reads",
        error.EncryptedKey => "the key has a password; give a key file with no password",
        error.UnsupportedKey => "the key is not a P-256 key, a P-384 key, or an RSA key of 1,024 to 4,096 bits",
        error.KeyMismatch => "the key is not the key of the first certificate",
        error.OutOfMemory => "out of memory",
    };
}
