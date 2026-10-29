"""Scratch DNG variants to test ImageIO's source selection. Never edit the source.
Restrict IFD0's SubIFDs to one full-resolution image, marking that image as primary.
This is an investigation tool, not a DNG writer or conformance validator.
"""
import struct
import sys
from pathlib import Path

source, directory = Path(sys.argv[1]), Path(sys.argv[2])
original = source.read_bytes()
endian = '<' if original[:2] == b'II' else '>'
assert struct.unpack_from(endian+'H', original, 2)[0] == 42
def entries(data, offset):
    for i in range(struct.unpack_from(endian+'H', data, offset)[0]):
        p = offset+2+i*12
        yield p, struct.unpack_from(endian+'HHII',data,p)
root = struct.unpack_from(endian+'I',original,4)[0]
entry, (_,kind,count,pointer) = next((p,v) for p,v in entries(original,root) if v[0]==330)
assert kind in (4,13) and count >= 2
offsets = struct.unpack_from(endian+'I'*count,original,pointer)
for index,label in [(0,'mosaic-only'),(1,'enhanced-only')]:
    data=bytearray(original)
    # Enhanced IFDs can inherit crop geometry from the primary image. Make that
    # geometry explicit when promoting the enhanced IFD to standalone primary.
    table={v[0]:bytes(data[p:p+12]) for p,v in entries(data,offsets[index])}
    if index==1:
        for p,v in entries(data,offsets[0]):
            if v[0] in (50718,50719,50720,50829) and v[0] not in table:
                table[v[0]]=bytes(data[p:p+12])
    table[254]=struct.pack(endian+'HHII',254,4,1,0)
    if len(data)%2:data.append(0)
    new_offset=len(data)
    data.extend(struct.pack(endian+'H',len(table)))
    for tag in sorted(table):data.extend(table[tag])
    data.extend(struct.pack(endian+'I',0))
    struct.pack_into(endian+'II',data,entry+4,1,new_offset)
    (directory/(source.stem+'-'+label+'.dng')).write_bytes(data)
