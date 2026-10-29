# Denoise evaluation on the supplied Sony samples

Evaluated 2026-10-27 on Apple M4, macOS 27.2. Research only: no DNG export option, model replacement, persistent enhancement feature or new shipping dependency was added.

**Recommendation after testing:** PMRID is the strongest next prototype for the requested Bayer-to-DNG workflow. It retains a mosaic, substantially reduces noise in this capture, and completed full-frame inference/stitching in 2.56 seconds with Core ML. This is not a claim of Lightroom parity or a final model selection: faint bright features are softened, camera noise profiles remain necessary, and only one high-ISO Bayer capture was tested. RawNIND Bayer demonstrates the alternative joint denoise/demosaic path, but its blotchy texture and colored bright-point artifacts are concerning on this scene.

## Inputs and comparison paths

| Input | Camera / sensitivity | Evaluation |
| --- | --- | --- |
| `DSC00032.ARW` | Sony ILCE-7RM3, ISO 640, 1/30 s, f/13 | ImageIO RGB: sky, mountain, water and foreground crops |
| `DSC00396.ARW` | Same camera, ISO 8000, 2.5 s, f/4.5 | ImageIO RGB crops plus full-frame Bayer inference with RawNIND and PMRID |
| `DSC00396-Enhanced-NR.dng` | Matching Lightroom-processed capture | Original mosaic, enhanced image, camera calibration and original-image noise profile |

`decode.swift` uses `CGImageSourceCreateImageAtIndex`, with float decoding allowed, at full resolution. It does not use the embedded-thumbnail API or LibRaw to render the comparisons. All three supplied files decode to 7952 × 5304, with 16-bit Display P3 `CGImage` output. Core Image converts that decoded image to float32 linear Rec.2020 for the model harness. This color conversion does **not** undo Apple's tone response, demosaicing, sharpening or noise processing. The RGB evaluation therefore measures the models **after ImageIO's default rendering**, not their published RAW-domain benchmark performance.

Following the clarified preference for Bayer input, the separate Bayer experiment uses LibRaw 0.22.3 solely to unpack the original ARW mosaic and metadata. The exposed sensor region is 7968 × 5320, RGGB, black 512 and white 16383. No white balance, tone curve, demosaicing or conventional denoise precedes the Bayer networks. Their saved research DNGs are then decoded with ImageIO.

The source DNG's decoded mosaic agrees with the ARW at all but **74 samples** across the overlapping 7968 × 5320 region; maximum difference is 245 sensor codes. This verifies a very close source match, not identical originals or the cause of those few corrections. See [source-mosaic-comparison.json](results/source-mosaic-comparison.json).

## ImageIO does not select Lightroom's enhanced image by default

The DNG contains an original CFA image and a separate JPEG XL LinearRaw enhanced IFD. A scratch variant exposing only the original mosaic produces **exactly the same sampled pixels** as ImageIO's default decode of the intact DNG. The comparison used every fourth pixel in each axis. Simply opening the supplied DNG through ImageIO would therefore compare against the original image rather than Lightroom denoise.

`select_dng_ifd.py` creates scratch variants with one primary image and restores the enhanced IFD's inherited crop geometry. It does not alter the supplied file. The comparison labels the resulting image **Lightroom enhanced / ImageIO**. This is a diagnostic rendering of the isolated enhanced payload, not a verified match to Lightroom's own final render. Fine colored grain in that rendering must not be used to conclude that Lightroom's denoiser is worse; the interpretation has not been validated against a full-resolution Lightroom-rendered TIFF.

ImageIO also renders the ARW and DNG with different geometry. In the star crop, correlation peaks differ by approximately 11 pixels vertically and 12 horizontally between the ARW and the DNG enhanced render. The DNG mosaic and Bayer-model render have zero integer offset against the enhanced render in that check. Consequently, the gallery keeps **ImageIO RGB** and **Bayer/DNG** comparisons separate. It does not compute pixelwise quality scores across these paths.

## Observations

