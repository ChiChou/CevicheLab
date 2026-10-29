#!/usr/bin/env python3
# Algorithm reference: Benedikt Bitterli, Star Stacker: Astrophotography with C++11.
# https://benedikt-bitterli.me/astro/ — independently implemented; no upstream code copied.
# See ../../../THIRD_PARTY_NOTICES.md for scope and differences.
"""Joint multi-frame camera/stellar fit for the existing five-frame RAW caches."""
import argparse,json,time
from pathlib import Path
import numpy as np
from scipy.optimize import least_squares
from scipy.sparse import lil_matrix
from scipy.spatial.transform import Rotation

def save(p,j):p.write_text(json.dumps(j,indent=2,allow_nan=False)+'\n')
def psf(image,point):
    x,y=point;ix,iy=round(x),round(y);r=12
    if min(ix,iy)<r or ix+r>=image.shape[1] or iy+r>=image.shape[0]:return None
    patch=np.asarray(image[iy-r:iy+r+1,ix-r:ix+r+1,:3])@np.array([.2126,.7152,.0722])
    yy,xx=np.mgrid[-r:r+1,-r:r+1];outer=xx*xx+yy*yy>90
    plane=np.linalg.lstsq(np.column_stack([np.ones(outer.sum()),xx[outer],yy[outer]]),patch[outer],rcond=None)[0]
    signal=patch-plane[0]-plane[1]*xx-plane[2]*yy
    noise=max(1e-6,1.4826*np.median(abs(signal[outer]-np.median(signal[outer]))))
    peak=signal.max()
    if peak<8*noise:return None
    # Elliptical Gaussian plus local plane; robust residuals limit neighboring
    # stars. No fitting mask or positive-only rule is applied to output pixels.
    z=signal/peak
    def fun(a):
        dx=xx-a[1];dy=yy-a[2];sx=np.exp(a[3]);sy=np.exp(a[4]);rho=a[5]
        e=(dx*dx/sx**2+dy*dy/sy**2-2*rho*dx*dy/(sx*sy))/(2*(1-rho*rho))
        return (a[0]*np.exp(-e)+a[6]+a[7]*xx+a[8]*yy-z).ravel()
    fit=least_squares(fun,[1,x-ix,y-iy,np.log(2),np.log(2),0,0,0,0],
        bounds=([0,x-ix-4,y-iy-4,np.log(.65),np.log(.65),-.85,-1,-.1,-.1],
                [4,x-ix+4,y-iy+4,np.log(7),np.log(7),.85,1,.1,.1]),
        loss='soft_l1',f_scale=max(.02,3*noise/peak),max_nfev=35)
    center=fit.x[1:3]+[ix,iy]
    if not fit.success or np.linalg.norm(center-point)>3.8:return None
    return center

def distort(p,k):
    r2=np.sum(p*p,axis=-1);return p*(1+k[0]*r2+k[1]*r2*r2)[...,None]
def undistort(p,k):
    q=p.copy()
    for _ in range(10):
        r2=np.sum(q*q,axis=-1);q=p/(1+k[0]*r2+k[1]*r2*r2)[...,None]
    return q
def map_points(points, f, k, rot, center):
    q=undistort((points-center)/f,k);rays=np.column_stack([q,np.ones(len(q))])@Rotation.from_rotvec(rot).as_matrix().T
    return distort(rays[:,:2]/rays[:,2,None],k)*f+center

