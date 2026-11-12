import FilmPhysics
import LightSufferPreview
import XCTest

final class PhotoInputSettingsTests: XCTestCase {

    func testPhotoKindDetectionFromExtensionsAndTypeIdentifiers() {
        XCTAssertEqual(PhotoKind.detect(filename: "holiday.JPG"), .jpeg)
        XCTAssertEqual(PhotoKind.detect(filename: "holiday.jpeg"), .jpeg)
        XCTAssertEqual(PhotoKind.detect(filename: "phone.HEIC"), .heic)
        XCTAssertEqual(PhotoKind.detect(filename: "graphic.png"), .png)
        XCTAssertEqual(PhotoKind.detect(filename: "capture.dng"), .dng)
        XCTAssertEqual(PhotoKind.detect(filename: "capture.CR3"), .dng)
        XCTAssertTrue(PhotoKind.detect(filename: "capture.nef").isRAW)
        XCTAssertEqual(PhotoKind.detect(filename: "capture.proraw"), .proraw)
        XCTAssertEqual(PhotoKind.detect(filename: "notes.txt"), .unknown)

        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "public.jpeg"), .jpeg)
        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "public.heic"), .heic)
        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "public.png"), .png)
        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "com.adobe.raw-image"), .dng)
        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "public.camera-raw-image"), .dng)
        XCTAssertEqual(PhotoKind.detect(typeIdentifier: "com.apple.proRAW"), .proraw)
    }

    func testPhotoKindDetectionFromMagicBytes() {
        XCTAssertEqual(PhotoKind.detect(data: Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(
            PhotoKind.detect(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])),
            .png
        )
        let heic = Data([
            0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
            0x68, 0x65, 0x69, 0x63, 0x00, 0x00, 0x00, 0x00,
        ])
        XCTAssertEqual(PhotoKind.detect(data: heic), .heic)
        XCTAssertEqual(PhotoKind.detect(data: Data([0x49, 0x49, 0x2A, 0x00])), .dng)
        XCTAssertEqual(PhotoKind.detect(data: Data([0x4D, 0x4D, 0x00, 0x2A])), .dng)
        XCTAssertEqual(PhotoKind.detect(data: Data([0x00, 0x01, 0x02])), .unknown)
    }

    func testRAWHintsAreConservativeAcrossContainerHints() {
        // A misleading processed-image UTI must not turn a DNG extension or
        // TIFF RAW signature into a silent processed-image decode.
        XCTAssertEqual(
            PhotoKind.detect(typeIdentifier: "public.jpeg", filename: "capture.dng"),
            .dng
        )
        XCTAssertTrue(PhotoKind.detect(filename: "capture.dng").isRAW)
        XCTAssertFalse(PhotoKind.heic.isRAW)
        XCTAssertFalse(PhotoKind.jpeg.isRAW)
        XCTAssertFalse(PhotoKind.png.isRAW)
    }

    func testWhiteBalanceDefaultsAndReferenceTemperatures() {
        let settings = PhotoInputSettings()
        XCTAssertEqual(settings.whiteBalanceMode, .asShot)
        XCTAssertEqual(settings.customTemperature, 6504)
        XCTAssertEqual(settings.customTint, 1)
        XCTAssertEqual(WhiteBalanceMode.daylightReferenceTemperature, 6504)
        XCTAssertEqual(WhiteBalanceMode.tungstenReferenceTemperature, 2850)
        XCTAssertEqual(settings.inputColorSpace, .automatic)
    }

    func testWhiteBalanceTemperatureResolution() throws {
        XCTAssertNil(try WhiteBalanceMode.asShot.resolvedTemperature(customTemperature: 3200))
        XCTAssertEqual(
            try WhiteBalanceMode.daylight.resolvedTemperature(customTemperature: nil),
            6504
        )
        XCTAssertEqual(
            try WhiteBalanceMode.tungsten.resolvedTemperature(customTemperature: nil),
            2850
        )
        XCTAssertEqual(
            try WhiteBalanceMode.custom.resolvedTemperature(customTemperature: 4321),
            4321
        )
        XCTAssertThrowsError(
            try WhiteBalanceMode.custom.resolvedTemperature(customTemperature: nil)
        ) { error in
            XCTAssertEqual(error as? PhotoInputSettingsError, .customTemperatureRequired)
        }
        XCTAssertThrowsError(
            try WhiteBalanceMode.custom.resolvedTemperature(customTemperature: .nan)
        )
    }

    func testAppleWhiteBalanceMappingUsesDemosaicPropertiesAndNeutralTint() throws {
        let asShot = try PhotoInputSettings().resolvedWhiteBalance()
        XCTAssertTrue(asShot.usesCameraWhiteBalance)
        XCTAssertNil(asShot.neutralTemperature)
        XCTAssertNil(asShot.neutralTint)
        XCTAssertTrue(asShot.mappingDescription.contains("CIRAWFilter"))

        let daylight = try PhotoInputSettings(whiteBalanceMode: .daylight).resolvedWhiteBalance()
        XCTAssertEqual(daylight.neutralTemperature, 6504)
        XCTAssertEqual(daylight.neutralTint, 0)
        XCTAssertFalse(daylight.usesCameraWhiteBalance)

        let tungsten = try PhotoInputSettings(whiteBalanceMode: .tungsten).resolvedWhiteBalance()
        XCTAssertEqual(tungsten.neutralTemperature, 2850)
        XCTAssertEqual(tungsten.neutralTint, 0)

        let custom = try PhotoInputSettings(
            whiteBalanceMode: .custom,
            customTemperature: 4100,
            customTint: 1.1
        ).resolvedWhiteBalance()
        XCTAssertEqual(custom.neutralTemperature, 4100)
        XCTAssertEqual(custom.neutralTint ?? .nan, -15, accuracy: 1e-12)
        XCTAssertTrue(custom.mappingDescription.contains("green"))
        XCTAssertTrue(custom.mappingDescription.contains("ACES"))
        XCTAssertEqual(PhotoInputSettings.coreImageNeutralTint(greenMultiplier: 1), 0)
        XCTAssertThrowsError(
            try PhotoInputSettings(
                whiteBalanceMode: .custom,
                customTemperature: 1000
            ).resolvedWhiteBalance()
        ) { error in
            XCTAssertEqual(
                error as? PhotoInputSettingsError,
                .temperatureOutsideCoreImageRange(1000)
            )
        }
    }

    func testNativeInputSpacesHaveMatchingLinearEngineTags() throws {
        for name in InputColorSpacePolicy.engineSupportedNames {
            let resolution = try InputColorSpacePolicy.resolve(.explicit(name))
            XCTAssertEqual(resolution.engine.inputColorSpace, name)
            XCTAssertFalse(resolution.engine.inputCCTFDecoding)
            XCTAssertFalse(resolution.requiresConversionFallback)
            XCTAssertNil(resolution.fallbackReason)
        }
    }

    func testFiveNonNativeSpacesFallBackToLinearProPhotoWithReason() throws {
        let fallbacks = ["DCI-P3", "Display P3", "Adobe RGB", "BT.2020", "ACES2065-1"]
        XCTAssertEqual(Set(PhotoInputColorSpace.offeredNames), Set(fallbacks + ["sRGB", "ProPhoto RGB"]))
        for name in fallbacks {
            let resolution = try InputColorSpacePolicy.resolve(.explicit(name))
            XCTAssertEqual(resolution.requestedName, name)
            XCTAssertEqual(resolution.engine.inputColorSpace, "ProPhoto RGB")
            XCTAssertFalse(resolution.engine.inputCCTFDecoding)
            XCTAssertTrue(resolution.requiresConversionFallback)
            XCTAssertEqual(
                resolution.fallbackReason,
                "\(name) is converted to linear ProPhoto RGB; the engine has no native \(name)."
            )
        }
    }

    func testUnknownInputSpaceIsAnErrorRatherThanAnEngineTag() {
        XCTAssertThrowsError(try InputColorSpacePolicy.resolve(.explicit("made-up-RGB"))) { error in
            XCTAssertEqual(
                error as? PhotoInputSettingsError,
                .unknownInputColorSpace("made-up-RGB")
            )
        }
    }

    func testDefaultSettingsPreserveCurrentPipelineContractAndDigest() throws {
        let baseline = try PreviewLook.pipelineParams()
        var params = try PreviewLook.pipelineParams()
        try PhotoInputSettings().apply(to: &params)

        XCTAssertEqual(params.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(params.io.inputCCTFDecoding)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertFalse(params.camera.autoExposure)
        XCTAssertEqual(params.film, baseline.film)
        XCTAssertEqual(params.print, baseline.print)
        XCTAssertEqual(params.filmRender, baseline.filmRender)
        XCTAssertEqual(params.printRender, baseline.printRender)
        XCTAssertEqual(params.stochastic, baseline.stochastic)
        XCTAssertEqual(params.camera, baseline.camera)
    }

    func testApplyingExplicitNativeAndFallbackSpacesWritesOnlySupportedTags() throws {
        var native = try PreviewLook.pipelineParams()
        try PhotoInputSettings(inputColorSpace: .explicit("sRGB")).apply(to: &native)
        XCTAssertEqual(native.io.inputColorSpace, "sRGB")
        XCTAssertFalse(native.io.inputCCTFDecoding)
        XCTAssertEqual(native.stochastic.grainSampler, .fast)
        XCTAssertFalse(native.camera.autoExposure)

        var proPhoto = try PreviewLook.pipelineParams()
        try PhotoInputSettings(inputColorSpace: .explicit("ProPhoto RGB")).apply(to: &proPhoto)
        XCTAssertEqual(proPhoto.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(proPhoto.io.inputCCTFDecoding)

        let fallbackSettings = PhotoInputSettings(inputColorSpace: .explicit("Display P3"))
        var fallback = try PreviewLook.pipelineParams()
        try fallbackSettings.apply(to: &fallback)
        XCTAssertEqual(fallback.io.inputColorSpace, "ProPhoto RGB")
        XCTAssertFalse(fallback.io.inputCCTFDecoding)
        XCTAssertEqual(try fallbackSettings.resolvedInputColorSpace.fallbackReason,
                       "Display P3 is converted to linear ProPhoto RGB; the engine has no native Display P3.")
        XCTAssertEqual(fallback.stochastic.grainSampler, .fast)
        XCTAssertFalse(fallback.camera.autoExposure)
    }

    func testNonRAWWhiteBalanceStatusSaysNoRetintWasApplied() throws {
        let settings = PhotoInputSettings(whiteBalanceMode: .tungsten)
        let status = try settings.status(for: .jpeg)
        XCTAssertTrue(status.contains("White balance applies to RAW files"))
        XCTAssertTrue(status.contains("not re-tinted"))
    }

    func testExportSnapshotUsesTheSameInputPolicy() throws {
        let request = ExportRequest(
            look: PreviewLook.defaultLook,
            adjustments: PreviewAdjustments(),
            inputSettings: PhotoInputSettings(inputColorSpace: .explicit("sRGB"))
        )
        let params = try request.pipelineParams()
        XCTAssertEqual(params.io.inputColorSpace, "sRGB")
        XCTAssertFalse(params.io.inputCCTFDecoding)
        XCTAssertEqual(params.stochastic.grainSampler, .fast)
        XCTAssertFalse(params.camera.autoExposure)
    }
}
