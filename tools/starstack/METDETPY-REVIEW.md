# MetDetPy: detector integration review

Follow-up: the user subsequently authorized a local implementation and sample run. See the [executed CLI experiment](METDETPY-EXPERIMENT.md): 304 frames detected, 300 aligned, 16 selected trail candidates. The source-only review below records the earlier assessment; model redistribution provenance remains unresolved.

Reviewed **2026-10-29**, pinned to [commit 2ae98d12a53cbd48f08772cc9da1146b19b29d41](https://github.com/LilacMeteorObservatory/MetDetPy/commit/2ae98d12a53cbd48f08772cc9da1146b19b29d41), identifying itself as v2.6.1. This is source inspection and experiment design: no model download, inference run, application integration or quality claim on our photographs.

## Recommendation

Evaluate **MetDetPhoto**, the repository's still-image detector, as an additional source of meteor candidates. Keep our EXIF-driven geometry, existing AI sky mask, separate sky/ground stacking and measured-pixel meteor restoration. Detection supplies regions and class scores; it does not provide a precise trail matte or establish how to align the sky.

The [tool guide](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/docs/tool-usage/Detector-usage.md) distinguishes ordinary video detection from static images, image sequences and timelapse. The video path has temporal rechecking; the photo path does not automatically provide that mechanism. Our long exposures and irregular gaps therefore need our own sequence verification. Do not turn the RAW sequence into a nominal-FPS video and assume its playback times represent capture times.

## What the inspected implementation provides

- [MetDetPhoto.py](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/MetDetPhoto.py): individual images, folders, explicit `@images.txt` manifests and timelapse videos; a mask input; bounding-box/class/score JSON output. Folder order is filename order. Supply an explicit manifest in EXIF order for our sequence, where filenames wrap.
- [Model code](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/MetLib/model.py): YOLO-style ONNX inference, overlapping multiscale partitions, class-aware non-maximum suppression and mapping boxes back to input coordinates. Public input is BGR; the default model path converts to RGB, divides by 255 and uses NCHW tensors. Input dimensions come from the model. Do not assume a generic YOLO preprocessing recipe or invent a fixed input size without inspecting the actual checkpoint.
- [Class list](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/global/class_name.txt): meteor, plane/satellite, red sprite, lightning, jet, rare sprite, spacecraft and bugs. These are trained class labels, not verified astronomical identities.
- [Image loader](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/MetLib/fileio.py): JPEG/PNG/TIFF and several RAW extensions, including ARW, through rawpy. For a controlled comparison, feed our identically developed 8-bit sRGB PNGs to separate detector differences from RAW development differences; retain full-resolution linear sources for compositing.
- [Device documentation](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/docs/tool-usage/Detector-usage.md): explicit `coreml` ONNX Runtime provider support. Measure actual node placement/fallback and end-to-end time. Core ML selection alone does not establish GPU-only execution, Neural Engine execution, or a speedup.

Two implementation details matter when evaluating results:

1. Scores are `sqrt(objectness × class score)`, not calibrated meteor probabilities. v2.6.1 restores an independent objectness threshold; both default thresholds are 0.25. Freeze version and settings when comparing runs. See [model implementation](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/MetLib/model.py) and [release notes](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/docs/update-log.md).
2. Sequence JSON is sparse, and saved scores are rounded to two decimals. An omitted image can mean zero predictions or a processing failure. Record completion for every manifest entry, and preserve full-precision detector outputs in our adapter. The [upstream comparison documentation](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/docs/dev-docs/photo-comparison.md) explicitly documents these evaluation limitations.

## Proposed Ceviche workflow

1. Develop consistent detection proxies and preserve their coordinate mapping, RAW identity, exposure interval and EXIF camera clock. Use the existing AI sky mask with an uncertainty margin; avoid cutting off genuine low-altitude trails.
2. Run photo detection on original exposures before background stacking suppresses unique events. Compare multiscale inference with our residual/Hough candidates. Initially retain their union for review; a negative AI result is not proof that a faint meteor is absent. Feeding residual images into the model is a separate, unvalidated input-domain experiment.
3. Keep three independent decisions: usable for geometry, usable for background mean, and contains an event candidate. Non-detection frames remain useful for the first two. Skip expensive event extraction only after conservative screening, with failed inference explicitly marked unknown.
4. Verify candidates against neighboring exposures using actual time intervals, appearance, measured line support and persistence. Aircraft/satellite labels inform review; do not automatically discard a frame that also contains a meteor. Leave `--exclude-noise` off during evaluation so false classifications remain visible.
5. Refine each accepted box into a trail mask using the source's measured signal and a compatible registered background estimate. Transfer only source-attributed meteor signal into the common sky epoch. A rectangular box is not a compositing mask; pasting it would also copy noise and mismatched stars.
6. Use the exposure midpoint for initial sky registration, while recording event-time uncertainty within the exposure. A meteor's actual instant is generally unknown from one long exposure; EXIF does not resolve it. Radiant fitting across multiple candidates can be a diagnostic, not a mandatory rule for sporadic meteors.

## Evaluation plan

Use `/path/to/samples/nightsky/101MSDCF` with the existing pilot and full-sequence caches. Label individual trails, including faint/short meteors, aircraft, satellites, clouds, bright stars and skyline interference. Compare current CV detection, MetDetPhoto alone and their union. Separate tuning and evaluation by capture session when more data is available.

Report event-level precision/recall, missed faint trails, false candidates per frame, per-frame completion, box localization, recovered trail flux/color and final composite artifacts. The upstream headline video accuracy is not evidence of accuracy on these wide-angle RAW photographs. Compare FP32 CPU with Core ML on exactly the same inputs before attempting a native model conversion; record cold/warm time, preprocessing, partitions, inference, postprocessing, memory and fallback. FP16 should follow parity testing, especially for threshold-crossing faint candidates.

## License intake

The repository declares [MPL-2.0](https://github.com/LilacMeteorObservatory/MetDetPy/blob/2ae98d12a53cbd48f08772cc9da1146b19b29d41/LICENSE). Its file-level source and notice requirements need to be retained when distributing covered code; this is not an MIT-style grant. Preserve applicable notices and review the actual imported files/dependencies before integration.

The pinned [weights directory](https://github.com/LilacMeteorObservatory/MetDetPy/tree/2ae98d12a53cbd48f08772cc9da1146b19b29d41/weights) contains `yolov5s_v2.onnx` and `yolov5s_v2_fp16.onnx`. No separate model card or weight-specific license/provenance document was found in the inspected tree. The project-wide MPL declaration is evidence, but does not independently establish the training/base-checkpoint lineage and third-party rights of those binaries. Do not infer a specific upstream YOLO license from the filename either. Weight redistribution and native conversion remain pending that provenance review; no maintainer was contacted.

Selected inspected blobs: `MetDetPhoto.py` = `c15a6ad9dc03d527fdc122ef600ba82ad0445429`; `MetLib/model.py` = `2845d8cdd1a3ac457e3c7cf2ce8d53f8da6aee43`; `LICENSE` = `fa0086a952236971ab37901954d596efae9f4af6`. ONNX binaries were not fetched or executed.
