#!/usr/bin/env python3
"""Independent numeric checks on Float32 outputs. Requires numpy; not used by the Swift tool."""
import json
import sys
from pathlib import Path
import numpy as np

root = Path(sys.argv[1])
report = json.loads((root / 'report.json').read_text())
w, h = report['width'], report['height']

def read(name):
    return np.fromfile(root / name, dtype='<f4').reshape(h, w, 4)

reference, clean, retained = [read(n + '.rgba') for n in ('reference', 'stack-clean', 'stack-meteors')]
mask = np.fromfile(root / 'sky-mask.f32', dtype='<f4').reshape(h, w)
ground = mask == 0
sky = mask > .999
ref_index = next(i for i, f in enumerate(report['frames']) if f['metadata']['path'] == report['reference'])
stars = report['frames'][ref_index]['stars']
yy, xx = np.mgrid[:h, :w]
for s in stars:
    x, y = s['point']['x'], s['point']['y']
    x0, x1 = max(0, int(x)-8), min(w, int(x)+9)
    y0, y1 = max(0, int(y)-8), min(h, int(y)+9)
    sky[y0:y1, x0:x1] = False
# Avoid silhouette, borders and very bright lower-sky gradients in noise measurement.
sky[:20] = False
sky[int(h*.65):] = False
sky[:, :20] = False
sky[:, -20:] = False

def luma(a):
    return a[..., :3] @ np.array([.2126, .7152, .0722])

def highpass(a):
    # Zero-sum Laplacian; divide by its white-noise gain. This is a local
    # high-frequency statistic, not a claim of independent-pixel SNR after resampling.
    return (4*a - np.roll(a,1,0)-np.roll(a,-1,0)-np.roll(a,1,1)-np.roll(a,-1,1)) / np.sqrt(20)

def sigma(a):
    v=highpass(luma(a))[sky]
    return float(np.median(np.abs(v-np.median(v)))*1.4826)

errors = [f['alignment']['validationP95Error'] for f in report['frames'] if f.get('alignment') and f['metadata']['path'] != report['reference']]
metrics = {
    'frames':len(report['frames']),
    'aligned':sum(bool(f.get('alignment')) for f in report['frames']),
    'morph_used':sum(bool((f.get('alignment') or {}).get('morph')) for f in report['frames']),
    'median_frame_heldout_p95_px':float(np.median(errors)),
    'worst_frame_heldout_p95_px':float(max(errors)),
    'ground_max_abs_change':float(np.abs(reference[ground]-retained[ground]).max()),
    'reference_sky_high_frequency_sigma':sigma(reference),
    'stack_sky_high_frequency_sigma':sigma(clean),
    'noise_statistic_reduction':sigma(reference)/sigma(clean),
    'streak_candidates':len(report['streaks']),
    'selected_candidates':sum(s.get('selected',False) for s in report['streaks']),
    'persistent_track_candidates':sum(s.get('persistentTrack',False) for s in report['streaks']),
    'finite_outputs':bool(np.isfinite(clean).all() and np.isfinite(retained).all()),
    'temporal_motion':report.get('temporalMotion'),
}

# Aperture flux and second-moment width against the exact reference, on unsaturated isolated stars.
flux_ratios=[]
width_ratios=[]
for s in stars:
    x,y=s['point']['x'],s['point']['y']; ix,iy=round(x),round(y)
    if not(10<ix<w-10 and 10<iy<h-10 and mask[iy,ix]>.999 and iy<h*.7):continue
    if s['peak']>.9:continue
    if any(t is not s and np.hypot(t['point']['x']-x,t['point']['y']-y)<14 for t in stars):continue
    dx,dy=xx[iy-7:iy+8,ix-7:ix+8]-x,yy[iy-7:iy+8,ix-7:ix+8]-y
    r2=dx*dx+dy*dy; core=r2<16; ring=(r2>25)&(r2<49)
    stats=[]
    for a in (reference,clean):
        p=luma(a[iy-7:iy+8,ix-7:ix+8]);signal=p-np.median(p[ring]);flux=signal[core].sum()
        positive=np.maximum(signal,0)*core
        radius=np.sqrt((positive*r2).sum()/max(1e-12,positive.sum()))
        stats.append((flux,radius))
    if stats[0][0]>.005 and stats[1][0]>0:
        flux_ratios.append(stats[1][0]/stats[0][0]);width_ratios.append(stats[1][1]/stats[0][1])
