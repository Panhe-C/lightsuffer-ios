# P4 app shell — interactive film preview

The SwiftUI app is an **Xcode-only application target**, not a Linux SwiftPM
application target.  The package continues to build on Linux and now also
contains `LightSufferPreview`, a Foundation-only helper library for geometry,
catalogue/session state, physical adjustments and pixel conversion.  The app target itself imports
SwiftUI, PhotosUI, Image I/O, Core Graphics and Metal only on iOS.

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

1. `PhotosPicker` supplies the selected photo as `Data`.
2. Image I/O creates a thumbnail directly from the **whole source frame**, with
   EXIF transformation enabled.  Core Graphics finishes scaling to an exact
   1280-pixel long edge in an explicit sRGB context.  No crop is requested.
3. `LightSufferPreview` drops RGBA alpha/padding, decodes the sRGB transfer
   function and converts the pixels to linear ProPhoto RGB.
4. `PreviewSession` starts at Kodak Portra 400 × Portra Endura.  Its bottom-strip
   catalogue contains all 20 camera films; selecting one chooses its `targetPrint`,
   or direct scan for a slide.  The adjustments sheet offers all eight print media
   and direct scan for negatives.  Each render builds fresh parameters through
   `StockCatalog.pipelineParams`, which disables the unported auto-exposure feature,
   applies the stock digest and preserves `GrainSampler.fast`.  EV, grain and
   halation adjustments are then reapplied, so a look change does not discard them.
5. Look and slider changes are debounced for **200 ms**.  Each photo/look/adjustment
   change invalidates the previous generation; only the newest completed render can
   be published.  The injected session scheduler is tested on Linux without sleeps.
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
colour curves, white-balance approximation or advanced parameter dump is present.

`FilmPhysics.RGBImage.data` is **row-major interleaved `RGBRGB…`**, not planar.
The default pipeline contract is linear ProPhoto RGB input
(`inputCCTFDecoding == false`) and encoded sRGB output
(`outputCCTFEncoding == true`).  The app therefore does not apply another
transfer function to the rendered output.  The input assumption for this slice
is an 8-bit sRGB display image; wide-gamut, RAW and explicit input-colour-space
handling are deliberately deferred.

There is no second LUT renderer.

## Full-resolution export

The preview is capped at a 1280-pixel long edge; the export is **not**.  The
export decodes the source bytes again with `PhotoDecoder.decodeFullResolution`
(no cap, the only guard is the 400 MP safety limit of
`FramedImageRenderer.checkSize`) and renders the **whole** frame.

### The pipeline

`ExportPipeline.run` is the single entry point; it runs entirely off the main
actor.

1. `ExportRequest` is an immutable snapshot of the look, the adjustments, the
   border, the format (JPEG by default, HEIC on request), the quality (0.92)
   and the EXIF orientation of the source.  `pipelineParams()` reuses
   `PreviewLook.pipelineParams`, so the export is the **same** grade as the
   preview, with the **fast** grain sampler (`GrainSampler.fast`).
2. `ExportSpatialPolicy.requiredOverlap` computes, on the **full** frame, the
   overlap the spatial effects of the engine need (the three-sigma radius of
   the FIR Gaussians, an eight-sigma apron for the recursive Young–van Vliet
   Gaussians and the eight-decay-constant budget of the exponentials).
3. `ExportTilePlanner.plan` covers the frame with tiles.  The **interiors** of
   the tiles partition the frame exactly — every pixel is rendered once — and
   the overlap is discarded, so the grade has no gap and no seam.
4. Every tile is cropped out of the full-resolution linear ProPhoto RGB image,
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
snapshot of the look and the adjustments of the moment it was started: a later
change of the look does not modify the file that is being written.  The cancel
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

RAW and the full advanced parameter panel are still not part of this slice.
