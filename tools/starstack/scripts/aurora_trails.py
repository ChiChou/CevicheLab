#!/usr/bin/env python3
"""Reproducible brightness filtering + literal maximum, in camera coordinates.
Inputs are neutral scene-linear RAW exports from nativebench trail-export.
No per-frame tone/exposure normalization, stellar warp, or gap filling.
"""
import argparse,csv,json,time
from pathlib import Path
import numpy as np
import cv2
from PIL import Image,ImageDraw,ImageFont

ap=argparse.ArgumentParser();ap.add_argument('root',type=Path);ap.add_argument('--measure-only',action='store_true');ap.add_argument('--threshold-ev',type=float,default=.5);args=ap.parse_args()
r=args.root;manifest=json.loads((r/'manifest.json').read_text());metadata=json.loads((r/'metadata.json').read_text())
w,h=manifest[0]['width'],manifest[0]['height'];n=len(manifest)
assert n==len(metadata),'Export is incomplete'
assert n>=12
mask=np.fromfile(r/'sky-model-uneroded.f32','<f4').reshape(h,w)
def read(m):
    a=np.fromfile(r/m['cache'],'<f4').reshape(h,w,4)[...,:3]
    assert np.isfinite(a).all()
    return a
reference=read(manifest[0]);tile_values=[]
# Existing Ceviche SkyRemoval guided-refinement recipe: encoded sRGB blue guide,
# radius 20/3000 of long edge, epsilon .01, encoded result. No color-rule sky mask.
def srgb(a):return np.where(a<=.0031308,a*12.92,1.055*np.maximum(a,0)**(1/2.4)-.055)
guide=srgb(np.clip(reference[...,2],0,1)).astype(np.float32)
radius=max(1,round(max(w,h)*20/3000));size=(2*radius+1,)*2
def box(a):return cv2.boxFilter(a,-1,size,borderType=cv2.BORDER_REPLICATE)
mi,mp=box(guide),box(mask);variance=np.maximum(0,box(guide*guide)-mi*mi)
a=(box(guide*mask)-mi*mp)/(variance+.01);b=mp-a*mi
mask=srgb(np.clip(box(a)*guide+box(b),0,1)).astype(np.float32)
mask[mask<.001]=0;mask[mask>.999]=1
np.save(r/'sky-mask-used.npy',mask);Image.fromarray(np.uint8(mask*255)).save(r/'sky-mask-used.png')
# Fixed sky-only ROI, chosen from survey before measuring the new RAW exports.
# Median in each tile suppresses point stars; distributed tiles resist local aurora.
xs=np.linspace(.05*w,.95*w,6).astype(int);ys=np.linspace(.05*h,.40*h,4).astype(int)
assert np.min(mask[ys[0]:ys[-1],xs[0]:xs[-1]])>.98,'Quality ROI must be unobstructed sky'
t0=time.perf_counter()
for m in manifest:
    rgb=read(m);gray=rgb@np.array([.2126,.7152,.0722],dtype=np.float32)
    tile_values.append([float(np.median(gray[y0:y1,x0:x1])) for y0,y1 in zip(ys,ys[1:]) for x0,x1 in zip(xs,xs[1:])])
tile_values=np.array(tile_values);baseline=np.median(tile_values[:12],axis=0)
assert np.all(baseline>0)
tile_ev=np.log2(np.maximum(tile_values,1e-9)/baseline);median_ev=np.median(tile_ev,axis=1)
broad=(tile_ev>args.threshold_ev).mean(axis=1)>=.8
extreme=(tile_ev>4).mean(axis=1)>=.8
exclude=extreme.copy();runs=[];start=None
for i in range(n+1):
    if i<n and broad[i]:
        if start is None:start=i
    elif start is not None:
        if i-start>=3:exclude[start:i]=True;runs.append([start,i-1])
        start=None
assert (~exclude).any() and exclude.any(),'Expected a measurable filtering comparison; inspect decisions'
rows=[]
for i,(m,meta) in enumerate(zip(manifest,metadata)):
    rows.append({'index':i,'file':Path(m['file']).name,'camera_time':meta['dateTimeOriginal'],
        'relative_seconds':meta['relativeClock']-metadata[0]['relativeClock'],
        'previous_start_interval_seconds':None if i==0 else meta['relativeClock']-metadata[i-1]['relativeClock'],
        'sky_ev_above_early_baseline':float(median_ev[i]),'fraction_sky_tiles_above_threshold':float((tile_ev[i]>args.threshold_ev).mean()),
        'excluded_from_night_sky':bool(exclude[i]),'reason':('extreme broad sky brightness (>4 EV)' if extreme[i] else f'persistent broad sky brightness (>{args.threshold_ev:g} EV, >=3 consecutive observations)') if exclude[i] else 'within night-sky brightness policy'})
report={'frames':n,'kept':int((~exclude).sum()),'excluded':int(exclude.sum()),'width':w,'height':h,
        'mode':'literal per-channel maximum; fixed camera coordinates; no gap filling',
        'reference':manifest[0]['file'],'ground':'same reference foreground in both main previews',
        'sky_mask':'Existing SkyRemoval model on the reference, no experimental exposure boost or horizon erosion; existing Ceviche blue-channel guided-refinement recipe, no manual/color-threshold replacement.',
        'quality_rule':{'baseline':'per-tile median of first 12 chronological frames','sky_roi_fraction':[.05,.05,.95,.40],
          'tile_grid':[5,3],'broad_fraction':.8,'persistent_ev':args.threshold_ev,'minimum_consecutive_observations':3,'instant_extreme_ev':4,
          'note':'Scene-linear brightness relative to early night. No claim of RAW sensor saturation, focus quality, or generic aurora classification. Gaps do not cause exclusion.'},
        'persistent_runs_inclusive':runs,'baseline_tile_luminance':baseline.tolist(),'frames_detail':rows}
