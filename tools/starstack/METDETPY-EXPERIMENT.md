# MetDetPhoto → star morph → meteor composite

**Executed 2026-10-29**, on the full photographer-supplied `/path/to/samples/nightsky/101MSDCF` sequence. The new entry point is [scripts/meteor_ai.py](scripts/meteor_ai.py), with a small native [meteorprep](Sources/meteorprep/main.swift) RAW adapter. The app/editor code and source photographs are unchanged.

## Actual results

| Measurement | Full sequence |
| --- | ---: |
| Sony ARW inputs | 304 |
| Detector successes / failures | 304 / 0 |
| Raw AI boxes, before spatial/line checks | 198: 123 meteor-label, 75 aircraft/satellite-label |
| Frames with a meteor-label score ≥0.5 | 96 |
| Frames with no model detections of any class | 154 |
| Accepted star alignments | 300 / 304 |
| Frames using smooth residual morph | 283 |
| Measured line candidates after merging duplicates | 42 |
| Persistent-track candidates | 21 |
| Selected trail candidates / source exposures | 16 / 16 |
| Selected origins | 12 CV; 2 CV extended by AI-region extraction; 2 additional AI-region lines |
| Detection proxy / star analysis width | 3200 px |
| Composite dimensions | **1600 × 1068** |
| Median of frame validation p95 errors | 0.351 output px |
| Worst accepted frame validation p95 | 1.046 output px |
| Known DSC00025 trail core residual-flux ratio | 1.00004, across 850 core pixels |
| Protected foreground maximum change | 0, Float32 |
| Pixels outside selected footprints | Exactly equal to the clean background |

The last four frames, DSC00186–DSC00189, failed registration: excessive validation residual, then insufficient bootstrap correspondences. Their detection records remain available but their trails are not pasted without valid geometry. Non-detection images remain eligible for alignment and background fusion.

**These are selected meteor candidates, not 16 independently confirmed meteors.** Tree branches received meteor scores in several raw predictions. Sky/source-validity checks and measured line support reject these before compositing. Temporal persistence removes additional continuous-track candidates, but cannot prove the identity of every isolated trail. No annotated ground truth establishes detector recall or precision here.

## Outputs

- [Meteor composite JPEG](output/metdetpy-2026-10-29/meteor-composite.jpg)
- [Reference / clean background / meteor composite JPEG](output/metdetpy-2026-10-29/comparison.jpg)
- [Selected trails annotated](output/metdetpy-2026-10-29/selected-trails.jpg)
- [Selected source crops for review](output/metdetpy-2026-10-29/selected-source-crops.jpg)
- [Floating-point linear TIFF](output/metdetpy-2026-10-29/meteor-composite-linear.tiff)
- [Summary](output/metdetpy-2026-10-29/summary.json), [per-frame detections](output/metdetpy-2026-10-29/detections.json), [candidate decisions](output/metdetpy-2026-10-29/candidates.json), [quality checks](output/metdetpy-2026-10-29/quality.json).

JPEGs use the same 0 EV linear-to-sRGB rendering and quality 95, without separate cosmetic adjustments. This trial is explicitly **1600-pixel output**, not a full-sensor export. The detection proxies are developed RAWs, not embedded JPEGs. Foreground is the reference exposure; this run does not denoise the ground. `meteor-owner.npy` records source-frame ownership for composited pixels.

## Pipeline implemented

1. **Prepare:** native ImageIO reads timestamps/exposure/focal metadata, sorts in EXIF order, and Core Image develops 3200-pixel sRGB detection PNGs with common reference white balance. Filenames wrap during this sequence; lexical ordering would be incorrect. Original ARWs remain read-only.
2. **Detect:** import the pinned upstream `YOLOModel` directly, using its actual multiscale and class-aware NMS implementation. Default two scales/partition two, FP32 checkpoint, independent objectness gate 0.25 and upstream score gate 0.25. Preserve full-precision class scores and an explicit success/failure record for every input. Proposed compositing selection additionally requires meteor score ≥0.5. Scores are square-root joint model scores, not calibrated probabilities.
3. **Morph and background stitch:** run the existing Swift `starstack` engine freshly across all 304 images. It reuses Ceviche's existing AI sky model, 3200-pixel star analysis, EXIF-midpoint transform prediction, projective alignment and validated cubic residual morphs. Inverse warping samples original linear RGB; robust median/MAD rejection builds a clean background from all accepted frames. No celestial alignment is inferred from the meteor itself.
4. **Refine candidates:** transform sampled AI-box boundaries into the reference epoch, including the smooth residual field. Associate boxes with existing CV residual lines. Where a meteor box has no existing central line, search its valid sky residual with a lower local threshold and Hough proposals, then verify measured pixel support and line shape. Exclude star cores, source-invalid areas and the protected skyline. Merge overlapping collinear fragments from the same exposure.
5. **Select:** require an associated meteor score ≥0.5 exceeding any associated aircraft/satellite score. Flag line groups across at least three nearby exposures as persistent; use actual time gaps ≤60 seconds as well as nearby sequence indices. Keep unselected and unaligned proposals in review records.
6. **Composite:** build narrow feathered trail footprints and restore the aligned source's measured RGB residual over the clean stack. Overlaps select one RGB source by luminance-residual strength, never independent RGB maxima. AI boxes are not pasted and no synthetic trail pixels are generated.

