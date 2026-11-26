// SPDX-License-Identifier: BSD-2-Clause
// The quad shaders of the Direct3D 12 renderer, a port of quad.vert and
// quad.frag. The quads are a structured buffer, and SV_InstanceID picks
// one. The vertex shader makes the four corners of a triangle strip from
// SV_VertexID, with the padding and the clip of quad.vert. The pixel
// shader reads the quad again by its index and has the formulas of
// src/render/renderer.zig. The atlas page is a byte buffer of
// page_size x page_size bytes, read 4 bytes at a time. The output color
// is premultiplied, for the blend ONE and INV_SRC_ALPHA on a UNORM
// target, as in quad.frag. Clip space has y up, so the vertex shader
// flips y. SV_Position in the pixel shader has y down and the 0.5 of the
// pixel center.

struct Quad {
    float4 rect;
    float4 clip;
    float4 radii;
    float4 border;
    float4 fill;
    float4 fill2;
    float4 border_color;
    float4 uv;
    float4 params;
    uint kind;
    uint3 pad;
};

cbuffer Push : register(b0) {
    float2 target;
};

StructuredBuffer<Quad> quads : register(t0);
ByteAddressBuffer atlas : register(t1);
// The RGBA image page of the atlas: 4 bytes for each texel, R first.
ByteAddressBuffer images : register(t2);

static const uint page_size = 1024;

struct VOut {
    float4 pos : SV_Position;
    nointerpolation uint index : INDEX;
};

VOut vs_main(uint vid : SV_VertexID, uint iid : SV_InstanceID) {
    Quad q = quads[iid];
    float pad = 0.0;
    if (q.kind == 0u) pad = 1.0;
    if (q.kind == 1u) pad = max(q.params.z, 1.0) + 1.0;
    float2 lo = q.rect.xy - pad;
    float2 hi = q.rect.xy + q.rect.zw + pad;
    lo = max(lo, q.clip.xy);
    hi = min(hi, q.clip.xy + q.clip.zw);
    hi = max(hi, lo);
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    float2 p = lerp(lo, hi, corner);
    float2 ndc = p / target * 2.0 - 1.0;
    VOut o;
    o.pos = float4(ndc.x, -ndc.y, 0.0, 1.0);
    o.index = iid;
    return o;
}

float clamp01(float x) {
    return clamp(x, 0.0, 1.0);
}

// roundedDistance: negative inside. The radii are top-left, top-right,
// bottom-right, and bottom-left.
float roundedDistance(float2 p, float4 rect, float4 radii) {
    float hw = rect.z * 0.5;
    float hh = rect.w * 0.5;
    float cx = rect.x + hw;
    float cy = rect.y + hh;
    float dx = p.x - cx;
    float dy = p.y - cy;
    float limit = min(hw, hh);
    int idx = (dy < 0.0) ? ((dx < 0.0) ? 0 : 1) : ((dx < 0.0) ? 3 : 2);
    float r = min(radii[idx], limit);
    float qx = abs(dx) - hw + r;
    float qy = abs(dy) - hh + r;
    float mx = max(qx, 0.0);
    float my = max(qy, 0.0);
    return min(max(qx, qy), 0.0) + sqrt(mx * mx + my * my) - r;
}

// boxCoverage: x is the fill coverage, y is the border coverage.
float2 boxCoverage(Quad q, float2 p) {
    float outer = clamp01(0.5 - roundedDistance(p, q.rect, q.radii));
    float bt = q.border[0];
    float br = q.border[1];
    float bb = q.border[2];
    float bl = q.border[3];
    if (bt == 0.0 && br == 0.0 && bb == 0.0 && bl == 0.0) return float2(outer, 0.0);
    float4 inner_rect = float4(q.rect.x + bl, q.rect.y + bt, q.rect.z - bl - br, q.rect.w - bt - bb);
    if (inner_rect.z <= 0.0 || inner_rect.w <= 0.0) return float2(0.0, outer);
    float4 inner_radii = float4(
        max(q.radii[0] - max(bt, bl), 0.0),
        max(q.radii[1] - max(bt, br), 0.0),
        max(q.radii[2] - max(bb, br), 0.0),
        max(q.radii[3] - max(bb, bl), 0.0));
    float inner = clamp01(0.5 - roundedDistance(p, inner_rect, inner_radii));
    return float2(inner, max(outer - inner, 0.0));
}

