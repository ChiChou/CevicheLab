"""Real Sony tile: compare PMRID Core ML with its original PyTorch weights."""
import sys,json,time
from pathlib import Path
import numpy as np,torch,coremltools as ct
root=Path(sys.argv[1]);source=root.parent/'denoise-model-research/PMRID';sys.path.insert(0,str(source))
from models.net_torch import Network
torch.set_num_threads(4);model=Network().eval()
model.load_state_dict(torch.load(source/'models/torch_pretrained.ckp',map_location='cpu',weights_only=True))
info=json.loads((root/'DSC00396-pmrid-inference.json').read_text())
meta=json.loads((root/'DSC00396-bayer.json').read_text())
raw=np.memmap(root/'DSC00396.bayer16',mode='r',dtype='<u2',shape=(meta['height'],meta['width']))
modelml=ct.models.MLModel(str(root.parent/'denoise-model-research/PMRID-research.mlpackage'),compute_units=ct.ComputeUnit.ALL)
scale=np.array(info['normalizationScale'],dtype=np.float32)[None,:,None,None]
offset=np.array(info['normalizationOffset'],dtype=np.float32)[None,:,None,None]
rows=[]
for name,x,y in [('stars',1400,600),('aurora',2900,2000),('window',350,3100)]:
    a=raw[y:y+512,x:x+512].astype(np.float32)
    a=np.clip((a-meta['black'])/(meta['white']-meta['black']),0,1)
    packed=np.stack([a[0::2,0::2],a[0::2,1::2],a[1::2,0::2],a[1::2,1::2]])[None]
    inp=np.ascontiguousarray((packed*scale+offset)*256,dtype=np.float32)
    with torch.no_grad():ref=model(torch.from_numpy(inp)).numpy()
    actual=modelml.predict({'packed_raw':inp})['denoised_raw']
    err=abs(actual-ref)/256/scale
    rows.append({'region':name,'meanNormalizedRawError':float(err.mean()),'maxNormalizedRawError':float(err.max()),'finite':bool(np.isfinite(actual).all())})
(root/'pmrid-real-tile-check.json').write_text(json.dumps(rows,indent=2));print(rows)
