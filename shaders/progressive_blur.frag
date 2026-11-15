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
    float maxTint;
    float blurEndY;
    float sideMargin;
    float bleed;
    float cornerRadius;
};

layout(binding = 1) uniform sampler2D source;

const int REACH = 20;

void main()
{
    float t = clamp(qt_TexCoord0.y / max(blurEndY, 0.001), 0.0, 1.0);
    float s = smoothstep(0.0, 1.0, t);
    float blurStrength = pow(s, 0.75);
    float sigma = maxSigma * blurStrength;

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

    if (maxTint > 0.0) {
        vec2 p = qt_TexCoord0 * itemSize;
        float dx = abs(p.x - itemSize.x * 0.5) - (itemSize.x * 0.5 - sideMargin - cornerRadius);
        float dy = p.y - (itemSize.y - bleed - cornerRadius);
        vec2 q = vec2(max(dx, 0.0), max(dy, 0.0));
        float sdCover = length(q) + min(max(dx, dy), 0.0) - cornerRadius;
        float tintMask = 1.0 - smoothstep(-8.0, 16.0, sdCover);
        float tintStrength = pow(s, 0.85);
        color.rgb *= 1.0 - maxTint * tintStrength * tintMask;
    }

    fragColor = color * qt_Opacity;
}
