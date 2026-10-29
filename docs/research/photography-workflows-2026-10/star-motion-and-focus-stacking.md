# Star-motion correction and focus stacking

Design expansion, **2026-10-28**, based on the photographer's two proposed workflows. These are specifications and research notes; no application code or model integration is included.

Both features need **separate geometry estimation and detail fusion**. Estimate where each source sample belongs, then decide which samples should supply the final image. Keep the transformations, contribution maps, and user corrections in the derived-image recipe.

## 1 — Sharp stars with a stationary foreground

### What the feature should do

The photographer selects a sequence of nighttime captures. Ceviche separates sky from the rest of the scene, tracks stars across captures, warps the sky to a common reference moment, and combines it with an independently aligned foreground. Trees and mountains remain stationary while the stars become sharper and less noisy.

The requested “morph” should initially be a physically constrained coordinate warp. Stars moving together across the celestial sphere provide a strong shared constraint; independent arbitrary warps around individual stars could distort constellations or turn noise into apparently consistent features.

### Two different kinds of motion

| Input condition | Proposed treatment | What it can accomplish |
| --- | --- | --- |
| Several exposures, stars sharp within each but displaced between them | Track, warp, and stack the sky separately | Correct inter-frame motion and combine real observations |
| Several exposures, some with short trails | Estimate inter-frame geometry; select sharper evidence or test motion-aware restoration | Improve the result where enough usable information exists |
| One long exposure with visible star trails | Experimental spatially varying deconvolution | Potentially reduce limited trailing; cannot promise recovery of a sharp original |

