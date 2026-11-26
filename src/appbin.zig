//! A ztk app in one file: a copy of the `ztk` program with the app as a
//! zip payload, in the form of `ztcl build` (docs/dev/static-build.md of
//! the ztcl repository).
//!
//! The `ztk` program has the slot `ztcl_app_slot` of
//! `ztcl.buildnative`. `build` makes the payload (the files of the app
//! and the manifest `.ztcl/manifest`) and gives it to
//! `buildnative.bundle`, which adds it to a copy of a runtime and writes
//! the offset and the length into the slot of the copy. The runtime of a
//! target is the `ztk` program of that target.
//!
//! At the start, `own` reads the slot of this program. With a payload,
//! `mount` mounts it at `//zipfs:/app` and gives the main script, the
//! capabilities, and the root of the manifest. `payload` and `build` use
//! only byte slices, so the browser build also runs them.
//!
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const Io = std.Io;
const ztcl = @import("ztcl");
const bn = ztcl.buildnative;
const Capability = ztcl.interp.Capability;

pub const File = struct { name: []const u8, data: []const u8 };

pub const Error = error{ NoFiles, Duplicate, BadName, BadCapability } || ztcl.zipwrite.Error;

/// True for a name of the app that stays in the app: relative, with no
/// `..`, `.`, or empty part.
fn safeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/' or std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |p| if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return false;
    return true;
}

fn lessThan(_: void, x: ztcl.zipwrite.Entry, y: ztcl.zipwrite.Entry) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// The zip payload of an app. The first file is the main script. The
/// entries are in the order of their names, so the same files give the
/// same bytes.
pub fn payload(a: std.mem.Allocator, files: []const File, allow: []const u8, root: ?[]const u8) Error![]u8 {
    if (files.len == 0) return error.NoFiles;
    if (allow.len > 0 and Capability.parse(allow) == null) return error.BadCapability;
    var zips: std.ArrayList(ztcl.zipwrite.Entry) = .empty;
    for (files) |f| {
        if (!safeName(f.name)) return error.BadName;
        for (zips.items) |z| if (std.mem.eql(u8, z.name, f.name)) return error.Duplicate;
        try zips.append(a, .{ .name = f.name, .data = f.data });
    }
    const manifest: bn.Manifest = .{ .scripts = &.{files[0].name}, .allow = allow, .root = root };
    try zips.append(a, .{ .name = bn.manifest_name, .data = try manifest.write(a) });
    std.mem.sort(ztcl.zipwrite.Entry, zips.items, {}, lessThan);
    return ztcl.zipwrite.write(a, zips.items, false);
}

/// A copy of `runtime` with the app in it. `ident` is the identifier of
/// the code signature of a Mach-O file.
pub fn build(a: std.mem.Allocator, runtime: []const u8, files: []const File, allow: []const u8, root: ?[]const u8, ident: []const u8) (Error || bn.Error)![]u8 {
    return bn.bundle(a, runtime, try payload(a, files, allow, root), ident);
}

/// The text of an error of `build` for a person.
pub fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.NoFiles => "no main script",
        error.Duplicate => "a file is in the input twice",
        error.BadName => "a file name leaves the app",
        error.BadCapability => "unknown capability",
        error.UnknownFormat => "the runtime is not an ELF, PE, or Mach-O file",
        error.NoSlot => "the runtime has no app slot: use a ztk program of this version",
        error.TwoSlots => "the runtime has two app slots",
        error.AlreadyBundle => "the runtime is an app already",
        error.BadMachO => "a Mach-O file with a form that the build does not read",
        error.NoRoom => "no space for a code signature after the load commands of the runtime",
        error.TooLarge => "the app is too large for a zip file",
        error.OutOfMemory => "out of memory",
        else => @errorName(e),
    };
}

