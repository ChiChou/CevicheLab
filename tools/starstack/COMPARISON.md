# Four upstream tools and a native Metal experiment

Tested 2026-10-28 on Apple M4, macOS 27.2 (26B123), Swift 6.4, Python 3.12.14. These are measured results on the supplied photographs, not upstream performance claims. Ceviche application code and deployment settings were not changed.

## Sample and outputs

The comparison uses **21 consecutive exposures, DSC00015–DSC00035**, from `/path/to/samples/nightsky/101MSDCF`, with DSC00025 as reference. This is the meteor interval used in the earlier experiment, **not a new benchmark of all 304 RAWs**. Camera: Sony ILCE-7RM3, 16 mm, f/4, ISO 2500, 15 seconds. Files remain untouched.

Apple Core Image developed each RAW to **1600 × 1068 scene-linear Float32 RGB**, with a common reference white balance. The converter saved TIFF, RGBA float buffers and a metadata manifest. The Python adapter wrote RGB FITS for Seiza. Detect Meteors read the original ARWs through its own RAW loader, producing **4000 × 2660** Bayer-binned luminance images. These paths use different RAW development, so detector pixel values are not directly comparable to the RGB stacks.

Actual image outputs, all with no generative reconstruction:

- [Native Metal result, 1280 pixels](output/comparison/previews/native-metal-1280.png)
- [All four upstream results](output/comparison/previews/four-upstreams-1280.png)
- [Reference / Seiza / Astroalign / native comparison](output/comparison/previews/stack-comparison-1280.png)
- [Meteor detail at matching source coordinates](output/comparison/previews/meteor-detail-1280.png)
- [Seiza alone](output/comparison/previews/seiza-1280.png), [Astroalign alone](output/comparison/previews/astroalign-1280.png)
- [tetra3 annotations](output/comparison/previews/tetra3-1280.png), [Detect Meteors diagnostic](output/comparison/previews/detect-meteors-1280.png)

All comparison RGB previews use the same linear-to-sRGB display conversion. Seiza and Astroalign previews include **our reference-foreground adapter**; the upstream-only RGB stacks are also saved in their result directories. Astroalign supplies alignment only; its clipped-mean integration is explicitly our adapter. Neither catalog identification nor meteor detection produces a photographic stack by itself.

## Direct upstream runs

