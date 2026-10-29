"""Synthetic geometric and CPU/Metal sampling checks; requires meanmetal build."""
import json,subprocess,tempfile
from pathlib import Path
import numpy as np,cv2
from joint_mean_geometry import map_points,distort,undistort

def main():
    rng=np.random.default_rng(52);p=rng.uniform(-1,1,(1000,2));k=np.array([-.04,.006])
    assert np.max(abs(undistort(distort(p,k),k)-p))<1e-8
    center=np.array([3975.5,2651.5]);points=rng.uniform([100,100],[7800,5200],(100,2))
    np.testing.assert_allclose(map_points(points,3200,k,np.zeros(3),center),points,atol=1e-5)
    repo=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='mean-parity-') as folder:
        r=Path(folder);w,h=37,29;xx,yy=np.meshgrid(np.arange(w),np.arange(h));mask=np.clip(xx/(w-1),0,1).astype(np.float32);mask.tofile(r/'mask.f32')
        coeff=np.empty((32,8),np.float32)
        for tap in range(8):
            im=np.zeros((16,16),np.float32);im[:,4+tap]=1
            coeff[:,tap]=cv2.remap(im,(7+np.arange(32,dtype=np.float32)/32)[None,:],np.full((1,32),7,np.float32),cv2.INTER_LANCZOS4).ravel()
        coeff.tofile(r/'weights.f32');sums=np.zeros((2,h,w,4),np.float32);records=[];ref=None
        for i in range(5):
            src=rng.normal(.03,.008,(h,w,4)).astype(np.float32);src[:,:,3]=1;src[10,12,:3]=1.5
            src.tofile(r/f'source-{i}');dx=.17*i;dy=-.23*i;q=np.stack([xx+.31*i,yy-.43*i],axis=-1).astype(np.float32)
            valid=(q[:,:,0]>=4)&(q[:,:,0]<w-5)&(q[:,:,1]>=4)&(q[:,:,1]<h-5)
            ground=(xx+dx>=4)&(xx+dx<w-5)&(yy+dy>=4)&(yy+dy<h-5)
            if i==0:valid[:]=True;ground[:]=True;ref=src.copy()
            maps=np.concatenate([q,valid[:,:,None],ground[:,:,None]],axis=2).astype(np.float32);maps.tofile(r/f'map-{i}')
            a=src if i==0 else cv2.remap(src,q[:,:,0],q[:,:,1],cv2.INTER_LANCZOS4)
            b=src if i==0 else cv2.remap(src,(xx+dx).astype(np.float32),(yy+dy).astype(np.float32),cv2.INTER_LANCZOS4)
            for n,(rgb,v) in enumerate([(a,valid),(b,ground)]):sums[n,:,:,:3]+=rgb[:,:,:3]*v[:,:,None];sums[n,:,:,3]+=v
            records.append(dict(source=str(r/f'source-{i}'),map=str(r/f'map-{i}'),groundShift=[dx,dy],reference=i==0))
        parts=[]
        for n in [0,1]:
            count=sums[n,:,:,3];mean=sums[n,:,:,:3]/np.maximum(count,1)[:,:,None];mean[count<3]=ref[:,:,:3][count<3];parts.append(mean)
        cpu=parts[0]*mask[:,:,None]+parts[1]*(1-mask[:,:,None])
        recipe=dict(width=w,height=h,frames=records,mask=str(r/'mask.f32'),table=str(r/'weights.f32'),reference=str(r/'source-0'))
        (r/'render.json').write_text(json.dumps(recipe));subprocess.run([str(repo/'.build/release/meanmetal'),str(r/'render.json'),str(r/'gpu.rgba')],check=True)
        gpu=np.fromfile(r/'gpu.rgba','<f4').reshape(h,w,4)[:,:,:3]
        error=float(np.max(abs(cpu-gpu)));assert error<2e-6,error
        print('PASS: radial inversion, identity, odd-sized masked Lanczos mean, CPU/Metal max error',error)

if __name__=='__main__':main()
