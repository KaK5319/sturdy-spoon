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

    // めくりの進行度に応じた円柱カールの中心位置（右端 1.0 から左へ移動）
    float curlRadius = 0.15; // カールの大きさ
    float foldPos = 1.0 - progress * (1.0 + curlRadius);

    if (uv.x < foldPos) {
        // 1. 左側：すでにめくり終わった領域（次のページ）
        vec4 col = texture(uTextureNext, uv);
        // めくりぎわの自然な影
        float shadow = smoothstep(0.0, 0.05, foldPos - uv.x);
        col.rgb *= mix(0.8, 1.0, shadow);
        fragColor = col;
    } 
    else if (uv.x >= foldPos && uv.x < foldPos + curlRadius) {
        // 2. カール（丸まっている）領域：ここでUVを巻き取るように計算
        float t = (uv.x - foldPos) / curlRadius; // 0.0 〜 1.0
        
        // カール表面の湾曲を擬似的に表現するUVの圧縮・逆転
        float bakedUvX = foldPos + (1.0 - t) * curlRadius;
        vec2 curledUv = vec2(bakedUvX, uv.y);
        
        vec4 col = texture(uTextureCurrent, curledUv);
        
        // 立体的なハイライトと影
        float highlight = sin(t * 3.14159) * 0.25;
        float shadow = (1.0 - sin(t * 3.14159)) * 0.4;
        
        col.rgb = clamp(col.rgb * (1.0 - shadow) + vec3(highlight), 0.0, 1.0);
        fragColor = col;
    } 
    else {
        // 3. 右側：まだめくられていない領域（現在のページ）
        vec4 col = texture(uTextureCurrent, uv);
        float dist = uv.x - (foldPos + curlRadius);
        float shadow = smoothstep(0.0, 0.05, dist);
        col.rgb *= mix(0.7, 1.0, shadow);
        fragColor = col;
    }
}
