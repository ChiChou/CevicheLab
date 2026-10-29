"""Compare the frozen previous mean with the joint-fit experiment at native scale."""
import argparse,json
from pathlib import Path
import numpy as np,tifffile
from PIL import Image,ImageCms,ImageDraw,ImageFont

def lum(a):return a[...,:3]@np.array([.2126,.7152,.0722])
def srgb(a):
    a=np.clip(a,0,1);return np.where(a<=.0031308,a*12.92,1.055*a**(1/2.4)-.055)
def mad(v):return float(np.median(abs(v-np.median(v)))*1.4826)

def run(root,out):
    j=json.loads((root/'manifest.json').read_text());w,h=j['width'],j['height'];ri=j['referenceIndex']
    ref=np.memmap(root/j['frames'][ri]['cache'],'<f4',mode='r',shape=(h,w,4))
    old=np.load(root/'mean-fullres-linear.npy',mmap_mode='r')
    cpu=np.memmap(out/'cpu.rgba','<f4',mode='r',shape=(h,w,4));gpu=np.memmap(out/'metal.rgba','<f4',mode='r',shape=(h,w,4))
    mask=np.load(root/'sky-mask-fullres.npy',mmap_mode='r')
    old_count=np.load(root/'sky-coverage.npy',mmap_mode='r');new_count=np.load(out/'sky-count.npy',mmap_mode='r')
    ground_count=np.load(out/'ground-count.npy',mmap_mode='r')
    error_max=0.;error_squared=0.;old_squared=0.;samples=0
    for y0 in range(0,h,128):
        a=np.asarray(cpu[y0:y0+128,:,:3]);b=np.asarray(gpu[y0:y0+128,:,:3]);assert np.isfinite(a).all() and np.isfinite(b).all()
        diff=a.astype(np.float64)-b;error_max=max(error_max,float(abs(diff).max()));error_squared+=float(np.sum(diff*diff));samples+=diff.size
        delta=b.astype(np.float64)-old[y0:y0+128];old_squared+=float(np.sum(delta*delta))
    assert error_max<2e-6,('CPU/Metal disagreement',error_max)
    metrics={'resolution':[w,h],'cpu_metal_max_abs_linear_rgb':error_max,'cpu_metal_rms_linear_rgb':(error_squared/samples)**.5,
             'previous_new_rms_linear_rgb':(old_squared/samples)**.5}
    confident=mask>.999
    metrics['confident_sky_five_frame_fraction']=float(np.count_nonzero((new_count==5)&confident)/np.count_nonzero(confident))
    determinants=[]
    for i in range(5):
        maps=np.memmap(out/f'map-{i}.float4','<f4',mode='r',shape=(h,w,4))
        grid=np.asarray(maps[64:-64:128,64:-64:128,:2],dtype=float);dy,dx=np.gradient(grid,128,axis=(0,1))
        determinants.append(float(np.min(dx[:,:,0]*dy[:,:,1]-dx[:,:,1]*dy[:,:,0])))
    assert min(determinants)>0,'Sampled warp foldover'
    metrics['sampled_reference_to_source_min_jacobian_by_frame']=determinants
    rng=np.random.default_rng(29);x=rng.integers(20,w-20,200000);y=rng.integers(20,h-20,200000)
    sky=(mask[y,x]>.999)&(old_count[y,x]==5)&(new_count[y,x]==5);ground=(mask[y,x]<.001)&(ground_count[y,x]==5)
    def hp(a):return (4*lum(a[y,x])-lum(a[y-1,x])-lum(a[y+1,x])-lum(a[y,x-1])-lum(a[y,x+1]))/np.sqrt(20)
    arrays=[ref,old,gpu];names=['reference','previous','joint']
    high=[hp(a) for a in arrays]
    metrics['sky_high_frequency_mad']={name:mad(v[sky]) for name,v in zip(names,high)}
    metrics['ground_high_frequency_mad']={name:mad(v[ground]) for name,v in zip(names,high)}
    for part in ['sky','ground']:
        m=metrics[part+'_high_frequency_mad'];metrics[part+'_reduction_vs_reference']={name:m['reference']/m[name] for name in names[1:]}
        metrics[part+'_new_reduction_vs_previous']=m['previous']/m['joint']
    metrics['noise_note']='Matched pixels in all-five coverage. Laplacian MAD is a high-frequency proxy, not calibrated SNR; interpolation changes noise correlation and scene texture contributes.'
    metrics['sampled_sky_pixels']=int(sky.sum());metrics['sampled_ground_pixels']=int(ground.sum())
    points=np.array([[(s['point']['x']+.5)*w/j['analysisWidth']-.5,(s['point']['y']+.5)*h/j['analysisHeight']-.5] for s in j['frames'][ri]['stars']])
    stats=[]
    for x,y in points:
        ix,iy=round(x),round(y)
        if not(20<ix<w-20 and 20<iy<h-20 and mask[iy,ix]>.999 and old_count[iy,ix]==5 and new_count[iy,ix]==5):continue
        if np.sum(np.linalg.norm(points-[x,y],axis=1)<35)>1:continue
        yy,xx=np.mgrid[iy-18:iy+19,ix-18:ix+19];rr=(xx-x)**2+(yy-y)**2;core=rr<81;ring=(rr>144)&(rr<324);row=[]
        for a in arrays:
            v=lum(a[iy-18:iy+19,ix-18:ix+19]);v-=np.median(v[ring]);flux=v[core].sum();positive=np.maximum(v,0)*core
            row.append([flux,np.sqrt((positive*rr).sum()/max(1e-12,positive.sum()))])
        if row[0][0]>.05 and min(r[0] for r in row)>0:stats.append(row)
    stats=np.asarray(stats);metrics['star_apertures']=len(stats);metrics['stars']={}
    for i,name in enumerate(names[1:],1):
        ratios=stats[:,i,:]/stats[:,0,:]
        metrics['stars'][name]={'median_flux_vs_reference':float(np.median(ratios[:,0])),
            'flux_p10_p90':np.quantile(ratios[:,0],[.1,.9]).tolist(),'median_radius_vs_reference':float(np.median(ratios[:,1]))}
    metrics['star_note']='Same isolated registration-star apertures, radius 9 pixels, background annulus 12–18 pixels. Not an unsaturated-only or faint-star-completeness benchmark.'
    icc=ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    for name,a in [('cpu',cpu),('metal',gpu)]:
        display=np.empty((h,w,3),np.uint8)
        master=None
        if name=='metal':master=tifffile.memmap(out/'mean-fullres-srgb16.tiff',shape=(h,w,3),dtype=np.uint16,photometric='rgb',extratags=[(34675,'B',len(icc),icc,False)])
        for y0 in range(0,h,128):
            encoded=srgb(a[y0:y0+128,:,:3]);display[y0:y0+128]=np.rint(encoded*255).astype(np.uint8)
            if master is not None:master[y0:y0+128]=np.rint(encoded*65535).astype(np.uint16)
        if master is not None:master.flush();del master
        Image.fromarray(display).save(out/f'mean-{name}-fullres.jpg',quality=95,subsampling=0,icc_profile=icc)
        with Image.open(out/f'mean-{name}-fullres.jpg') as im:assert im.size==(w,h) and im.info.get('icc_profile')
        del display
    with tifffile.TiffFile(out/'mean-fullres-srgb16.tiff') as t:assert t.pages[0].shape==(h,w,3) and t.pages[0].dtype==np.uint16 and 34675 in t.pages[0].tags
    master=tifffile.memmap(out/'mean-fullres-srgb16.tiff',mode='r')
    for yy,xx in [(100,100),(h//3,w//2),(h-100,w-100)]:np.testing.assert_array_equal(master[yy,xx],np.rint(srgb(gpu[yy,xx,:3])*65535).astype(np.uint16))
    metrics['export_dimensions_icc_and_tiff_samples_verified']=True
    font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',18)
    regions=[('Milky Way',int(w*.45),int(h*.24),0),('Outer field',int(w*.10),int(h*.10),0),
             ('Terrain',int(w*.68),int(h*.82),3),('Milky Way',int(w*.45),int(h*.24),2)]
    for i,(title,x,y,ev) in enumerate(regions,1):
        x=min(x,w-800);y=min(y,h-600);canvas=Image.new('RGB',(2400,650),'#16191d');draw=ImageDraw.Draw(canvas)
        for col,(name,a) in enumerate(zip(['Single reference','Previous mean','New joint-fit mean'],arrays)):
            crop=Image.fromarray(np.rint(srgb(a[y:y+600,x:x+800,:3]*(2**ev))*255).astype(np.uint8));canvas.paste(crop,(col*800,50))
            draw.text((col*800+12,14),f'{name} | {title} | 100% | {ev:+d} EV',font=font,fill='white')
        canvas.save(out/f'comparison-{i}-100percent.jpg',quality=97,subsampling=0,icc_profile=icc)
        canvas.save(out/f'comparison-{i}-100percent.png',icc_profile=icc)
    (out/'quality.json').write_text(json.dumps(metrics,indent=2)+'\n');print(json.dumps(metrics,indent=2),flush=True)

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('input',type=Path);p.add_argument('output',type=Path);a=p.parse_args();run(a.input,a.output)
