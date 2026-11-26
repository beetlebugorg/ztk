//! The scene: a flat list of quads in paint order. All numbers of a quad
//! are device pixels. The Builder turns logical boxes into quads: it
//! multiplies by the scale, rounds each rectangle edge to a device pixel,
//! rounds a border width to a whole device pixel (at least 1 when the
//! width is above 0), and tracks an origin offset and a clip. A quad
//! has no pointer, so a scene can be copied or sent to another program.
//! The text dump has a fixed format with two decimals. Golden files
//! depend on it.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const num = @import("num.zig");
const geom = @import("geom.zig");
const atlas_mod = @import("text/atlas.zig");
const shape_mod = @import("text/shape.zig");
const easing = @import("easing.zig");

pub const Kind = enum(u32) { box = 0, shadow = 1, glyph = 2, image = 3 };

pub const Quad = extern struct {
    /// x, y, w, h
    rect: [4]f32,
    /// x, y, w, h. A pixel outside gets no color.
    clip: [4]f32,
    /// top-left, top-right, bottom-right, bottom-left
    radii: [4]f32,
    /// widths: top, right, bottom, left
    border: [4]f32,
    /// r, g, b, a in 0..1, sRGB, straight alpha
    fill: [4]f32,
    /// The end color of a gradient. Equal to fill for one color.
    fill2: [4]f32,
    border_color: [4]f32,
    /// x, y, w, h in the atlas, in texels (glyph, image)
    uv: [4]f32,
    /// gradient direction x, y; shadow blur; opacity
    params: [4]f32,
    kind: u32,
    _pad: [3]u32 = .{ 0, 0, 0 },
};

/// A region of a page of the atlas with its new bytes: rows of `w` bytes
/// of the coverage page, or of `w * 4` bytes of the image page (`rgba`).
pub const AtlasPatch = struct { x: u32, y: u32, w: u32, h: u32, bytes: []const u8, rgba: bool = false };

pub const Scene = struct {
    quads: std.ArrayListUnmanaged(Quad) = .empty,
    /// Device pixels.
    width: u32 = 0,
    height: u32 = 0,
    clear: [4]f32 = .{ 1, 1, 1, 1 },

    pub fn reset(s: *Scene, width: u32, height: u32) void {
        s.quads.clearRetainingCapacity();
        s.width = width;
        s.height = height;
    }

    pub fn deinit(s: *Scene, gpa: std.mem.Allocator) void {
        s.quads.deinit(gpa);
    }

    /// One line for each quad, with fixed number formats.
    pub fn dump(s: *const Scene, w: *std.Io.Writer) !void {
        try w.print("scene {d}x{d} clear {s}\n", .{ s.width, s.height, hex(s.clear)[0..] });
        for (s.quads.items) |q| {
            const name = switch (@as(Kind, @fromBackingInt(@intCast(q.kind)))) {
                .box => "box",
                .shadow => "shadow",
                .glyph => "glyph",
                .image => "image",
            };
            try w.print("{s} rect {f} clip {f} radii {f} border {f} fill {s} fill2 {s} bcolor {s} params {f}", .{
                name,             N4{ .v = q.rect }, N4{ .v = q.clip },        N4{ .v = q.radii },  N4{ .v = q.border },
                hex(q.fill)[0..], hex(q.fill2)[0..], hex(q.border_color)[0..], N4{ .v = q.params },
            });
            if (q.kind >= @backingInt(Kind.glyph)) try w.print(" uv {f}", .{N4{ .v = q.uv }});
            try w.writeByte('\n');
        }
    }
};

/// Four numbers with two decimals, in parentheses.
const N4 = struct {
    v: [4]f32,

    pub fn format(n: N4, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('(');
        for (n.v, 0..) |x, i| {
            if (i > 0) try w.writeByte(',');
            const y: f32 = if (@abs(x) < 0.005) 0 else x;
            try w.print("{d:.2}", .{y});
        }
        try w.writeByte(')');
    }
};

fn hex(c: [4]f32) [9]u8 {
    const digits = "0123456789abcdef";
    var out: [9]u8 = undefined;
    out[0] = '#';
    for (c, 0..) |x, i| {
        const v = num.byte(x * 255);
        out[1 + i * 2] = digits[v >> 4];
        out[2 + i * 2] = digits[v & 15];
    }
    return out;
}

