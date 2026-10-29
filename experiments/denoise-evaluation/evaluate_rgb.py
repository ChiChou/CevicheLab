"""Evaluate native-resolution ImageIO crops. Outputs stay in ignored research storage.
Usage: PYTHONPATH=... python evaluate_rgb.py DATA_DIRECTORY
"""
import json, time, sys, hashlib
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont
import onnxruntime as ort
import coremltools as ct
from scipy.ndimage import gaussian_filter

ROOT=Path(sys.argv[1]); OUT=ROOT/'rgb-results'; OUT.mkdir(exist_ok=True)
R2020_TO_SRGB=np.array([[1.660491,-.587641,-.072850],[-.124550,1.132900,-.008349],[-.018151,-.100579,1.118730]],dtype=np.float32)
SRGB_TO_R2020=np.linalg.inv(R2020_TO_SRGB).astype(np.float32)
CASES={'DSC00032': [('sky',3000,1000),('mountain',1000,2100),('water',3500,3400),('foreground',5100,4400)],
       'DSC00396': [('stars',1400,600),('aurora',2900,2000),('window',350,3100),('dark-sky',3700,900)]}
SIZE=768
def encode(a):
    a=np.maximum(a,0)
    return np.where(a<=.0031308,a*12.92,1.055*a**(1/2.4)-.055)
def decode(a):
    a=np.clip(a,0,1)
    return np.where(a<=.04045,a/12.92,((a+.055)/1.055)**2.4)
def display(a,ev=0):
    return np.uint8(np.round(np.clip(encode((a@R2020_TO_SRGB.T)*2**ev),0,1)*255))
def load(stem):
    m=json.loads((ROOT/(stem+'.json')).read_text())
    return np.memmap(ROOT/(stem+'.rgba32'),mode='r',dtype='<f4',shape=(m['height'],m['width'],4)),m
def tiled(a,run,tile,halo):
    step=tile-2*halo; h,w,_=a.shape; ny=(h+step-1)//step; nx=(w+step-1)//step
    padded=np.pad(a,((halo,ny*step+halo-h),(halo,nx*step+halo-w),(0,0)),mode='reflect')
    out=np.zeros_like(a); times=[]
    for y in range(0,h,step):
        for x in range(0,w,step):
            t=time.perf_counter(); b=run(padded[y:y+tile,x:x+tile]);times.append(time.perf_counter()-t)
            dy=min(step,h-y);dx=min(step,w-x)
            out[y:y+dy,x:x+dx]=b[halo:halo+dy,halo:halo+dx]
    if not np.isfinite(out).all(): raise ValueError('Nonfinite model output')
    return out,times
opt=ort.SessionOptions();opt.intra_op_num_threads=4;opt.inter_op_num_threads=1
report={'scope':'768px native-resolution crops, full-resolution ImageIO decode, no clean ground truth',
        'models':{},'cases':[]}
for model in ['rawnind-linear','treenet-light','nafnet']:
    t=time.perf_counter()
    if model=='nafnet':
        session=ct.models.MLModel(str(ROOT/'NAFNet.mlpackage'),compute_units=ct.ComputeUnit.ALL)
        def run(a):
            lin=a@R2020_TO_SRGB.T; clipped=np.clip(lin,0,1)
            inp=encode(clipped).transpose(2,0,1)[None].copy()
            b=session.predict({'image':inp})['denoised'][0].transpose(1,2,0)
            corrected=lin+decode(b)-clipped
            corrected[np.any(lin>1,axis=2)]=lin[np.any(lin>1,axis=2)]
            return corrected@SRGB_TO_R2020.T
        tile,halo=512,32;backend='Core ML ALL, FP16 graph'
    else:
        path=ROOT/('rawdenoise-nind/model_linear.onnx' if model=='rawnind-linear' else 'treenet-light.onnx')
        session=ort.InferenceSession(str(path),sess_options=opt,providers=['CPUExecutionProvider'])
        def run(a):
            inp=np.clip(a,0,1).transpose(2,0,1)[None].copy()
            if model=='treenet-light':
                feed={'input':inp.astype(np.float16),'cond':np.array([[min(iso,65535)/6400]],dtype=np.float16)}
            else:feed={'input':inp}
            return session.run(None,feed)[0][0].transpose(1,2,0).astype(np.float32)
        tile,halo=(512,64) if model=='rawnind-linear' else (256,32)
        backend='ONNX Runtime CPU, 4 threads; '+('FP32' if model=='rawnind-linear' else 'FP16 model')
    report['models'][model]={'loadSeconds':time.perf_counter()-t,'backend':backend,'tile':tile,'halo':halo}
    for stem,rois in CASES.items():
        full,meta=load(stem);iso=meta['iso'][0]; outputs=[]; inputs=[]; alltimes=[]
        for name,x,y in rois:
            a=np.asarray(full[y:y+SIZE,x:x+SIZE,:3]).copy()
            b,times=tiled(a,run,tile,halo)
            inputs.append(a);outputs.append(b);alltimes.extend(times)
            print(model,stem,name,'seconds',round(sum(times),3),flush=True)
        # One scalar across all sampled regions of this image, never one per tile.
        gain=float(sum(a.sum(dtype=np.float64) for a in inputs)/sum(b.sum(dtype=np.float64) for b in outputs)) if model=='rawnind-linear' else 1.
        for (name,x,y),a,b in zip(rois,inputs,outputs):
            b*=gain
            np.save(OUT/f'{stem}-{name}-{model}.npy',b)
            np.save(OUT/f'{stem}-{name}-input.npy',a)
            for ev in [0,2]:
                Image.fromarray(display(b,ev)).save(OUT/f'{stem}-{name}-{model}-ev{ev}.png')
                Image.fromarray(display(a,ev)).save(OUT/f'{stem}-{name}-input-ev{ev}.png')
        report['cases'].append({'model':model,'file':stem,'iso':iso,'rois':rois,'size':SIZE,'gain':gain,
            'inferenceSeconds':sum(alltimes),'predictionCount':len(alltimes),'firstTileSeconds':alltimes[0],
            'medianTileSeconds':float(np.median(alltimes[1:])),'finite':True})
        (OUT/'metrics.json').write_text(json.dumps(report,indent=2))
    del session

# Lightroom reference uses the same ImageIO path; no denoiser is run on the enhanced DNG.
lr,meta=load('DSC00396-Enhanced-NR-enhanced-only')
for name,x,y in CASES['DSC00396']:
    a=lr[y:y+SIZE,x:x+SIZE,:3].copy();np.save(OUT/f'DSC00396-{name}-lightroom.npy',a)
    for ev in [0,2]:Image.fromarray(display(a,ev)).save(OUT/f'DSC00396-{name}-lightroom-ev{ev}.png')

# Contact sheets use native 384px center crops, with identical +2 EV display lift.
for stem,rois in CASES.items():
    columns=['input','nafnet','rawnind-linear','treenet-light']+(['lightroom'] if stem=='DSC00396' else [])
    sheet=Image.new('RGB',(384*len(columns),424*len(rois)),(24,24,27));draw=ImageDraw.Draw(sheet)
    font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',16)
    for row,(name,x,y) in enumerate(rois):
        for col,model in enumerate(columns):
            image=Image.open(OUT/f'{stem}-{name}-{model}-ev2.png').crop((192,192,576,576))
            sheet.paste(image,(col*384,row*424+40));draw.text((col*384+8,row*424+10),f'{name} / {model} / +2 EV',font=font,fill='white')
    sheet.save(OUT/f'{stem}-comparison.png')
print(json.dumps(report,indent=2),flush=True)
