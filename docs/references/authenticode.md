# Authenticode

`ztk bundle --sign-cert` signs a Windows program on each host with `src/pesign.zig`. This page lists the sources of the formats.

| Source | License | Use |
|---|---|---|
| Microsoft, "Windows Authenticode Portable Executable Signature Format" | Documentation | The hash of a PE image, the `WIN_CERTIFICATE` table, `SpcIndirectDataContent`, `SpcPeImageData`, and the signed attributes of the signer |
| Microsoft, "PE Format" | Documentation | The `CheckSum` field, the data directories, and the entry of the certificate table |
| RFC 2315, "PKCS #7: Cryptographic Message Syntax Version 1.5" | IETF Trust | `ContentInfo`, `SignedData`, and `SignerInfo` |
| RFC 8017, "PKCS #1: RSA Cryptography Specifications Version 2.2" | IETF Trust | The EMSA-PKCS1-v1_5 encoding and the `RSAPrivateKey` structure |
| RFC 5208, "PKCS #8", and RFC 5915, "Elliptic Curve Private Key Structure" | IETF Trust | The structures of a private key file |
| RFC 5280, "Internet X.509 Public Key Infrastructure Certificate" | IETF Trust | The issuer, the serial number, and the public key of a certificate |
| The Zig standard library, `std.crypto` | MIT | SHA-256, ECDSA on P-256 and P-384, and the modular power of an RSA signature |

No code of Microsoft, of `signtool`, or of another signer went into ztk. The test "pesign: WinVerifyTrust reads the signature of a signed copy of the test program" gives a signed file to `WinVerifyTrust` of Windows. The keys and the certificates of `src/tests/pesign/` are test data from `openssl req -x509`.