Moving an already blurred trail to another position does not undo the integration that created it. Registration and deconvolution are distinct operations. Siril documents both [sequence registration](https://siril.readthedocs.io/en/stable/preprocessing/registration.html) and the limitations of recovering detail from an estimated [point-spread function](https://siril.readthedocs.io/en/stable/processing/deconvolution.html).

### Proposed processing stages

1. **Inspect the sequence.** Group captures by scene; build an exposure timeline from original EXIF timestamps, fractional seconds, and exposure durations. Use it to predict stellar motion before matching. Estimate trail extent, cloud interference, and foreground camera shake. Show whether the selected inputs primarily need alignment, trail restoration, or both.
2. **Create editable masks.** Begin with Ceviche's sky mask, refine at source resolution, and let the photographer correct the horizon. Keep uncertain boundaries around foliage and cables. Treat clouds/aurora separately when their motion disagrees with the stars.
3. **Find trustworthy stars.** Detect unsaturated point sources and short-trail candidates at multiple scales; measure position, brightness, shape, and uncertainty. Exclude known sensor defects. Persistent sensor-coordinate points are a useful hot-pixel cue when the sky moves, but not conclusive for tracked captures.
4. **Associate star patterns.** Match neighborhoods or triangles rather than brightness alone. Verify associations across multiple frames, reject outliers, and retain track confidence. If severe blur makes centroids ambiguous, mark tracking as unreliable instead of silently forcing a fit.
5. **Fit one sky motion model.** Start with calibrated lens rays and a time-conditioned rotation model. For a stationary camera, use the known approximate sidereal rate and EXIF time differences as strong constraints, fitting the shared celestial axis and checking the result against observed tracks. Allow separately estimated camera movement when the tripod shifted. Weight timing constraints by metadata reliability; nominal focal length still needs geometric verification. For narrow fields, a simpler transform can be a validated approximation.
6. **Solve foreground motion independently.** Fit the ground from terrain/building features; do not let stellar motion move it. Select a sharp ground reference or combine well-aligned ground frames. A tracked sky capture may require a separately captured foreground.
7. **Render a common reference.** Choose a reference exposure and sky epoch. Compose lens correction and sky/ground transforms, then resample original-resolution pixels as few times as possible. Track valid coverage for each layer, including which sky regions were obscured by the foreground in each input.
8. **Fuse and composite.** Use a robust sky stack with optional transient retention and a separate ground estimate. At silhouettes, use validity-aware source selection and refined mattes; a broad feather can produce halos or double branches. Preserve unsupported borders as transparent or crop them.

**Sky warp model, proposed:** for a source pixel `p_i`, solve its normalized source-camera ray with inverse lens distortion and intrinsics, rotate that ray into the reference camera/sky-time coordinate system, then project it into the chosen output. The rotation includes relative camera pose and celestial motion where both are estimated. Rendering should use inverse sampling; do not confuse the source-to-reference mapping used in fitting with the output-to-source mapping needed by the resampler.

### EXIF time as the backbone of the motion model

Capture time is more than an ordering hint: it supplies the independent time coordinate for fitting the entire sequence. Exposure duration supplies each frame's integration interval. For reliable metadata and a stationary camera, estimate a shared motion law rather than unrelated per-frame displacements.

**Read the original capture metadata:**

| Field | Proposed use |
| --- | --- |
| `DateTimeOriginal` + `SubSecTimeOriginal` | Capture timestamp with available fractional precision; retain the original values and precision |
| `OffsetTimeOriginal` | Interpret a recorded timezone offset when present; do not infer the capture timezone from the Mac's current timezone |
| `ExposureTime` | Exposure duration in seconds, retaining the rational value; do not interpret APEX `ShutterSpeedValue` directly as seconds |
| Optional camera-specific timing or GPS time | Cross-check or refine timing only when its event semantics and synchronization are known |

Tag identities and time relationships are documented in the [ExifTool EXIF table](https://github.com/exiftool/exiftool/blob/master/html/TagNames/EXIF.html). File modification/import/export times are not substitutes for capture time.

**Use exposure midpoints for initial frame alignment.** If a camera's timestamp is verified to describe exposure start, define:

```text
start_i = parsed original capture time
duration_i = ExposureTime
mid_i = start_i + duration_i / 2
delta_i = mid_i - mid_reference
```

The EXIF tag name alone does not guarantee an exact shutter-start event. Record a camera-specific timing convention when verified; otherwise treat start/midpoint/end interpretation and timestamp quantization as uncertainties. For uniformly exposed, approximately steady sources, the midpoint is a useful initial reference. Full trajectory integration handles curved trails and changing intensity more accurately.

Example: a 10-second exposure starting at `22:00:00` has midpoint `22:00:05`; a 30-second exposure starting at `22:00:40` has midpoint `22:00:55`. Their alignment separation is **50 seconds**, despite a 40-second difference between start timestamps. Capture gaps remain part of the timeline; never replace actual intervals with frame index times a nominal cadence.

**Constrain rotation using sidereal time.** For short photographic sequences, the approximate angular rate about the celestial pole is `omega ≈ 2π / 86164 seconds`, or about **15.041 arcseconds per second**. This is a rotation angle, not a uniform pixel displacement or every star's angular path speed. The projected movement depends on the star's position relative to the pole, camera orientation, focal length, and distortion. [US Naval Observatory sidereal-time reference](https://aa.usno.navy.mil/data/siderealtime).

For a stationary camera, a proposed predictor is `ray_j(t) = Rot(axis, omega * (t - t_reference)) * ray_j(reference)`, with the signed axis convention fitted consistently. Estimate the axis and reference rays from observed tracks, project through the calibrated lens, and use predictions to narrow the next frame's matching search. Jointly refine across all frames with robust residuals and confidence weights. This can stabilize weak individual matches, but insufficient star evidence must still produce low confidence.

Absolute UTC/GPS location and plate solving can strengthen the orientation prior, but same-camera relative alignment does not require them: a constant clock offset cancels in time differences. Clock drift, timestamp jumps, incorrect durations, and mixed camera clocks do not cancel. Do not fit unconstrained per-frame clock offsets that merely absorb bad geometry. If the camera is tracking the sky, or has moved, model its motion separately; the apparent sky rate can differ greatly from a fixed-tripod prediction.

**Use duration to predict blur as well as displacement.** Integrate the projected path over `[start_i, start_i + duration_i]` to estimate each star's motion blur. This informs frame quality, source weighting, and the experimental restoration kernel. Duration also enters radiometric normalization, but a long exposure should not automatically receive the greatest fusion weight: blur, clipping, noise, clouds, and valid coverage also matter.

**Validation:** compare image-only, time-only prediction after calibration, and joint timing-plus-image fits on held-out star tracks. Include unequal durations, irregular gaps, whole-second timestamps, missing offsets, midnight crossings, deliberate clock errors, camera shake, and tracked sequences. Store raw timing values, interpreted intervals, assumed event convention, uncertainty, and fit residuals in the recipe. Fall back to image-based registration when metadata disagrees with reliable visual evidence.

### Experimental correction of trails inside an exposure

Model the observed sky as a time integral of a sharper latent sky under the estimated motion, plus optical blur, sky background, and sensor noise. Exposure duration and tracks from adjacent captures can constrain the path. On a wide-angle frame the direction/length of the trail varies across the field; a single constant linear kernel is only a local approximation.

Evaluate a regularized, spatially varying reconstruction with the measured noise model. Use short/sharp frames as anchors when available. For a single exposure, blur and scene content are less identifiable: coma, poor focus, shake, saturation, and overlapping trails can mimic or compound rotation blur. This remains an experimental extension rather than the default stack mode.

Check a proposed restored result by forward-projecting and reblurring it into the input exposures, inspecting residuals as well as star shape and flux. Data consistency is necessary but insufficient—an ill-posed reconstruction can still invent detail. Require independent/injected-star evaluation and reject unstable results. A learned restoration prior must earn its place against this baseline; it must not simply replace every elongated point with an attractive round star.

### User controls and review

- **Align stars** and **Align foreground**, with separate overlays and a shared output preview.
- Reference frame/time, editable sky boundary, and source inclusion.
- **Preserve meteor/aurora** region or chosen time window.
- A separate **Reduce existing trails · Experimental** control only for the restoration extension.
- Before/after crops of center stars, corner stars, and the skyline; show failed tracks and insufficient coverage.

**First milestone:** a supported tripod sequence with mild inter-frame movement, separate sky/ground registration, and no automatic within-exposure deblurring. **Second milestone:** robust wide-field/camera-motion handling. **Research milestone:** constrained trail restoration with explicit recoverability assessment.

## 2 — All-in-focus subject and background

### What the feature should do

The photographer takes a focus bracket from approximately the same position and angle over a short interval. Ceviche corrects framing changes caused by focusing, chooses the genuinely sharp regions from each exposure, and merges them into a photo with extended depth of field.

“Without bokeh” means using sharp observations from other focus planes. It does not mean a depth mask can reveal detail blurred in every input. Capture must cover the desired near-to-far range with overlapping in-focus regions.

Established products explicitly align before focus fusion; Helicon exposes scale/shift/rotation controls for focus-stack alignment. These support the workflow distinction, not the superiority of a particular Ceviche algorithm. [Adobe extended-depth-of-field workflow](https://helpx.adobe.com/photoshop/desktop/create-masks/blend-images/create-a-composite-with-extended-depth-of-field.html), [Helicon alignment controls](https://www.heliconsoft.com/focus/help9/english/HeliconFocus.html).

### Correct focus breathing before selecting detail

1. **Check capture consistency.** Same camera/lens and scene; fixed aperture/exposure preferred. Treat focus distance/order metadata as optional and approximate. Detect subject movement or framing jumps separately from focus changes.
2. **Choose the output framing.** Anchor one frame's geometry and show the intersection of valid coverage. Breathing compensation usually costs border coverage; selecting a wider output cannot create the missing edges of a tighter frame.
3. **Estimate a conservative transform.** Start with translation, small rotation, and isotropic scale about a fitted center. This captures simple apparent magnification changes. Do not assume every lens breathes as a perfect global zoom.
4. **Use evidence robust to defocus.** Match neighboring focus planes where some structures remain identifiable, and add direct reference links where available. Use coarse structure, gradient orientation, and deliberately blurred matching proxies to reduce unequal-sharpness bias. Pixels used for output remain the original linear samples.
5. **Solve the stack jointly.** Refine the transformation graph with the reference fixed, so pairwise scale errors do not accumulate. Smooth variation with focus order is a soft prior, not a requirement that the photographer supplied a sorted stack.
6. **Escalate only when justified.** If a similarity transform leaves structured residuals, test focus-dependent distortion and a tightly regularized local warp. Focus-related entrance-pupil shifts or actual camera translation can create depth-dependent parallax; a single homography cannot always correct a three-dimensional scene. Reject folds and stretched object edges.
7. **Freeze and compose transforms.** Use the same accepted geometry for all fusion methods and source-retouch views. Compose transformations and resample once for final fusion; source indices must remain meaningful after any reordering.

Display an optional diagnostic graph of relative scale versus frame, alignment confidence, and the proposed crop. Most photographers only need **Correct focus breathing**, a reference selection, and a crop preview; the graph helps inspect unusual lenses and failed captures.

### Decide what is sharp, then merge

Compute a per-frame, multiscale focus-confidence map after alignment. Compare local detail while accounting for noise, exposure, saturation, and alignment uncertainty. A noisy or sharpened frame can otherwise falsely win the “sharpest” test.

Produce a **source-index map** describing which frame supplies each region. A derived focal-index/depth map can regularize coherent surfaces and protect boundaries, but it is not necessarily metric depth. Monocular DA2/DA3 depth is an optional weak prior, not a substitute for inspecting focus across the actual bracket.

At high-confidence detail, prefer the sharp source. Near transitions, compare conservative edge-aware label blending with a multiscale fusion baseline. Unrestricted soft averaging can reintroduce blur; hard selection can create discontinuities. Use one coherent set of weights for RGB channels to avoid color fringes.

Handle defocus occlusion explicitly: a blurred foreground silhouette spills into the background in other frames. A depth boundary and a feather alone will not remove that spill. Select the capture with the least contaminated sharp evidence, offer source painting, and flag areas where the stack contains no clean observation.

### Research candidates

Start with measured focus confidence and a classical fusion baseline. Compare [Petteri Aimonen's focus-stack](https://github.com/PetteriAimonen/focus-stack), which documents ECC alignment and complex-wavelet fusion; its [code license](https://github.com/PetteriAimonen/focus-stack/blob/master/LICENSE.md) is MIT. Audit dependencies before reuse; this note copies no implementation.

[StackMFF V3](https://github.com/Xinzhe99/StackMFF-V3) is a current October 2026 candidate that predicts per-pixel source probabilities from an already registered stack. Its manuscript is in preparation, not an established peer-reviewed 2026 paper. Code is MIT, but the inspected release documentation does not establish an explicit separate checkpoint grant. See the expanded [model ledger](models-and-licenses.md#focus-stacking-follow-up--october-2026). A fusion model does not perform breathing correction merely because it accepts multiple frames.

An earlier [real-world focus-stacking paper](https://arxiv.org/abs/2311.17846) provides a relevant high-resolution RAW-burst evaluation direction. Its targets are pseudo-ground-truth produced with commercial software, so agreement with them is not proof of optical truth. Inspect original dataset permissions before use.

### User controls and acceptance

Offer **Everything sharp** as the initial intent, with a near-to-far filmstrip, **Correct focus breathing**, reference framing, auto crop, and source painting. Show **Sharpness coverage** and **Source contribution** overlays. Let the user preserve a moving subject from one frame, accepting that this region may retain that frame's depth of field.

Evaluate breathing correction independently from fusion: measure withheld landmarks and line geometry before judging sharpness. Test lenses with weak/strong breathing, irregular focus order, defocused reference frames, thin branches/hair, specular bokeh, noise, and missing focus planes. Compare each selected region against its sharpest valid original; inspect halos, crop loss, and distortion.

**First milestone:** stationary ordinary focus brackets, similarity-scale correction, classical sharpness fusion, and retouchable source ownership. **Second milestone:** difficult lenses, depth-dependent residuals, and occlusion handling. **Research milestone:** learned source selection with verified weight terms and scene-linear/HDR validation.
