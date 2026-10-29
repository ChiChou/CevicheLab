// Port of Martin Jambon's Unpurple. Copyright (c) 2012 Martin Jambon.
// See LICENSE.upstream for redistribution conditions and disclaimer.
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    uint width;
    uint height;
    uint radius;
    uint mode;
    float intensity;
    float minBrightness;
    float minRed;
    float maxRed;
};

kernel void make_mask(device const uchar4 *input [[buffer(0)]],
                      device float *output [[buffer(1)]],
                      constant Parameters &p [[buffer(2)]],
                      uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    output[i] = p.intensity * max(0.0f, float(input[i].b) / 255.0f - p.minBrightness)
        / (1.0f - p.minBrightness);
}

// Four passes: horizontal, vertical, horizontal, vertical. Replicate border pixels.
kernel void box_blur(device const float *input [[buffer(0)]],
                     device float *output [[buffer(1)]],
                     constant Parameters &p [[buffer(2)]],
                     constant uint &horizontal [[buffer(3)]],
                     uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    int x = int(i % p.width), y = int(i / p.width);
    float total = 0;
    for (int offset = -int(p.radius); offset <= int(p.radius); ++offset) {
        uint sx = uint(clamp(x + (horizontal ? offset : 0), 0, int(p.width) - 1));
        uint sy = uint(clamp(y + (horizontal ? 0 : offset), 0, int(p.height) - 1));
        total += input[sy * p.width + sx];
    }
    output[i] = total / float(2 * p.radius + 1);
}

kernel void correct(device const uchar4 *input [[buffer(0)]],
                    device const float *mask [[buffer(1)]],
                    device uchar4 *output [[buffer(2)]],
                    constant Parameters &p [[buffer(3)]],
                    uint i [[thread_position_in_grid]]) {
    if (i >= p.width * p.height) return;
    uchar4 pixel = input[i];
    float r = pixel.r, g = pixel.g, b = pixel.b;
    float blur = clamp(mask[i] * 255.0f, 0.0f, 255.0f);
    float mb = min(blur, max(b - g, 0.0f));
    float dr = min(max(r - g, 0.0f), mb * p.maxRed);
    float db = p.minRed > 0 ? min(mb, dr / p.minRed) : mb;
    // Truncate correction amounts as upstream does; leave alpha unchanged.
    if (p.mode == 1) output[i] = uchar4(uchar(dr), 0, uchar(db), pixel.a);
    else if (p.mode == 2) output[i] = uchar4(uchar3(uchar(blur)), pixel.a);
    else output[i] = uchar4(pixel.r - uchar(dr), pixel.g, pixel.b - uchar(db), pixel.a);
}
