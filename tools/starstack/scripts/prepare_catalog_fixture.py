"""Export tetra3's database and unsolved measured centroids for a native solver test.
No solved pointing, matched IDs, or fitted FOV is passed to the native program.
Run with the separate NumPy 1.x tetra-venv.
"""
from pathlib import Path
import json,numpy as np,tetra3
r=Path(__file__).resolve().parents[1]/'output/comparison';d=r/'catalog-fixture';d.mkdir(exist_ok=True)
solver=tetra3.Tetra3();solver.pattern_catalog.astype('<u2').tofile(d/'patterns.u16')
solver.star_table[:,2:5].astype('<f4').tofile(d/'vectors.f32')
rgb=np.fromfile(r/'input1600/0010_DSC00025.rgba',dtype='<f4').reshape(1068,1600,4)[110:460,625:975,:3]
gray=(rgb@np.array([.2126,.7152,.0722])).astype('float32')
centroids=tetra3.get_centroids_from_image(gray,sigma=3,min_area=2,max_area=100,binary_open=False,max_returned=60)
(d/'input.json').write_text(json.dumps({'width':350,'height':350,'crop':[625,110,350,350],'centroids':centroids.tolist(),
 'fov_estimate_degrees':float(np.degrees(2*np.arctan(350/(2*750)))), 'pattern_rows':len(solver.pattern_catalog),'star_count':len(solver.star_table)},indent=2))
print('Exported unsolved centroids and database',len(centroids),solver.pattern_catalog.shape)
