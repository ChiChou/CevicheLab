#!/usr/bin/env python3
"""Run actual upstream libraries; adapters/visualizations are explicitly separate."""
import argparse,json,time,sys
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw
from astropy.io import fits

parser=argparse.ArgumentParser();parser.add_argument('tool',choices=['seiza','astroalign','tetra3']);parser.add_argument('--cpu',action='store_true');a=parser.parse_args()
root=Path(__file__).resolve().parents[1]/'output/comparison';inp=root/'input1600'
manifest=json.loads((inp/'manifest.json').read_text());w,h=manifest[0]['width'],manifest[0]['height'];ri=next(i for i,m in enumerate(manifest) if m['reference'])
def frame(i):return np.fromfile(inp/(manifest[i]['base']+'.rgba'),dtype='<f4').reshape(h,w,4)[...,:3].copy()
reference=frame(ri)
original=json.loads((root.parent/'pilot-final-3200/report.json').read_text())
mask=np.fromfile(root.parent/'pilot-final-3200/sky-mask.f32',dtype='<f4').reshape(original['height'],original['width'])
mask=np.asarray(Image.fromarray(mask).resize((w,h),Image.Resampling.BILINEAR))
out=root/(a.tool+('-cpu' if a.cpu else ''));out.mkdir(exist_ok=True)
def preview(rgb,path):
    rgb=np.nan_to_num(rgb,nan=0,posinf=1,neginf=0);rgb=np.clip(rgb,0,1)
    srgb=np.where(rgb<=.0031308,12.92*rgb,1.055*rgb**(1/2.4)-.055)
    im=Image.fromarray(np.round(srgb*255).astype('uint8'));im.thumbnail((1280,1280));im.save(path)
def save_report(report):
    (out/'report.json').write_text(json.dumps(report,indent=2,default=lambda x:x.tolist() if hasattr(x,'tolist') else str(x))+'\n')
def save_stack(rgb):
    np.save(out/'upstream-clean.npy',rgb);preview(rgb,out/'upstream-clean.png')
    # This foreground protection is our adapter, not a feature claimed for upstream.
    shown=reference.copy();valid=np.isfinite(rgb).all(axis=2);alpha=mask*valid
    shown=alpha[...,None]*np.nan_to_num(rgb)+(1-alpha[...,None])*reference
    np.save(out/'foreground-adapter.npy',shown);preview(shown,out/'foreground-adapter.png')

if a.tool=='seiza':
    import seiza
    paths=[]
    for i,m in enumerate(manifest):
        path=inp/(m['base']+'.fits');paths.append(str(path))
        if not path.exists():
            hdr=fits.Header();hdr['EXPTIME']=m['exposure'];hdr['FOCALLEN']=16.;hdr['IMAGETYP']='LIGHT'
            fits.writeto(path,frame(i).transpose(2,0,1),hdr,overwrite=False)
    order=[ri]+[i for i in range(len(paths)) if i!=ri]
    opts=seiza.StackOptions(normalization='none',registration_model='quadratic',maximum_stars=700,
        triangle_stars=40,maximum_registration_rms=2.0,minimum_integrated_fraction=.3,
        gpu=seiza.GpuOptions(enabled=not a.cpu,trace=True,memory_bytes=4*1024**3))
    t=time.perf_counter();result=seiza.stack_fits([paths[i] for i in order],str(out/'stack.fits'),options=opts,defects='off')
    elapsed=time.perf_counter()-t;data=fits.getdata(out/'stack.fits');rgb=data.transpose(1,2,0) if data.shape[0]==3 else data
    report={'tool':'seiza','version':seiza.__version__,'gpu_requested':not a.cpu,'elapsed_seconds':elapsed,'options':str(opts),'frames':[]}
    for f in result.frames:
        d={k:getattr(f,k) for k in dir(f) if not k.startswith('_') and not callable(getattr(f,k))};report['frames'].append(d);print(d,flush=True)
    report['accepted_nonreference']=sum(bool(f['accepted']) for f in report['frames'])
    report['accepted']=report['accepted_nonreference']+1;save_report(report);save_stack(rgb)
    print('SEIZA COMPLETE',elapsed,report['accepted'],flush=True)