/// The payload of this program, or null for the plain `ztk` program.
pub fn own(io: Io, a: std.mem.Allocator) !?[]const u8 {
    const r = bn.payloadRange() orelse return null;
    const exe = try std.process.executablePathAlloc(io, a);
    const whole = try Io.Dir.cwd().readFileAlloc(io, exe, a, .unlimited);
    if (r.off > whole.len or whole.len - r.off < r.len) return error.PayloadPastEnd;
    return whole[@intCast(r.off)..][0..@intCast(r.len)];
}

/// The start of an app of a payload.
pub const App = struct {
    /// The path of the main script, below `//zipfs:/app/`.
    main: []const u8,
    /// The capabilities of the manifest and `embedded`.
    allow: u32,
    root: ?[]const u8,
};

/// Mounts `bytes` at `//zipfs:/app` in `it` and reads the manifest.
pub fn mount(it: *ztcl.Interp, a: std.mem.Allocator, bytes: []const u8) !App {
    try ztcl.vfs.mountBytes(it, "app", "", bytes);
    const z = &it.vfs.mounts.items[it.vfs.mounts.items.len - 1].z;
    const entry = z.find(bn.manifest_name) orelse return error.NoManifest;
    const m = try bn.Manifest.parse(a, try z.extract(a, entry));
    if (m.scripts.len == 0) return error.NoManifest;
    const bits = if (m.allow.len == 0) 0 else Capability.parse(m.allow) orelse return error.BadCapability;
    return .{
        .main = try std.fmt.allocPrint(a, "//zipfs:/app/{s}", .{m.scripts[0]}),
        .allow = bits | @backingInt(Capability.embedded),
        .root = m.root,
    };
}

const t = std.testing;

test "appbin: a payload has the files and the manifest in name order" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zip = try payload(a, &.{ .{ .name = "main.tcl", .data = "button .b" }, .{ .name = "lib/a.tcl", .data = "set x 1" } }, "file", null);
    const z = try ztcl.zipread.Archive.parse(a, zip);
    try t.expectEqualStrings("script main.tcl\nallow file\n", try z.extract(a, z.find(bn.manifest_name).?));
    try t.expectEqualStrings("set x 1", try z.extract(a, z.find("lib/a.tcl").?));
    try t.expectEqualSlices(u8, zip, try payload(a, &.{ .{ .name = "main.tcl", .data = "button .b" }, .{ .name = "lib/a.tcl", .data = "set x 1" } }, "file", null));
    try t.expectError(error.BadName, payload(a, &.{.{ .name = "../x.tcl", .data = "" }}, "", null));
    try t.expectError(error.Duplicate, payload(a, &.{ .{ .name = "a.tcl", .data = "" }, .{ .name = "a.tcl", .data = "" } }, "", null));
    try t.expectError(error.BadCapability, payload(a, &.{.{ .name = "a.tcl", .data = "" }}, "nope", null));
}

test "appbin: mount gives the main script and adds embedded" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zip = try payload(a, &.{.{ .name = "app.tcl", .data = "set n 1" }}, "", null);
    var it: ztcl.Interp = undefined;
    try it.init(t.allocator);
    defer it.deinit();
    const app = try mount(&it, a, zip);
    try t.expectEqualStrings("//zipfs:/app/app.tcl", app.main);
    try t.expectEqual(@as(u32, @backingInt(Capability.embedded)), app.allow);
    try it.allow(app.allow);
    const v = try it.eval("source //zipfs:/app/app.tcl; set n");
    try t.expectEqualStrings("1", try it.str(v));
}

test "appbin: ztk::style load reads a style sheet of the app" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const zip = try payload(a, &.{ .{ .name = "app.tcl", .data = "" }, .{ .name = "look.css", .data = "Button { color: #ff0000 }" } }, "", null);
    const Harness = @import("testing.zig").Harness;
    var h: Harness = undefined;
    h.render_mode = .inline_draw;
    h.animations = false;
    h.dark = false;
    try h.initWith("//zipfs:/app");
    defer h.deinit();
    const app = try mount(&h.it, a, zip);
    try h.it.allow(app.allow);
    try t.expect(std.mem.startsWith(u8, try h.eval("ztk::style load look.css"), "style"));
}
