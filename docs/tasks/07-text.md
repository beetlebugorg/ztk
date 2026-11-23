# Task 07: Text: the built-in font engine

## Goal

ztk reads a TrueType font, makes glyph images, places the glyphs of a line of left-to-right text with kerning, measures the line, and draws it with the CPU renderer. All of it is Zig code with no library. The same code runs on each platform, so a line of text has the same pixels on each machine.

The plan has the reason in decision D6: the direct backend and the web build must have no dependency, and one rasterizer makes the golden images exact.

## Files

- `src/text/ttf.zig`: the font file parser
- `src/text/raster.zig`: from an outline to a coverage image
- `src/text/font.zig`: `Fonts`, `Font`, `FontDesc`, `Metrics`
- `src/text/shape.zig`: `Run`, `shape`, `measure`
- `src/text/atlas.zig`: `Atlas`
- `src/scene.zig`: `Builder.text`
- `src/render/cpu.zig`: glyph quads
- `assets/fonts/`: the font files and their license
- `tools/font-oracle.py`: prints font facts with `fontTools`, for the tests
- `docs/references/dependencies.md`, `docs/references/rendering.md`

## Interfaces

```zig
// src/text/ttf.zig. All numbers are font units unless a name says more.
pub const Point = struct { x: f32, y: f32, on_curve: bool };
pub const Outline = struct {
    points: []const Point,
    /// The index of the last point of each contour.
    contour_ends: []const u16,
};
pub const Face = struct {
    units_per_em: u16,
    ascent: i16, descent: i16, line_gap: i16,   // from hhea
    glyph_count: u16,
    /// Reads the tables. `data` must stay valid as long as the Face.
    pub fn init(data: []const u8) error{BadFont, Unsupported}!Face;
    /// The glyph of a code point, or 0.
    pub fn glyphIndex(f: *const Face, codepoint: u21) u16;
    pub fn advance(f: *const Face, glyph: u16) u16;
    /// The kerning between two glyphs, from the GPOS table.
    pub fn kerning(f: *const Face, left: u16, right: u16) i16;
    /// The outline of a glyph, with composite glyphs resolved.
    pub fn outline(f: *const Face, gpa: std.mem.Allocator, glyph: u16) !Outline;
    /// The family and the style name from the name table.
    pub fn family(f: *const Face) []const u8;
};

// src/text/raster.zig
pub const Bitmap = struct { width: u32, height: u32, left: i32, top: i32, pixels: []u8 };
/// Makes the coverage image of an outline at a scale (device pixels for
/// each font unit), moved right by `sub_x` of a pixel (0 to 0.75).
/// `left` and `top` give the place of the image from the glyph origin.
pub fn rasterize(gpa: std.mem.Allocator, o: Outline, scale: f32, sub_x: f32) !Bitmap;

// src/text/font.zig
pub const FontDesc = struct {
    family: []const u8 = "system-ui",
    size: f32 = 13,        // logical pixels
    weight: u16 = 400,     // 100..900
    italic: bool = false,
};
pub const Metrics = struct { ascent: i32, descent: i32, line_height: i32 }; // logical pixels, rounded up
pub const Font = struct { face: *const ttf.Face, size: f32, scale: f32 };
pub const Fonts = struct {
    pub fn init(gpa: std.mem.Allocator) !Fonts;
    pub fn deinit(f: *Fonts) void;
    /// Adds a font from memory. The bytes must stay valid.
    pub fn add(f: *Fonts, data: []const u8) !void;
    /// The font for a description at a scale. The result is cached and
    /// stays valid until `deinit`.
    pub fn get(f: *Fonts, desc: FontDesc, scale: f32) !*Font;
    pub fn metrics(font: *const Font) Metrics;
    /// Parses a font value of Tk: "Helvetica 12 bold", {Liberation Sans} 10,
    /// "TkDefaultFont". A positive size is points. A negative size is pixels.
    pub fn parseTk(text: []const u8, base: FontDesc, scaling: f64) ?FontDesc;
};

// src/text/shape.zig
pub const Glyph = struct { id: u16, x: f32, y: f32, cluster: u32 }; // device pixels from the line origin
pub const Run = struct {
    font: *Font,
    glyphs: []Glyph,
    width: i32,            // logical pixels, rounded up
    pub fn deinit(r: *Run, gpa: std.mem.Allocator) void;
    /// The x position of the caret before byte `index`, in logical pixels.
    pub fn caretX(r: *const Run, text: []const u8, index: usize) i32;
    /// The byte index of the caret stop nearest to x.
    pub fn indexAt(r: *const Run, text: []const u8, x: i32) usize;
};
pub fn shape(gpa: std.mem.Allocator, font: *Font, text: []const u8) !Run;
/// The width of a line in logical pixels. The result is cached.
pub fn measure(fonts: *Fonts, font: *Font, text: []const u8) i32;

// src/text/atlas.zig
pub const AtlasGlyph = struct { uv: [4]f32, left: f32, top: f32, w: f32, h: f32 };
pub const Atlas = struct {
    pub const page_size = 1024;
    pub fn init(gpa: std.mem.Allocator) Atlas;
    pub fn deinit(a: *Atlas) void;
    /// The image of a glyph. `sub` is the quarter-pixel x offset, 0..3.
    pub fn get(a: *Atlas, font: *Font, glyph: u16, sub: u2) !AtlasGlyph;
    pub fn page(a: *const Atlas) []const u8; // 1024 by 1024, one byte of coverage for each texel
    /// Counts up at each change of the page. The GPU renderer uploads on a change.
    generation: u32 = 0,
};

// src/scene.zig
/// Adds one glyph quad for each glyph. x and y are the left end of the
/// baseline in logical pixels.
pub fn text(b: *Builder, atlas: *Atlas, run: *const Run, x: i32, y: i32, color: geom.Color) !void;
```

