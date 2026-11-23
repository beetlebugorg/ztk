# Task 06: The scene, the CPU renderer, and golden images

## Goal

A scene is a list of quads. The CPU renderer draws a scene to an image. A test compares the image and the text form of a scene with golden files. This is the base of the verification of all later drawing.

## Files

- `src/scene.zig`: `Quad`, `Scene`, `Builder`
- `src/render/renderer.zig`: the `Image` type and the shared math
- `src/render/cpu.zig`
- `src/png.zig`
- `src/testing.zig`: `expectGolden`, `expectScene`
- `tests/golden/`
- `build.zig`: the path of the repository for the tests

## Interfaces

```zig
// src/scene.zig. All numbers of a Quad are device pixels.
pub const Kind = enum(u32) { box = 0, shadow = 1, glyph = 2, image = 3 };
pub const Quad = extern struct {
    rect: [4]f32,         // x, y, w, h
    clip: [4]f32,         // x, y, w, h. A pixel outside gets no color.
    radii: [4]f32,        // top-left, top-right, bottom-right, bottom-left
    border: [4]f32,       // widths: top, right, bottom, left
    fill: [4]f32,         // r, g, b, a in 0..1, sRGB, straight alpha
    fill2: [4]f32,        // the end color of a gradient. Equal to fill for one color.
    border_color: [4]f32,
    uv: [4]f32,           // x, y, w, h in the atlas, in texels (glyph, image)
    params: [4]f32,       // gradient direction x, y; shadow blur; opacity
    kind: u32,
    _pad: [3]u32 = .{ 0, 0, 0 },
};
pub const Scene = struct {
    quads: std.ArrayListUnmanaged(Quad) = .empty,
    width: u32 = 0,       // device pixels
    height: u32 = 0,
    clear: [4]f32 = .{ 1, 1, 1, 1 },
    pub fn reset(s: *Scene, width: u32, height: u32) void;
    pub fn deinit(s: *Scene, gpa: std.mem.Allocator) void;
    /// One line for each quad, with fixed number formats.
    pub fn dump(s: *const Scene, w: *std.Io.Writer) !void;
};
pub const BoxStyle = struct {
    fill: geom.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    fill2: ?geom.Color = null,
    gradient_angle_deg: f32 = 180,       // the CSS angle: 180 is top to bottom
    border: [4]f32 = .{ 0, 0, 0, 0 },    // logical pixels
    border_color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    opacity: f32 = 1,
};
pub const Shadow = struct { dx: f32 = 0, dy: f32 = 0, blur: f32 = 0, spread: f32 = 0, color: geom.Color };
pub const Builder = struct {
    pub fn init(gpa: std.mem.Allocator, scene: *Scene, scale: f32) Builder;
    /// Moves the origin for the quads that follow. Logical pixels.
    pub fn pushOffset(b: *Builder, dx: i32, dy: i32) void;
    pub fn popOffset(b: *Builder) void;
    /// Intersects the clip with a rectangle. Logical pixels.
    pub fn pushClip(b: *Builder, r: geom.Rect) void;
    pub fn popClip(b: *Builder) void;
    pub fn box(b: *Builder, r: geom.Rect, style: BoxStyle) !void;
    pub fn shadow(b: *Builder, r: geom.Rect, radii: [4]f32, s: Shadow) !void;
};
```

```zig
// src/render/renderer.zig
pub const Image = struct {
    width: u32, height: u32,
    pixels: []u8,          // RGBA, 8 bits, sRGB, rows from the top
};
/// The distance from a point to a rounded rectangle. Negative inside.
pub fn roundedDistance(px: f32, py: f32, rect: [4]f32, radii: [4]f32) f32;
pub const RowRange = struct { first: u32, last: u32 }; // rows [first, last)
/// The rows that differ between two images of equal size, as ranges in
/// order. `out` gets at most `out.len` ranges. When more ranges exist,
/// the last range covers the rest.
pub fn changedRows(prev: Image, cur: Image, out: []RowRange) []RowRange;
/// The coverage of a pixel center for one quad: fill alpha and border alpha.
pub fn boxCoverage(q: *const Quad, px: f32, py: f32) struct { fill: f32, border: f32 };
pub fn shadowCoverage(q: *const Quad, px: f32, py: f32) f32;
```

```zig
// src/render/cpu.zig
/// Draws the scene. `atlas` is null until task 07.
pub fn render(scene: *const Scene, atlas: ?*const anyopaque, out: *Image) void;
// src/png.zig
pub fn encode(gpa: std.mem.Allocator, img: Image) ![]u8;
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) !Image;
// src/testing.zig
pub fn expectGolden(name: []const u8, img: Image, tol: Tolerance) !void;
pub fn expectScene(name: []const u8, scene: *const Scene) !void;
pub const Tolerance = struct { max_level: u8 = 0, max_fraction: f32 = 0 };
```

## Steps

