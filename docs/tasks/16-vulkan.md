# Task 16: The Vulkan renderer

## Goal

A Vulkan renderer draws a scene to an offscreen image, with one instanced draw call. A test compares its image with the image of the CPU renderer. No window exists in this task.

## Files

- `src/render/vulkan.zig`
- `src/render/shaders/quad.vert`, `src/render/shaders/quad.frag`
- `src/render/renderer.zig`: the `Renderer` interface
- `build.zig`, `build.zig.zon`: the Vulkan headers, `glslc`, the loader
- `docs/references/rendering.md`, `docs/references/dependencies.md`

## Interfaces

```zig
// src/render/renderer.zig
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        /// Draws a scene to the current target.
        draw: *const fn (ptr: *anyopaque, scene: *const Scene, atlas: *const text.Atlas) anyerror!void,
    };
};

// src/render/vulkan.zig
pub const Options = struct {
    /// The index of the physical device, or null for the default.
    device_index: ?u32 = null,
    /// Instance extensions that the backend needs for its surface.
    instance_extensions: []const [*:0]const u8 = &.{},
    validate: bool = false,
};
pub const Vulkan = struct {
    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Vulkan;
    pub fn deinit(v: *Vulkan) void;
    pub fn renderer(v: *Vulkan) Renderer;
    /// An offscreen target of a size. The format is RGBA 8-bit UNORM.
    pub fn createOffscreen(v: *Vulkan, width: u32, height: u32) !*Target;
    pub fn destroyTarget(v: *Vulkan, t: *Target) void;
    pub fn setTarget(v: *Vulkan, t: *Target) void;
    /// Copies the pixels of an offscreen target to an image.
    pub fn readPixels(v: *Vulkan, t: *Target, out: *Image) !void;
    /// The name of the device, for the test log.
    pub fn deviceName(v: *const Vulkan) []const u8;
    /// The Vulkan handles that the Wayland backend needs (task 17).
    pub fn instance(v: *const Vulkan) *anyopaque;
};
pub const Target = opaque {};
```

## Steps

1. The Vulkan headers. The development machine has the loader and no headers. Add the headers as a pinned package:
   ```sh
   zig fetch --save=vulkan_headers git+https://github.com/KhronosGroup/Vulkan-Headers#v1.4.369
   ```
   `v1.4.369` was the newest tag on 2026-11-23. In `build.zig`, add `b.dependency("vulkan_headers", .{}).path("include")` as an include path. Add the entry to `docs/references/dependencies.md` (license: Apache-2.0 OR MIT).
   Do not link the Vulkan loader. Open it at run time: `std.DynLib.open("libvulkan.so.1")`, look up `vkGetInstanceProcAddr`, and get each other function from it and from `vkGetDeviceProcAddr`. Keep the function pointers in one table. When the loader is missing, `Vulkan.init` returns `error.NoVulkan`, and the program uses the CPU renderer. The build option `-Dvulkan=false` leaves the renderer out (task 20 adds the option; add it here if that is simpler).
2. The shaders. `build.zig` runs `glslc` for each shader with `b.addSystemCommand`, and gives the SPIR-V output to the code with `addAnonymousImport`, so that `@embedFile` reads it. When `glslc` is not on the path, the build fails with a message that names the package (`shaderc`).
3. Use only Vulkan 1.0 core features and the swapchain extension (task 17). Select the first physical device that has a graphics queue. The environment variable `ZTK_GPU=<index>` selects another one.
4. `validate` turns on the layer `VK_LAYER_KHRONOS_validation` when it exists. The environment variable `ZTK_VK_VALIDATE=1` sets it. A validation message goes to stderr and makes the test fail.
5. The pipeline:
   - One vertex buffer binding with the input rate "instance". Its data is the array of `Quad` of the scene, as it is in memory. The attributes are the fields of `Quad`.
   - The vertex shader makes the four corners of a triangle strip from `gl_VertexIndex`. It gives the fragment shader the pixel position and the fields of the quad with the `flat` qualifier.
   - A push constant has the size of the target.
   - The fragment shader is the math of task 06, step 1, line for line: the clip test, `roundedDistance`, the coverage of the fill and the border, the gradient, the shadow, the opacity, and for a glyph quad the texel of the atlas with `texelFetch`.
   - The output color is not premultiplied. The blend is source alpha and one minus source alpha for the color, on the UNORM target. That is the sRGB "source over" of task 06, step 2.
   - No depth test. The quads draw in the order of the list.
6. One draw call: `vkCmdDraw(4, quad_count, 0, 0)`.
7. The instance buffer grows by a factor of two when the scene has more quads than its capacity. It never shrinks in Stage 1.
8. The atlas texture has the format R8 UNORM and the size of the atlas page. Upload the complete page when `atlas.generation` differs from the generation of the last upload.
9. The clear color of the render pass is `scene.clear`.
10. `readPixels` copies the image to a buffer that the host can read, and then to the `Image`.
11. Write `docs/references/rendering.md`: the source of the distance function of a rounded box, and each other source of the shader math.
12. The CPU renderer and the shader must agree. When they differ, find the cause. Do not raise the tolerance. A common cause is the pixel center: `gl_FragCoord` already has the 0.5.

## Tests

```sh
zig build test -Dtest-filter=vulkan
```

Each test starts with `Vulkan.init`. When no device exists, the test prints `SKIP: no Vulkan device` and returns. A machine with a device must not skip.

- `init` and `deinit` with validation, when the layer exists: no message.
- For each scene of the golden tests of task 06 and task 07 (`box-plain`, `box-radius`, `box-border`, `box-gradient`, `box-shadow`, `box-clip`, `text-sizes`, `text-bold`, `text-color`, `text-scale2`, `text-clip`, `text-large`): draw it with both renderers. At most 0.1 % of the pixels differ, and no channel differs by more than 2 levels. On a failure, write `<name>.gpu.png` and `<name>.gpu-diff.png` beside the golden file.
- A scene with zero quads gives the clear color.
- A scene with 20 000 quads draws, after the buffer grows two times.
- Two draws of different scenes to one target: the second image has no rest of the first.
- A change of the atlas between two draws uploads it again (the new glyph shows).
- Draw 10 000 quads 100 times. Print the mean time of one draw, with `readPixels` not in the time. The test name is `vulkan-speed`.
- `deinit` after each test with validation gives no message about an object that is still alive.

Run the tests on each physical device of the machine:

```sh
ZTK_GPU=0 zig build test -Dtest-filter=vulkan
ZTK_GPU=1 zig build test -Dtest-filter=vulkan
```

## Acceptance

- All tests pass on the Intel device and on the NVIDIA device of the development machine. The commit message names the devices and the result.
- The fragment shader has no formula that differs from `src/render/renderer.zig`. The reviewer compares them side by side.
- `git ls-files` has no `.spv` file.
- `ldd zig-out/bin/ztk` does not list the Vulkan loader. With the loader renamed in a test (give `Vulkan.init` a library name that does not exist), the result is `error.NoVulkan` and no crash.
- A draw of 10 000 quads is under 2 ms on the NVIDIA device. If it is slower, record the number and the reason in the commit message.

## Out of scope

- A window, a surface, and a swapchain. Task 17.
- More than one atlas page, images, and blur passes.
- A software Vulkan driver. The plan lists it as a decision for the user.
- Metal, Direct3D 12, and WebGL. Stage 3.