## Steps

1. Add the font to the repository. [The plan](../plan.md), decision D18, proposes Inter 4.1. Download the release archive from the releases page of `https://github.com/rsms/inter`. Add the static TrueType files `Inter-Regular.ttf` and `Inter-Bold.ttf` and the license file `LICENSE.txt` of the archive (SIL Open Font License 1.1) to `assets/fonts/`. Check that the files have a `glyf` table (`ttx -l Inter-Regular.ttf`). If the user selected another font, use that font. Record the choice in the commit message.
2. `build.zig` gives the font files to the code with `addAnonymousImport`, so that `@embedFile` reads them. This task links no library and does not need libc.
3. `ttf.zig`. The source is the OpenType specification (the links are in `docs/references/rendering.md`). Read these tables, all with big-endian numbers:
   - The table directory, `head` (units for each em, the `loca` format), `hhea`, `maxp`, `hmtx`, `name`.
   - `cmap`: format 4 and format 12. Prefer a Unicode full table (platform 3 encoding 10, or platform 0) and then a BMP table (platform 3 encoding 1).
   - `loca` and `glyf`: simple glyphs (the flags, the delta-coded coordinates, the repeat flag) and composite glyphs (the offsets and the 2 by 2 transform, to a depth of at most 8).
   - `GPOS`: the `kern` feature of the default language system of the `DFLT` or `latn` script, with pair adjustment lookups (type 2) in format 1 and format 2, and extension lookups (type 9) that hold them. Only the x advance of the first glyph is used.
   - A font with no `glyf` table (CFF outlines) and a variable font give `error.Unsupported`. Stage 4 adds them.
   - Each read checks its offset against the length of the data. A bad font gives `error.BadFont` and never reads outside the data. Limit the points of one glyph to 16 384 and the lookups that one pair reads to 64.
