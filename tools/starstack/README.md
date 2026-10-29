# StarStack — native macOS meteor-shower experiment

A standalone, headless Swift tool for developing camera RAWs, separating the usable sky from foreground, aligning stellar motion, stacking the sky, and restoring recorded meteor candidates. It does not modify Ceviche's editor or its deployment settings.

The [four-tool comparison and native Metal benchmark](COMPARISON.md) records actual Seiza, Astroalign, tetra3 and Detect Meteors runs, the new `nativebench` executable, partial-port boundaries, measured timings, numerical checks and downscaled photographs.

The [aurora star-trail trial](AURORA-TRAILS.md) compares maximum stacks from all 172 RAWs against heuristic night-sky filtering (162 kept), using the existing AI sky mask and identical display settings.

The [Tenerife mean-denoise trial](TENERIFE-MEAN.md) delivers two five-frame **7952 × 5304** stacks, using EXIF 14 mm/time-informed sky geometry, the existing AI mask, and independently aligned terrain. It includes full-resolution 16-bit TIFF references and results. The pipeline below describes the earlier meteor experiment; the Tenerife note documents its separate mean-fusion path.

The [mean-stack algorithm and CPU/Metal development contract](MEAN-STACK-CPU-GPU.md) adds Benedikt Bitterli's Star Stacker reference and the requirement to **retain both CPU and GPU implementations**. The [joint-fit Tenerife rerun](TENERIFE-JOINT-MEAN.md) now provides CPU and Metal Lanczos mean renderers, full-resolution JPEGs and numerical parity checks. It finds no material denoising improvement over the previous mean; existing paths are preserved.

**Experimental target: macOS 27+, explicitly requested for this experiment.** This is separate from the product research's proposed macOS 15 baseline. Tested on macOS 27.2 with Apple's Swift 6.4 toolchain. No claim of compatibility testing on older systems.

## Build and run

```sh
swift build -c release --build-system native --package-path tools/starstack
swift test -c release --build-system native --package-path tools/starstack

tools/starstack/.build/release/starstack survey \
  /path/to/RAWs tools/starstack/output/survey

tools/starstack/.build/release/starstack stack \
  /path/to/RAWs tools/starstack/output/run \
  --sky-model /path/to/SkyRemoval.mlmodelc \
  --count 304 --edge 1280 --analysis-edge 3200
```

`--build-system native` is the SwiftPM build engine used for these experiments; this toolchain marks that engine deprecated. The package has no remote Swift dependencies. Core Image and Core ML need access to the Mac's graphics services: a restrictive execution sandbox can make rendering fail even when compilation succeeds.

Use a fresh output directory per experiment. The tool writes generated files there and reads, but never writes, the source RAWs. `--from DSC00015.ARW --count 21 --edge 3200` selects the pilot interval in the supplied sequence. `--reference INDEX` is a zero-based index within the selected, chronologically ordered interval; otherwise the middle exposure is the reference. The output edge can be larger than the analysis setting; analysis then uses that larger size. The meteor experiments validate 1280- and 3200-pixel outputs; the subsequent Tenerife mean experiment separately validates native 42 MP exports.

The model is the **existing Ceviche-converted SkyRemoval model**, not a newly fetched checkpoint. See [model provenance](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/MODELS.md), [conversion](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/convert_sky.py), and [model license](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/licenses/SkyRemoval-Model-LICENSE). Pass a compiled `.mlmodelc` directory explicitly. This tool does not download models. In the local experiment, the existing model was at `/path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc`.

## Pipeline

1. Read metadata with ImageIO. Sort by `DateTimeOriginal`, fractional seconds and recorded timezone offset where present. Keep the camera clock interpretation explicit. The supplied sequence wraps from `DSC09999` to `DSC00001`, so filename ordering is incorrect.
2. Develop RAWs with `CIRAWFilter` into extended linear sRGB Float32. Share the reference white balance, disable optional tone mapping, sharpening and noise reduction, and request native lens corrections where supported. The embedded JPEG is used only for contact-sheet reconnaissance.
3. Run the existing SkyRemoval network through Core ML on a brightness-normalized proxy. Treat confidence as a class probability, not optical transparency. Keep a conservative, scale-dependent uncertainty band around the skyline from the reference exposure; model resolution cannot accurately matte distant lights and thin trees.
4. Find point-like sources using local background subtraction, local noise estimates, peak centroids and second moments. Reject isolated hot pixels and strongly elongated features. Retain spatial coverage rather than letting one cluster dominate.
5. Work outward from the reference in time. Predict the next transform from two accepted neighbors and actual EXIF exposure-midpoint intervals. Verify that prediction with new image correspondences; fall back to triangle-pattern matching when needed. The 92-second initial gap in the supplied sequence is a useful timing test.
6. Fit a projective transform, then evaluate a regularized cubic residual field for distortion left by the lens model. Enable the residual only if a deterministic held-out subset improves. Fit one smooth field, not a separate warp for each star. Invert the composed mapping numerically and sample source pixels into the common epoch. Never treat a forward displacement field as its own inverse.
7. Keep star analysis at 3200 pixels by default, even for smaller outputs. Scale geometry with the pixel-center convention. Direct star detection at 1280 pixels proved materially less reliable on this dataset.
8. Stream aligned frames to Float32 caches and fuse in bounded row strips with median/MAD rejection. Track source validity so ground cannot leak into the sky warp. Keep the foreground and the unresolved boundary from the reference. This experiment does **not** denoise the ground.
9. Detect positive, locally background-subtracted linear residuals in each aligned source. Exclude invalid borders and star cores, merge nearby collinear fragments, and identify tracks persisting through at least three exposures. Restore measured RGB samples along selected candidates; do not synthesize a trail or take independent RGB-channel maxima.
10. Separately fit a shared, EXIF-driven 3D rotation and effective focal length. Report its inferred angular speed and held-out error against the sidereal reference. This diagnostic is not blindly substituted for the image-validated distortion warp.

