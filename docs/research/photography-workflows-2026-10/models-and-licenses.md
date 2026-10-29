# Models, papers, and license evidence

Checked **2026-10-28** against primary sources. These are adoption recommendations, not measured Ceviche quality rankings or a completed distribution audit. No weight files were downloaded or executed. Links to `main` describe the inspected state and can change; implementation must pin immutable revisions and hashes.

## How to read the ledger

- **Explicit:** the publisher expressly identifies the checkpoint/model license. Eligible for a technical prototype, subject to dependency, attribution, and release checks.
- **Repository-scoped:** a permissive repository contains the official weights or code, but no separate explicit checkpoint grant was found in the material inspected. Record that evidence; do not quietly turn it into an explicit weight declaration.
- **Unresolved:** externally hosted weights, missing terms, conflicting metadata, or unverified dependencies prevent a distribution recommendation.
- **Restricted/custom:** terms differ from the standard unrestricted distribution path proposed for Ceviche. Evaluate the actual agreement before considering a separately licensed integration. This does not mean every commercial use is forbidden.

Ceviche's [own license](../../../LICENSE) is AGPLv3. Preserve upstream notices and applicable source obligations. GPLv3/AGPLv3 combination provisions and Apache-to-GPLv3 compatibility matter; model/data permissions still need their own review. The [Apache Software Foundation's compatibility explanation](https://www.apache.org/licenses/GPL-compatibility.html) supports the latter software relationship. It does not settle every model, dataset, patent, or packaging question.

## Matching and geometric stitching

### XFeat + LighterGlue — first lightweight matching experiment

**Publication:** [XFeat, CVPR 2024](https://arxiv.org/abs/2404.19174). **Role:** image → sparse/semi-dense features; a compatible matcher produces correspondences for Ceviche's geometry solver. Good initial fit for landscape and ground alignment; star-field suitability is unproven.

**Artifacts:** official [`weights/xfeat.pt` and `weights/xfeat-lighterglue.pt`](https://github.com/verlab/accelerated_features/tree/main/weights). **Code:** [Apache-2.0](https://github.com/verlab/accelerated_features/blob/main/LICENSE). **Weights:** repository-scoped evidence, official binaries in the same repository; the README does not separately spell out checkpoint terms. Retain the distinction in the release record.

**Apple hypothesis:** export the convolutional feature network first; keep keypoint selection and geometric verification outside the network if needed. LighterGlue needs a separate attention/export evaluation. Use its XFeat-specific weights, not an arbitrary SuperPoint-trained LightGlue checkpoint. Upstream CPU/CUDA speed claims are not Apple benchmarks. [Official implementation](https://github.com/verlab/accelerated_features).

**Decision:** first matching prototype; verify the exact redistribution scope before bundling.

### LightGlue with SIFT, DISK, or ALIKED — licensed component pairing matters

**Publication:** [LightGlue, ICCV 2023](https://arxiv.org/abs/2306.13643). **Role:** keypoints/descriptors → matches; this is not an image feature extractor or a stitch compositor.

**Code and weights:** **explicit Apache-2.0** for LightGlue in the [official license section](https://github.com/cvg/LightGlue#license). That section identifies DISK as Apache-2.0 and ALIKED as BSD-3-Clause, while warning that SuperPoint's inference code and pretrained weights use restrictive terms. Each extractor/checkpoint must match the selected matcher variant and undergo its own intake check.

**Apple hypothesis:** fixed keypoint budgets and disabled adaptive pruning may simplify a first export, with potential speed/quality tradeoffs. ALIKED's sampling operations need evaluation; SIFT plus the corresponding LightGlue weights offers an alternative without a learned extractor.

**Decision:** prototype a verified compatible pair. Do not copy the convenient SuperPoint demo wholesale. [Source and weights](https://github.com/cvg/LightGlue), [SuperPoint license](https://github.com/magicleap/SuperPointPretrainedNetwork/blob/master/LICENSE).

### PixelStitch — recent local-warp research comparator

**Publication:** ICCV 2025, *Structure-Preserving Pixel-Wise Bidirectional Warps for Unsupervised Image Stitching*. [Author repository and paper link](https://github.com/MakiseChris666/PixelStitch).

**Role:** refine alignment using bidirectional pixel warps. The release supplies only the pixel-wise warp stage; it requires precomputed homography. Training code is not released in the inspected README.

**Code:** [MIT](https://github.com/MakiseChris666/PixelStitch/blob/main/LICENSE). **Weights:** `checkpoints/ckpt.pth` is officially provided in-repository; repository-scoped licensing evidence. Audit inherited RAFT/UDIS components and the exact checkpoint before distribution.

**Apple hypothesis:** correlation/recurrent warping and grid sampling are conversion and memory risks. Work at reduced resolution, then validate how predicted warps transfer to full-resolution imagery. Warps can distort branches, buildings, and stars even when overlap error falls.

**Decision:** compare against a constrained classical mesh on difficult parallax cases; not a first-release requirement.

### UniStitch — 2026 research priority, weight-license hold

**Publication:** [arXiv March 2026](https://arxiv.org/abs/2603.10568); identified as ECCV 2026 by the [author repository](https://github.com/MmelodYy/UniStitch). Combines geometric keypoints and semantic feature maps, with adaptive fusion. Relevant when either representation alone is unreliable.

**Code:** [Apache-2.0](https://github.com/MmelodYy/UniStitch/blob/main/LICENSE). **Weights:** official [`Y5Y/UniStitch_model`](https://huggingface.co/Y5Y/UniStitch_model) exists, but its card declares `license: other` and supplies no clear accompanying grant in the inspected card. **Unresolved.** Code licensing must not override that ambiguity.

The README provides LightGlue/OpenCV keypoint routes and precomputed data named `superpoint_lmdb`; audit feature provenance. Replacing the extractor may change the model's input distribution and require training. The inspected [network implementation](https://github.com/MmelodYy/UniStitch/blob/main/Codes/network.py) includes scatter-reduction/voxelization, adding native-export work.

**Decision:** high-value paper/design reference. Resolve checkpoint terms and feature dependencies before adopting weights.

### RoMa v2 — strong dense-matching reference with custom dependency terms

**Publication:** [preprint November 2025; ECCV 2026 camera-ready revision](https://arxiv.org/abs/2511.15706). **Role:** dense correspondences with overlap/precision information; potentially useful for failed landscape pairs.

**Code:** MIT except DINOv3, as stated in the [repository](https://github.com/Parskatt/RoMaV2#license). **Backbone/materials:** [DINOv3 custom license](https://github.com/facebookresearch/dinov3/blob/main/LICENSE.md), including its own redistribution conditions and use restrictions. Do not describe the combined weights as simply MIT. RoMa-specific checkpoint terms also need an artifact-level record.

**Apple hypothesis:** high memory cost, transformer inference, and the optional fused local-correlation CUDA path need separate evaluation. CPU/MPS execution or an ONNX conversion does not establish a successful native Core ML implementation.

**Decision:** conditional research comparison; outside the default unrestricted bundle until license and deployment questions are settled. Original [RoMa](https://github.com/Parskatt/RoMa) uses DINOv2 with Apache-2.0 rather than DINOv3; it is a useful older comparator, with its own checkpoint audit still required.

### UDIS++ and RopStitch — distinguish the releases

| Method | What it contributes | Release/license evidence | Decision |
| --- | --- | --- | --- |
| [UDIS++, ICCV 2023](https://github.com/nie-lang/UDIS2) | Separate unsupervised warp and composition stages | Apache-2.0 repository; external official checkpoints linked in [warp](https://github.com/nie-lang/UDIS2/blob/main/Warp/readme.md) and [composition](https://github.com/nie-lang/UDIS2/blob/main/Composition/readme.md) notes. Separate checkpoint terms not verified. | Reproducible-method comparator after weight/dependency intake; not assumed RAW/HDR-safe. |
| [RopStitch, preprint 2025 / TVCG 2026](https://arxiv.org/abs/2508.05903) | Select an intermediate plane to distribute geometric distortion | [Official code and weights link](https://github.com/MmelodYy/RopStitch) available. No root license file in the inspected tree; external weight terms unverified. | Paper reference; no code/weight adoption until permissions are established. |

Neither publication proves that a pairwise RGB benchmark result scales to a multirow, 160 MP, scene-linear panorama.

## Masks and scene geometry

### Depth Anything 3 Small/Base — current permissive geometry candidates

**Publication:** [Depth Anything 3, November 2025](https://arxiv.org/abs/2511.10647). **Role:** relative depth and pose assistance from one or multiple RGB views. Use as a prior for overlap/parallax diagnostics and local warp regularization, never as ground-truth camera calibration.

**Code:** Apache-2.0 repository. **Weights:** **explicit Apache-2.0** in official [DA3-SMALL](https://huggingface.co/depth-anything/DA3-SMALL) and [DA3-BASE](https://huggingface.co/depth-anything/DA3-BASE) cards. Small is listed at 0.08B parameters, Base at 0.12B. The [upstream table](https://github.com/ByteDance-Seed/Depth-Anything-3#-model-cards) lists Large/Giant/Nested variants under CC BY-NC 4.0; do not use the default large-model example as a substitute. Training-data provenance remains a separate review.

**Apple hypothesis:** begin with Small, limited views, and proxy resolution. Multi-view attention/memory and native conversion are unmeasured here. Sky, reflective water, and repetitive detail need geometric fallback.

**Decision:** optional prototype after F1's explicit geometry/seam baseline; no need to replace Ceviche's existing depth model immediately.

### Existing Depth Anything V2 Small and sky/scene models — reuse first

**Weights:** DA2 **Small** is explicitly Apache-2.0; Base/Large/Giant carry different, noncommercial terms in the [official README](https://github.com/DepthAnything/Depth-Anything-V2#license). Ceviche already records a specific Core ML Small conversion plus its sky/scene models in [ml/MODELS.md](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/ml/MODELS.md).

**Decision:** reuse existing masks as editable hints. Current daytime sky segmentation does not establish reliable masks around night silhouettes, aurora, thin branches, or mountain snow. Validate those cases before automatic sky/ground compositing.

### SAM 2.1 Tiny/Small — optional interactive masks

**Release:** SAM 2.1, September 2024. **Role:** point/box-guided object masks; possible assistance for source ownership and protected subjects.

**Code and checkpoint terms:** **explicit Apache-2.0** in the [official SAM 2 license section](https://github.com/facebookresearch/sam2#license). Audit optional third-party postprocessing; no need to redistribute the web demo and its fonts. The repository supplies `sam2.1_hiera_tiny.pt` and Small alternatives.

**Apple hypothesis:** cache image embeddings and evaluate the prompt decoder separately. Treat optional CUDA postprocessing as replaceable functionality, not a Mac dependency. Memory and latency must be measured locally.

**Decision:** optional benchmark against Ceviche's existing macOS object selection. Adopt only if it materially improves these photographic workflows.

### SAM 3 / SAM 3.1 — current, but a different license path

The [official repository](https://github.com/facebookresearch/sam3) announces SAM 3.1 on March 27, 2026, and gated checkpoint access. Text/exemplar concept masks could make commands such as “keep the water moving” easier.

The [SAM License](https://github.com/facebookresearch/sam3/blob/main/LICENSE) covers model/software materials with custom redistribution and use conditions. **Restricted/custom**, not Apache-2.0. Larger capability does not establish better thin-edge masks or acceptable local latency.

**Decision:** track as an optional future capability; do not silently substitute it for SAM 2.1 or accept gated agreements in an automated build.

## Night restoration, calibration, and burst models

### PMRID — established baseline with local evidence

**Publication:** [Practical Deep Raw Image Denoising on Mobile Devices, ECCV 2020](https://arxiv.org/abs/2010.06935). **Contract:** packed Bayer → packed Bayer with prescribed noise normalization.

**Code:** [Apache-2.0](https://github.com/MegEngine/PMRID/blob/main/LICENSE). **Weights:** official PyTorch/MegEngine checkpoints are in the repository's `models` directory, documented in its [README](https://github.com/MegEngine/PMRID). Repository-scoped evidence; preserve the exact artifact record already investigated locally.

**Ceviche evidence:** the [October 27 evaluation](../../../experiments/denoise-evaluation/README.md) supports further calibrated Bayer experiments but reports weakened faint points and limited camera coverage. It is neither a universal astrophotography validation nor proof of end-to-end export speed.

**Decision:** first single-frame RAW prototype, with camera/ISO calibration and star-retention gates. Keep enhancement persistent rather than rerunning inference on sliders.

### RawNIND / UtNet2 — clear weight terms, quality/deployment caveats

**Publication:** [Learning Joint Denoising, Demosaicing, and Compression from the Raw Natural Image Noise Dataset, 2025](https://arxiv.org/abs/2501.08924).

**Code:** GPLv3. **Weights:** the [official README](https://github.com/trougnouf/rawnind_jddc) explicitly states dual GPL3 + CC-BY-4.0 licensing and links pretrained models. Record the chosen applicable licensing route and attribution in any release.

**Contract:** linear variant and Bayer joint-demosaic variant are distinct. The former expects linear Rec.2020; the latter outputs camera-native RGB before color conversion, per the [existing detailed investigation](../../../experiments/linear-dng/DENOISE-MODELS.md). Existing tests found star/texture issues; upstream Core ML precision concerns for the Bayer path also remain relevant.

**Decision:** comparative baseline, not selected over PMRID. Explicit licensing does not overcome an unsuitable input domain or poor star preservation.

### PNNP — 2026 camera noise modeling, not a universal denoiser

**Publication:** [TPAMI 2026; revised January 2026](https://arxiv.org/abs/2310.09126), originally a 2023 preprint. **Role:** learn aspects of sensor noise from dark frames and synthesize training noise for downstream restoration.

**Code:** [Apache-2.0](https://github.com/fenghansen/PNNP/blob/main/LICENSE). **Weights:** the [author release](https://github.com/fenghansen/PNNP) links Sony A7S2 and IMX686 resources on Baidu; separate weight/archive terms were not verified. The README says PNNP's own training code is not included, although downstream denoiser training code is available.

**Decision:** research reference for a calibration program, with a reproducibility gap for new camera training. Confirm resource terms and missing training components before planning a product dependency. Do not apply the A7S2 noise model to the existing A7RM3 samples merely because both are Sony.

### DEBIR — CVPR 2026 dynamic-exposure burst restoration

**Publication:** [Dynamic Exposure Burst Image Restoration](https://arxiv.org/abs/2603.21784). Predicts capture exposures and restores the resulting burst.

**Code:** [MIT](https://github.com/woo525/DEBIR/blob/main/LICENSE). **Weights:** the [official repository](https://github.com/woo525/DEBIR) links Google Drive checkpoints; no separate weight grant was established from the inspected README. Dependencies include Burstormer, EMA-VFI, and RAFT; audit any copied code and required pretrained components individually.

**Product fit:** only the restoration portion is relevant to already imported images. Capture-time exposure prediction would require a future tethered/mobile capture feature. Exact tensor normalization, output radiometry, burst length assumptions, and Apple export still need inspection and experiments.

**Decision:** promising 2026 research candidate for F2/F5; no automatic integration until checkpoint rights and sensor-domain behavior are verified.

### ASTERIS — 2026 astronomical self-supervised restoration

**Publication:** [Science 2026 / arXiv](https://arxiv.org/abs/2602.17205). **Role:** multi-exposure spatiotemporal denoising; a useful reference for evaluating point-spread functions, photometry, and faint-source detection.

**Code:** [MIT](https://github.com/freemercury/ASTERIS_THU/blob/main/LICENSE). **Weights:** the [official repository](https://github.com/freemercury/ASTERIS_THU) links four/eight-frame short/long-wavelength models on [Zenodo](https://doi.org/10.5281/zenodo.17114980). That record timed out during this research, so checkpoint license terms remain **unverified**.

The supplied models target aligned JWST/NIRCam imagery at a specified pixel scale. They are not ready-made DSLR sky/foreground models. Consumer-camera adaptation would require domain-specific training and validation. Paper-access permission is also separate from model permission; link the paper rather than redistributing its PDF.

**Decision:** valuable research/evaluation reference; defer production weights and any claim of faint-star recovery on Ceviche inputs.

### GraXpert — background estimation comparator

**Role:** astronomical background-gradient estimation, with classical and AI modes described in the [official README](https://github.com/Steffenhir/GraXpert).

**Code:** [GPLv3](https://github.com/Steffenhir/GraXpert/blob/main/License.md). **Weights:** no separately explicit grant established from the inspected README/license; external model versions require a separate audit.

**Decision:** classical background fitting is the first F8 approach. Use GraXpert's workflow as a comparator; do not assume application-source licensing automatically authorizes every downloaded ONNX model.

## Additional paper directions and exclusions

| Source | Useful lesson | Treatment |
| --- | --- | --- |
| [Image Stitching in Adverse Condition / ACDIS, NeurIPS 2025](https://github.com/ZengxiZhang/ACDIS) | Explicit low-light/haze stitching evaluation | Watchlist. Public code/checkpoint links are visible, but redistribution permissions and ASIS image provenance were not established. The README notes some images originate on the Internet. |
| [Depth-Supervised Fusion Network / DSFN, NeurIPS 2025](https://github.com/DLUT-YRH/DSFN) | Depth-conditioned seam/fusion research | Watchlist; license and checkpoint intake incomplete. Do not label it approved. |
| [Generative Panoramic Image Stitching, CVPR Workshops 2026](https://openaccess.thecvf.com/content/CVPR2026W/LoViF/html/Tuli_Generative_Panoramic_Image_Stitching_CVPRW_2026_paper.html) | Generative synthesis can conceal inconsistencies by changing image content | Creative-only research track. Unsuitable as the default for star geometry or faithful source-derived panoramas; no model adoption proposed. |
| [NTIRE 2025 Efficient Burst HDR and Restoration](https://openaccess.thecvf.com/content/CVPR2025W/NTIRE/html/Lee_NTIRE_2025_Challenge_on_Efficient_Burst_HDR_and_Restoration_Datasets_CVPRW_2025_paper.html) | A current benchmark for noisy, misaligned, differently exposed RAW bursts | Inspect candidate methods separately. Challenge participation or a paper does not grant code/weight/dataset rights. |
| [Training Neural Networks on RAW and HDR Images for Restoration Tasks, CVPR Workshops 2025](https://openaccess.thecvf.com/content/CVPR2025W/NTIRE/html/Ke_Training_Neural_Networks_on_RAW_and_HDR_Images_for_Restoration_CVPRW_2025_paper.html) | Training representation and loss strongly affect restoration | Useful for future training. Do not reinterpret an existing sRGB checkpoint as HDR-aware simply by changing its input transfer function. |
| [Handheld Multi-Frame Super-Resolution, TOG 2019](https://research.google/pubs/handheld-multi-frame-super-resolution/) | Exploit actual subpixel CFA observations and reject unreliable motion | Classical methodological baseline for F10; no claim of available Google production weights. |

Existing [NAFNet, TreeNet, and other denoise notes](../../../experiments/linear-dng/DENOISE-MODELS.md) remain relevant. NAFNet is a rendered-image/export baseline, not a new RAW-domain candidate. TreeNet's separately hosted weight licensing remains unresolved in the existing investigation. Do not expand the experiment matrix merely to add model names.

## Focus-stacking follow-up — October 2026

**Classical baseline:** [PetteriAimonen/focus-stack](https://github.com/PetteriAimonen/focus-stack) documents ECC alignment and complex-wavelet fusion. Its [LICENSE.md](https://github.com/PetteriAimonen/focus-stack/blob/master/LICENSE.md) grants MIT terms. It requires no learned weights; verify third-party components before incorporating code.

**Current learned candidate:** [StackMFF V3](https://github.com/Xinzhe99/StackMFF-V3), released October 2026, predicts source-selection probabilities for registered focal stacks. The official checkpoint is `stackmff_v3_final.pth`, linked from the repository's v2.0 release. The authors explicitly describe the manuscript as in preparation; do not label this a peer-reviewed publication. Code is [MIT](https://github.com/Xinzhe99/StackMFF-V3/blob/main/LICENSE), but the README's grant is explicitly for code and a separate checkpoint grant was not established. Treat weights as **unresolved** pending artifact intake. [Third-party notices](https://github.com/Xinzhe99/StackMFF-V3/blob/main/THIRD_PARTY_NOTICES.md) separately discuss training data, benchmark assets, and variant-dependent Depth Anything terms.

Its source-selection formulation is relevant to preserving recorded detail. Evaluate alignment errors, blurred-edge contamination, stack-length memory, and transfer from rendered-image inputs to Ceviche's linear/HDR domain. Predicting weights on a display proxy and applying them to aligned linear samples is a proposed adaptation, not validated behavior. It does not replace focus-breathing correction.

**Real-camera evaluation reference:** [Towards Real-World Focus Stacking with Deep Learning](https://arxiv.org/abs/2311.17846), submitted November 2023, describes 94 high-resolution RAW bursts and commercially generated pseudo-ground-truth. The [dataset repository README](https://github.com/araujoalexandre/FocusStackingDataset) does not provide a separate data license. Keep use/redistribution unresolved; photographer-owned brackets remain the initial corpus.

## Required artifact record before implementation ships

For each selected model, save a small Markdown record alongside the existing model inventory:

| Field | Required evidence |
| --- | --- |
| Identity | Official owner/repository, exact model variant, code commit, checkpoint revision/file, download origin |
| Integrity | SHA-256 of original weights, converted model, and license files; never infer hashes from a filename |
| Permission scope | Code license, explicit weight terms or documented repository scope, backbone licenses, required third-party code, outstanding questions |
| Distribution duties | License/NOTICE/attribution files, modification record, applicable source obligations, any custom acceptance conditions |
| Data provenance | Training datasets described by upstream; rights for any fine-tuning/evaluation data Ceviche acquires; redistribution separately tracked |
| Tensor contract | Input layout, CFA/color space, transfer function, normalization, output domain, supported range, masks, camera assumptions |
| Reproducibility | Conversion tool versions, settings, original-versus-converted error, supported execution backends, validation report |

Model conversion, quantization, distillation, and user-initiated download do not by themselves erase upstream terms. A missing license is a missing permission determination, not permission by default. For custom terms, inspect the proposed packaging rather than claiming that a separate process or optional download automatically resolves compatibility.

## Selected next evaluations

1. **XFeat/LighterGlue and one compatible LightGlue pair** against the existing matcher, holding the geometry and compositor constant.
2. **Seam/source selection and robust temporal stacking** with existing masks, before adding another model.
3. **PMRID with calibrated sources**, using the existing work but expanding camera and star-specific evaluation.
4. **DA3 Small** only if image-verified parallax diagnostics improve beyond the existing DA2 prior.
5. **PixelStitch** as an experimental local-warp comparison after artifact intake. UniStitch, DEBIR, PNNP, and ASTERIS remain conditional on their specific unresolved issues.

This ordering is based on Ceviche's current architecture, licensing evidence, and testability. It is not a published model leaderboard.
