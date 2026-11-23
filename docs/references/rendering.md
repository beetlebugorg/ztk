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
