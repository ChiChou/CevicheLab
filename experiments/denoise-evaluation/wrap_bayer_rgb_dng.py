"""Research-only uncompressed LinearRaw DNG from RawNIND camera-RGB output.
Uses the matching Lightroom DNG's calibration/geometry metadata; retains unused
original payloads in this scratch file. Not a shipping exporter or space-efficient writer.
"""
import json,struct,sys
from pathlib import Path
import numpy as np

root=Path(sys.argv[1]); template=Path(sys.argv[2]); stem=sys.argv[3]
mosaic='--mosaic' in sys.argv
model='pmrid' if mosaic else 'rawnind-bayer'
meta=json.loads((root/(stem+'-bayer.json')).read_text());h,w=meta['height'],meta['width']
a=np.memmap(root/(stem+('-pmrid.mosaic32' if mosaic else '-rawnind-bayer.rgb32')),dtype='<f4',mode='r',shape=(h,w) if mosaic else (h,w,3))
lo=float(a.min());hi=float(a.max())
# Reserve negative range and highlight headroom while retaining >14-bit scale.
black=8192;scale=32768
assert lo>=-black/scale and hi<=(65535-black)/scale,(lo,hi)
data=bytearray(template.read_bytes());e='<' if data[:2]==b'II' else '>'
assert e=='<','This narrow research writer expects the supplied little-endian DNG'
def entries(offset):
    for i in range(struct.unpack_from(e+'H',data,offset)[0]):
        p=offset+2+i*12;yield p,struct.unpack_from(e+'HHII',data,p)
ifd0=struct.unpack_from(e+'I',data,4)[0]
subp,(_,_,n,pointer)=next((p,v) for p,v in entries(ifd0) if v[0]==330)
primary=struct.unpack_from(e+'I',data,pointer)[0]
omit={254,256,257,258,259,262,273,277,278,279,284,322,323,324,325,339,
      33421,33422,50710,50711,50712,50713,50714,50715,50716,50717,50829,
      51008,51009,51022,52553,52554,52555}
if mosaic:omit-= {33421,33422,50710,50711}
table={v[0]:bytes(data[p:p+12]) for p,v in entries(primary) if v[0] not in omit}
def tag(tag,kind,values):
    fmt={3:'H',4:'I'}[kind];payload=struct.pack(e+fmt*len(values),*values)
    if len(payload)>4:
        if len(data)%2:data.append(0)
        value=struct.pack(e+'I',len(data));data.extend(payload)
    else:value=payload.ljust(4,b'\0')
    table[tag]=struct.pack(e+'HHI',tag,kind,len(values))+value
channels=1 if mosaic else 3
for t,k,v in [(254,4,[0]),(256,4,[w]),(257,4,[h]),(258,3,[16]*channels),(259,3,[1]),
              (262,3,[32803 if mosaic else 34892]),(277,3,[channels]),(278,4,[h]),(279,4,[h*w*2*channels]),(284,3,[1]),
              (339,3,[1]*channels),(50713,3,[1,1]),(50714,4,[black]*channels),(50717,4,[black+scale]*channels),
              (50829,4,[0,0,h,w])]:tag(t,k,v)
if len(data)%2:data.append(0)
# Image payload follows the new IFD, whose size is now known (plus StripOffsets).
new_ifd=len(data);payload_offset=new_ifd+2+(len(table)+1)*12+4
tag(273,4,[payload_offset])
data.extend(struct.pack(e+'H',len(table)))
for t in sorted(table):data.extend(table[t])
data.extend(struct.pack(e+'I',0))
struct.pack_into(e+'II',data,subp+4,1,new_ifd)
dest=root/(stem+'-'+model+'.dng')
with dest.open('wb') as f:
    f.write(data)
    for y in range(0,h,128):f.write(np.rint(a[y:y+128]*scale+black).astype('<u2').tobytes())
report={'file':dest.name,'template':template.name,'payload':'denoised CFA mosaic' if mosaic else 'camera-native linear RGB from Bayer model',
        'black':black,'white':black+scale,'scale':scale,'minimum':lo,'maximum':hi,
        'clippedSamples':0,'idealQuantizationHalfStep':.5/scale,'compression':'none',
        'note':'Research copy: source opcodes omitted; unused original payloads remain. Not a conformance-validated exporter.'}
(root/(stem+'-'+model+'-dng-wrapper.json')).write_text(json.dumps(report,indent=2));print(report)
