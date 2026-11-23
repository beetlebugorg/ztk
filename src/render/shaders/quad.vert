// SPDX-License-Identifier: BSD-2-Clause
// The vertex shader of the quad renderer. Each instance is one Quad of
// the scene. gl_VertexIndex 0 to 3 gives the corners of a triangle strip.
// A box grows by one pixel for the anti-aliasing, a shadow by its blur
// plus one pixel, and a glyph has its exact rectangle. The quad is cut to
// its clip rectangle, which saves fragments. The fragment shader tests the
// clip again.
#version 450

layout(location = 0) in vec4 a_rect;
layout(location = 1) in vec4 a_clip;
layout(location = 2) in vec4 a_radii;
layout(location = 3) in vec4 a_border;
layout(location = 4) in vec4 a_fill;
layout(location = 5) in vec4 a_fill2;
layout(location = 6) in vec4 a_border_color;
layout(location = 7) in vec4 a_uv;
layout(location = 8) in vec4 a_params;
layout(location = 9) in uint a_kind;

layout(push_constant) uniform Push {
    vec2 target;
} pc;

layout(location = 0) flat out vec4 f_rect;
layout(location = 1) flat out vec4 f_clip;
layout(location = 2) flat out vec4 f_radii;
layout(location = 3) flat out vec4 f_border;
layout(location = 4) flat out vec4 f_fill;
layout(location = 5) flat out vec4 f_fill2;
layout(location = 6) flat out vec4 f_border_color;
layout(location = 7) flat out vec4 f_uv;
layout(location = 8) flat out vec4 f_params;
layout(location = 9) flat out uint f_kind;

void main() {
    float pad = 0.0;
    if (a_kind == 0u) pad = 1.0;
    if (a_kind == 1u) pad = max(a_params.z, 1.0) + 1.0;
    vec2 lo = a_rect.xy - pad;
    vec2 hi = a_rect.xy + a_rect.zw + pad;
    lo = max(lo, a_clip.xy);
    hi = min(hi, a_clip.xy + a_clip.zw);
    hi = max(hi, lo);
    vec2 corner = vec2(float(gl_VertexIndex & 1), float(gl_VertexIndex >> 1));
    vec2 pos = mix(lo, hi, corner);
    gl_Position = vec4(pos / pc.target * 2.0 - 1.0, 0.0, 1.0);
    f_rect = a_rect;
    f_clip = a_clip;
    f_radii = a_radii;
    f_border = a_border;
    f_fill = a_fill;
    f_fill2 = a_fill2;
    f_border_color = a_border_color;
    f_uv = a_uv;
    f_params = a_params;
    f_kind = a_kind;
}
