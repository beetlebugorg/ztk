# D-Bus and the desktop portals

`src/platform/dbus.zig` is a client of the D-Bus wire protocol, and `src/platform/portal.zig` uses it for the file dialogs of the desktop portal. This page lists the documents that the code follows. The code links no D-Bus library, and the work did not read the source of one.

| Source | License | Use |
|---|---|---|
| D-Bus Specification (freedesktop.org), the sections "Type System", "Message Protocol", "Authentication Protocol", and "Message Bus Specification" | Specification | The marshaling and the alignment of each type, the header and its fields, the SASL lines of `EXTERNAL`, `Hello`, `AddMatch`, `NameHasOwner`, `ListActivatableNames`, and the bus address forms `unix:path=` and `unix:abstract=` |
| `org.freedesktop.portal.FileChooser.xml` and `org.freedesktop.portal.Request.xml` (package `xdg-desktop-portal`, in `/usr/share/dbus-1/interfaces`) | LGPL-2.1 interface description, read as documentation | `OpenFile` and `SaveFile`, their options (`handle_token`, `modal`, `multiple`, `directory`, `filters`, `current_folder`, `current_name`), the results (`uris`, `current_filter`), the path of the `Request` object, and the `Response` signal |
| RFC 8089, "The file URI Scheme" | Specification | The `file://` URIs of the results and their percent encoding |