(r/'quality.json').write_text(json.dumps(report,indent=2)+'\n')
with (r/'quality.csv').open('w') as f:
    writer=csv.DictWriter(f,fieldnames=list(rows[0]));writer.writeheader();writer.writerows(rows)
print(json.dumps({k:report[k] for k in ['frames','kept','excluded','persistent_runs_inclusive']},indent=2),flush=True)
if args.measure_only:raise SystemExit()
all_max=np.full((h,w,3),-np.inf,dtype=np.float32);kept_max=all_max.copy()
for i,m in enumerate(manifest):
    rgb=read(m);np.maximum(all_max,rgb,out=all_max)
    if not exclude[i]:np.maximum(kept_max,rgb,out=kept_max)
np.save(r/'maximum-all-linear.npy',all_max);np.save(r/'maximum-filtered-linear.npy',kept_max)
shown_all=all_max*mask[...,None]+reference*(1-mask[...,None])
shown_kept=kept_max*mask[...,None]+reference*(1-mask[...,None])
assert np.isfinite(all_max).all() and np.isfinite(kept_max).all()
assert np.all(all_max>=kept_max)
assert np.array_equal(shown_all[mask==0],reference[mask==0]) and np.array_equal(shown_kept[mask==0],reference[mask==0])
report['checks']={'finite':True,'all_max_dominates_subset_max':True,'protected_ground_exact':True,'elapsed_python_seconds':time.perf_counter()-t0}
report['display']={'exposure_ev':0,'transfer':'linear sRGB to sRGB','common_for_both':True,'long_edge':1280}
(r/'quality.json').write_text(json.dumps(report,indent=2)+'\n')
def display(a):
    a=np.clip(a,0,1);a=np.where(a<=.0031308,a*12.92,1.055*a**(1/2.4)-.055)
    return Image.fromarray(np.round(a*255).astype('uint8'))
def save(a,name):
    im=display(a);im.thumbnail((1280,1280),Image.Resampling.LANCZOS);im.save(r/name);return im
all_im=save(shown_all,'trails-all-1280.png');filtered_im=save(shown_kept,'trails-filtered-1280.png')
save(all_max,'maximum-full-frame-all-1280.png');save(kept_max,'maximum-full-frame-filtered-1280.png')
save(reference,'reference-1280.png')
try:font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',20);small=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',15)
except OSError:font=ImageFont.load_default(size=20);small=ImageFont.load_default(size=15)
panel_h=all_im.height+74;sheet=Image.new('RGB',(1280,panel_h*2),'#15181d');d=ImageDraw.Draw(sheet)
for k,(im,title) in enumerate([(all_im,f'All {n} frames • maximum sky'),(filtered_im,f'Filtered • {report["kept"]} kept, {report["excluded"]} too bright for this night-sky policy')]):
    y=k*panel_h;sheet.paste(im,(0,y+74));d.text((16,y+10),title,font=font,fill='white');d.text((16,y+39),'Identical exposure/color display and reference foreground. Captured gaps retained.',font=small,fill='#bbc8d6')
sheet.save(r/'comparison-1280.png')
# Audit contact sheet: boundary observations plus representative early/late sky.
changes=np.flatnonzero(np.diff(exclude.astype(int)))
indices=sorted(set([0,11,n//2,n-1]+[int(j) for c in changes for j in range(max(0,c-2),min(n,c+4))]))
contact=Image.new('RGB',(1280,235*((len(indices)+3)//4)),'#15181d');draw=ImageDraw.Draw(contact)
for k,i in enumerate(indices):
    im=display(read(manifest[i]));im.thumbnail((320,190),Image.Resampling.LANCZOS);x=(k%4)*320;y=(k//4)*235;contact.paste(im,(x,y+42))
    draw.text((x+6,y+3),f'{rows[i]["file"]} • {"EXCLUDE" if exclude[i] else "KEEP"}',font=small,fill='#ffb59b' if exclude[i] else '#b4e5bc')
    draw.text((x+6,y+22),f'{median_ev[i]:+.2f} EV • {rows[i]["camera_time"].split()[-1]}',font=small,fill='white')
contact.save(r/'selection-audit-1280.png')
# Detail panel at original processing pixels: no local contrast enhancement.
box=(int(w*.32),int(h*.07),int(w*.72),int(h*.39));cw,ch=box[2]-box[0],box[3]-box[1]
detail=Image.new('RGB',(cw*2,ch+55),'#15181d');d=ImageDraw.Draw(detail)
for k,(a,title) in enumerate([(shown_all,'All frames'),(shown_kept,'Filtered')]):
    detail.paste(display(a).crop(box),(k*cw,55));d.text((k*cw+12,14),title,font=font,fill='white')
detail.save(r/'trail-detail.png')
print('Saved identical-display maximum-stack previews, audit and linear arrays.',flush=True)
