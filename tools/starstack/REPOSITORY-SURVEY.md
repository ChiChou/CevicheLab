# Repository survey for star stacking and a Metal experiment

Follow-up 2026-10-29: [MetDetPy detailed review](METDETPY-REVIEW.md) inspects its still-photo path, multiscale inference, score semantics, Apple acceleration options and pending checkpoint provenance, and proposes integration with our meteor workflow.

Follow-up: the first four candidates have now been run on the supplied meteor interval. See [measured comparison and native Metal experiment](COMPARISON.md). The survey below describes the earlier research-only pass.

Reviewed 2026-10-28. Scope: primary-source discovery, selected source inspection, license intake, and experiment design. No packages, catalogs or model weights were installed; no external program was benchmarked. Existing Swift code and images are unchanged. Repository branches can move; selected source blob identifiers appear below.

## Recommended shortlist

| Repository | What we can learn or compare | Observed source terms | Fit for our experiment |
| --- | --- | --- | --- |
| [theatrus/seiza](https://github.com/theatrus/seiza) | GPU resampling, bounded stacking, star measurement and plate solving | [Apache-2.0](https://github.com/theatrus/seiza/blob/main/LICENSE); some bundled data/assets have separate terms | **First GPU architecture reference**; actual wgpu compute paths include Metal |
| [quatrope/astroalign](https://github.com/quatrope/astroalign) | Triangle matching and robust similarity initialization | [MIT](https://github.com/quatrope/astroalign/blob/master/LICENSE.txt), plus an embedded BSD-style RANSAC notice | **Small registration baseline**; CPU algorithm, not a complete wide-angle sky/ground stacker |
| [esa/tetra3](https://github.com/esa/tetra3) | Catalog identification, pointing recovery, geometric verification | [Apache-2.0 plus retained original Tetra notice](https://github.com/esa/tetra3/blob/master/LICENSE.txt) | **Physical-geometry reference**; adapt database/FOV rather than assuming its default fits a 16 mm landscape |
| [shin3tky/detect_meteors](https://github.com/shin3tky/detect_meteors) | Adjacent-frame residuals, Hough lines, aircraft review and RAW samples | [Apache-2.0](https://github.com/shin3tky/detect_meteors/blob/main/LICENSE), with [NOTICE](https://github.com/shin3tky/detect_meteors/blob/main/NOTICE) | **Closest meteor-photo comparison**; candidate discovery, not validated automatic classification |
| [LilacMeteorObservatory/MetDetPy](https://github.com/LilacMeteorObservatory/MetDetPy) | Video/image detection, temporal rechecking, optional learned inference | [MPL-2.0 source](https://github.com/LilacMeteorObservatory/MetDetPy/blob/main/LICENSE); exact checkpoint terms/provenance still need checking | **Detector evaluation candidate**, after model review; Core ML inference is distinct from stacking acceleration |
| [majmichu1/Astraios](https://github.com/majmichu1/Astraios) | GPU triangle voting, rejection, processing benchmarks | [GPL-3.0-or-later notice](https://github.com/majmichu1/Astraios/blob/main/NOTICE) | **Secondary GPU reference**, with copyleft attribution/provenance work; alpha, no native camera RAW input |
| [Dacongan/strehl](https://github.com/Dacongan/strehl) | Local phase correlation, patch quality selection, optional MLX backend | [GPLv3 text](https://github.com/Dacongan/strehl/blob/main/LICENSE) | **Later planetary/lunar workflow**; patchwise turbulence correction is a different problem from sidereal wide-angle registration |
| [supernovae/photonloom](https://github.com/supernovae/photonloom) | GPU median/MAD and Winsorized integration in spatial tiles | README declares MIT; no root license file found in inspected listing and GitHub license metadata was null | **Inspect further before code reuse**; real WGSL implementation exists, but finish the license record first |
| [chickadeebird/GPUStacker](https://github.com/chickadeebird/GPUStacker) | CUDA star detection and stacking pipeline description | No license identified in the inspected root listing/metadata | **Reference only for now**; CUDA does not run directly on Apple GPUs |
| [samuelkriegerbonini-dev/AstroBurst](https://github.com/samuelkriegerbonini-dev/AstroBurst) | CPU processing and scientific measurement workflow | README declares AGPLv3; file-level audit not performed | **Not a GPU stacking reference**: current README explicitly limits GPU use to display |

These labels distinguish permissive source candidates, copyleft candidates, and incomplete license records; they are not blanket approval of dependencies, weights, catalogs or bundled photographs. Preserve applicable notices and inspect the exact files/revision selected before importing code. The table does not imply equivalent maturity or measured quality.

## Seiza: the most relevant GPU design

The current [GPU design document](https://github.com/theatrus/seiza/blob/main/docs/design/gpu-stacking.md) separates dense pixel work from small numerical fits. GPU stages include detection preprocessing, resampling, normalization application, live accumulation and final integration. Registration fitting and normalization fitting stay on the CPU. It bounds device memory, uses reusable buffers and overlaps row-band processing, with CPU fallback for small inputs or GPU failures. Reported performance and parity numbers are upstream measurements, not results on our sequence.

The [resampling shader](https://github.com/theatrus/seiza/blob/main/seiza-stacking/src/gpu/resample.wgsl) handles bilinear or clamped Lanczos-3 sampling and mask resampling. Source coordinates come from a grid evaluated on the host in double precision. Grid nodes separate integer pixel positions from fractional offsets, reducing float precision loss far from the image origin. This is directly relevant to high-resolution subpixel star rendering, although a coarse grid adds interpolation error that must be checked for our cubic field.

The [band integration shader](https://github.com/theatrus/seiza/blob/main/seiza-stacking/src/gpu/bands.wgsl) performs multi-pass weighted integration with leave-one-out rejection and records accepted/rejected counts. This is not the same estimator as our median/MAD-clipped RGB mean. Borrowing its execution structure must not silently change our rejection policy. The inspected shader declares a 512-frame limit; larger sequences need explicit handling, never truncation.

## Registration candidates

**Astroalign:** its [implementation](https://github.com/quatrope/astroalign/blob/master/astroalign.py) and [README](https://github.com/quatrope/astroalign#readme) expose control-point correspondences and a similarity transform. Compare matching on our existing detected star coordinates, keeping RAW development and resampling fixed. It is a useful bootstrap/control, not a substitute for distortion modeling over 85 minutes. The RANSAC section contains an additional attribution/license notice that must travel with copied portions.

**tetra3:** uses hashed four-star patterns and verifies additional catalog matches. Its default database targets approximately 10–30 degree fields; our 16 mm full-frame field is much wider. Test calibrated crops or an appropriate database, and audit catalog redistribution separately. A successful solve can anchor absolute sky geometry; it does not perform meteor compositing or GPU image fusion. [README and algorithm source](https://github.com/esa/tetra3/blob/master/tetra3/tetra3.py).

**Astraios:** selected [GPU registration source](https://github.com/majmichu1/Astraios/blob/main/astraios/core/gpu_registration.py) constructs local triangle descriptors and votes for star pairs with device tensors, then performs the small final RANSAC fit on the CPU. This suggests a later GPU matching experiment if profiling shows matching is expensive. Do not assume that moving a few hundred stars to the GPU improves elapsed time: allocation, dispatch and transfer costs count. Its source notices identify code ported from Seti Astro Suite Pro, so provenance is more than a top-level license badge.

## Meteor detection: useful limits to preserve

The [Detect Meteors README](https://github.com/shin3tky/detect_meteors#readme) describes adjacent absolute differences, thresholding, morphology, contour filters and Hough lines. It processes filename order and does not score the first frame. Those are consequential differences: our filenames wrap, and a meteor disappearing between images can produce another absolute-difference detection. Use EXIF order and signed, source-attributed residuals in our comparison; retain a separate first-frame check. NPF-based thresholds are exposure heuristics, not a measured star-motion solution.

Its [aircraft sample report](https://github.com/shin3tky/detect_meteors/blob/main/docs/aircraft_sample_validation.md) documents 12 exposures containing aircraft and two owner-confirmed meteor images. A meteor-plus-aircraft image receives a high aircraft score. The hook annotates candidates rather than deleting them; its default matching settings fail to join tracks in that sample. This is useful adversarial evidence for per-trail review, not evidence of universal classification accuracy. We have not downloaded these RAWs or established their independent reuse terms.

[MetDetPy](https://github.com/LilacMeteorObservatory/MetDetPy/blob/main/readme.md) offers both video and photo workflows, with optional neural detection/rechecking. Its [usage documentation](https://github.com/LilacMeteorObservatory/MetDetPy/blob/main/docs/tool-usage/Detector-usage.md) exposes Core ML alongside other execution providers and distinguishes their scheduling. Core ML can use different compute units; merely selecting the provider is not proof of GPU execution or speedup. The inspected `weights/` directory contains YOLOv5-named ONNX artifacts, but no separate license/model card there. Do not infer weight provenance or usage terms from the MPL source license. Our 15-second exposures also differ from continuous meteor-monitoring video.

## Other GPU projects: what the claims actually cover

[Photonloom's GPU source](https://github.com/supernovae/photonloom/blob/main/src/gpu.rs) contains WGSL median selection, MAD-based scale estimation and Winsorized integration, with reusable tiled buffers. Its backend selection includes Metal. That is substantive compute code, but its [licensing notice](https://github.com/supernovae/photonloom#licensing-notice) is currently a declaration rather than a root MIT license file in the inspected listing. Keep it as an algorithm reference until the precise grant is recorded; third-party RAW libraries and optional model terms are separate.

[Strehl](https://github.com/Dacongan/strehl#readme) is relevant to future lucky imaging: select good frames/patches and compensate local seeing. Its documented NumPy/MLX/Numba backend choices do not establish that every operation runs on Metal. Applying free local motion compensation to our star field could distort celestial geometry, so it is lower priority here.

[AstroBurst](https://github.com/samuelkriegerbonini-dev/AstroBurst#readme) is an example of why the GPU scope must be checked: its current description says stacking and alignment execute on CPU, despite a WebGPU display. [GPUStacker](https://github.com/chickadeebird/GPUStacker#readme) describes CUDA kernels, but the inspected license record is incomplete and its platform is not native Apple Metal. Neither is my first choice for the requested experiment.

## Design for the new native GPU test program

Recommendation: retain the existing macOS RAW development and verified geometry, and build a separate **Swift/Metal benchmark executable**. Seiza is the first permissively licensed implementation to study; Astroalign is a separate matching baseline. This search pass does not implement the program.

1. **Freeze input and numerical behavior.** Use our existing reference, sky mask, accepted-frame list and transforms. Keep the 21-frame pilot and 300 accepted long-span frames as separate cases. First compare GPU and CPU on identical operations, then compare alternative algorithms.
2. **GPU inverse warp first.** Test the current projective/cubic inverse and bilinear sampling with identical pixel-center, border and mask conventions. Compare direct float evaluation with a double-precision CPU coordinate grid plus relative-coordinate GPU interpolation. Measure coordinate error before image error. Keep geometry fitting on CPU initially.
3. **GPU integration second.** Feed already-aligned row tiles, preserving validity, median/MAD thresholds, joint-luminance rejection and whole-RGB accumulation. Keep all temporal samples for each spatial tile. Averaging independently clipped temporal chunks is not equivalent to clipping the complete sequence.
4. **Bound memory and reuse allocations.** Include input, scratch, masks, outputs and queued work in the budget. An uncompressed 304-frame, 42 MP Float32 RGBA cube is roughly 205 GB, so full-sequence GPU residency is unsuitable. Start with one reusable tile set, then measure whether two in flight help.
5. **Separate timing scopes.** Record shader compilation/device initialization, upload/staging, device execution, readback, cache I/O and total elapsed time. Report cold and warmed runs, device/OS, dimensions, frame count and peak allocated bytes. Do not present kernel-only speed as end-to-end speedup.
6. **Require photographic parity.** Report finite output, identical protected ground and coverage, inverse round-trip error, CPU/GPU RMS and worst errors, rejection disagreements, star aperture flux/shape, and meteor residual retention. Use synthetic stars/trails plus actual corner crops; a global error average can conceal bright-star damage.
7. **Keep a forced CPU mode and explicit failures.** GPU absence, memory limits or unsupported work must produce a documented fallback. GPU tests must report whether kernels actually ran, rather than quietly validating the CPU route.

After parity, separately test clamped Lanczos-3, alternate rejection estimators, PSF centers and shared calibration. GPU acceleration alone will not recover missing meteors or fix our current aperture-flux loss.

## Inspection record

Selected inspected source blobs, for identifying the reviewed content independently of mutable branch links:

| Repository/file | Git blob SHA |
| --- | --- |
| Seiza `gpu/resample.wgsl` | `0edc7cddc63227df09c9c83662ad2b8604684405` |
| Seiza `gpu/bands.wgsl` | `7860eb2f763d4f8b0204429d0fa33bc3570b70df` |
| Seiza `LICENSE` | `f49a4e16e68b128803cc2dcea614603632b04eac` |
| Astroalign `LICENSE.txt` | `a51a43fb476b2272200a65259a2385087821cd33` |
| Astraios `core/gpu_registration.py` | `d6f1bb01d048cb33e08f7a622f11d240dd07c34f` |
| Photonloom `src/gpu.rs` | `d28c27d2916748a813533dd51253bd6f2b99fbae` |
| Detect Meteors `README.md` | `28981d5daa797071f53411019afce36063b25390` |

Source terms were read for Seiza, Astroalign, tetra3, Detect Meteors, MetDetPy and Strehl; Astraios' project NOTICE was read. GPU sources were sampled for Seiza, Astraios and Photonloom. Other entries are documentation-level screening. Before importing a candidate, pin a commit and complete a dependency/data/weight review for the actual chosen path. No upstream performance claims were reproduced in this survey.
