#!/usr/bin/env python3
"""Core ML conversion smoke test, NOT a denoising quality or full-photo benchmark.

Usage: python pmrid_coreml_probe.py /path/to/PMRID /path/to/output
Requires torch, numpy and coremltools on macOS. Uses official tensor-only weights.
"""
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time

import numpy as np
import torch
import coremltools as ct

source = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
checkpoint = source/'models/torch_pretrained.ckp'
digest = hashlib.sha256(checkpoint.read_bytes()).hexdigest()
assert digest == '9361614f3514d27351d81909f2215c0fdc38619c0288d936b7266485ac106c14'
sys.path.insert(0, str(source))
from models.net_torch import Network

torch.set_num_threads(4)
model = Network().eval()
model.load_state_dict(torch.load(checkpoint, map_location='cpu', weights_only=True), strict=True)
# Upstream multiplies normalized, noise-normalized packed RAW by 256 before inference.
# This synthetic input tests conversion equivalence only; it does not calibrate a camera.
rng = np.random.default_rng(42)
sample = (np.clip(0.1 + rng.normal(0, 0.01, size=(1,4,256,256)), 0, 1)*256).astype(np.float32)
tensor = torch.from_numpy(sample)
with torch.no_grad():
    expected = model(tensor).numpy()
    traced = torch.jit.trace(model, tensor)
converted = ct.convert(traced, inputs=[ct.TensorType(name='packed_raw', shape=sample.shape)],
                       outputs=[ct.TensorType(name='denoised_raw')], convert_to='mlprogram',
                       compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.macOS13,
                       compute_units=ct.ComputeUnit.ALL)
package = output/'PMRID-research.mlpackage'
converted.save(str(package))
rows = []
for units in [ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_ONLY]:
    executable = ct.models.MLModel(str(package), compute_units=units)
    start = time.perf_counter()
    actual = executable.predict({'packed_raw':sample})['denoised_raw']
    cold = time.perf_counter()-start
    times=[]
    for _ in range(5):
        start=time.perf_counter()
        actual=executable.predict({'packed_raw':sample})['denoised_raw']
        times.append(time.perf_counter()-start)
    error = np.abs(actual-expected)/256
    rows.append({'requestedComputeUnits':units.name, 'finite':bool(np.isfinite(actual).all()),
                 'coldPredictionSeconds':cold, 'warmMedianSeconds':statistics.median(times),
                 'warmPredictionSeconds':times, 'maeNormalizedRaw':float(error.mean()),
                 'maxErrorNormalizedRaw':float(error.max()), 'shape':list(actual.shape)})
report = {'purpose':'Synthetic conversion equivalence and tile timing only; no denoising quality ranking',
          'chip':subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
          'os':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),
          'upstreamCommit':subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip(),
          'checkpointSHA256':digest, 'parameters':sum(p.numel() for p in model.parameters()),
          'packedTile':[256,256], 'equivalentSensorRegion':[512,512], 'torch':torch.__version__,
          'coremltools':ct.__version__, 'precision':'FP16 weights/compute graph; float32 input and output',
          'packageBytes':sum(p.stat().st_size for p in package.rglob('*') if p.is_file()), 'results':rows}
(output/'pmrid-coreml.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
