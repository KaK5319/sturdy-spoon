#version 460 core

#include <flutter/runtime_effect.glsl>

uniform vec2 uResolution;
uniform float uProgress;   // 0.0 〜 1.0
uniform float uRtl;        // 1.0: 左端からめくる(右開き) / 0.0: 右端からめくる
uniform float uTilt;       // -1.0(上をつまむ) 〜 +1.0(下をつまむ) 折り目の傾き
uniform sampler2D uTextureCurrent;
uniform sampler2D uTextureNext;

out vec4 fragColor;

const float PI = 3.14159265;
const float R_REL = 0.07;                    // 巻きの半径(画面幅に対する比率)
const float MAX_TILT = 1.8;                  // 傾きの最大(1.0で約45度、1.5で約56度)
const vec3 PAPER = vec3(1.0, 1.0, 1.0);      // 紙の裏面の色(真っ白)
const float SEE_THROUGH = 0.42;              // 裏面に透ける絵の濃さ
const float ROLL_DARK = 0.85;                // 巻きの一番暗い所の明るさ

// 内部では常に「右端からめくる」座標(ピクセル単位)で計算する
vec2 toUv(vec2 pp) {
    vec2 uv = pp / uResolution;
    if (uRtl > 0.5) uv.x = 1.0 - uv.x;
    return uv;
}
vec4 cur(vec2 pp) { return texture(uTextureCurrent, toUv(pp)); }
vec4 nxt(vec2 pp) { return texture(uTextureNext, toUv(pp)); }

bool inPage(vec2 pp) {
    return pp.x >= 0.0 && pp.x <= uResolution.x && pp.y >= 0.0 && pp.y <= uResolution.y;
}

void main() {
    vec2 frag = FlutterFragCoord().xy;
    vec2 p = vec2(uRtl > 0.5 ? uResolution.x - frag.x : frag.x, frag.y);
    float pr = clamp(uProgress, 0.0, 1.0);

    if (pr <= 0.001) { fragColor = cur(p); return; }
    if (pr >= 0.999) { fragColor = nxt(p); return; }

    // めくる方向(折り目に垂直な向き)。つまんだ高さで傾く
    vec2 n = normalize(vec2(1.0, uTilt * MAX_TILT));
    float R = R_REL * uResolution.x;

    // ページの四隅を n 方向に射影した範囲
    float t1 = uResolution.x * n.x;
    float t2 = uResolution.y * n.y;
    float t3 = t1 + t2;
    float tmax = max(max(0.0, t1), max(t2, t3));
    float tmin = min(min(0.0, t1), min(t2, t3));

    // 折り目の位置(tmax → tmin-R へ動く)
    float a = mix(tmax, tmin - R, pr);
    float t = dot(p, n);

    vec4 col;

    if (t < a) {
        // 折り目より内側: 現在ページ
        col = cur(p);

        // 折り返された裏面
        float to = 2.0 * a + PI * R - t;
        vec2 po = p + n * (to - t);
        if (inPage(po)) {
            col = vec4(mix(PAPER, cur(po).rgb, SEE_THROUGH), 1.0);
        } else {
            // 折り返しの縁が落とす影(段にならないよう、距離でなめらかに減衰)
            float sh = 0.0;
            for (int i = 1; i <= 12; i++) {
                float d = float(i) * R * 0.12;
                vec2 q = p + n * d;
                float tq = dot(q, n);
                if (tq >= a) break;
                float toq = 2.0 * a + PI * R - tq;
                if (inPage(q + n * (toq - tq))) {
                    sh = 0.32 * (1.0 - float(i) / 13.0);
                    break;
                }
            }
            col.rgb *= 1.0 - sh;
        }
    } else {
        // めくれた後ろ: 次のページ + 巻きの影
        col = nxt(p);
        float k = 1.0 - smoothstep(0.8, 1.0, pr);
        float shadow = mix(0.55, 1.0, smoothstep(0.0, 0.3 * uResolution.x, t - a));
        col.rgb *= mix(1.0, shadow, k);

        if (t < a + R) {
            // 円筒の巻き部分
            float u = clamp((t - a) / R, 0.0, 1.0);
            float th = asin(u);
            float sBack = PI * R - R * th;   // 上側(裏面が見える)
            float sFront = R * th;           // 下側(表面)
            vec2 poB = p + n * ((a + sBack) - t);
            vec2 poF = p + n * ((a + sFront) - t);
            if (inPage(poB)) {
                float shade = ROLL_DARK + (1.0 - ROLL_DARK) * cos(th);
                col = vec4(mix(PAPER, cur(poB).rgb, SEE_THROUGH) * shade, 1.0);
            } else if (inPage(poF)) {
                col = vec4(cur(poF).rgb * (0.5 + 0.3 * cos(th)), 1.0);
            }
        }
    }

    fragColor = col;
}
