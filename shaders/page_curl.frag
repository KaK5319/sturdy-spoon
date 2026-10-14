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

    // めくりの境界線（右端 1.0 から左へ移動）
    float curlPos = 1.0 - progress * 1.02;
    float curlWidth = 0.08; // 影と立体感をつける帯の幅

    if (uv.x < curlPos) {
        // 1. 左側：すでにめくり終わった「次のページ」（歪みなし）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // めくり際に落ちる自然な影
        float shadow = smoothstep(0.0, 0.2, curlPos - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.5, 1.0, shadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    } 
    else if (uv.x >= curlPos && uv.x <= curlPos + curlWidth) {
        // 2. 中央の帯：紙が折れ曲がっている立体部分（文字の歪みをなくし、綺麗な影とハイライトで表現）
        float t = (uv.x - curlPos) / curlWidth; // 0.0 〜 1.0
        
        // 下地の色（紙の裏面や折れ目としての白〜グレー）
        vec3 paperFold = vec3(0.92);
        
        // 立体感を演出するサインカーブのハイライトとシャドウ
        float lighting = sin(t * PI) * 0.35;
        // 端に行くほど暗くするシャドウ
        float edgeDarkening = smoothstep(0.0, 0.3, t) * smoothstep(1.0, 0.7, t);
        
        vec3 finalRgb = paperFold + vec3(lighting) - vec3(edgeDarkening * 0.15);
        
        fragColor = vec4(finalRgb, 1.0);
    } 
    else {
        // 3. 右側：まだめくられていない「現在のページ」（歪みなし）
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // カールの手前に落ちる控えめな影
        float edgeShadow = smoothstep(curlPos + curlWidth, curlPos + curlWidth + 0.15, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.65, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
