# Tenerife: joint geometry and CPU/Metal mean rerun

Run **2026-10-29**, macOS 27.2, Apple M4. Both five-frame Milky Way groups were processed at **7952 × 5304**. The new alignment does **not materially improve denoising over the previous mean**. The high-frequency sky statistic is slightly higher, by approximately 0.17% and 0.08%. Visual inspection of central stars, outer-field stars and terrain agrees: the previous and new means look nearly identical; both reduce noise relative to a single exposure, but residual color noise and original star elongation remain.

This is a standalone experiment. Application code and original RAWs are unchanged. The previous results remain intact.

## Full-resolution photographs

| Batch | New Metal JPEG | CPU JPEG | 16-bit sRGB TIFF | Native-pixel comparison |
| --- | --- | --- | --- | --- |
| 1: DSC02083–02087, 5 × 20 s | [JPEG](output/tenerife-joint-2026-10-29/group-1/mean-metal-fullres.jpg) | [JPEG](output/tenerife-joint-2026-10-29/group-1/mean-cpu-fullres.jpg) | [TIFF](output/tenerife-joint-2026-10-29/group-1/mean-fullres-srgb16.tiff) | [Single / previous / new, +2 EV](output/tenerife-joint-2026-10-29/group-1/comparison-4-100percent.jpg) |
| 2: DSC02161–02165, 5 × 15 s | [JPEG](output/tenerife-joint-2026-10-29/group-2/mean-metal-fullres.jpg) | [JPEG](output/tenerife-joint-2026-10-29/group-2/mean-cpu-fullres.jpg) | [TIFF](output/tenerife-joint-2026-10-29/group-2/mean-fullres-srgb16.tiff) | [Single / previous / new, +2 EV](output/tenerife-joint-2026-10-29/group-2/comparison-4-100percent.jpg) |

JPEGs use quality 95, 4:4:4 sampling and an sRGB ICC profile. The main photographs have the same 0 EV display transform as the previous output. They are neither downscaled nor cropped. Comparisons contain three unresized 800 × 600 crops: single reference, previous mean, new mean. Additional comparisons 1–3 show central stars at 0 EV, outer stars at 0 EV, and terrain at +3 EV. Exposure lifts apply equally to all three columns. Lossless PNG versions of the comparisons are saved alongside JPEGs.

`cpu.rgba` and `metal.rgba` retain unclipped scene-linear Float32 RGBA, little-endian, top row first, alpha 1. Display TIFF/JPEG exports clip to the sRGB range. These are diagnostic outputs rather than an aesthetically graded photograph.

## What changed

