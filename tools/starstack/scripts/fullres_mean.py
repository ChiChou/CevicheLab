#!/usr/bin/env python3
"""Five-frame, full-resolution mean with EXIF-informed wide-field sky geometry.
No learned restoration, pixel clipping/rejection, or output downscaling.
"""
import argparse,json,time,struct,zlib
from pathlib import Path
import numpy as np,cv2,tifffile
from scipy.optimize import least_squares
from scipy.spatial.transform import Rotation
from PIL import Image,ImageCms,ImageDraw,ImageFont

p=argparse.ArgumentParser();p.add_argument('root',type=Path);p.add_argument('--geometry-only',action='store_true');a=p.parse_args()
r=a.root;j=json.loads((r/'manifest.json').read_text());w,h=j['width'],j['height'];aw,ah=j['analysisWidth'],j['analysisHeight'];ri=j['referenceIndex'];frames=j['frames']
assert len(frames)==5 and (w,h)==(7952,5304)
def src(i):return np.memmap(r/frames[i]['cache'],dtype='<f4',mode='r',shape=(h,w,4))
def smallmask(i):return np.fromfile(r/frames[i]['mask'],'<f4').reshape(ah,aw)
ref=src(ri);f0=w*j['focal35']/36;epoch=frames[ri]['metadata']['relativeClock']+frames[ri]['metadata']['exposure']/2
dts=np.array([(epoch-f['metadata']['relativeClock']-f['metadata']['exposure']/2)/1000 for f in frames])
cx,cy=(w-1)/2,(h-1)/2
def srgb(v):return np.where(v<=.0031308,v*12.92,1.055*np.maximum(v,0)**(1/2.4)-.055)
def project(points,m):
    q=points@m[:2,:2].T+m[:2,2];z=points@m[2,:2]+m[2,2];return q/z[:,None]
def matrix(params,i):
    f=f0*np.exp(params[3]);K=np.array([[f,0,cx],[0,f,cy],[0,0,1.]])
    return K@Rotation.from_rotvec(params[:3]*dts[i]).as_matrix()@np.linalg.inv(K)
def basis(xy,degree=3):
    u=(xy[:,0]-cx)/w;v=(xy[:,1]-cy)/w
    b=[np.ones(len(xy)),u,v,u*u,u*v,v*v]
    if degree==3:b += [u*u*u,u*u*v,u*v*v,v*v*v]
    return np.column_stack(b)
def centroid(image,point):
    x,y=point;ix,iy=round(x),round(y);rad=14
    if not(rad<ix<w-rad-1 and rad<iy<h-rad-1):return point,False
    rgb=np.asarray(image[iy-rad:iy+rad+1,ix-rad:ix+rad+1,:3]);patch=rgb@np.array([.2126,.7152,.0722])
    yy,xx=np.mgrid[-rad:rad+1,-rad:rad+1];ring=xx*xx+yy*yy>100
    plane=np.column_stack([np.ones(ring.sum()),xx[ring],yy[ring]])
    fit=np.linalg.lstsq(plane,patch[ring],rcond=None)[0];signal=patch-(fit[0]+fit[1]*xx+fit[2]*yy)
    q=np.array([x-ix,y-iy]);noise=np.median(abs(signal[ring]-np.median(signal[ring])))*1.4826
    # Extended-linear developed RGB can exceed 1 without establishing sensor
    # clipping. Let correspondence holdout checks reject unstable centers rather
    # than discarding nearly every bright registration star at an sRGB threshold.
    if signal.max()<8*noise:return point,False
    for _ in range(8):
        weights=np.exp(-((xx-q[0])**2+(yy-q[1])**2)/(2*5.0**2));v=signal*weights;total=v.sum()
        if total<=0:return point,False
        nxt=np.array([(v*xx).sum(),(v*yy).sum()]);delta=np.linalg.norm(nxt/total-q);q=nxt/total
        if delta<.002:break
    result=q+[ix,iy]
    return result,bool(np.linalg.norm(result-point)<4)

start=time.perf_counter();observations={}
for i,f in enumerate(frames):
    if i==ri:continue
    image=src(i);sp=[];tp=[]
    for pair in f['alignment']['matches']:
        ss=np.array([pair['source']['x'],pair['source']['y']]);tt=np.array([pair['reference']['x'],pair['reference']['y']])
        ss=(ss+.5)*(w/aw)-.5;tt=(tt+.5)*(w/aw)-.5
        ss,ok=centroid(image,ss);tt,ok2=centroid(ref,tt)
        if ok and ok2:sp.append(ss);tp.append(tt)
    sp=np.asarray(sp);tp=np.asarray(tp);order=np.lexsort((sp[:,0],sp[:,1]));sp=sp[order];tp=tp[order]
    assert len(sp)>60
    held=np.arange(len(sp))%5==0;observations[i]=(sp,tp,held)
    print('native centroids',i,len(sp),flush=True)