The CLI provides `--stage detect`, `--stage compose`, and the default complete workflow. It resumes matching detector caches, checks input paths/sizes/modification times and dimensions, pins model SHA/revision, retries explicit inference failures, and rejects incomplete/differently ordered detection records. Geometry and proxy caches are local experiment artifacts; use a fresh output directory after changing the implementation or development settings.

## Apple acceleration and timings

Machine: Apple M4, macOS 27.2. ONNX Runtime **1.31.1**. Checkpoint input shape **1 × 3 × 544 × 960**. Raw image inputs are BGR; upstream converts to the model's RGB tensor convention. Multiscale inference preserves more small-trail detail than one whole-image resize.

Measured detector initialization including warmup: **1.48 s**. Sum of per-frame image loading/inference/postprocessing scopes: **58.60 s** for 304 exposures. This excludes RAW development, geometry, stack fusion and final composition, and is not total pipeline latency.

ORT profiling recorded **1521 CoreML provider node events** and **10647 CPU provider node events**, including warmup. Corresponding summed event durations were about 11.02 s and 0.39 s; these are profiling scopes, not end-to-end GPU timings. Core ML execution is verified, but the profiler does not identify its internal CPU/GPU/Neural Engine split. No CPU-versus-GPU speedup claim is established. Swift geometry/fusion and Python candidate processing remain CPU work; this is not a complete Metal port.

## Reproduce

Build the standalone package and install dependencies in an experiment environment. This run used `tools/starstack/output/comparison/venv/bin/python` with NumPy, SciPy, OpenCV, Pillow, tifffile, ONNX Runtime, dacite, rawpy, av, pyexiv2 and tqdm. Some video dependencies are imported by upstream package initialization even though this path processes photos. Record the environment before a comparison run.

The reviewed upstream checkout is `output/metdetpy-upstream`, revision **2ae98d12a53cbd48f08772cc9da1146b19b29d41**. Obtain the actual `weights/yolov5s_v2.onnx` LFS binary, not its pointer. Verified SHA256: **f97d3e92e69c42fba74c1835adc210891595aff183bd7e937376b9a7d728cfeb**. The CLI fails on a different revision/hash.

```sh
swift build -c release --build-system native --package-path tools/starstack

tools/starstack/output/comparison/venv/bin/python \
  tools/starstack/scripts/meteor_ai.py \
  /path/to/samples/nightsky/101MSDCF \
  tools/starstack/output/metdetpy-2026-10-29 \
  --upstream tools/starstack/output/metdetpy-upstream \
  --sky-model /path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc \
  --provider coreml --detect-edge 3200 --edge 1600

tools/starstack/output/comparison/venv/bin/python \
  tools/starstack/scripts/inspect_meteor_ai.py \
  tools/starstack/output/metdetpy-2026-10-29

tools/starstack/output/comparison/venv/bin/python \
  tools/starstack/scripts/test_meteor_ai.py
```

For this full run, proxy development and fresh geometry ran concurrently through the native helper commands, then the new CLI executed detection and its complete path using those validated caches. A separate **three-frame fresh CLI smoke run** around DSC00025 performed all phases from RAW inputs without pre-existing caches: 3/3 detections, 3/3 alignments, one selected trail.

Four new adapter tests cover measured synthetic trail recovery, rejection of noise/ground, narrow compositing support, overlap deduplication and coordinate conventions. An independent comparison of Python forward mapping against native recorded fits found a maximum median-error discrepancy of **5.44e-13 pixels** across the earlier full-run fixture. Existing seven native tests also pass. Native-pixel image checks verified finite output, unchanged foreground, unchanged non-trail pixels and the known-trail residual retention; the latter is not a measurement of faint-tail completeness.

## Limits and license status

Selected candidates remain reviewable: the faint DSC00036 proposal, for example, needs identity review rather than an automatic scientific meteor claim. A short-lived satellite/aircraft streak can evade the persistence filter. Conversely, strict spatial support can miss faint/near-horizon meteors. The detector lacks our sequence's ground-truth annotations. The original star elongation and long-span photometric limitations of the baseline remain.

The upstream source declares MPL-2.0. Its checkpoint was downloaded and executed locally for this explicitly requested experiment; it is ignored by Git and is not bundled into Ceviche. The weight lineage/redistribution questions from the [source review](METDETPY-REVIEW.md) remain unresolved. Running a local trial does not establish shipping clearance. No upstream source was copied into application code.