The [Bitterli article](https://benedikt-bitterli.me/astro/) motivates fitted star centers and shared multi-frame geometry; this implementation is independently written. It is **not a complete port** of that pipeline. No upstream source or new model weights were copied. See the [reference/license review and backend contract](MEAN-STACK-CPU-GPU.md).

1. Reuse the previous RAW development, existing AI sky masks and verified stellar correspondences. The bootstrap is the existing matcher; this run does not add a new DoG detector.
2. Fit native-resolution elliptical Gaussian star profiles plus a local background plane. Build tracks observed in at least three frames. Group 1 retains 1,109 tracks; group 2 retains 1,139.
3. Jointly fit shared focal length, two radial distortion coefficients, four frame rotations and latent reference star positions. Fix the middle frame's rotation and the principal point. Use robust least squares with bounded intrinsics. EXIF 14 mm initializes the focal prior. EXIF exposure-midpoint timing enters indirectly through the previous time-based fit that initializes and weakly constrains rotations; this new solver does not impose an exact sidereal trajectory.
4. Hold out every fifth spatially ordered track from the joint fit and residual fitting. Select an optional quadratic residual using another subset; it must improve p95 by 10%. That selection subset participates in the global camera fit, so only the final held-out tracks are excluded from both stages. Correspondence discovery itself used earlier registration, making this a conditional geometric check, not independent catalog astrometry.
5. Generate one reference-to-source map per frame, combining camera projection and the validated residual. Resample each image once with Lanczos4. Reuse the previous accepted ground translations and refined AI skyline blend to isolate the sky-alignment change.
6. Take equal arithmetic means of valid sky and terrain observations in linear light. Keep the reference where fewer than three contributions survive. No light-pollution subtraction, sharpening, spatial denoiser or intensity-based rejection is added.

The shared fitted intrinsics are an effective description of already-developed images, not a calibrated measurement of the lens. Five short-sequence images weakly constrain distortion and focal length independently.

## Measurements

| Measurement | Batch 1 | Batch 2 |
| --- | --- | --- |
| Fitted effective focal length | 3220.16 px | 3204.14 px |
| Final held-out p95 across four non-reference frames | 0.474–0.538 px | 0.312–0.369 px |
| Confident reference sky receiving all five frames | 98.66% | 99.14% |
| Previous sky high-frequency reduction vs single | 1.5757× | 1.6397× |
| New sky high-frequency reduction vs single | 1.5731× | 1.6384× |
| New ground high-frequency reduction vs single | 1.9441× | 2.0004× |
| Isolated star apertures | 955 | 992 |
| New median star flux / single-reference flux | 1.00025 | 1.00272 |
| New median star radius / single-reference radius | 0.98327 | 0.99250 |
| CPU/Metal maximum absolute linear RGB difference | 3.58e-7 | 3.58e-7 |
| CPU/Metal RMS linear RGB difference | 3.17e-9 | 2.71e-9 |
| Sampled minimum warp Jacobian determinant | 0.9658 | 0.9881 |

The noise proxy is luminance Laplacian MAD at identical sampled pixels with five-frame sky coverage in both results. It includes scene texture and correlated resampling noise; it is **not a calibrated SNR measurement**. The differences do not establish a quality gain. Ground geometry is unchanged, so its result should be unchanged apart from floating-point error, as observed.

Star measurements use identical 9-pixel apertures and 12–18-pixel background annuli across the three images. They cover isolated registration stars, not an unsaturated-only sample or faint-star completeness. This comparison uses separate width/height proxy-coordinate scaling; minor differences from the older report's aperture measurements are expected. Old/new geometry validation sets and center estimators also differ, so their p95 values are not a controlled head-to-head score.

Full image scans verify finite RGB and CPU/Metal parity. Saved JPEG dimensions and ICC presence, TIFF dimensions/depth/ICC and sampled display values are checked. A sampled grid shows no warp foldovers; this is not a proof for every coordinate. Native-pixel visual checks cover central and outer stars and lifted terrain. They show residual mottled noise and elongated stars in both means, without an obvious improvement from joint fitting.

The release build and all seven existing native geometry, timing and transient tests passed. The new synthetic CPU/Metal test also passed. These checks establish implementation consistency, not a denoising quality gain.

## CPU and GPU are both retained

- [joint_mean_geometry.py](scripts/joint_mean_geometry.py): CPU double-precision geometry solver.
- [joint_mean_render.py](scripts/joint_mean_render.py): CPU OpenCV Lanczos4 warp and mean; writes shared coordinate/validity maps.
- [meanmetal/main.swift](Sources/meanmetal/main.swift) and [Mean.metal](Sources/meanmetal/Mean.metal): native Metal warp and mean, with explicit failure if Metal is unavailable. No CPU fallback is presented as a GPU result.
- [test_joint_mean.py](scripts/test_joint_mean.py): radial inversion, identity geometry and odd-sized masked CPU/Metal sampling test, including bright values above 1. Synthetic maximum RGB difference: 5.96e-8.
- [inspect_joint_mean.py](scripts/inspect_joint_mean.py): full-image parity, matched noise/star measurements and exports.

The Metal renderer uses the same OpenCV 32-phase Lanczos4 coefficients and Float32 maps as the CPU renderer. The global fit and map construction remain on CPU. Framewise buffers keep all source frames from being resident together, but maps consume about 3.4 GB per batch; this prototype is not yet a bounded tile-streaming implementation suitable for arbitrary sensor sizes.

Measured CPU map preparation plus rendering took **42.63 / 43.76 s**. Metal rendering from prepared maps, including file reads, allocations, shader setup and output writing, took **13.76 / 13.63 s**; GPU commands alone took **0.347 / 0.372 s**. These scopes differ, so the numbers are **not an end-to-end speedup claim**. Geometry fitting with cached star tracks took approximately **40 / 41 s**, excluding original PSF localization, RAW decode and segmentation. Exports are outside those render timings.

## Reproduce

Requires the preserved [previous experiment caches](TENERIFE-MEAN.md), Python with NumPy/SciPy/OpenCV/Pillow/tifffile, and the macOS 27 toolchain. Commands below run from the repository root; repeat for batch 2 by changing both group paths.

```sh
swift build -c release --build-system native --package-path tools/starstack
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/test_joint_mean.py

python tools/starstack/scripts/joint_mean_geometry.py \
  tools/starstack/output/tenerife-mean-2026-10-29/group-1 \
  tools/starstack/output/tenerife-joint-2026-10-29/group-1
python tools/starstack/scripts/joint_mean_render.py \
  tools/starstack/output/tenerife-mean-2026-10-29/group-1 \
  tools/starstack/output/tenerife-joint-2026-10-29/group-1
tools/starstack/.build/release/meanmetal \
  tools/starstack/output/tenerife-joint-2026-10-29/group-1/render.json \
  tools/starstack/output/tenerife-joint-2026-10-29/group-1/metal.rgba
python tools/starstack/scripts/inspect_joint_mean.py \
  tools/starstack/output/tenerife-mean-2026-10-29/group-1 \
  tools/starstack/output/tenerife-joint-2026-10-29/group-1
```

Use the experiment virtual environment for all Python commands. The geometry script reuses `tracks.npz` when present; use a fresh output folder when inputs or PSF localization change. These CLIs intentionally operate on five-frame cached fixtures; they are not a new general RAW importer.

## Interpretation for the next experiment

The previous alignment was already subpixel. More elaborate registration alone does not address the remaining noise in these samples. Both paths still compute an ordinary five-image mean. Additional useful experiments are sensor-domain noise/calibration analysis and a separately named noise-aware reconstruction, validated with injected faint stars and diffuse-structure tests. They should be compared to this preserved plain mean, rather than replacing it with visually smoother output and assuming stars survived. Registration cannot undo the blur accumulated inside each original 15–20-second exposure.
