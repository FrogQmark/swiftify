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
    vec2 direction;
    float maxSigma;
    float blurEndY;
    float uniformBlur;
};

layout(binding = 1) uniform sampler2D source;

const int REACH = 18;

void main()
{
    float t = clamp(qt_TexCoord0.y / max(blurEndY, 0.001), 0.0, 1.0);
    float strength = mix(smoothstep(0.0, 1.0, t), 1.0, uniformBlur);
    float sigma = maxSigma * strength;

    vec4 color;
    if (sigma <= 0.05) {
        color = texture(source, clamp(qt_TexCoord0, vec2(0.001), vec2(0.999)));
    } else {
        vec2 texel = direction / max(itemSize, vec2(1.0));
        float stepPx = max(0.35, sigma * 2.5 / float(REACH));
        float spread = -0.5 / (sigma * sigma);

        vec4 total = texture(source, clamp(qt_TexCoord0, vec2(0.001), vec2(0.999)));
        float weights = 1.0;
        for (int i = 1; i <= REACH; i++) {
            float d = float(i) * stepPx;
            float w = exp(d * d * spread);
            vec2 offset = texel * d;
            vec2 uvPlus = clamp(qt_TexCoord0 + offset, vec2(0.001), vec2(0.999));
            vec2 uvMinus = clamp(qt_TexCoord0 - offset, vec2(0.001), vec2(0.999));
            total += w * (texture(source, uvPlus) + texture(source, uvMinus));
            weights += 2.0 * w;
        }
        color = total / weights;
    }

    fragColor = color * qt_Opacity;
}
