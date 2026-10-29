# Meteor-shower experiment — 2026-10-28

## Scope and reproducibility

This is a standalone macOS 27+ experiment, per the user's latest platform instruction. It leaves the editor and product deployment target untouched. Build and CLI instructions, model provenance, and algorithm details are in [README.md](README.md).

Input: `/path/to/samples/nightsky/101MSDCF`, 304 Sony ARW files, 7952 × 5304 pixels. Inspected metadata records 15-second exposures, ISO 2500, f/4 and 16 mm. Camera-clock span is 2021-12-14 02:28:10–03:53:35, or 85m25s. No recorded timezone is assumed to be UTC. The filename counter wraps at DSC09999; sort by EXIF, not filename. The initial DSC09884→DSC09886 gap is 92 seconds, much longer than the usual cadence.

Native development uses `CIRAWFilter`, ImageIO, Core Image and Core ML. The existing, locally compiled Ceviche SkyRemoval model was used under its documented AGPL-3.0 license; no weights were downloaded. Registration and fusion are implemented in Swift. NumPy is used only for independent measurement. Tested locally with macOS 27.2 / Swift 6.4.

The source RAWs were read only. Outputs and caches are ignored by Git under `output/`. Keep the original run's aligned caches if you want to recompose its transient candidates.

## Final measured results

| Measurement | Short pilot | Full capture span |
| --- | ---: | ---: |
| Sources requested / aligned | 21 / 21 | 304 / 300 |
| Output dimensions | 3200 × 2135 | 1280 × 854 |
| Star-analysis width | 3200 | 3200 |
| Reference | DSC00025 | DSC00038 |
| Frames using smooth residual morph | 3 | 283 |
| Median of frame held-out p95 residuals, output pixels | 0.370 | 0.281 |
| Worst accepted frame held-out p95, output pixels | 0.759 | 0.837 |
| Background high-frequency statistic reduction | 5.93× | 8.90× |
| Isolated stars measured | 565 | 342 |
| Median star aperture-flux ratio versus reference | 0.965 | 0.916 |
| Median star radius ratio versus reference | 1.029 | 0.936 |
| DSC00025 meteor residual-flux ratio | 0.991 | 1.001 |
| Detected / selected streak candidates | 1 / 1 | 34 / 14 |
| Persistent-track detections omitted | 0 | 20 |
| Maximum change in protected ground Float32 pixels | 0 | 0 |
| All output values finite | yes | yes |

The pilot is DSC00015 through DSC00035, spanning 334 seconds. Its 3200-pixel result is the stronger test of detailed meteor preservation. The full run demonstrates registration over a much longer interval, with a lower-resolution rendered output. Pixel errors across these columns therefore cannot be compared without scaling: the full run's median residual is approximately 0.702 pixels at its 3200-pixel analysis scale.

Noise reduction here means a masked, robust high-frequency statistic, **not** calibrated SNR or proof of independent samples. Resampling correlates pixels. Aperture measurements use the same reference coordinates and a local annular background; their reference is a noisy image, not a calibrated stellar flux standard. The full stack's roughly 8.4% median aperture-flux loss remains a limitation, potentially involving clipping, resampling, source selection and real brightness variation over the capture. The smaller measured radius is not proof of recovered optical detail.

Meteor retention measures signed luminance residual relative to the clean stack inside the detected line footprint. It does not measure every faint trail pixel or establish detector recall. The 1.001 ratio in the long run is numerical/measurement variation, not recovered additional meteor energy. Multiple candidates are composited into the reference sky epoch; this is a time-integrated presentation, not a single instant.

### Local artifacts

- [Full composite PNG](output/full-reviewed-1280/stack-meteors.png) and [linear Float32 TIFF](output/full-reviewed-1280/stack-meteors.tiff).
- [Reference / clean / selected-candidate comparison](output/full-reviewed-1280/comparison.png), with identical top-right crops at 2× nearest-neighbor scale. Corner star elongation remains visible; the method does not remove intra-exposure motion or optical aberrations.
- [Full report](output/full-reviewed-1280/report.json) and [full numerical measurements](output/full-reviewed-1280/metrics.json).
- [Pilot composite PNG](output/pilot-reviewed-3200/stack-meteors.png), [pilot TIFF](output/pilot-reviewed-3200/stack-meteors.tiff), and [pilot measurements](output/pilot-reviewed-3200/metrics.json).
- [Full-run sky mask](output/full-exif-1280/sky-mask.png) and [coverage](output/full-exif-1280/coverage.png).

