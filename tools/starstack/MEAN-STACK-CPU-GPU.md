# Mean stacking: Bitterli reference and retained CPU/Metal backends

Recorded **2026-10-29**. User requirement: **keep both CPU and GPU versions for future development**. This note records the algorithm reference and development contract. Follow-up implementation and measured results are in the [joint-fit Tenerife rerun](TENERIFE-JOINT-MEAN.md): CPU and Metal mean renderers now exist, while several broader proposals below remain unimplemented.

## Reference and evidence

[Benedikt Bitterli — Star Stacker: Astrophotography with C++11](https://benedikt-bitterli.me/astro/) describes:

1. A local background mask and patchwise linear least-squares light-pollution estimate.
2. Difference-of-Gaussians blob detection across scales, followed by background-aware Gaussian star localization and pruning.
3. Triangle constellation matching to bootstrap rotation estimates.
4. Nonlinear refinement of rotations and a shared focal length, followed by a global adjustment using observations across frames.
5. Inverse reprojection into a reference camera and averaging.

Its camera assumes centered projection and negligible distortion. The example uses 8-bit JPEGs and omits dark-frame correction; the author identifies both as limitations. The article is an algorithm explanation, not a demonstrated Apple GPU implementation. No accompanying source repository or explicit code-reuse license was established in this review. Attribute the reference; do not assume its prose, images or any subsequently located code are permissively licensed.

## What already exists locally — preserve these paths

| Path | Current role | Limit |
| --- | --- | --- |
| [fullres_mean.py](scripts/fullres_mean.py) | CPU reference for two five-frame 42 MP groups; EXIF focal/time geometry, native centroid refinement, separate sky/ground arithmetic means | Sample-specific Python/NumPy/OpenCV path; not a complete native Metal implementation |
| [StarStackCore](Sources/StarStackCore/Pipeline.swift) | Native Swift registration, inverse morph and robust background integration | Earlier meteor integration differs from the Tenerife ordinary mean |
| [Benchmark.swift](Sources/nativebench/Benchmark.swift) and [Kernels.metal](Sources/nativebench/Kernels.metal) | Existing CPU/Metal comparisons for inverse warp and robust integration | Resident benchmark supports at most 64 frames; bilinear sampling and robust rejection are not the full-resolution mean's Lanczos/equal-weight recipe |
| [COMPARISON.md](COMPARISON.md) | Existing measured parity/performance results | Evidence for those exact fixtures, not parity for a future mean backend |

Retain the CPU implementation after GPU work lands. Keep explicit regression fixtures, transforms and numerical reports alongside both paths. Avoid changing the CPU estimator merely to make it resemble a faster GPU result.

## Proposed algorithm for our RAW photographs

Everything below is a **Ceviche design proposal**, extending our [Tenerife experiment](TENERIFE-MEAN.md). It is not a transcription of Bitterli's implementation.

### 1. Inputs and validity

Group compatible camera/lens/focus/exposure regimes. Read sensor dimensions, focal length/35 mm equivalent, crop, exposure duration, ISO and EXIF capture times, retaining missing/uncertain metadata. The 14 mm value must initialize camera intrinsics numerically; it is not merely a label. Use calibrated intrinsics when available and record whether RAW development already applied distortion correction.

Decode to scene-linear floating-point RGB with a shared development recipe. Keep sensor saturation, geometric coverage, sky classification and noise variance as separate fields. Never identify sensor clipping solely from developed RGB exceeding one. Preserve signed interpolation values until the display/export stage.

Use the **existing AI sky model** for scene separation, with a protected uncertain skyline. A star-detection mask has a different purpose and cannot replace the sky mask. Fit terrain motion independently; disable temporal averaging in moving ground regions or fall back to a chosen reference.

### 2. Stellar measurements

Compare the existing local-noise detector against a DoG candidate generator on identical inputs. Refine centers at native resolution using a local background plane and a fitted PSF. Start with an elliptical Gaussian approximation, then test trail-aware or empirical PSFs where long exposures/coma make that approximation fail. Record fit residual, SNR, center covariance, saturation and crowding; do not rank solely by peak brightness.

Keep spatial coverage in the outer field and across brightness bins. A robust centroid fit can exclude noisy background samples, but that selection must not become a positive-only rule for the final image mean. Reserve independent stars/patches for validation, not only stars used to select model complexity.

### 3. Shared calibration and global alignment

Bootstrap correspondences using our existing triangle matcher and EXIF-time prediction. Build tracks identifying the same star across multiple frames. Use reliable overlaps beyond immediate neighbors so a failed frame does not break the entire chain.

For a proposed global fit, model measured star position `p_ij` as:

```text
predicted_ij = project(K, distortion, R_i * sky_direction_j)
residual_ij  = measured_ij - predicted_ij
objective   = sum robust_loss(residual_ij with centroid uncertainty)
              + focal/calibration priors + optional timing prior
```

Fix the reference rotation to remove coordinate ambiguity. Share focal/distortion parameters only within a compatible camera configuration. Keep principal point/distortion strongly constrained for a short five-frame sequence; do not unlock poorly observed parameters just because the optimizer permits it. Solve in normalized coordinates with double precision, a robust loss and a bounded nonlinear least-squares method. Hold out whole tracks/spatial regions for validation.

Actual exposure-midpoint offsets provide an initial rotation trajectory and a soft consistency prior. Camera shake, timing uncertainty and residual calibration error require measured correction. A longer exposure's unknown photon timing and existing stellar blur are not undone by moving its midpoint. Report departures from the timing model rather than silently forcing an exact sidereal trajectory.

For a distortion-free model, a reference output pixel maps into source frame `i` through `K_i R_i R_ref^-1 K_ref^-1`. Include inverse/forward distortion in the appropriate spaces, or invert the validated empirical forward morph. Confirm the matrix convention with known synthetic rotations. Compose all geometric corrections into **one source sampling operation**.

### 4. Reprojection and mean

Specify one shared sampling contract: pixel centers, top-row convention, interpolation kernel, valid support radius and source-mask handling. A kernel touching invalid pixels requires explicit rejection or a documented renormalization rule. The CPU and Metal versions must use the same rule. Bilinear versus Lanczos is a recipe change, not a backend optimization.

For each output pixel, stream valid observations through:

```text
sum_rgb    += weight_i * warped_linear_rgb_i
sum_weight += weight_i
sum_weight2 += weight_i * weight_i
count      += 1
result      = sum_rgb / sum_weight
```

The baseline uses equal weights, matching our current five-frame experiment. A separate variance-weighted mode uses a calibrated noise model after exposure normalization. Avoid weights based directly on each sample's noisy value. Save coverage, weight sums and effective support; do not equate these with independent-sample SNR after resampling.

Keep robust rejection as a separately named estimator with the plain mean available for comparison. With only five frames, aggressive rejection can erase faint stars. For robust statistics, tile spatially while preserving the required temporal samples; clipping independent temporal batches and averaging them changes the estimator.

### 5. Background and exposure policy

Background subtraction is **off by default** for denoising. Provide it as a separate, reversible operation with a saved background layer. Milky Way dust, airglow and aurora are real diffuse signals; a smooth fit does not establish that they are pollution. Compare broad-structure flux and color with subtraction disabled, and require user-editable exclusion regions.

Camera exposure jumps and actual twilight changes need different treatment. Use the [day/night transition policy](../../docs/research/photography-workflows-2026-10/day-night-transition.md), rather than forcing all observations to a flat brightness. Dark/flat correction requires compatible calibration data; neither averaging nor a smooth-background fit removes every systematic sensor effect.

## CPU and GPU development contract

**Both are maintained implementations. CPU remains runnable independently.** Shared geometry/recipe data feed both backends; they must produce the same photographic operation.

| Work | CPU version | Metal version |
| --- | --- | --- |
| EXIF grouping, correspondences, global solve | Double-precision solver and deterministic ordering | Initially reuse the same CPU solution; no duplicate GPU solver is required |
| Dense feature preprocessing | Reference filters | Optional separable filters/reductions after profiling and parity checks |
| Warp | Double-precision coordinate reference, explicit sampler | Float32 sampling; evaluate coordinate precision or use host-computed maps/relative tile coordinates |
| Arithmetic/weighted mean | Stable accumulation, double-precision reference; compensated/ordered sums where useful | Stream spatial tiles, bounded reusable buffers, stable Float32 reductions; measure accumulation error |
| Robust integration | Reference estimator | Separate implementation of the exact same estimator; no silent sample-count cap |
| Diagnostics/export | Identical coverage/weights/recipe provenance | Identical diagnostic semantics; record actual device, dispatch and any fallback |

Proposed future CLI interface: `--compute cpu|metal|auto`, `--estimator mean|weighted-mean|robust`, and a frozen geometry/recipe manifest. **These flags are a design, not options already implemented in the current CLIs.**

- `cpu`: force the CPU geometry/warp/fusion path. Shared RAW development and optional AI segmentation can still use Apple frameworks; record that boundary so this is not misrepresented as an entirely CPU-only pipeline.
- `metal`: require Metal execution for advertised dense stages; fail explicitly if unsupported. Never report CPU output as a successful GPU test.
- `auto`: choose a measured policy and report any fallback. Benchmark reports include fallback reason and actual backend.

Stream frames and reuse buffers instead of retaining a full RAW cube. Account for source images, halos, scratch, masks, diagnostics and queued commands in the memory budget. Keep tile/frame order explicit. Different floating-point reduction orders can be acceptable within measured tolerances; equality of byte output is not a universal requirement.

## Validation and implementation order

1. Freeze the current full-resolution Tenerife outputs and per-pixel support as the CPU baseline. Add a generic recipe/geometry manifest without deleting the existing experiment.
2. Implement ordinary mean accumulation and the chosen warp sampler in native CPU code; verify against that baseline. Add global refinement as an independent geometry experiment so its effects can be separated from rendering changes.
3. Implement Metal using the same geometry and estimator. Compare warp coordinates before pixel values, exact validity where possible, count/weight differences, max/RMS errors and spatial error maps. Explain disagreements at validity thresholds rather than hiding them in a global average.
4. Measure star aperture flux, faint-star completeness with injected sources, centroids/PSFs, skyline leakage, foreground edges and broad Milky Way structure. Include odd image sizes, tile boundaries, irregular intervals, missing matches, saturation and limited-memory runs.
5. Benchmark both versions on five native 42 MP frames and longer sequences. Record cold/warm setup, RAW decode, segmentation, geometry, transfers, kernel time, I/O, total elapsed time and peak memory. Existing small-case GPU results do not establish a speedup for these workloads.

Performance tuning must retain the CPU backend, numerical checks and explicit backend selection. The original reference review introduced no code, model or upstream image. The subsequent [Tenerife implementation report](TENERIFE-JOINT-MEAN.md) distinguishes completed work from these remaining proposals and records actual measurements.
