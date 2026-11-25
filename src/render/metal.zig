//! The Metal renderer of macOS. It draws a scene with one instanced draw
//! call, with the design of the Vulkan renderer: each `Quad` is one
//! instance, read from a shared buffer by its instance index, and the
//! vertex function makes the four corners of a triangle strip. The
//! fragment function has the formulas of `renderer.zig`. The shaders are
//! Metal Shading Language source that `init` compiles with
//! `newLibraryWithSource:options:error:`, so the build needs no Metal
//! compiler. Metal has its clip space y axis upward, so the vertex
//! function flips y. The pixel position of the fragment has its origin at
//! the top left and the 0.5 of the pixel center, as in Vulkan. A draw
//! commits one command buffer and waits for it, so the CPU and the GPU
//! never share a buffer. The instance buffer grows by a factor of two. The
//! atlas page is one R8 texture that uploads again when the generation of
//! the atlas changes. An offscreen target is a private RGBA8 texture, and
//! `readPixels` copies it to a shared buffer.
//! SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");
const objc = @import("../sys/objc.zig");
const scene_mod = @import("../scene.zig");
const renderer_mod = @import("renderer.zig");
const Atlas = @import("../text/atlas.zig").Atlas;
const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Image = renderer_mod.Image;
const Id = objc.Id;
const Sel = objc.Sel;

pub const available = true;

extern fn MTLCreateSystemDefaultDevice() ?Id;

// The values of the Metal enumerations that the renderer uses.
const pixel_r8 = 10; // MTLPixelFormatR8Unorm
const pixel_rgba8 = 70; // MTLPixelFormatRGBA8Unorm
const blend_one = 1; // MTLBlendFactorOne
const blend_one_minus_src_alpha = 5; // MTLBlendFactorOneMinusSourceAlpha
const usage_shader_read = 1; // MTLTextureUsageShaderRead
const usage_render_target = 4; // MTLTextureUsageRenderTarget
const storage_private = 2; // MTLStorageModePrivate
const resource_shared = 0; // MTLResourceStorageModeShared
const load_clear = 2; // MTLLoadActionClear
const store_store = 1; // MTLStoreActionStore
const primitive_triangle_strip = 4; // MTLPrimitiveTypeTriangleStrip
const status_completed = 4; // MTLCommandBufferStatusCompleted

const ClearColor = extern struct { r: f64, g: f64, b: f64, a: f64 };
const Origin = extern struct { x: usize, y: usize, z: usize };
const Size = extern struct { w: usize, h: usize, d: usize };
const Region = extern struct { origin: Origin, size: Size };

const atlas_size: usize = Atlas.page_size;

