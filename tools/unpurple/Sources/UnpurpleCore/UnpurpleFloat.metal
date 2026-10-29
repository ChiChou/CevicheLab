// Floating-point adaptation of Martin Jambon's Unpurple. See LICENSE.upstream.
#include <metal_stdlib>
using namespace metal;

float encodeChannel(float v) {
    return v <= 0.0031308f ? 12.92f*v : 1.055f*pow(v,1.0f/2.4f)-0.055f;
}
float decodeChannel(float v) {
    return v <= 0.04045f ? v/12.92f : pow((v+0.055f)/1.055f,2.4f);
}
kernel void floatMask(texture2d<float,access::read> source [[texture(0)]],
                      texture2d<float,access::write> mask [[texture(1)]],
                      constant float4 &controls [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    float4 s=source.read(pos);
    float value=0.0f;
    if (s.a>0.0f) {
        float3 c=s.rgb/s.a;
        if (min(c.r,min(c.g,c.b))>=0.0f)
            value=controls.x*max(0.0f,encodeChannel(c.b)-controls.y)/(1.0f-controls.y)*s.a;
    }
    mask.write(float4(value,0,0,1),pos);
}
kernel void floatBox(texture2d<float,access::sample> source [[texture(0)]],
                     texture2d<float,access::write> destination [[texture(1)]],
                     constant float4 &config [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    constexpr sampler linearClamp(coord::pixel,address::clamp_to_edge,filter::linear);
    float sum=0.0f;
    int radius=int(config.x);
    for (int i=-radius;i<=radius;i++)
        sum+=source.sample(linearClamp,float2(pos)+0.5f+config.yz*(float(i)*config.w)).r;
    destination.write(float4(sum/float(2*radius+1),0,0,1),pos);
}
kernel void floatCorrect(texture2d<float,access::read> source [[texture(0)]],
                         texture2d<float,access::read> mask [[texture(1)]],
                         texture2d<float,access::write> destination [[texture(2)]],
                         constant float4 &controls [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
    uint2 inputPos=pos+uint2(controls.zw);
    float4 s=source.read(inputPos);
    if (s.a>0.0f) {
        float3 c=s.rgb/s.a;
        if (min(c.r,min(c.g,c.b))>=0.0f) {
            float3 encoded=float3(encodeChannel(c.r),encodeChannel(c.g),encodeChannel(c.b));
            // Extended values remain meaningful; no SDR-white clamp or integer conversion.
            float mb=min(max(mask.read(inputPos).r,0.0f),max(encoded.b-encoded.g,0.0f));
            float dr=min(max(encoded.r-encoded.g,0.0f),mb*controls.y);
            float db=controls.x>0.0f ? min(mb,dr/controls.x) : mb;
            if (dr>0.0f) s.r=decodeChannel(encoded.r-dr)*s.a;
            if (db>0.0f) s.b=decodeChannel(encoded.b-db)*s.a;
        }
    }
    // Green, alpha, negative RGB and all unaffected channels are preserved exactly.
    destination.write(s,pos);
}
