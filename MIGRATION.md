# Experiment extraction — 2026-10-29

Extracted from [Ceviche at 32044f3bb735](https://github.com/ChiChou/Ceviche/tree/32044f3bb73503329be17304ed11ee77fb4af1a2), plus the uncommitted photography research and StarStack work developed on October 28–29. Existing copyright and license notices are preserved.

| Original location | CevicheLab location | Source checkout treatment |
| --- | --- | --- |
| `docs/research/photography-workflows-2026-10/` | same | Moved |
| `tools/starstack/` | same | Moved, including local ignored outputs |
| `tools/chromatic/` | same | Moved |
| `tools/unpurple/` | same | Copied; Ceviche's shipping app currently imports its original local package |
| `app/experiments/linear-dng/` | `experiments/linear-dng/` | Moved |
| `app/experiments/denoise-evaluation/` | `experiments/denoise-evaluation/` | Moved |

The Unpurple application copy is deliberately retained so extracting experiments does not break Ceviche's existing package dependency. Future work can choose a versioned package integration; that app migration is not included here. The opt-in `LinearDNGInvestigationTests` fixture generator also remains with the application because it exercises its internal renderer. Set `CEVICHE_ROOT` when invoking the lab's DNG runner or the NAFNet architecture check. Other links to application sources and model provenance point to the source revision above.

All 136 source/note/result files were verified against their pre-migration SHA-256 hashes before changing paths. Research documents and small historical reports use portable placeholder input paths. Algorithms and numerical results are preserved; migration edits concern references, explicit input configuration, documentation and ignore rules.

Local StarStack outputs, model experiments and virtual environments moved with the directory; they are excluded from the public commit. Known absolute recipe/configuration paths and virtual-environment launchers were relocated. Original camera files remain in their existing sample folders. Old Swift build products are retained under ignored `tools/starstack/output/migration-cache/pre-migration-swift-build/`; rebuild from the new path instead of using those stale binaries. Old chat file links still point to the previous checkout; the same files now live below this repository's `tools/starstack/output/`.

The original Ceviche working tree has the corresponding tracked experiment removals and updated documentation links for review. This task publishes CevicheLab only; it does not push or rewrite the application repository.

## Validation after relocation

All three Swift packages built from the new location: StarStack's 7 tests, Chromatic's 6 tests, and Unpurple's 11 tests passed. The 4 Python meteor-adapter tests and the synthetic CPU/Metal mean parity check passed using the moved Python environment. Python syntax, historical JSON parsing, shell syntax and non-generated relative Markdown links were checked. The two known whitespace warnings in inherited license text were retained to preserve those license files verbatim.

The initial public snapshot contains 140 files (about 1.4 MB), including source, notes, licenses, compact benchmark records and synthetic chart fixtures. Checks found no credential-pattern matches in the staged text, no generated output or model files staged, and verified ignore rules for local RAWs, outputs, models, environments and credentials. Full photographic inference was not rerun for this file migration.