The geometric holdout tests evaluate localization conditional on accepted correspondences; they are not an independent astrometric catalog validation. A global homography plus residual field is an empirical lens-motion approximation. The physical diagnostic is useful precisely because it can disagree with that approximation.

## Meteor selection and review

The [MetDetPy CLI experiment](METDETPY-EXPERIMENT.md) now runs learned detection, native EXIF-seeded morphing/background fusion and measured-pixel meteor compositing. It processed all 304 sample exposures and selected 16 trail candidates from 300 aligned frames. The earlier [source review](METDETPY-REVIEW.md) records checkpoint provenance questions that still apply to redistribution.

`--streak-policy isolated` is the default: retain isolated candidates and omit tracks continuing across three or more exposures. `all` retains every detected linear transient; `none` produces the clean stack only. A persistent track is an aircraft/satellite **candidate**, not a definitive classification. Likewise an isolated streak is not automatically proven to be a meteor.

For explicit source selection, use `--keep-frames DSC00025.ARW,DSC09965.ARW`. This selects detected candidates from those frames, overriding the automatic policy. It does not fabricate detections or replace a whole sky with the selected frame.

Review and recompose from aligned caches without decoding RAWs or rerunning Core ML:

```sh
tools/starstack/.build/release/starstack recompose \
  tools/starstack/output/run tools/starstack/output/reviewed \
  --streak-policy isolated

tools/starstack/.build/release/starstack recompose \
  tools/starstack/output/run tools/starstack/output/chosen \
  --keep-frames DSC00025.ARW
```

`report.json` records every source, accepted/rejected alignment, matched coordinates, transforms, model selection, timing diagnostic, candidate geometry, temporal classification and selected state. Cache paths refer to the original run; retain its `aligned/` directory for recomposition. A recomposed report retains the original alignment algorithm identifier, because recomposition does not refit geometry.

## Outputs

| File | Meaning |
| --- | --- |
| `reference.png`, `reference.rgba` | Shared reference and the exact Float32 baseline for numerical comparisons |
| `sky-mask.png`, `sky-mask.f32` | Conservative sky contribution mask; the unstacked reference boundary is intentional |
| `coverage.png` | Fraction of accepted frames providing geometrically valid sky evidence |
| `aligned/*.rgba` | Reference-space Float32 RGBA sources; alpha zero means no usable source sky |
| `stack-clean.tiff`, `.png`, `.rgba` | Robust stack before transient restoration |
| `stack-meteors.tiff`, `.png`, `.rgba` | Selected-candidate composite |
| `report.json` | Machine-readable provenance and diagnostics |

TIFF masters are linear Float32; PNGs are sRGB previews. Raw `.rgba` and `.f32` files are little-endian Float32, top row first, with dimensions in the report. Output size is explicit. Caches can consume several GB for hundreds of frames; bounded RAM does not imply bounded disk usage.

## Validation

The Swift tests cover projective fitting/inversion, missing stars and false correspondences, hot-pixel rejection, smooth-warp inversion and scale conversion, a measured synthetic meteor near an invalid boundary, persistent-track grouping, and recovery of a known sidereal rotation from irregular capture times.

`scripts/measure.py RUN_DIRECTORY` independently reads Float32 outputs and reports ground invariance, finite values, held-out star residuals, isolated-star aperture flux/width, a background high-frequency noise statistic, and residual-flux preservation of the supplied `DSC00025.ARW` meteor. This optional analysis script requires NumPy; the Swift executable does not use Python.

The high-frequency statistic is **not** a calibrated SNR claim: interpolation introduces pixel correlations. Aperture ratios are relative to one noisy reference, and long capture spans can include real atmospheric brightness changes. See [experiment results](EXPERIMENTS.md) for measured outcomes and limitations.

## Limits and evidence

See the subsequent [HGMeteorTool source review](HGMETEORTOOL-REVIEW.md) for shared camera calibration, spherical matching, PSF fitting, and proposed comparison experiments. Its code is not imported; its licensing remains unresolved.

The broader [repository survey](REPOSITORY-SURVEY.md) compares ten astronomy projects, checks license evidence and GPU scope, and specifies a separate Swift/Metal benchmark experiment.

- Supported experiment: one fixed-camera, constant-exposure Sony RAW sequence with substantial overlap. General camera movement, mixed exposure settings, clouds, focus changes, calibration frames and other camera models are not validated.
- The conservative boundary avoids double trees and city lights by preserving reference pixels. It is not a full-resolution astronomical sky matte, and near-horizon meteors may require better masking.
- Existing intra-exposure star trails, coma and defocus remain. Inter-frame registration cannot undo the 15-second exposure's blur.
- The model's training domain does not guarantee night-sky segmentation. Its mask and the final composite require inspection. No segmentation-accuracy benchmark is claimed.
- No generated stars, deconvolution, generative filling, optical-flow hallucination, third-party RAW decoder, or external model download is involved.

Primary references: [Apple CIRAWFilter](https://developer.apple.com/documentation/coreimage/cirawfilter), [Apple linear-space RAW hook](https://developer.apple.com/documentation/coreimage/cirawfilter/linearspacefilter), [Siril's registration models and single-resampling distortion composition](https://siril.readthedocs.io/en/stable/preprocessing/registration.html), and [OpenDroneMap SkyRemoval](https://github.com/OpenDroneMap/SkyRemoval). Siril documentation informed the geometry choice; its implementation is not copied. The code is part of Ceviche under the repository's [AGPL license](../../LICENSE).