metrics['star_aperture_sample_count']=len(flux_ratios)
metrics['median_star_flux_ratio']=float(np.median(flux_ratios)) if flux_ratios else None
metrics['median_star_radius_ratio']=float(np.median(width_ratios)) if width_ratios else None

# Independently evaluate sampled forward Jacobians and the five-step inverse used
# by the renderer. This checks this run's warps, not arbitrary unseen inputs.
gx,gy=np.meshgrid(np.linspace(0,w-1,33),np.linspace(0,h-1,23))
grid=np.column_stack((gx.ravel(),gy.ravel()))
minimum_det=float('inf');maximum_roundtrip=0.0;maximum_usable_roundtrip=0.0
grid_sky=mask[grid[:,1].astype(int),grid[:,0].astype(int)]>.001
for f in report['frames']:
    a=f.get('alignment')
    if not a:continue
    matrix=np.asarray(a['transform']['m']).reshape(3,3)
    inverse=np.linalg.inv(matrix)
    def project(points,m):
        q=np.column_stack((points,np.ones(len(points)))) @ m.T
        return q[:,:2]/q[:,2:]
    def displacement(points):
        field=a.get('morph')
        if not field:return np.zeros_like(points)
        u,v=((points+field.get('inputOffset',0))/field['scale']-np.array([.5,.35])).T
        basis=np.column_stack((np.ones(len(u)),u,v,u*u,u*v,v*v,u**3,u*u*v,u*v*v,v**3))
        return basis @ np.column_stack((field['x'],field['y']))
    def forward(points):return project(points,matrix)+displacement(points)
    q=forward(grid);epsilon=.001
    dx=(forward(grid+[epsilon,0])-q)/epsilon
    dy=(forward(grid+[0,epsilon])-q)/epsilon
    minimum_det=min(minimum_det,float(np.min(dx[:,0]*dy[:,1]-dx[:,1]*dy[:,0])))
    p=project(grid,inverse)
    for _ in range(5):p=project(grid-displacement(p),inverse)
    error=np.linalg.norm(forward(p)-grid,axis=1)
    maximum_roundtrip=max(maximum_roundtrip,float(error.max()))
    # The renderer never uses targets outside the sky mask or sources outside
    # the image. Report extrapolated corners separately rather than hiding them.
    usable=grid_sky & (p[:,0]>=0) & (p[:,0]<w-1) & (p[:,1]>=0) & (p[:,1]<h-1)
    maximum_usable_roundtrip=max(maximum_usable_roundtrip,float(error[usable].max()))
metrics['sampled_warp_minimum_jacobian_determinant']=minimum_det
metrics['sampled_inverse_maximum_roundtrip_px']=maximum_roundtrip
metrics['sampled_usable_sky_inverse_maximum_roundtrip_px']=maximum_usable_roundtrip

metrics['meteor_candidates']=[]
for s in report['streaks']:
    f=report['frames'][s['frameIndex']]
    if Path(f['metadata']['path']).name != 'DSC00025.ARW':continue
    a,b=s['start'],s['end'];dx,dy=b['x']-a['x'],b['y']-a['y'];length=np.hypot(dx,dy)
    if length<w*.08:continue
    t=np.clip(((xx-a['x'])*dx+(yy-a['y'])*dy)/(length*length),0,1)
    distance=np.hypot(xx-a['x']-t*dx,yy-a['y']-t*dy)
    region=(distance<max(2,s['width']*1.5)) & (mask>.98)
    source=np.fromfile(f['cache'],dtype='<f4').reshape(h,w,4)
    original=float((luma(source)-luma(clean))[region].sum())
    recovered=float((luma(retained)-luma(clean))[region].sum())
    metrics['meteor_candidates'].append({'file':Path(f['metadata']['path']).name,'length_px':float(length),'residual_flux_retention':recovered/original if original else None})

(root/'metrics.json').write_text(json.dumps(metrics,indent=2)+'\n')
print(json.dumps(metrics,indent=2))
assert metrics['finite_outputs']
assert metrics['ground_max_abs_change']==0
assert minimum_det>0, 'Sampled warp folds'
assert maximum_usable_roundtrip<.01, 'Sampled usable-sky inverse does not converge'
