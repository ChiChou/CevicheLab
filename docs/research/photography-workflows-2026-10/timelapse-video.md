# Timelapse video from edited photographs

Research date: **2026-10-28**. This is a proposed feature design, supported by repository inspection and Apple's documentation. No application code, encoder prototype, or benchmark was produced.

## Recommendation

Add **Create Timelapse…** to the catalog's multi-image actions: select photographs, review the sequence and export settings, then generate a video in one background job. Use the photographs' current edits, with optional sequence-level exposure smoothing. A saved preset makes subsequent exports a single action followed by destination selection.

macOS supplies the necessary native building blocks. Core Image can render an image into a Core Video pixel buffer, and AVFoundation can write those buffers as video frames. Ceviche can build this with its existing image rendering and a native SwiftUI interface, without an external encoder executable or a downloaded model. Supported codec, resolution, profile, and frame-rate combinations still need validation on the target Mac. [Core Image rendering](https://developer.apple.com/documentation/coreimage/cicontext/render(_:to:)), [AVFoundation pixel-buffer receiver](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver).

**Format constraint:** use only Apple-provided native encoders and MOV/MP4 containers. Include HEVC/H.265 and ProRes in the initial format design, alongside H.264 for compatibility. Do not bundle FFmpeg, x265, or another codec implementation, and do not require third-party codec packs. Unsupported options are disabled with an explanation.

**Priority: P1.** Basic edited-image video export is a medium-sized integration proposal. Reliable day-to-night exposure transitions, stabilization, and HDR export should be separately scoped additions. Basic export does not depend on the proposed panorama/stacking engine.

## Photographer workflow

1. Select at least two photographs in the catalog and choose **Create Timelapse…**.
2. Review a filmstrip and playable preview. Confirm ordering, trim the sequence, and exclude unwanted frames. Show selected image count and resulting duration immediately.
3. Use current photo edits by default. Optionally enable **Smooth exposure** and compare before/after playback and the brightness curve. Previously edited images should not receive an unrelated automatic exposure adjustment on every frame.
4. Choose FPS, video size, framing, format, and quality. The preview shows the actual output crop, including portrait output or padding.
5. Choose **Generate Video**. Render and encode in the background, with progress, cancellation, and a final **Play** / **Reveal in Finder** result.

A sequence recipe records source identifiers, their order and exclusions, edit revisions, exposure corrections, framing, timing, and export settings. Freeze this state when the job starts so further Develop edits cannot change half of an in-progress movie. Sequence corrections remain separate from catalog photo edits; reopening the recipe allows another export without changing the originals.

The first version exports a silent video. Audio, titles, and a general-purpose video timeline are outside this feature's initial scope.

## GUI and defaults

Use a large preview with a scrubber and filmstrip, plus a compact settings panel. Put advanced encoding options behind disclosure controls.

| Control | Proposed behavior |
| --- | --- |
| Order | Capture time with subsecond precision where present; natural filename and manual ordering alternatives. Stable tie-breaking for duplicate timestamps. |
| Range | First/last frame, exclusions, and reverse. Show every exclusion before export. |
| FPS | Default 30; presets 24, 25, 30, 50, 60. Advanced exact fractional rates 24000/1001, 30000/1001, 60000/1001. |
| Video size | 1920×1080 default; 3840×2160; portrait 1080×1920; custom dimensions validated against the encoder. |
| Framing | Fit with padding by default; Fill with adjustable crop. One consistent output canvas and orientation. No stretching. |
| Timing | One photograph per video frame by default. Capture-interval timing is an advanced later option. |
| Format | Native H.264 or HEVC/H.265 in MP4/MOV; ProRes 422 in MOV, with optional 422 HQ. Default MP4/H.264 SDR Rec. 709. Enable only validated combinations. |
| Quality | Standard / High presets with codec-specific settings; advanced target bitrate where applicable. Display estimated size as an estimate. |
| Exposure | Current edits by default; optional smoothing strength, correction limit in stops, and analysis region. |
| Output | Destination, filename, collision policy, estimated duration, and export preset. |

For mixed aspect ratios, preview the crop/padding on every frame. Normalize EXIF orientation before framing. Composite transparent areas over an explicit matte. Common chroma-subsampled encoder paths require dimension alignment; validate the actual configuration instead of silently changing the requested size. Keep a sequence-wide framing policy so automatic per-frame crops do not produce visible zoom pulses.

Missing originals, unreadable files, and ambiguous ordering are preflight issues. Default to requiring resolution before starting. If an image fails during rendering, stop with its identity and a retry option; never silently skip it and change the movie's timing. A future explicit hold-previous-frame policy can preserve timing when the photographer chooses it.

## Native formats and platform policy

**The current application already requires macOS 27.0.** Both [Package.swift](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Package.swift) and [Info.plist](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Info.plist) declare it, and the [app README](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/README.md) agrees. The separate [signing-stub project](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Signing/CevicheSigning.xcodeproj/project.pbxproj) declares macOS 14.0; that provisioning helper does not establish the main app's deployment target. No platform requirement was changed during this research.

HEVC and ProRes encoding are older capabilities than this application's minimum. Inspection of the installed Apple macOS 27.0 SDK's `AVFoundation.framework/Headers/AVVideoSettings.h` shows the modern `AVVideoCodecTypeHEVC` and `AVVideoCodecTypeAppleProRes422` constants available from macOS 10.13, and `AVVideoCodecTypeAppleProRes422HQ` from 10.15. These are **API availability annotations**, not promises that every profile, resolution, or hardware encoder exists. Apple's WWDC20 documentation also describes native HEVC and ProRes software encoding on Macs. [Apple codec definitions](https://developer.apple.com/documentation/avfoundation/avvideocodectype), [Apple's encoder discussion](https://developer.apple.com/videos/play/wwdc2020/10010/).

| Codec | Containers offered | Product role | Availability policy |
| --- | --- | --- | --- |
| H.264/AVC | MP4, MOV | Compatible SDR delivery; MP4 default | Validate native writer settings and a representative encode. |
| HEVC/H.265 | MP4, MOV | Efficient delivery; later optional Main10 HDR | Check the requested profile, dimensions, frame rate, and color mode together. |
| Apple ProRes 422 / 422 HQ | MOV | High-quality editing/interchange output | Use the system encoder; expose profile selection instead of a generic bitrate-quality slider. |

MOV and MP4 are containers; ProRes and HEVC are codecs. The UI should offer supported pairs rather than an unrestricted codec/container cross-product. ProRes RAW is outside this design: the inputs at the encoder stage are developed image frames, and ordinary ProRes 422 serves that workflow.

**Proposed product baseline: macOS 15 Sequoia and later**, to reach users two major releases below macOS 27. The release sequence is 15 → 26 → 27. macOS 14 is outside the intended support range. This updates the design direction; the current application's macOS 27 configuration remains unchanged during research. Gate newer APIs and individual export configurations instead of raising the whole application's minimum for optional features.

### Proposed macOS 15+ support matrix

| OS target | Proposed native timelapse support | Writer implementation |
| --- | --- | --- |
| macOS 26 | H.264, HEVC, and ProRes through the system encoders, subject to configuration checks | Modern `AVAssetWriterInput.PixelBufferReceiver`, including asynchronous append. |
| macOS 15 Sequoia | Same codec/container policy; no need to remove HEVC or ProRes solely because of the OS version | `AVAssetWriterInputPixelBufferAdaptor` with writer-input readiness/backpressure handling. |
| macOS 27 | Same native codec/container policy, with newer optional features where useful | Modern receiver; no reason to make basic timelapse exclusive to 27. |

Availability was checked directly in the installed Apple macOS 27.0 SDK: `usr/lib/swift/AVFoundation.swiftmodule/arm64e-apple-macos.swiftinterface` annotates `PixelBufferReceiver` and `inputPixelBufferReceiver` with **macOS 26.0**. `AVFoundation.framework/Headers/AVAssetWriterInput.h` declares the older pixel-buffer adaptor from **macOS 10.7**, deprecated for Swift from **macOS 27.0**. Deprecation does not mean removal; the adaptor remains the appropriate compatibility path for macOS 15. [Modern receiver](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver), [older adaptor](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor).

For the proposed macOS 15-compatible implementation, isolate the two writer paths behind the same frame-sink interface: modern receiver on 26+, adaptor on 15. Keep ordering, color conversion, timestamps, and error policy shared. An OS availability branch selects the API; runtime encoder checks select supported output configurations. Native hardware acceleration and native software encoding remain separate capability questions.

**Application compatibility work:** the macOS 15 baseline is a product proposal, not confirmation that the whole app already works there. For example, the current [Object selection implementation](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Sources/CevicheCore/RawRenderer+Selection.swift) directly uses the iterative Vision segmentation feature documented as macOS 27 in the app README. Lowering the application minimum also needs an audit of that feature, image encoders, SwiftUI, persistence, and other newer APIs, with appropriate fallbacks or disabled controls. Merely changing `Package.swift` and `Info.plist` would not establish compatibility.

No macOS 15/26 runtime tests or whole-app backport build were performed. The table describes supported API architecture and a proposed implementation policy. Release validation should cover macOS 15, 26, and 27; there is no planned macOS 14 test or compatibility obligation.

When implementing the lower baseline, update the package, launch metadata, build/release configuration, and documentation together after resolving availability issues. Keep basic timelapse and its native codec choices available on 15; gate optional 26/27-only functionality with clear requirements. Any future increase of the product minimum should be an explicit support-policy decision. A higher OS version still does not supply missing hardware acceleration.

Native software encoding is allowed when Apple provides it. Lack of a dedicated HEVC or ProRes hardware engine should affect performance expectations, not automatically disable an otherwise functional export. Discover available encoders and their hardware flags through VideoToolbox where needed, then verify the actual writer configuration; decoding support is not an encoding capability test. [Encoder enumeration](https://developer.apple.com/documentation/videotoolbox/vtcopyvideoencoderlist(_:_:)), [encoder information keys](https://developer.apple.com/documentation/videotoolbox/video-encoder-list-keys).

Show disabled settings with a specific reason, such as an unavailable encoder or an unsupported size/profile combination. Preserve a loaded preset's requested settings and ask the photographer to select a supported alternative instead of silently changing codec, bit depth, or HDR mode. If no allowed encoder works, disable **Generate Video**. This remains a proposed capability policy; no encoding probe was run during the research.

## FPS, EXIF time, and exposure time

These values have different roles:

| Value | Role |
| --- | --- |
| Output FPS | How quickly the selected sequence plays. |
| EXIF capture time | Ordering, gap detection, capture-span reporting, and optional real-interval playback mapping. |
| Exposure duration | Motion blur within each captured photograph and a clue to camera exposure changes. It is not the video frame duration. |

In the default mode, `N` photographs at `f` FPS produce `N/f` seconds. For example, 600 photos at 30 FPS produce 20 seconds. If photographed every five seconds, their first-to-last capture span is 2,995 seconds: display that separately from movie duration. Changing FPS changes speed and duration without creating new photographic samples.

Represent FPS as a rational `p/q`. Give frame `i`, starting at zero, presentation time `i*q/p` seconds and explicitly end the session at `N*q/p`. Use rational `CMTime` values rather than accumulating floating-point frame durations. The final image must remain visible for a full frame interval. Apple's session documentation makes explicit end-time handling relevant; encoder compression settings alone do not define the submitted frames' presentation timeline. [AVAssetWriter session timing](https://developer.apple.com/documentation/avfoundation/avassetwriter/endsession(atsourcetime:)).

In a later **Respect capture intervals** mode, map capture-time offsets through a chosen acceleration factor, then sample that timeline at the output FPS. Hold/nearest-frame sampling is a transparent starting policy; show where a long capture gap causes a hold. Define the final hold duration explicitly because the last photograph has no following capture interval. Optical-flow or generative interpolation should be a separate optional feature, with its own moving-object and star-fidelity evaluation.

Use the timestamp-quality handling described in the [star-motion design](star-motion-and-focus-stacking.md): offsets, subsecond precision, duplicates, inconsistent clocks, and uncertain metadata need explicit handling. Filename order remains useful when timestamps are too coarse. For interval-based sampling, choose and record a consistent exposure-start or exposure-midpoint convention; changing shutter duration can make the difference visible.

Night timelapse should normally retain the stars' apparent motion. The star-stack workflow's common-epoch sky registration would erase part of the motion the photographer wants here. Optional tripod-jitter correction should anchor the ground, while leaving celestial motion intact.

## Exposure preparation and deflicker

The goal is to suppress unwanted frame-to-frame brightness jumps while preserving the intended evolution of a sunset, sunrise, cloud shadow, or artificial-light event. Matching every frame to one brightness would destroy that evolution.

Proposed initial method, to be validated on real sequences:

1. Render low-resolution analysis proxies from a consistent linear working stage, including the selected base exposure edits but before the proposed temporal correction and display tone mapping.
2. Estimate robust luminance from a consistent analysis region. Exclude clipped highlights, near-black unreliable samples, and obvious transients where practical. Allow a photographer-selected static region; mark low-confidence estimates when moving clouds or subjects dominate it.
3. Convert the per-frame luminance statistic to log2 units. Fit a robust smooth target curve over time. The difference between target and measured brightness is the proposed exposure correction in stops.
4. Limit correction magnitude, expose smoothing strength, and preview the correction curve. Apply the correction as an additive exposure adjustment in the linear rendering stage, before the common output tone transform.
5. Allow protected intervals or manual anchors for intentional changes such as lightning, lights switching on, and a deliberate day-to-night transition.

This is a design proposal, not a claimed state-of-the-art deflicker algorithm. Scene illumination and camera-induced flicker are not always distinguishable from image statistics. Low confidence should reduce automatic correction and invite an anchor, rather than forcing a flat result.

EXIF shutter duration, aperture, and ISO can identify likely camera exposure steps and support diagnostics. They do not alone establish scene brightness, exact sensor gain, lens transmission, or the photographer's desired final exposure. Use metadata as a prior alongside measured images. Avoid correcting a step twice when existing Develop edits already compensate for it.

Keep white-balance smoothing separate and opt-in. Copying a shared look across a sequence can help consistency, but indiscriminately copying one exposure value would overwrite intentional per-image corrections. A later keyframe workflow can interpolate supported global adjustments, including exposure in stops and validated white-balance parameters; arbitrary masks and source-dependent geometry need their own rules.

Temporal noise consistency also matters: individually plausible denoised frames may shimmer when played together. Validate existing denoise/sharpening settings in motion, especially for faint stars and foliage. Do not assume a still-image quality improvement automatically improves a timelapse.

## Native macOS export design

Proposed data flow:

```text
Ordered source IDs + frozen edit revisions + sequence recipe
    → proxy analysis and preview
    → bounded full-quality frame rendering
    → exposure correction, common framing, output color transform
    → pooled Core Video pixel buffers
    → AVAssetWriter with explicit presentation times
    → finalized and validated MP4/MOV
```

Use `AVAssetWriter` for creating video from rendered frames. Current Apple documentation exposes `AVAssetWriterInput.PixelBufferReceiver`, including an asynchronous append that waits for readiness and a recyclable buffer pool. Prefer this API when available in the project's SDK/deployment combination; older pixel-buffer-adaptor examples should not be copied without checking their deprecation and availability. No new media framework wrapper is required merely to get a first prototype working. [Pixel-buffer receiver](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver), [asynchronous append](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver/append(_:with:)).

Backpressure must pause frame production. If using immediate append, a false result means retry the same buffer and timestamp when ready, not advance to the next photograph. Finish the input and the writing session correctly, then await successful file finalization before reporting completion. [Immediate append behavior](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/pixelbufferreceiver/appendimmediately(_:with:)).

Bound in-flight decoding and rendering to a small queue. One uncompressed 3840×2160 BGRA8 frame is approximately 33.2 MB before row padding; RAW decoding, float working images, caches, and encoder storage add more. Do not decode a whole sequence into memory. Reuse a rendering context and buffer pool, while preserving asynchronous buffer ownership until encoding no longer needs the contents.

Check codec/container compatibility with `canApply(outputSettings:forMediaType:)`, then validate input creation and a real encode path for supported presets. That method is a format/settings check, not a guarantee of hardware acceleration, sustained throughput, or sufficient memory. Handle startup, append, and finalization errors. [Apple's compatibility check](https://developer.apple.com/documentation/avfoundation/avassetwriter/canapply(outputsettings:formediatype:)).

Write to a temporary file in the destination's filesystem and publish the result only after successful finalization and validation. Preserve the selected overwrite/rename policy. Cancellation removes the temporary output; do not promise resumability of partially written MP4 files. Saved recipes and reusable analysis caches can make a restart cheaper.

## Color and HDR

Start with a deliberate SDR Rec. 709 output transform. Convert the image pixels appropriately, and set matching color primaries, transfer-function, and matrix metadata. Merely labeling an sRGB or wide-gamut still render as Rec. 709 is insufficient. Where source buffers and output settings have different tags, AVFoundation may perform color conversion; design one coherent conversion path to avoid double conversion. Compare an actually encoded preview with the intended appearance. [Apple's video color guidance](https://developer.apple.com/documentation/avfoundation/tagging-media-with-video-color-information), [color-property combinations](https://developer.apple.com/documentation/avfoundation/setting-color-properties-for-a-specific-resolution).

HDR is a later explicit output mode. Use suitable high-precision intermediates and an appropriate 10-bit output path, matching HLG or PQ signaling and codec configuration. Apple's documented HEVC HDR path requires Main10; HDR10 also needs considered mastering/content-light metadata. A still photo's HDR headroom or gain map does not automatically become a correctly authored HDR movie. ProRes is an additional editing-oriented output candidate. Validate current hardware/OS capabilities rather than treating a historical support table as a current guarantee. [Apple's HDR export architecture](https://developer.apple.com/videos/play/wwdc2020/10010/).

## Fit with the current repository

| Existing component | Proposed reuse or boundary |
| --- | --- |
| [CatalogExport.swift](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Sources/Ceviche/CatalogExport.swift) | Selection, destination/preset conventions, cancellation, and job coordination. Video needs its own ordering and failure policy; the still batch export's skip behavior must not silently carry over. |
| [RawRenderer+Export.swift](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Sources/CevicheCore/RawRenderer+Export.swift) | Reuse the image development pipeline through a future rendered-frame interface before still-file encoding. Avoid exporting temporary JPEGs and decoding them again. |
| [ExportSizing.swift](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Sources/CevicheCore/ExportSizing.swift) | Reuse applicable sizing math, with a fixed video canvas and explicit sequence-wide framing. |
| [ActivityCenter.swift](https://github.com/ChiChou/Ceviche/blob/32044f3bb73503329be17304ed11ee77fb4af1a2/app/Sources/Ceviche/ActivityCenter.swift) | Background status, cancellation, and a completed file result. Show analysis, rendering/encoding, and finalizing phases. |

Keep the sequence recipe distinct from a merged-still recipe: it produces many timed frames. Source revision tracking, rendering caches, and job infrastructure can be shared with the [broader architecture proposal](architecture-and-evaluation.md). A movie need not become a new editable photo-catalog source for this workflow to be useful.

The MVP needs no new model weights and therefore no new checkpoint licensing decision. It uses platform frameworks and the project's existing image dependencies. External video encoders and third-party codec packs are excluded by the native-only format policy.

## Delivery stages and acceptance checks

| Stage | Deliverable |
| --- | --- |
| A — Native export | Current photo edits, ordering, trim/exclude, FPS, size, Fit/Fill, SDR H.264/HEVC in MP4/MOV and ProRes 422 in MOV, capability gating, presets, preview, background cancellation. Validate each exposed encoder independently. |
| B — Consistent exposure | Optional robust deflicker, brightness/correction curves, analysis region, protected intervals, and saved sequence corrections. |
| C — Advanced photography | Day-to-night keyframes, capture-interval timing, ground stabilization, HDR through supported native HEVC/ProRes configurations, optional pan/zoom. Each needs its own validation. |

Proposed release checks:

- Decode output and verify expected frame count, ordering, monotonic presentation timestamps, full last-frame duration, and exact rational-rate timing over long exports. Test encoder backpressure without dropped frames.
- Verify the native codec/container matrix, unavailable-option explanations, saved presets containing unsupported settings, and Apple software-encoder paths where available. If older OS support is introduced, test both sides of every API availability guard.
- Exercise portrait/mixed-orientation sources, custom dimensions, missing originals, duplicate timestamps, cancellation, destination collisions, disk-full errors, and corrupt frames. Failed jobs must not leave a successful-looking final file.
- Test SDR color charts, gradients, saturated lights, and night skies in encoded playback, including banding and black-level behavior. Assess HDR separately before exposing it.
- Compare exposure smoothing on static scenes, sunsets, auto-exposure steps, moving clouds, and lightning. Reduce artificial brightness jumps while retaining annotated real events and gradual illumination changes.
- Measure peak memory and export throughput on representative Macs and long high-resolution RAW sequences. Keep catalog editing responsive and ensure edits made after job submission do not alter the frozen result.

These are proposed checks, not completed tests. The immediate product value is turning already edited photographs into a correctly timed, color-managed movie through one native export workflow.
