# Handling night-to-day and day-to-night transitions

Design **2026-10-29**, informed by the aurora maximum-stack experiment. This is a proposed production solution, not a claim that atmospheric/stellar separation has been implemented.

## The observed problem

The aurora sequence held exposure settings constant while the sky brightened. Maximum stacking let late daylight-like frames dominate the diffuse sky. The [first experiment](../../../tools/starstack/AURORA-TRAILS.md) excluded ten frames using a sample-tuned brightness rule. That is a useful baseline, but it discards their sky contribution wholesale and can misclassify a bright aurora on other nights.

A general solution needs **temporal scene segmentation, recoverability checks and separate component policies**. Applying negative exposure compensation to a daylight frame does not restore the star-to-background contrast or signal-to-noise ratio of nighttime.

## 1. Separate capture changes from illumination changes

Read exposure time, aperture, ISO/gain, black/white levels, focal length, camera identity, and original timestamp precision. Detect regional changes using actual elapsed time, with a robust trend model and change points. Fit sky, ground and highlights separately; avoid treating every difference from the first frame as a fault.

- **Camera-setting jump, scene stable:** estimate a constrained radiometric correction using unsaturated overlaps and supported metadata. Propagate variance and verify image residuals after correction.
- **Real smooth twilight transition:** preserve it as a lighting regime, rather than undoing it as if it were a capture error. Use continuity and persistence to avoid unstable selection near a boundary.
- **Local or fast atmospheric change:** use spatial evidence for aurora/clouds and keep an uncertain state. Global brightness or blue color alone is insufficient.
- **Clipping or buried signal:** reject the damaged region for the role requiring that information; retain other usable roles. No display adjustment proves recovery of lost data.

Use hysteresis around state boundaries, with duration measured in seconds and capture support recorded. A single exceptional exposure can still be flagged immediately. Missing/irregular intervals increase uncertainty; they are not image defects.

## 2. Give each photographic output a clear policy

| Output | Recommended transition policy |
| --- | --- |
| Night star trails | Choose a night-background reference/short interval. Accumulate only measured stellar contributions with sufficient local SNR; later bright images may still supply useful star segments or ground. Retain a literal maximum baseline. |
| Sharp-star/Milky Way mean | Average compatible celestial observations in a common epoch, weighting by variance after any radiometric correction. Exclude/downweight twilight where background shot noise or changed structure destroys useful information. Never normalize broad Milky Way structure away. |
| Meteor shower | Keep usable background/geometry roles, and assess unique event visibility independently. A meteor in a bright frame deserves review even when that frame is unsuitable for the clean night sky. |
| Night-to-day timelapse | Keep the illumination progression. Smooth capture-induced exposure discontinuities around a slowly changing target brightness curve, not a constant night level. Respect intentional brightness changes and highlight headroom. |
| Mixed-lighting foreground composite | Explicitly choose a ground time/interval. Offer daylight foreground as a deliberate creative selection, not an automatic replacement for nighttime terrain. |

## 3. Better star trails than whole-frame exclusion

For each usable observation, model scene-linear sky as **diffuse background plus recorded stellar/transient signal**, with source validity and noise estimates. The background model must be constrained in scale and space: broad aurora/Milky Way structure is real light, and subtracting it indiscriminately can distort the result.

Estimate stellar support using the shared celestial motion model, local PSFs and temporal consistency. Extract measured RGB residuals where the evidence supports them. Accumulate those residuals in camera coordinates for trails, over the photographer's chosen background. Do not independently maximize RGB residual channels when preserving star color is requested. Retain source ownership, uncertainty and integration intervals.

Late frames can contribute high-confidence bright-star segments even if their diffuse sky is too bright. If faint stars are no longer measurable, display reduced trail coverage rather than constructing unobserved segments. Invalid/occluded areas stay invalid; optional gap reconstruction remains separately labeled creative processing.

This decomposition is a research stage. A positive-only residual or an unconstrained high-pass filter will promote noise and can destroy flux/color. Validate against captured star PSFs and injected sources before replacing the current frame-filter baseline.

## 4. Quality and controls

UI: timeline states **Night / Transition / Day / Uncertain**, alongside independent sky, ground, geometry and event roles. Let the user choose the target sky background, allowed transition span and quality sensitivity. Show source contributions, actual gaps and the effect of restoring an excluded frame. Defaults should propose selections, with reversible overrides.

Start with interpretable CV/metadata features. A later quality model should predict recoverability and role suitability, with calibrated confidence and abstention. Train on labeled sessions containing dawn, dusk, aurora, clouds and exposure jumps; split tests by entire session/camera, not adjacent images. A generic aesthetic score is not a rejection policy.

## 5. Evaluation and implementation sequence

1. Improve the existing brightness baseline with regional time trends, hysteresis, exposure-change attribution and per-role decisions. Audit on the aurora sequence; do not call one tuned threshold universal.
2. Add per-pixel variance/support and reference-background previews. Compare all-frame, manually selected and automatically selected results with identical display transforms.
3. Prototype background/stellar decomposition on controlled transition intervals, preserving a literal-maximum comparison. Measure star flux/color, completeness by brightness, false trails, aurora structure and skyline artifacts.
4. Add a separate timelapse brightness-curve optimizer. Evaluate flicker and clipping while preserving the genuine day/night trend. Scene-changing gaps should not be silently bridged.

No operation should claim to recover sensor-clipped detail or stars below the measurable signal floor. Correct exposure scale, preserve real illumination changes, and retain useful information by region and role.