| Tool actually executed | Result | Interpretation |
| --- | --- | --- |
| [Seiza](https://github.com/theatrus/seiza), wheel **0.46.0** | **21/21 accepted**, including reference; quadratic registration and integration ran on **Apple M4 / Metal** | Strongest complete stacking reference. A 1 GiB GPU budget initially fell back to CPU integration; the final 4 GiB run explicitly logged GPU accumulation. |
| [Astroalign](https://github.com/quatrope/astroalign), wheel **2.6.2** | **21/21 aligned**, 30–100 matched stars on nonreference images | Useful compact similarity-transform baseline. Our sky mask excludes ground during star detection. Similarity geometry is less flexible than wide-angle lens-aware models. |
| [tetra3](https://github.com/esa/tetra3), source revision below | First **350 × 350 crop solved**, **12 catalog matches** | RA **126.6165°**, Dec **5.6232°**, FOV **25.7444°**, reported residual **394.9 arcsec**. Identification works, but this is not a precision astrometric calibration of the full landscape. |
| [Detect Meteors](https://github.com/shin3tky/detect_meteors), **1.6.10**, source revision below | RAW input worked. Automatic parameters and full-image tuned parameters each flagged **20/20 pairs**. A conservative **sky ROI** plus measured threshold reduced this to **four candidate files** | Final files: DSC00024, 25, 26, 31. DSC00025 contains the known meteor. Adjacent differences can flag neighboring exposures for one event; four files do not imply four meteors. |

Seiza used `normalization=none`, `registration_model=quadratic`, 700 maximum stars, 40 triangle stars, maximum registration RMS 2 px, minimum integrated fraction 0.3, defects off, reference first. Its result list contains only the 20 nonreference frames; the adapter explicitly adds the accepted reference to the total.

Astroalign used `max_control_points=100`, `detection_sigma=5`, `min_area=3`, masked luminance for correspondence detection, and its actual `apply_transform` on RGB. Our adapter then used a median/MAD clipped mean and reference ground. It is not Astroalign's own stacking algorithm.

tetra3's supplied database covers 10–30° FOV. Feeding the entire 16 mm landscape would be inappropriate. The successful unwarped crop is `(x=625, y=110, width=350, height=350)` in the 1600-pixel reference. The approximate FOV prior came from an assumed 750-pixel focal length, not a solved pointing. `solve_from_image` requires a PIL image. The current source also calls removed `np.math`, so it ran in a separate **NumPy 1.26.4 / SciPy 1.14.1 / Astropy 6.1.7** environment; upstream source was not monkey-patched.

Detect Meteors' automatic threshold was 8 sensor ADU. A separate background region in the first two frames measured difference-noise MAD sigma **35.5824 ADU**; a five-sigma threshold rounded to **179 ADU**. This alone did not fix foreground contamination. The final polygon, in its binned RAW coordinates, was `40,40;3960,40;3960,900;3000,1700;40,2100`. Remaining settings: area 10, aspect ratio 3, line score 80, Hough threshold 10, minimum line length 15, maximum gap 5, two workers, aircraft-trail hook. No labeled dataset exists here for a precision/recall claim.

Recorded call times: Seiza final GPU **0.890 s**, separate CPU run **0.782 s**; Astroalign plus our integration **8.756 s**; tetra3 including database loading **1.292 s** (solve call **1.131 s**). These are different workflows and startup/cache conditions, not a controlled speed ranking. RAW conversion and Python imports are excluded. The Seiza CPU run was faster than the later GPU run on this small case; GPU use does not guarantee a total-workflow speedup.

## Native implementations: what was actually ported

New executable: **`nativebench`**, isolated inside this experimental Swift package. It has no remote Swift dependencies. Metal compilation and dispatch failures are explicit errors; it does not silently substitute CPU output for a failed GPU test.

| Reference | Native experiment implemented and exercised | Boundary |
| --- | --- | --- |
| Seiza's division of CPU geometry and GPU pixels | Metal inverse projective/cubic warp, bilinear sampling, validity masks, joint-luminance median/MAD rejection, whole-RGB averaging and protected ground | Independently implemented using our existing algorithm. This is **not a translation of Seiza's full integrator**, photometry or calibration pipeline. |
| Astroalign's pattern registration | Existing Swift star detector and robust registration, refitted on all 21 converted frames; resulting transforms feed Metal warp | Seeded from the earlier native 3200-pixel geometry, then independently matched and refitted at 1600. This does not benchmark a blind triangle search for every real frame. The package's synthetic missing-star/outlier test does exercise native pattern registration. |
| tetra3 | Native edge-ratio hash search against its default database, polar-decomposition attitude fit, brightness-limited catalog matching, mismatch check; separate Metal catalog projection test | Actual blind catalog search receives **unsolved measured centroids**, not upstream RA/Dec or matched IDs. Centroid extraction and database generation still come from tetra3. The simplified native solver lacks its continuous distortion/FOV refinement and full API. |
| Detect Meteors | Metal absolute difference, strict threshold, 3 × 3 erosion and dilation | Exact OpenCV preprocessing counterpart. **Hough voting and the aircraft hook were not ported.** The native photographic output uses our existing Swift connected-component/line-residual detector and measured-RGB restoration. |

The native stack refitted **21/21 frames**, with median frame held-out p95 error **0.458 px** and worst **0.533 px** at 1600 pixels. No cubic residual field passed model selection on these low-resolution refits; synthetic tests separately exercise that Metal branch. Higher-resolution analysis remains preferable for final photographic registration.

The native catalog subset found **18 correspondences**, including **nine outside the 15-star pattern-search pool**, in **0.0136 s of search**. Database loading and extraction are excluded. It estimated RA **126.7827°**, Dec **5.8237°**, FOV **25.7992°**, with **1.33 px RMS**. This coarser pointing differs from tetra3 by about **0.26°**; more matches do not establish better astrometric accuracy. It should remain a research diagnostic.

An initial count-only catalog acceptance rule falsely accepted a deterministic random-star control. The final implementation restricts matches to the brightest in-field catalog stars, requires six matches outside the search pool, and applies tetra3's database-corrected binomial mismatch approximation. The same negative control is now **rejected** after 2,719 tested rotations; the real crop still passes. This is one negative control, not a calibrated false-positive rate. Neither statistical approximation nor this single image establishes production reliability.

## Measured native GPU results

All Metal times below are host-observed **command submission plus completion wait**, not claimed device-only timestamps. The warp total includes the first dispatch. Fusion was repeated three times on the same resident input; report the median, not the fastest value. The CPU fusion baseline is straightforward, single-threaded release Swift, not an optimized parallel CPU library.

| Stage | CPU | Metal | Result |
| --- | ---: | ---: | --- |
| 21 inverse warps, 1600 × 1068 | 399.8 ms | 64.2 ms aggregate | **6.2×** in the measured processing scope; uploads excluded |
| 21-frame robust fusion | 843.0 ms | **10.27 ms median**; runs 13.78 / 10.27 / 8.71 ms | **82.1×** versus this single-threaded CPU reference |
| RAW-pair difference + opening, 4000 × 2660 | OpenCV **4.17 ms median** | **6.10 ms median** | GPU was slower for this small three-dispatch workload |
| Project 8,818 catalog stars | Swift **0.106 ms** | **0.222 ms median** | CPU is preferable for this small catalog operation |

Shader/device setup measured **56.0 ms** for the stack run. CPU star detection/registration measured **974 ms**. RAW development, segmentation, disk caching, image encoding, transient detection and preview generation are outside these stage timings. **No end-to-end 82× claim is justified.** Upload durations are recorded per frame in the benchmark JSON.

The experimental fusion kernel supports **3–64 temporal frames**, with all samples resident; the measured 21-frame RGBA cube is **574 MB decimal**. It explicitly rejects larger frame counts and checks Metal allocation limits. It is not the memory-bounded 304-frame/full-RAW production implementation proposed in the survey. Spatial tiling while retaining all temporal samples is the next scaling step.

## Numerical and photographic checks

- On identical GPU-warped inputs, **CPU and Metal fusion were pixel-identical**, maximum error **0**, including protected ground. The first implementation differed at rejection thresholds because of fused arithmetic; disabling contraction fixed this. Safe math alone did not suffice.
- Float32 GPU warp versus Double-coordinate CPU warp: RGB RMS **4.94e-7**, maximum **2.26e-4** in scene-linear units, with **one source-validity boundary pixel** differing across the 21 frames. Warp equality is therefore not claimed.
- Metal detector preprocessing versus OpenCV on DSC00024/25: **zero different pixels** across 10.64 million pixels. This verifies preprocessing, not meteor classification.
- Metal catalog projection versus CPU: maximum coordinate error **0.000061 px**.
- Seven synthetic GPU fusion cases cover constant input, an outlier, insufficient coverage, protected ground, soft masks, zeros, negative scene-linear values, and the **64-frame boundary**. A nonzero cubic-warp case passes with maximum RGB error **4.95e-6**.
- Existing Swift package: **7 tests passed**. Actual-sample geometry checks found no sampled fold or inverse failure; outputs are finite.
- Native output preserves **99.58%** of the known meteor's integrated residual relative to the clean stack, retaining measured RGB along the selected DSC00025 trail. Selection is explicit; the program does not claim an automatic meteor/satellite classifier.
- Native median star aperture flux ratio **0.973** and radius ratio **0.927**, using 446 isolated, unsaturated reference stars. These are image-space checks, not calibrated photometry.
- A common star-excluded high-frequency sky statistic falls by **4.67× Seiza**, **4.78× Astroalign+adapter**, **5.35× native**. Resampling correlates noise and can smooth structure: these are **not independent-pixel SNR gains or a quality ranking**.

## Reproduction and evidence

From the repository root, after installing the recorded environments:

```sh
swift build -c release --build-system native --package-path tools/starstack
tools/starstack/.build/release/nativebench export \
  tools/starstack/output/pilot-final-3200/report.json \
  tools/starstack/output/comparison/input1600 1600

tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/run_upstreams.py seiza
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/run_upstreams.py seiza --cpu
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/run_upstreams.py astroalign
tools/starstack/output/comparison/tetra-venv/bin/python tools/starstack/scripts/run_upstreams.py tetra3

tools/starstack/output/comparison/venv/bin/detect-meteors \
  --config tools/starstack/output/comparison/detect-sky-roi-config.json \
  --roi '40,40;3960,40;3960,900;3000,1700;40,2100' --debug-image --no-resume

tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/prepare_comparison_fixtures.py
tools/starstack/output/comparison/tetra-venv/bin/python tools/starstack/scripts/prepare_catalog_fixture.py
tools/starstack/.build/release/nativebench selftest tools/starstack/output/comparison
tools/starstack/.build/release/nativebench compare tools/starstack/output/comparison
tools/starstack/.build/release/nativebench catalog tools/starstack/output/comparison
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/measure.py tools/starstack/output/comparison/native-metal
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/comparison_outputs.py
```

These scripts deliberately target this local fixture and its existing pilot report/mask; they are not a general importer or GUI. The `raw-pilot` directory contains ordered symlinks to the 21 originals so the upstream detector's filename sorting follows capture order.

Evidence: [native timing/parity JSON](output/comparison/native-metal/benchmark.json), [native photographic metrics](output/comparison/native-metal/metrics.json), [synthetic checks](output/comparison/selftest.json), [native catalog](output/comparison/native-catalog/report.json), [negative catalog control](output/comparison/catalog-negative/native-catalog/report.json), [Seiza GPU trace](output/comparison/seiza-4g.log), [Astroalign report](output/comparison/astroalign/report.json), [tetra3 report](output/comparison/tetra3/report.json), [detector final log](output/comparison/detect-sky-roi.log), [OpenCV baseline](output/comparison/detector-fixture/report.json), [environment freeze](output/comparison/environment.lock.txt), [tetra3 environment](output/comparison/tetra-environment.lock.txt). Generated outputs and environments remain under ignored `output/`.

## License and revision record

- Seiza 0.46.0 wheel: [Apache-2.0 source](https://github.com/theatrus/seiza/blob/main/LICENSE). No Seiza source or bundled assets were copied into the native target.
- Astroalign 2.6.2 wheel: [MIT with retained embedded BSD RANSAC notice](https://github.com/quatrope/astroalign/blob/master/LICENSE.txt). Inspected source checkout `76077b2583601611f5f8f2d52be47ca481f77ab1` is a research checkout, not proof that this wheel was built from that commit. Native registration is the existing independent Swift implementation.
- tetra3 source **`f9fa2eb9a32a5efc529e2d86f0b59f35b1e9028d`**, Apache-2.0 and original Tetra MIT notice. The native hash/database conventions and projection equations are an adapted subset, explicitly attributed in `Catalog.swift`; the complete license is retained in [ThirdParty/tetra3-LICENSE.txt](ThirdParty/tetra3-LICENSE.txt). Its database is a local fixture, not bundled into the executable.
- Detect Meteors source **`a1d772a305825ea613ba916826f28a009837afc0`**, [Apache-2.0](https://github.com/shin3tky/detect_meteors/blob/a1d772a305825ea613ba916826f28a009837afc0/LICENSE) with [NOTICE](https://github.com/shin3tky/detect_meteors/blob/a1d772a305825ea613ba916826f28a009837afc0/NOTICE). Its source and notices remain together in the ignored upstream checkout. Generic Metal image operations were written independently.

This is local execution and an experimental subset port. Shipping upstream binaries, Python dependency trees or a star database requires retaining their own applicable notices/data terms. The previously generated sky mask comes from the existing SkyRemoval model, whose AGPL provenance remains documented in the earlier experiment. No new model weights were downloaded for this comparison.
