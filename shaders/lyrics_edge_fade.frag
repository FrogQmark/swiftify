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
    float edgePx;
    float maxSigma;
};

layout(binding = 1) uniform sampler2D source;

const int REACH = 3;

void main()
{
    vec2 p = qt_TexCoord0 * itemSize;
    float distToEdge = min(p.y, itemSize.y - p.y);
    float edgeT = clamp(distToEdge / max(edgePx, 1.0), 0.0, 1.0);
    float fade = smoothstep(0.0, 1.0, edgeT);
    float sigma = maxSigma * (1.0 - fade);

    vec4 color;
    if (sigma <= 0.05) {
        color = texture(source, qt_TexCoord0);
    } else {
        vec2 texel = 1.0 / max(itemSize, vec2(1.0));
        float stepPx = max(0.5, sigma * 1.1);
        float spread = -0.5 / (sigma * sigma);

        vec4 total = vec4(0.0);
        float weights = 0.0;
        for (int dy = -REACH; dy <= REACH; dy++) {
            for (int dx = -REACH; dx <= REACH; dx++) {
                vec2 offsetPx = vec2(float(dx), float(dy)) * stepPx;
                float w = exp(dot(offsetPx, offsetPx) * spread);
                vec2 uv = clamp(qt_TexCoord0 + offsetPx * texel, vec2(0.001), vec2(0.999));
                total += w * texture(source, uv);
                weights += w;
            }
        }
        color = total / weights;
    }

    fragColor = color * (fade * qt_Opacity);
}
