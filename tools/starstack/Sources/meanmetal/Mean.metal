#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)
struct Params { uint w; uint h; float dx; float dy; uint reference; };
float3 lanczos(device const float4 *src, float2 q, uint w, device const float *weights) {
    int2 fixed=int2(rint(q*32.0f));int2 base=fixed>>5;int2 phase=fixed&31;
    float3 result=0;
    for(int y=0;y<8;y++) {
        float3 row=0;
        for(int x=0;x<8;x++)row+=src[(base.y+y-3)*int(w)+base.x+x-3].rgb*weights[phase.x*8+x];
        result+=row*weights[phase.y*8+y];
    }
    return result;
}
kernel void accumulate(device const float4 *src [[buffer(0)]],device const float4 *map [[buffer(1)]],
    device float4 *sky [[buffer(2)]],device float4 *ground [[buffer(3)]],device const float *weights [[buffer(4)]],
    constant Params &p [[buffer(5)]],uint k [[thread_position_in_grid]]) {
    if(k>=p.w*p.h)return;
    float4 m=map[k];
    if(m.z>0)sky[k]+=float4(p.reference ? src[k].rgb : lanczos(src,m.xy,p.w,weights),1);
    if(m.w>0)ground[k]+=float4(p.reference ? src[k].rgb : lanczos(src,float2(k%p.w,k/p.w)+float2(p.dx,p.dy),p.w,weights),1);
}
kernel void finish(device const float4 *sky [[buffer(0)]],device const float4 *ground [[buffer(1)]],
    device const float4 *ref [[buffer(2)]],device const float *mask [[buffer(3)]],device float4 *out [[buffer(4)]],
    constant Params &p [[buffer(5)]],uint k [[thread_position_in_grid]]) {
    if(k>=p.w*p.h)return;
    float3 s=sky[k].a>=3 ? sky[k].rgb/sky[k].a : ref[k].rgb;
    float3 g=ground[k].a>=3 ? ground[k].rgb/ground[k].a : ref[k].rgb;
    out[k]=float4(s*mask[k]+g*(1-mask[k]),1);
}