pub const BoxStyle = struct {
    fill: geom.Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    fill2: ?geom.Color = null,
    /// The CSS angle: 180 is top to bottom.
    gradient_angle_deg: f32 = 180,
    /// Logical pixels: top, right, bottom, left.
    border: [4]f32 = .{ 0, 0, 0, 0 },
    border_color: geom.Color = .{ .r = 0, .g = 0, .b = 0 },
    /// top-left, top-right, bottom-right, bottom-left
    radii: [4]f32 = .{ 0, 0, 0, 0 },
    opacity: f32 = 1,
};

pub const Shadow = struct { dx: f32 = 0, dy: f32 = 0, blur: f32 = 0, spread: f32 = 0, color: geom.Color };

fn colorF(c: geom.Color) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255,
        @as(f32, @floatFromInt(c.g)) / 255,
        @as(f32, @floatFromInt(c.b)) / 255,
        @as(f32, @floatFromInt(c.a)) / 255,
    };
}

const max_depth = 64;

pub const Builder = struct {
    gpa: std.mem.Allocator,
    scene: *Scene,
    scale: f32,
    off: geom.Point = .{},
    offs: [max_depth]geom.Point = undefined,
    n_offs: usize = 0,
    /// The clip in device pixels: x, y, w, h.
    clip: [4]f32,
    clips: [max_depth][4]f32 = undefined,
    n_clips: usize = 0,
    /// Set when a stack is too deep.
    failed: bool = false,

    pub fn init(gpa: std.mem.Allocator, scene: *Scene, scale: f32) Builder {
        return .{
            .gpa = gpa,
            .scene = scene,
            .scale = scale,
            .clip = .{ 0, 0, @floatFromInt(scene.width), @floatFromInt(scene.height) },
        };
    }

    /// Moves the origin for the quads that follow. Logical pixels.
    pub fn pushOffset(b: *Builder, dx: i32, dy: i32) void {
        if (b.n_offs == max_depth) {
            b.failed = true;
            return;
        }
        b.offs[b.n_offs] = b.off;
        b.n_offs += 1;
        b.off = .{ .x = b.off.x + dx, .y = b.off.y + dy };
    }

    pub fn popOffset(b: *Builder) void {
        if (b.n_offs == 0) return;
        b.n_offs -= 1;
        b.off = b.offs[b.n_offs];
    }

    fn deviceRect(b: *const Builder, r: geom.Rect) [4]f32 {
        const x0 = @round(@as(f32, @floatFromInt(r.x + b.off.x)) * b.scale);
        const y0 = @round(@as(f32, @floatFromInt(r.y + b.off.y)) * b.scale);
        const x1 = @round(@as(f32, @floatFromInt(r.x + b.off.x + r.w)) * b.scale);
        const y1 = @round(@as(f32, @floatFromInt(r.y + b.off.y + r.h)) * b.scale);
        return .{ x0, y0, x1 - x0, y1 - y0 };
    }

    fn intersect(a: [4]f32, c: [4]f32) [4]f32 {
        const x0 = @max(a[0], c[0]);
        const y0 = @max(a[1], c[1]);
        const x1 = @min(a[0] + a[2], c[0] + c[2]);
        const y1 = @min(a[1] + a[3], c[1] + c[3]);
        return .{ x0, y0, @max(x1 - x0, 0), @max(y1 - y0, 0) };
    }

    /// Intersects the clip with a rectangle. Logical pixels.
    pub fn pushClip(b: *Builder, r: geom.Rect) void {
        if (b.n_clips == max_depth) {
            b.failed = true;
            return;
        }
        b.clips[b.n_clips] = b.clip;
        b.n_clips += 1;
        b.clip = intersect(b.clip, b.deviceRect(r));
    }

    pub fn popClip(b: *Builder) void {
        if (b.n_clips == 0) return;
        b.n_clips -= 1;
        b.clip = b.clips[b.n_clips];
    }

    fn base(b: *const Builder, kind: Kind, rect: [4]f32) Quad {
        return .{
            .rect = rect,
            .clip = b.clip,
            .radii = .{ 0, 0, 0, 0 },
            .border = .{ 0, 0, 0, 0 },
            .fill = .{ 0, 0, 0, 0 },
            .fill2 = .{ 0, 0, 0, 0 },
            .border_color = .{ 0, 0, 0, 0 },
            .uv = .{ 0, 0, 0, 0 },
            .params = .{ 0, 0, 0, 1 },
            .kind = @backingInt(kind),
        };
    }

    pub fn box(b: *Builder, r: geom.Rect, style: BoxStyle) !void {
        if (b.failed) return error.NestingTooDeep;
        const rect = b.deviceRect(r);
        if (rect[2] <= 0 or rect[3] <= 0) return;
        if (intersect(rect, b.clip)[2] <= 0 or intersect(rect, b.clip)[3] <= 0) return;
        var q = b.base(.box, rect);
        var has_border = false;
        for (style.border, 0..) |w, i| {
            if (w > 0) {
                q.border[i] = @max(1, @round(w * b.scale));
                has_border = true;
            }
        }
        const fill2 = style.fill2 orelse style.fill;
        const shows_fill = style.fill.a > 0 or fill2.a > 0;
        if (!shows_fill and !has_border) return;
        if (has_border and style.border_color.a == 0 and !shows_fill) return;
        for (style.radii, 0..) |rad, i| q.radii[i] = rad * b.scale;
        q.fill = colorF(style.fill);
        q.fill2 = colorF(fill2);
        q.border_color = colorF(style.border_color);
        const a = style.gradient_angle_deg * std.math.pi / 180.0;
        q.params = .{ @sin(a), -@cos(a), 0, style.opacity };
        try b.scene.quads.append(b.gpa, q);
    }

    /// An image of the image page of the atlas, stretched to `r` with a
    /// filter. `uv` is its place in the page (`Atlas.image`), in texels.
    pub fn image(b: *Builder, r: geom.Rect, uv: [4]f32, opacity: f32) !void {
        if (b.failed) return error.NestingTooDeep;
        const rect = b.deviceRect(r);
        if (rect[2] <= 0 or rect[3] <= 0 or uv[2] <= 0 or uv[3] <= 0) return;
        const vis = intersect(rect, b.clip);
        if (vis[2] <= 0 or vis[3] <= 0) return;
        var q = b.base(.image, rect);
        q.uv = uv;
        q.params[3] = opacity;
        try b.scene.quads.append(b.gpa, q);
    }

    pub fn shadow(b: *Builder, r: geom.Rect, radii: [4]f32, s: Shadow) !void {
        if (b.failed) return error.NestingTooDeep;
        if (s.color.a == 0) return;
        var rect = b.deviceRect(r);
        const dx = s.dx * b.scale;
        const dy = s.dy * b.scale;
        const sp = s.spread * b.scale;
        rect = .{ rect[0] + dx - sp, rect[1] + dy - sp, rect[2] + 2 * sp, rect[3] + 2 * sp };
        if (rect[2] <= 0 or rect[3] <= 0) return;
        var q = b.base(.shadow, rect);
        for (radii, 0..) |rad, i| q.radii[i] = @max(0, rad * b.scale + sp);
        q.fill = colorF(s.color);
        q.fill2 = q.fill;
        q.params = .{ 0, 0, s.blur * b.scale, 1 };
        try b.scene.quads.append(b.gpa, q);
    }

    /// Adds one glyph quad for each glyph. x and y are the left end of the
    /// baseline in logical pixels. The position of a glyph rounds down to
    /// a quarter pixel: the whole part goes in the quad, and the rest
    /// selects the image in the atlas. The baseline rounds to a whole pixel.
    pub fn text(b: *Builder, atlas: *atlas_mod.Atlas, run: *const shape_mod.Run, x: i32, y: i32, color: geom.Color) !void {
        if (b.failed) return error.NestingTooDeep;
        if (color.a == 0) return;
        const ox = @as(f32, @floatFromInt(x + b.off.x)) * b.scale;
        const baseline = @round(@as(f32, @floatFromInt(y + b.off.y)) * b.scale);
        for (run.glyphs) |g| {
            const q4 = num.pxFloor((ox + g.x) * 4);
            const whole: i32 = @divFloor(q4, 4);
            const sub: u2 = @intCast(@mod(q4, 4));
            // A glyph that does not fit in the atlas is left out of the frame.
            const ag = atlas.get(run.font, g.id, sub) catch |e| switch (e) {
                error.GlyphTooLarge, error.AtlasFull => continue,
                else => return e,
            };
            if (ag.w == 0 or ag.h == 0) continue;
            const rect = [4]f32{ @as(f32, @floatFromInt(whole)) + ag.left, baseline + g.y + ag.top, ag.w, ag.h };
            const vis = intersect(rect, b.clip);
            if (vis[2] <= 0 or vis[3] <= 0) continue;
            var q = b.base(.glyph, rect);
            q.fill = colorF(color);
            q.fill2 = q.fill;
            q.uv = ag.uv;
            try b.scene.quads.append(b.gpa, q);
        }
    }
};

