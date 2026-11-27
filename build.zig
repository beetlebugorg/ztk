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

/// A static Linux program (musl) opens the Vulkan loader with the ELF
/// loader of `src/sys/elf`, which gives the libraries the glibc functions
/// of `shim.c`.
fn addElfShim(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag != .linux or !target.result.abi.isMusl() or (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64)) return;
    m.addCSourceFile(.{ .file = b.path("src/sys/elf/shim.c"), .flags = &.{ "-std=c11", "-Wall", "-Wno-unused-result" } });
}

/// The module `vulkan_c`: the translation of `src/render/vulkan_c.h` with the
/// pinned Vulkan headers.
fn vulkanC(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/render/vulkan_c.h"), .target = target, .optimize = optimize });
    tc.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
    return tc.createModule();
}

/// The backends of one build of the ztk module, and the Vulkan renderer.
const Config = struct { backends: []const u8, vulkan: bool };

/// The full GUI backend of each platform: Wayland, X11, and the direct
/// backend with Vulkan on Linux, AppKit with Metal on macOS, and Win32
/// with Direct3D 12 on Windows. The Win32 backend has no flag: each
/// Windows build has it.
fn fullConfig(t: std.Target) Config {
    return switch (t.os.tag) {
        .linux => .{ .backends = "wayland,direct,headless", .vulkan = true },
        .macos => .{ .backends = "appkit,headless", .vulkan = false },
        else => .{ .backends = "headless", .vulkan = false },
    };
}

/// The SPIR-V files of the Vulkan renderer. They are the same for each target.
const Shaders = struct { vert: std.Build.LazyPath, frag: std.Build.LazyPath };

/// The ztk module of one target and one configuration, with its ztcl.
const Built = struct {
    ztcl: *std.Build.Module,
    ztk: *std.Build.Module,
    libc: bool,
    use_llvm: bool,
    use_lld: bool,
};

/// `public`: other packages import the module as "ztk".
fn addZtk(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cfg: Config, shaders: Shaders, public: bool) Built {
    const ztcl = b.dependency("ztcl", .{ .target = target, .optimize = optimize }).module("ztcl");
    const is_linux = target.result.os.tag == .linux;
    const is_macos = target.result.os.tag == .macos;
    // The Wayland and X11 code exists for Linux only.
    const wayland_on = is_linux and std.mem.indexOf(u8, cfg.backends, "wayland") != null;
    // The AppKit backend links the frameworks through the text stubs in
    // `src/sys/macos-stubs`, so a build on each host has it.
    const appkit_on = is_macos and std.mem.indexOf(u8, cfg.backends, "appkit") != null;
    const vulkan_on = cfg.vulkan;
    const opts = b.addOptions();
    opts.addOptionPathUntracked("repo_root", b.path("."));
    opts.addOption(bool, "vulkan", vulkan_on);
    opts.addOption(bool, "wayland", wayland_on);
    opts.addOption(bool, "appkit", appkit_on);

    const mod_opts: std.Build.Module.CreateOptions = .{
        .root_source_file = b.path("src/ztk.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ztcl", .module = ztcl }},
    };
    const ztk = if (public) b.addModule("ztk", mod_opts) else b.createModule(mod_opts);
    ztk.addOptions("build_options", opts);
    if (vulkan_on) {
        // The Vulkan loader opens at run time. The headers come from a pinned package, and the
        // shaders compile with glslc (package shaderc).
        ztk.link_libc = true;
        ztk.addIncludePath(b.dependency("vulkan_headers", .{}).path("include"));
        ztk.addImport("vulkan_c", vulkanC(b, target, optimize));
        addElfShim(b, ztk, target);
        ztk.addAnonymousImport("quad_vert_spv", .{ .root_source_file = shaders.vert });
        ztk.addAnonymousImport("quad_frag_spv", .{ .root_source_file = shaders.frag });
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
        ztk.linkFramework("CoreText", .{});
        ztk.linkFramework("AppKit", .{});
    }
    ztk.addAnonymousImport("inter_regular", .{ .root_source_file = b.path("assets/fonts/Inter-Regular.ttf") });
    ztk.addAnonymousImport("inter_bold", .{ .root_source_file = b.path("assets/fonts/Inter-Bold.ttf") });
    ztk.addAnonymousImport("mono_regular", .{ .root_source_file = b.path("assets/fonts/JetBrainsMono-Regular.ttf") });

    const libc_on = vulkan_on or appkit_on;
    // The self-hosted backend covers x86-64 Linux. Each other target uses LLVM.
    const use_llvm = libc_on or !is_linux or target.result.cpu.arch != .x86_64;
    return .{
        .ztcl = ztcl,
        .ztk = ztk,
        .libc = libc_on,
        .use_llvm = use_llvm,
        // Zig links Mach-O files with its own linker.
        .use_lld = use_llvm and target.result.ofmt != .macho,
    };
}

/// The `ztk` program of one target.
fn addProgram(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, cfg: Config, strip: ?bool, shaders: Shaders) *std.Build.Step.Compile {
    const m = addZtk(b, target, optimize, cfg, shaders, false);
    const exe = b.addExecutable(.{ .name = "ztk", .use_llvm = m.use_llvm, .use_lld = m.use_lld, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = m.libc,
        .imports = &.{
            .{ .name = "ztcl", .module = m.ztcl },
            .{ .name = "ztk", .module = m.ztk },
        },
    }) });
    // Space after the load commands, for the code signature that
    // `ztk bundle --target` adds to a Mach-O file.
    if (target.result.os.tag == .macos) exe.headerpad_size = 0x1000;
    return exe;
}

