# CevicheLab

Experimental photography algorithms, research notes, and CPU/GPU prototypes for [Ceviche](https://github.com/ChiChou/Ceviche). This repository holds experiments independently of the shipping editor. Results are observations on specific samples, not production-quality guarantees.

## Experiments

| Area | Code and notes | Status |
| --- | --- | --- |
| Stars, Milky Way, meteors, aurora trails | [StarStack](tools/starstack/README.md) | Swift/Metal CLI, Python references, measured experiments |
| Joint star alignment and mean denoise | [Latest Tenerife comparison](tools/starstack/TENERIFE-JOINT-MEAN.md) | Full-resolution CPU/Metal parity; no material quality gain over the previous mean |
| Chromatic aberration | [Chromatic](tools/chromatic/README.md) | Swift CPU reference and Metal port |
| Purple-fringe removal | [Unpurple](tools/unpurple/README.md) | CPU, Metal and Core Image implementations |
| Sensor/RGB denoise evaluation | [Denoise evaluation](experiments/denoise-evaluation/README.md) | Camera-specific model, quality and timing investigations |
| Reusable enhanced negatives | [Linear DNG](experiments/linear-dng/README.md) | DNG structure, preview, model and native-processing experiments |
| Future photographic workflows | [Research index](docs/research/photography-workflows-2026-10/README.md) | Focus stacking, sky/ground alignment, quality filtering, day/night transitions and native timelapse video |

## Build and test

Each Swift tool is an independent package. StarStack currently targets macOS 27; Chromatic and Unpurple declare macOS 13+. Check each package's instructions. Apple graphics services and a Metal-capable Mac are required for GPU checks.

```sh
swift test -c release --package-path tools/starstack
swift test -c release --package-path tools/chromatic
swift test -c release --package-path tools/unpurple
```

The StarStack Python mean experiments use NumPy, SciPy, OpenCV, Pillow and tifffile. Other model experiments have their own dependencies documented beside the scripts. Create a local virtual environment; no environment or downloaded dependency is committed. The [CPU/GPU mean contract](tools/starstack/MEAN-STACK-CPU-GPU.md) explains numerical checks and remaining work.

RAWs, trained weights and compiled Core ML models are supplied explicitly. The sky-mask experiment uses the existing Ceviche SkyRemoval conversion; follow the linked provenance/conversion notes in StarStack. Model files and third-party repository clones are not bundled. The DNG fixture runner and NAFNet check need a separate Ceviche checkout: set `CEVICHE_ROOT=/absolute/path/to/Ceviche`.

## Data and reproducibility

Keep new datasets under `samples/` or `datasets/`, generated files under an `output/` directory, and temporary builds under `.build/`. These paths, virtual environments, RAW formats, model weights and binary tensor caches are ignored. Put small, reviewed benchmark summaries or synthetic fixtures in a versioned `results/` or `Tests/` directory when they are suitable for publication. Do not force-add private photographs or downloaded checkpoints.

Most report links into `tools/starstack/output/` refer to local, ignored artifacts. They work in the migrated working copy but are intentionally unavailable in a fresh public clone. Historical DNG/denoise JSON results and two synthetic chart PNGs remain versioned. Published notes use placeholder sample paths; substitute your own input paths. These five-frame and fixed-camera experiments are not general-purpose importers.

## Migration and licensing

See [MIGRATION.md](MIGRATION.md) for origin, application dependencies and local cache relocation. The root [AGPL-3.0 license](LICENSE) is preserved from Ceviche. Upstream licenses and notices remain alongside their respective ports, including Unpurple, Chromatic and tetra3. A source-code license does not grant redistribution rights for every model or dataset discussed in the notes. No model weight is distributed here.