1. The math, the same for the CPU renderer and for the shader of task 16:
   - A pixel has its center at `x + 0.5`, `y + 0.5`.
   - `roundedDistance`: move the point to the frame of the rectangle center. Select the radius of the quadrant of the point. With `q = abs(p) - half_size + r`, the distance is `min(max(q.x, q.y), 0) + length(max(q, 0)) - r`. Limit each radius to half of the smaller side.
   - The outer coverage is `clamp(0.5 - d, 0, 1)`.
   - The inner shape is the rectangle minus the four border widths. Each inner radius is the outer radius minus the larger of its two adjacent border widths, and at least 0. The inner coverage uses the same formula.
   - Fill alpha is the inner coverage. Border alpha is the outer coverage minus the inner coverage.
   - A gradient: `t` is the projection of the pixel on the direction `params[0..2]`, mapped to 0..1 over the rectangle, as the CSS `linear-gradient` length rule does. The color is `fill + (fill2 - fill) * t` on the four sRGB channels.
   - A shadow quad has the rectangle of the shadow shape. With `blur = params[2]`: `t = clamp(0.5 - d / max(blur, 1), 0, 1)`, and the coverage is `t * t * (3 - 2 * t)`. The quad covers the shape plus `blur` on each side.
   - The opacity `params[3]` multiplies each alpha.
   - A pixel outside `clip` gets no color.
2. The blend is "source over" on the 8-bit sRGB values with straight alpha: `out = src * a + dst * (1 - a)`. The target is opaque. Round to the nearest integer.
3. `Builder.box` adds one quad of kind `box`. It multiplies positions and sizes by the scale. It rounds the four edges of the rectangle to device pixels. It rounds a border width to a whole device pixel, and to at least 1 when the width is above 0. It adds no quad when the result does not show: an alpha of 0 for the fill and no border.
4. `Scene.dump` prints one line for each quad: the kind, the rectangle, the clip, the radii, the border, and the colors as `#rrggbbaa`. Print each number with two decimals. The format must not change after this task, because golden files depend on it.
5. `png.encode` writes an 8-bit RGBA file with filter type 0 and a zlib stream from `std.compress.flate`. If the compressor of the standard library does not work for this, write stored blocks and say so in the commit message. `png.decode` reads 8-bit RGBA files with no interlace and the five filter types.
6. The golden helpers:
   - The files are `tests/golden/<name>.png` and `tests/golden/<name>.scene.txt`.
   - `build.zig` gives the tests the absolute path of the repository through a build options module. The path is not in a source file.
   - With the environment variable `ZTK_UPDATE_GOLDEN=1`, the helper writes the golden file and passes.
   - On a difference, `expectGolden` writes `<name>.actual.png` and `<name>.diff.png` beside the golden file. The difference image is white where the pixels are equal and red where they differ. The error message has the count of pixels that differ and the largest difference.
   - A missing golden file is a failure with a message that names `ZTK_UPDATE_GOLDEN`.
7. `Headless.draw` now draws the scene with the CPU renderer into an image of the window. `Headless.image(w)` returns it.
8. `changedRows` compares the rows of two RGBA images byte for byte. A backend that shows CPU images writes only these rows to the display (tasks 17 and 20). Printdeck measured the effect of this rule on a Raspberry Pi 5: see [the lessons](../references/printdeck.md).

## Tests

```sh
zig build test -Dtest-filter=scene
zig build test -Dtest-filter=cpu
zig build test -Dtest-filter=png
```

- `roundedDistance` at the center of a 10 by 10 rectangle with radius 0 is -5. On the edge it is 0. At a corner with radius 5 it is positive.
- A 4 by 4 opaque red box on white at (2, 2): each of its 16 pixels is `255, 0, 0`, and each other pixel is white.
- A box with alpha 0.5 black on white gives 128 or 127. The test names the exact value.
- `png.decode(png.encode(img))` is equal to `img` for a 64 by 64 image with all four channels.
- `png.decode` reads one small PNG that another program made. Make it with the Python standard library (`zlib` and `struct`) in the test setup, or add the bytes as a literal.
- A clip: a box that is half outside the clip draws only the inside half.
- Golden images and scene dumps, each 200 by 120 at scale 1, and the first one also at scale 2:
  - `box-plain`: a solid box.
  - `box-radius`: radii 8, and a second box with four different radii.
  - `box-border`: a 1 pixel and a 3 pixel border with radius 6.
  - `box-gradient`: a gradient from top to bottom and one at 90 degrees.
  - `box-shadow`: a box with a shadow with blur 12 and offset (0, 4).
  - `box-clip`: three boxes in a clip.
- `expectGolden` with a changed pixel fails and writes the two extra files. The test deletes them.
- `changedRows` of two equal images is empty. With rows 3, 4, and 9 changed it gives [3, 5) and [9, 10). With more ranges than `out.len`, the last range goes to the last changed row.

## Acceptance

- All tests pass with a tolerance of zero.
- The reviewer opens each golden image. Each one shows what its name says, with smooth corners and no gaps between a border and its fill.
- The CPU renderer has no dependence on a C library.
- `render` of a scene with 10 000 boxes of 100 by 30 pixels in a 1920 by 1080 image runs in under 200 ms in `ReleaseFast`. Print the time in a test with the name `cpu-speed`.

## Out of scope

- Glyphs and images. Task 07 adds glyphs, with a tolerance of zero too.
- Rounded clips, inset shadows, and more than two gradient colors.
- A GPU.
