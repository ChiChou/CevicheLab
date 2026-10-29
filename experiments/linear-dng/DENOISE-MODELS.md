# Denoise models for a persistent enhanced source

**Follow-up, 2026-10-27:** [Evaluation on the supplied Sony RAW files](../denoise-evaluation/README.md) now includes ImageIO RGB crops and full-frame Bayer tests. PMRID is the strongest next Bayer prototype in that run; the matching DNG supplied a source noise profile. The initial shortlist below is retained as research context, not the final measured recommendation.

Investigated 2026-10-26. Recommendation: evaluate **RawNIND's linear variant first** for Ceviche's current demosaiced-image pipeline, and **PMRID as a small RAW-domain baseline**. RawNIND's Bayer variant is a closer architectural match to joint denoise/demosaic, but has an upstream Core ML numerical issue to resolve. These are integration recommendations, not a measured image-quality ranking. No replacement model is bundled or selected by the app.

The main performance improvement remains running enhancement once and reusing the result. A more expensive model can still give responsive editing if inference is upstream of interactive adjustments and its output is persisted. See the [DNG investigation](README.md) for source preservation, cache invalidation and color/range requirements.

## Shortlist

| Candidate | Input → output | Fit and principal limitation | License evidence |
| --- | --- | --- | --- |
| [RawNIND / UtNet2](https://github.com/trougnouf/rawnind_jddc), linear | Linear Rec.2020 RGB → linear Rec.2020 RGB | Best first experiment with the existing demosaiced pipeline. Requires neutral, correctly normalized input and gain handling. Not gamma sRGB. | GPLv3 code; upstream README explicitly dual-licenses model weights under GPLv3 and CC BY 4.0. |
| RawNIND / UtNet2, Bayer | Four packed Bayer channels → full-resolution camera-native RGB | Joint denoise/demosaic; good conceptual fit for a linear enhanced negative. Needs mosaic access and camera-color conversion. Upstream reports FP16 Core ML overflow for this variant. | Same explicit weight license as above. |
| [PMRID](https://github.com/MegEngine/PMRID) | Four packed Bayer channels → four packed Bayer channels | Small, successfully converted to Core ML here. Needs a camera noise model and the prescribed K-sigma normalization. Can produce a denoised mosaic derivative. | Apache-2.0 repository includes official checkpoints; no checkpoint-specific exception found in the inspected tree. |
| [TreeNet / RawForge](https://github.com/rymuelle/RawForge) | Demosaiced linear Rec.2020 RGB plus ISO conditioning → RGB | Useful alternative with SuperLight, Light, standard and Heavy weights. Native Core ML behavior and quality untested here. | MIT code. Separate release-weight licensing was not explicit in the inspected release; resolve before bundling. |

For AGPLv3 distribution, retain the applicable notices and source obligations: [GPLv3 section 13](https://gcc.gnu.org/onlinedocs/libstdc++/manual/appendix_gpl.html) expressly permits combining GPLv3 and AGPLv3 code, and [Apache documents Apache-2.0 compatibility with GPLv3](https://www.apache.org/licenses/GPL-compatibility.html). RawNIND offers an explicit weight-license choice; preserve attribution and the chosen license. Record exact checkpoint hashes and conversion changes for any shipped artifact. A source-code license alone is not sufficient evidence for a separately hosted checkpoint when its terms are unclear.

## Model-specific integration findings

### RawNIND

The Bayer network's output is camera-native RGB; the training pipeline applies camera-to-linear-Rec.2020 conversion afterward. Do not tag that network output as Rec.2020 without the transform, or copy a camera matrix onto already converted RGB. The linear model works directly in linear Rec.2020. The implementation uses a convolutional U-Net with pooling, transpose convolutions and, for Bayer output, pixel shuffle. Source: [network definitions](https://github.com/trougnouf/rawnind_jddc/blob/main/src/rawnind/models/raw_denoiser.py), [trainer and output processing](https://github.com/trougnouf/rawnind_jddc/blob/main/src/rawnind/libs/abstract_trainer.py), [color conversion](https://github.com/trougnouf/rawnind_jddc/blob/main/src/rawnind/libs/rawproc.py).

Its output has a learned gain that must be matched to the input reference. Gain handling must remain consistent across an image; independently correcting each tile can introduce brightness seams. Input preparation must also define white balance and avoid Apple's default tone response, sharpening and denoise being baked into a supposedly neutral source.

The [darktable integration notes](https://github.com/darktable-org/darktable-ai/blob/master/models/rawdenoise-nind/README.md) document exported Bayer and linear ONNX variants. They report NaN/Inf from FP16 overflow for the Bayer model on Core ML ANE/GPU and use CPU-only execution; they report the linear variant as unaffected. This is upstream evidence, not a local reproduction or a guarantee for Ceviche. Test actual Core ML conversion, finite outputs, highlight range and multiple Apple chips before selecting it.

### PMRID

The official checkpoint contains **1,031,908 parameters** and occupies 4,183,200 bytes. The convolutional architecture converts without custom operators in the local smoke test. Because it returns packed mosaic samples, saving a correctly described CFA DNG is possible in principle; a linear RGB DNG is not required for the once-only workflow.

The [official benchmark](https://github.com/MegEngine/PMRID/blob/master/run_benchmark.py) supplies an OPPO Reno 10x noise profile and a K-sigma transformation before inference, including the network's scale factor of 256. Those coefficients must not simply be reused for the supplied Sony files. Black/white levels, Bayer arrangement, shot/read noise calibration and the inverse normalization are part of the model contract. ISO alone does not identify equivalent noise across cameras. The smoke test below does not validate any of those camera-dependent steps.

### TreeNet

RawForge's [model registry](https://github.com/rymuelle/RawForge/blob/main/application/MODEL_REGISTRY.py) and preprocessing select linear Rec.2020 RGB after demosaicing, with ISO conditioning. This is potentially useful for a persistent linear intermediate, but not a direct replacement for the current sRGB NAFNet wrapper.

The [ONNX release](https://github.com/rymuelle/RawForge/releases/tag/onnx_v1.0.0) contains roughly 0.84 MB SuperLight, 1.51 MB Light, 10.07 MB standard and 21.86 MB Heavy models. These are file sizes, not memory or speed measurements. RawForge advertises ONNX Runtime with a Core ML provider; that is not evidence that every operation executes on the ANE or that a native Core ML conversion is numerically safe. The code is MIT, but the inspected release did not separately state checkpoint terms; a third-party model mirror's license label does not settle that question.

## Other candidates considered

| Model | Assessment |
| --- | --- |
| [Restormer](https://github.com/swz30/Restormer) | MIT code; real-image denoising models target rendered RGB. Relevant to export denoise comparison, but do not establish RAW-domain semantics. Exact checkpoint terms still need verification before bundling. |
| [SCUNet](https://github.com/cszn/SCUNet) | Apache-2.0 code; RGB restoration. Evaluate a fidelity/PSNR model rather than a GAN model for photographic detail preservation. No local quality or Core ML test; checkpoint terms need verification. |
| [Nonlocal match-filter](https://github.com/MIA-UIB/nonlocal-matchfilter) | MIT code; packed RAW with noise conditioning is relevant. Upstream uses custom CUDA extensions, so native Apple deployment requires substantial additional work. Third-party conversions were not audited. |
| [DualDn](https://github.com/OpenImagingLab/DualDn) | Exclude from the shipping shortlist: upstream uses CC BY-NC 4.0. Its noncommercial restriction conflicts with unrestricted commercial use of an AGPLv3 distribution. |

The existing NAFNet-SIDD implementation remains the app's current model. Its gamma-sRGB training domain makes it a useful RGB baseline, but moving it earlier in the graph does not automatically turn it into a camera-linear or Bayer model.

## Local PMRID Core ML smoke test

Measured on Apple M4, macOS 27.2, PyTorch 2.8.0, coremltools 8.3.0. Official upstream commit `8ebb9e8e96559881dee957f34243933c5beb77dd`; checkpoint SHA-256 `9361614f3514d27351d81909f2215c0fdc38619c0288d936b7266485ac106c14`. The generated ML Program uses FP16 weights/compute with float32 input/output and occupies 2,200,271 bytes.

Input was a seeded synthetic tensor of shape `1 × 4 × 256 × 256`, equivalent in dimensions to a 512 × 512 sensor region. It is not a real photograph or a calibrated camera noise sample. Five warm predictions were timed after one initial prediction.

| Requested compute units | First prediction | Median warm prediction | Mean / maximum error vs PyTorch, in normalized RAW units | Finite output |
| --- | ---: | ---: | ---: | --- |
| ALL | 58.28 ms | **2.86 ms** | 0.0000230 / 0.0001223 | Yes |
| CPU_ONLY | 42.06 ms | 34.09 ms | 0.0000631 / 0.0004394 | Yes |

`ALL` is a requested policy, not verification of which hardware ran each operation. The timings exclude model construction/compilation, source decode, noise normalization, packing, tile overlap, stitching and storage. Do not extrapolate a whole-photo processing time or denoising quality from this result. It establishes that this checkpoint converts and produces closely matching finite outputs for this test input. Recorded data: [results/pmrid-coreml.json](results/pmrid-coreml.json).

To reproduce on macOS with a compatible Python environment containing PyTorch, NumPy and coremltools:

```sh
git clone https://github.com/MegEngine/PMRID.git .build/denoise-model-research/PMRID
git -C .build/denoise-model-research/PMRID checkout 8ebb9e8e96559881dee957f34243933c5beb77dd
python experiments/linear-dng/pmrid_coreml_probe.py \
  .build/denoise-model-research/PMRID .build/denoise-model-research
```

The probe verifies the checkpoint hash and loads tensor-only weights. Research downloads and converted packages remain under ignored `.build`; none are bundled into Ceviche.

## Evaluation needed before choosing a shipping model

Compare RawNIND linear, PMRID with a valid camera profile, and the existing NAFNet baseline using the same source photographs and a controlled final rendering. Include high-ISO shadow detail, fine foliage/hair/text, smooth gradients, saturated colors, clipped highlights and multiple white balances. Judge texture preservation, chroma noise, false detail, color drift and tile seams at equal display scale. Measure full-resolution wall time, peak memory and initial-load cost separately from warm tile inference.

The supplied enhanced Lightroom DNG is useful for structure and visual comparison, but its enhanced image is not noise-free ground truth. Its embedded mosaic can provide a common source where the decoder supports it. A valid comparison must control subsequent color rendering and edits rather than attributing renderer differences to the denoiser.

Finally, round-trip the chosen output through storage and decode, preserving its defined color space, black/white interpretation and needed range. A mosaic model and a linear RGB model require different DNG metadata. Avoid forcing either result into the original sensor's nominal bit depth merely to match a tag: select precision for the generated data, retain the immutable original, and verify that later edits reuse the enhanced result without invoking inference.