4. `raster.zig`:
   - Turn each contour into line segments. Two off-curve points in a row have an on-curve point in the middle between them. Divide each quadratic curve into segments so that the error is under 0.1 device pixels, with at most 32 segments.
   - Use the signed area method: for each segment, add its signed coverage and area to an accumulation buffer of the image size, and then sum each row from left to right. The coverage of a pixel is the absolute value of the sum, limited to 1, as an 8-bit number. The sources are in `docs/references/rendering.md`.
   - The fill rule is non-zero winding. The y axis of a font goes up. The image has rows from the top.
   - Apply no hinting and no gamma change.
5. `Fonts`:
   - `Fonts.init` adds the two fonts of the repository.
   - In Stage 1, `get` selects among the added fonts by weight: Bold for a weight of 600 or more, Regular for all other weights. Each family name gives these fonts. `monospace` also gives them in Stage 1. Write this limit in `docs/stage1-limits.md`. The fonts of the system come in Stage 2.
   - The scale of a font is `size * scale / units_per_em` device pixels for each font unit.
6. `shape`:
   - Decode the UTF-8. An invalid byte gives the glyph 0.
   - Map each code point to a glyph. A code point with no glyph gives the glyph 0 (the font draws its "missing" box).
   - Place each glyph at the sum of the advances and the kerning before it, in font units, and convert to device pixels with no rounding of one advance.
   - The glyph position rounds down to a quarter pixel: the whole part goes in the quad position, and the rest selects `sub`. All y positions round to whole pixels.
   - Stage 1 has no ligatures, no combining marks, and no right-to-left text.
7. `Run.width` is the last position plus the last advance, divided by the scale, rounded up. `Metrics` rounds the ascent and the descent up, and `line_height` is their sum plus the line gap.
8. The atlas has one page in Stage 1. A shelf packer puts the glyph images in rows, with one texel of space between images. When the page is full, `get` returns `error.AtlasFull`. Stage 2 adds pages.
9. The CPU renderer draws a `glyph` quad: the coverage is the texel of the atlas at the pixel (no filter, because a glyph quad has whole device pixel positions). The color is `fill`, and the alpha is `fill.a` times the coverage times the opacity.
10. `parseTk` accepts: a family alone, a family and a size, a family and a size and style words (`bold`, `italic`, `normal`, `roman`; `underline` and `overstrike` are accepted and ignored in Stage 1). A family with spaces is a list item in braces. The names `TkDefaultFont`, `TkTextFont`, `TkFixedFont`, `TkMenuFont`, and `TkHeadingFont` give `base`, with the family `monospace` for `TkFixedFont`. A size in points is `size * scaling` logical pixels.
11. `measure` keeps a cache from the font and the text to the width. Limit the cache to 4 096 entries and empty it when it is full.
12. `tools/font-oracle.py <font file>` prints, with the Python package `fontTools`: the units for each em, the `hhea` numbers, and for a fixed list of characters and pairs the glyph id, the advance, the count of contours, the count of points, and the kerning of the pair. The development machine has `fontTools` 4.67.0. The script is for the tests only.
13. Add the entries to `docs/references/dependencies.md` (the font) and `docs/references/rendering.md` (the OpenType specification and the rasterizer method).

## Tests

```sh
zig build test -Dtest-filter=ttf
zig build test -Dtest-filter=raster
zig build test -Dtest-filter=shape
zig build test -Dtest-filter=atlas
python3 -I tools/font-oracle.py assets/fonts/Inter-Regular.ttf > /tmp/ztk-font-oracle.txt
```

Parser tests. The expected numbers are in the test source, copied from the output of `tools/font-oracle.py`. A second test runs the script and compares all its lines with the parser. It prints `SKIP: no fontTools` when Python or the package is missing.