def residual(params,all_points=False):
    out=[]
    for i,(sp,tp,held) in observations.items():
        keep=np.ones(len(sp),bool) if all_points else ~held
        out.append((project(sp[keep],matrix(params,i))-tp[keep]).ravel())
    # EXIF focal length is a prior, not just a label. Allow limited effective-FOV
    # changes from lens correction/cropping; use actual elapsed times in every ray.
    out.append(np.array([params[3]/.15]));return np.concatenate(out)
fit=least_squares(residual,np.zeros(4),loss='soft_l1',f_scale=1,max_nfev=120,
                  bounds=([-1,-1,-1,np.log(.75)],[1,1,1,np.log(1.25)]),x_scale='jac')
params=fit.x;models={};metrics=[]
for i,f in enumerate(frames):
    if i==ri:models[i]=(np.eye(3),None);continue
    sp,tp,held=observations[i];H=matrix(params,i);delta=tp-project(sp,H)
    base_error=np.linalg.norm(delta[held],axis=1);best=None;best_error=base_error
    for degree in [2,3]:
        B=basis(sp,degree);weight=(~held).astype(float)
        for _ in range(4):
            coef=np.linalg.lstsq(B*np.sqrt(weight[:,None]),delta*np.sqrt(weight[:,None]),rcond=None)[0]
            error=np.linalg.norm(B@coef-delta,axis=1);scale=max(.15,1.4826*np.median(abs(error[~held]-np.median(error[~held]))))
            weight=(~held)*np.minimum(1,2.5*scale/np.maximum(error,1e-8))
        candidate=np.linalg.norm((B@coef-delta)[held],axis=1)
        if np.quantile(candidate,.95)<np.quantile(best_error,.95)*.9:best=degree;best_error=candidate
    # Refit the chosen smooth residual field with all accepted correspondences.
    coef=None
    if best:
        B=basis(sp,best);weight=np.ones(len(sp))
        for _ in range(4):
            coef=np.linalg.lstsq(B*np.sqrt(weight[:,None]),delta*np.sqrt(weight[:,None]),rcond=None)[0]
            err=np.linalg.norm(B@coef-delta,axis=1);scale=max(.15,1.4826*np.median(abs(err-np.median(err))))
            weight=np.minimum(1,2.5*scale/np.maximum(err,1e-8))
    models[i]=(H,coef)
    metrics.append({'frame':i,'file':Path(f['metadata']['path']).name,'refined_matches':len(sp),'heldout_matches':int(held.sum()),
        'physical_only_heldout_p95_px':float(np.quantile(base_error,.95)),'selected_residual_degree':best,
        'heldout_median_px':float(np.median(best_error)),'heldout_p95_px':float(np.quantile(best_error,.95))})
    print('alignment',metrics[-1],flush=True)
def inverse(target,i):
    H,coef=models[i];inv=np.linalg.inv(H);q=project(target,inv)
    if coef is not None:
        for _ in range(5):q=project(target-basis(q,2 if len(coef)==6 else 3)@coef,inv)
    return q
xx,yy=np.meshgrid(np.linspace(4,w-5,31),np.linspace(4,h-5,23));grid=np.column_stack([xx.ravel(),yy.ravel()]);roundtrips=[];jacobians=[]
for i,(H,coef) in models.items():
    def forward(p):return project(p,H)+(0 if coef is None else basis(p,2 if len(coef)==6 else 3)@coef)
    q=inverse(grid,i);roundtrips.append(float(np.max(np.linalg.norm(forward(q)-grid,axis=1))))
    dx=(forward(grid+[.01,0])-forward(grid))/.01;dy=(forward(grid+[0,.01])-forward(grid))/.01
    jacobians.append(float(np.min(dx[:,0]*dy[:,1]-dx[:,1]*dy[:,0])))
report={'width':w,'height':h,'frames':5,'reference':frames[ri]['metadata']['path'],'lens':j['lensModel'],'exif_focal_mm':frames[ri]['metadata']['focalLength'],
 'exif_focal35_mm':j['focal35'],'nominal_focal_pixels':f0,'fitted_effective_focal_pixels':float(f0*np.exp(params[3])),
 'nominal_horizontal_fov_degrees':float(np.degrees(2*np.arctan(w/(2*f0)))),
 'angular_velocity_rad_per_second':(params[:3]/1000).tolist(),'angular_speed_arcsec_per_second':float(np.linalg.norm(params[:3])/1000*180/np.pi*3600),
 'exposure_seconds':frames[ri]['metadata']['exposure'],'time_offsets_seconds':(dts*1000).tolist(),
 'geometry':'EXIF focal prior and actual midpoint times drive shared pinhole ray rotation; smooth residual selected by withheld star errors; native-pixel centroid refinement',
 'alignment':metrics,'sampled_inverse_max_error_px':max(roundtrips),'sampled_min_jacobian':min(jacobians),
 'models':{str(i):{'H':H.tolist(),'residual':None if coef is None else coef.tolist()} for i,(H,coef) in models.items()},
 'geometry_seconds':time.perf_counter()-start}