| Model / path | What the supplied images show | Decision |
| --- | --- | --- |
| PMRID, Bayer → Bayer | Strong smoothing of the window and aurora; relatively restrained bright-point shapes compared with RawNIND Bayer. Some faint points are weakened and residual texture remains. | Best next Bayer prototype, subject to detail-preservation and camera-profile work. |
| RawNIND Bayer → camera RGB | Strong smoothing, but blotchy dark-sky texture and conspicuous colored/expanded bright points. | Useful proof of the linear-DNG route; not ready to select on this evidence. |
| TreeNet Light after ImageIO | Reduces grain while retaining more mountain/foreground structure than the tested NAFNet path. Fine texture is still softened. | Worth further RGB testing; release-weight license still needs confirmation before bundling. |
| RawNIND linear after ImageIO | Reduces some luminance variation, but leaves grain, changes chroma texture and rounds bright points. | No clear reason to prefer it for this post-ImageIO path. This does not rank it under a neutral RAW decode. |
| Existing NAFNet wrapper/checkpoint | Smooths low-ISO grain strongly but loses mountain/foreground detail; produces colored grid artifacts in the ISO 8000 star crop. | Failure case requiring investigation, not an acceptable baseline for choosing a shipping denoiser. |

The NAFNet grid also occurs with the original FP32 checkpoint in PyTorch using the repository's architecture. Replacing global pooling with upstream local pooling did not eliminate it on the checked tile. Core ML adds numerical differences, but the visible failure is **not solely a Core ML conversion defect**. Its root cause is unresolved. The test does not establish that every upstream NAFNet setup fails. [Real-tile numerical check](results/nafnet-real-tile-check.json).

## PMRID noise normalization

The matching DNG's **original mosaic IFD** contains a three-plane NoiseProfile, with shot coefficients approximately 0.00145–0.00147 and read-variance offsets approximately 2.43–2.49 × 10⁻⁶. This enabled a camera-specific experiment that was unavailable during the initial model survey. The coefficients are metadata supplied by Adobe, not independently measured calibration for this sensor.

