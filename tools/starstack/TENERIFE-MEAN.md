# Tenerife: full-resolution five-frame mean denoise

Experiment **2026-10-29**, using the photographer's `/path/to/samples/tenerifie/` folder. Application code and original RAW/XMP/ACR files are unchanged. Sidecar edits are not applied. This is a standalone experiment on macOS 27.2.

## Inputs and outputs

Both groups are Sony ILCE-7RM3, **7952 × 5304**, Sony **FE 14mm F1.8 GM**, EXIF focal length and 35mm-equivalent focal length **14 mm**, **f/2, ISO 3200**. The middle exposure defines framing and white balance.

| Group | Five inputs | Exposure per frame | Camera-local timestamps | Reference |
| --- | --- | --- | --- | --- |
| 1 | DSC02083–DSC02087.ARW | 20 s | 2024-07-05 22:52:23, 22:53:59, 22:54:19, 22:54:39, 22:55:00 | DSC02085 |
| 2 | DSC02161–DSC02165.ARW | 15 s | 2024-07-06 00:25:32, 00:25:48, 00:26:04, 00:26:20, 00:26:36 | DSC02163 |

No timezone was recorded; these times are not asserted to be UTC. Group 1's initial 96-second gap is used explicitly, rather than assuming uniform intervals.

All deliverables retain **7952 × 5304 source pixels**, with no resize or crop. The recommended files are the ICC-tagged **16-bit sRGB TIFFs**, approximately 241 MiB each. References use exactly the same development and display transform as the means.

| Group | Mean | Single-frame reference | Full-resolution PNG alternative |
| --- | --- | --- | --- |
| 1 | [16-bit TIFF](output/tenerife-mean-2026-10-29/group-1/mean-fullres-srgb16.tiff) | [16-bit TIFF](output/tenerife-mean-2026-10-29/group-1/reference-fullres-srgb16.tiff) | [Mean PNG](output/tenerife-mean-2026-10-29/group-1/mean-fullres.png) |
| 2 | [16-bit TIFF](output/tenerife-mean-2026-10-29/group-2/mean-fullres-srgb16.tiff) | [16-bit TIFF](output/tenerife-mean-2026-10-29/group-2/reference-fullres-srgb16.tiff) | [Mean PNG](output/tenerife-mean-2026-10-29/group-2/mean-fullres.png) |

Each directory also includes `mean-fullres-linear.tiff` and `reference-fullres-linear.tiff`: 32-bit floating-point, extended linear sRGB masters, approximately 483 MiB each. These retain negative interpolation undershoots and values above one; they need a color-managed linear workflow. The display TIFFs/PNGs clip to the sRGB display range. No extra exposure lift, sharpening, learned restoration or generated stars is applied.

The three `crop-*-100percent.png` comparisons per group are **unresized native-pixel crops**, reference left and mean right. The terrain crop alone applies +3 EV equally to both sides to expose shadow noise. They are supplementary inspection files, not substitutes for the full-resolution outputs.

## Algorithm

1. Decode every RAW at native resolution using Apple's Core Image RAW pipeline, shared reference white balance and extended linear sRGB. Request supported lens corrections; disable optional sharpening, tone boost and denoise. Develop the RAW, not its embedded preview.
2. Reuse Ceviche's existing **SkyRemoval Core ML model**. Run inference on a proxy; refine its boundary with the native-resolution blue-channel guide. The model's existing provenance and license are recorded in [the model ledger](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/MODELS.md).
3. Obtain initial stellar correspondences at 3200 pixels. Refine matched centroids in native pixels using background-plane subtraction and iterative weighted centroids. There are roughly 1064–1125 accepted correspondences per non-reference frame.
4. Use EXIF **14 mm equivalent focal length as a numerical prior**, giving an initial focal length of 3092.44 pixels, and actual exposure-midpoint time offsets. Fit a shared 3D angular velocity and effective focal length; project rays through `K R(delta-time) K^-1`. This handles wide-field perspective instead of assuming stars share one translation.
5. Evaluate smooth quadratic/cubic residual fields for remaining lens/camera deviations. Reserve every fifth spatially sorted correspondence when fitting; select a field only when validation p95 improves by at least 10%. Refit the selected field on all matches. All eight frames selected quadratic residuals. Invert the composed transform numerically and resample each source once with float Lanczos.
6. Align terrain separately using translation ECC, masked to ground. Verify forward/reverse agreement below 0.25 native pixels, both correlation scores above 0.5 and translation below 8 pixels. All five frames in each group participate in terrain averaging.
7. Take an **equal-weight arithmetic mean in linear light**, separately for sky and terrain. No intensity-based sample rejection or extra denoiser. Reject only geometrically invalid or wrong-region contributions; fewer than three valid contributors falls back to the reference. Blend the two components at the refined boundary.

Sky confidence is a classification score, not optical opacity. Initial inspection exposed an overly strict 0.98 source cutoff that left group 2's outer sky mostly unstacked. The final policy uses sky probability >0.8 and ground <0.2, with a separate three-analysis-pixel erosion around source boundaries. Reference probabilities are mapped through smoothstep over 0.2–0.8 before guided refinement. This preserves full sky contribution in confident corners while keeping an uncertainty band at the skyline. Thresholds remain experimental; the source masks and coverage must be inspected on other sessions.

