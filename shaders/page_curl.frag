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

    // ページのめくり位置（右端 1.0 から左方向へ進む）
    // progress に合わせてダイナミックにめくり面が移動します
    float foldLine = 1.0 - progress * 1.2;
    
    // めくりの影響を受ける幅（大きく取って、ページ全体がたわむようにする）
    float curlWidth = 0.25; 

    if (uv.x < foldLine) {
        // 1. すでにめくり進められた左側のエリア（次のページを表示）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // めくりぎわの自然な影
        float shadow = smoothstep(0.0, 0.15, foldLine - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.7, 1.0, shadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    }
    else if (uv.x >= foldLine && uv.x <= foldLine + curlWidth) {
        // 2. ふわっとめくれているダイナミックな曲線エリア
        // 5ミリのような細い棒ではなく、ページ全体が大きく湾曲するグラデーションとテクスチャの合成
        float t = (uv.x - foldLine) / curlWidth; // 0.0 (折れ目) 〜 1.0 (表面の端)
        
        // 湾曲に沿って現在のページのテクスチャを少しスケーリングしてサンプリング
        float sampleX = foldLine + t * (1.0 - foldLine);
        vec2 sampleUv = vec2(clamp(sampleX, 0.0, 1.0), uv.y);
        vec4 currColor = texture(uTextureCurrent, sampleUv);
        
        // 紙がめくれているときの立体的な陰影（中央がふわっと浮き上がるハイライトと、端のシャドウ）
        float light = sin(t * 3.14159) * 0.25;
        float shadow = smoothstep(0.0, 0.3, t) * smoothstep(1.0, 0.7, t);
        
        vec3 finalRgb = currColor.rgb + vec3(light) - vec3(shadow * 0.15);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
    else {
        // 3. まだめくられていない右側のエリア（現在のページ）
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // めくり面の直前に落ちるやわらかい影
        float edgeShadow = smoothstep(foldLine + curlWidth, foldLine + curlWidth + 0.2, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.75, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