const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\
    \\struct Quad {
    \\    float4 rect; float4 clip; float4 radii; float4 border;
    \\    float4 fill; float4 fill2; float4 border_color; float4 uv; float4 params;
    \\    uint kind; uint pad0; uint pad1; uint pad2;
    \\};
    \\
    \\struct Out {
    \\    float4 pos [[position]];
    \\    uint index [[flat]];
    \\};
    \\
    \\vertex Out quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
    \\                       const device Quad *quads [[buffer(0)]],
    \\                       constant float2 &target [[buffer(1)]]) {
    \\    Quad q = quads[iid];
    \\    float pad = 0.0;
    \\    if (q.kind == 0u) pad = 1.0;
    \\    if (q.kind == 1u) pad = max(q.params.z, 1.0) + 1.0;
    \\    float2 lo = q.rect.xy - pad;
    \\    float2 hi = q.rect.xy + q.rect.zw + pad;
    \\    lo = max(lo, q.clip.xy);
    \\    hi = min(hi, q.clip.xy + q.clip.zw);
    \\    hi = max(hi, lo);
    \\    float2 corner = float2(float(vid & 1u), float(vid >> 1u));
    \\    float2 p = mix(lo, hi, corner) / target * 2.0 - 1.0;
    \\    Out o;
    \\    o.pos = float4(p.x, -p.y, 0.0, 1.0);
    \\    o.index = iid;
    \\    return o;
    \\}
    \\
    \\static float clamp01(float x) { return clamp(x, 0.0, 1.0); }
    \\
    \\static float roundedDistance(float2 p, float4 rect, float4 radii) {
    \\    float hw = rect.z * 0.5;
    \\    float hh = rect.w * 0.5;
    \\    float dx = p.x - (rect.x + hw);
    \\    float dy = p.y - (rect.y + hh);
    \\    float limit = min(hw, hh);
    \\    int idx = (dy < 0.0) ? ((dx < 0.0) ? 0 : 1) : ((dx < 0.0) ? 3 : 2);
    \\    float r = min(radii[idx], limit);
    \\    float qx = abs(dx) - hw + r;
    \\    float qy = abs(dy) - hh + r;
    \\    float mx = max(qx, 0.0);
    \\    float my = max(qy, 0.0);
    \\    return min(max(qx, qy), 0.0) + sqrt(mx * mx + my * my) - r;
    \\}
    \\
    \\static float2 boxCoverage(float2 p, Quad q) {
    \\    float outer = clamp01(0.5 - roundedDistance(p, q.rect, q.radii));
    \\    float bt = q.border[0], br = q.border[1], bb = q.border[2], bl = q.border[3];
    \\    if (bt == 0.0 && br == 0.0 && bb == 0.0 && bl == 0.0) return float2(outer, 0.0);
    \\    float4 ir = float4(q.rect.x + bl, q.rect.y + bt, q.rect.z - bl - br, q.rect.w - bt - bb);
    \\    if (ir.z <= 0.0 || ir.w <= 0.0) return float2(0.0, outer);
    \\    float4 irad = float4(max(q.radii[0] - max(bt, bl), 0.0), max(q.radii[1] - max(bt, br), 0.0),
    \\                         max(q.radii[2] - max(bb, br), 0.0), max(q.radii[3] - max(bb, bl), 0.0));
    \\    float inner = clamp01(0.5 - roundedDistance(p, ir, irad));
    \\    return float2(inner, max(outer - inner, 0.0));
    \\}
    \\
    \\static float shadowCoverage(float2 p, Quad q) {
    \\    float d = roundedDistance(p, q.rect, q.radii);
    \\    float blur = max(q.params.z, 1.0);
    \\    float t = clamp01(0.5 - d / blur);
    \\    return t * t * (3.0 - 2.0 * t);
    \\}
    \\
    \\static float gradientT(float2 p, Quad q) {
    \\    float dx = q.params.x, dy = q.params.y;
    \\    float len = abs(q.rect.z * dx) + abs(q.rect.w * dy);
    \\    if (len <= 0.0) return 0.0;
    \\    float cx = q.rect.x + q.rect.z * 0.5;
    \\    float cy = q.rect.y + q.rect.w * 0.5;
    \\    return clamp01(((p.x - cx) * dx + (p.y - cy) * dy) / len + 0.5);
    \\}
    \\
    \\fragment float4 quad_fragment(Out in [[stage_in]], const device Quad *quads [[buffer(0)]],
    \\                              texture2d<float, access::read> atlas [[texture(0)]]) {
    \\    Quad q = quads[in.index];
    \\    float2 p = in.pos.xy;
    \\    if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.x + q.clip.z || p.y >= q.clip.y + q.clip.w) discard_fragment();
    \\    float opacity = q.params.w;
    \\    if (q.kind == 0u) {
    \\        float2 c = boxCoverage(p, q);
    \\        float4 col = all(q.fill == q.fill2) ? q.fill : mix(q.fill, q.fill2, gradientT(p, q));
    \\        float fa = col.a * c.x * opacity;
    \\        float ba = q.border_color.a * c.y * opacity;
    \\        float3 rgb = q.border_color.rgb * ba + col.rgb * fa * (1.0 - ba);
    \\        return float4(rgb, 1.0 - (1.0 - fa) * (1.0 - ba));
    \\    } else if (q.kind == 1u) {
    \\        float a = q.fill.a * shadowCoverage(p, q) * opacity;
    \\        return float4(q.fill.rgb * a, a);
    \\    } else if (q.kind == 2u) {
    \\        int2 t = int2(q.uv.xy) + int2(floor(p)) - int2(q.rect.xy);
    \\        float a = q.fill.a * atlas.read(uint2(t)).r * opacity;
    \\        return float4(q.fill.rgb * a, a);
    \\    }
    \\    discard_fragment();
    \\    return float4(0.0);
    \\}