The full geometry/fusion run is `full-exif-1280`; `full-reviewed-1280` reuses that run's caches and applies the final transient grouping and selection. Similarly, `pilot-reviewed-3200` reuses `pilot-final-3200`. Recomposed directories contain the final composite and numerical baselines; reference previews, coverage and clean TIFFs remain in the originating run.

## What the experiments changed

1. A strict sky probability threshold produced holes and false linear residuals. Binary classification followed by conservative erosion and a feathered transition was substantially more useful. A pilot without the uncertainty band produced 96 candidates, dominated by skyline artifacts. The final mask keeps the skyline and ground from the reference, rather than claiming accurate night-time semantic matting.
2. Direct matching to the central reference with a homography accepted only 209/304 frames in the first full-span trial. Tracking outward from the reference and validating a smooth cubic residual field improved acceptance substantially.
3. A lower-resolution tracking trial accepted 303/304, but its median frame held-out p95 was about 1.20 output pixels. Keeping star analysis at 3200 pixels improved the final full run to 0.281 output pixels. Acceptance count alone is an inadequate objective.
4. EXIF exposure midpoints are used in the actual short-interval transform predictor, not just added to a report. The 92-second gap now aligns. A new image must still pass star correspondence and held-out residual checks; EXIF cannot rescue an unverified match.
5. Restoring every line restored the obvious persistent aircraft-like track too. Grouping aligned candidates across neighboring exposures now excludes 20 persistent detections in this sequence and retains 14 isolated candidates. This is a heuristic, not a meteor classifier with measured precision/recall. `--keep-frames` allows explicit review decisions.

The final four sources, DSC00186–DSC00189, are excluded. DSC00186 fails a 2.5-analysis-pixel held-out threshold with 4.81 pixels. The next three fail bootstrap matching with only 9, 8 and 11 inliers. Losing the immediately adjacent accepted seed makes those later frames harder to recover. A future recovery pass could search farther back for reliable seeds; this experiment records the failures rather than weakening the quality threshold.

## Geometry and timing audit

An independent NumPy evaluation samples a 33 × 23 grid for every accepted warp. No sampled Jacobian is negative: the minimum determinant is 0.961 in the pilot and 0.598 in the long run. The worst five-iteration inverse round-trip error in usable sky is approximately 1.1e-11 and 0.000785 output pixels respectively. These checks support the tested mappings; they are not a mathematical proof of global invertibility.

The long run has a 0.0339-pixel worst round-trip residual when including all extrapolated corners, including points outside the usable sky/source domain. That initially failed an all-corner 0.01-pixel check. The measurement now reports both domains separately and asserts the tolerance on the domain actually eligible for rendering. The unused-corner result remains visible in `metrics.json`.

The separate EXIF-conditioned rotation fit estimates 14.43 arcseconds/second for the long run against a sidereal reference of 15.041, with held-out p95 1.44 output pixels. The fit estimates an effective focal length of 600.6 pixels versus nominal 568.9. The report's `compatibleWithFixedTripod` is only a loose consistency test (rate within 1.5 arcseconds/second and p95 below 2 pixels), not proof of a calibrated physical solution. Unknown lens projection, distortion and focal calibration remain confounded with angular speed. Measured image warps remain authoritative.

## Validation and next experiments

All seven Swift tests pass. They cover projective fitting/inversion, correspondence outliers and missing stars, hot-pixel rejection, warp rescaling/inversion, line detection near invalid boundaries, persistent-track grouping and known sidereal motion with irregular EXIF intervals. The final executable also passed an end-to-end five-frame RAW smoke run around DSC00025: 5/5 aligned, one candidate selected, finite output and zero protected-ground change. Its short 67-second span yields a poorly constrained physical rate of 17.63 arcseconds/second, correctly failing the diagnostic consistency flag despite good image alignment. This reinforces the need to keep that fit diagnostic.

The next useful experiments are a manually annotated meteor/aircraft set, better sky-boundary masks, calibrated distortion models, a failed-frame recovery pass, and photometric clipping/flux evaluation. Full-sensor rendering, mixed exposure sequences, moving cameras, clouds and ground denoising remain unvalidated. The current result demonstrates the requested native headless workflow; it is not ready to claim general-purpose astronomical photometry or reliable automatic meteor classification.
