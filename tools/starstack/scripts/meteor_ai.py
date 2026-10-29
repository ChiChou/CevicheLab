#!/usr/bin/env python3
"""Experimental MetDetPhoto -> EXIF star morph -> measured meteor composite CLI.

Requires the pinned upstream checkout and its local ONNX weight; never downloads
or modifies source photographs. See METDETPY-EXPERIMENT.md for setup and limits.
"""
import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import tifffile
from PIL import Image, ImageCms, ImageDraw

REVISION = '2ae98d12a53cbd48f08772cc9da1146b19b29d41'
WEIGHT_SHA = 'f97d3e92e69c42fba74c1835adc210891595aff183bd7e937376b9a7d728cfeb'
ROOT = Path(__file__).resolve().parents[1]

def save(path, data):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(data, indent=2, allow_nan=False) + '\n')
    temp.replace(path)

def load(path):
    return json.loads(path.read_text())

def log(*args):
    print(*args, flush=True)

def cross2(a, b):
    return a[0]*b[1]-a[1]*b[0]

def project(points, alignment):
    """Same source-to-reference convention as StarStackCore.Alignment.apply."""
    p = np.asarray(points, dtype=float)
    m = np.asarray(alignment['transform']['m']).reshape(3, 3)
    result = (p @ m[:2, :2].T + m[:2, 2]) / (p @ m[2, :2] + m[2, 2])[:, None]
    morph = alignment.get('morph')
    if morph:
        u, v = ((p + morph.get('inputOffset', 0)) / morph['scale']).T
        u -= .5; v -= .35
        basis = np.column_stack([np.ones(len(p)), u, v, u*u, u*v, v*v, u**3, u*u*v, u*v*v, v**3])
        result += basis @ np.array([morph['x'], morph['y']]).T
    return result

def box_polygon(box, alignment, scale):
    x0, y0, x1, y1 = box
    t = np.linspace(0, 1, 12)
    border = np.concatenate([np.column_stack([x0+(x1-x0)*t, t*0+y0]),
                             np.column_stack([t*0+x1, y0+(y1-y0)*t]),
                             np.column_stack([x1-(x1-x0)*t, t*0+y1]),
                             np.column_stack([t*0+x0, y1-(y1-y0)*t])])
    return project((border+.5)*scale-.5, alignment)

def preview(rgb, path):
    rgb = np.clip(rgb[..., :3], 0, 1)
    srgb = np.where(rgb <= .0031308, rgb*12.92, 1.055*rgb**(1/2.4)-.055)
    im = Image.fromarray(np.round(srgb*255).astype('uint8'))
    icc = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    im.save(path, quality=95, subsampling=0, icc_profile=icc)
    return im

