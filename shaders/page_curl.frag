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

    // ページのめくり位置（右から左へダイナミックに移動）
    float curlPos = 1.0 - progress * 1.1;
    float curlWidth = 0.12; // 少し幅を持たせてダイナミックな曲面にする

    if (uv.x < curlPos) {
        // 3. めくり終わった左側の領域（次のページ）＋ 強い立体シャドウ
        vec4 nextColor = texture(uTextureNext, uv);
        float shadow = smoothstep(0.0, 0.25, curlPos - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.35, 1.0, shadow);
        fragColor = vec4(finalRgb, nextColor.a);
    } 
    else if (uv.x >= curlPos && uv.x <= curlPos + curlWidth) {
        // 2. めくりの先端（立体的な紙の円筒・カール部分）
        float t = (uv.x - curlPos) / curlWidth; // 0.0 〜 1.0
        
        // 紙の曲面をシミュレートする湾曲座標
        vec2 backUv = vec2(curlPos + (curlWidth - (uv.x - curlPos)), uv.y);
        vec4 currColor = texture(uTextureCurrent, backUv);
        
        // 紙の裏面らしいたたずまい（白ベースに少し絵柄を透かす）
        vec3 paperBack = mix(vec3(0.94), currColor.rgb * 0.6, 0.3);
        
        // 立体的なハイライト（光の当たり方）と深いシャドウ
        float highlight = pow(sin(t * PI), 1.2) * 0.45;
        float coreShadow = (1.0 - sin(t * PI)) * 0.3;
        
        vec3 finalRgb = (paperBack + vec3(highlight)) * (1.0 - coreShadow);
        fragColor = vec4(finalRgb, currColor.a);
    } 
    else {
        // 1. まだめくられていない右側のページ
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // カールの手前に落ちる影のグラデーション
        float edgeShadow = smoothstep(curlPos + curlWidth, curlPos + curlWidth + 0.15, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.6, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
