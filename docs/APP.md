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

Export, borders, RAW and the full advanced parameter panel are not part of this
slice.  There is no second LUT renderer.
