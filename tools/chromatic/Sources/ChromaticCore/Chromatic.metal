// Chromatic aberration correction of Chang, Kang and Kang (IEEE TIP 2013), after Eboli's IPOL 2023/443 reference.
// See LICENSE.upstream. Two passes: `horizontal` stores each pixel's directional estimates; `vertical_and_merge`
// computes the vertical ones in registers, merges, arbitrates and writes the corrected image.
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    uint width, height;
    int horizontalRadius, verticalRadius;
    float rho0, rho1, rho2, tau;
    float alphaRed, alphaBlue, betaRed, betaBlue;
    float gamma1, gamma2, amount;
};

struct Directional { float kTI, kFC, xMax, xMin; };

inline float3 fetch(texture2d<float, access::read> source, int2 p, constant Parameters &P) {
    p = clamp(p, int2(0), int2(P.width - 1, P.height - 1));
    return source.read(uint2(p)).rgb;
}
inline float luma(float3 c) { return 0.299f * c.r + 0.587f * c.g + 0.114f * c.b; }
inline float channel(float3 c, int index) { return index == 0 ? c.r : c.b; }
inline int signOf(float v) { return v > 0 ? 1 : (v < 0 ? -1 : 0); }
// The reference tests the ceiling before the floor; where the floor lies above the ceiling that returns the floor,
// so a plain clamp would not match it.
inline float clipSlice(float pf, float lo, float hi) { return pf > hi ? hi : (pf < lo ? lo : pf); }

// One channel's 1D pass along `step` (Equations 2 to 11). `index` is 0 for red, 2 for blue.
Directional directional(texture2d<float, access::read> source, int2 at, int2 step, int L, int index, float alpha,
                        constant Parameters &P) {
    float3 c0 = fetch(source, at, P);
    float center = channel(c0, index);
    float eMax = center, eMin = center, wMax = center, wMin = center;
    for (int l = 1; l <= L; ++l) {
        float e = channel(fetch(source, at + l * step, P), index), w = channel(fetch(source, at - l * step, P), index);
        eMax = max(eMax, e); eMin = min(eMin, e); wMax = max(wMax, w); wMin = min(wMin, w);
    }
    float xMax, xMin;
    if (eMax - wMin >= wMax - eMin) { xMax = eMax; xMin = wMin; } else { xMax = wMax; xMin = eMin; }
    bool above = center > c0.g;
    float pf0 = above ? P.rho0 * xMax + P.rho1 * center + P.rho2 * xMin : P.rho0 * xMin + P.rho1 * center + P.rho2 * xMax;
    float hi0 = above ? center : min(xMax, c0.g), lo0 = above ? max(xMin, c0.g) : center;
    float k0 = clipSlice(pf0, lo0, hi0) - c0.g;
    float y0 = luma(c0);
    float numerator = 0, denominator = 0;
    float3 previous = fetch(source, at - (L + 1) * step, P);
    for (int l = -L; l <= L; ++l) {
        float3 c = fetch(source, at + l * step, P);
        float xl = channel(c, index), gl = c.g;
        float pf = above ? P.rho0 * xMax + P.rho1 * xl + P.rho2 * xMin : P.rho0 * xMin + P.rho1 * xl + P.rho2 * xMax;
        float hi = above ? xl : min(xMax, gl), lo = above ? max(xMin, gl) : xl;
        float kl = clipSlice(pf, lo, hi) - gl;
        float gradX = xl - channel(previous, index), gradG = gl - previous.g;
        previous = c;
        if (signOf(kl) == signOf(k0) || abs(kl) < P.tau) {
            float weight = 1.0f / (abs(gradG) + max(abs(gradX), alpha * abs(kl)) + abs(y0 - luma(c)) + 1e-8f);
            float clipped = k0 > 0 ? min(kl, k0) : (k0 < 0 ? max(kl, k0) : k0);
            numerator += weight * clipped; denominator += weight;
        }
    }
    Directional d = { k0, numerator / (denominator + 1e-8f), xMax, xMin };
    return d;
}