;

pub const Options = struct {};

pub const Target = struct {
    texture: Id,
    width: u32,
    height: u32,
};

pub const Metal = struct {
    gpa: std.mem.Allocator,
    device: Id,
    queue: Id,
    pipeline: Id,
    atlas_texture: Id,
    atlas_generation: ?u32 = null,
    instances: ?Id = null,
    instances_size: usize = 0,
    readback: ?Id = null,
    readback_size: usize = 0,
    target: ?*Target = null,

    pub fn init(gpa: std.mem.Allocator, _: Options) !*Metal {
        const pool = objc.Pool.push();
        defer pool.pop();
        const device = MTLCreateSystemDefaultDevice() orelse return error.NoMetal;
        errdefer objc.release(device);
        const queue = call(Id, device, "newCommandQueue", .{});
        errdefer objc.release(queue);

        var err: ?Id = null;
        const src = objc.nsString(shader_source);
        defer objc.release(src);
        const lib = objc.call(fn (Id, Sel, Id, ?Id, *?Id) callconv(.c) ?Id, device, "newLibraryWithSource:options:error:", .{ src, null, &err }) orelse {
            if (err) |e| logError("Metal shader", e);
            return error.MetalFailed;
        };
        defer objc.release(lib);
        const vname = objc.nsString("quad_vertex");
        defer objc.release(vname);
        const fname = objc.nsString("quad_fragment");
        defer objc.release(fname);
        const vfn = call(Id, lib, "newFunctionWithName:", .{vname});
        defer objc.release(vfn);
        const ffn = call(Id, lib, "newFunctionWithName:", .{fname});
        defer objc.release(ffn);

        const desc = objc.new(objc.class("MTLRenderPipelineDescriptor").?);
        defer objc.release(desc);
        callVoid(desc, "setVertexFunction:", .{vfn});
        callVoid(desc, "setFragmentFunction:", .{ffn});
        const attachments = call(Id, desc, "colorAttachments", .{});
        const color = objc.call(fn (Id, Sel, usize) callconv(.c) Id, attachments, "objectAtIndexedSubscript:", .{0});
        callVoid(color, "setPixelFormat:", .{@as(usize, pixel_rgba8)});
        callVoid(color, "setBlendingEnabled:", .{true});
        // Premultiplied "source over", as in the Vulkan renderer.
        callVoid(color, "setSourceRGBBlendFactor:", .{@as(usize, blend_one)});
        callVoid(color, "setDestinationRGBBlendFactor:", .{@as(usize, blend_one_minus_src_alpha)});
        callVoid(color, "setSourceAlphaBlendFactor:", .{@as(usize, blend_one)});
        callVoid(color, "setDestinationAlphaBlendFactor:", .{@as(usize, blend_one_minus_src_alpha)});
        const pipeline = objc.call(fn (Id, Sel, Id, *?Id) callconv(.c) ?Id, device, "newRenderPipelineStateWithDescriptor:error:", .{ desc, &err }) orelse {
            if (err) |e| logError("Metal pipeline", e);
            return error.MetalFailed;
        };
        errdefer objc.release(pipeline);

        const tdesc = objc.call(fn (objc.Class, Sel, usize, usize, usize, bool) callconv(.c) Id, objc.class("MTLTextureDescriptor").?, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_r8, atlas_size, atlas_size, false });
        callVoid(tdesc, "setUsage:", .{@as(usize, usage_shader_read)});
        const atlas_texture = call(Id, device, "newTextureWithDescriptor:", .{tdesc});

        const m = try gpa.create(Metal);
        m.* = .{ .gpa = gpa, .device = device, .queue = queue, .pipeline = pipeline, .atlas_texture = atlas_texture };
        return m;
    }

    pub fn deinit(m: *Metal) void {
        if (m.instances) |b| objc.release(b);
        if (m.readback) |b| objc.release(b);
        objc.release(m.atlas_texture);
        objc.release(m.pipeline);
        objc.release(m.queue);
        objc.release(m.device);
        m.gpa.destroy(m);
    }

    /// The name of the GPU.
    pub fn deviceName(m: *const Metal) []const u8 {
        return objc.utf8(call(Id, m.device, "name", .{}));
    }

    pub fn createOffscreen(m: *Metal, width: u32, height: u32) !*Target {
        const desc = objc.call(fn (objc.Class, Sel, usize, usize, usize, bool) callconv(.c) Id, objc.class("MTLTextureDescriptor").?, "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ pixel_rgba8, width, height, false });
        callVoid(desc, "setUsage:", .{@as(usize, usage_render_target | usage_shader_read)});
        callVoid(desc, "setStorageMode:", .{@as(usize, storage_private)});
        const tex = objc.call(fn (Id, Sel, Id) callconv(.c) ?Id, m.device, "newTextureWithDescriptor:", .{desc}) orelse return error.MetalFailed;
        const t = try m.gpa.create(Target);
        t.* = .{ .texture = tex, .width = width, .height = height };
        return t;
    }

    pub fn destroyTarget(m: *Metal, t: *Target) void {
        if (m.target == t) m.target = null;
        objc.release(t.texture);
        m.gpa.destroy(t);
    }

    pub fn setTarget(m: *Metal, t: *Target) void {
        m.target = t;
    }

    fn syncAtlas(m: *Metal, atlas: *const Atlas) void {
        if (m.atlas_generation == atlas.generation) return;
        const page = atlas.page();
        if (page.len == atlas_size * atlas_size) {
            const region = Region{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .w = atlas_size, .h = atlas_size, .d = 1 } };
            objc.call(fn (Id, Sel, Region, usize, [*]const u8, usize) callconv(.c) void, m.atlas_texture, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, 0, page.ptr, atlas_size });
        }
        m.atlas_generation = atlas.generation;
    }

    /// A shared buffer of at least `need` bytes in `slot`, grown by a factor of two.
    fn ensureBuffer(m: *Metal, slot: *?Id, size: *usize, need: usize) !Id {
        if (slot.* == null or size.* < need) {
            var n: usize = @max(size.*, 64 * 1024);
            while (n < need) n *= 2;
            if (slot.*) |b| objc.release(b);
            slot.* = objc.call(fn (Id, Sel, usize, usize) callconv(.c) ?Id, m.device, "newBufferWithLength:options:", .{ n, resource_shared }) orelse return error.OutOfMemory;
            size.* = n;
        }
        return slot.*.?;
    }

    /// Draws a scene to the current target.
    pub fn draw(m: *Metal, scene: *const Scene, atlas: *const Atlas) !void {
        const t = m.target orelse return error.NoTarget;
        const pool = objc.Pool.push();
        defer pool.pop();
        const n = scene.quads.items.len;
        const need = @max(n * @sizeOf(Quad), @sizeOf(Quad));
        const buf = try m.ensureBuffer(&m.instances, &m.instances_size, need);
        if (n > 0) {
            const dst: [*]u8 = @ptrCast(call(*anyopaque, buf, "contents", .{}));
            @memcpy(dst[0 .. n * @sizeOf(Quad)], std.mem.sliceAsBytes(scene.quads.items));
        }
        m.syncAtlas(atlas);

        const pass = objc.call(fn (objc.Class, Sel) callconv(.c) Id, objc.class("MTLRenderPassDescriptor").?, "renderPassDescriptor", .{});
        const atts = call(Id, pass, "colorAttachments", .{});
        const att = objc.call(fn (Id, Sel, usize) callconv(.c) Id, atts, "objectAtIndexedSubscript:", .{0});
        callVoid(att, "setTexture:", .{t.texture});
        callVoid(att, "setLoadAction:", .{@as(usize, load_clear)});
        callVoid(att, "setStoreAction:", .{@as(usize, store_store)});
        const cc = scene.clear;
        objc.call(fn (Id, Sel, ClearColor) callconv(.c) void, att, "setClearColor:", .{ClearColor{ .r = cc[0], .g = cc[1], .b = cc[2], .a = cc[3] }});

        const cmd = call(Id, m.queue, "commandBuffer", .{});
        const enc = call(Id, cmd, "renderCommandEncoderWithDescriptor:", .{pass});
        if (n > 0) {
            callVoid(enc, "setRenderPipelineState:", .{m.pipeline});
            objc.call(fn (Id, Sel, Id, usize, usize) callconv(.c) void, enc, "setVertexBuffer:offset:atIndex:", .{ buf, 0, 0 });
            objc.call(fn (Id, Sel, Id, usize, usize) callconv(.c) void, enc, "setFragmentBuffer:offset:atIndex:", .{ buf, 0, 0 });
            const size = [2]f32{ @floatFromInt(t.width), @floatFromInt(t.height) };
            objc.call(fn (Id, Sel, *const anyopaque, usize, usize) callconv(.c) void, enc, "setVertexBytes:length:atIndex:", .{ &size, @sizeOf([2]f32), 1 });
            objc.call(fn (Id, Sel, Id, usize) callconv(.c) void, enc, "setFragmentTexture:atIndex:", .{ m.atlas_texture, 0 });
            objc.call(fn (Id, Sel, usize, usize, usize, usize) callconv(.c) void, enc, "drawPrimitives:vertexStart:vertexCount:instanceCount:", .{ primitive_triangle_strip, 0, 4, n });
        }
        callVoid(enc, "endEncoding", .{});
        try commitAndWait(cmd);
    }

    /// Copies the pixels of an offscreen target to an image of the same size.
    pub fn readPixels(m: *Metal, t: *Target, out: *Image) !void {
        const pool = objc.Pool.push();
        defer pool.pop();
        const row: usize = @as(usize, t.width) * 4;
        const bytes = row * t.height;
        const buf = try m.ensureBuffer(&m.readback, &m.readback_size, bytes);
        const cmd = call(Id, m.queue, "commandBuffer", .{});
        const blit = call(Id, cmd, "blitCommandEncoder", .{});
        objc.call(fn (Id, Sel, Id, usize, usize, Origin, Size, Id, usize, usize, usize) callconv(.c) void, blit, "copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:", .{
            t.texture, 0, 0, Origin{ .x = 0, .y = 0, .z = 0 }, Size{ .w = t.width, .h = t.height, .d = 1 }, buf, 0, row, bytes,
        });
        callVoid(blit, "endEncoding", .{});
        try commitAndWait(cmd);
        const src: [*]const u8 = @ptrCast(call(*anyopaque, buf, "contents", .{}));
        @memcpy(out.pixels[0..bytes], src[0..bytes]);
        out.width = t.width;
        out.height = t.height;
    }

    // ---- The Renderer interface ----

    fn rDeinit(ptr: *anyopaque) void {
        const m: *Metal = @ptrCast(@alignCast(ptr));
        m.deinit();
    }

    fn rDraw(ptr: *anyopaque, scene: *const Scene, atlas: *const Atlas) anyerror!void {
        const m: *Metal = @ptrCast(@alignCast(ptr));
        return m.draw(scene, atlas);
    }

    const vtable: renderer_mod.Renderer.VTable = .{ .deinit = rDeinit, .draw = rDraw };

    pub fn renderer(m: *Metal) renderer_mod.Renderer {
        return .{ .ptr = m, .vtable = &vtable };
    }
};

fn call(comptime Ret: type, target: Id, selector: [*:0]const u8, args: anytype) Ret {
    const Args = @TypeOf(args);
    const fields = @typeInfo(Args).@"struct".fields;
    return switch (fields.len) {
        0 => objc.call(fn (Id, Sel) callconv(.c) Ret, target, selector, args),
        1 => objc.call(fn (Id, Sel, fields[0].type) callconv(.c) Ret, target, selector, args),
        else => @compileError("call has at most one argument; use objc.call for more"),
    };
}

fn callVoid(target: Id, selector: [*:0]const u8, args: anytype) void {
    call(void, target, selector, args);
}

fn commitAndWait(cmd: Id) !void {
    callVoid(cmd, "commit", .{});
    callVoid(cmd, "waitUntilCompleted", .{});
    const status = call(usize, cmd, "status", .{});
    if (status != status_completed) {
        if (call(?Id, cmd, "error", .{})) |e| logError("Metal command buffer", e);
        return error.MetalFailed;
    }
}

fn logError(what: []const u8, err: Id) void {
    const desc = call(Id, err, "localizedDescription", .{});
    std.log.err("{s}: {s}", .{ what, objc.utf8(desc) });
}
