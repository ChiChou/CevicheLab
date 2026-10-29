"""Check real-image Core ML output against the official checkpoint in PyTorch."""
import sys,time,json,os
from pathlib import Path
import numpy as np
import torch,coremltools as ct
root=Path(sys.argv[1])
if not os.environ.get('CEVICHE_ROOT'):
    raise SystemExit('Set CEVICHE_ROOT to a Ceviche checkout containing ml/nafnet_arch.py')
sys.path.insert(0,str(Path(os.environ['CEVICHE_ROOT'])/'ml'))
from nafnet_arch import NAFNet
torch.set_num_threads(4)
model=NAFNet().eval();state=torch.load(root/'nafnet.pth',map_location='cpu',weights_only=True)
model.load_state_dict(state['params'] if 'params' in state else state)
a=np.load(root/'rgb-results/DSC00396-stars-input.npy')[:512,:512]
m=np.array([[1.660491,-.587641,-.072850],[-.124550,1.132900,-.008349],[-.018151,-.100579,1.118730]],dtype=np.float32)
lin=np.clip(a@m.T,0,1);inp=np.where(lin<=.0031308,lin*12.92,1.055*lin**(1/2.4)-.055).transpose(2,0,1)[None].copy()
t=time.perf_counter()
with torch.no_grad():ref=model(torch.from_numpy(inp)).numpy()
report={'torchSeconds':time.perf_counter()-t,'inputRange':[float(inp.min()),float(inp.max())],
        'torchRange':[float(ref.min()),float(ref.max())],'results':[]}
np.save(root/'nafnet-torch-tile.npy',ref)
for units in [ct.ComputeUnit.ALL,ct.ComputeUnit.CPU_ONLY,ct.ComputeUnit.CPU_AND_GPU]:
    executable=ct.models.MLModel(str(root/'NAFNet.mlpackage'),compute_units=units)
    t=time.perf_counter();out=executable.predict({'image':inp})['denoised'];dt=time.perf_counter()-t
    error=abs(out-ref)
    row={'computeUnits':units.name,'seconds':dt,'meanError':float(error.mean()),'maxError':float(error.max()),
         'finite':bool(np.isfinite(out).all()),'range':[float(out.min()),float(out.max())]}
    report['results'].append(row);print(row,flush=True)
    (root/'nafnet-real-tile-check.json').write_text(json.dumps(report,indent=2))