/// The direction of the iterations of a frame animation, as in CSS.
pub const Direction = enum(u8) { normal, reverse, alternate, alternate_reverse };

/// An animation that the render thread moves: a transition, a keyframe
/// animation, an option animation of `ztk::animate`, or the move of a
/// part. The quads `first` to `first + count` of the scene take their
/// values from `stops` sets of `count` quads in `Frame.anim_quads`,
/// which start at `from`. Set k is the paint at the offset
/// `Frame.anim_offsets[offsets + k]` of the iteration. With `base`, one
/// more set follows the stops: the paint with no animation, which shows
/// before the delay with no backward fill and after the end with no
/// forward fill.
pub const FrameAnim = struct {
    first: u32,
    count: u32,
    from: u32,
    stops: u32 = 2,
    offsets: u32 = 0,
    /// The time of the start, on the clock of the UI thread.
    start_us: i64,
    delay_us: i64,
    /// The time of one iteration.
    len_us: i64,
    timing: easing.Timing,
    /// The count of iterations. 0 is no end.
    iterations: f32 = 1,
    direction: Direction = .normal,
    fill_backwards: bool = true,
    fill_forwards: bool = true,
    base: bool = false,

    pub const Sample = struct {
        /// The eased progress in the iteration, or null for the base set.
        p: ?f32,
        done: bool,
    };

    fn reversedAt(a: FrameAnim, n: u64) bool {
        return switch (a.direction) {
            .normal => false,
            .reverse => true,
            .alternate => n % 2 == 1,
            .alternate_reverse => n % 2 == 0,
        };
    }

    /// The eased progress at a time, with the iterations, the direction,
    /// and the fill.
    pub fn sample(a: FrameAnim, time_us: i64) Sample {
        const since = time_us - a.start_us - a.delay_us;
        if (since < 0) {
            if (!a.fill_backwards and a.base) return .{ .p = null, .done = false };
            return .{ .p = a.timing.eval(if (a.reversedAt(0)) 1 else 0), .done = false };
        }
        const len: f64 = @floatFromInt(@max(a.len_us, 1));
        const iters: f64 = @as(f64, @floatFromInt(since)) / len;
        const count: f64 = a.iterations;
        if (count > 0 and iters >= count) {
            if (!a.fill_forwards and a.base) return .{ .p = null, .done = true };
            const last: u64 = @intFromFloat(@max(@ceil(count) - 1, 0));
            const frac: f32 = @floatCast(count - @floor(count));
            const p: f32 = if (frac == 0) 1 else frac;
            const q = if (a.reversedAt(last)) 1 - p else p;
            // The end of a move is exact: a spring can end near 1.
            return .{ .p = if (q == 1) 1 else a.timing.eval(q), .done = true };
        }
        const n: u64 = @intFromFloat(@floor(iters));
        var p: f32 = @floatCast(iters - @floor(iters));
        if (a.reversedAt(n)) p = 1 - p;
        return .{ .p = a.timing.eval(p), .done = false };
    }

    /// The eased progress of a transition at a time.
    pub fn progress(a: FrameAnim, time_us: i64) f32 {
        return a.sample(time_us).p orelse 0;
    }

    pub fn done(a: FrameAnim, time_us: i64) bool {
        return a.sample(time_us).done;
    }
};

