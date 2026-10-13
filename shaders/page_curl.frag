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

    // 右開き：右端から左方向へ大きくめくれていく基準位置
    float curlPos = 1.0 - progress * 1.2;
    
    // 【重要】細い丸まり（1センチ）を解消し、幅広くダイナミックにめくるため幅を拡大
    float curlWidth = 0.28; 

    if (uv.x < curlPos) {
        // 3. 完全にめくり終わった左側の領域（次のページ）
        vec4 nextColor = texture(uTextureNext, uv);
        float shadow = smoothstep(0.0, 0.3, curlPos - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.4, 1.0, shadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    } 
    else if (uv.x >= curlPos && uv.x <= curlPos + curlWidth) {
        // 2. 大きく湾曲している「紙のめくり面（裏面・曲面）」
        float t = (uv.x - curlPos) / curlWidth; // 0.0 〜 1.0
        
        // 広範囲の裏面テクスチャマッピングで「面」としての広がりを演出
        vec2 backUv = vec2(curlPos + (curlWidth * (1.0 - t)), uv.y);
        vec4 currColor = texture(uTextureCurrent, backUv);
        
        // 紙の白っぽい裏地と絵柄の融合
        vec3 paperBack = mix(vec3(0.95), currColor.rgb * 0.7, 0.4);
        
        // 緩やかで大きな弧を描く立体的なハイライトとシャドウ
        float lighting = sin(t * PI) * 0.35;
        vec3 finalRgb = paperBack + vec3(lighting);
        
        fragColor = vec4(finalRgb, currColor.a);
    } 
    else {
        // 1. まだめくられていない右側のページ
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // カールの手前に落ちる自然な大判の影
        float edgeShadow = smoothstep(curlPos + curlWidth, curlPos + curlWidth + 0.2, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.55, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
