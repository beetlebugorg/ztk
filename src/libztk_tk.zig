//! libtk8.6 of libztk: the names of the Tk functions that libztk has.
//! Each name is a jump to the function with the prefix `ztk_` in
//! libtcl8.6 of libztk (`src/libztk.zig`), which has ztcl and ztk. The
//! jump keeps the arguments and the return of the caller as they are, so
//! this file needs no type of a function. A program that links libtk8.6
//! and libtcl8.6 records both, as with the libraries of Tcl and Tk.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const builtin = @import("builtin");

/// The same list as `tk_names` of src/libztk.zig.
const names = .{ "Tk_Init", "Tk_MainWindow", "Tk_MainLoop", "Tk_CreateWindow", "Tk_GetNumMainWindows", "Tk_FindPhoto", "Tk_PhotoPutBlock", "Tk_PhotoPutZoomedBlock", "Tk_PhotoGetImage", "Tk_PhotoBlank", "Tk_PhotoGetSize", "Tk_PhotoSetSize", "Tk_PhotoExpand" };

fn jump(comptime name: []const u8) *const fn () callconv(.naked) noreturn {
    const S = struct {
        fn f() callconv(.naked) noreturn {
            // Mach-O names have a leading underscore. ELF calls go through the PLT.
            const macho = builtin.target.ofmt == .macho;
            const sym = (if (macho) "_ztk_" else "ztk_") ++ name;
            switch (builtin.cpu.arch) {
                .x86_64 => asm volatile ("jmp " ++ sym ++ (if (macho) "" else "@PLT")),
                .aarch64 => asm volatile ("b " ++ sym),
                else => @compileError("libztk: no jump for this CPU"),
            }
        }
    };
    return &S.f;
}

comptime {
    for (names) |nm| @export(jump(nm), .{ .name = nm });
}
