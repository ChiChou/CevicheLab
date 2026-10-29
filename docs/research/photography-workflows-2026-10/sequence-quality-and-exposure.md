# Sequence quality, exposure repair, and irregular timing

Proposed design, **2026-10-29**, shared by the [three astro tools](astro-scenario-tools.md) and timelapse. This is a specification, not an implemented classifier or quality gate.

## Assess usefulness per task

Decisions are **per frame, region and role**: **Use**, **Use with correction**, **Downweight**, **Analysis only**, **Review**, **Exclude from this output**. Preserve originals and make decisions reversible. A frame unsuitable for a night sky can still provide good ground, motion evidence or a unique meteor.

Avoid one universal quality score. Star elongation is desirable for trails, undesirable for sharp-star denoise, and potentially evidence of an event. Bright aurora can lower star contrast while being the subject. Rank within compatible sequence segments and expose the reasons.

## Heuristics and CV first

| Evidence | Interpretation | Possible action |
| --- | --- | --- |
| Decode integrity, dimensions, lens/framing changes | Corrupt/incompatible capture or changed scene | Exclude unusable data or split groups |
| RAW black/white levels and regional per-channel clipping | Lost versus usable detail | Mask clipped regions; isolated saturated stars need not exclude a whole frame |
| Exposure settings plus linear sky/ground luminance | Camera jump versus real illumination change | Correct compatible observations; segment changed lighting |
| Star PSF width/elongation and fit residuals | Focus, exposure trailing, shake, alignment confidence | Mode-specific weighting or review |
| Ground feature motion/residuals | Camera motion versus moving subjects/trees | Stabilize camera; choose source regions for subject motion |
| Background variance, gradients and fixed-pattern noise | Information after exposure correction | Weight by useful signal/variance, not ISO alone |
| Clouds, haze, aurora and stellar visibility | Atmospheric changes | Shorten interval or separate background treatment |
| Timestamp precision and exposure intervals | Motion uncertainty and coverage gaps | Widen matching search; show gaps; retain good irregularly spaced frames |

PSF measurements must account for field position, exposure duration, saturation and SNR. Star counts alone would penalize twilight and bright aurora. Global Laplacian sharpness can reward noise; keep dedicated sky/ground evidence.

Siril provides useful references for weighting/rejection diagnostics and separating transformation estimation from rendering. Our role-specific selection adds application policy around those measurements. [Stacking](https://siril.readthedocs.io/en/stable/preprocessing/stacking.html), [registration](https://siril.readthedocs.io/en/stable/preprocessing/registration.html).

## Exposure: correct, segment, or exclude

1. **Measure linear RAW information.** A JPEG preview can suggest a problem but cannot prove RAW clipping/recoverability. Inspect channels and regions against sensor black/white levels; retain highlight headroom.
2. **Use actual elapsed time.** Plot exposure settings, regional brightness, clipping, variance and usable stars. Fit robust time-aware trends/change points; do not smooth across unsupported gaps or assume frame index equals time.
3. **Distinguish capture changes from real scene changes.** Combine EXIF with robust overlap/region evidence. Constant settings and coherently brightening sky may indicate dawn. Changing aurora is real signal. EXIF alone cannot establish the cause; ISO is not a complete radiometric calibration.
4. **Normalize compatible observations.** Recover a camera-induced exposure jump using constrained linear gains and supported offsets, excluding clipped pixels/events and propagating variance. Avoid flexible local corrections that can subtract Milky Way structure or aurora. Preview both correction and remaining mismatch.
5. **Reassess after correction.** A large lift raises noise. Lowering displayed exposure cannot recover sensor-clipped star/color data. Downweight poor information and retain useful unclipped regions where possible.
6. **Split lighting regimes when needed.** Night, twilight and daylight may deserve separate groups. A dawn frame can be excluded from the night trail sky but explicitly offered for foreground. Timelapse should retain real night-to-day evolution while smoothing capture-induced discontinuities; do not automatically normalize daylight back to night.

No universal hidden “too bright” threshold. Start with inspectable conservative rules and segment-relative comparisons, then calibrate thresholds on labeled cameras/scenes. Ambiguous cases go to Review. A changed exposure setting alone is not grounds for rejection; successful correction can preserve its contribution.

## Irregular timing

Persist original EXIF, fractional precision/offset when available, exposure duration, inferred integration intervals and uncertainty. Use mid-exposure time for alignment where justified and full integration intervals for motion blur/trail coverage. A long gap increases prediction uncertainty and may require fresh image matching; it is not inherently a bad photograph.

If metadata is missing/inconsistent, use image evidence with downgraded timing confidence. Do not silently invent a regular schedule. A gap plus a camera/scene change can trigger a new group; a gap alone need not. A real-time timelapse policy uses capture times; a fixed-frame-rate creative sequence may intentionally compress time, explicitly.

## CV/ML assistance

First evaluate a small calibrated classifier/ranker on measured features: RAW clipping/variance, PSF statistics, registration residuals, regional brightness, exposure metadata and time-aware context. Output role suitability, confidence and reason probabilities. A unique bright meteor must not be rejected simply because neighboring images lack it.

Later test source-resolution star/ground crops plus a whole-frame proxy. Downsampling should not remove tiny stars before judging whether they survive. General multiscale quality research such as [MUSIQ](https://openaccess.thecvf.com/content/ICCV2021/html/Ke_MUSIQ_Multi-Scale_Image_Quality_Transformer_ICCV_2021_paper.html) is a useful architectural reference; its general-photo evaluations do not establish performance on these RAW sequences. No checkpoint is selected here. Check exact code, weights and data terms before adopting an external model.

Labels should cover **role suitability, recoverability and reasons**, not just attractiveness. Split evaluation by entire capture session/camera/location, not neighboring timelapse frames. Measure false rejection of unique meteors, faint-star-rich images and intentional aurora separately from average accuracy. Calibrate confidence, abstain on unfamiliar conditions, and retain user corrections/model versions.

## UI and persistence

Timeline/filmstrip badges: **Use / Correct / Review / Excluded**, with separate sky, ground, motion-analysis and meteor-detail roles. Clicking a badge shows affected regions, measurements and a correction preview: “Sky unsuitable for this night stack; ground available,” or “Capture gap; frame retained.” Show lost trail segments and reduced coverage caused by exclusions.

Offer **Auto-select**, **Restore all**, **Keep this frame**, region overrides and sensitivity. Recompute dependent decisions when intent, interval, reference or masks change. “No meteor candidate” skips event-detail processing while retaining other contributions. Exclusion never deletes originals or overwrites XMPs.

## Evaluation using the aurora sample

The [survey](astro-scenario-tools.md#aurora-sample-observed-facts-and-test-roles) found 172 constant-setting 13-second RAWs, irregular opening cadence, mostly 96-second later cadence, and visibly brightening late previews. RAW clipping and ML quality have not yet been measured.

Label dense opening captures, sparse night frames, changing aurora, the brightening tail, and any actual focus/shake/cloud failures found by inspection. Compare all-frame, hand-curated and automatic per-role selections. Measure trail gaps, source decisions, star flux/completeness, ground quality, event recall where applicable and user override rate. Test exposure correction on real examples plus controlled changes with known noise/saturation; a nicer tone-mapped preview is not evidence of restored clipped detail.

First deliverable: explainable quality report and proposed selections, followed by reviewed labels for evaluation. Automatic production rejection follows measurement; the current survey does not establish that the proposed gate works.