fn lerp4(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    var o: [4]f32 = undefined;
    for (&o, a, b) |*x, p, q| x.* = p + (q - p) * t;
    return o;
}

fn mixQuad(p: Quad, q: Quad, t: f32) Quad {
    var out = q;
    out.rect = lerp4(p.rect, q.rect, t);
    out.radii = lerp4(p.radii, q.radii, t);
    out.border = lerp4(p.border, q.border, t);
    out.fill = lerp4(p.fill, q.fill, t);
    out.fill2 = lerp4(p.fill2, q.fill2, t);
    out.border_color = lerp4(p.border_color, q.border_color, t);
    out.params = lerp4(p.params, q.params, t);
    return out;
}

/// Writes the quads of each animation of the frame for a time. Returns
/// true when an animation still runs at that time.
pub fn applyAnims(f: *Frame, time_us: i64) bool {
    var running = false;
    const quads = f.scene.quads.items;
    const src = f.anim_quads.items;
    const offs = f.anim_offsets.items;
    for (f.anims.items) |a| {
        const sets = a.stops + @intFromBool(a.base);
        if (a.stops < 2 or a.first + a.count > quads.len or a.from + sets * a.count > src.len or a.offsets + a.stops > offs.len) continue;
        const s = a.sample(time_us);
        if (!s.done) running = true;
        const out = quads[a.first..][0..a.count];
        const p = s.p orelse {
            @memcpy(out, src[a.from + a.stops * a.count ..][0..a.count]);
            continue;
        };
        // The two stops around the progress, and the progress between them.
        const o = offs[a.offsets..][0..a.stops];
        var i: u32 = 1;
        while (i < a.stops - 1 and p > o[i]) i += 1;
        const span = o[i] - o[i - 1];
        // A spring or a curve can go past the ends, so the progress is not clamped.
        const t = if (span <= 0) 1 else (p - o[i - 1]) / span;
        const lo = src[a.from + (i - 1) * a.count ..][0..a.count];
        const hi = src[a.from + i * a.count ..][0..a.count];
        for (out, lo, hi) |*q, x, y| q.* = mixQuad(x, y, t);
    }
    return running;
}