// shadowCoverage: a smooth step over the blur width.
float shadowCoverage(Quad q, float2 p) {
    float d = roundedDistance(p, q.rect, q.radii);
    float blur = max(q.params.z, 1.0);
    float t = clamp01(0.5 - d / blur);
    return t * t * (3.0 - 2.0 * t);
}

// gradientT: the position along the gradient line, 0 to 1.
float gradientT(Quad q, float2 p) {
    float dx = q.params.x;
    float dy = q.params.y;
    float len = abs(q.rect.z * dx) + abs(q.rect.w * dy);
    if (len <= 0.0) return 0.0;
    float cx = q.rect.x + q.rect.z * 0.5;
    float cy = q.rect.y + q.rect.w * 0.5;
    return clamp01(((p.x - cx) * dx + (p.y - cy) * dy) / len + 0.5);
}

// The coverage byte of the atlas at a texel, 0 to 1.
float atlasAt(int2 t) {
    uint at = uint(t.y) * page_size + uint(t.x);
    uint word = atlas.Load(at & ~3u);
    return float((word >> ((at & 3u) * 8u)) & 0xffu) / 255.0;
}

// The texel of the image page at `t`, straight RGBA from 0 to 1.
float4 imageAt(int2 t) {
    uint word = images.Load((uint(t.y) * page_size + uint(t.x)) * 4u);
    return float4(float(word & 0xffu), float((word >> 8u) & 0xffu), float((word >> 16u) & 0xffu), float(word >> 24u)) / 255.0;
}

float4 ps_main(VOut i) : SV_Target {
    Quad q = quads[i.index];
    float2 p = i.pos.xy;
    if (p.x < q.clip.x || p.y < q.clip.y || p.x >= q.clip.x + q.clip.z || p.y >= q.clip.y + q.clip.w) discard;
    float opacity = q.params.w;
    float4 o = float4(0.0, 0.0, 0.0, 0.0);
    if (q.kind == 0u) {
        float2 c = boxCoverage(q, p);
        float4 col = all(q.fill == q.fill2) ? q.fill : lerp(q.fill, q.fill2, gradientT(q, p));
        float fa = col.a * c.x * opacity;
        float ba = q.border_color.a * c.y * opacity;
        float3 rgb = q.border_color.rgb * ba + col.rgb * fa * (1.0 - ba);
        float a = 1.0 - (1.0 - fa) * (1.0 - ba);
        o = float4(rgb, a);
    } else if (q.kind == 1u) {
        float cov = shadowCoverage(q, p);
        float a = q.fill.a * cov * opacity;
        o = float4(q.fill.rgb * a, a);
    } else if (q.kind == 2u) {
        int2 t = int2(q.uv.xy) + int2(floor(p)) - int2(q.rect.xy);
        float cov = atlasAt(t);
        float a = q.fill.a * cov * opacity;
        o = float4(q.fill.rgb * a, a);
    } else if (q.kind == 3u) {
        // The bilinear filter of the CPU renderer, on four texels of the image page.
        float2 u = clamp(q.uv.xy + (p - q.rect.xy) * (q.uv.zw / q.rect.zw) - 0.5, 0.0, 1022.0);
        float2 f = u - floor(u);
        int2 t = int2(floor(u));
        float4 c = lerp(lerp(imageAt(t), imageAt(t + int2(1, 0)), f.x),
                        lerp(imageAt(t + int2(0, 1)), imageAt(t + int2(1, 1)), f.x), f.y);
        float a = c.a * opacity;
        o = float4(c.rgb * a, a);
    } else {
        discard;
    }
    return o;
}
