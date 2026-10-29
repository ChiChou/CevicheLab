"""RawNIND Bayer full-frame CPU evaluation on an unpacked sensor mosaic.
No white balance, tone mapping, Apple denoise, resizing or demosaic before the net.
"""
import sys,json,time,hashlib
from pathlib import Path
import numpy as np
import onnxruntime as ort

root=Path(sys.argv[1]); stem=sys.argv[2]
meta=json.loads((root/(stem+'-bayer.json')).read_text())
h,w=meta['height'],meta['width'];assert meta['pattern']==[0,1,3,2] and h%2==w%2==0
raw=np.memmap(root/(stem+'.bayer16'),dtype='<u2',mode='r',shape=(h,w))
planes=[]
for y,x,ch in [(0,0,0),(0,1,1),(1,0,3),(1,1,2)]:
    black=meta['black']+meta['channelBlack'][ch]
    planes.append(np.clip((raw[y::2,x::2].astype(np.float32)-black)/(meta['white']-black),0,1))
packed=np.stack(planes,axis=0)[None];del planes
anchor_mean=float(packed.mean(dtype=np.float64))
tile,halo,step=512,64,384
hh,ww=h//2,w//2; ny=(hh+step-1)//step;nx=(ww+step-1)//step
padded=np.pad(packed,((0,0),(0,0),(halo,ny*step+halo-hh),(halo,nx*step+halo-ww)),mode='reflect');del packed
opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
path=root/'rawdenoise-nind/model_bayer.onnx'
start=time.perf_counter();session=ort.InferenceSession(str(path),sess_options=opt,providers=['CPUExecutionProvider']);load=time.perf_counter()-start
output=np.memmap(root/(stem+'-rawnind-bayer.rgb32'),mode='w+',dtype='<f4',shape=(h,w,3))
times=[];start=time.perf_counter()
for y in range(0,hh,step):
    for x in range(0,ww,step):
        a=np.ascontiguousarray(padded[:,:,y:y+tile,x:x+tile]);t=time.perf_counter()
        b=session.run(None,{'input':a})[0][0].transpose(1,2,0)
        times.append(time.perf_counter()-t)
        if not np.isfinite(b).all():raise ValueError('Nonfinite Bayer model output')
        dy=min(step,hh-y)*2;dx=min(step,ww-x)*2
        output[y*2:y*2+dy,x*2:x*2+dx]=b[halo*2:halo*2+dy,halo*2:halo*2+dx]
    print(stem,'row',y//step+1,'/',ny,'elapsed',round(time.perf_counter()-start,2),flush=True)
gain=anchor_mean/float(output.mean(dtype=np.float64))
for y in range(0,h,256):output[y:y+256]*=gain
output.flush()
report={'model':'RawNIND Bayer','backend':'ONNX Runtime CPU, 4 threads, FP32','source':stem,
        'input':'black/white normalized un-white-balanced LibRaw mosaic','width':w,'height':h,
        'tilePacked':tile,'haloPacked':halo,'predictionCount':len(times),'gain':gain,
        'loadSeconds':load,'inferenceSeconds':sum(times),'totalInferenceAndStitchSeconds':time.perf_counter()-start,
        'firstTileSeconds':times[0],'medianTileSeconds':float(np.median(times[1:])),
        'minimum':float(output.min()),'maximum':float(output.max()),'fractionBelowZero':float((output<0).mean()),
        'fractionAboveOne':float((output>1).mean()),'finite':True,
        'onnxSHA256':hashlib.sha256(path.read_bytes()).hexdigest()}
(root/(stem+'-rawnind-bayer-inference.json')).write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2),flush=True)
