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

    // 右開き：右端から左方向へ移動するめくりの境界線
    float curlPos = 1.0 - progress * 1.05;
    
    // カール帯の幅をシャープにして、パイプ状に丸まるのを防ぐ
    float curlWidth = 0.06;

    if (uv.x < curlPos) {
        // 3. めくり終わった左側の領域（次のページ）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // 自然なドロップシャドウ
        float shadow = smoothstep(0.0, 0.15, curlPos - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.45, 1.0, shadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    } 
    else if (uv.x >= curlPos && uv.x <= curlPos + curlWidth) {
        // 2. めくりの先端（紙が折れ曲がるシャープなエッジ部分）
        float t = (uv.x - curlPos) / curlWidth; // 0.0 〜 1.0
        
        // 裏面テクスチャのマッピング
        vec2 backUv = vec2(curlPos + (curlWidth - (uv.x - curlPos)), uv.y);
        vec4 currColor = texture(uTextureCurrent, backUv);
        
        // 紙の裏面らしさ（白地にうっすら透ける）
        vec3 paperBack = mix(vec3(0.97), currColor.rgb * 0.7, 0.3);
        
        // 立体感を出すためのソフトなハイライト
        float lighting = sin(t * PI) * 0.25;
        vec3 finalRgb = paperBack + vec3(lighting);
        
        fragColor = vec4(finalRgb, currColor.a);
    } 
    else {
        // 1. まだめくられていない右側のページ（ピンと張った状態を維持）
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // 境界付近に落ちる控えめな影
        float edgeShadow = smoothstep(curlPos + curlWidth, curlPos + curlWidth + 0.1, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.7, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
