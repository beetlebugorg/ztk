//! The text engine of the system, as an optional backend of `Fonts`
//! (step 2 of `docs/dev/native-look.md`). A platform gives one when the
//! system has a text engine: DirectWrite on Windows. With a backend, each
//! font description opens a face of the system, and the metrics, the
//! glyphs, the advances, the kerning, and the glyph images come from the
//! system. Without one, `Fonts` uses its own TrueType faces.
//!
//! The values are in the design units of the face, as `ttf.Face` gives
//! them, so the layout code is the same for both. `raster` gives the
//! image of a glyph at an em size in device pixels, with an x offset of
//! a quarter pixel.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const FontDesc = @import("font.zig").FontDesc;
const Bitmap = @import("raster.zig").Bitmap;

/// The vertical metrics of a face, in design units.
pub const FaceMetrics = struct {
    units_per_em: u16,
    ascent: i32,
    /// Below the baseline, as a negative number, as in `ttf.Face`.
    descent: i32,
    line_gap: i32,
};

pub const System = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The id of a face for a description at an em size in logical
        /// pixels, or null when the system has no face for it. The same
        /// face gives the same id.
        open: *const fn (ctx: *anyopaque, desc: FontDesc) ?u32,
        metrics: *const fn (ctx: *anyopaque, face: u32) FaceMetrics,
        glyph: *const fn (ctx: *anyopaque, face: u32, cp: u21) u16,
        advance: *const fn (ctx: *anyopaque, face: u32, glyph: u16) i32,
        kern: *const fn (ctx: *anyopaque, face: u32, left: u16, right: u16) i32,
        /// The image of a glyph. `em_px` is the em size in device pixels,
        /// and `sub_x` the x offset of the origin, from 0 to 1.
        raster: *const fn (ctx: *anyopaque, gpa: std.mem.Allocator, face: u32, glyph: u16, em_px: f32, sub_x: f32) anyerror!Bitmap,
    };

    pub fn open(s: System, desc: FontDesc) ?u32 {
        return s.vtable.open(s.ctx, desc);
    }
    pub fn metrics(s: System, face: u32) FaceMetrics {
        return s.vtable.metrics(s.ctx, face);
    }
    pub fn glyph(s: System, face: u32, cp: u21) u16 {
        return s.vtable.glyph(s.ctx, face, cp);
    }
    pub fn advance(s: System, face: u32, g: u16) i32 {
        return s.vtable.advance(s.ctx, face, g);
    }
    pub fn kern(s: System, face: u32, left: u16, right: u16) i32 {
        return s.vtable.kern(s.ctx, face, left, right);
    }
    pub fn raster(s: System, gpa: std.mem.Allocator, face: u32, g: u16, em_px: f32, sub_x: f32) !Bitmap {
        return s.vtable.raster(s.ctx, gpa, face, g, em_px, sub_x);
    }
};
