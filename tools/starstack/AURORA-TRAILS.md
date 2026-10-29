# Aurora sequence: star-trail maximum with brightness filtering

Experiment **2026-10-29**, macOS 27.2 / Apple M4. Processed all **172 Sony ARWs** from `/path/to/samples/Aurora-timelapse-2024-10-11/`. Original RAWs/XMPs and application code were not modified. New commands and scripts are confined to this experimental package.

## Results

- [Comparison: all versus filtered](output/aurora-trails-2026-10-29/comparison-1280.png)
- [All 172 frames](output/aurora-trails-2026-10-29/trails-all-1280.png)
- [Filtered: 162 frames](output/aurora-trails-2026-10-29/trails-filtered-1280.png)
- [Matching sky detail](output/aurora-trails-2026-10-29/trail-detail.png)
- [Selection audit](output/aurora-trails-2026-10-29/selection-audit-1280.png)
- [Per-frame decisions, JSON](output/aurora-trails-2026-10-29/quality.json) / [CSV](output/aurora-trails-2026-10-29/quality.csv)

**162 kept; the final 10 excluded from this night-sky stack:** DSC03349–DSC03358, camera time **05:15:55–05:30:19**. The retained interval ends at DSC03348, **05:14:19**. All files have reported 13 s, ISO 1600, f/5.6, 39 mm settings; these exclusions respond to actual scene brightening, not an EXIF exposure-setting change.

The filtered result has a substantially darker sky and more visible faint trail segments under the **same display transform**. The unfiltered result is dominated by the bright blue late sky. Aircraft/satellite-like lines and maximum-stack noise remain; this experiment does not classify or remove them. Sparse capture intervals produce dotted arcs, and no gaps are reconstructed.

## Processing held constant

Apple Core Image develops each RAW to **1600 × 1068 scene-linear Float32 RGBA**, using the first frame's white balance, with optional RAW tone/sharpen/NR controls disabled as in the earlier experiment. XMP edits are not applied. Each comparison photo is downscaled to **1280 × 854**, with the same linear-to-sRGB conversion, **0 EV display adjustment**, and no independent auto contrast or exposure normalization.

Fusion is **literal per-channel maximum in camera coordinates**. There is no stellar registration, which would remove the desired trails. This first trial assumes the fixed camera framing observed in the survey; it does not estimate or correct camera shake. Both main previews use the same reference foreground from DSC03187 and the same AI sky mask. Full-frame maximum outputs without the foreground composite are also retained: [all](output/aurora-trails-2026-10-29/maximum-full-frame-all-1280.png), [filtered](output/aurora-trails-2026-10-29/maximum-full-frame-filtered-1280.png).

The maximum accumulators and normalization/display policies are identical; the frame inclusion list is the difference. Per-channel maximum is not a color-preserving RGB source selection, and it accumulates positive noise. These are intentional baseline characteristics, not claims of final photographic quality.

## Heuristic night-sky filter

1. Use the clear upper sky, normalized rectangle `(0.05, 0.05)–(0.95, 0.40)`, divided into **5 × 3 tiles**. Verify it is sky in the final model mask.
2. Compute median linear luminance per tile; point stars have little influence on these medians.
3. Establish each tile's night baseline as the median over the first **12 chronological frames**.
4. Mark broad brightening when **at least 80% of tiles exceed their baseline by 0.5 EV** (about 1.414× luminance).
5. Exclude runs of at least **three consecutive marked observations**. An independent >4 EV broad-brightness rule permits immediate rejection of isolated extreme frames; it did not trigger here.
6. Keep irregularly spaced frames. Timing gaps themselves never contribute to the brightness rejection decision.

The first excluded image measures **+0.543 EV** in the median normalized tile statistic, with 14/15 tiles above the threshold. The last retained image measures **+0.420 EV**, with no tiles above the threshold. The last source reaches **+2.73 EV**.

The threshold is **sample-tuned**, not a validated general night/aurora classifier. An initial +2 EV trial excluded only three frames and left the sky strongly dominated by dawn; its [report](output/aurora-trails-2026-10-29/initial-2ev/quality.json) and [preview](output/aurora-trails-2026-10-29/initial-2ev/comparison-1280.png) are retained. After visual review, the final threshold was tightened to +0.5 EV. Bright aurora on another sequence could also meet this rule; broader quality/classification validation remains future work. No RAW saturation, focus or full image-quality claim follows from this luminance gate.

## Existing AI sky mask

Uses the existing **SkyRemoval Core ML model** at `/path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc`. No new model download and no color-rule replacement in the final outputs.

The older experimental wrapper applied a brightness boost and a broad skyline erosion intended to stop ground leaking into stellar warps. This produced an inappropriate dark band for the fixed-camera trail composite. The final mask disables those experimental additions and uses the existing model on the reference's normal encoded-sRGB input. The Python preview follows Ceviche's guided-refinement approach: encoded blue-channel guide, approximately 20/3000 of the long edge as radius, epsilon 0.01 and the same output-encoding convention. It is a preview implementation of that approach, not a claim of bit-identical Core Image refinement.

The optional parameters default to the previous behavior for existing star-alignment runs. Application model code is unchanged. A temporary color-threshold diagnostic and manually repaired mask were explored before returning to the application model; neither is used by the final script. Small probability values are snapped at 0.001/0.999 for stable interiors; soft boundary pixels remain blended. Thin foliage and boundary matting remain limitations, not perfect transparency recovery.

## Checks and reproduction

The build succeeds; the package's seven existing regression tests pass. Output values are finite. The all-frame maximum is everywhere at least the filtered maximum. A separate check recomputed **1,024 sampled RGB pixel maxima** across original cached inputs and matched both saved linear outputs exactly. Reference pixels are unchanged in the mask's zero-valued ground interior. Previews and the final mask were visually inspected; the checks do not establish camera stability or a general quality-classifier accuracy.

```sh
swift build -c release --build-system native --package-path tools/starstack
tools/starstack/.build/release/nativebench trail-export \
  /path/to/samples/Aurora-timelapse-2024-10-11 \
  tools/starstack/output/aurora-trails-2026-10-29 1600 \
  /path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc
tools/starstack/.build/release/nativebench trail-mask \
  tools/starstack/output/aurora-trails-2026-10-29 \
  /path/to/Ceviche/ml/build/compiled/SkyRemoval.mlmodelc
tools/starstack/output/comparison/venv/bin/python tools/starstack/scripts/aurora_trails.py \
  tools/starstack/output/aurora-trails-2026-10-29 --threshold-ev 0.5
```

The existing isolated Python environment supplies NumPy, Pillow and OpenCV. Cached scene-linear frames allow threshold changes without decoding RAWs again. Generated files remain under ignored `output/`; full-frame linear maxima are saved as `.npy` for further analysis. See [scenario design](../../docs/research/photography-workflows-2026-10/astro-scenario-tools.md) and [quality design](../../docs/research/photography-workflows-2026-10/sequence-quality-and-exposure.md).