For normalized signal `x`, source variance is `a*x + b`. The [PMRID reference implementation](https://github.com/MegEngine/PMRID/blob/master/run_benchmark.py) maps to its training anchor's noise distribution. In normalized units, the equivalent affine transform is:

```text
scale  = anchor_a / source_a
offset = anchor_a * source_b / source_a² - anchor_b / anchor_a
network_input = 256 * (scale * x + offset)
output = (network_output / 256 - offset) / scale
```

The published OPPO profile is used only to identify the checkpoint's **training anchor**, not as Sony's source profile. Each Sony color plane uses its recorded coefficients; the two green planes share the green profile. See [recorded parameters](results/DSC00396-pmrid-inference.json). The normalized noise convention is also documented in [Android's DNG-referenced sensor-noise definition](https://developer.android.com/reference/android/hardware/camera2/CaptureResult#SENSOR_NOISE_PROFILE).

On three real Sony tiles, converted Core ML and original PyTorch outputs agree to mean errors of approximately 5.6–5.8 × 10⁻⁶ in normalized RAW units; maximum errors range from 8.4 × 10⁻⁵ to 5.7 × 10⁻⁴. Outputs are finite. [Real-tile check](results/pmrid-real-tile-check.json). The ISO 640 image was not tested with PMRID because this run did not have a matching source noise profile for that sensitivity; reusing the ISO 8000 coefficients would be invalid.

## Timing and output range

| Full ISO 8000 sensor frame | Backend | Inference + stitching | Separate model load |
| --- | --- | ---: | ---: |
| PMRID, 294 packed 256 × 256 tiles | Core ML ALL, FP16 | **2.56 s** | 2.82 s |
| RawNIND Bayer, 77 packed 512 × 512 tiles | ONNX Runtime CPU, 4 threads, FP32 | **285.14 s** | 0.38 s |

These timings exclude ARW unpacking, input preparation, writing DNG and ImageIO decoding. They use different backends and were measured on a working Mac, with some concurrent research work during RawNIND inference; they are observed pipeline costs, not an equal-hardware architecture benchmark. Requested Core ML `ALL` does not identify which hardware ran each operation. RGB crop timings are retained in [rgb-metrics.json](results/rgb-metrics.json), but are not normalized speed rankings.

### Native speed follow-up: rendering pipeline or a DNG copy?

**Use a one-time enhanced source, preferably persisted as a DNG; do not rerun full-resolution PMRID on slider changes.** The native benchmark below confirms that the earlier 2.56-second number was not an end-to-end RAW processing time. A cached enhancement node could also avoid repeated inference without a user-visible copy, but that requires an explicit source cache; putting the network in the ordinary adjustment graph alone does not provide that behavior.

`benchmark_native.swift` links the research-only `speed_raw.cpp` bridge and measures original ARW → LibRaw unpack → native tile preparation → Core ML → complete denoised mosaic in memory. It uses no Python tensors or intermediate image files. The model is retained across three sequential passes per photo; source extraction is repeated each time. The 42.39 MP sensor region uses 294 packed tiles. Filesystem caches were not purged.

| Real sample | First pass | Subsequent passes | Median of all three |
| --- | ---: | ---: | ---: |
| `DSC00396.ARW`, ISO 8000 | 3.73 s | 3.04 / 3.46 s | **3.46 s** |
| `DSC00032.ARW`, ISO 640 | 4.54 s | 2.83 / 2.94 s | **2.94 s** |

The ISO 8000 run uses the matching DNG noise profile. The ISO 640 run uses identity noise normalization **for timing only**; its fixed model graph and tile count are the same, but this is not a calibrated quality result. All six outputs were finite. Model compilation and loading were separately observed at 0.40 s and 4.06 s before the first pass; the first ISO 8000 result therefore took about 8.18 s including those stages, still excluding DNG encoding and Apple rendering. These are observed initialization times, not guaranteed uncached OS startup measurements.

At ISO 8000, median measured stages were approximately 0.64 s unpack, 0.65 s tile preparation, 1.63 s prediction, and 0.45 s stitching. Even retaining the unpacked input would leave seconds of work per full-image update. Native Core ML returns float16 here; the benchmark widens it to float32 for normalization/stitching. Peak process resident memory was approximately 387 MiB, including a 162 MiB float32 output mosaic. [Complete native results](results/native-speed.json).

`benchmark_apple.swift` separately measures the existing Apple-style path: a retained `CIRAWFilter`, Metal-backed `CIContext`, 2200-pixel long-edge preview, and three exposure changes after the first render. Pixel data is realized before stopping each timer. This is a RAW-preview baseline, not the whole editor including masks, looks, histogram and UI.

| Apple RAW preview source | Open filter + first render | Subsequent exposure renders |
| --- | ---: | ---: |
| ISO 8000 ARW | 2.01 s | 19–28 ms |
| ISO 640 ARW | 1.55 s | 20–22 ms |
| PMRID Bayer DNG | 0.89 s | **17–20 ms** |

The generated DNG therefore supports responsive subsequent Apple rendering in this test. The benchmark does not establish that every edit or full-resolution export takes 20 ms, nor that DNG always opens faster across cameras or compressed encodings. [Apple preview results](results/apple-preview-speed.json).

The integration boundary remains unchanged: **LibRaw only inside the denoise action; Apple's APIs for the main app.** Run enhancement upstream of white balance, exposure and other interactive edits, save or cache its output, then let the existing Apple pipeline render it. Changes to the original, model or inference parameters invalidate the enhancement; ordinary downstream edits do not. A persistent DNG also avoids recomputation on reopen and provides the interoperable derivative already requested. No shipping integration was made by this benchmark.

To rebuild the native timing harness from the repository root (using the research LibRaw build and PMRID package from the earlier evaluation):

```sh
clang++ -std=c++17 -O2 -I.build/linear-dng-research/LibRaw \
  -c experiments/denoise-evaluation/speed_raw.cpp -o .build/denoise-evaluation/speed/raw.o
swiftc -O experiments/denoise-evaluation/benchmark_native.swift \
  .build/denoise-evaluation/speed/raw.o .build/linear-dng-research/LibRaw/lib/libraw.a \
  -lc++ -lz -o .build/denoise-evaluation/speed/benchmark
.build/denoise-evaluation/speed/benchmark .build/denoise-evaluation/speed \
  .build/denoise-model-research/PMRID-research.mlpackage \
  /absolute/path/DSC00396.ARW /absolute/path/DSC00032.ARW
```

Both Bayer outputs contain negative values and values above nominal white. The research DNG encoding uses unsigned 16-bit values with black 8192 and white 40960, representing normalized values from −0.25 to approximately 1.75. Both outputs fit without clipping. The ideal quantization half-step is 0.5/32768; including float arithmetic in the writer, the **measured maximum error is 1.532 × 10⁻⁵**, finer than one original 14-bit-range sensor code. [Payload verification](results/quantization-check.json) checks both complete generated images. This preserves the generated range at that precision; it does not make the denoised samples identical to the source or preserve float output exactly.

PMRID writes a CFA mosaic. RawNIND writes camera-native linear RGB. The research writer reuses calibration from the matching Lightroom DNG, omits source opcodes and retains unused original payloads in the scratch container. It is deliberately **not** a production or conformance-validated DNG exporter. ImageIO's default treatment of the different RAW representations remains part of the observed result. A shipping writer must rebuild metadata, digests, thumbnails, processing/noise information and provenance consistently.

## Inspect the outputs

Generated files remain under ignored `.build/denoise-evaluation/`; the originals are unchanged and were not uploaded.

- [Interactive comparison gallery](../../.build/denoise-evaluation/rgb-results/comparison.html): select path, region, model and original/+2 EV brightness; 768-pixel native crops.
- [Bayer comparison sheet](../../.build/denoise-evaluation/rgb-results/DSC00396-bayer-comparison.png): DNG mosaic, RawNIND Bayer, PMRID Bayer and isolated Lightroom enhanced payload.
- [ISO 640 RGB comparison](../../.build/denoise-evaluation/rgb-results/DSC00032-rgb-comparison.png).
- [ISO 8000 RGB comparison](../../.build/denoise-evaluation/rgb-results/DSC00396-rgb-comparison.png).

The sheets show 384-pixel center crops without image resizing, all with a +2 EV display lift applied **after** inference. No sharpening was added by the Python display code. The underlying ImageIO decode retains Apple's default processing.

Descriptive high-pass MAD measurements in [quality-summary.json](results/quality-summary.json) quantify remaining small-scale variation, which includes texture as well as noise. Lower is not automatically better. Bright-feature measurements are tied to the isolated enhanced rendering and include renderer effects; they are not verified star counts or ground-truth detail scores. No PSNR/SSIM quality ranking is claimed without a clean reference.

## Reproduction and integration boundaries

The scripts in this directory record each step: `decode.swift`, `extract_bayer.cpp`, `evaluate_rgb.py`, `evaluate_bayer.py`, `evaluate_pmrid.py`, `wrap_bayer_rgb_dng.py`, `select_dng_ifd.py`, numerical checks, and `summarize.py`. Model paths and region coordinates are explicit in those scripts. `evaluate_rgb.py` intentionally uses the existing `ml/nafnet_arch.py` architecture and `ml/convert_nafnet.py` conversion so it tests the current model path.

Dependencies used: ONNX Runtime 1.31.1, PyTorch 2.8.0, coremltools 8.3.0, NumPy 2.5.4, SciPy 1.18.1 and Pillow 13.0.0. Sources and hashes are in [manifest.json](results/manifest.json). Downloaded models and evaluation dependencies are outside shipping targets. Licensing remains as in the [model survey](../linear-dng/DENOISE-MODELS.md): PMRID's Apache-2.0 repository includes its checkpoints; RawNIND explicitly licenses weights under GPLv3 / CC BY 4.0; TreeNet's separate weight terms are not cleared here. LibRaw is a research dependency only.

For the intended feature, retain the immutable original, produce enhancement from Bayer once, and materialize a reusable source before interactive edits. PMRID permits preserving the CFA layout; RawNIND requires a linear RGB negative. Validate noise-profile coverage, defective-pixel handling, faint-detail preservation, input/output precision and full DNG interoperability before selecting a model and shipping this workflow.
