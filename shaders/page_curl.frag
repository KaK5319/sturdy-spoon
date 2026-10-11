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
    
    // 右開き：右端(1.0)から左端(0.0)へ向かってカールが移動
    // progressが1.0になったときに完全に次のページに切り替わる座標設計
    float curlX = 1.0 - progress * 1.0;
    float radius = 0.06;
    float curlWidth = radius * PI;
    
    if (progress <= 0.001) {
        // 初期状態：現在のページをそのまま表示
        fragColor = texture(uTextureCurrent, uv);
    } else if (progress >= 0.999) {
        // 完了状態：次のページを完全に表示
        fragColor = texture(uTextureNext, uv);
    } else if (uv.x < curlX) {
        // 3. めくられた下に見える「次のページ」領域（左側）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // カールの端に落とす影
        float shadowDist = curlX - uv.x;
        float dropShadow = smoothstep(0.0, 0.15, shadowDist);
        dropShadow = mix(0.45, 1.0, dropShadow);
        
        fragColor = vec4(nextColor.rgb * dropShadow, nextColor.a);
    } else if (uv.x < curlX + curlWidth) {
        // 2. 円筒（シリンダー）状に巻いている立体領域（裏面反転 ＋ 影）
        float angle = (uv.x - curlX) / radius;
        
        // 裏面の画像を左右反転してマッピング
        vec2 backUv = vec2(curlX - (uv.x - curlX), uv.y);
        vec4 backColor = texture(uTextureCurrent, backUv);
        
        float highlight = pow(sin(angle), 3.0) * 0.3;
        float shadow = (1.0 - cos(angle)) * 0.4;
        
        vec3 finalRgb = (backColor.rgb + vec3(highlight)) * (1.0 - shadow);
        fragColor = vec4(finalRgb, backColor.a);
    } else {
        // 1. まだめくられていない表面（右側）
        fragColor = texture(uTextureCurrent, uv);
    }
}