elif a.tool=='astroalign':
    import astroalign as aa
    aligned=[];records=[];t0=time.perf_counter()
    target=(reference@np.array([.2126,.7152,.0722]))*np.where(mask>.98,1,0)
    for i,m in enumerate(manifest):
        source=frame(i);start=time.perf_counter()
        try:
            if i==ri:warped=source.copy();invalid=np.zeros((h,w),bool);matrix=np.eye(3);matches=0;error=0
            else:
                luma=(source@np.array([.2126,.7152,.0722]))*np.where(mask>.98,1,0)
                transform,(sp,tp)=aa.find_transform(luma,target,max_control_points=100,detection_sigma=5,min_area=3)
                warped,invalid=aa.apply_transform(transform,source,reference,fill_value=np.nan)
                matrix=transform.params;matches=len(sp);error=float(np.sqrt(np.mean(np.sum((transform(sp)-tp)**2,axis=1))))
            warped[invalid]=np.nan;aligned.append(warped)
            d={'file':m['source'],'accepted':True,'matrix':matrix,'matches':matches,'fit_rms_px':error,'seconds':time.perf_counter()-start}
        except Exception as e:d={'file':m['source'],'accepted':False,'error':repr(e),'seconds':time.perf_counter()-start}
        records.append(d);print(m['base'],d.get('matches'),d.get('error'),flush=True)
    # Astroalign only registers; this clipped mean is our explicit comparison adapter.
    output=reference.copy()
    for y in range(0,h,32):
        cube=np.stack([f[y:y+32] for f in aligned]);lum=cube@np.array([.2126,.7152,.0722])
        mid=np.nanmedian(lum,axis=0);mad=np.nanmedian(abs(lum-mid),axis=0)
        keep=abs(lum-mid)<=np.maximum(1e-5,4.5*1.4826*mad)
        count=keep.sum(axis=0);total=np.where(keep[...,None],np.nan_to_num(cube),0).sum(axis=0)
        output[y:y+32]=np.divide(total,np.maximum(1,count)[...,None]);output[y:y+32][count<3]=reference[y:y+32][count<3]
    save_report({'tool':'astroalign','version':aa.__version__,'elapsed_seconds':time.perf_counter()-t0,'frames':records,'accepted':len(aligned),
        'adapter':'sky mask for feature detection; numpy clipped mean; reference foreground; upstream performs registration only'})
    save_stack(output)
elif a.tool=='tetra3':
    import tetra3
    t0=time.perf_counter();solver=tetra3.Tetra3();attempts=[]
    # The supplied database supports narrow FOVs. Crops are real, unwarped source pixels.
    for x,y,size in [(625,110,350),(950,80,350),(200,120,350),(650,300,300),(450,30,500)]:
        rgb=reference[y:y+size,x:x+size];gray=rgb@np.array([.2126,.7152,.0722])
        t=time.perf_counter()
        result=solver.solve_from_image(Image.fromarray(gray.astype('float32')),fov_estimate=float(np.degrees(2*np.arctan(size/(2*750)))),fov_max_error=8,
            pattern_checking_stars=15,solve_timeout=15000,distortion=(-.15,.15),return_matches=True,
            sigma=3,min_area=2,max_area=100,binary_open=False,max_returned=60)
        result['crop']=[x,y,size,size];result['wall_seconds']=time.perf_counter()-t
        attempts.append(result);print('TETRA',result,flush=True)
        if result.get('RA') is not None:
            preview(rgb,out/'solved-crop.png');im=Image.open(out/'solved-crop.png').convert('RGB');d=ImageDraw.Draw(im)
            for yy,xx in result['matched_centroids']:d.ellipse((xx-5,yy-5,xx+5,yy+5),outline='lime',width=1)
            im.save(out/'matched-stars.png');np.save(out/'solved-crop.npy',gray);break
    save_report({'tool':'tetra3','elapsed_seconds':time.perf_counter()-t0,'attempts':attempts,'solved':any(r.get('RA') is not None for r in attempts)})