(r/'geometry.json').write_text(json.dumps(report,indent=2))
assert max(roundtrips)<.01 and min(jacobians)>.5
assert max(m['heldout_p95_px'] for m in metrics)<.8,'Native-pixel alignment not yet good enough'
if a.geometry_only:raise SystemExit()

# Refine the existing AI mask as in the app; work on native-resolution guide.
# Class probability is not optical opacity: confident sky must receive the
# complete sky mean, including darker corners with probabilities below 0.98.
prob=np.clip((smallmask(ri)-.2)/.6,0,1);prob=prob*prob*(3-2*prob)
mask=cv2.resize(prob,(w,h),interpolation=cv2.INTER_LINEAR)
guide=srgb(np.clip(np.asarray(ref[:,:,2]),0,1)).astype(np.float32);radius=max(1,round(w*20/3000));ks=(radius*2+1,)*2
def box(a):return cv2.boxFilter(a,-1,ks,borderType=cv2.BORDER_REPLICATE)
mi,mp=box(guide),box(mask);variance=np.maximum(0,box(guide*guide)-mi*mi)
co=(box(guide*mask)-mi*mp)/(variance+.01);offset=mp-co*mi
mask=srgb(np.clip(box(co)*guide+box(offset),0,1)).astype(np.float32);mask[mask<.001]=0;mask[mask>.999]=1
np.save(r/'sky-mask-fullres.npy',mask);del guide,mi,mp,variance,co,offset

# Ground motion is checked independently using the dark terrain, not the stars.
scale=1600/w;gw,gh=1600,round(h*scale);ground_mask=(cv2.resize(mask,(gw,gh))<.01).astype('uint8')*255
def ground_proxy(image):
    g=cv2.resize(np.asarray(image),(gw,gh))[:,:,:3]@np.array([.2126,.7152,.0722],np.float32)
    return np.log1p(np.maximum(g,0)*1000).astype(np.float32)
template=ground_proxy(ref);ground_maps={ri:np.zeros(2)};ground_info=[]
for i in range(5):
    if i==ri:continue
    try:
        proxy=ground_proxy(src(i))
        score,warp=cv2.findTransformECC(template,proxy,np.eye(2,3,dtype=np.float32),cv2.MOTION_TRANSLATION,
            (cv2.TERM_CRITERIA_COUNT|cv2.TERM_CRITERIA_EPS,100,1e-5),ground_mask,5)
        reverse_score,reverse=cv2.findTransformECC(proxy,template,np.eye(2,3,dtype=np.float32),cv2.MOTION_TRANSLATION,
            (cv2.TERM_CRITERIA_COUNT|cv2.TERM_CRITERIA_EPS,100,1e-5),ground_mask,5)
        shift=warp[:,2]/scale;roundtrip=float(np.linalg.norm(warp[:,2]+reverse[:,2])/scale)
        accepted=min(score,reverse_score)>.5 and roundtrip<.25 and np.linalg.norm(shift)<8
        if accepted:ground_maps[i]=shift
        ground_info.append({'frame':i,'correlation':score,'reverse_correlation':reverse_score,'roundtrip_native_pixels':roundtrip,'source_offset_pixels':shift.tolist(),'used_for_ground':bool(accepted)})
    except cv2.error as e:ground_info.append({'frame':i,'used_for_ground':False,'reason':'ECC did not converge'})
