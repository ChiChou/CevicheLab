#!/usr/bin/env python3
"""Read selected TIFF/DNG structure and develop metadata without decoding pixels.

Usage: python3 inspect_dng.py input.dng > summary.json
No third-party dependency. Classic TIFF only; deliberately not a general TIFF validator.
"""
import hashlib
import json
import struct
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

NAMES = {
    254:'NewSubfileType', 256:'ImageWidth', 257:'ImageLength', 258:'BitsPerSample',
    259:'Compression', 262:'PhotometricInterpretation', 274:'Orientation', 277:'SamplesPerPixel',
    284:'PlanarConfiguration', 322:'TileWidth', 323:'TileLength', 339:'SampleFormat',
    33421:'CFARepeatPatternDim', 33422:'CFAPattern', 50706:'DNGVersion', 50707:'DNGBackwardVersion',
    50708:'UniqueCameraModel', 50713:'BlackLevelRepeatDim', 50714:'BlackLevel', 50717:'WhiteLevel',
    50719:'DefaultCropOrigin', 50720:'DefaultCropSize', 50721:'ColorMatrix1', 50722:'ColorMatrix2',
    50723:'CameraCalibration1', 50724:'CameraCalibration2', 50728:'AsShotNeutral',
    50729:'AsShotWhiteXY', 50730:'BaselineExposure', 50778:'CalibrationIlluminant1',
    50779:'CalibrationIlluminant2', 50829:'ActiveArea', 50831:'AsShotICCProfile',
    50833:'CurrentICCProfile', 50879:'ColorimetricReference', 50936:'ProfileName',
    50937:'ProfileHueSatMapDims', 50938:'ProfileHueSatMapData1', 50939:'ProfileHueSatMapData2',
    50940:'ProfileToneCurve', 50964:'ForwardMatrix1', 50965:'ForwardMatrix2',
    50970:'PreviewColorSpace', 50981:'ProfileLookTableDims', 50982:'ProfileLookTableData',
    51008:'OpcodeList1', 51009:'OpcodeList2', 51022:'OpcodeList3',
    51109:'BaselineExposureOffset', 51110:'DefaultBlackRender',
    52553:'JXLDistance', 52554:'JXLEffort', 52555:'JXLDecodeSpeed',
}
SIZES = {1:1,2:1,3:2,4:4,5:8,6:1,7:1,8:2,9:4,10:8,11:4,12:8,13:4}
CRS = '{http://ns.adobe.com/camera-raw-settings/1.0/}'
SETTINGS = {'HasSettings','AlreadyApplied','HasCrop','WhiteBalance','Temperature','Tint',
            'Exposure2012','Contrast2012','Highlights2012','Shadows2012','Whites2012','Blacks2012',
            'Vibrance','Saturation','CameraProfile','HDREditMode','LensProfileEnable'}

def inspect(path):
    data = path.read_bytes()
    endian = '<' if data[:2] == b'II' else '>'
    def unpack(fmt, offset): return struct.unpack_from(endian+fmt,data,offset)
    if data[:2] not in (b'II',b'MM') or unpack('H',2)[0] != 42:
        raise ValueError('Expected classic TIFF DNG')
    result = {'file':path.name, 'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest(), 'ifds':[]}
    seen = set()
    def visit(offset, label):
        if offset in seen or offset == 0: return
        seen.add(offset)
        count = unpack('H',offset)[0]
        if count > 4096: raise ValueError('Unreasonable IFD entry count')
        tags = {}; children = []
        for i in range(count):
            p = offset+2+i*12
            tag,kind,n = unpack('HHI',p)
            if kind not in SIZES: continue
            length = n*SIZES[kind]
            start = p+8 if length <= 4 else unpack('I',p+8)[0]
            if start+length > len(data): raise ValueError('Tag outside file')
            raw = data[start:start+length]
            if tag == 330:
                children = list(unpack('I'*n,start)); continue
            if tag == 700:
                # Only selected develop attributes; no GPS, serials, private profile tables or history.
                settings = {}
                for node in ET.fromstring(raw).iter():
                    for k,v in node.attrib.items():
                        if k.startswith(CRS) and k[len(CRS):] in SETTINGS: settings[k[len(CRS):]] = v
                result['developMetadata'] = settings
            if tag not in NAMES: continue
            if length > 512 or kind == 7:
                value = {'count':n, 'bytes':length}
            elif kind == 2: value = raw.rstrip(b'\0').decode('utf8',errors='replace')
            elif kind in (5,10):
                pairs = unpack(('i' if kind==10 else 'I')*(n*2),start)
                value = [f'{pairs[j]}/{pairs[j+1]}' for j in range(0,n*2,2)]
            else:
                value = list(unpack({1:'B',3:'H',4:'I',6:'b',8:'h',9:'i',11:'f',12:'d',13:'I'}[kind]*n,start))
            tags[NAMES[tag]] = value
        result['ifds'].append({'ifd':label, 'tags':tags})
        for i,child in enumerate(children): visit(child,label+f'/SubIFD{i}')
        visit(unpack('I',offset+2+count*12)[0],label+'/next')
    visit(unpack('I',4)[0],'IFD0')
    return result

if __name__ == '__main__':
    print(json.dumps(inspect(Path(sys.argv[1])),indent=2))
