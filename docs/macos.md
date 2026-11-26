# On macOS

ztk has a native backend for macOS 13 and later. It uses AppKit for the windows, the input, and the menus, and Metal for the drawing, with no layer between ztk and macOS.

## Build and run

Install [Zig 0.16.0](https://ziglang.org/download/) and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/beetlebugorg/ztk
cd ztk
zig build -Doptimize=ReleaseFast       # makes zig-out/bin/ztk
zig-out/bin/ztk examples/demo.tcl      # opens a window
```

`ztk --headless` works as on the other systems, with no window.

## Make an app

`ztk bundle` makes a macOS app, a folder `Name.app`, from a main script and its files:

```sh
ztk bundle -o Notes.app --icon notes.png --id org.example.notes notes.tcl lib/ images/
open Notes.app
```

The app has a copy of the ztk program, the scripts and the files in `Contents/Resources/app`, an icon set made from the PNG, and an `Info.plist`. The app runs its main script with the folder `app` as the root of the file commands. Each word of the command line of the app is an argument of the script, so a flag cannot add a capability.

| Option | Meaning |
|---|---|
| `-o Name.app` | The app to write. The name of the app comes from it. |
| `--name NAME` | Another name for the app. |
| `--id ID` | The bundle identifier, such as `org.example.notes`. The default is `org.ztk.` and the name. |
| `--version V` | The version. The default is 1.0. |
| `--icon FILE.png` | The icon: a square 8-bit RGBA PNG, 1,024 pixels or less. |
| `--allow CAPS` | The capabilities of the app, as for `ztk --allow`. The default is `file,channels`. |
| `--menu-bar-only` | No Dock icon and no menu bar (`LSUIElement`), for an app that lives in a tray icon. |
| `--runner FILE` | The macOS ztk program to copy. The default is the program that runs the command. |
| `--no-sign` | Leave the app unsigned. |

A bundle can come from Linux or Windows too: give a macOS ztk with `--runner`. Windows has no mode bits for files, so an app from Windows needs `chmod +x Name.app/Contents/MacOS/Name` on the Mac. On macOS, `ztk bundle` signs the app with an ad hoc signature. Run the app on the Mac that made it, or sign it as below before you give it to others.

## Sign and notarize an app

An app for other people needs a Developer ID signature and a notarization from Apple, or macOS refuses to open it. Each step needs an Apple Developer account.

1. Sign the app with your Developer ID and the hardened runtime:

   ```sh
   codesign --force --options runtime --timestamp \
     --sign "Developer ID Application: Your Name (TEAMID)" Notes.app
   ```

   A ztk program that runs scripts with the JIT of ztcl needs the entitlement `com.apple.security.cs.allow-jit` as well: give a plist with it to `--entitlements`.

2. Send a zip of the app to Apple, wait for the answer, and staple the ticket to the app:

   ```sh
   ditto -c -k --keepParent Notes.app Notes.zip
   xcrun notarytool submit Notes.zip --keychain-profile notary --wait
   xcrun stapler staple Notes.app
   ```

   `xcrun notarytool store-credentials notary` saves the profile one time.

The design and the plan are in [docs/dev/macos.md](https://github.com/beetlebugorg/ztk/blob/main/docs/dev/macos.md).
