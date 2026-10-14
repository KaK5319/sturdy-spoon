#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress; // 0.0 〜 1.0
uniform sampler2D uTextureCurrent;
uniform sampler2D uTextureNext;

out vec4 fragColor;

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    float progress = clamp(uProgress, 0.0, 1.0);

    if (progress <= 0.001) {
        fragColor = texture(uTextureCurrent, uv);
        return;
    }
    if (progress >= 0.995) {
        fragColor = texture(uTextureNext, uv);
        return;
    }

    // 境界線（めくられている位置）が右から左へ移動 (1.0 -> 0.0)
    float splitX = 1.0 - progress;

    if (uv.x < splitX) {
        // 1. 左側：次のページ（めくった後のページ）
        vec4 col = texture(uTextureNext, uv);
        
        // 境界付近に落ちるやわらかい影
        float shadow = smoothstep(0.0, 0.04, splitX - uv.x);
        col.rgb *= mix(0.9, 1.0, shadow);
        
        fragColor = col;
    } else {
        // 2. 右側：現在のページ（まだめくっていないページ）
        vec4 col = texture(uTextureCurrent, uv);
        
        // めくりのフチに沿った立体的な影
        float shadow = smoothstep(0.0, 0.06, uv.x - splitX);
        col.rgb *= mix(0.6, 1.0, shadow);
        
        fragColor = col;
    }
}
