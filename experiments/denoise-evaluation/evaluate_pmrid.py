"""PMRID Bayer evaluation using the matching DNG's source NoiseProfile.
The camera profile is metadata, not independently measured noise calibration.
"""
import sys,json,time,struct
from pathlib import Path
import numpy as np
import coremltools as ct
root=Path(sys.argv[1]);stem=sys.argv[2];dng=Path(sys.argv[3])
meta=json.loads((root/(stem+'-bayer.json')).read_text());h,w=meta['height'],meta['width']
b=dng.read_bytes();e='<' if b[:2]==b'II' else '>'
def entries(o):
    for i in range(struct.unpack_from(e+'H',b,o)[0]):yield struct.unpack_from(e+'HHII',b,o+2+i*12)
_,_,n,p=next(t for t in entries(struct.unpack_from(e+'I',b,4)[0]) if t[0]==330)
primary=struct.unpack_from(e+'I',b,p)[0]
_,kind,n,p=next(t for t in entries(primary) if t[0]==51041);assert kind==12 and n==6
profile=np.array(struct.unpack_from(e+'d'*n,b,p)).reshape(3,2)
# Plane order from the supplied CFAPlaneColor: R,G,B; pack is R,G1,G2,B.
cfa=next(t for t in entries(primary) if t[0]==50710);assert cfa[1:3]==(1,3) and cfa[3]&0xffffff==0x020100
coeff=profile[[0,1,1,2]].astype(np.float32)
# PMRID's published anchor noise distribution, expressed in normalized units.
V=959.;anchor=1600.;ka=(.0005995267*anchor+.00868861)/V
ba=(7.11772e-7*anchor**2+6.514934e-4*anchor+.11492713)/(V*V)
scale=(ka/coeff[:,0])[None,:,None,None]
offset=(ka*coeff[:,1]/coeff[:,0]**2-ba/ka)[None,:,None,None]
raw=np.memmap(root/(stem+'.bayer16'),dtype='<u2',mode='r',shape=(h,w))
packed=[]
for y,x,ch in [(0,0,0),(0,1,1),(1,0,3),(1,1,2)]:
    black=meta['black']+meta['channelBlack'][ch]
    packed.append(np.clip((raw[y::2,x::2].astype(np.float32)-black)/(meta['white']-black),0,1))
packed=np.stack(packed,axis=0)[None];hh,ww=h//2,w//2;tile,halo,step=256,32,192
ny=(hh+step-1)//step;nx=(ww+step-1)//step
padded=np.pad(packed,((0,0),(0,0),(halo,ny*step+halo-hh),(halo,nx*step+halo-ww)),mode='reflect');del packed
path=root.parent/'denoise-model-research/PMRID-research.mlpackage'
t=time.perf_counter();model=ct.models.MLModel(str(path),compute_units=ct.ComputeUnit.ALL);load=time.perf_counter()-t
output=np.memmap(root/(stem+'-pmrid.mosaic32'),dtype='<f4',mode='w+',shape=(h,w))
times=[];start=time.perf_counter()
for y in range(0,hh,step):
    for x in range(0,ww,step):
        a=np.ascontiguousarray((padded[:,:,y:y+tile,x:x+tile]*scale+offset)*256,dtype=np.float32)
        t=time.perf_counter();pred=model.predict({'packed_raw':a})['denoised_raw'];times.append(time.perf_counter()-t)
        pred=(pred/256-offset)/scale
        if not np.isfinite(pred).all():raise ValueError('nonfinite PMRID output')
        dy=min(step,hh-y);dx=min(step,ww-x)
        for c,(oy,ox) in enumerate([(0,0),(0,1),(1,0),(1,1)]):
            output[y*2+oy:(y+dy)*2:2,x*2+ox:(x+dx)*2:2]=pred[0,c,halo:halo+dy,halo:halo+dx]
    print(stem,'row',y//step+1,'/',ny,'elapsed',round(time.perf_counter()-start,3),flush=True)
output.flush()
report={'model':'PMRID','source':stem,'backend':'Core ML ALL, FP16 graph','noiseProfileRGB':profile.tolist(),
 'profileSource':'NoiseProfile in original mosaic IFD of matching Lightroom DNG; not independently calibrated',
 'anchorNormalized':[ka,ba],'normalizationScale':scale.flatten().tolist(),'normalizationOffset':offset.flatten().tolist(),
 'width':w,'height':h,'tilePacked':tile,'haloPacked':halo,'predictionCount':len(times),'loadSeconds':load,
 'inferenceSeconds':sum(times),'totalInferenceAndStitchSeconds':time.perf_counter()-start,
 'medianTileSeconds':float(np.median(times[1:])),'finite':True,'minimum':float(output.min()),'maximum':float(output.max())}
(root/(stem+'-pmrid-inference.json')).write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
