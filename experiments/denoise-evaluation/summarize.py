"""Build aligned crop comparisons and descriptive (not ground-truth) metrics."""
import sys,json
from pathlib import Path
import numpy as np
from PIL import Image,ImageDraw,ImageFont
from scipy.ndimage import gaussian_filter,maximum_filter

root=Path(sys.argv[1]);out=root/'rgb-results'
M=np.array([[1.660491,-.587641,-.072850],[-.124550,1.132900,-.008349],[-.018151,-.100579,1.118730]],dtype=np.float32)
CASES={'DSC00032':[('sky',3000,1000),('mountain',1000,2100),('water',3500,3400),('foreground',5100,4400)],
       'DSC00396':[('stars',1400,600),('aurora',2900,2000),('window',350,3100),('dark-sky',3700,900)]}
LABELS={'input':'ImageIO ARW','nafnet':'NAFNet','rawnind-linear':'RawNIND linear','treenet-light':'TreeNet Light',
        'lightroom':'Lightroom enhanced','bayer':'RawNIND Bayer','pmrid':'PMRID Bayer','mosaic':'ImageIO DNG mosaic'}
def full(stem):
    m=json.loads((root/(stem+'.json')).read_text())
    return np.memmap(root/(stem+'.rgba32'),mode='r',dtype='<f4',shape=(m['height'],m['width'],4))
def encode(a):
    a=np.maximum(a,0);return np.where(a<=.0031308,a*12.92,1.055*a**(1/2.4)-.055)
def display(a,ev=0):return np.uint8(np.round(np.clip(encode((a@M.T)*2**ev),0,1)*255))
for key,stem in [('lightroom','DSC00396-Enhanced-NR-enhanced-only'),('mosaic','DSC00396-Enhanced-NR-mosaic-only'),('bayer','DSC00396-rawnind-bayer'),('pmrid','DSC00396-pmrid')]:
    a=full(stem)
    for name,x,y in CASES['DSC00396']:
        if (out/f'DSC00396-{name}-{key}-ev2.png').exists():continue
        crop=a[y:y+768,x:x+768,:3].copy();np.save(out/f'DSC00396-{name}-{key}.npy',crop)
        for ev in [0,2]:Image.fromarray(display(crop,ev)).save(out/f'DSC00396-{name}-{key}-ev{ev}.png')

report={'note':'No noise-free reference. High-pass MAD measures remaining small-scale variation, including texture; lower is not automatically better.',
        'rows':[],'features':{}}
font=ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc',16)
for stem,rois in CASES.items():
    columns=['input','nafnet','rawnind-linear','treenet-light']+(['lightroom','bayer','pmrid','mosaic'] if stem=='DSC00396' else [])
    for name,x,y in rois:
        for model in columns:
            a=np.load(out/f'{stem}-{name}-{model}.npy');rgb=encode(np.clip(a@M.T,0,1))*255
            luma=rgb@np.array([.2126,.7152,.0722]);high=luma-gaussian_filter(luma,1)
            chroma=rgb[:,:,0]-rgb[:,:,1];chroma-=gaussian_filter(chroma,1)
            mad=lambda v:float(np.median(abs(v-np.median(v)))*1.4826)
            report['rows'].append({'file':stem,'region':name,'model':model,'lumaHighpassMAD8':mad(high),
                'chromaRGHighpassMAD8':mad(chroma),'meanLinearRGB':a.mean((0,1)).tolist()})
    for title,cols in [('rgb',['input','nafnet','rawnind-linear','treenet-light']),
                       *([('bayer',['mosaic','bayer','pmrid','lightroom'])] if stem=='DSC00396' else [])]:
        sheet=Image.new('RGB',(384*len(cols),424*len(rois)),(24,24,27));d=ImageDraw.Draw(sheet)
        for row,(name,x,y) in enumerate(rois):
            for col,model in enumerate(cols):
                image=Image.open(out/f'{stem}-{name}-{model}-ev2.png').crop((192,192,576,576))
                sheet.paste(image,(col*384,row*424+40));d.text((col*384+8,row*424+10),f'{name} / {LABELS[model]}',font=font,fill='white')
        sheet.save(out/f'{stem}-{title}-comparison.png')

