"""Verify the actual scratch DNG quantization and expected gallery assets."""
import json,struct,sys
from pathlib import Path
import numpy as np
root=Path(sys.argv[1]);rows=[]
for model,extension,channels in [('rawnind-bayer','rgb32',3),('pmrid','mosaic32',1)]:
    p=root/f'DSC00396-{model}.dng'
    with p.open('rb') as f:
        header=f.read(8);assert header[:4]==b'II*\0';first=struct.unpack_from('<I',header,4)[0]
        def tags(offset):
            f.seek(offset);n=struct.unpack('<H',f.read(2))[0]
            return {t:(k,c,v) for t,k,c,v in (struct.unpack('<HHII',f.read(12)) for _ in range(n))}
        top=tags(first);kind,count,offset=top[330];assert count==1
        t=tags(offset);w=t[256][2];h=t[257][2];payload=t[273][2]
        assert t[259][2]==1 and t[277][2]==channels
    shape=(h,w,3) if channels==3 else (h,w)
    actual=np.memmap(p,dtype='<u2',mode='r',offset=payload,shape=shape)
    original=np.memmap(root/f'DSC00396-{model}.{extension}',dtype='<f4',mode='r',shape=shape)
    maximum=0.;clipped=0
    for y in range(0,h,64):
        restored=(actual[y:y+64].astype(np.float64)-8192)/32768
        maximum=max(maximum,float(np.max(abs(restored-original[y:y+64]))))
        clipped+=int(np.count_nonzero((original[y:y+64]<-.25)|(original[y:y+64]>(65535-8192)/32768)))
    assert maximum<=1.54e-5 and clipped==0,(model,maximum,clipped)
    rows.append({'model':model,'width':w,'height':h,'clippedSamples':clipped,'maxMeasuredQuantizationError':maximum})
for stem,regions in [('DSC00032',['sky','mountain','water','foreground']),('DSC00396',['stars','aurora','window','dark-sky'])]:
    models=['input','nafnet','rawnind-linear','treenet-light']+(['mosaic','bayer','pmrid','lightroom'] if stem=='DSC00396' else [])
    for region in regions:
        for model in models:
            for ev in [0,2]:assert (root/'rgb-results'/f'{stem}-{region}-{model}-ev{ev}.png').stat().st_size>0
(root/'quantization-check.json').write_text(json.dumps(rows,indent=2));print(json.dumps(rows,indent=2))
