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

    // 右開き：右端(1.0)から左方向へ進むめくりの境界線
    float curlPos = 1.0 - progress * 1.0;
    
    // カール（丸まり）の幅をシャープにして、全体が丸まるのを防ぐ
    float curlWidth = 0.08; 

    if (uv.x < curlPos - curlWidth) {
        // 3. 完全にめくられた下に見える「次のページ」（左側）
        vec4 nextColor = texture(uTextureNext, uv);
        
        // めくった紙が落とす自然なシャドウ
        float shadow = smoothstep(0.0, 0.15, curlPos - curlWidth - uv.x);
        vec3 finalRgb = nextColor.rgb * mix(0.5, 1.0, shadow);
        
        fragColor = vec4(finalRgb, nextColor.a);
    } 
    else if (uv.x >= curlPos - curlWidth && uv.x <= curlPos) {
        // 2. めくりの先端（シャープな紙の裏面・曲面部分）
        // ここに「紙の裏側」の質感を出し、全体が丸まっているような錯覚を消す
        float t = (uv.x - (curlPos - curlWidth)) / curlWidth; // 0.0 〜 1.0
        
        // 裏面としての白っぽい質感と、現在のページの絵柄をミックス
        vec2 backUv = vec2(1.0 - (uv.x - (curlPos - curlWidth)), uv.y);
        vec4 currColor = texture(uTextureCurrent, backUv);
        
        // 紙の白ベースに裏返ったインクがうっすら透ける表現
        vec3 paperBack = mix(vec3(0.95), currColor.rgb * 0.7, 0.4);
        
        // 立体的なハイライトとシャドウ
        float lighting = sin(t * PI) * 0.35;
        vec3 finalRgb = paperBack + vec3(lighting);
        
        fragColor = vec4(finalRgb, currColor.a);
    } 
    else {
        // 1. まだめくられていない右側のページ（ピンと張った状態を維持、丸めない）
        vec4 currColor = texture(uTextureCurrent, uv);
        
        // 境界付近のわずかな陰影のみ
        float edgeShadow = smoothstep(curlPos, curlPos + 0.1, uv.x);
        vec3 finalRgb = currColor.rgb * mix(0.7, 1.0, edgeShadow);
        
        fragColor = vec4(finalRgb, currColor.a);
    }
}
