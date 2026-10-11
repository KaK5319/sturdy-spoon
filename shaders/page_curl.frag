#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress; // 0.0 (初期) 〜 1.0 (めくり完了)
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
    if (progress >= 0.999) {
        fragColor = texture(uTextureNext, uv);
        return;
    }

    // 右開き：右端から左方向へ移動するめくりの中心軸
    // 漫画のページが美しく弧を描くように位置を連動
    float foldX = 1.0 - progress * 1.1;
    float radius = 0.12; // 紙のしなり（曲面）の大きさをリアルなサイズに調整
    float curlWidth = radius * PI;

    if (uv.x < foldX) {
        // 3. めくられたあとに現れる「次のページ」（左側ベース）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // めくった紙の束が落とす深いドロップシャドウ
        float shadowDist = foldX - uv.x;
        float dropShadow = smoothstep(0.0, 0.25, shadowDist);
        dropShadow = mix(0.4, 1.0, dropShadow);
        
        fragColor = vec4(nextColor.rgb * dropShadow, nextColor.a);
    } else if (uv.x < foldX + curlWidth) {
        // 2. 弧を描いて丸まっている「紙の裏面および側面」（ここが最大のポイント）
        float angle = (uv.x - foldX) / radius;
        
        // 裏面に「現在のページ」の絵柄を反転させて、紙が透けているような質感を表現
        vec2 backUv = vec2(foldX + (foldX + curlWidth - uv.x), uv.y);
        vec4 currColor = texture(uTextureCurrent, backUv);
        
        // 紙の白っぽい質感と、立体的なグラデーション（ハイライトと影）
        float highlight = pow(sin(angle), 1.5) * 0.35;
        float shadow = (1.0 - cos(angle)) * 0.45;
        
        // 紙の裏側特有の少しトーンを落とした立体表現
        vec3 paperRgb = mix(currColor.rgb, vec3(0.92, 0.92, 0.92), 0.35);
        vec3 finalRgb = (paperRgb + vec3(highlight)) * (1.0 - shadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    } else {
        // 1. まだめくられていない右側のページ
        vec4 surfaceColor = texture(uTextureCurrent, uv);
        
        // めくり際に落ちる自然な影
        float edgeShadow = smoothstep(foldX + curlWidth, foldX + curlWidth + 0.2, uv.x);
        edgeShadow = mix(0.65, 1.0, edgeShadow);
        
        fragColor = vec4(surfaceColor.rgb * edgeShadow, surfaceColor.a);
    }
}
