"""Build actual-result previews; no generated/synthesized image content."""
from pathlib import Path
import json,numpy as np
from PIL import Image,ImageDraw,ImageFont
r=Path(__file__).resolve().parents[1]/'output/comparison';out=r/'previews';out.mkdir(exist_ok=True)
w,h=1600,1068
def read(path):return np.fromfile(path,dtype='<f4').reshape(h,w,4)[...,:3]
def display(rgb):
    rgb=np.clip(np.nan_to_num(rgb),0,1);s=np.where(rgb<=.0031308,rgb*12.92,1.055*rgb**(1/2.4)-.055)
    return Image.fromarray(np.round(s*255).astype('uint8'))
ref=read(r/'input1600/0010_DSC00025.rgba');native=read(r/'native-metal/stack-meteors.rgba')
clean=read(r/'native-metal/stack-clean.rgba')
images={'reference':display(ref),'native-metal':display(native),
        'seiza':display(np.load(r/'seiza/foreground-adapter.npy')),'astroalign':display(np.load(r/'astroalign/foreground-adapter.npy'))}
for name,im in images.items():
    copy=im.copy();copy.thumbnail((1280,1280));copy.save(out/(name+'-1280.png'))
try:font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',18)
except OSError:font=ImageFont.load_default(size=18)
def panel(im,title,subtitle):
    canvas=Image.new('RGB',(640,490),'#15181d');pic=im.copy();pic.thumbnail((640,427))
    canvas.paste(pic,((640-pic.width)//2,63+(427-pic.height)//2));d=ImageDraw.Draw(canvas)
    d.text((12,8),title,font=font,fill='white');d.text((12,33),subtitle,font=font,fill='#b8c4d4');return canvas
def sheet(panels,name):
    canvas=Image.new('RGB',(1280,980));
    for i,p in enumerate(panels):canvas.paste(p,((i%2)*640,(i//2)*490))
    canvas.save(out/name)
sheet([panel(images['reference'],'Original reference • DSC00025','Single 15-second RAW'),
       panel(images['seiza'],'Seiza • 21 frames','Upstream stack + our reference-ground adapter'),
       panel(images['astroalign'],'Astroalign • 21 frames','Upstream alignment + our clipped-mean adapter'),
       panel(images['native-metal'],'Swift + Metal • 21 frames','Robust stack + measured meteor restored')],'stack-comparison-1280.png')

tetra=json.loads((r/'tetra3/report.json').read_text())['attempts'][0]
annotated=images['reference'].copy();draw=ImageDraw.Draw(annotated);x,y,cw,ch=tetra['crop']
draw.rectangle((x,y,x+cw,y+ch),outline='cyan',width=3)
for yy,xx in tetra['matched_centroids']:draw.ellipse((x+xx-6,y+yy-6,x+xx+6,y+yy+6),outline='lime',width=2)
annotated.resize((1280,854),Image.Resampling.LANCZOS).save(out/'tetra3-1280.png')
det=Image.open(r/'detect-sky-roi-debug/mask_0010_DSC00025.ARW.png').convert('RGB')
det.thumbnail((1280,1280));det.save(out/'detect-meteors-1280.png')
sheet([panel(images['seiza'],'Seiza • native upstream Metal','21/21 frames accepted'),panel(images['astroalign'],'Astroalign • upstream CPU','21/21 frames accepted'),
       panel(annotated,'tetra3 • catalog identification','12 stars matched in the cyan crop'),panel(det,'Detect Meteors • upstream mask','Sky ROI: four candidate frames; not classification')],'four-upstreams-1280.png')

# Identical unscaled crop, for checking star/meteor detail independently of thumbnails.
box=(150,210,650,540)
sheet([panel(images['reference'].crop(box),'Reference crop','Same pixels and display transform'),
       panel(images['seiza'].crop(box),'Seiza crop','Meteor mostly rejected by integration'),
       panel(images['astroalign'].crop(box),'Astroalign crop','Our integration rejects the transient'),
       panel(images['native-metal'].crop(box),'Swift + Metal crop','Recorded RGB restored from DSC00025')],'meteor-detail-1280.png')

# Comparable noise/flux measurements on a common mask and the same star list.
report=json.loads((r/'native-metal/report.json').read_text());stars=report['frames'][10]['stars']
mask=np.fromfile(r/'input1600/mask.f32',np.float32).reshape(h,w);sky=mask>.999;sky[:20]=False;sky[int(h*.65):]=False;sky[:,:20]=False;sky[:,-20:]=False
for s in stars:
    x,y=round(s['point']['x']),round(s['point']['y']);sky[max(0,y-8):min(h,y+9),max(0,x-8):min(w,x+9)]=False
def luma(a):return a@np.array([.2126,.7152,.0722])
def sigma(a):
    a=luma(a);v=((4*a-np.roll(a,1,0)-np.roll(a,-1,0)-np.roll(a,1,1)-np.roll(a,-1,1))/np.sqrt(20))[sky]
    return float(np.median(abs(v-np.median(v)))*1.4826)
metrics={}
for name,rgb in [('seiza',np.load(r/'seiza/foreground-adapter.npy')),('astroalign',np.load(r/'astroalign/foreground-adapter.npy')),('native-metal',clean)]:
    metrics[name]={'finite':bool(np.isfinite(rgb).all()),'ground_max_error':float(abs(rgb[mask==0]-ref[mask==0]).max()),
        'sky_high_frequency_sigma':sigma(rgb),'high_frequency_reduction_vs_reference':sigma(ref)/sigma(rgb)}
(out/'quality-comparison.json').write_text(json.dumps(metrics,indent=2))
print(json.dumps(metrics,indent=2))