- `units_per_em`, the ascent, the descent, and the line gap of both fonts.
- The glyph id and the advance of each character of `AVa.1 é€`.
- The count of contours and points of `A`, `B`, `i`, and `é`. (`é` is a composite glyph in many fonts. The test states what the oracle gives.)
- The kerning of `AV`, `To`, `LT`, and `aa`.
- A code point with no glyph gives 0.
- A file that is cut at each of 200 lengths gives `error.BadFont` and no crash.
- 1 000 copies of the font with one random byte changed, from a fixed seed: `init`, `glyphIndex`, `kerning`, and `outline` of 50 glyphs give a result or an error, and never read outside the data. Run it in a safe build mode.

Rasterizer tests:

- A square outline of 10 by 10 font units at scale 1 gives 100 pixels of 255.
- The same square moved by half a pixel in x gives a first and a last column of 127 or 128.
- A triangle with the corners (0, 0), (10, 0), (0, 10): the sum of all coverage is 50 times 255, with an error under 1 %.
- A contour inside a contour with the other direction makes a hole: a ring has 0 in the middle.
- The sum of the coverage of the glyph `o` at 64 pixels is equal to the area of its outline (from the segments) with an error under 0.5 %.
- A glyph at the sub offsets 0 and 0.25 gives different images with equal sums, with an error under 1 %.

Shape and atlas tests:

- `metrics` of the Regular font at 13 pixels: the ascent and the descent are above 0, and `line_height` is between 14 and 20.
- `measure("")` is 0. `measure("AV")` is smaller than `measure("A") + measure("V")` at 100 pixels, because of the kerning.
- `measure("Hello")` at scale 2 is equal to the value at scale 1, or differs by 1.
- At the scales 1.25, 1.5, and 2, the right edge of the last glyph of "Right aligned text 0123456789" is at most 1 logical pixel from `Run.width`. Printdeck found that rounded advances move a long line out of its box at a scale of 1.5.
- `caretX` at index 0 is 0, at the end it is the width or the width minus 1, and it does not go down as the index goes up.
- `indexAt(caretX(i))` is `i` for each character start of "Hello, wörld".
- `shape("é")` (two bytes) gives one glyph with the cluster 0.
- The atlas gives the same `uv` for two calls with the same key, and `generation` does not change on the second call.
- `parseTk("Helvetica 12 bold")` gives the size 16 and the weight 700 with the default scaling. `parseTk("Courier -14")` gives the size 14. `parseTk("{Liberation Sans} 10")` gives that family.

Golden images, equal in each byte, and scene dumps:

- `text-sizes`: "The quick brown fox" at 11, 13, 16, and 24 pixels, black on white.
- `text-bold`: Regular and Bold lines.
- `text-color`: white text on a blue box, and text with alpha 0.5.
- `text-scale2`: one line at scale 2.
- `text-clip`: a line that a clip cuts in the middle of a glyph.
- `text-large`: the letters `aegR&@` at 96 pixels, to show the curves.

## Acceptance

- All tests pass.
- The reviewer opens each golden image. The curves are smooth, the stems of one size have one width, the baseline is straight, and the space between letters is even. `text-large` has no gap, no spike, and no filled counter.
- The parser never reads outside the font data: the reviewer reads each offset check.
- A test with `std.testing.allocator` shapes 1 000 lines and has no leak.
- The text code imports no C header: `grep -rn cImport src/text` finds no line.
- The glyph image of `a` at 13 pixels is made in under 50 microseconds, and a line of 60 characters with all glyphs in the atlas is shaped in under 20 microseconds, in `ReleaseFast`. Print the times in a test with the name `text-speed`.

## Out of scope

- CFF outlines, variable fonts, color glyphs, and font collections. Stage 4.
- The fonts of the system. Stage 2.
- Ligatures, combining marks, right-to-left text, font fallback, and line breaks. Stage 4.
- HarfBuzz. It is an optional shaper of Stage 4.
- Hinting and subpixel (LCD) rendering.
- More than one atlas page, underline, overstrike, and the `font` command of Tk.
