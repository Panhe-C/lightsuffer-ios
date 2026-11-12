# P4 app shell — interactive film preview

The SwiftUI app is an **Xcode-only application target**, not a Linux SwiftPM
application target.  The package continues to build on Linux and now also
contains `LightSufferPreview`, a Foundation-only helper library for geometry,
catalogue/session state, physical adjustments, RAW/input policy and pixel conversion. The app target itself imports
SwiftUI, PhotosUI, Image I/O, Core Graphics, Core Image and Metal only on iOS.

## Build

XcodeGen generates the project; the generated `.xcodeproj` is intentionally
not checked in.  CI generates it **after** its existing package-scheme loop,
so `xcodebuild -list` at the package root retains its previous meaning.

```bash
brew install xcodegen
xcodegen generate --spec project.yml
xcodebuild -project LightSuffer.xcodeproj \
  -scheme LightSuffer \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Open `LightSuffer.xcodeproj` after generation to run the app.  The deployment
target is iOS 17.  There are no app UI tests in this slice; the platform-neutral
helper tests run through SwiftPM:

```bash
swift test --build-system native --filter LightSufferPreviewTests
```

## Preview path

1. `PhotosPicker` supplies the selected photo as `Data`. The original bytes and
   metadata are retained so an input-policy change and an export can decode them
   again without reusing the preview's capped pixels.
2. Processed JPEG / HEIC / PNG files use Image I/O to create a thumbnail from the
   **whole source frame**, with EXIF transformation enabled and no crop. Core
   Image / ColorSync then honours the embedded profile and renders to an exact
   1280-pixel long edge as **32-bit floating-point extended linear sRGB**. This
   replaces the old 8-bit sRGB context: wide-gamut components are not silently
   clipped or mistagged before the film engine.
3. The default input policy matrix-converts those unclamped linear-sRGB floats
   to linear ProPhoto RGB. Native explicit sRGB instead retains linear sRGB.
   The hold-to-compare display image alone is encoded and clamped to sRGB.
4. `PreviewSession` starts at Kodak Portra 400 × Portra Endura.  Its bottom-strip
   catalogue contains all 20 camera films; selecting one chooses its `targetPrint`,
   or direct scan for a slide.  The adjustments sheet offers all eight print media
   and direct scan for negatives.  Each render builds fresh parameters through
   `StockCatalog.pipelineParams`, which disables the unported auto-exposure feature,
   applies the stock digest and preserves `GrainSampler.fast`. EV, grain,
   halation and `PhotoInputSettings` are then reapplied, so a look change does
   not discard either physical or input adjustments.
5. Look, physical-adjustment and input-setting changes are debounced for
   **200 ms**. Each photo/look/adjustment/input change invalidates the previous
   generation; only the newest completed render can be published. WB / input
   colour changes also re-decode the retained original bytes before rendering.
   The injected session scheduler is tested on Linux without sleeps.
6. The app creates `MetalBackend(device:)` from
   `MTLCreateSystemDefaultDevice()`.  A missing device, a failable initializer
   result, or a non-nil `initializationError` selects `CPUBackend` instead.
   Backend creation and rendering happen off the main actor.  A render error is
   shown in the view rather than crashing the app.
7. The encoded-sRGB output is clamped to display bytes and shown letterboxed above
   the compact bottom film strip.  Press/hold displays the original scaled photo;
   releasing restores the grade.

The basic sheet maps camera EV to `camera.exposureCompensationEV`, grain/halation
toggles to their `active` fields, and halation amount to
`filmRender.halation.halationAmount`.  Grain strength is a dimensionless physical
particle-area scale: every digested `filmRender.grain.particleScale[channel]` is
multiplied by the control value.  Thus 1.0 preserves the digest exactly and 1.5
makes every channel's effective particle area 1.5×; base particle area, channel
ratios and sublayer ratios are unchanged.  It is not a post-process noise layer.  No extra
colour curves or advanced parameter dump is present. The same sheet has a small
**Input** section for the detected kind, decoder/fallback status, WB and input
colour space; it is not the full advanced parameter panel.

`FilmPhysics.RGBImage.data` is **row-major interleaved `RGBRGB…`**, not planar.
The default pipeline contract is linear ProPhoto RGB input
(`inputCCTFDecoding == false`) and encoded sRGB output
(`outputCCTFEncoding == true`).  The app therefore does not apply another
transfer function to the rendered output.

There is no second LUT renderer.

## RAW, white balance and input colour space

### Detection and scene-linear decode

`LightSufferPreview.PhotoKind` provides Linux-testable detection from a UTI /
type identifier, filename extension and magic bytes (JPEG `FF D8`, PNG's
signature, HEIC `ftyp`, and little-/big-endian TIFF signatures). `dng` is the
model's RAW/DNG category; common camera-RAW extensions and TIFF signatures are
only **candidates**. On iOS the decoder also checks the actual Image I/O
container UTI, DNG/RAW metadata and `UTType` conformance to `rawImage`.

Ordinary JPEG and PNG stay on Image I/O. HEIC is probed because ProRAW can be
HEIC-wrapped. Any RAW hint must be validated by `CIRAWFilter`; an Apple DNG is
reported as ProRAW, as is a HEIC accepted by the RAW decoder. If a file looked
like RAW but `CIRAWFilter(imageData:identifierHint:)` cannot open it, or cannot
produce an output image, decoding fails with a visible error. It never silently
falls back to an 8-bit Image I/O interpretation of a Bayer / ProRAW file.

The iOS 17 RAW decode uses only APIs available since iOS 15:

- EXIF `orientation`, `nativeSize`, and `scaleFactor` (capped at 1; the preview
  still finishes at the existing exact 1280 px long edge);
- `exposure = 0`, `baselineExposure = 0`, `shadowBias = 0`, `boostAmount = 0`,
  `localToneMapAmount = 0`, `contrastAmount = 0`, `detailAmount = 0`, and
  `extendedDynamicRangeAmount = 0`;
- `boostShadowAmount = 1` (inert with zero boost), draft mode off and gamut
  mapping off;
- floating-point `.RGBAf` output through `CIContext` into extended linear sRGB,
  followed by the unclamped conversion to the selected engine input.

Thus boost / automatic baseline brightening, global and local tone curves,
local contrast/detail enhancement and EDR are disabled as far as the iOS 17 API
permits. Export repeats this decode at
`scaleFactor = 1` and full native size, subject to the existing 400 MP guard.

### WB modes and the iOS approximation

The four upstream modes are exposed for RAW / ProRAW / DNG. The constants match
`utils/raw_file_processor.py` exactly: daylight is **6504 K**, tungsten is
**2850 K**. Defaults are as-shot, custom temperature 6504 K and tint 1.0.

- **As shot** leaves CIRAWFilter's metadata-derived neutral properties untouched,
  the iOS counterpart of LibRaw `use_camera_wb`.
- **Daylight** sets `neutralTemperature = 6504` and `neutralTint = 0` at demosaic
  time. This approximates LibRaw's daylight-balanced default output; no extra
  adaptation is applied.
- **Tungsten** sets 2850 K / tint 0, and **custom** sets the chosen temperature
  and mapped tint at demosaic time. These are iOS approximations of upstream's
  daylight-balanced base followed by colour-science chromatic adaptation in
  linear ACES; CIRAWFilter is not LibRaw and no exact parity is claimed.
- Upstream tint is a multiplicative green-channel scale. The custom control
  keeps that meaning (1.0 is neutral) and maps it to Core Image's conventional
  green–magenta `neutralTint` with `(1 − greenMultiplier) × 150`, clamped to the
  documented −150…150 range. Positive Core Image tint is treated as magenta.
  Daylight / tungsten use tint 0. The typed properties are the iOS 17 interface
  to the RAW keys `inputNeutralTemperature` / `inputNeutralTint`.

For JPEG / HEIC / PNG the WB picker is disabled with **“White balance applies to
RAW files”**; as-shot is the baked-WB no-op and the app does not apply an
untested adaptation to processed images. Selecting a new photo resets input
settings to as-shot + automatic colour, so a processed photo cannot inherit the
previous RAW photo's WB. Look and physical-adjustment changes preserve the
current input settings.

### Engine-supported spaces and visible fallback

The Input section offers **embedded / automatic**, **sRGB**, **DCI-P3**,
**Display P3**, **Adobe RGB**, **BT.2020**, **ProPhoto RGB**, and **ACES2065-1**
(the longer upstream labels Adobe RGB (1998) and ITU-R BT.2020 are accepted by
the policy as aliases).

`FilmPhysics.RGBColourspace.named` still implements only **sRGB** and **ProPhoto
RGB**. No new engine colour spaces are claimed or passed through:

- automatic / embedded converts to linear ProPhoto RGB, tagged
  `inputColorSpace = "ProPhoto RGB"`, `inputCCTFDecoding = false`;
- explicit ProPhoto uses the same linear-ProPhoto tags;
- explicit sRGB converts to **linear sRGB**, tagged `"sRGB"` + CCTF decoding off
  (not encoded sRGB with CCTF on);
- the other five names are colour-managed to linear ProPhoto RGB through the
  Core Image / ColorSync + matrix path and tagged ProPhoto + CCTF off. The Input
  section reports, for example, **“Display P3 is converted to linear ProPhoto
  RGB; the engine has no native Display P3.”** An unknown name is an error.

`PreviewLook.pipelineParams` and the export request write only these supported
I/O tags. They do not alter the stock digest, camera auto-exposure policy or
grain sampler. The default remains linear ProPhoto + `.fast` + auto-exposure off.

## Full-resolution export

The preview is capped at a 1280-pixel long edge; the export is **not**.  The
export decodes the original source bytes again with
`PhotoDecoder.decodeFullResolution` (no cap, the only guard is the 400 MP safety
limit of `FramedImageRenderer.checkSize`) and renders the **whole** frame. The
export request's immutable `PhotoInputSettings` snapshot drives that decode, so
RAW demosaic, WB and input colour conversion are the same policy as preview—not
a second decode of the 1280 px input.

### The pipeline

`ExportPipeline.run` is the single entry point; it runs entirely off the main
actor.

1. `ExportRequest` is an immutable snapshot of the look, the adjustments, the
   border, the format (JPEG by default, HEIC on request), the quality (0.92),
   the EXIF orientation and the input settings of the source.
   `pipelineParams()` reuses `PreviewLook.pipelineParams`, so the export is the
   **same** grade and input-space tagging as the preview, with the **fast**
   grain sampler (`GrainSampler.fast`).
2. `ExportSpatialPolicy.requiredOverlap` computes, on the **full** frame, the
   overlap the spatial effects of the engine need (the three-sigma radius of
   the FIR Gaussians, an eight-sigma apron for the recursive Young–van Vliet
   Gaussians and the eight-decay-constant budget of the exponentials).
3. `ExportTilePlanner.plan` covers the frame with tiles.  The **interiors** of
   the tiles partition the frame exactly — every pixel is rendered once — and
   the overlap is discarded, so the grade has no gap and no seam.
4. Every tile is cropped out of the full-resolution linear engine-input image
   (ProPhoto by default / after fallback, or linear sRGB for native sRGB),
   rendered with `ExportSpatialPolicy.parametersForTile` (which scales the film
   format of the tile so that the physical size of a pixel is the one of the
   full frame) and cropped back to its interior with `tile.cropX`/`tile.cropY`.
   The tiles are stitched with `ExportImageBuffer` (the interleaved
   `RGBRGB…` layout of `FilmPhysics.RGBImage` and its display bytes).
5. The stitched frame is framed by `FramedImageRenderer.renderFull`: the border
   only adds margins around the picture.  The picture is **never cropped and
   never resampled** to make room for a border.
6. `ExportImageEncoder` writes a JPEG or a HEIC.  The pixels are already
   EXIF-upright, so every orientation tag is reset to **1** and the other
   metadata groups (EXIF, GPS, IPTC, …) are carried through; only the
   dimensions and the read-only container keys are regenerated.
7. `PhotoLibraryWriter` saves the file in the photo library with the
   **add-only** authorization (`PHAccessLevel.addOnly`,
   `requestAuthorization(for: .addOnly)`, `PHAssetCreationRequest`).  The app
   never asks for the read access of the library.  A refusal of the
   authorization and a failure of the save are shown as an error; they never
   crash the app.

### The device budget

The tile budget comes from the device:

```
working set = clamp(0.25 × device.recommendedMaxWorkingSetSize, 64 MiB, 512 MiB)
tile pixels = working set ÷ 192 bytes per pixel
tile side   ≤ 16384 px                (the dimension of a 2D texture of the Metal feature set)
```

The 192 bytes per pixel are a pessimistic estimate of the whole working set of
one rendered tile (about a dozen pooled RGB float buffers of 12 bytes per
pixel, the input, the read-back of the output and the CPU side copies).  A
frame that fits both limits is rendered in **one pass**; a bigger frame is
rendered with the overlapped tiles of the planner.

The Metal port of the engine is preferred (`MetalBackend(device:)` with a
device, a non-nil backend and no `initializationError`, the same rules as the
preview).  The CPU reference is used when there is no Metal device, and as the
last resort when the GPU cannot run a tile.

### The cancellation

`ExportCancellation` is checked between the stages and between the tiles.  A
render that is already running may finish; its result is then discarded.  A
newer export cancels the previous one (the generation discipline of the
preview), and a new photo cancels the running export.  The export runs on the
snapshot of the look, physical adjustments and input settings of the moment it
was started: a later change of the look does not modify the file that is being
written.  The cancel
button stops the export before the request of the photo library is submitted.

### The borders

The border painter is the vendored `Sources/FrameCore` of
`lightsuffer-border-mac` @ **f6de465**; it is used unchanged.

The export offers the six styles of `ExportRequest.offeredBorderStyles`, with
the names of `BorderStyle.displayName`: 无边框 (none), 120 胶片 (film120),
不规则细黑边 (edgeBlackThin), 不规则细白边 (edgeWhiteThin), 不规则黑边
(edgeBlack) and 不规则白边 (edgeWhite).  The preview shows the same border with
`FramedImageRenderer.renderPreview(photo:sourceSize:style:stockName:)`: the
layout is computed from the size of the **full** frame, so the border of the
preview has the proportions of the border of the export, while the film grade
itself stays the existing 1280-pixel preview render.

The full ~118-parameter advanced panel is still not part of this slice.

Linux tests cover file-kind hints / magic bytes, WB constants and mapping,
engine-tag / fallback policy, settings preservation and generation invalidation.
They do **not** execute CIRAWFilter, ColorSync, Metal or SwiftUI and do not
verify a real device. No preview ΔE or RAW colour accuracy has been measured on
a device in this step.
