# macOS signature

`ztk bundle` signs a macOS app on Linux and Windows with `src/machosign.zig`. This page lists the sources of the formats.

| Source | License | Use |
|---|---|---|
| Apple, TN2206 "macOS Code Signing In Depth" | Documentation | The parts of a signed bundle: `_CodeSignature/CodeResources`, the sealed resources, and the nested code in `MacOS/` |
| Apple, TN3126 "Inside Code Signing: Hashes" | Documentation | The CodeDirectory, the page hashes, the special slots of `Info.plist`, the requirements, the resources, and the entitlements |
| Apple, TN3125 "Inside Code Signing: Provisioning Profiles" and "Diagnosing Issues with Entitlements" | Documentation | The XML and the DER forms of the entitlements, and `com.apple.security.cs.allow-jit` |
| `src/macho.zig` of ztcl | BSD-2-Clause | The load commands that a new signature changes, and the CodeDirectory of version 0x20400 |

No code of Apple, of `codesign`, or of another signer went into ztk. `CodeResources` has the default rules of an app bundle. The job "Show a window of the cross build (macOS)" of `ci.yml` checks an app that Linux signed with `codesign --verify --deep --strict` on a macOS runner.