/// A drag that the render thread moves with the pointer: the quads
/// `first` to `first + count` of the scene move along one axis by the
/// distance from `base` to the pointer, between `lo` and `hi`. A `stretch`
/// drag moves only the far edge of each quad. The distances are logical
/// pixels and `scale` turns them into device pixels. `rects` is the
/// index of the rectangles of the quads at the paint in `Frame.drag_rects`.
/// `gain` multiplies the distance: the content of a scrolled view moves
/// against its scrollbar thumb, by the ratio of the view to the track.
pub const FrameDrag = struct {
    first: u32,
    count: u32,
    rects: u32,
    axis: u1,
    stretch: bool = false,
    base: f32,
    lo: f32,
    hi: f32,
    scale: f32,
    gain: f32 = 1,
};

/// Moves the quads of each drag for a pointer position in logical pixels
/// of the window.
pub fn applyDrags(f: *Frame, px: f32, py: f32) void {
    const quads = f.scene.quads.items;
    const rects = f.drag_rects.items;
    for (f.drags.items) |d| {
        if (d.first + d.count > quads.len or d.rects + d.count > rects.len) continue;
        const ptr = if (d.axis == 0) px else py;
        const off = std.math.clamp(ptr - d.base, d.lo, d.hi) * d.gain * d.scale;
        for (quads[d.first..][0..d.count], rects[d.rects..][0..d.count]) |*q, r| {
            q.rect = r;
            if (d.stretch) q.rect[2 + @as(usize, d.axis)] = @max(r[2 + @as(usize, d.axis)] + off, 0) else q.rect[d.axis] = r[d.axis] + off;
        }
    }
}

/// All that the render thread needs for one frame. It has no pointer into
/// the widget tree or the interpreter. The patches own their bytes.
pub const Frame = struct {
    scene: Scene = .{},
    patches: std.ArrayListUnmanaged(AtlasPatch) = .empty,
    serial: u64 = 0,
    /// The transitions that the render thread moves, and their quads.
    anims: std.ArrayListUnmanaged(FrameAnim) = .empty,
    anim_quads: std.ArrayListUnmanaged(Quad) = .empty,
    anim_offsets: std.ArrayListUnmanaged(f32) = .empty,
    /// The drags that the render thread moves, and the rectangles of their quads.
    drags: std.ArrayListUnmanaged(FrameDrag) = .empty,
    drag_rects: std.ArrayListUnmanaged([4]f32) = .empty,
    /// The time of the frame on the clock of the UI thread, and the
    /// system time when the UI thread handed it over.
    time_us: i64 = 0,
    wall_us: i64 = 0,

    /// Frees the patches and clears the quads. The capacity stays.
    pub fn reset(f: *Frame, gpa: std.mem.Allocator) void {
        for (f.patches.items) |p| gpa.free(p.bytes);
        f.patches.clearRetainingCapacity();
        f.scene.quads.clearRetainingCapacity();
        f.anims.clearRetainingCapacity();
        f.anim_quads.clearRetainingCapacity();
        f.anim_offsets.clearRetainingCapacity();
        f.drags.clearRetainingCapacity();
        f.drag_rects.clearRetainingCapacity();
    }

    pub fn deinit(f: *Frame, gpa: std.mem.Allocator) void {
        for (f.patches.items) |p| gpa.free(p.bytes);
        f.patches.deinit(gpa);
        f.scene.deinit(gpa);
        f.anims.deinit(gpa);
        f.anim_quads.deinit(gpa);
        f.anim_offsets.deinit(gpa);
        f.drags.deinit(gpa);
        f.drag_rects.deinit(gpa);
    }
};
