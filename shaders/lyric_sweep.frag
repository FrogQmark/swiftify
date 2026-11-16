/*
 * Swiftify, a spotify player for desktop
 * Copyright (C) 2026  shred0s
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#version 440
// Feathered horizontal karaoke wipe with a subtle bloom along the moving edge.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec4 glowColor;
    float progress;
    float feather;
    float baseAlpha;
    float glowBoost;
};

layout(binding = 1) uniform sampler2D source;

void main()
{
    vec4 tex = texture(source, qt_TexCoord0);
    float t = clamp(progress, 0.0, 1.0);
    float f = max(feather, 0.02);
    float head = mix(-f, 1.0 + f, t);
    float lit = 1.0 - smoothstep(head - f, head + f, qt_TexCoord0.x);

    float d = (qt_TexCoord0.x - head) / max(f * 0.75, 0.04);
    float activeEdge = sin(t * 3.14159265);
    float edgeGlow = exp(-(d * d)) * activeEdge * glowBoost;

    float mask = clamp(mix(baseAlpha, 1.0, lit), 0.0, 1.0);
    vec4 base = tex * mask;
    vec3 bloom = mix(vec3(1.0), glowColor.rgb, 0.45) * (tex.a * edgeGlow * 0.45);
    fragColor = (base + vec4(bloom, tex.a * edgeGlow * 0.25)) * qt_Opacity;
}
