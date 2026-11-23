# Rendering

The renderers of ztk have their own code. This page lists the methods.

## The distance to a rounded box

Inigo Quilez, "2D distance functions". https://iquilezles.org/articles/distfunctions2d

**License:** Article

**How ztk uses it:** the CPU renderer and each shader compute the signed distance from a pixel center to a box with four corner radii. The coverage of a pixel is that distance, limited to one pixel. ztk has its own code for the function.

## One quad form for a user interface

The idea to draw a complete user interface as one list of instanced quads, with the rounded corners, the borders, and the shadows computed in the fragment program, is common in GPU user interface toolkits. ztk does not follow the code of one of them.

## Color blend

The "source over" operator of Thomas Porter and Tom Duff, "Compositing Digital Images", SIGGRAPH 1984.

**License:** Paper

**How ztk uses it:** each quad blends over the target with straight alpha, on the sRGB values, as CSS does.

## The font file format

The OpenType specification, Microsoft. https://learn.microsoft.com/en-us/typography/opentype/spec/

The TrueType Reference Manual, Apple. https://developer.apple.com/fonts/TrueType-Reference-Manual/

**License:** Specifications

**How ztk uses it:** `src/text/ttf.zig` reads the tables `head`, `hhea`, `maxp`, `hmtx`, `name`, `cmap`, `loca`, `glyf`, and `GPOS` as these documents define them. ztk has its own parser and has no code of FreeType, HarfBuzz, or another font library.

## The glyph rasterizer

Sean Barrett, "How the stb_truetype Anti-Aliased Software Rasterizer v2 Works". https://nothings.org/gamedev/rasterize/

Raph Levien, "Inside the fastest font renderer in the world" (2016). The planner did not check a link for this article.

**License:** Articles

**How ztk uses it:** `src/text/raster.zig` uses the method of signed areas: each edge adds its signed coverage to an accumulation buffer, and a sum along each row gives the coverage of each pixel. ztk has its own code and has no code of `stb_truetype` or `font-rs`.

A task that adds a method to a renderer adds its source here.

## The signed area rasterizer

The method of an accumulation buffer for the signed area under each line segment, summed along each row, is described in the public write-ups of font rasterizers (for example the "font-rs" article by Raph Levien and the sparse-coverage method of "stb_truetype" version 2). ztk has its own code. It does not copy a function from either source.

**How ztk uses it:** `src/text/raster.zig` flattens each quadratic curve, adds each segment to the buffer, and sums each row to get an 8-bit coverage image.

## The area of a quadratic curve

The area between a parabola and its chord is 2/3 of the area of the triangle that the two end points and the control point make. The tests use this fact to check the rasterizer with an independent area.

## Pair adjustment kerning

The GPOS table of the OpenType specification, lookup type 2 (pair adjustment) in formats 1 and 2, and lookup type 9 (extension). `src/text/ttf.zig` reads the `kern` feature of the `DFLT` and `latn` scripts.

## The distance function of a rounded box

The signed distance of a point to a rounded rectangle is a public formula. Inigo Quilez describes it on the page "Distance Functions" (https://iquilezles.org/articles/distfunctions2d/). The formula is: `q = abs(p - center) - half_size + r`, and the distance is `min(max(q.x, q.y), 0) + length(max(q, 0)) - r`. `src/render/renderer.zig` has this formula in `roundedDistance`, with one radius for each corner. `src/render/shaders/quad.frag` has the same formula in the same order. The coverage of a pixel is `clamp(0.5 - distance, 0, 1)`, which is a filter of one pixel. The shadow uses a smooth step of the distance over the blur width.

**License:** The article is not code. ztk has its own code.

## The Vulkan renderer

The Vulkan specification, version 1.0 core: the render pass, the graphics pipeline with instance rate vertex input, the push constants, the image barriers, and the buffer to image copies. https://registry.khronos.org/vulkan/

**License:** Specification

**How ztk uses it:** `src/render/vulkan.zig` uses only Vulkan 1.0 core functions and the extension `VK_EXT_debug_utils` when validation is on. The blend is `ONE` and `ONE_MINUS_SRC_ALPHA` with a premultiplied output color, so that a box with a fill and a border blends in one step. The result equals "source over" of the CPU renderer. The CPU renderer blends the fill and the border in two steps. The two differ by at most 2 levels in a channel in the tests.
