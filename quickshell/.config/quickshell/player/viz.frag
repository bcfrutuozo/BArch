#version 440
// The visualizer, drawn on the GPU (VizPage.qml → ShaderEffect). The spectrum arrives as a 1-pixel-high
// texture (`bands`: one texel per band, its red channel the level, interpolated by the scene graph between
// frames), the previous frame as `prev` for the trails. Compiled with make-shaders.sh (qsb).
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float aspect;      // width / height
    float bandsN;      // bands in the texture
    float mode;        // 0 bars · 1 mirror · 2 wave · 3 radial · 4 dots
    float colorMode;   // 0 palette · 1 accent · 2 heat
    float decay;       // trails: how much of the previous frame stays (0 = none)
    float level;       // overall loudness 0..1
    float time;
    vec4 c0;           // accent
    vec4 c1;           // green
    vec4 c2;           // yellow
    vec4 c3;           // red
};
layout(binding = 1) uniform sampler2D bands;
layout(binding = 2) uniform sampler2D prev;

float band(float x) { return texture(bands, vec2(clamp(x, 0.002, 0.998), 0.5)).r; }

vec4 pal(float t) {
    t = clamp(t, 0.0, 1.0);
    if (t < 1.0 / 3.0) return mix(c0, c1, t * 3.0);
    if (t < 2.0 / 3.0) return mix(c1, c2, (t - 1.0 / 3.0) * 3.0);
    return mix(c2, c3, (t - 2.0 / 3.0) * 3.0);
}
vec4 colorAt(float pos, float v) {
    if (colorMode > 1.5) return v < 0.5 ? mix(c0, c2, v * 2.0) : mix(c2, c3, (v - 0.5) * 2.0);
    if (colorMode > 0.5) return c0;
    return pal(pos);
}

void main() {
    vec2 uv = qt_TexCoord0;
    float y = 1.0 - uv.y;                 // up
    float n = max(bandsN, 1.0);
    vec4 col = vec4(0.0);

    if (mode < 1.5) {                     // bars, mirror
        float fi = floor(uv.x * n), fx = fract(uv.x * n);
        float v = band((fi + 0.5) / n);
        float gap = n > 64.0 ? 0.14 : 0.22;
        float inBar = step(gap * 0.5, fx) * step(fx, 1.0 - gap * 0.5);
        float h = mode < 0.5 ? y : abs(y - 0.5) * 2.0;
        float lit = step(h, v) * inBar;
        float cap = exp(-abs(h - v) * 22.0) * inBar * 0.9 * step(0.01, v);
        vec4 c = colorAt(fi / max(n - 1.0, 1.0), v);
        col = c * (lit * (0.5 + 0.5 * h / max(v, 0.001)) + cap);
    } else if (mode < 2.5) {              // wave
        float v = band(uv.x);
        float amp = v * 0.48;
        float d = abs(y - 0.5);
        float inside = step(d, amp);
        float edge = exp(-abs(d - amp) * 70.0);
        vec4 c = colorAt(uv.x, v);
        col = c * (inside * (0.12 + 0.55 * d / max(amp, 0.001)) + edge * 1.1);
        col += c0 * exp(-d * 60.0) * (0.25 + level * 0.5);
    } else if (mode < 3.5) {              // radial, around the cover
        vec2 p = (uv - 0.5) * vec2(aspect, 1.0);
        p.y = -p.y;
        float r = length(p);
        float a = atan(p.x, p.y) / 6.2831853 + 0.5;
        float fi = floor(a * n), fa = fract(a * n);
        float v = band((fi + 0.5) / n);
        float r0 = 0.215 + level * 0.008;
        float len = 0.025 + v * 0.26;
        float inBar = step(0.18, fa) * step(fa, 0.82);
        float lit = step(r0, r) * step(r, r0 + len) * inBar;
        float cap = exp(-abs(r - (r0 + len)) * 90.0) * inBar * step(r0 - 0.01, r) * 0.9 * step(0.01, v);
        vec4 c = colorAt(fi / max(n - 1.0, 1.0), v);
        col = c * (lit * (0.55 + 0.45 * (r - r0) / max(len, 0.001)) + cap);
        col += c0 * exp(-abs(r - r0) * 220.0) * (0.35 + level * 0.65);
    } else {                              // dots with a bright one at the top
        float rows = 24.0;
        float fi = floor(uv.x * n), fx = fract(uv.x * n) - 0.5;
        float fj = floor(y * rows), fy = fract(y * rows) - 0.5;
        float v = band((fi + 0.5) / n);
        float dist = length(vec2(fx * aspect * rows / n, fy));
        float dot = 1.0 - smoothstep(0.26, 0.34, dist);
        float lit = step(fj / rows, v);
        float top = step(abs(fj / rows - v), 1.0 / rows) * step(0.02, v);
        vec4 c = colorAt(fi / max(n - 1.0, 1.0), v);
        col = c * dot * lit * 0.85 + vec4(1.0) * dot * top * 0.6;
    }

    vec4 old = texture(prev, qt_TexCoord0) * decay;
    col = max(col, old);
    fragColor = clamp(col, 0.0, 1.0) * qt_Opacity;
}
