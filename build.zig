//! The build of ztk: the module, the `ztk` program, the tests, and the run step.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

/// Compiles one shader with glslc and returns the SPIR-V file. A machine with no `glslc` needs the package `shaderc`.
fn shader(b: *std.Build, stage: []const u8, src: []const u8, out: []const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ "glslc", b.fmt("-fshader-stage={s}", .{stage}), "-o" });
    const spv = run.addOutputFileArg(out);
    run.addFileArg(b.path(src));
    return spv;
}

const Protocol = struct { xml: []const u8, name: []const u8 };

const protocols = [_]Protocol{
    .{ .xml = "stable/xdg-shell/xdg-shell.xml", .name = "xdg-shell" },
    .{ .xml = "unstable/xdg-decoration/xdg-decoration-unstable-v1.xml", .name = "xdg-decoration-unstable-v1" },
    .{ .xml = "stable/viewporter/viewporter.xml", .name = "viewporter" },
    .{ .xml = "staging/fractional-scale/fractional-scale-v1.xml", .name = "fractional-scale-v1" },
    .{ .xml = "stable/tablet/tablet-v2.xml", .name = "tablet-v2" },
    .{ .xml = "staging/cursor-shape/cursor-shape-v1.xml", .name = "cursor-shape-v1" },
};

/// Links the Wayland client library and `xkbcommon`, and compiles the C code that
/// `wayland-scanner` makes from the protocol files of the system. The module
/// `wayland_c` is the translation of `src/platform/wayland_c.h`.
fn addWayland(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    m.link_libc = true;
    m.linkSystemLibrary("wayland-client", .{});
    m.linkSystemLibrary("xkbcommon", .{});
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/platform/wayland_c.h"), .target = target, .optimize = optimize });
    tc.linkSystemLibrary("wayland-client", .{});
    tc.linkSystemLibrary("xkbcommon", .{});
    var code: u8 = 0;
    const dir_raw = b.runAllowFail(&.{ "pkg-config", "--variable=pkgdatadir", "wayland-protocols" }, &code, .ignore) catch "/usr/share/wayland-protocols";
    const dir = std.mem.trim(u8, dir_raw, " \n");
    for (protocols) |p| {
        const xml = b.fmt("{s}/{s}", .{ dir, p.xml });
        const hdr = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xml });
        const hdr_out = hdr.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{p.name}));
        m.addIncludePath(hdr_out.dirname());
        tc.addIncludePath(hdr_out.dirname());
        const src = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml });
        const src_out = src.addOutputFileArg(b.fmt("{s}-protocol.c", .{p.name}));
        m.addCSourceFile(.{ .file = src_out, .flags = &.{} });
    }
    m.addImport("wayland_c", tc.createModule());
}

