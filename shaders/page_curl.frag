#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress; // 0.0 (めくり前) 〜 1.0 (めくり完了)
uniform sampler2D uTextureCurrent;
uniform sampler2D uTextureNext;

out vec4 fragColor;

const float RADIUS = 0.15; // シリンダー（筒）の太さ

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    
    // 右開き（右から左へ捲る）の計算
    float curlX = 1.0 - uProgress;
    
    if (uv.x < curlX) {
        // まだめくられていない表面の領域
        fragColor = texture(uTextureCurrent, uv);
    } else if (uv.x < curlX + RADIUS * 3.14159) {
        // 円筒（シリンダー）状に曲がっている領域
        float angle = (uv.x - curlX) / RADIUS;
        float shadow = sin(angle) * 0.4; // 筒状の影
        
        // 裏面の画像を左右反転してマッピング
        vec2 backUv = vec2(curlX - (uv.x - curlX), uv.y);
        vec4 backColor = texture(uTextureCurrent, backUv);
        
        // 裏面を少し薄くして影を合成
        fragColor = vec4(backColor.rgb * (1.0 - shadow), backColor.a);
    } else {
        // めくられた後に見えてくる次のページ
        fragColor = texture(uTextureNext, uv);
    }
}