// The arbitration's directional contrast with the chroma penalty (Equation 17).
float contrast(texture2d<float, access::read> source, int2 at, int2 step, int L, int index, float beta, constant Parameters &P) {
    float center = channel(fetch(source, at, P), index);
    float eMax = center, eMin = center, wMax = center, wMin = center;
    for (int l = 0; l < L; ++l) {
        float3 ce = fetch(source, at + l * step, P), cw = fetch(source, at + (l - L + 1) * step, P);
        float e = channel(ce, index), w = channel(cw, index);
        eMax = max(eMax, e - beta * abs(e - ce.g)); eMin = min(eMin, e + beta * abs(e - ce.g));
        wMax = max(wMax, w - beta * abs(w - cw.g)); wMin = min(wMin, w + beta * abs(w - cw.g));
    }
    return eMax - wMin >= wMax - eMin ? eMax - wMin : wMax - eMin;
}

float arbitrate(Directional h, Directional v, float contrastH, float contrastV, constant Parameters &P) {
    float kFC = abs(h.kFC) < abs(v.kFC) ? h.kFC : v.kFC;
    Directional ti = abs(h.kTI) < abs(v.kTI) ? h : v;
    float alpha = min(max(max(contrastH, contrastV), 0.0f) / min(max(ti.xMax - ti.xMin, P.gamma2), P.gamma1), 1.0f);
    return (1 - alpha) * ti.kTI + alpha * kFC;
}

kernel void horizontal(texture2d<float, access::read> source [[texture(0)]],
                       device float4 *chroma [[buffer(0)]],
                       device float4 *extrema [[buffer(1)]],
                       constant Parameters &P [[buffer(2)]],
                       uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= P.width || pos.y >= P.height) return;
    int2 at = int2(pos), step = int2(1, 0);
    Directional r = directional(source, at, step, P.horizontalRadius, 0, P.alphaRed, P);
    Directional b = directional(source, at, step, P.horizontalRadius, 2, P.alphaBlue, P);
    uint i = pos.y * P.width + pos.x;
    chroma[i] = float4(r.kTI, r.kFC, b.kTI, b.kFC);
    extrema[i] = float4(r.xMax, r.xMin, b.xMax, b.xMin);
}

kernel void vertical_and_merge(texture2d<float, access::read> source [[texture(0)]],
                               texture2d<float, access::write> destination [[texture(1)]],
                               device const float4 *chroma [[buffer(0)]],
                               device const float4 *extrema [[buffer(1)]],
                               constant Parameters &P [[buffer(2)]],
                               uint2 pos [[thread_position_in_grid]]) {
    if (pos.x >= P.width || pos.y >= P.height) return;
    int2 at = int2(pos), right = int2(1, 0), down = int2(0, 1);
    uint i = pos.y * P.width + pos.x;
    float4 c = chroma[i], e = extrema[i];
    Directional hr = { c.x, c.y, e.x, e.y }, hb = { c.z, c.w, e.z, e.w };
    Directional vr = directional(source, at, down, P.verticalRadius, 0, P.alphaRed, P);
    Directional vb = directional(source, at, down, P.verticalRadius, 2, P.alphaBlue, P);
    float4 pixel = source.read(pos);
    float red = arbitrate(hr, vr, contrast(source, at, right, P.horizontalRadius, 0, P.betaRed, P),
                          contrast(source, at, down, P.verticalRadius, 0, P.betaRed, P), P) + pixel.g;
    float blue = arbitrate(hb, vb, contrast(source, at, right, P.horizontalRadius, 2, P.betaBlue, P),
                           contrast(source, at, down, P.verticalRadius, 2, P.betaBlue, P), P) + pixel.g;
    pixel.r += P.amount * (red - pixel.r);
    pixel.b += P.amount * (blue - pixel.b);
    destination.write(pixel, pos);
}