/// The module `vulkan_c`: the translation of `src/render/vulkan_c.h` with the
/// pinned Vulkan headers.
fn vulkanC(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/render/vulkan_c.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
    return tc.createModule();
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Run only the tests whose name has this text");

    const ztcl_dep = b.dependency("ztcl", .{ .target = target, .optimize = optimize });
    const ztcl = ztcl_dep.module("ztcl");

    // The Wayland, direct, and Vulkan code exists for Linux only.
    const is_linux = target.result.os.tag == .linux;
    const is_macos = target.result.os.tag == .macos;
    const backends = b.option([]const u8, "backends", "The backends to build, separated by commas: wayland, direct, appkit, headless (default: wayland, direct, and headless on Linux, appkit and headless on macOS, headless elsewhere)") orelse
        if (is_linux) "wayland,direct,headless" else if (is_macos) "appkit,headless" else "headless";
    const wayland_on = std.mem.indexOf(u8, backends, "wayland") != null;
    // The AppKit backend links the frameworks through the text stubs in
    // `src/sys/macos-stubs`, so a build on each host has it.
    const appkit_on = is_macos and std.mem.indexOf(u8, backends, "appkit") != null;
    const vulkan_on = b.option(bool, "vulkan", "Build the Vulkan renderer (default: true on Linux)") orelse is_linux;
    const strip = b.option(bool, "strip", "Remove the debug sections from the program");
    const opts = b.addOptions();
    opts.addOptionPathUntracked("repo_root", b.path("."));
    opts.addOption(bool, "vulkan", vulkan_on);
    opts.addOption(bool, "wayland", wayland_on);
    opts.addOption(bool, "appkit", appkit_on);

    const ztk = b.addModule("ztk", .{
        .root_source_file = b.path("src/ztk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    });

    ztk.addOptions("build_options", opts);
    if (vulkan_on) {
        // The Vulkan loader opens at run time. The headers come from a pinned package, and the
        // shaders compile with glslc (package shaderc).
        ztk.link_libc = true;
        ztk.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
        ztk.addImport("vulkan_c", vulkanC(b, target, optimize));
        ztk.addAnonymousImport("quad_vert_spv", .{ .root_source_file = shader(b, "vertex", "src/render/shaders/quad.vert", "quad.vert.spv") });
        ztk.addAnonymousImport("quad_frag_spv", .{ .root_source_file = shader(b, "fragment", "src/render/shaders/quad.frag", "quad.frag.spv") });
    }
    if (appkit_on) {
        ztk.link_libc = true;
        ztk.addLibraryPath(b.path("src/sys/macos-stubs/usr/lib"));
        ztk.addFrameworkPath(b.path("src/sys/macos-stubs/Frameworks"));
        ztk.linkSystemLibrary("objc", .{});
        ztk.linkFramework("Foundation", .{});
        ztk.linkFramework("Metal", .{});
        ztk.linkFramework("QuartzCore", .{});
        ztk.linkFramework("CoreGraphics", .{});
        ztk.linkFramework("AppKit", .{});
    }
    ztk.addAnonymousImport("inter_regular", .{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") });
    ztk.addAnonymousImport("inter_bold", .{ .root_source_file = b.path("assets/fonts/Inter-Bold.ttf") });
    ztk.addAnonymousImport("mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });

    const libc_on = vulkan_on or wayland_on or appkit_on;
    // The self-hosted backend covers x86-64 Linux. Each other target uses LLVM.
    const use_llvm = libc_on or !is_linux or target.result.cpu.arch != .x86_64;
    // Zig links Mach-O files with its own linker.
    const use_lld = use_llvm and target.result.ofmt != .macho;
    if (wayland_on) addWayland(b, ztk, target, optimize);

    const exe = b.addExecutable(.{ .name = "ztk", .use_llvm = use_llvm, .use_lld = use_lld, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = libc_on,
        .imports = &.{
            .{ .name = "ztcl", .module = ztcl },
            .{ .name = "ztk", .module = ztk },
        },
    }) });
    // Space after the load commands, for the code signature that
    // `ztk bundle --target` adds to a Mach-O file.
    if (is_macos) exe.headerpad_size = 0x1000;
    b.installArtifact(exe);

    // The WebAssembly build for the browser: the core, the headless backend, and src/web.zig.
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const wasm_opts = b.addOptions();
        wasm_opts.addOption([]const u8, "repo_root", ".");
        wasm_opts.addOption(bool, "vulkan", false);
        wasm_opts.addOption(bool, "wayland", false);
        const wasm_ztcl = b.dependency("ztcl", .{ .target = wasm_target, .optimize = .fast }).module("ztcl");
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("src/web.zig"),
            .target = wasm_target,
            .optimize = .fast,
            .strip = true,
            .imports = &.{.{ .name = "ztcl", .module = wasm_ztcl }},
        });
        wasm_mod.addOptions("build_options", wasm_opts);
        wasm_mod.addAnonymousImport("inter_regular", .{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") });
        wasm_mod.addAnonymousImport("inter_bold", .{ .root_source_file = b.path("assets/fonts/Inter-Bold.ttf") });
        wasm_mod.addAnonymousImport("mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });
        const wasm = b.addExecutable(.{ .name = "ztk", .root_module = wasm_mod });
        wasm.entry = .disabled;
        wasm.rdynamic = true;
        const wasm_step = b.step("wasm", "Build ztk for the browser into zig-out/web");
        wasm_step.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
        wasm_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("web"), .install_dir = .{ .custom = "web" }, .install_subdir = "" }).step);
        wasm_step.dependOn(&b.addInstallDirectory(.{ .source_dir = b.path("examples"), .install_dir = .{ .custom = "web" }, .install_subdir = "examples", .include_extensions = &.{ ".tcl", ".css" } }).step);
    }

    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run a script: zig build run -- script.tcl").dependOn(&run.step);

    // The benchmark builds in ReleaseFast, whatever the optimize option is.
    const bench_ztcl = b.dependency("ztcl", .{ .target = target, .optimize = .fast }).module("ztcl");
    const bench_ztk = b.createModule(.{
        .root_source_file = b.path("src/ztk.zig"),
        .target = target,
        .optimize = .fast,
        .imports = &.{.{ .name = "ztcl", .module = bench_ztcl }},
    });
    bench_ztk.addOptions("build_options", opts);
    bench_ztk.addAnonymousImport("inter_regular", .{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") });
    bench_ztk.addAnonymousImport("inter_bold", .{ .root_source_file = b.path("assets/fonts/Inter-Bold.ttf") });
    bench_ztk.addAnonymousImport("mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });
    if (vulkan_on) {
        bench_ztk.link_libc = true;
        bench_ztk.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
        bench_ztk.addImport("vulkan_c", vulkanC(b, target, .fast));
        bench_ztk.addAnonymousImport("quad_vert_spv", .{ .root_source_file = shader(b, "vertex", "src/render/shaders/quad.vert", "quad.vert.spv") });
        bench_ztk.addAnonymousImport("quad_frag_spv", .{ .root_source_file = shader(b, "fragment", "src/render/shaders/quad.frag", "quad.frag.spv") });
    }
    if (wayland_on) addWayland(b, bench_ztk, target, .fast);
    const bench = b.addExecutable(.{ .name = "ztk-bench", .use_llvm = use_llvm, .use_lld = use_lld, .root_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .fast,
        .link_libc = libc_on,
        .imports = &.{
            .{ .name = "ztcl", .module = bench_ztcl },
            .{ .name = "ztk", .module = bench_ztk },
        },
    }) });
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    b.step("bench", "Run the benchmark (ReleaseFast)").dependOn(&bench_run.step);

    const tests = b.addTest(.{
        .use_llvm = use_llvm,
        .use_lld = use_lld,
        .root_module = ztk,
        .filters = if (filter) |f| &.{f} else &.{},
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
