# Unpurple: Swift + Metal CLI

A standalone macOS port of [Martin Jambon's Unpurple](https://github.com/mjambon/purple-fringe),
based on commit `36d8f03a0a5fe65352fbc4531781d7f2db2f902f`.
This is the original heuristic, not the DCA-LUT neural model. No training, model downloads,
or third-party dependencies are needed. Requires macOS 13+, Swift 5.10+, and a Metal GPU
for the default backend. The CPU reference is available explicitly.

## Build and use

From this directory:

```sh
swift build -c release
.build/release/unpurple input.jpg output.png
.build/release/unpurple --gentle --radius 8 --verify input.jpg output.png
.build/release/unpurple --diff input.jpg removed-color.png
.build/release/unpurple --backend cpu input.jpg reference.png
.build/release/unpurple --help
swift test
```

The binary and `Unpurple_UnpurpleCore.bundle` in `.build/release` must stay together
when copied elsewhere. The bundle contains the shader source and upstream license;
Metal compiles the shader at process startup. `unpurple --license` prints the upstream terms.

Metal runs all six algorithm passes: build a blue-channel mask; horizontal and vertical
box blurs twice; then subtract red/blue with green-channel and red:blue constraints.
Borders replicate the nearest pixel. Correction amounts are truncated to integers as
in the OCaml implementation. The default radius is 5, intensity 1, minimum brightness 0,
and minimum/maximum removed red:blue ratios 0 and 0.33. All original options are supported.
Options are applied left-to-right, including `--gentle`.

`--verify` compares decoded, pre-encoding Metal output against the independent
Double-precision CPU implementation and refuses to write if any byte differs by more
than 1. Float GPU arithmetic can differ by one level at integer truncation boundaries;
bit-for-bit agreement with OCaml or its JPEG decoder is not promised. Metal failures
are reported, with no silent CPU fallback. Timings distinguish GPU execution,
processing including buffer allocation/readback, and total time including I/O and setup.

## Image handling and limits

These limits describe the standalone byte-based CLI. The separate `CoreImageProcessor`
API accepts and returns `CIImage` for Ceviche's RAW pipeline. Render that graph with
an extended-linear-sRGB `CIContext` and `CIFormat.RGBAf`. It uses continuous correction
in floating-point sRGB encoding, then returns linear values; no 8-bit quantization or
SDR-white clipping is applied. Green and alpha are preserved, and pixels containing
negative RGB components are left unchanged. The blue mask is alpha-weighted.
This HDR extension is an adaptation of Unpurple, not bit-identical OCaml behavior.
`scale` expresses preview resolution relative to the original and scales spatial taps;
the expanded regions of interest allow cropped/detail rendering without seams.
A `CIImageProcessorKernel` encodes six Metal compute passes on Core Image's command
buffer, with two R32F mask textures and RGBA32F input/output. The API validates
parameters immediately; shader/resource failures surface when the lazy graph renders.
It performs no CPU readback or GPU wait and does not normalize neighboring pixels independently.

- Input uses Apple's ImageIO decoder; only the first frame/image is processed.
- Processing is **8-bit gamma-encoded sRGB**, matching the upstream algorithm's byte-domain
  approach. Input profiles are converted to sRGB. This is not a RAW/HDR or 16-bit pipeline.
- EXIF orientation is applied before processing. Output orientation is normalized.
- Output supports PNG, JPEG, and TIFF. JPEG quality defaults to 0.95 (`--quality`).
  PNG/TIFF preserve alpha; JPEG refuses transparent input. Premultiplied image decoding
  can round RGB values around partially transparent pixels.
- EXIF/GPS/IPTC/TIFF dictionaries are copied where supported by the output format.
  Use `--strip-metadata` to omit them. Metadata preservation is not byte-for-byte;
  unsupported tags, embedded thumbnails, and source color profiles are not retained.
- Existing output files require `--force`; input and output paths must differ.
- Radius must be in `(0, 256]`, intensity in `[0, 100]`, brightness in `[0, 1)`,
  and red ratios must satisfy `0 <= minred <= maxred <= 100`. Zero intensity is a no-op.
  Radius zero is rejected because upstream's blur does not implement it as an identity.
- GPU working buffers total approximately 16 bytes/pixel, excluding decoded images and
  encoder memory. Blur work grows with radius. Very large images can exceed device memory.
- As with upstream, genuine blue/purple details can be desaturated; green fringing is not
  corrected. Start with `--gentle` and inspect the result and `--diff` output.

## Validation

Tests cover known correction values, an independent direct-convolution blur oracle,
CPU/Metal agreement across modes and parameter sets, tiny/narrow images and large
relative radii, green/alpha preservation, invalid inputs, lossless image round trips,
overwrite protection, orientation, and metadata. GPU tests skip only if no Metal
device is available; shader or execution failures fail the tests.

## License

The original algorithm and its port retain Martin Jambon's copyright notice and
BSD 3-clause-style terms in [LICENSE.upstream](LICENSE.upstream), also bundled with
the executable. The upstream notice separately declares its sample photos public
domain; no sample photos are bundled here. New Ceviche code follows the repository's
[AGPL-3.0 license](../../LICENSE).
