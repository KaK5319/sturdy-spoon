#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress; // 0.0 〜 1.0
uniform sampler2D uTextureCurrent;
uniform sampler2D uTextureNext;

out vec4 fragColor;

const float PI = 3.14159265359;

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

    // めくりの進行に伴う軸の位置（右端 1.0 から左方向へ移動）
    float radius = 0.25; // めくる曲面のふくらみの大きさ
    float pivot = 1.0 - progress * (1.0 + radius);

    if (uv.x < pivot - radius) {
        // 3. すでにめくり終わった左側のページ（次のページ）
        vec4 nextColor = texture(uTextureNext, uv);
        float shadow = smoothstep(0.0, 0.2, (pivot - radius) - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.5, 1.0, shadow);
        fragColor = vec4(finalRgb, nextColor.a);
    }
    else if (uv.x >= pivot - radius && uv.x <= pivot + radius) {
        // 2. 実際に紙が大きく湾曲して丸まっている「めくり面（円弧部分）」
        float dist = uv.x - pivot;
        float angle = (dist / radius) * (PI * 0.5);
        
        // 湾曲した表面のテクスチャサンプリング
        float mappedX = pivot + sin(angle) * radius;
        vec2 curvedUv = vec2(mappedX, uv.y);
        
        if (curvedUv.x > 1.0 || curvedUv.x < 0.0) {
            fragColor = vec4(0.0, 0.0, 0.0, 0.0);
            return;
        }

        vec4 currColor = texture(uTextureCurrent, curvedUv);
        
        // 立体的な陰影（円弧の頂点に向かって明るくなり、端で暗くなる）
        float shading = cos(angle) * 0.4 + 0.6;
        vec3 finalRgb = currColor.rgb * shading;
        
        fragColor = vec4(finalRgb, currColor.a);
    }
    else {
        // 1. まだめくられていない右側のページ
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // カールの手前に落ちる影
        float edgeShadow = smoothstep(pivot + radius, pivot + radius + 0.15, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.6, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
