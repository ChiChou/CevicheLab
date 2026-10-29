"""Make read-only input fixtures for native Metal/OpenCV parity checks."""
from pathlib import Path
import argparse
import numpy as np,json,cv2,time
from PIL import Image
from meteor_core.inputs.raw import RawImageLoader,RawLoaderConfig
parser=argparse.ArgumentParser();parser.add_argument('--raw-dir',type=Path,required=True);args=parser.parse_args()
r=Path(__file__).resolve().parents[1]/'output/comparison';p=r.parent/'pilot-final-3200'
j=json.loads((p/'report.json').read_text())
m=np.fromfile(p/'sky-mask.f32',np.float32).reshape(j['height'],j['width'])
np.asarray(Image.fromarray(m).resize((1600,1068),Image.Resampling.BILINEAR)).astype('<f4').tofile(r/'input1600/mask.f32')
d=r/'detector-fixture';d.mkdir(exist_ok=True);loader=RawImageLoader(RawLoaderConfig())
raw=args.raw_dir
a=loader.load(str(raw/'DSC00024.ARW')).image_data;b=loader.load(str(raw/'DSC00025.ARW')).image_data
assert a.shape==b.shape==(2660,4000)
a.astype('<f4').tofile(d/'a.f32');b.astype('<f4').tofile(d/'b.f32')
times=[]
for _ in range(3):
    t=time.perf_counter();diff=cv2.absdiff(a,b);_,mask=cv2.threshold(diff,179,255,cv2.THRESH_BINARY)
    opened=cv2.morphologyEx(mask.astype('uint8'),cv2.MORPH_OPEN,np.ones((3,3),np.uint8));times.append(time.perf_counter()-t)
opened.tofile(d/'opencv-opened.u8')
(d/'report.json').write_text(json.dumps({'shape':list(a.shape),'opencv_cpu_seconds':times,'threshold':179,'pair':['DSC00024.ARW','DSC00025.ARW']},indent=2))
print('Prepared detector parity fixture',times)
