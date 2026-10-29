#!/usr/bin/env python3
"""Prepare common geometry/sampling fixtures and retain a CPU mean renderer."""
import argparse,json,time
from pathlib import Path
import numpy as np,cv2
from joint_mean_geometry import map_points

def run(root,out):
    j=json.loads((root/'manifest.json').read_text());geo=json.loads((out/'geometry.json').read_text());old=json.loads((root/'result.json').read_text())
    w,h=j['width'],j['height'];aw,ah=j['analysisWidth'],j['analysisHeight'];ri=j['referenceIndex'];center=np.array(geo['center'])
    mask=np.load(root/'sky-mask-fullres.npy',mmap_mode='r');np.asarray(mask).tofile(out/'blend-mask.f32')
    def src(i):return np.memmap(root/j['frames'][i]['cache'],'<f4',mode='r',shape=(h,w,4))
    def small(i):return np.fromfile(root/j['frames'][i]['mask'],'<f4').reshape(ah,aw)
    shifts={ri:[0,0]};shifts.update({x['frame']:x['source_offset_pixels'] for x in old['ground_alignment'] if x['used_for_ground']})
    # Extract the actual OpenCV 32-phase Lanczos4 coefficient table, making CPU
    # and GPU sampling mathematically identical, including phase quantization.
    coeff=np.empty((32,8),np.float32)
    for tap in range(8):
        im=np.zeros((16,16),np.float32);im[:,4+tap]=1
        coeff[:,tap]=cv2.remap(im,(7+np.arange(32,dtype=np.float32)/32)[None,:],np.full((1,32),7,np.float32),cv2.INTER_LANCZOS4).ravel()
    coeff.tofile(out/'lanczos4-table.f32')
    assert np.max(abs(coeff.sum(axis=1)-1))<1e-6
    sums=np.zeros((2,h,w,4),np.float32);tick=time.perf_counter();records=[]
    for i in range(5):
        frame=src(i);maps=np.memmap(out/f'map-{i}.float4',mode='w+',dtype='<f4',shape=(h,w,4))
        sky=cv2.erode((small(i)>.8).astype(np.float32),np.ones((7,7),np.uint8));ground=cv2.erode((small(i)<.2).astype(np.float32),np.ones((7,7),np.uint8))
        shift=np.array(shifts.get(i,[0,0]),np.float32);model=geo['models'][str(i)]
        for y0 in range(0,h,128):
            y1=min(h,y0+128);xx,yy=np.meshgrid(np.arange(w),np.arange(y0,y1));target=np.column_stack([xx.ravel(),yy.ravel()])
            if i==ri:q=target.astype(float)
            else:
                q=map_points(target,geo['focal_pixels'],np.array(geo['distortion']),np.array(model['rotation']),center)
                if model['residual'] is not None:
                    u,v=((target-center)/w).T;B=np.column_stack([u*0+1,u,v,u*u,u*v,v*v]);q+=B@np.asarray(model['residual'])
            mx=q[:,0].reshape(y1-y0,w).astype(np.float32);my=q[:,1].reshape(y1-y0,w).astype(np.float32)
            gx=(xx+shift[0]).astype(np.float32);gy=(yy+shift[1]).astype(np.float32)
            if i==ri:
                sv=np.ones_like(mx,bool);gv=np.ones_like(mx,bool);warped=np.asarray(frame[y0:y1]);terrain=warped
            else:
                sm=cv2.remap(sky,(mx+.5)*aw/w-.5,(my+.5)*aw/w-.5,cv2.INTER_LINEAR)
                gm=cv2.remap(ground,(gx+.5)*aw/w-.5,(gy+.5)*aw/w-.5,cv2.INTER_LINEAR)
                sv=(mx>=4)&(my>=4)&(mx<w-5)&(my<h-5)&(sm>.999)
                gv=(gx>=4)&(gy>=4)&(gx<w-5)&(gy<h-5)&(gm>.999)&(i in shifts)
                warped=cv2.remap(frame,mx,my,cv2.INTER_LANCZOS4);terrain=cv2.remap(frame,gx,gy,cv2.INTER_LANCZOS4)
            maps[y0:y1,:,0]=mx;maps[y0:y1,:,1]=my;maps[y0:y1,:,2]=sv;maps[y0:y1,:,3]=gv
            for k,(rgb,valid) in enumerate([(warped,sv),(terrain,gv)]):
                sums[k,y0:y1,:,:3]+=rgb[:,:,:3]*valid[:,:,None];sums[k,y0:y1,:,3]+=valid
        maps.flush();del maps
        records.append(dict(source=str((root/j['frames'][i]['cache']).resolve()),map=str((out/f'map-{i}.float4').resolve()),groundShift=shift.tolist(),reference=i==ri))
        print('CPU warp/mean',i+1,'/5',flush=True)
    result=np.memmap(out/'cpu.rgba',mode='w+',dtype='<f4',shape=(h,w,4));ref=src(ri)
    for y0 in range(0,h,128):
        y1=min(h,y0+128);parts=[]
        for k in [0,1]:
            count=sums[k,y0:y1,:,3];mean=sums[k,y0:y1,:,:3]/np.maximum(count,1)[:,:,None]
            mean[count<3]=ref[y0:y1,:,:3][count<3];parts.append(mean)
        a=mask[y0:y1,:,None];result[y0:y1,:,:3]=parts[0]*a+parts[1]*(1-a);result[y0:y1,:,3]=1
    result.flush();np.save(out/'sky-count.npy',sums[0,:,:,3].astype(np.uint8));np.save(out/'ground-count.npy',sums[1,:,:,3].astype(np.uint8))
    spec=dict(width=w,height=h,frames=records,mask=str((out/'blend-mask.f32').resolve()),table=str((out/'lanczos4-table.f32').resolve()),reference=records[ri]['source'],cpu_seconds=time.perf_counter()-tick)
    (out/'render.json').write_text(json.dumps(spec,indent=2)+'\n');print('CPU READY',spec['cpu_seconds'],flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('output',type=Path);a=p.parse_args();run(a.input,a.output)