# Detect bright local features in Lightroom's star crop, then measure peak minus
# local background at those same coordinates. These are not confirmed stars or
# ground-truth preservation scores. ±2px search tolerates subpixel demosaic shifts.
ref=np.load(out/'DSC00396-stars-lightroom.npy')@np.array([.2627,.6780,.0593])
background=gaussian_filter(ref,3);signal=ref-background
peaks=(signal==maximum_filter(signal,11))&(signal>.015)
peaks[:12]=False;peaks[-12:]=False;peaks[:,:12]=False;peaks[:,-12:]=False
positions=np.argwhere(peaks)
contrasts={}
for model in ['lightroom','bayer','pmrid','mosaic']:
    a=np.load(out/f'DSC00396-stars-{model}.npy')@np.array([.2627,.6780,.0593]);values=[]
    for y,x in positions:
        patch=a[y-10:y+11,x-10:x+11];ring=np.ones((21,21),bool);ring[6:15,6:15]=False
        values.append(float(a[y-2:y+3,x-2:x+3].max()-np.median(patch[ring])))
    contrasts[model]=np.array(values)
report['features']={'count':len(positions),'positionsYX':positions.tolist(),'thresholdLinear':.015,
 'note':'Reference-associated bright features, not verified astronomical objects. Ratios also include rendering/demosaic changes.',
 'models':{m:{'medianContrastRelativeToLightroom':float(np.median(v/contrasts['lightroom'])),
              'countBelowHalfLightroomContrast':int(np.sum(v<contrasts['lightroom']*.5))} for m,v in contrasts.items()}}
(out/'quality-summary.json').write_text(json.dumps(report,indent=2))

data={'cases':CASES,'labels':LABELS}
html='''<!doctype html><html><meta charset="utf-8"><title>Ceviche denoise evaluation</title>
<style>body{font:16px system-ui;background:#19191d;color:#eee;margin:28px}h1{font-size:26px}p{max-width:1050px;line-height:1.5}select{font:inherit;background:#333;color:white;padding:8px;margin:4px;border:1px solid #666;border-radius:6px}.pair{display:flex;gap:18px;overflow:auto}.panel{flex:none}img{display:block;width:768px;height:768px}h2{font-size:18px}small{color:#bbb}</style>
<h1>Denoise evaluation · supplied Sony RAW samples</h1>
<p>Native-resolution 768 × 768 crops. +2 EV is applied after denoising to expose shadow noise. No noise-free ground truth. ImageIO's default Lightroom DNG decode selects the original mosaic; “Lightroom enhanced” explicitly selects the enhanced IFD. ARW and DNG decoding produce different geometry, so comparisons are grouped by input path.</p>
<select id="suite"><option value="bayer">Bayer / DNG comparison</option><option value="rgb">ImageIO RGB comparison</option></select><select id="photo"></select><select id="region"></select><select id="ev"><option value="2">Shadow view: +2 EV</option><option value="0">Original brightness</option></select>
<div class="pair"><div class="panel"><h2><select id="left"></select></h2><img id="a"></div><div class="panel"><h2><select id="right"></select></h2><img id="b"></div></div>
<p><small>RGB: ImageIO decode → model-specific color conversion → denoise. Bayer: LibRaw mosaic → model → research DNG → ImageIO. RawNIND outputs camera RGB; PMRID retains the mosaic and uses the matching source DNG's noise profile. NAFNet's colored-grid failure is retained for inspection and also reproduced in PyTorch. Generated DNGs are research artifacts.</small></p>
<script>const data=DATA;const q=id=>document.getElementById(id);function options(id,items){q(id).replaceChildren(...items.map(([value,text])=>Object.assign(document.createElement('option'),{value,textContent:text})));}function suite(){const b=q('suite').value==='bayer';options('photo',(b?['DSC00396']:Object.keys(data.cases)).map(x=>[x,x+(x==='DSC00396'?' · ISO 8000':' · ISO 640')]));setup();}function setup(){const p=q('photo').value,b=q('suite').value==='bayer';options('region',data.cases[p].map(x=>[x[0],x[0]]));const models=b?['mosaic','bayer','pmrid','lightroom']:['input','nafnet','rawnind-linear','treenet-light'];for(const id of ['left','right'])options(id,models.map(x=>[x,data.labels[x]]));q('left').value=b?'lightroom':'input';q('right').value=b?'pmrid':'treenet-light';render();}function render(){for(const [select,img] of [['left','a'],['right','b']])q(img).src=`${q('photo').value}-${q('region').value}-${q(select).value}-ev${q('ev').value}.png`;}q('suite').onchange=suite;q('photo').onchange=setup;for(const id of ['region','left','right','ev'])q(id).onchange=render;suite();</script></html>'''.replace('DATA',json.dumps(data))
(out/'comparison.html').write_text(html)
print(json.dumps(report['features'],indent=2))
