# Proposed photography features

Research/design date: **2026-10-28**. Everything below is proposed behavior. Model names refer to the [license ledger](models-and-licenses.md); they do not imply a shipping dependency.

## Shared interaction

Select photos, then choose **Photo → Combine → Panorama / Night Stack / Long Exposure / HDR / Star Trails / Focus Stack**. Single-photo restoration lives under **Enhance**. Suggest a workflow from timestamps, exposure metadata, overlap, and image content, but let the photographer choose: a burst can intentionally become either sharp stars or trails.

The combine workspace should show a source filmstrip, the result, and a short set of task-specific controls. Each source has an inclusion toggle and quality indicators. A click on the output reveals contributing sources; brushing **Use this frame** resolves uncertain motion, focus, and seam choices. Preview at fit size and inspect source-resolution crops before committing.

Save a derived photo beside its source group in the catalog, with a reopenable recipe. Retain source references, exclusion decisions, masks, transforms, model versions, and the chosen reference time. A cached result remains editable when some originals are offline; recomputation identifies which originals are required.

## F1 — Landscape panorama with reliable seams

**Capture:** overlapping landscape, cityscape, interior, or seascape frames. Initial release retains the current same-camera constraint; multirow and 360-degree support are separate extensions.

**Experience:** choose projection and horizon, then inspect a ghosting overlay. Click a person, branch, or wave and select which capture should supply it. Allow seam painting and a **Preserve straight lines** option. Show excluded frames and uncovered regions before merging.

**Proposed processing:**

1. Build a connected overlap graph; use capture order as a hint, not the sole pairing rule. Compare the existing matcher with XFeat/LighterGlue and compatible LightGlue pairs.
2. Fit robust camera rotations with lens geometry and jointly refine poses. Inspect spatial coverage of inliers, not just their count.
3. Diagnose parallax from structured residuals. Prefer moving the seam around a close object before bending its geometry. A constrained local mesh is an optional escalation; reject foldovers and excessive line distortion.
4. Solve exposure/vignette differences using static, unsaturated overlaps. Preserve genuine illumination gradients and intentional exposure brackets.
5. Select source ownership with a seam cost combining mismatch, motion, edge visibility, and user preferences. Apply multiband blending where a gradual transition helps; retain strong ownership around moving objects to avoid averaging duplicate subjects.
6. Warp original-resolution linear images, preserving coverage and headroom.

