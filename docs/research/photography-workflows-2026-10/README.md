# Domain-specific photography workflows for Ceviche

Research started **2026-10-28**; astro scenarios and sequence-quality design expanded **2026-10-29**. Scope: research and feature design, plus a read-only metadata/embedded-preview survey of the supplied aurora sample. No application changes or new model downloads were performed for these notes. Actual stacking benchmarks are linked separately below.

Subsequent, separately authorized work: the [native meteor-stacking experiment](../../../tools/starstack/README.md) targets macOS 27+ and has [measured results](../../../tools/starstack/EXPERIMENTS.md) on the supplied RAW sequence. Its experimental platform target is independent of the product baseline proposed below.

## Recommendation

Build a shared, nondestructive multi-image processing system with photographer-facing workflows. Start with **better panorama seams**, **night/astro stacking with separate sky and ground alignment**, and **temporal long-exposure blending**. Add learned models where they improve matching, masks, or calibrated restoration; retain explicit geometry and linear-light compositing as the foundation.

The strongest near-term model experiments are **XFeat with its matching LighterGlue checkpoint**, **LightGlue with a license-compatible feature extractor**, and the already investigated **PMRID**. **Depth Anything 3 Small** is a current, explicitly Apache-licensed candidate for geometry assistance. None is selected for shipping by this research. See the [model and license ledger](models-and-licenses.md) for exact evidence and unresolved conditions.

Recent research worth evaluating includes **PixelStitch (ICCV 2025)**, **UniStitch (ECCV 2026)**, **RoMa v2 (ECCV 2026; preprint 2025)**, **DEBIR (CVPR 2026)**, **PNNP (TPAMI 2026; preprint 2023)**, and **ASTERIS (Science 2026)**. Their release and license situations differ substantially. Newer publication dates do not establish better performance on camera RAWs, stars, or Apple hardware.

## Read these notes

| Note | Purpose |
| --- | --- |
| [Three astro tools and aurora sample](astro-scenario-tools.md) | Star-trail maximum, star-preserving mean denoise, selective meteor processing, and the 172-frame aurora survey |
| [Sequence quality and exposure](sequence-quality-and-exposure.md) | Recoverable exposure changes, night/day segmentation, irregular cadence, per-role selection, and CV/ML evaluation |
| [Day/night transition solution](day-night-transition.md) | Separate capture corrections from changing illumination; retain useful stellar/event/ground information and preserve timelapse evolution |
| [Full-resolution Tenerife mean trial](../../../tools/starstack/TENERIFE-MEAN.md) | Two five-frame 42 MP outputs, EXIF 14 mm/time-informed sky alignment, existing AI masks and independent terrain averaging |
| [Mean-stack algorithm and CPU/GPU policy](../../../tools/starstack/MEAN-STACK-CPU-GPU.md) | Bitterli reference, global calibration/alignment design, preserved CPU reference and Metal parity requirements |
| [Feature designs](features.md) | Inputs, user experience, processing choices, limits, and priorities for ten workflows |
| [Star motion and focus stacking](star-motion-and-focus-stacking.md) | Detailed designs from the photographer's proposed workflows: sky tracking/warping, exposure-trail correction, and focus breathing |
| [Timelapse video](timelapse-video.md) | Edited-photo sequences, exposure smoothing, FPS/size controls, and native macOS video export |
| [Models, papers, and licenses](models-and-licenses.md) | Current candidates, official sources, separate code/weight terms, and adoption decisions |
| [Architecture and evaluation](architecture-and-evaluation.md) | Proposed processing contracts, Apple deployment risks, validation matrix, and staged implementation plan |

## What Ceviche already has

These observations come from the repository's documentation, not a new runtime audit:

- A native SwiftUI/macOS editor with Core Image, Metal, Core ML, a local catalog, nondestructive edits, background jobs, and float linear RGB processing.
- A panorama merge for ordered, overlapping RAWs from one camera: rotation-based alignment, perspective/cylindrical projection, overlap gain compensation, feather blending, and a linear DNG result. The documented limit is 160 MP; there is no seam search, moving-object removal, or 360-degree merge.
- Sky, depth, scene, and object masking capabilities that can seed user-correctable selections.
- Export-time NAFNet denoise, plus research on persistent RAW enhancement. The existing sample evaluation reports NAFNet star-crop artifacts and faint-point attenuation even with the promising PMRID path. That evidence argues for star-specific validation, not a generic “AI quality” slider.

Sources: [app overview](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/README.md), [bundled models](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/MODELS.md), [existing denoise evaluation](../../../experiments/denoise-evaluation/README.md), and [enhanced-source model investigation](../../../experiments/linear-dng/DENOISE-MODELS.md).

## Proposed product priorities

Effort labels below are relative engineering estimates, not calendar commitments. A shared merge recipe and tiled renderer are prerequisites across several rows.

