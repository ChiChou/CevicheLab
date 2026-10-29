"""Independent image checks and source-crop review for meteor_ai outputs."""
import collections
import json
import sys
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw
from meteor_ai import line_mask

r=Path(sys.argv[1]);g=r/'geometry'
def read_json(path):return json.loads(path.read_text())
j=read_json(g/'report.json');c=read_json(r/'candidates.json')
d=read_json(r/'detections.json');m=read_json(r/'proxies/manifest.json')
w,h=j['width'],j['height']
def frame(path):return np.fromfile(path,'<f4').reshape(h,w,4)
clean=frame(g/'stack-clean.rgba');out=frame(r/'meteor-composite.rgba');ref=frame(g/'reference.rgba')
owner=np.load(r/'meteor-owner.npy');sky=np.fromfile(g/'sky-mask.f32','<f4').reshape(h,w)
assert np.array_equal(out[owner<0],clean[owner<0])
assert np.array_equal(out[sky==0],ref[sky==0])
assert np.isfinite(out).all()
metrics=dict(unchanged_outside_selected_trail_footprints=True,protected_ground_max_change=0.,finite=True,
    selected_segments=sum(x['selected'] for x in c),selected_frames=len({x['frameIndex'] for x in c if x['selected']}),
    selected_origins=dict(collections.Counter(x['origin'] for x in c if x['selected'])))
fi=next((i for i,f in enumerate(m) if Path(f['source']).stem=='DSC00025'),None)
if fi is not None and j['frames'][fi].get('cache'):
    source=np.memmap(j['frames'][fi]['cache'],dtype='<f4',mode='r',shape=(h,w,4));core=np.zeros((h,w),bool)
    for x in c:
        if x['selected'] and x['frameIndex']==fi:
            region,alpha=line_mask(x,w,h);core[region]|=alpha>=.95
    core &= owner==fi
    if core.any():
        lum=np.array([.2126,.7152,.0722]);original=(source[core,:3]-clean[core,:3])@lum;retained=(out[core,:3]-clean[core,:3])@lum
        metrics['known_meteor']=dict(source='DSC00025.ARW',core_pixels=int(core.sum()),signed_residual_flux_ratio=float(retained.sum()/original.sum()))
errors=[f['alignment']['validationP95Error'] for f in j['frames'] if f.get('alignment') and f['metadata']['path']!=j['reference']]
metrics.update(median_frame_heldout_p95_px=float(np.median(errors)),worst_frame_heldout_p95_px=float(max(errors)))
(r/'quality.json').write_text(json.dumps(metrics,indent=2)+'\n');print(json.dumps(metrics,indent=2))
indices=sorted({x['frameIndex'] for x in c if x['selected']})
if indices:
    canvas=Image.new('RGB',(1200,240*((len(indices)+3)//4)),'#151515');draw=ImageDraw.Draw(canvas)
    for k,i in enumerate(indices):
        prediction=max((b for b in d['frames'][i]['detections'] if b['label']=='METEOR'),key=lambda b:b['score'])
        x0,y0,x1,y1=prediction['box'];cx,cy=(x0+x1)/2,(y0+y1)/2;edge=max(220,x1-x0+40,y1-y0+40)
        with Image.open(r/'proxies'/m[i]['proxy']) as image:
            crop=image.crop((int(cx-edge/2),int(cy-edge/2),int(cx+edge/2),int(cy+edge/2)))
        crop.thumbnail((300,210));x,y=(k%4)*300,(k//4)*240
        canvas.paste(crop,(x,y+30));draw.text((x+4,y+8),f"{Path(m[i]['source']).stem} score {prediction['score']:.2f}",fill='white')
    canvas.save(r/'selected-source-crops.jpg',quality=94)