report['ground_alignment']=ground_info;report['ground_frames']=len(ground_maps)
if len(ground_maps)<3:ground_maps={ri:np.zeros(2)};report['ground_frames']=1;report['ground_fallback']='Reference only: insufficient confident terrain matches'
print('ground',ground_info,flush=True)
sources=[src(i) for i in range(5)]
# A separate spatial safety margin protects the skyline. Confidence alone
# should not make otherwise clear sky corners fall back to the noisy reference.
kernel=np.ones((7,7),np.uint8)
source_skies=[cv2.erode((smallmask(i)>.8).astype(np.float32),kernel) for i in range(5)]
source_grounds=[cv2.erode((smallmask(i)<.2).astype(np.float32),kernel) for i in range(5)]
output=np.lib.format.open_memmap(r/'mean-fullres-linear.npy',mode='w+',dtype='<f4',shape=(h,w,3))
coverage=np.lib.format.open_memmap(r/'sky-coverage.npy',mode='w+',dtype='uint8',shape=(h,w))
render_start=time.perf_counter()
for y0 in range(0,h,128):
    y1=min(h,y0+128);rows=y1-y0;xx,yy=np.meshgrid(np.arange(w),np.arange(y0,y1));target=np.column_stack([xx.ravel(),yy.ravel()])
    sky_sum=np.zeros((rows,w,3),np.float32);sky_count=np.zeros((rows,w),np.float32);ground_sum=sky_sum.copy();ground_count=sky_count.copy()
    for i,source in enumerate(sources):
        if i==ri:
            warped=np.asarray(source[y0:y1,:,:3]);valid=mask[y0:y1]>.001
        else:
            q=inverse(target,i);mx=q[:,0].reshape(rows,w).astype(np.float32);my=q[:,1].reshape(rows,w).astype(np.float32)
            # Lanczos preserves more measured star detail than bilinear; float
            # undershoots remain in the linear output instead of clipping them.
            warped=cv2.remap(source,mx,my,cv2.INTER_LANCZOS4,borderMode=cv2.BORDER_CONSTANT)[:,:,:3]
            sm=cv2.remap(source_skies[i],(mx+.5)*(aw/w)-.5,(my+.5)*(aw/w)-.5,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
            valid=(mx>=4)&(my>=4)&(mx<w-5)&(my<h-5)&(sm>.999)
        sky_sum+=warped*valid[:,:,None];sky_count+=valid
        if i in ground_maps:
            shift=ground_maps[i]
            if i==ri:ground=np.asarray(source[y0:y1,:,:3]);gv=np.ones((rows,w),bool)
            else:
                mx=(xx+shift[0]).astype(np.float32);my=(yy+shift[1]).astype(np.float32)
                ground=cv2.remap(source,mx,my,cv2.INTER_LANCZOS4,borderMode=cv2.BORDER_CONSTANT)[:,:,:3]
                sm=cv2.remap(source_grounds[i],(mx+.5)*(aw/w)-.5,(my+.5)*(aw/w)-.5,cv2.INTER_LINEAR,borderMode=cv2.BORDER_CONSTANT)
                gv=(mx>=4)&(my>=4)&(mx<w-5)&(my<h-5)&(sm>.999)
            ground_sum+=ground*gv[:,:,None];ground_count+=gv
    sky=sky_sum/np.maximum(sky_count,1)[:,:,None];ground=ground_sum/np.maximum(ground_count,1)[:,:,None]
    sky[sky_count<3]=ref[y0:y1,:,:3][sky_count<3];ground[ground_count<3]=ref[y0:y1,:,:3][ground_count<3]
    alpha=mask[y0:y1,:,None];output[y0:y1]=sky*alpha+ground*(1-alpha);coverage[y0:y1]=sky_count.astype('uint8')
    if y0%512==0:print('mean rows',y1,'/',h,flush=True)
output.flush();coverage.flush();report['render_seconds']=time.perf_counter()-render_start
report['fusion']='equal-weight arithmetic mean, no pixel rejection; sky and ground transforms independent; <3 valid contributions fall back to reference'
report['mask_policy']='Existing AI probabilities: sky >0.8, ground <0.2, 3 analysis-pixel erosion for source validity; reference smoothstep 0.2–0.8 then guided edge refinement'
report['sky_five_frame_coverage_fraction']=float((coverage[mask>.99]==5).mean())
assert np.isfinite(output).all()
# Full-resolution deliveries, with identical rendering for reference and mean.
icc=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
for name,array in [('reference',ref[:,:,:3]),('mean',output)]:
    tifffile.imwrite(r/(name+'-fullres-linear.tiff'),array,photometric='rgb',metadata={'color_space':'extended linear sRGB','exposure_adjustment_ev':0})
    display=np.empty((h,w,3),np.uint16)
    for y0 in range(0,h,256):display[y0:y0+256]=np.round(srgb(np.clip(array[y0:y0+256],0,1))*65535).astype('uint16')
    tifffile.imwrite(r/(name+'-fullres-srgb16.tiff'),display,photometric='rgb',metadata=None,extratags=[(34675,'B',len(icc),icc,False)])
    path=r/(name+'-fullres.png');assert cv2.imwrite(str(path),display[:,:,::-1],[cv2.IMWRITE_PNG_COMPRESSION,3])
    data=path.read_bytes();payload=b'sRGB'+bytes([0]);chunk=struct.pack('>I',1)+payload+struct.pack('>I',zlib.crc32(payload)&0xffffffff)
    path.write_bytes(data[:33]+chunk+data[33:]);del display
report['output']={'resolution':[w,h],'display':'same 0 EV linear-to-sRGB, no sharpening or learned denoise','formats':['32-bit linear RGB TIFF','16-bit sRGB TIFF with ICC','16-bit full-resolution PNG with sRGB chunk']}
(r/'result.json').write_text(json.dumps(report,indent=2))
print('FULL RESOLUTION OUTPUTS READY',r,flush=True)