## Geometry checks

| Measurement | Group 1 | Group 2 |
| --- | --- | --- |
| Native-pixel validation p95, range across four frames | 0.356–0.534 px | 0.292–0.351 px |
| Effective focal length | 3334.03 px | 3339.47 px |
| Fitted angular speed | 15.037 arcsec/s | 14.470 arcsec/s |
| Sampled minimum forward-map Jacobian determinant | 0.9668 | 0.9902 |
| Sampled forward/inverse round trip | <0.000001 px | <0.000001 px |

Group 1's inferred speed is close to the sidereal value. Group 2's disagreement demonstrates that this is an empirical wide-field fit with lens/motion residuals, not calibrated astrometry. EXIF focal length constrains the fit but does not provide full camera intrinsics. Effective focal length may absorb lens correction/crop and other modeling error; it does not establish the lens's true focal length.

Validation stars also select residual complexity, and initial correspondence selection used image registration. These are conditional localization/model-selection measurements, not an untouched independent test set or astrometric catalog validation. The final transforms are refitted on all accepted matches. Foldover and inverse checks sample a grid rather than proving global invertibility.

## Final image checks

| Measurement | Group 1 | Group 2 |
| --- | --- | --- |
| Confident reference-sky pixels receiving all five frames | 98.65% | 99.09% |
| Sky high-frequency statistic reduction | 1.576× | 1.640× |
| Ground high-frequency statistic reduction | 1.944× | 2.000× |
| Isolated stars measured | 955 | 992 |
| Median mean/reference aperture-flux ratio | 1.00035 | 1.00248 |
| Aperture-flux ratio p10–p90 | 0.9288–1.0727 | 0.9659–1.0427 |
| Median star-radius ratio | 0.9857 | 0.9927 |

The noise statistic is a sampled luminance Laplacian MAD, measured on native pixels. It includes scene detail and correlated interpolation noise; **it is not a calibrated SNR improvement**. Aperture measurements use isolated registration stars and the noisy reference, not an unsaturated-only sample or a faint-star completeness benchmark. Reported radii use positive background-subtracted weights, which can change as noise falls.

Inspection covered unresized central, outer-field and terrain crops. The corrected outer-field crop receives all five observations in both groups. Existing stellar elongation remains, with less mottled/color noise; the terrain comparison shows reduced shadow noise. Full-resolution TIFF/PNG dimensions, 16-bit depth, TIFF ICC presence and sampled display values were verified. Linear masters are Float32 RGB. The boundary and image margins may still fall back to the reference.

## Reproduce

```sh
swift build -c release --build-system native --package-path tools/starstack
tools/starstack/.build/release/nativebench mean-export \
  /path/to/samples/tenerifie \
  tools/starstack/output/tenerife-mean-2026-10-29 \
  /path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc

python tools/starstack/scripts/fullres_mean.py tools/starstack/output/tenerife-mean-2026-10-29/group-1
python tools/starstack/scripts/fullres_mean.py tools/starstack/output/tenerife-mean-2026-10-29/group-2
python tools/starstack/scripts/inspect_fullres_mean.py tools/starstack/output/tenerife-mean-2026-10-29/group-1
python tools/starstack/scripts/inspect_fullres_mean.py tools/starstack/output/tenerife-mean-2026-10-29/group-2
```

Python requires NumPy, SciPy, OpenCV, tifffile and Pillow; the existing experiment environment is `output/comparison/venv`. `mean-export` deliberately expects two five-frame groups; the renderer asserts this sample's native dimensions. This is a reproducible sample program, not a general importer. Core Image/Core ML use native Apple frameworks; full-resolution fitting and fusion currently run in Python/NumPy/OpenCV on CPU. This turn does not complete a native Metal port of that new fusion path.

`manifest.json` records metadata and initial correspondences; `geometry.json`/`result.json` record transformations, validation errors, terrain checks and coverage. `quality.json` records independent output inspection. Full-resolution caches consume several gigabytes. The existing seven Swift geometry/temporal/transient tests pass; image-specific validation is additional to those tests.

## Limits and next experiments

Follow-up: [Bitterli reference and CPU/Metal development contract](MEAN-STACK-CPU-GPU.md) specifies global geometry refinement and maintained CPU/GPU paths. Preserve this experiment as the numerical baseline when developing the native versions.

Within-exposure star trails, coma and defocus remain; inter-frame registration cannot reverse the original 15–20 second blur. Five-frame means also retain transient trails/hot-pixel contributions unless an additional explicit rejection policy is selected. Terrain noise and sky noise have different spatial correlations after resampling.

Measure faint-star completeness with injected sources and independent reference data before claiming preservation of all stars. Add sensor-domain saturation checks, dark/flat calibration and a camera noise model before variance-weighted stacking. Test more skyline structures and mask stability; conservative fallback intentionally leaves some boundary pixels less denoised. A fully native implementation should then reproduce this floating-point reference within a stated error tolerance.

For genuine illumination changes across a session, see the separate [day/night transition design](../../docs/research/photography-workflows-2026-10/day-night-transition.md). This constant-setting five-frame trial does not implement that transition decomposition.
