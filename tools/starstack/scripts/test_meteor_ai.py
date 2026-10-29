"""Small image-behavior regression checks for the new candidate adapter."""
import unittest
import cv2
import numpy as np
from meteor_ai import refine_roi, streak_points, line_mask, project, merge_segments

class MeteorAdapterTests(unittest.TestCase):
    def setUp(self):
        rng=np.random.default_rng(12);self.h=self.w=256
        self.clean=np.full((256,256,4),.02,np.float32);self.clean[:,:,3]=1
        self.source=self.clean.copy();self.source[:,:,:3]+=rng.normal(0,.0001,(256,256,3))
        self.poly=np.array([[40,40],[165,40],[165,160],[40,160]])
        self.sky=np.ones((256,256));self.stars=np.zeros((256,256),bool)

    def test_measured_trail_is_found_without_accepting_noise(self):
        self.assertFalse(refine_roi(self.source,self.clean,self.sky,self.stars,self.poly,0))
        trail=np.zeros((256,256),np.float32);cv2.line(trail,(50,55),(150,145),.008,2)
        self.source[:,:,:3]+=trail[:,:,None]
        found=refine_roi(self.source,self.clean,self.sky,self.stars,self.poly,0)
        self.assertTrue(found)
        self.assertGreater(max(np.linalg.norm(np.diff(streak_points(s),axis=0)) for s in found),100)
        self.assertFalse(refine_roi(self.source,self.clean,self.sky*0,self.stars,self.poly,0))

    def test_footprint_does_not_paste_a_box(self):
        s=dict(start=dict(x=10,y=10),end=dict(x=100,y=100),width=1)
        region,alpha=line_mask(s,128,128)
        image=np.zeros((128,128));image[region]=alpha
        self.assertEqual(image[10,100],0)
        self.assertEqual(image[50,50],1)
        self.assertLess(np.count_nonzero(image),800)

    def test_forward_projective_coordinates(self):
        a={'transform':{'m':[1,0,4,0,1,-2,0,0,1]}}
        np.testing.assert_allclose(project([[10,20],[0,0]],a),[[14,18],[4,-2]])

    def test_duplicate_cv_and_ai_segments_form_one_trail(self):
        a=dict(start=dict(x=10,y=10),end=dict(x=100,y=100),width=1,pixels=30,peakResidual=.1,origin='cv')
        b=dict(a,start=dict(x=90,y=90),end=dict(x=110,y=110),origin='ai')
        joined=merge_segments([a,b])
        self.assertEqual(len(joined),1)
        np.testing.assert_allclose(streak_points(joined[0]),[[10,10],[110,110]])

if __name__=='__main__':unittest.main()
