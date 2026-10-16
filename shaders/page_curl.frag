#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress;   // 0.0 〜 1.0
uniform float uRtl;        // 1.0: 左端からめくる(右開き) / 0.0: 右端からめくる
uniform sampler2D uTextureCurrent;
uniform sampler2D uTextureNext;

out vec4 fragColor;

const float PI = 3.14159265;
const float R  = 0.07;                       // 巻きの半径(画面幅に対する比率)
const vec3 PAPER = vec3(1.0, 1.0, 1.0);      // 紙の裏面の色(真っ白)
const float SEE_THROUGH = 0.08;              // 裏面に透ける絵の濃さ(0で完全な白紙)
const float ROLL_DARK = 0.80;                // 巻きの一番暗い所の明るさ(1.0に近いほど白い)

// 内部では常に「右端から左へめくる」座標で計算し、RTLのときだけ左右反転して読む
vec4 cur(float x, float y) {
    return texture(uTextureCurrent, vec2(uRtl > 0.5 ? 1.0 - x : x, y));
}
vec4 nxt(float x, float y) {
    return texture(uTextureNext, vec2(uRtl > 0.5 ? 1.0 - x : x, y));
}

void main() {
    vec2 uv = FlutterFragCoord().xy / uResolution;
    float p = clamp(uProgress, 0.0, 1.0);
    float x = uRtl > 0.5 ? 1.0 - uv.x : uv.x;
    float y = uv.y;

    if (p <= 0.001) { fragColor = cur(x, y); return; }
    if (p >= 0.999) { fragColor = nxt(x, y); return; }

    // 折り目(円柱の接地位置)。1.0 → -R へ動く
    float a = mix(1.0, -R, p);
    // 平らに折り返された部分の先端
    float flapEnd = 2.0 * a + PI * R - 1.0;

    vec4 col;

    if (x < a) {
        // 折り目より内側: めくれていない現在ページ
        col = cur(x, y);
        if (flapEnd < a) {
            if (x >= flapEnd) {
                // 折り返された裏面(うっすら透ける)
                float xo = a + PI * R + (a - x);
                col = vec4(mix(PAPER, cur(xo, y).rgb, SEE_THROUGH), 1.0);
            } else {
                // 折り返しが落とす影
                col.rgb *= 1.0 - 0.3 * exp(-(flapEnd - x) * 25.0);
            }
        }
    } else {
        // めくれた後ろ: 次のページ + 巻きの影
        col = nxt(x, y);
        float k = 1.0 - smoothstep(0.8, 1.0, p);
        float shadow = mix(0.55, 1.0, smoothstep(0.0, 0.3, x - a));
        col.rgb *= mix(1.0, shadow, k);

        if (x < a + R) {
            // 円筒の巻き部分
            float t = clamp((x - a) / R, 0.0, 1.0);
            float th = asin(t);
            float sBack  = PI * R - R * th;  // 上側(裏面が見える)
            float sFront = R * th;           // 下側(表面)
            if (a + sBack <= 1.0) {
                float shade = ROLL_DARK + (0.7 - ROLL_DARK) * cos(th);
                col = vec4(mix(PAPER, cur(a + sBack, y).rgb, SEE_THROUGH) * shade, 0.15
);
            } else if (a + sFront <= 1.0) {
                col = vec4(cur(a + sFront, y).rgb * (0.5 + 0.3 * cos(th)), 1.0);
            }
        }
    }

    fragColor = col;
}