/// The targets of `ztk bundle --target`, and of `zig build runtimes`.
const runtime_targets = [_][]const u8{ "x86_64-linux", "aarch64-linux", "x86_64-macos", "aarch64-macos", "x86_64-windows", "aarch64-windows" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const filter = b.option([]const u8, "test-filter", "Run only the tests whose name has this text");
    const full = fullConfig(target.result);
    const backends = b.option([]const u8, "backends", "The backends to build, separated by commas: wayland, direct, appkit, headless (default: wayland, direct, and headless on Linux, appkit and headless on macOS, headless elsewhere)") orelse full.backends;
    const vulkan_on = b.option(bool, "vulkan", "Build the Vulkan renderer (default: true on Linux)") orelse full.vulkan;
    const strip = b.option(bool, "strip", "Remove the debug sections from the program");
    const cfg: Config = .{ .backends = backends, .vulkan = vulkan_on };
    const shaders: Shaders = .{
        .vert = shader(b, "vertex", "src/render/shaders/quad.vert", "quad.vert.spv"),
        .frag = shader(b, "fragment", "src/render/shaders/quad.frag", "quad.frag.spv"),
    };

    const main_ztk = addZtk(b, target, optimize, cfg, shaders, true);
    const ztk = main_ztk.ztk;

    const exe = addProgram(b, target, optimize, cfg, strip, shaders);
    b.installArtifact(exe);

    // `zig build runtimes`: the ztk program of each target of
    // `ztk bundle --target`, with the full GUI backend of its platform, in
    // ReleaseFast and stripped, in lib/ztk/runtime/TARGET/. `ztk bundle`
    // finds it there next to bin/ztk. `-Druntime-targets` builds a part of
    // the list.
    const runtimes = b.step("runtimes", "Build the ztk program of each target of ztk bundle into lib/ztk/runtime");
    const rt_only = b.option([]const u8, "runtime-targets", "The targets of zig build runtimes, separated by commas (default: all six)");
    for (runtime_targets) |name| {
        if (rt_only) |list| {
            var it = std.mem.splitScalar(u8, list, ',');
            const found = while (it.next()) |t| {
                if (std.mem.eql(u8, t, name)) break true;
            } else false;
            if (!found) continue;
        }
        const rt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = name }) catch unreachable);
        const rexe = addProgram(b, rt, .ReleaseFast, fullConfig(rt.result), true, shaders);
        const inst = b.addInstallArtifact(rexe, .{ .dest_dir = .{ .override = .{ .custom = b.fmt("lib/ztk/runtime/{s}", .{name}) } } });
        runtimes.dependOn(&inst.step);
    }

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
    const bench_m = addZtk(b, target, .fast, cfg, shaders, false);
    const bench = b.addExecutable(.{ .name = "ztk-bench", .use_llvm = bench_m.use_llvm, .use_lld = bench_m.use_lld, .root_module = b.createModule(.{
        .root_source_file = b.path("bench/bench.zig"),
        .target = target,
        .optimize = .fast,
        .link_libc = bench_m.libc,
        .imports = &.{
            .{ .name = "ztcl", .module = bench_m.ztcl },
            .{ .name = "ztk", .module = bench_m.ztk },
        },
    }) });
    // `zig build native-ref -- OUTDIR`: the reference renders and measures
    // of AppKit controls for the native look of macOS (ztk#154).
    if (target.result.os.tag == .macos) {
        const ref = b.addExecutable(.{ .name = "native-ref", .use_llvm = main_ztk.use_llvm, .use_lld = main_ztk.use_lld, .root_module = b.createModule(.{
            .root_source_file = b.path("tools/native-ref/macos/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "ztk", .module = ztk }},
        }) });
        const ref_run = b.addRunArtifact(ref);
        ref_run.addPassthruArgs();
        b.step("native-ref", "Render AppKit controls offscreen as the references of the macOS look").dependOn(&ref_run.step);
    }
    const bench_run = b.addRunArtifact(bench);
    bench_run.setCwd(b.path("."));
    b.step("bench", "Run the benchmark (ReleaseFast)").dependOn(&bench_run.step);

    // The virtual pointer of tests/wayland-drag.sh, in zig-out/bin.
    const wire_mod = b.createModule(.{ .root_source_file = b.path("src/platform/wl/wire.zig"), .target = target, .optimize = optimize });
    const test_pointer = b.addExecutable(.{ .name = "ztk-test-pointer", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/wayland/pointer.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wire", .module = wire_mod }},
    }) });
    b.step("test-pointer", "Build the virtual pointer of the Wayland drag test").dependOn(&b.addInstallArtifact(test_pointer, .{}).step);

    const tests = b.addTest(.{
        .use_llvm = main_ztk.use_llvm,
        .use_lld = main_ztk.use_lld,
        .root_module = ztk,
        .filters = if (filter) |f| &.{f} else &.{},
    });
    b.step("test", "Run the unit tests").dependOn(&b.addRunArtifact(tests).step);
}
