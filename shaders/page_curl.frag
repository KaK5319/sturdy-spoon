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

    // めくりの進行に伴う折り目の位置（右端 1.0 から左方向へ 0.0 まで移動）
    float foldPos = 1.0 - progress;
    
    // カール（めくれ部分）の幅
    float curlWidth = 0.08;

    if (uv.x < foldPos) {
        // 1. 左側：完全にめくり終わった領域（次のページを表示）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // めくりぎわに落ちるやわらかい影
        float edgeShadow = smoothstep(0.0, 0.05, foldPos - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.85, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    }
    else if (uv.x >= foldPos && uv.x < foldPos + curlWidth) {
        // 2. めくり部のカール領域（立体的なハイライトと影を付与）
        float t = (uv.x - foldPos) / curlWidth; // 0.0 (折れ目) 〜 1.0 (表面)
        
        // 現在のページのテクスチャを取得
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // 折り目付近を暗くし、中央に向かって立体的な光（ハイライト）を当てる
        float shadow = smoothstep(0.0, 0.5, t) * 0.4;
        float highlight = sin(t * 3.14159) * 0.15;
        
        vec3 finalRgb = currColor.rgb * (1.0 - shadow) + vec3(highlight);
        fragColor = vec4(finalRgb, currColor.a);
    }
    else {
        // 3. 右側：まだめくられていない領域（現在のページ）
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // めくり直前のシャドウ
        float dist = uv.x - (foldPos + curlWidth);
        float shadow = smoothstep(0.0, 0.08, dist);
        vec3 finalRgb = currColor.rgb * mix(0.7, 1.0, shadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
