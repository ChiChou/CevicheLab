# Chromatic: Swift + Metal chromatic aberration correction

A standalone macOS port of the false-color filtering method of Chang, Kang and Kang
(*Correction of Axial and Lateral Chromatic Aberration With False Color Filtering*, IEEE
Transactions on Image Processing, 2013), following Thomas Eboli's reference implementation
in [IPOL 2023/443](https://doi.org/10.5201/ipol.2023.443). Requires macOS 13+, Swift 5.10+,
and a Metal GPU for the default backend. The Double-precision CPU port is the reference.

## Build and use

From this directory:

```sh
swift build -c release
.build/release/chromatic input.tiff output.png
.build/release/chromatic -x 12 -y 12 --amount 0.8 input.tiff output.png
.build/release/chromatic --crop 5808,3772,1200,900 --repeat 5 --verify input.tiff crop.png
.build/release/chromatic --backend cpu input.png reference.png
.build/release/chromatic --help
swift test
```

The binary and `Chromatic_ChromaticCore.bundle` in `.build/release` must stay together;
the bundle holds the shader source, compiled at startup, and the upstream license
(`chromatic --license`).

## Method

Red and blue are corrected independently against green, which the method treats as the
in-focus guide. For each pixel and each of the two directions, a 1D window of radius `L`
(`-x` horizontal, `-y` vertical; the paper's defaults are 7 and 4) yields:

- **Transient improvement**: the channel is sharpened towards green's edge profile by a
  three-tap prefilter over the window's local extrema, clipped to the admissible range.
- **False color**: the sharpened chroma (`X - G`) is replaced by a weighted average of the
  window's chroma, weighting down neighbours across green or luma edges and dropping those
  of the opposite sign unless nearly achromatic (`--tau`).

The more achromatic estimate of the two directions is kept, and a per-pixel **arbitration**
blends TI and FC by the local contrast, so coloured scene edges are not greyed. `--amount`
blends the result with the input. The thresholds `tau`, `gamma1` and `gamma2` are fractions
of the signal range and were set for 8-bit display-referred data; linear RAW data will need
its own values.

Metal runs two passes: `horizontal` stores each pixel's two directional estimates (32 bytes
per pixel), and `vertical_and_merge` computes the vertical ones in registers, merges,
arbitrates and writes the result. Borders replicate the nearest pixel, as the reference's
edge padding does. Green and alpha are untouched.

### Departures from the reference code

The port follows the paper where the IPOL code departs from it:

1. The reference's arbitration call for blue passes its TI and FC images in swapped order.
2. Its contrast step indexes the green guide with `L + l` in one term instead of `j + l`.
3. Its fused slice loop compares each neighbour's chroma sign against the slice centre
   before that centre has been computed for the current pixel, so the first half of every
   window is weighted against the previous pixel's value.
4. Its finite-difference gradient reads one element before the row at the first column,
   which segfaults on page-aligned buffers.
5. Its false-color accumulator is never zeroed per pixel and relies on fresh allocations
   reading as zero.
6. It pads rows by the vertical radius while the horizontal pass skips its own radius of
   rows, so with unequal radii the outermost rows read uninitialised estimates.

With those patched, the reference and this port agree to float precision (a handful of
pixels per million differ by a few levels where Float and Double take different branches).
One detail of the reference is kept on purpose: the slice clipping tests the ceiling
before the floor, so where a neighbour's floor lies above its ceiling the floor wins; a
plain clamp changes the false-color result at about a third of all pixels.

## Validation and speed

`--verify` compares Metal against the CPU port; Float and Double take different branches
at the method's sign and threshold tests for a few isolated pixels, so the check is on the
count of differing values rather than the maximum. Tests cover a synthetic lateral fringe
(chroma falls by more than half, green and alpha are untouched), identity at zero amount,
backend agreement across radii, noise and tiny images, and parameter validation.
`ReferenceFixtureTests` pins two small outputs of the patched reference so a port change
that alters the branch order is caught.

On an Apple M4, a 7008x4672 frame takes 0.48 s of GPU time at the default radii, 0.88 s at
12x12 and 1.54 s at 20x20, plus about 0.5 s for texture upload and readback in the CLI; a
1200x900 crop takes 14 ms, against 3.2 s for the single-threaded Cython reference and 4.2 s
for the Double-precision CPU port.

## License

The algorithm belongs to its authors; the reference implementation this port follows is
MIT licensed, see [LICENSE.upstream](LICENSE.upstream), also bundled with the executable.
New Ceviche code follows the repository's [AGPL-3.0 license](../../LICENSE).