**Research basis:** OpenCV separates matching, rotation estimation, warping, seam estimation, exposure compensation, and blending. UDIS++ and PixelStitch are useful learned-warp comparators, not complete replacements for all these responsibilities. [OpenCV](https://docs.opencv.org/4.13.0/d1/d46/group__stitching.html), [UDIS++](https://github.com/nie-lang/UDIS2), [PixelStitch](https://github.com/MakiseChris666/PixelStitch).

**Failure behavior:** low overlap, textureless water, repeated windows, or major viewpoint translation can make a seam impossible. Return an explicit problem region and source-frame controls. Do not stretch a foreground subject until it merely looks continuous.

**Acceptance focus:** seam visibility, full-resolution landmark error, straight-line preservation, connected coverage, and ghosting. **Priority P0; medium effort.**

## F2 — Night stack with separate stars and foreground

Detailed design: [star-motion tracking and sky warping](star-motion-and-focus-stacking.md#1--sharp-stars-with-a-stationary-foreground). Distinguish movement between exposures from trails integrated within a single exposure: alignment corrects the former, while the latter requires a separate, uncertain restoration step.

**Capture:** approximately 8–32 same-view RAWs as an initial product target, captured from a tripod or with modest camera movement. Calibration frames are optional. Tracked-sky captures and separately exposed foregrounds require explicit source grouping.

**Experience:** choose **Stars and foreground**, **Sky only**, or **Ground only**; inspect suggested frame exclusions. Controls: reference frame/time, noise reduction strength, sky boundary, and transient handling. Show star sharpness, cloud contamination, and how many usable frames contribute locally.

**Proposed processing:**

1. Normalize sensor metadata; handle known bad pixels and calibrated fixed-pattern defects before geometric resampling. Do not classify every isolated bright sample as a defect.
2. Identify sky and terrain with existing masks plus manual correction. Build a conservative transition region around branches, mountains, and buildings.
3. Build an EXIF exposure timeline using original capture time, fractional seconds, available timezone offset, and exposure duration. Use exposure midpoints and the approximate sidereal rate to constrain motion predictions, then jointly fit them to detected star patterns after lens correction. Wide-field sky motion is not generally a simple XY shift. Use terrain features for a separate ground transform. See the [timing model](star-motion-and-focus-stacking.md#exif-time-as-the-backbone-of-the-motion-model) for timestamp semantics, unequal exposures, and clock-error handling.
4. Rank frames by star shape, blur, clouds, saturation, and usable overlap. Retain an explanation for each exclusion.
5. Resample each layer to a common reference, then use a noise-aware robust average. Estimate rejection in exposure-normalized data and use conservative behavior with few frames.
6. Compose sky and ground with boundary/occlusion handling. Prefer an appropriate original frame in uncertain silhouettes rather than blending two displaced boundaries.
7. Offer mild residual denoise only after a star-preservation evaluation; keep the un-denoised stack available.

Google's astrophotography work motivates exposure splitting and sky-specific processing; Siril documents practical frame-quality and rejection tools. Neither supplies a drop-in Ceviche model. [Google Night Sight astrophotography](https://research.google/blog/astrophotography-with-night-sight-on-pixel-phones/), [Siril stacking](https://siril.readthedocs.io/en/stable/preprocessing/stacking.html).

**Special cases:** a tracked sky blurs the ground, so sharp foreground needs another suitable capture. Aurora, clouds, meteors, comets, and airglow can change independently of stars. Offer a short temporal window or selected-frame rendering for those regions. Meteor retention must be intentional; automatic outlier rejection can erase it.

**Acceptance focus:** faint-star recall, false stars, centroid/flux stability, star shape, terrain ghosting, and boundary halos. **Priority P0; large effort.**

## F3 — Milky Way and astro-landscape panorama

**Capture:** several overlapping sky/land panels, optionally a short burst per panel; optional dedicated foreground exposures. Initial scope excludes telescope mosaics with photometric calibration and general FITS/WCS processing.

**Experience:** show panels as groups. Let users fix grouping, capture order, and the chosen sky time. Separate **Sky alignment** and **Ground alignment** previews expose why a single panorama fit may fail.

**Proposed processing:** first align/stack the burst within each panel, preserving variance and coverage. Estimate celestial rotation between panels and map them to one sky epoch; independently solve terrain poses. With no reliable time metadata, fit sky correspondences empirically and ask for a reference capture. Time is a prior, not sufficient calibration by itself.

Fit panel exposure/background differences only in valid overlaps, excluding bright stars, foreground lights, and protected Milky Way structure. A low-frequency correction must not flatten the galaxy into the background. Solve a global panel graph rather than chaining pairwise transforms. Use spherical rays for wide sky coverage; add explicit wrap and pole handling before offering 360 degrees.

**Model opportunity:** XFeat/LightGlue for terrain, dedicated star-pattern geometry for sky, existing sky masks, and later DA3 Small for terrain parallax hints. Evaluate any learned warp only on the terrestrial layer initially.

**Failure behavior:** sparse stars, changing clouds, long gaps between panels, missing overlap, and moving silhouettes can leave physically unobserved areas. Preserve transparent coverage or crop; do not synthesize constellations.

**Acceptance focus:** star continuity across seams, retained Milky Way structure, reference-time consistency, horizon accuracy, and source coverage. **Priority P1; large effort; depends on F1 and F2.**

## F4 — Long exposure from a sequence

This workflow produces a blended still. For a movie that preserves the sequence's temporal progression, see the separate [timelapse video design](timelapse-video.md).

**Capture:** a sequence of short exposures showing moving water, clouds, pedestrians, or traffic. For the first version, prefer fixed aperture, focus, ISO, and white balance; explicitly normalize supported exposure changes.

**Experience:** choose a time interval and preview its appearance. Controls: **Smooth water/clouds**, **Keep subject sharp**, **Remove passersby**, and frame inclusion. Show both accumulated exposure and elapsed capture span; they are not the same when there are gaps.

**Proposed processing:** register the static scene; average scene-linear radiance over the chosen captures. Restrict alignment to stable terrain/buildings so optical flow does not freeze the water that the user wants blurred. A selected subject can come from one frame, while its surroundings are averaged. Passerby removal uses a separate robust/median-like temporal estimate; this is a different effect from physical exposure integration.

**Important distinction:** an average of equally exposed normalized frames retains average brightness while approximating sampled temporal blur. Summing can represent accumulated signal with appropriate exposure normalization. Neither exactly reproduces one continuously open shutter: read noise, capture gaps, clipped frames, and subject trajectories differ. Report these as capture properties, not a fabricated “equivalent shutter speed.”

**Model opportunity:** masks help assign motion policies. A large generative model is unnecessary for the first implementation.

**Failure behavior:** rippled seams, strobing clouds, or discontinuous trails arise from large time gaps. Do not silently interpolate missing events. Offer a shorter interval or a visibly labeled future creative gap-fill mode.

**Acceptance focus:** stable edges, correct mean exposure, smooth temporal rendering, subject-mask quality, and honest time metadata. **Priority P0; medium effort.**

## F5 — HDR landscape and bracketed panorama

**Capture:** exposure brackets with unclipped samples covering highlights and shadows, optionally grouped per panorama panel.

**Experience:** choose the reference moment and inspect motion regions. Controls: moving-object source, highlight priority, and bracket inclusion. Preserve an HDR/scene-linear result; perform the aesthetic tone mapping in Develop.

**Proposed processing:** infer bracket groups from metadata and overlap, then allow correction. Align each exposure using normalized matching proxies, but estimate radiance from the linear source and exposure metadata. Reject saturated channels and weight by usable signal/noise. In moving/occluded regions, select a valid reference source instead of averaging incompatible scene states.

For panoramas, start by merging brackets within each panel, then stitch panel results using common radiometry. Retain original contributors and exposure transforms to support a later joint solve. Do not run ordinary panorama gain matching first and accidentally erase intentional bracketing.

**Research opportunity:** DEBIR and the NTIRE 2025 burst-HDR work are useful experimental comparisons. DEBIR's exposure-selection component requires capture control, so only its restoration ideas transfer to already imported photographs. [DEBIR paper](https://arxiv.org/abs/2603.21784), [NTIRE burst-HDR report](https://openaccess.thecvf.com/content/CVPR2025W/NTIRE/html/Lee_NTIRE_2025_Challenge_on_Efficient_Burst_HDR_and_Restoration_Datasets_CVPRW_2025_paper.html).

**Failure behavior:** detail absent from every exposure cannot be recovered faithfully. Wind-blown leaves, rolling-shutter motion, artificial-light flicker, and fast clouds need local fallback. Prefer the least damaged source and show clipping/motion limitations.

**Acceptance focus:** highlight headroom, color under later edits, ghosting, and exposure consistency across panels. **Priority P1; large effort.**

## F6 — Calibrated night RAW enhancement

**Capture:** a single supported Bayer RAW, with trustworthy black/white levels and a validated source noise profile. Later: additional sensors, long-exposure calibration, and burst-aware restoration.

**Experience:** **Enhance → Night Detail** creates a reusable enhanced source, with noise strength and protected-detail controls. Show 100% crops of stars, foliage, and smooth sky. Preserve the original and make enhancement removable. The UI should distinguish a supported calibrated camera/ISO from a generic uncalibrated experiment.

**Proposed processing:** use PMRID as the first Bayer prototype because of the existing local conversion/evaluation evidence. Keep RawNIND as a separately evaluated linear/joint-demosaic alternative. Blend a controlled residual in the correct signal domain and retain saturation/bad-pixel masks. For star fields, validate any protective mask against independent data; protecting only stars already detected in a noisy image can still erase faint ones.

PNNP suggests a longer-term camera-calibration and synthetic-training direction. Its noise proxy is not itself a universal inference denoiser, and its released camera weights are not a noise profile for every Sony body. [PNNP](https://github.com/fenghansen/PNNP).

**Failure behavior:** unknown CFA layout, absent noise calibration, hot-pixel clusters, saturation, or out-of-domain imagery should retain the existing/manual path. Single-image neural inference cannot establish that a new faint point is a real star.

**Acceptance focus:** camera-held-out results, faint-detail retention, dark-sky artifacts, color/headroom, and subsequent editing speed. **Priority P1; medium–large effort.** See [existing Ceviche evidence](../../../experiments/denoise-evaluation/README.md); no results were rerun here.

## F7 — Star trails, traffic trails, and selective transient retention

**Capture:** a stationary sequence, with fixed settings preferred. Separate ground-camera movement from intentional sky/subject movement.

**Experience:** choose **Star trails** or **Light trails**, select the interval, and mark satellites, aircraft, meteors, or traffic to retain/remove. Offer natural trails and separately labeled creative fading/comet-style effects. Keep a clean foreground stack underneath.

**Proposed processing:** register the ground while preserving stellar motion. Detect excess signal over a local background and accumulate trails using a controlled brighten/max-like operation. Select by luminance while carrying the selected RGB sample together to avoid channelwise color mixing. Mask persistent hot pixels before accumulation; otherwise the max operator promotes noise. Use temporal evidence for transient suggestions and let users override them.

Siril documents pixel-maximum stacking for trails. The proposed RGB ownership and transient UI are Ceviche design choices. [Siril stacking](https://siril.readthedocs.io/en/stable/preprocessing/stacking.html).

**Failure behavior:** missed intervals produce gaps. A gap-filling aesthetic should never be represented as a continuously recorded meteor or airplane trajectory.

**Acceptance focus:** trail continuity where captured, stable ground, preserved color, and reproducible transient decisions. **Priority P1; medium effort.**

## F8 — Light-pollution and uneven-sky correction

**Capture:** a linear sky image, stack, or astro panorama with gradients from city glow, moonlight, or panel mismatch.

**Experience:** **Sky → Background gradient** shows the fitted background separately. Automatically suggest samples but let users move/delete them and protect the Milky Way, nebulae, aurora, or foreground. Offer **Subtract glow** and, only with an appropriate explanation, **Correct illumination** for multiplicative variation.

**Proposed processing:** fit a smooth low-order surface or regularized interpolant to trustworthy background samples, excluding stars and uncovered borders. Subtract additive sky glow; do not use the same operation as flat-field division. For mosaics, constrain relative corrections by overlaps. Preview the removed signal and allow strength adjustment.

Siril provides a useful classical reference. GraXpert is an AI comparator only after exact weight terms are resolved. [Siril background extraction](https://siril.readthedocs.io/en/latest/processing/background.html), [GraXpert](https://github.com/Steffenhir/GraXpert).

**Failure behavior:** diffuse astronomical signal may look like an unwanted gradient. Prefer undercorrection and user-selected samples over automatic removal of real structures. Keep negative intermediate values available internally instead of clipping away evidence of overcorrection.

**Acceptance focus:** injected faint structures, background smoothness, overlap consistency, and reversibility. **Priority P1; medium effort.**

## F9 — Focus-stacked landscape and macro

Detailed design: [focus stacking with breathing correction](star-motion-and-focus-stacking.md#2--all-in-focus-subject-and-background). This is a priority workflow following the photographer's explicit proposal, including ordinary subject/background scenes rather than only macro.

**Capture:** a focus bracket with stable exposure, covering near foreground through distant terrain; macro subjects are an extension with more severe magnification changes.

**Experience:** show a near-to-far source list and a focus-contribution map. Controls: reference frame, breathing correction, halo suppression, and **Use this frame** painting.

**Proposed processing:** align static structure while estimating focus breathing, compute multiscale sharpness confidence with a noise penalty, regularize source labels, and blend boundaries conservatively. Use DA2/DA3 depth only as a weak boundary prior: predicted depth cannot prove which capture is actually sharp. Handle occluding near objects with explicit source ownership, since blurred foreground can contaminate the background in other captures.

**Research context:** joint focus/depth reconstruction exists, but results on specialized capture systems are not validation for ordinary landscape brackets. Begin with a classical measured-focus baseline. [Focus-stack research example](https://openaccess.thecvf.com/content/ICCV2021/html/Wang_Bridging_Unsupervised_and_Supervised_Depth_From_Focus_via_All-in-Focus_Supervision_ICCV_2021_paper.html).

**Failure behavior:** wind, insects, missing focus planes, or extreme breathing may prevent a fully sharp result. Flag low-confidence areas instead of inventing texture.

**Acceptance focus:** sharpness by depth band, edge halos, thin structures, corrected breathing, and geometry. **Priority P1; large effort.**

## F10 — Detail reconstruction from a handheld burst

**Capture:** multiple overlapping RAWs with useful subpixel offsets and a largely static subject.

**Experience:** **Combine → More Detail** previews native-resolution and optional enlarged outputs side by side, with a confidence overlay. Offer **Natural detail** as the default objective; no generative texture synthesis in this mode.

**Proposed processing:** compare a robust registered average against multiframe sampling-aware reconstruction. Use local confidence to fall back around motion, occlusion, and insufficient sampling diversity. A tripod burst with nearly identical sampling can improve noise without delivering extra spatial detail.

Google's handheld multiframe work is a methodological reference for exploiting real CFA samples and motion robustness; the paper does not grant access to Google's production implementation or weights. [Handheld Multi-Frame Super-Resolution](https://research.google/pubs/handheld-multi-frame-super-resolution/).

**Acceptance focus:** resolved detail on controlled charts and natural textures, aliasing, false texture, color, and motion fallback. **Priority P2; large effort.**

## Suggested release grouping

- **First useful release:** F1 seam/source control, a basic F4 temporal average, and F2 tripod sky/ground stacking on an explicit supported input set. Deliver independently as they pass evaluation.
- **Second wave:** F9 focus stacking with breathing correction, F3 panel grouping/common sky time, F5 brackets, F7 trails, and F8 gradients. F6 proceeds in parallel only after calibration and star-preservation gates pass.
- **Later experiments:** F10, full 360-degree support, model-assisted local warps, experimental within-exposure star-trail restoration, and specialized telescope workflows.

Do not combine every correction automatically. A deghosting policy that helps HDR can remove a meteor; a registration field that helps denoising can destroy the motion intended for a long exposure.
