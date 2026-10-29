# HGMeteorTool: ideas for the native experiment

Reviewed 2026-10-28 from the public `main` branch. [Repository](https://github.com/HG731GZ/HGMeteorTool). Its current README calls the application HoshinoPanoAssistant. This is a targeted source review, not a runtime benchmark or a claim that its output is better on our RAW sequence. No external implementation, model, or catalog was imported; this review changes Markdown only.

## Most useful direction

Separate **shared camera/lens calibration**, **frame orientation and capture time**, and **small remaining local errors**. Our current independently fitted projective/cubic mappings work, but they let lens errors and stellar motion compensate for each other. A shared physical model could stabilize long sequences and provide a better recovery seed after an alignment failure. This is a hypothesis to test, not an established explanation for our corner elongation or flux loss.

The inspected `FrameAstrometricModel` explicitly combines a camera calibration profile with frame pose and an optional local residual. Its forward path maps celestial directions to camera rays and then pixels; its inverse follows the reverse chain. [Source: frame_astrometry.py](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/frame_astrometry.py#L253).

## Techniques worth testing

### 1. Calibrated sky motion driven by EXIF

HGMeteorTool's fixed-camera model maps local east/north/up directions through a static camera projection and residual distortion. Its timing estimator projects known celestial positions at nearby times, estimates their image velocities by finite differences, and robustly fits a scalar time correction. [Source: fixed_camera_model.py](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/fixed_camera_model.py).

For us, first fit a shared lens model and reference orientation across multiple well-distributed exposures. Predict subsequent orientations using exposure-midpoint intervals; retain image checks and allow a small pose correction for tripod disturbances. Keep clock offset separate from camera pose. Absolute catalog-based prediction also needs reliable time-zone/location information or an independently solved celestial orientation; missing EXIF information must not silently become UTC.

Do not fit unconstrained focal length, arbitrary angular speed, clock offset and per-frame warps simultaneously. Our five-frame diagnostic already illustrates weak physical identifiability: good pixel alignment can coexist with a wrong inferred rate. Relative sidereal rotation can be useful without requiring a user to supply GPS for every stack; absolute sky labels are an optional additional capability.

### 2. A spherical fallback for star matching

The adjacent-frame matcher tries both Astroalign's planar similarity initialization and a spherical alternative. The latter converts pixels into approximate camera rays, compares triangles by angular side lengths, estimates rotations using SVD/Kabsch, and scores hypotheses. It then builds unique star correspondences and refines with a RANSAC homography. [Source: adjacent_alignment.py](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/adjacent_alignment.py#L333).

Our next bootstrap experiment should compare planar and spherical hypotheses, particularly for DSC00186–DSC00189 and deliberately skipped intervals. Use the last several reliable frames as possible seeds instead of depending only on the immediate neighbor. With a 16 mm lens, calibrated rays matter; nominal EXIF focal length alone is an approximation. Keep our held-out validation, spatial coverage and rejection rules. More accepted frames are useful only if the rendering also improves.

### 3. Better measurement of star centers and shapes

The PSF fitter includes local background estimation, neighbor masking, adaptive windows and robust elliptical Moffat fitting. It can compare the elliptical result with a circular Moffat using a complexity penalty, while a faster path uses source moments. [Source: psf/fitting.py](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/psf/fitting.py#L581).

We currently use small-window centroids and moments. Test a two-stage native estimator: inexpensive detection first, then robust profile fitting for calibration anchors and uncertain matches. Use fitted uncertainty and shape diagnostics to weight correspondences. Evaluate centroid repeatability, saturated stars, close pairs, stars near terrain, and off-axis aberrations. Moffat profiles will not perfectly describe coma or a star integrated over 15 seconds, so do not equate a converged fit with a physically correct center. Do not circularize the rendered star merely because a circular model fits its center adequately.

### 4. Spatial residuals with explicit support

Its residual correction uses thin-plate splines (TPS), with hard anchors and weighted soft constraints. Interpolation checks anchor geometry and supports smoothing. [Residual implementation](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/alignment/residuals.py), [interpolation implementation](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/alignment/interpolation.py).

A local spline can model distortions that our global cubic misses, but exact interpolation of noisy star centers can overfit. Compare a regularized TPS against the cubic using spatially held-out stars, output flux and shape, and Jacobian/inverse checks. Prefer improving shared calibration before adding per-frame flexibility.

The frame-local residual path falls back to the base mapping outside a padded coverage rectangle; despite its helper's name, that inspected code is a hard fallback, not a smooth blend. It stores separately fitted forward and inverse interpolation objects. [Coverage and inverse handling](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/frame_astrometry.py#L120). For us, evaluate a smooth confidence transition based on actual anchor support, and require round-trip accuracy; independently fitted reverse maps need not be exact inverses. The existing fixed-camera inverse path separately uses iterative inversion with validity checks. These are different paths, not one universal inversion algorithm.

### 5. Background matching before fusion or meteor insertion

The low-frequency subsystem measures overlapping sky directions and solves a regularized spatial correction with frame offsets and optional planes. Its solver supports B-spline bases and Huber reweighting. Its measurement mask excludes bright sources, saturation and strong gradients. [Pipeline](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/photometric/lowfreq/pipeline.py), [solver](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/photometric/lowfreq/solver.py), [measurement masking](https://github.com/HG731GZ/HGMeteorTool/blob/main/meteoralign/photometric/lowfreq/masking.py).

For our scene-linear stack, start with a simpler optional additive background correction, estimated from valid common sky while excluding stars, meteors and terrain. Measure whether it reduces insertion seams and inappropriate temporal rejection. Keep multiplicative exposure/throughput correction separate. Broad Milky Way structure, airglow and real changing illumination must not be erased just because they vary slowly. This will not automatically fix the measured stellar flux loss; resampling and clipping need separate experiments.

### 6. Editable meteor selections and reusable sky coordinates

The documented workflow supports manual meteor regions, associated JSON, sky-coordinate reprojection and meteor-only export. Automatic detection is an optional external MetDet worker, not an included end-to-end detector whose accuracy we have verified. [README](https://github.com/HG731GZ/HGMeteorTool#readme).

We should extend source-frame selection to per-candidate keep/reject and editable footprints, with source crops and persistent-track context. Retain a clean sky stack separately from meteor overlays. A calibrated sky-coordinate model would later support alternate panorama projections and radiant visualization. Radiant consistency can assist review, but should not hard-reject sporadic meteors or claim that every selected streak belongs to a shower.

## Proposed experiment order

| Order | Independent change | Evidence required on our samples |
| --- | --- | --- |
| 1 | Recovery from several reliable seeds plus spherical initialization | Retry the four rejected tail frames and larger artificial gaps; report acceptance, held-out errors and independent image checks |
| 2 | Profile-based star centers and shared lens calibration | Compare against the current 21-frame pilot and 300-frame accepted set; measure corner shape, spatial errors and aperture flux |
| 3 | Optional supported residual spline | Beat the cubic on held-out regions without folds, unstable inverses or degraded stellar/meteor flux |
| 4 | Conservative background normalization | Reduce seams without changing protected foreground or erasing injected broad sky signal |
| 5 | Candidate-level review and sky-coordinate export | Preserve decisions across recomposition; verify each retained trail against its original exposure |

Keep the existing clean/meteor-retained outputs as fixed baselines. Use identical masks, source sets, linear development and rendering resolution when isolating algorithm changes; separately report the effect of recovering additional frames. Include artificial stars/trails with known centers and flux to avoid judging every change against one noisy reference. Proposed methods above are not yet implemented or benchmarked.

## License and source provenance

The README explicitly says no standalone license is provided and asks readers to confirm authorization before copying, distributing or commercial use. GitHub repository metadata also returned `license: null` during this review. Accordingly, this is an algorithm/workflow reference, not an approved dependency or source-code donor. Catalog data, optional detector weights and third-party libraries would each need their own artifact-specific terms checked before adoption. No author contact was made. [License notice in README](https://github.com/HG731GZ/HGMeteorTool#注意事项).

Observed source blob identifiers for traceability (the links above follow the mutable `main` branch):

| File | Git blob SHA |
| --- | --- |
| `fixed_camera_model.py` | `7b65f76528a1d17e3bc80f1cd5d85c113e60ff4a` |
| `frame_astrometry.py` | `8d0ec79f07dd148f1927caa3652ed1c5244e93eb` |
| `adjacent_alignment.py` | `1b18775ec1b39431a842feb5aaaabe0605f3a97f` |
| `psf/fitting.py` | `1f0ebb9cc4641a8eeaf0cc24b36c6e544f4517e1` |
| `alignment/interpolation.py` | `58fb3d5008001270364ae9ee4ff01566e97e7b3e` |
| `photometric/lowfreq/solver.py` | `c48953588cd579b756c615958e1c001e14a16fcd` |

Revisit the terms and pin a commit before any future integration decision. The repository contains multiple calibration paths; this review does not establish which path every GUI action currently selects.