def main():
    p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    a.output.mkdir(parents=True,exist_ok=True);j=json.loads((a.input/'manifest.json').read_text());old=json.loads((a.input/'geometry.json').read_text())
    w,h=j['width'],j['height'];ri=j['referenceIndex'];scale=w/j['analysisWidth'];center=np.array([(w-1)/2,(h-1)/2]);f0=w*j['focal35']/36
    images=[np.memmap(a.input/f['cache'],'<f4',mode='r',shape=(h,w,4)) for f in j['frames']]
    tick=time.perf_counter();trackfile=a.output/'tracks.npz'
    if trackfile.exists():
        t=np.load(trackfile);obs=t['observations'];ids=t['frame_ids'];tracks=t['track_ids'];initial=t['initial']
    else:
        matches={};reference_points={}
        for i,frame in enumerate(j['frames']):
            if i==ri:continue
            for pair in frame['alignment']['matches']:
                key=(pair['reference']['x'],pair['reference']['y']);reference_points[key]=(np.array(key)+.5)*scale-.5
                matches.setdefault(key,{})[i]=(np.array([pair['source']['x'],pair['source']['y']])+.5)*scale-.5
        obs=[];ids=[];tracks=[];initial=[]
        for n,key in enumerate(sorted(matches,key=lambda k:(k[1],k[0]))):
            ref=psf(images[ri],reference_points[key])
            if ref is None:continue
            samples={ri:ref}
            for i,point in matches[key].items():
                fitted=psf(images[i],point)
                if fitted is not None:samples[i]=fitted
            if len(samples)<3:continue
            tid=len(initial);initial.append(ref)
            for i,point in samples.items():obs.append(point);ids.append(i);tracks.append(tid)
            if n%100==0:print('PSF tracks',n,len(initial),flush=True)
        obs=np.asarray(obs);ids=np.asarray(ids);tracks=np.asarray(tracks);initial=np.asarray(initial)
        np.savez(trackfile,observations=obs,frame_ids=ids,track_ids=tracks,initial=initial)
    held=np.arange(len(initial))%5==0;train_ids=np.flatnonzero(~held);index=np.full(len(initial),-1);index[train_ids]=np.arange(len(train_ids))
    chosen=~held[tracks];train_obs=obs[chosen];frame_ids=ids[chosen];track_ids=index[tracks[chosen]]
    nonref=[i for i in range(5) if i!=ri];slots={i:n for n,i in enumerate(nonref)}
    fstart=old['fitted_effective_focal_pixels'];K=np.array([[fstart,0,center[0]],[0,fstart,center[1]],[0,0,1.]])
    rotations=[]
    for i in nonref:
        H=np.array(old['models'][str(i)]['H']);matrix=np.linalg.inv(K)@H@K
        rotations.append(Rotation.from_matrix(matrix).inv().as_rotvec())
    rotations=np.array(rotations)
    def predict(par,points,frame):
        if frame==ri:return points
        return map_points(points,f0*np.exp(par[0]),par[1:3],par[3+3*slots[frame]:6+3*slots[frame]],center)
    count=len(train_ids);ng=15
    start=np.r_[np.log(fstart/f0),0,0,rotations.ravel(),((initial[train_ids]-center)/f0).ravel()]
    def residual(par):
        latent=par[ng:].reshape(-1,2)*f0+center;pred=np.empty_like(train_obs)
        for i in range(5):
            sel=frame_ids==i;pred[sel]=predict(par,latent[track_ids[sel]],i)
        # EXIF focal prior and a weak time-informed rotation prior keep short
        # sequences from unconstrained intrinsic/camera-motion drift.
        priors=np.r_[par[0]/.15,par[1]/.2,par[2]/.2,(par[3:15]-rotations.ravel())/.003]
        return np.r_[(pred-train_obs).ravel(),priors]
    sparsity=lil_matrix((2*len(train_obs)+ng,ng+2*count),dtype=int)
    for n,(i,t) in enumerate(zip(frame_ids,track_ids)):
        if i!=ri:
            sparsity[2*n:2*n+2,:3]=1;sparsity[2*n:2*n+2,3+3*slots[i]:6+3*slots[i]]=1
        sparsity[2*n:2*n+2,ng+2*t:ng+2*t+2]=1
    sparsity[-ng:,:ng]=np.eye(ng,dtype=int)
    lower=np.full(len(start),-np.inf);upper=-lower
    lower[:3]=[np.log(.75),-.25,-.15];upper[:3]=[np.log(1.25),.25,.15]
    print('Joint fit',count,'training tracks',int(held.sum()),'held-out tracks',flush=True)
    fit=least_squares(residual,start,jac_sparsity=sparsity.tocsr(),bounds=(lower,upper),
        loss='soft_l1',f_scale=.5,x_scale='jac',max_nfev=120,ftol=1e-7,xtol=1e-7)
    par=fit.x[:ng];f=f0*np.exp(par[0]);print('Global fit',fit.message,'focal',f,'distortion',par[1:3],flush=True)
    models={};metrics=[]
    # An empirical residual is retained only if a separate validation split
    # improves; final untouched tracks report performance after that selection.
    def basis(p):
        u,v=((p-center)/w).T;return np.column_stack([u*0+1,u,v,u*u,u*v,v*v])
    selection=(np.arange(len(initial))%5==1)
    for i in range(5):
        rot=np.zeros(3) if i==ri else par[3+3*slots[i]:6+3*slots[i]]
        if i==ri:models[str(i)]={'rotation':rot.tolist(),'residual':None};continue
        rows=np.flatnonzero(ids==i);tid=tracks[rows];src=initial[tid];dst=obs[rows]
        delta=dst-map_points(src,f,par[1:3],rot,center);B=basis(src)
        train=~held[tid]&~selection[tid];valid=selection[tid];test=held[tid]
        weights=train.astype(float)
        for _ in range(5):
            coeff=np.linalg.lstsq(B*np.sqrt(weights[:,None]),delta*np.sqrt(weights[:,None]),rcond=None)[0]
            err=np.linalg.norm(delta-B@coeff,axis=1);weights=train*np.minimum(1,.5/np.maximum(err,1e-9))
        use=np.quantile(np.linalg.norm((delta-B@coeff)[valid],axis=1),.95)<.9*np.quantile(np.linalg.norm(delta[valid],axis=1),.95)
        # Refit correction with training + selection tracks, never final holdout.
        if use:
            train=~test;weights=train.astype(float)
            for _ in range(5):
                coeff=np.linalg.lstsq(B*np.sqrt(weights[:,None]),delta*np.sqrt(weights[:,None]),rcond=None)[0]
                err=np.linalg.norm(delta-B@coeff,axis=1);weights=train*np.minimum(1,.5/np.maximum(err,1e-9))
        else:coeff=None
        error=np.linalg.norm((delta-(0 if coeff is None else B@coeff))[test],axis=1)
        metrics.append(dict(frame=i,heldout_stars=int(test.sum()),median_px=float(np.median(error)),p95_px=float(np.quantile(error,.95)),
                            physical_only_p95_px=float(np.quantile(np.linalg.norm(delta[test],axis=1),.95)),residual_selected=bool(use)))
        models[str(i)]={'rotation':rot.tolist(),'residual':None if coeff is None else coeff.tolist()}
    result=dict(width=w,height=h,reference_index=ri,focal_pixels=float(f),nominal_focal_pixels=f0,distortion=par[1:3].tolist(),
        center=center.tolist(),models=models,validation=metrics,tracks=len(initial),observations=len(obs),fit_evaluations=fit.nfev,
        fit_success=bool(fit.success),fit_message=fit.message,seconds=time.perf_counter()-tick,
        method='Elliptical-Gaussian centroids, joint latent star positions/shared focal/radial distortion/per-frame rotations, EXIF-informed initialization and priors; independently held-out residual checks')
    save(a.output/'geometry.json',result);print(json.dumps(metrics,indent=2),flush=True)
    assert max(x['p95_px'] for x in metrics)<1,'Alignment quality gate failed'

if __name__=='__main__':main()
