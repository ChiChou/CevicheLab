# Star trails, clean night skies, and meteor showers

Design update: **2026-10-29**. Proposed workflows informed by the user's requests, the [measured native experiment](../../../tools/starstack/COMPARISON.md), and a read-only survey of the aurora sequence. No application code changed. The new sequence has not yet been RAW-stacked or evaluated by a quality classifier.

## Three tools, shared analysis

| Tool | What stays fixed | Combination rule | Foreground |
| --- | --- | --- | --- |
| **Star Trails** | Camera/landscape coordinates; correct camera shake but preserve celestial motion | Maximum of observed samples; optional color-preserving selection | Reference or separately aligned ground mean |
| **Night Sky Denoise** | Sky at a reference epoch; ground in a separate coordinate system | Exposure-normalized weighted mean, with conservative rejection | Independent alignment/mean; reference fallback for moving regions |
| **Meteor Shower** | Denoised sky at a reference epoch; explicit event-position policy | Clean background plus selected measured event residuals | Reference or independent ground denoise |

The stellar warp used to make sharp stars would erase the motion needed for trails. Store **camera motion separately from celestial motion**. Static ground landmarks provide the preferred camera constraint. If these are insufficient, use a verified physical sky model or flag uncertainty rather than treating every stellar displacement as camera shake.

Shared stages: metadata timeline → exposure/scene segmentation → quality assessment → camera/celestial geometry → editable boundaries → role-specific source selection → tiled fusion → saved linear result and recipe. See [quality and exposure design](sequence-quality-and-exposure.md).

