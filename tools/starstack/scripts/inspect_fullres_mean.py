"""Inspect native-pixel mean outputs; emit 1:1 crops, never resized images."""
import json,sys
from pathlib import Path
import numpy as np,cv2,tifffile
from PIL import Image,ImageDraw,ImageFont
r=Path(sys.argv[1]);j=json.loads((r/'manifest.json').read_text());report=json.loads((r/'result.json').read_text())
w,h=j['width'],j['height'];ri=j['referenceIndex'];ref=np.memmap(r/j['frames'][ri]['cache'],dtype='<f4',mode='r',shape=(h,w,4))
mean=np.load(r/'mean-fullres-linear.npy',mmap_mode='r');mask=np.load(r/'sky-mask-fullres.npy',mmap_mode='r');coverage=np.load(r/'sky-coverage.npy',mmap_mode='r')
def lum(a):return a[...,:3]@np.array([.2126,.7152,.0722])
def srgb(a):
 a=np.clip(a,0,1);return np.where(a<=.0031308,a*12.92,1.055*a**(1/2.4)-.055)
def display(a,ev=0):return Image.fromarray(np.round(srgb(a[...,:3]*(2**ev))*255).astype('uint8'))
rng=np.random.default_rng(29);x=rng.integers(20,w-20,200000);y=rng.integers(20,h-20,200000)
sky=(mask[y,x]>.999)&(coverage[y,x]==5);ground=mask[y,x]<.001
def hp(a):return (4*lum(a[y,x])-lum(a[y-1,x])-lum(a[y+1,x])-lum(a[y,x-1])-lum(a[y,x+1]))/np.sqrt(20)
def mad(v):return float(np.median(abs(v-np.median(v)))*1.4826)
rh,mh=hp(ref),hp(mean);metrics={'resolution':[w,h],'sky_noise_statistic_reference':mad(rh[sky]),'sky_noise_statistic_mean':mad(mh[sky]),
 'sky_high_frequency_reduction':mad(rh[sky])/mad(mh[sky]),'ground_high_frequency_reduction':mad(rh[ground])/mad(mh[ground]),
 'noise_statistic_note':'Sampled Laplacian MAD; resampling creates correlation. Not independent-pixel SNR or a star-completeness measurement.'}

# Same measured apertures in reference and mean, with local background rings.
stars=j['frames'][ri]['stars'];points=np.array([[(s['point']['x']+.5)*w/j['analysisWidth']-.5,(s['point']['y']+.5)*w/j['analysisWidth']-.5] for s in stars])
ratios=[];widths=[]
for i,(x,y) in enumerate(points):
 ix,iy=round(x),round(y)
 if not(20<ix<w-20 and 20<iy<h-20 and mask[iy,ix]>.999 and coverage[iy,ix]==5):continue
 if np.sum(np.linalg.norm(points-[x,y],axis=1)<35)>1:continue
 yy,xx=np.mgrid[iy-18:iy+19,ix-18:ix+19];rr=(xx-x)**2+(yy-y)**2;core=rr<9**2;ring=(rr>12**2)&(rr<18**2);stats=[]
 for image in [ref,mean]:
  v=lum(image[iy-18:iy+19,ix-18:ix+19]);v-=np.median(v[ring]);flux=v[core].sum();positive=np.maximum(v,0)*core
  stats.append((flux,np.sqrt((positive*rr).sum()/max(1e-12,positive.sum()))))
 if stats[0][0]>.05 and stats[1][0]>0:ratios.append(stats[1][0]/stats[0][0]);widths.append(stats[1][1]/stats[0][1])
metrics.update({'star_aperture_count':len(ratios),'median_star_flux_ratio':float(np.median(ratios)),'star_flux_ratio_p10_p90':np.quantile(ratios,[.1,.9]).tolist(),
 'median_star_radius_ratio':float(np.median(widths)),'star_note':'Isolated registration stars; not an unsaturated-only or faint-star completeness benchmark. No sensor saturation inference from developed RGB >1.'})
for name in ['reference','mean']:
 with tifffile.TiffFile(r/(name+'-fullres-srgb16.tiff')) as t:
  assert t.pages[0].shape==(h,w,3) and t.pages[0].dtype==np.uint16 and 34675 in t.pages[0].tags
 with tifffile.TiffFile(r/(name+'-fullres-linear.tiff')) as t:assert t.pages[0].shape==(h,w,3) and t.pages[0].dtype==np.float32
 im=cv2.imread(str(r/(name+'-fullres.png')),cv2.IMREAD_UNCHANGED);assert im.shape==(h,w,3) and im.dtype==np.uint16
 for yy0,xx0 in [(100,100),(h//3,w//2),(h-100,w-100)]:
  original=ref[yy0,xx0,:3] if name=='reference' else mean[yy0,xx0]
  expected=np.round(srgb(original)*65535).astype('uint16');assert np.array_equal(im[yy0,xx0,::-1],expected)
 del im
metrics['native_dimensions_bit_depth_and_sampled_display_values_verified']=True
(r/'quality.json').write_text(json.dumps(metrics,indent=2)+'\n');print(json.dumps(metrics,indent=2),flush=True)
try:font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',20)
except OSError:font=ImageFont.load_default(size=20)
# Exact source pixels: crop only. 2x800 columns, each crop is 800x600 at 1:1.
regions=[('Central stars / Milky Way',int(w*.45),int(h*.24),0),('Outer field',int(w*.10),int(h*.10),0),('Terrain, +3 EV inspection',int(w*.68),int(h*.82),3)]
for index,(title,x,y,ev) in enumerate(regions):
 x=min(x,w-800);y=min(y,h-600);canvas=Image.new('RGB',(1600,650),'#16191d');d=ImageDraw.Draw(canvas)
 for col,(name,array) in enumerate([('Single reference',ref),('Five-frame mean',mean)]):
  canvas.paste(display(array[y:y+600,x:x+800],ev),(col*800,50));d.text((col*800+12,12),f'{name} • {title} • 100%',font=font,fill='white')
 canvas.save(r/f'crop-{index+1}-100percent.png')
