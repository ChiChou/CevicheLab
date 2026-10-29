#!/usr/bin/env python3
"""Minimal research-only, uncompressed 16-bit LinearRaw DNG writer; no preview."""
import json
import struct
import sys
from pathlib import Path

CM_D65 = [3.2404542, -1.5371385, -.4985314, -.969266, 1.8760108, .041556, .0556434, -.2040259, 1.0572252]
CM_D50 = [3.1338561, -1.6168667, -.4906146, -.9787684, 1.9161415, .0334540, .0719453, -.2289914, 1.4052427]
FM = [.4360747, .3850649, .1430804, .2225045, .7168786, .0606169, .0139322, .0971045, .7141733]

def write(path, width, height, pixels, output_referred=False, neutral=True, forward=True, icc=None):
    tags = {}
    def put(tag, kind, values):
        if kind == 7:
            data = values; count = len(data)
        elif kind == 2:
            data = values.encode() + b'\0'; count = len(data)
        elif kind in (5, 10):
            data = b''.join(struct.pack('<ii' if kind == 10 else '<II', round(v*10000000), 10000000) for v in values)
            count = len(values)
        else:
            data = struct.pack('<' + {1:'B',3:'H',4:'I',11:'f'}[kind]*len(values), *values); count = len(values)
        tags[tag] = (kind, count, data)
    for tag,kind,values in [
        (254,4,[0]), (256,4,[width]), (257,4,[height]), (258,3,[16,16,16]),
        (259,3,[1]), (262,3,[34892]), (271,2,'Ceviche'), (272,2,'Rendered RGB experiment'),
        (273,4,[0]), (274,3,[1]), (277,3,[3]), (278,4,[height]), (279,4,[len(pixels)]), (284,3,[1]),
        (305,2,'Ceviche isolated linear DNG investigation'), (339,3,[1,1,1]),
        (50706,1,[1,4,0,0]), (50707,1,[1,4,0,0]), (50708,2,'Ceviche Rendered Linear sRGB'),
        (50713,3,[1,1]), (50714,5,[0,0,0]), (50717,4,[65535,65535,65535]),
        (50718,5,[1,1]), (50719,4,[0,0]), (50720,4,[width,height]),
        (50721,10,CM_D50 if output_referred else CM_D65), (50728,5,[1,1,1]),
        (50730,10,[0]), (50731,5,[1]), (50732,5,[1]), (50734,5,[1]), (50739,5,[1]),
        (50778,3,[23 if output_referred else 21]), (50829,4,[0,0,height,width]),
        (50879,3,[int(output_referred)]), (50936,2,'Ceviche linear sRGB identity'),
    ]: put(tag,kind,values)
    if output_referred:
        # Output-referred data uses the ICC PCS white, not camera white balance.
        del tags[50728]
        put(50729,5,[0.3457,0.3585])
    if neutral:
        put(50940,11,[0,0,1,1]); put(51110,4,[1]); put(51109,10,[0])
    if forward: put(50964,10,FM)
    if icc:
        put(50831,7,icc)
        put(50832,10,[1,0,0,0,1,0,0,0,1])
    def pack():
        offset = 8 + 2 + len(tags)*12 + 4
        entries = bytearray(); extra = bytearray()
        for tag,(kind,count,data) in sorted(tags.items()):
            entries += struct.pack('<HHI',tag,kind,count)
            if len(data) <= 4: entries += data.ljust(4,b'\0')
            else:
                entries += struct.pack('<I',offset+len(extra)); extra += data
                if len(extra)%2: extra += b'\0'
        return b'II*\0'+struct.pack('<I',8)+struct.pack('<H',len(tags))+entries+struct.pack('<I',0)+extra
    put(273,4,[len(pack())])
    path.write_bytes(pack()+pixels)

if __name__ == '__main__':
    folder = Path(sys.argv[1])
    for raw in folder.glob('*.rgb16'):
        meta = json.loads(raw.with_suffix('.json').read_text())
        pixels = raw.read_bytes()
        assert len(pixels) == meta['width']*meta['height']*6
        for name,options in [
            ('scene-default', {} | {'neutral':False}),
            ('scene-neutral', {}),
            ('output-neutral', {'output_referred':True}),
            ('output-no-forward', {'output_referred':True,'forward':False}),
            ('output-icc', {'output_referred':True,'icc':(folder/'linear-srgb.icc').read_bytes()}),
        ]:
            destination = folder/(raw.stem+'_'+name+'.dng')
            write(destination,meta['width'],meta['height'],pixels,**options)
            print(destination.name)
