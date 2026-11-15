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

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;
    float cornerRadius;
    float maxBlur;
    float maxTint;
};

layout(binding = 1) uniform sampler2D source;

const int TAPS = 24;
const float GOLDEN_ANGLE = 2.39996323;

void main()
{
    float t = clamp(qt_TexCoord0.y, 0.0, 1.0);
    float strength = sqrt(smoothstep(0.0, 1.0, t));
    float radius = maxBlur * strength;

    vec4 color;
    if (radius <= 0.25) {
        color = texture(source, qt_TexCoord0);
    } else {
        vec2 texel = 1.0 / max(itemSize, vec2(1.0));
        vec4 total = texture(source, qt_TexCoord0);
        for (int i = 0; i < TAPS; i++) {
            float r = sqrt((float(i) + 0.5) / float(TAPS)) * radius;
            float angle = float(i) * GOLDEN_ANGLE;
            vec2 offset = vec2(cos(angle), sin(angle)) * r * texel;
            vec2 uv = clamp(qt_TexCoord0 + offset, vec2(0.001), vec2(0.999));
            total += texture(source, uv);
        }
        color = total / float(TAPS + 1);
    }

    float tint = maxTint * strength;
    vec3 rgb = mix(color.rgb, vec3(0.0), tint);

    vec2 p = qt_TexCoord0 * itemSize;
    vec2 corner = vec2(
        p.x < cornerRadius ? cornerRadius - p.x : (p.x > itemSize.x - cornerRadius ? p.x - (itemSize.x - cornerRadius) : 0.0),
        max(0.0, p.y - (itemSize.y - cornerRadius))
    );
    float alpha = 1.0 - smoothstep(cornerRadius - 0.75, cornerRadius + 0.75, length(corner));

    fragColor = vec4(rgb * alpha, alpha) * qt_Opacity;
}