def detect(args, manifest):
    import onnxruntime as ort
    sys.path.insert(0, str(args.upstream))
    from MetLib.model import YOLOModel
    from MetLib.utils import get_id2name
    model_path = args.upstream / 'weights/yolov5s_v2.onnx'
    sha = hashlib.sha256(model_path.read_bytes()).hexdigest()
    if sha != WEIGHT_SHA:
        raise ValueError('Unexpected checkpoint SHA256; review it before running')
    revision = subprocess.check_output(['git', '-C', str(args.upstream), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != REVISION:
        raise ValueError('Unexpected upstream revision')
    config = dict(revision=revision, weight_sha256=sha, provider=args.provider,
                  scales=args.scales, objectness=.25, score_threshold=.25,
                  score_semantics='sqrt(objectness * class score)', input='8-bit sRGB BGR proxies -> upstream RGB/NCHW')
    path = args.output / 'detections.json'
    previous = load(path) if path.exists() else None
    if previous and previous['config'] != config:
        raise ValueError('Detection settings differ: choose a new output directory')
    records = previous['frames'] if previous else []
    if len(records) == len(manifest) and all(f['status'] == 'ok' for f in records):
        log('Using complete, matching detection cache'); return previous
    # Completed failures remain explicit; retry from the first failed frame.
    first_bad = next((i for i, f in enumerate(records) if f['status'] != 'ok'), len(records))
    records = records[:first_bad]
    if args.provider == 'coreml' and 'CoreMLExecutionProvider' not in ort.get_available_providers():
        raise RuntimeError('Core ML provider unavailable; explicitly choose --provider cpu')
    # Instrument the upstream's unmodified ORT construction, then restore it.
    original_options = ort.SessionOptions
    def options():
        result = original_options(); result.enable_profiling = True
        result.profile_file_prefix = str(args.output / 'onnx-profile')
        return result
    ort.SessionOptions = options
    started = time.perf_counter()
    try:
        model = YOLOModel(str(model_path), dtype='float32', providers_key=args.provider, nms=True, warmup=True,
                          num_threads=4, multiscale_pred=args.scales, multiscale_partition=2)
    finally:
        ort.SessionOptions = original_options
    info = dict(config=config, frames=records, model_input_shape=model.backend.input_shape,
                active_providers=model.backend.model_session.get_providers(),
                initialization_seconds=time.perf_counter()-started, onnxruntime=ort.__version__)
    classes = get_id2name()
    try:
        for item in manifest[len(records):]:
            tick = time.perf_counter()
            rec = dict(index=item['index'], source=item['source'], detections=[], status='error')
            try:
                image = cv2.imread(str(args.output/'proxies'/item['proxy']))
                if image is None or image.shape[:2] != (item['height'], item['width']):
                    raise ValueError('Unreadable or wrong-sized detector proxy')
                boxes, scores = model.forward(image)
                for box, score in zip(boxes, scores):
                    label = int(np.argmax(score))
                    rec['detections'].append(dict(box=np.asarray(box).astype(float).tolist(),
                        label=classes[label], score=float(score[label]), class_scores=score.astype(float).tolist()))
                rec['status'] = 'ok'
            except Exception as error:
                rec['error'] = repr(error)
            rec['seconds'] = time.perf_counter()-tick
            records.append(rec); save(path, info)
            log('DETECT', item['index']+1, '/', len(manifest), Path(item['source']).name,
                rec['status'], [(d['label'], round(d['score'], 3)) for d in rec['detections']])
    finally:
        profile = model.backend.model_session.end_profiling()
        events = load(Path(profile)); providers = {}
        for event in events:
            provider = event.get('args', {}).get('provider')
            if provider:
                entry = providers.setdefault(provider, {'node_events': 0, 'duration_us': 0})
                entry['node_events'] += 1; entry['duration_us'] += event.get('dur', 0)
        info['profile'] = profile; info['profiled_providers'] = providers; save(path, info)
    if any(f['status'] != 'ok' for f in records):
        raise RuntimeError('Inference failures recorded; rerun to retry, do not treat as negatives')
    return info

def streak_points(streak):
    return np.array([[streak[k]['x'], streak[k]['y']] for k in ['start', 'end']], dtype=float)

def line_mask(streak, w, h):
    a, b = streak_points(streak); d = b-a; length2 = d@d
    radius = max(2, streak['width']*1.5)
    x0, y0 = np.maximum(0, np.floor(np.minimum(a, b)-radius-1).astype(int))
    x1, y1 = np.minimum([w, h], np.ceil(np.maximum(a, b)+radius+2).astype(int))
    if x1 <= x0 or y1 <= y0 or length2 <= 0:
        return (slice(0, 0), slice(0, 0)), np.zeros((0, 0), np.float32)
    yy, xx = np.mgrid[y0:y1, x0:x1]
    t = np.clip(((xx-a[0])*d[0]+(yy-a[1])*d[1])/length2, 0, 1)
    distance = np.hypot(xx-a[0]-t*d[0], yy-a[1]-t*d[1])
    alpha = np.clip((radius-distance)/max(.5, radius*.35), 0, 1).astype(np.float32)
    return (slice(y0, y1), slice(x0, x1)), alpha

def merge_segments(lines):
    """Merge overlapping collinear CV/AI fragments within one exposure."""
    lines=[dict(s) for s in lines]
    changed=True
    while changed:
        changed=False
        for i,a in enumerate(lines):
            p,q=streak_points(a);d=q-p;length=np.linalg.norm(d);d/=length
            for k in range(i+1,len(lines)):
                b=lines[k];u,v=streak_points(b);e=v-u;e/=np.linalg.norm(e)
                projection=(np.array([u,v])-p)@d
                gap=max(0,projection.min()-length,-projection.max())
                if abs(cross2(d,e))>.07 or max(abs(cross2(u-p,d)),abs(cross2(v-p,d)))>3 or gap>8:continue
                lo=min(0,float(projection.min()));hi=max(length,float(projection.max()))
                origins=set(a['origin'].split('+')+b['origin'].split('+'))
                lines[i]=dict(a,start=dict(zip(['x','y'],(p+lo*d).tolist())),
                    end=dict(zip(['x','y'],(p+hi*d).tolist())),width=max(a['width'],b['width']),
                    pixels=max(a['pixels'],b['pixels']),peakResidual=max(a['peakResidual'],b['peakResidual']),
                    origin='+'.join(sorted(origins)),merged_fragments=a.get('merged_fragments',1)+b.get('merged_fragments',1))
                del lines[k];changed=True;break
            if changed:break
    return lines

def refine_roi(source, clean, sky, star_mask, polygon, frame_index):
    """Find measured line support inside an AI box, never paste the rectangle."""
    h, w = sky.shape
    roi = np.zeros((h, w), np.uint8)
    cv2.fillPoly(roi, [np.round(polygon).astype(np.int32)], 1)
    valid = (sky>.98)&(source[..., 3]>0)
    valid = cv2.erode(valid.astype(np.uint8), np.ones((17,17), np.uint8)) > 0
    residual = (source[..., :3]-clean[..., :3]) @ np.array([.2126,.7152,.0722], np.float32)
    high = residual-cv2.boxFilter(residual, -1, (25,25))
    eligible = (roi>0)&valid&(~star_mask)
    values = high[eligible]
    if len(values)<100: return []
    center = np.median(values); sigma = max(1e-6, 1.4826*np.median(abs(values-center)))
    active = eligible & (high > center+3.5*sigma)
    lines = cv2.HoughLinesP(active.astype('uint8')*255, 1, np.pi/720,
                            threshold=10, minLineLength=12, maxLineGap=6)
    if lines is None: return []
    yy, xx = np.nonzero(active); points = np.column_stack([xx, yy]); found=[]
    for line in lines.reshape(-1,4):
        a, b = line.reshape(2,2).astype(float); d=b-a; length=np.linalg.norm(d); d/=length
        along=(points-a)@d; across=abs((points[:,0]-a[0])*d[1]-(points[:,1]-a[1])*d[0])
        p=points[(across<2.5)&(along>-3)&(along<length+3)]
        if len(p)<10: continue
        centroid=p.mean(axis=0); eig, axes=np.linalg.eigh(np.cov(p.T)); direction=axes[:,-1]
        q=(p-centroid)@direction; lo,hi=np.quantile(q,[0,.99]); width=max(1,2.96*np.median(abs((p-centroid)@axes[:,0])))
        if hi-lo<12 or (hi-lo)/width<6 or width>5: continue
        ends=[centroid+lo*direction,centroid+hi*direction]
        found.append(dict(frameIndex=frame_index,start=dict(zip(['x','y'],ends[0].tolist())),
            end=dict(zip(['x','y'],ends[1].tolist())),width=float(width),pixels=len(p),
            peakResidual=float(high[p[:,1],p[:,0]].max()),origin='ai-roi-measured-line',local_sigma=float(sigma)))
    # Longest supported segment first; suppress overlapping fragments.
    kept=[]
    for line in sorted(found,key=lambda s:np.linalg.norm(np.diff(streak_points(s),axis=0)),reverse=True):
        a,b=streak_points(line); mid=(a+b)/2; d=(b-a)/np.linalg.norm(b-a)
        duplicate=False
        for old in kept:
            c,e=streak_points(old); u=(e-c)/np.linalg.norm(e-c)
            duplicate |= abs(cross2(d,u))<.1 and abs(cross2(mid-c,u))<4 and np.linalg.norm(mid-(c+e)/2)<(np.linalg.norm(b-a)+np.linalg.norm(e-c))/2
        if not duplicate: kept.append(line)
    return kept

def compose(args, manifest, detections):
    geometry=args.output/'geometry'; report=load(geometry/'report.json'); w,h=report['width'],report['height']
    if [f['metadata']['path'] for f in report['frames']] != [f['source'] for f in manifest]:
        raise ValueError('Detector and geometry sequences differ')
    if [f['source'] for f in detections['frames']] != [f['source'] for f in manifest]:
        raise ValueError('Incomplete or differently ordered detection results')
    def read(name): return np.fromfile(geometry/name,dtype='<f4').reshape(h,w,4)
    clean=read('stack-clean.rgba'); reference=read('reference.rgba')
    sky=np.fromfile(geometry/'sky-mask.f32','<f4').reshape(h,w)
    ri=next(i for i,f in enumerate(manifest) if f['reference'])
    stars=np.zeros((h,w),np.uint8)
    for star in report['frames'][ri]['stars']:
        cv2.circle(stars,(round(star['point']['x']),round(star['point']['y'])),4,1,-1)
    candidates=[]; transformed=[]
    for i,(frame,det,item) in enumerate(zip(report['frames'],detections['frames'],manifest)):
        if det['status'] != 'ok': raise ValueError('Cannot classify failed inference as empty')
        existing=[dict(s,origin='cv-residual') for s in report['streaks'] if s['frameIndex']==i]
        boxes=[]
        if frame.get('alignment'):
            for prediction in det['detections']:
                poly=box_polygon(prediction['box'],frame['alignment'],w/item['width'])
                boxes.append(dict(prediction,polygon=poly.tolist()))
        transformed.append(dict(index=i,source=item['source'],aligned=bool(frame.get('cache')),boxes=boxes))
        if not frame.get('cache'): continue
        source=np.memmap(frame['cache'],dtype='<f4',mode='r',shape=(h,w,4))
        # Look for candidates missed by the global CV threshold inside AI meteor ROIs.
        for box in boxes:
            if box['label']=='METEOR' and box['score']>=args.meteor_score:
                polygon=np.asarray(box['polygon'])
                if not any(cv2.pointPolygonTest(polygon.astype(np.float32),tuple(streak_points(s).mean(axis=0)),False)>=0 for s in existing):
                    existing += refine_roi(source,clean,sky,stars>0,polygon,i)
        for candidate in merge_segments(existing):
            points=streak_points(candidate); probes=points[0]+np.linspace(0,1,11)[:,None]*(points[1]-points[0])
            associated=[]
            for box in boxes:
                poly=np.asarray(box['polygon'],np.float32)
                overlap=np.mean([cv2.pointPolygonTest(poly,tuple(p),True)>=-3 for p in probes])
                if overlap>=.5: associated.append(dict(label=box['label'],score=box['score'],line_overlap=float(overlap)))
            candidate['ai']=associated
            candidate['meteor_score']=max([d['score'] for d in associated if d['label']=='METEOR'],default=0)
            candidate['aircraft_score']=max([d['score'] for d in associated if d['label']=='PLANE/SATELLITE'],default=0)
            candidates.append(candidate)
    # Persistence uses capture time as well as nearby sequence indices.
    parent=list(range(len(candidates)))
    def root(i):
        while parent[i]!=i: i=parent[i]
        return i
    for i,a in enumerate(candidates):
        p,q=streak_points(a); d=q-p; length=np.linalg.norm(d)
        for k in range(i):
            b=candidates[k]; gap=abs(a['frameIndex']-b['frameIndex'])
            dt=abs(manifest[a['frameIndex']]['midpoint']-manifest[b['frameIndex']]['midpoint'])
            if not(0<gap<=2 and dt<=60): continue
            u,v=streak_points(b); e=v-u; other=np.linalg.norm(e)
            distance=min(np.linalg.norm(x-y) for x in [p,q] for y in [u,v])
            if abs(cross2(d,e))/(length*other)<.12 and abs(cross2(u-p,d))/length<12 and distance<max(30,max(length,other)*2):
                parent[root(i)]=root(k)
    groups={}
    for i,c in enumerate(candidates): groups.setdefault(root(i),set()).add(c['frameIndex'])
    result=clean.copy(); strongest=np.full((h,w),-np.inf,np.float32); ownership=np.full((h,w),-1,np.int16)
    for i,c in enumerate(candidates):
        c['persistent']=len(groups[root(i)])>=3
        c['selected']=bool(c['meteor_score']>=args.meteor_score and c['meteor_score']>c['aircraft_score'] and not c['persistent'])
        c['decision']='selected-ai-and-measured-line' if c['selected'] else ('persistent-track-review' if c['persistent'] else 'unconfirmed-or-other-class-review')
        if not c['selected']: continue
        source=np.memmap(report['frames'][c['frameIndex']]['cache'],dtype='<f4',mode='r',shape=(h,w,4))
        region,alpha=line_mask(c,w,h)
        alpha*=((source[region][...,3]>0)&(sky[region]>.98))
        delta=source[region][...,:3]-clean[region][...,:3]
        score=alpha*(delta@np.array([.2126,.7152,.0722],np.float32))
        # Whole RGB ownership; do not maximize channels independently.
        keep=(alpha>0)&(score>strongest[region])
        result[region][...,:3][keep]=(clean[region][...,:3]+alpha[...,None]*delta)[keep]
        strongest[region][keep]=score[keep];ownership[region][keep]=c['frameIndex']
        c['composited_pixels']=int(keep.sum())
    if not np.isfinite(result).all(): raise ValueError('Non-finite composite')
    ground=sky==0
    assert np.array_equal(result[ground],reference[ground])
    out=args.output
    np.save(out/'meteor-owner.npy',ownership)
    tifffile.imwrite(out/'meteor-composite-linear.tiff',result[...,:3],photometric='rgb',metadata={'color_space':'extended linear sRGB'})
    result.astype('<f4').tofile(out/'meteor-composite.rgba')
    images=[preview(frame,out/name) for frame,name in [(reference,'reference.jpg'),(clean,'clean-background.jpg'),(result,'meteor-composite.jpg')]]
    canvas=Image.new('RGB',(w*3,h+40),'#12151b');draw=ImageDraw.Draw(canvas)
    for n,(im,title) in enumerate(zip(images,['Single reference','Robust background','AI + measured meteor trails'])):
        canvas.paste(im,(n*w,40));draw.text((n*w+15,12),title,fill='white')
    canvas.save(out/'comparison.jpg',quality=95,subsampling=0)
    annotated=images[-1].copy();draw=ImageDraw.Draw(annotated)
    for i,c in enumerate(candidates):
        if c['selected']:
            p,q=streak_points(c);draw.line([tuple(p),tuple(q)],fill='lime',width=2)
            draw.text(tuple(p+4),f"{i}: {Path(manifest[c['frameIndex']]['source']).stem} {c['meteor_score']:.2f}",fill='yellow')
    annotated.save(out/'selected-trails.jpg',quality=95)
    failures=[dict(source=f['metadata']['path'],reason=f.get('failure')) for f in report['frames'] if not f.get('cache')]
    summary=dict(frames=len(manifest),detection_completed=sum(f['status']=='ok' for f in detections['frames']),
        ai_boxes=sum(len(f['detections']) for f in detections['frames']),
        ai_meteor_frames=sum(any(d['label']=='METEOR' and d['score']>=args.meteor_score for d in f['detections']) for f in detections['frames']),
        aligned=len(manifest)-len(failures),alignment_failures=failures,width=w,height=h,
        morph_frames=sum(bool((f.get('alignment') or {}).get('morph')) for f in report['frames']),
        candidates=len(candidates),selected=sum(c['selected'] for c in candidates),
        selected_source_frames=sorted({Path(manifest[c['frameIndex']]['source']).name for c in candidates if c['selected']}),
        ground_max_abs_change=float(np.max(abs(result[ground]-reference[ground]))),
        finite=True,meteor_score_threshold=args.meteor_score,detector=detections['config'],
        profiled_providers=detections.get('profiled_providers'),
        caveats=['Candidates are not confirmed meteor identities','Unaligned detections remain in review; never pasted without geometry',
                 'Sky photometric loss and within-exposure elongation inherit baseline limitations','No detector recall established without annotations'])
    save(out/'candidates.json',candidates);save(out/'warped-detections.json',transformed);save(out/'summary.json',summary)
    log('COMPLETE',json.dumps(summary,indent=2))

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('input',type=Path);p.add_argument('output',type=Path)
    p.add_argument('--upstream',type=Path,required=True);p.add_argument('--sky-model',type=Path,required=True)
    p.add_argument('--provider',choices=['cpu','coreml'],default='coreml')
    p.add_argument('--detect-edge',type=int,default=3200);p.add_argument('--edge',type=int,default=1600)
    p.add_argument('--scales',type=int,choices=[1,2,3],default=2)
    p.add_argument('--meteor-score',type=float,default=.5)
    p.add_argument('--stage',choices=['all','detect','compose'],default='all')
    args=p.parse_args()
    for name in ['input','output','upstream','sky_model']: setattr(args,name,getattr(args,name).resolve())
    if not(128<=args.edge<=8000 and 128<=args.detect_edge<=8000 and 0<=args.meteor_score<=1):p.error('Invalid dimensions or threshold')
    args.output.mkdir(parents=True,exist_ok=True)
    sources=sorted(args.input.glob('*.ARW'))
    if len(sources)<3: p.error('This experiment expects at least three Sony .ARW files')
    identity=dict(sources=[dict(path=str(f),bytes=f.stat().st_size,mtime_ns=f.stat().st_mtime_ns) for f in sources],
                  edge=args.edge,detect_edge=args.detect_edge,sky_model=str(args.sky_model))
    identity_path=args.output/'inputs.json'
    if identity_path.exists() and load(identity_path)!=identity:raise ValueError('Inputs/settings changed; choose a new output directory')
    save(identity_path,identity)
    manifest_path=args.output/'proxies/manifest.json'
    if not manifest_path.exists():
        subprocess.run([str(ROOT/'.build/release/meteorprep'),str(args.input),str(args.output/'proxies'),str(args.detect_edge)],check=True)
    manifest=load(manifest_path)
    if {f['source'] for f in manifest}!={str(f) for f in sources} or max(manifest[0]['width'],manifest[0]['height'])!=args.detect_edge:
        raise ValueError('Proxy manifest differs from requested inputs/settings')
    detections=load(args.output/'detections.json') if args.stage=='compose' else detect(args,manifest)
    if args.stage=='detect':return
    geometry=args.output/'geometry'
    if not all((geometry/name).exists() for name in ['report.json','stack-clean.rgba','stack-meteors.rgba','reference.rgba','sky-mask.f32']):
        subprocess.run([str(ROOT/'.build/release/starstack'),'stack',str(args.input),str(geometry),
            '--sky-model',str(args.sky_model),'--count',str(len(manifest)),'--edge',str(args.edge),
            '--analysis-edge','3200','--streak-policy','none'],check=True)
    report=load(geometry/'report.json')
    if report['width']!=args.edge or any(f.get('failure')=='not processed' for f in report['frames']):
        raise ValueError('Incomplete or differently sized geometry cache')
    compose(args,manifest,detections)

if __name__=='__main__':main()
