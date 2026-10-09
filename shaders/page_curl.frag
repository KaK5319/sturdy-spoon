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
    
    // 右開き（右から左へめくる）の物理計算
    float progress = clamp(uProgress, 0.0, 1.0);
    
    // ページがめくられるシリンダーの位置
    float curlX = (1.0 - progress) * 1.2 - 0.1;
    
    // シリンダーの半径（めくり進行度に合わせて微妙に変化し紙のしなりを表現）
    float radius = 0.07 + 0.03 * sin(progress * PI);
    float curlWidth = radius * PI;
    
    if (uv.x < curlX) {
        // 1. 表面（まだ捲れていない領域）
        fragColor = texture(uTextureCurrent, uv);
    } else if (uv.x < curlX + curlWidth) {
        // 2. 円筒（シリンダー）状に巻いている立体領域
        float angle = (uv.x - curlX) / radius;
        
        // 裏面画像の左右反転マッピング
        vec2 backUv = vec2(curlX - (uv.x - curlX), uv.y);
        vec4 backColor = texture(uTextureCurrent, backUv);
        
        // 高精度な光沢と影（3Dハイライトとシリンダー影）
        float highlight = pow(sin(angle), 3.0) * 0.3;
        float shadow = (1.0 - cos(angle)) * 0.35;
        
        vec3 finalRgb = (backColor.rgb + vec3(highlight)) * (1.0 - shadow);
        fragColor = vec4(finalRgb, backColor.a);
    } else {
        // 3. 次のページ ＋ めくった紙が落とす落とし影（Drop Shadow）
        vec4 nextColor = texture(uTextureNext, uv);
        
        float shadowDist = uv.x - (curlX + curlWidth);
        float dropShadow = smoothstep(0.0, 0.15, shadowDist);
        dropShadow = mix(0.45, 1.0, dropShadow); // 自然で深みのある影
        
        fragColor = vec4(nextColor.rgb * dropShadow, nextColor.a);
    }
}