Maximum stacking and averaging with rejection are established baselines. The landscape and aurora policies below are our proposed extensions. [Siril stacking documentation](https://siril.readthedocs.io/en/stable/preprocessing/stacking.html).

## Star Trails

Controls: time range, reference framing, maximum mode, preserve star color, ground source, aurora source, transient review, and a timeline of captured exposure intervals and gaps.

Provide a literal per-channel maximum baseline: `output[c,x] = max_i(frame[i,c,x])` over valid selected samples with the chosen normalization. It can combine colors from different captures, accumulate positive noise and hot pixels, and let a bright dawn frame dominate. Calibrate defects before resampling and assess frame suitability before accumulating.

**Preserve star color** instead chooses a winning sample using scalar brightness/stellar signal and copies its RGB together. Persist the winning source index. Label this as an option, since it is not mathematically identical to per-channel maximum.

Two background treatments:

- **Maximum sky:** accumulate selected sky observations, including changing aurora; keep this literal baseline available.
- **Trails over chosen sky:** select one frame or a short interval for diffuse sky/aurora, then accumulate measured stellar contributions. Local background estimation and temporal stellar evidence must distinguish trails from noise and auroral detail. This more advanced separation requires its own validation.

Aurora and stars overlap along the same sightlines; a binary semantic mask alone cannot separate them. A diffuse atmospheric component and stellar component may be needed. When uncertain, preserve an ordinary maximum preview and offer a shorter interval rather than claiming perfect separation.

Preserve capture gaps by default. Optional **Reconstruct gaps** is a creative operation, off by default, with reconstructed regions recorded. Interpolated motion is not captured light. Excluding a frame can introduce a gap; show that consequence. Never simulate continuous exposure merely by holding a source frame longer.

Acceptance: observed trail positions/colors, stable ground, correct source ownership, explicit gaps, and no invented segments. Test camera shake, hot pixels, aircraft, bright dawn, aurora contamination and foliage boundaries against the literal maximum baseline.

## Night Sky Denoise: stars and Milky Way

Controls: reference epoch, selected interval, ground source, quality weighting, conservative rejection strength, star-preservation comparison and contribution/uncertainty overlays. Begin with measured multiframe averaging before optional learned restoration.

1. Develop consistent scene-linear data and account for black level, white balance, exposure and supported sensor calibration. Propagate variance through exposure normalization: multiplying samples by `g` multiplies variance by `g²`.
2. Use EXIF timing as an uncertain motion prior, verified by image correspondences. Estimate camera movement and lens distortion separately; compose transforms and resample each original once.
3. Align stars **and the celestial diffuse Milky Way** to the same epoch. Clouds, aurora and twilight backgrounds need different treatment because they do not follow celestial motion.
4. Compute `sum(w_i * I_i) / sum(w_i)` from valid samples. Weights reflect variance, coverage and alignment reliability. Keep an ordinary weighted-mean baseline visible alongside the robust variant.
5. Interpret bright residuals using noise and registration uncertainty before rejecting them. PSF differences, misregistration and genuine stars can resemble outliers. Handle saturation separately.
6. Align and average ground independently. Moving trees/people and thin uncertain boundaries may need a reference source. Respect per-source visibility; never average ground into sky that was occluded.

**Protecting stars requires more than a bright-star mask.** Such a mask misses the faint stars most at risk. Use independent subset stacks to build/test stellar support, measured PSFs and flux checks across brightness bins. Audit rejection around real and injected faint sources. Avoid weights based on a pixel's own noisy brightness or keeping only positive residuals, which can bias the mean. With insufficient support, lower confidence or retain a reference contribution instead of aggressively clipping.

A smoother image may have lost real detail. Measure the Milky Way's multiscale structure as well as background noise. Smooth background fitting must not subtract broad dust/emission structure. Generic denoisers and quality scores are not accepted solely because they produce clean-looking skies.

For independent, equally noisy, correctly aligned samples, mean noise standard deviation falls as `1/sqrt(N)`. Real sequences violate those assumptions. Display coverage and weight-based `N_eff = (sum w)^2 / sum(w²)` as support diagnostics; neither that number nor a high-frequency noise statistic alone establishes SNR for correlated/unequally noisy samples.

Acceptance: independent split-stack checks; injected PSF sources on realistic noise backgrounds; flux, color, detection completeness and false stars by brightness; width/elongation; diffuse Milky Way structure; horizon leakage and noise correlation. Hold out entire sessions. The existing meteor pilot does not establish faint-star completeness or Milky Way preservation.

## Meteor Shower: sparse event processing

Keep independent roles instead of one global include/exclude flag:

| Frame condition | Motion analysis | Clean sky/ground | Meteor detail |
| --- | --- | --- | --- |
| Good, no candidate | Yes | Yes | Skip expensive event extraction/compositing |
| Good, event candidate | Yes | Use unaffected samples; mask event | Refine and review |
| Saturated event region, useful stars elsewhere | Reliable stars only | Reliable regions only | Review; do not claim clipped detail recovered |
| Poor sky, useful ground | Where supported | Ground only | Review if evidence or uncertainty warrants |
| Unreadable/incompatible | No, or separate group | No | Explain exclusion; preserve source |

First analyze all usable captures for geometry, quality and background; screen low/medium-resolution line residuals. Escalate candidates, uncertain negatives and audit samples to higher resolution. Thin/faint meteors can disappear on proxies: “not detected” is not proof of absence. Offer a sensitive full-resolution scan and retain neighbors for temporal classification.

Then extract high-resolution event details only from candidate tiles. Meteor-free frames still contribute to star-motion fitting and noise reduction. This saves event analysis, storage and compositing, **not all RAW decoding or warping** needed for the background stack.

Detect positive source-to-background residuals and restore measured RGB with a feathered source-owned footprint. Prevent an event from contaminating its own background using exclusion masks, verified robust integration or leave-one-out estimation. Adjacent differences can flag the same event twice: deduplicate by source interval/track. Persistent lines support aircraft/satellite review, not infallible classification.

Default presentation: **common sky epoch**, applying the background's stellar transforms to each selected event. Optional **as captured** preserves camera/ground-coordinate placement. Explain the distinction, especially for multi-hour apparent radiant patterns. A selected event is never reconstructed from maximum values taken independently across RGB channels.

Acceptance: recall of faint/thin events, false alarms, temporal deduplication, residual/color retention, protected ground and runtime by stage. Optimize screening only after measuring what it misses.

## Shared execution and implementation order

CPU handles small geometric fits/policy; Metal handles dense resampling and reductions when benchmarks justify it. Mean can stream sums/weights; maximum can stream winners/source IDs. Robust integration needs spatial tiles retaining the complete temporal statistics, not independent clipped temporal chunks averaged together. The existing 64-frame resident benchmark does not scale directly to this 172-frame sequence or full RAW resolution.

Persist per-role decisions/reasons, timestamp uncertainty, exposure normalization, camera versus celestial transforms, quality/model versions, overrides, weights/coverage and event provenance. Reuse analysis across tools but invalidate dependent decisions when mode, interval, reference or masks change.

Proposed order: (1) quality timeline and literal maximum baseline; (2) separate sky/ground mean with star-preservation tests; (3) sparse meteor detail work; (4) aurora/stellar separation and ML quality assistance. These are designs, not implemented features.

## Aurora sample: observed facts and test roles

Source: `/path/to/samples/Aurora-timelapse-2024-10-11/`. Surveyed read-only on **2026-10-29** with the existing survey executable. [Metadata](../../../tools/starstack/output/aurora-survey-2026-10-29/metadata.json), [summary](../../../tools/starstack/output/aurora-survey-2026-10-29/summary.json), [early previews](../../../tools/starstack/output/aurora-survey-2026-10-29/contact-0001.png), [last 12 previews](../../../tools/starstack/output/aurora-survey-2026-10-29/contact-0161.png). Generated survey files are local ignored artifacts.

- **172 ARWs and 172 XMPs**, DSC03187–DSC03358. Sidecars counted, not applied/modified. Embedded JPEGs are reconnaissance, not linear stacking inputs.
- Sony ILCE-7RM3; reported **7952 × 5304**, **39 mm, f/5.6, ISO 1600, 13 s** throughout exported metadata.
- Camera time **2024-10-11 01:11:52–05:30:19**: **4 h 18 min 27 s** start-to-start. No timezone/subsecond fields in the exported records; these are not asserted UTC times.
- Start intervals: **158 × 96 s**, **1 × 95 s**, **5 × 14 s**, **5 × 13 s**, **1 × 32 s**, **1 × 77 s**. Assuming EXIF marks exposure start, the usual cycle has about **83 s unexposed**. Show these gaps without treating cadence alone as poor image quality.
- **DSC03188–DSC03198** is an 11-frame interval at 13–14 s cadence: a useful short, nearly continuous trail baseline. Later frames test sparse arcs and long-span motion.
- Late embedded previews visibly brighten toward a daylight-like sky while exposure settings stay constant. This supports testing real scene change instead of assuming a camera exposure jump. RAW clipping/recoverability, focus, shake and segmentation quality remain unmeasured.

Test dense early maximum, full sparse-interval maximum, night-only versus transition-inclusive selection, fixed aurora reference versus maximum sky, and per-role quality decisions. This is not a validated Milky Way ground-truth dataset; event-like lines also require review.
