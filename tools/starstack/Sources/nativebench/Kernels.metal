#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)
// Independent implementations. Geometry follows our existing Swift experiment;
// no source is copied from the four benchmarked projects.
float2 project(float2 q, constant float *p) {
    float z=p[6]*q.x+p[7]*q.y+p[8];
    return float2(p[0]*q.x+p[1]*q.y+p[2],p[3]*q.x+p[4]*q.y+p[5])/z;
}
float poly(float u,float v,constant float *a) {
    return a[0]+u*(a[1]+u*(a[3]+u*a[6])+v*(a[4]+u*a[7]+v*a[8]))+v*(a[2]+v*(a[5]+v*a[9]));
}
kernel void warp(device const float4 *src [[buffer(0)]],device float4 *dst [[buffer(1)]],
                 device const float *mask [[buffer(2)]],constant float *p [[buffer(3)]],uint k [[thread_position_in_grid]]) {
    uint w=uint(p[0]),h=uint(p[1]);if(k>=w*h)return;dst[k]=0;
    if(mask[k]<=.001f)return;
    float2 target=float2(k%w,k/w),q=project(target,p+2);
    if(p[11]>0)for(int j=0;j<5;j++) {
        float u=(q.x+p[12])/p[11]-.5f,v=(q.y+p[12])/p[11]-.35f;
        float2 next=project(target-float2(poly(u,v,p+13),poly(u,v,p+23)),p+2);
        float delta=distance(next,q);q=next;if(delta<.0001f)break;
    }
    if(!all(isfinite(q))||any(q<0)||q.x>=w-1||q.y>=h-1)return;
    uint x=uint(q.x),y=uint(q.y),a=y*w+x;float fx=q.x-x,fy=q.y-y;
    float m=(mask[a]*(1-fx)+mask[a+1]*fx)*(1-fy)+(mask[a+w]*(1-fx)+mask[a+w+1]*fx)*fy;
    if(m<=.98f)return;
    float4 c=(src[a]*(1-fx)+src[a+1]*fx)*(1-fy)+(src[a+w]*(1-fx)+src[a+w+1]*fx)*fy;
    dst[k]=float4(c.rgb,1);
}
// Pilot bounded to 64 frames. Frame-major storage; do not silently truncate a stack.
kernel void fuse(device const float4 *frames [[buffer(0)]],device float4 *dst [[buffer(1)]],
                 device const float *mask [[buffer(2)]],device const float4 *ref [[buffer(3)]],
                 constant uint2 &p [[buffer(4)]],uint k [[thread_position_in_grid]]) {
    if(k>=p.x)return;dst[k]=ref[k];if(mask[k]<=.001f)return;
    float values[64],dev[64];uint indices[64];uint n=0;
    for(uint i=0;i<p.y;i++) {float4 c=frames[i*p.x+k];if(c.a<=0)continue;
        float l=c.r*.2126f+c.g*.7152f+c.b*.0722f;uint j=n++;
        while(j>0&&values[j-1]>l){values[j]=values[j-1];indices[j]=indices[j-1];j--;}
        values[j]=l;indices[j]=i;
    }
    if(n<3)return;float mid=values[n/2];
    for(uint i=0;i<n;i++){float d=abs(values[i]-mid);uint j=i;while(j>0&&dev[j-1]>d){dev[j]=dev[j-1];j--;}dev[j]=d;}
    float mad=n%2 ? dev[n/2] : (dev[n/2-1]+dev[n/2])*.5f;
    float limit=max(1e-5f,4.5f*1.4826f*mad);float3 sum=0;uint count=0;
    for(uint i=0;i<n;i++)if(abs(values[i]-mid)<=limit){sum+=frames[indices[i]*p.x+k].rgb;count++;}
    if(count>0)dst[k]=float4(sum/float(count)*mask[k]+ref[k].rgb*(1-mask[k]),1);
}
kernel void difference(device const float *a [[buffer(0)]],device const float *b [[buffer(1)]],
                       device uchar *out [[buffer(2)]],constant float2 &p [[buffer(3)]],uint k [[thread_position_in_grid]]) {
    if(k<uint(p.x))out[k]=abs(a[k]-b[k])>p.y ? 255 : 0;
}
kernel void morphology(device const uchar *src [[buffer(0)]],device uchar *dst [[buffer(1)]],
                       constant uint3 &p [[buffer(2)]],uint k [[thread_position_in_grid]]) {
    if(k>=p.x*p.y)return;int x=k%p.x,y=k/p.x;uchar v=p.z ? 0 : 255;
    // OpenCV's default morphology border is neutral for each operation.
    for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++) {
        int xx=x+dx,yy=y+dy;if(xx<0||yy<0||xx>=int(p.x)||yy>=int(p.y))continue;
        uchar a=src[yy*p.x+xx];v=p.z ? max(v,a) : min(v,a);
    }dst[k]=v;
}
kernel void catalog_project(device const float4 *world [[buffer(0)]],device float2 *pixels [[buffer(1)]],
                            constant float *p [[buffer(2)]],uint i [[thread_position_in_grid]]) {
    if(i>=uint(p[0]))return;float3 v=world[i].xyz;
    float3 q=float3(dot(v,float3(p[4],p[5],p[6])),dot(v,float3(p[7],p[8],p[9])),dot(v,float3(p[10],p[11],p[12])));
    pixels[i]=float2(-1);if(q.x<=0)return;
    float2 xy=float2(p[1],p[2])*.5f-p[3]*q.yz/q.x;
    if(all(xy>=0)&&xy.x<p[1]&&xy.y<p[2])pixels[i]=xy;
}