| Priority | Feature | Photographer benefit | Initial method | Relative effort |
| --- | --- | --- | --- | --- |
| P0 | Landscape panorama refinement | Fewer doubled branches, people, and waves | Better matching, source selection, seam search, multiband blending | Medium |
| P0 | Night stack / stars and foreground | Lower noise with sharp stars and terrain | Separate registration, robust stacking, editable boundary | Large |
| P0 | Long exposure from a sequence | Smooth water/clouds while retaining selected detail | Linear temporal average and region-specific motion policy | Medium |
| P1 | Milky Way panorama | Consistent sky geometry across a changing night sky | Per-panel stacking, common sky epoch, layered stitching | Large |
| P1 | HDR landscape and HDR panorama | Recover available highlight/shadow detail | Exposure-aware radiance merge and deghosting | Large |
| P1 | Night RAW enhancement | A reusable cleaner source | Calibrated PMRID experiment; star-preservation gate | Medium–large |
| P1 | Star trails and light trails | Controlled accumulation of recorded motion | Ground registration, trail compositing, transient selection | Medium |
| P1 | Light-pollution gradient correction | Better local contrast without losing faint structures | Editable smooth background model | Medium |
| P1 | Focus-stacked subject and background | Near-to-far sharpness with consistent framing | Focus-breathing correction, measured sharpness, source painting | Large |
| P1 | Timelapse video from edited photos | Generate a movie directly from a selected sequence | Native frame rendering and AVFoundation encoding; optional exposure smoothing | Medium for basic export; advanced stages separate |
| P2 | Detail from a handheld burst | More real sampled detail | Conservative multiframe reconstruction | Large |

## Product principles

**Proposed platform baseline: macOS 15 Sequoia and later (15, 26, 27).** This covers two major releases below 27; macOS 14 is excluded. Preserve the baseline with native compatibility paths and availability-gated optional features. The current app still declares macOS 27: lowering it requires a separate application-wide compatibility audit and implementation. These research notes do not change build settings. See the [timelapse platform policy](timelapse-video.md#native-formats-and-platform-policy).

1. **Name the photographic intent.** “Smooth water,” “Keep stars sharp,” and “Keep this person” expose meaningful decisions. Model names belong in diagnostics and model settings.
2. **Preserve capture evidence.** Default workflows combine or restore recorded samples. Generative border fill or creative reconstruction, if ever added, gets a separate explicit operation and provenance.
3. **Show uncertainty where it matters.** Highlight failed overlaps, unobserved borders, rejected frames, and uncertain sky boundaries. Offer a source-frame override instead of silently inventing detail.
4. **Keep editing responsive.** Alignment and enhancement run once and persist reusable results. Exposure and color sliders operate on the resulting source.
5. **Respect the input domain.** A rendered-sRGB denoiser is not interchangeable with a Bayer or scene-linear model. A camera noise profile is not transferable merely because ISO matches.
6. **Choose exact artifacts.** A repository's license badge does not establish terms for every checkpoint, backbone, dataset, or copied dependency.

## Key research conclusions

- Better correspondence alone does not solve parallax, occlusion, temporal change, or blending. Matchers should feed a verified geometry/seam system. [XFeat](https://github.com/verlab/accelerated_features), [OpenCV stitching components](https://docs.opencv.org/4.13.0/d1/d46/group__stitching.html).
- Current geometry models can assist with difficult terrain overlaps, but their estimates need image-based verification. DA3 Small/Base have explicit Apache-2.0 weight declarations; larger variants have different terms. [Official DA3 model table](https://github.com/ByteDance-Seed/Depth-Anything-3#-model-cards).
- UniStitch's code is Apache-2.0, while its official weight card says `license: other` without supplying a clear grant there. Keep checkpoint adoption on hold. [Code license](https://github.com/MmelodYy/UniStitch/blob/main/LICENSE), [weight card](https://huggingface.co/Y5Y/UniStitch_model).
- RoMa v2 includes DINOv3 under a custom license. SAM 3/3.1 likewise use custom terms; they are not automatic replacements for permissively licensed components. [RoMa v2](https://github.com/Parskatt/RoMaV2#license), [DINOv3 terms](https://github.com/facebookresearch/dinov3/blob/main/LICENSE.md), [SAM terms](https://github.com/facebookresearch/sam3/blob/main/LICENSE).
- ASTERIS is a valuable 2026 astronomical restoration reference, but its released pretrained configurations target aligned telescope data. This does not establish suitability for Bayer Milky Way landscapes. [Official ASTERIS repository](https://github.com/freemercury/ASTERIS_THU).

## Scope and evidence limits

The search emphasized official papers, author repositories, model cards, license texts, and established imaging documentation, including 2025–2026 releases. It is a targeted survey, not a claim to have found every paper available on the research date. Search snippets and third-party catalogs were used for discovery, not as the basis for license approval.

All feature behavior, priorities, architecture, and numerical acceptance targets are **proposals**. Published benchmark claims have not been reproduced. Existing local results are linked and attributed separately. License labels are a technical intake assessment; unresolved checkpoint terms remain unresolved rather than being inferred from download availability. No authors were contacted and no new license agreements were accepted.
