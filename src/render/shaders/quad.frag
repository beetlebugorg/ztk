// SPDX-License-Identifier: BSD-2-Clause
// The fragment shader of the quad renderer. It has the formulas of
// src/render/renderer.zig, one function for each function there:
// roundedDistance, boxCoverage, shadowCoverage, and gradientT. The pixel
// center is gl_FragCoord.xy, which has the 0.5 already. The output color
// is premultiplied, so that a box with a fill and a border blends in one
// step. The blend is ONE and ONE_MINUS_SRC_ALPHA on the UNORM target. The
// result equals "source over" of the CPU renderer.
#version 450
#extension GL_EXT_samplerless_texture_functions : require

layout(location = 0) flat in vec4 f_rect;
layout(location = 1) flat in vec4 f_clip;
layout(location = 2) flat in vec4 f_radii;
layout(location = 3) flat in vec4 f_border;
layout(location = 4) flat in vec4 f_fill;
layout(location = 5) flat in vec4 f_fill2;
layout(location = 6) flat in vec4 f_border_color;
layout(location = 7) flat in vec4 f_uv;
layout(location = 8) flat in vec4 f_params;
layout(location = 9) flat in uint f_kind;

layout(set = 0, binding = 0) uniform texture2D atlas;
layout(set = 0, binding = 1) uniform texture2D images;

layout(location = 0) out vec4 out_color;

float clamp01(float x) {
    return clamp(x, 0.0, 1.0);
}

// roundedDistance: negative inside. The radii are top-left, top-right,
// bottom-right, and bottom-left.
float roundedDistance(vec2 p, vec4 rect, vec4 radii) {
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
vec2 boxCoverage(vec2 p) {
    float outer = clamp01(0.5 - roundedDistance(p, f_rect, f_radii));
    float bt = f_border[0];
    float br = f_border[1];
    float bb = f_border[2];
    float bl = f_border[3];
    if (bt == 0.0 && br == 0.0 && bb == 0.0 && bl == 0.0) return vec2(outer, 0.0);
    vec4 inner_rect = vec4(f_rect.x + bl, f_rect.y + bt, f_rect.z - bl - br, f_rect.w - bt - bb);
    if (inner_rect.z <= 0.0 || inner_rect.w <= 0.0) return vec2(0.0, outer);
    vec4 inner_radii = vec4(
        max(f_radii[0] - max(bt, bl), 0.0),
        max(f_radii[1] - max(bt, br), 0.0),
        max(f_radii[2] - max(bb, br), 0.0),
        max(f_radii[3] - max(bb, bl), 0.0));
    float inner = clamp01(0.5 - roundedDistance(p, inner_rect, inner_radii));
    return vec2(inner, max(outer - inner, 0.0));
}

// shadowCoverage: a smooth step over the blur width.
float shadowCoverage(vec2 p) {
    float d = roundedDistance(p, f_rect, f_radii);
    float blur = max(f_params.z, 1.0);
    float t = clamp01(0.5 - d / blur);
    return t * t * (3.0 - 2.0 * t);
}

// gradientT: the position along the gradient line, 0 to 1.
float gradientT(vec2 p) {
    float dx = f_params.x;
    float dy = f_params.y;
    float len = abs(f_rect.z * dx) + abs(f_rect.w * dy);
    if (len <= 0.0) return 0.0;
    float cx = f_rect.x + f_rect.z * 0.5;
    float cy = f_rect.y + f_rect.w * 0.5;
    return clamp01(((p.x - cx) * dx + (p.y - cy) * dy) / len + 0.5);
}

void main() {
    vec2 p = gl_FragCoord.xy;
    if (p.x < f_clip.x || p.y < f_clip.y || p.x >= f_clip.x + f_clip.z || p.y >= f_clip.y + f_clip.w) discard;
    float opacity = f_params.w;
    if (f_kind == 0u) {
        vec2 c = boxCoverage(p);
        vec4 col = (f_fill == f_fill2) ? f_fill : mix(f_fill, f_fill2, gradientT(p));
        float fa = col.a * c.x * opacity;
        float ba = f_border_color.a * c.y * opacity;
        vec3 rgb = f_border_color.rgb * ba + col.rgb * fa * (1.0 - ba);
        float a = 1.0 - (1.0 - fa) * (1.0 - ba);
        out_color = vec4(rgb, a);
    } else if (f_kind == 1u) {
        float cov = shadowCoverage(p);
        float a = f_fill.a * cov * opacity;
        out_color = vec4(f_fill.rgb * a, a);
    } else if (f_kind == 2u) {
        ivec2 t = ivec2(f_uv.xy) + ivec2(floor(p)) - ivec2(f_rect.xy);
        float cov = texelFetch(atlas, t, 0).r;
        float a = f_fill.a * cov * opacity;
        out_color = vec4(f_fill.rgb * a, a);
    } else if (f_kind == 3u) {
        // The bilinear filter of the CPU renderer, on four texels of the image page.
        vec2 u = clamp(f_uv.xy + (p - f_rect.xy) * (f_uv.zw / f_rect.zw) - 0.5, 0.0, 1022.0);
        vec2 f = u - floor(u);
        ivec2 i = ivec2(floor(u));
        vec4 c = mix(mix(texelFetch(images, i, 0), texelFetch(images, i + ivec2(1, 0), 0), f.x),
                     mix(texelFetch(images, i + ivec2(0, 1), 0), texelFetch(images, i + ivec2(1, 1), 0), f.x), f.y);
        float a = c.a * opacity;
        out_color = vec4(c.rgb * a, a);
    } else {
        discard;
    }
}
