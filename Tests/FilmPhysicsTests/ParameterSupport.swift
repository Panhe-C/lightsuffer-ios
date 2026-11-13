//
//  ParameterSupport.swift
//  light suffer胶片 — iOS app
//
//  The helpers that rebuild the upstream parameters of a reference fixture
//  case in Swift.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation
import XCTest
import FilmPhysics

extension JSONValue {

    /// The halation parameters of a fixture.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_schema.HalationParams`.
    func halationParams(file: StaticString = #filePath, line: UInt = #line) throws -> HalationParams {
        var params = HalationParams()
        guard let halation = self["halation"] else { return params }
        if let active = halation["active"]?.bool { params.active = active }
        if let value = halation["scatter_amount"]?.double { params.scatterAmount = value }
        if let value = halation["scatter_spatial_scale"]?.double { params.scatterSpatialScale = value }
        if let value = halation["halation_amount"]?.double { params.halationAmount = value }
        if let value = halation["halation_spatial_scale"]?.double { params.halationSpatialScale = value }
        if let values = halation["scatter_core_um"]?.doubles { params.scatterCoreUM = values }
        if let values = halation["scatter_tail_um"]?.doubles { params.scatterTailUM = values }
        if let values = halation["scatter_tail_weight"]?.doubles { params.scatterTailWeight = values }
        if let value = halation["boost_ev"]?.double { params.boostEV = value }
        if let value = halation["boost_range"]?.double { params.boostRange = value }
        if let value = halation["protect_ev"]?.double { params.protectEV = value }
        if let values = halation["halation_strength"]?.doubles { params.halationStrength = values }
        if let values = halation["halation_first_sigma_um"]?.doubles {
            params.halationFirstSigmaUM = values
        }
        if let value = halation["halation_n_bounces"]?.int { params.halationNBounces = value }
        if let value = halation["halation_bounce_decay"]?.double {
            params.halationBounceDecay = value
        }
        if let value = halation["halation_renormalize"]?.bool { params.halationRenormalize = value }
        return params
    }

    /// The diffusion filter parameters of a fixture.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_schema.DiffusionFilterParams`.
    func diffusionFilterParams(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> DiffusionFilterParams {
        var params = DiffusionFilterParams()
        guard let filter = self["diffusion_filter"] else { return params }
        if let active = filter["active"]?.bool { params.active = active }
        if let value = filter["filter_family"]?.string { params.filterFamily = value }
        if let value = filter["strength"]?.double { params.strength = value }
        if let value = filter["spatial_scale"]?.double { params.spatialScale = value }
        if let value = filter["halo_warmth"]?.double { params.haloWarmth = value }
        if let value = filter["core_intensity"]?.double { params.coreIntensity = value }
        if let value = filter["core_size"]?.double { params.coreSize = value }
        if let value = filter["halo_intensity"]?.double { params.haloIntensity = value }
        if let value = filter["halo_size"]?.double { params.haloSize = value }
        if let value = filter["bloom_intensity"]?.double { params.bloomIntensity = value }
        if let value = filter["bloom_size"]?.double { params.bloomSize = value }
        return params
    }

    /// The grain parameters of a fixture.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_schema.GrainParams`.
    func grainParams(file: StaticString = #filePath, line: UInt = #line) throws -> GrainParams {
        var params = GrainParams()
        guard let grain = self["grain"] else { return params }
        if let active = grain["active"]?.bool { params.active = active }
        if let value = grain["sublayers_active"]?.bool { params.sublayersActive = value }
        if let value = grain["particle_area_um2"]?.double { params.particleAreaUM2 = value }
        if let values = grain["particle_scale"]?.doubles { params.particleScale = values }
        if let values = grain["particle_scale_layers"]?.doubles { params.particleScaleLayers = values }
        if let values = grain["density_min"]?.doubles { params.densityMin = values }
        if let values = grain["uniformity"]?.doubles { params.uniformity = values }
        if let value = grain["blur"]?.double { params.blur = value }
        if let value = grain["blur_dye_clouds_um"]?.double { params.blurDyeCloudsUM = value }
        if let values = grain["micro_structure"]?.doubles { params.microStructure = values }
        if let value = grain["n_sub_layers"]?.int { params.nSubLayers = value }
        return params
    }

    /// The glare parameters of a fixture.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_schema.GlareParams`.
    func glareParams(file: StaticString = #filePath, line: UInt = #line) throws -> GlareParams {
        var params = GlareParams()
        guard let glare = self["glare"] else { return params }
        if let active = glare["active"]?.bool { params.active = active }
        if let value = glare["percent"]?.double { params.percent = value }
        if let value = glare["roughness"]?.double { params.roughness = value }
        if let value = glare["blur"]?.double { params.blur = value }
        return params
    }

    /// The DIR coupler parameters of a fixture.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_schema.DirCouplersParams`.
    func dirCouplersParams(
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> DirCouplersParams {
        var params = DirCouplersParams()
        if let active = self["active"]?.bool { params.active = active }
        if let value = self["amount"]?.double { params.amount = value }
        if let value = self["inhibition_samelayer"]?.double { params.inhibitionSamelayer = value }
        if let value = self["inhibition_interlayer"]?.double { params.inhibitionInterlayer = value }
        if let values = self["gamma_samelayer_rgb"]?.doubles { params.gammaSamelayerRGB = values }
        if let values = self["gamma_interlayer_r_to_gb"]?.doubles {
            params.gammaInterlayerRToGB = values
        }
        if let values = self["gamma_interlayer_g_to_rb"]?.doubles {
            params.gammaInterlayerGToRB = values
        }
        if let values = self["gamma_interlayer_b_to_rg"]?.doubles {
            params.gammaInterlayerBToRG = values
        }
        if let value = self["diffusion_size_um"]?.double { params.diffusionSizeUM = value }
        if let value = self["diffusion_tail_um"]?.double { params.diffusionTailUM = value }
        if let value = self["diffusion_tail_weight"]?.double { params.diffusionTailWeight = value }
        return params
    }
}

/// Builds the pipeline parameters of a reference fixture case.
///
/// The fixtures store the *digested* upstream parameters, so the port can
/// replay them exactly.
func makePipelineParams(
    fixture: JSONValue,
    film: Profile,
    print printProfile: Profile,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> PipelineParams {
    let params = try XCTUnwrap(fixture["params"], file: file, line: line)
    let camera = try XCTUnwrap(params["camera"], file: file, line: line)
    let io = try XCTUnwrap(params["io"], file: file, line: line)
    let enlarger = try XCTUnwrap(params["enlarger"], file: file, line: line)
    let scanner = try XCTUnwrap(params["scanner"], file: file, line: line)
    let unsharp = try XCTUnwrap(scanner["unsharp_mask"]?.doubles, file: file, line: line)
    let filmRender = try XCTUnwrap(params["film_render"], file: file, line: line)
    let grain = try XCTUnwrap(filmRender["grain"], file: file, line: line)

    let inputColourSpace = try XCTUnwrap(
        io["input_color_space"]?.string, file: file, line: line
    )
    let outputColourSpace = try XCTUnwrap(
        io["output_color_space"]?.string, file: file, line: line
    )
    let inputGamutCompress = try XCTUnwrap(
        io["input_gamut_compress"], file: file, line: line
    )
    let outputGamutCompress = try XCTUnwrap(
        io["output_gamut_compress"], file: file, line: line
    )

    // The digest of the stock (the DIR coupler chemistry and the halation
    // baseline) is applied by the pipeline itself; the fixture already holds
    // the digested values.
    var digest = Digest.filmRender(for: film)
    digest.dirCouplers = try XCTUnwrap(
        filmRender["dir_couplers"], file: file, line: line
    ).dirCouplersParams(file: file, line: line)
    digest.densityCurveGamma = try XCTUnwrap(
        filmRender["density_curve_gamma"]?.double, file: file, line: line
    )
    digest.halation = try filmRender.halationParams(file: file, line: line)

    let knee = try XCTUnwrap(inputGamutCompress["knee"]?.doubles, file: file, line: line)
    let inputSpec = InputGamutCompressSpec(
        active: try XCTUnwrap(inputGamutCompress["active"]?.bool, file: file, line: line),
        algorithm: try XCTUnwrap(
            inputGamutCompress["algorithm"]?.string, file: file, line: line
        ),
        knee: ReinhardKnee(threshold: knee[0], limit: knee[1], power: knee[2])
    )
    let outputKnee = try XCTUnwrap(outputGamutCompress["knee"]?.doubles, file: file, line: line)
    let lightness = outputGamutCompress["lightness_compression"]?.doubles
    let outputSpec = OutputGamutCompressSpec(
        algorithm: try XCTUnwrap(
            outputGamutCompress["algorithm"]?.string, file: file, line: line
        ),
        knee: ReinhardKnee(threshold: outputKnee[0], limit: outputKnee[1], power: outputKnee[2]),
        lightnessCompression: lightness.map {
            ReinhardKnee(threshold: $0[0], limit: $0[1], power: $0[2])
        }
    )

    return PipelineParams(
        film: film,
        print: printProfile,
        camera: CameraParams(
            exposureCompensationEV: try XCTUnwrap(
                camera["exposure_compensation_ev"]?.double, file: file, line: line
            ),
            autoExposure: try XCTUnwrap(
                camera["auto_exposure"]?.bool, file: file, line: line
            ),
            // Older fixtures predate this field and use the upstream default.
            autoExposureMethod: camera["auto_exposure_method"]?.string ?? "center_weighted",
            lensBlurUM: try XCTUnwrap(
                camera["lens_blur_um"]?.double, file: file, line: line
            ),
            filmFormatMM: try XCTUnwrap(
                camera["film_format_mm"]?.double, file: file, line: line
            ),
            diffusionFilter: try camera.diffusionFilterParams(file: file, line: line)
        ),
        filmRender: FilmRenderParams(
            dirCouplers: digest.dirCouplers,
            densityCurveGamma: digest.densityCurveGamma,
            grain: try filmRender.grainParams(file: file, line: line),
            halation: digest.halation
        ),
        printRender: PrintRenderParams(
            glare: try XCTUnwrap(params["print_render"], file: file, line: line)
                .glareParams(file: file, line: line)
        ),
        enlarger: EnlargerParams(
            illuminant: try XCTUnwrap(
                enlarger["illuminant"]?.string, file: file, line: line
            ),
            printExposure: try XCTUnwrap(
                enlarger["print_exposure"]?.double, file: file, line: line
            ),
            printExposureCompensation: try XCTUnwrap(
                enlarger["print_exposure_compensation"]?.bool, file: file, line: line
            ),
            normalizePrintExposure: try XCTUnwrap(
                enlarger["normalize_print_exposure"]?.bool, file: file, line: line
            ),
            yFilterShift: try XCTUnwrap(
                enlarger["y_filter_shift"]?.double, file: file, line: line
            ),
            mFilterShift: try XCTUnwrap(
                enlarger["m_filter_shift"]?.double, file: file, line: line
            ),
            yFilterNeutral: try XCTUnwrap(
                enlarger["y_filter_neutral"]?.double, file: file, line: line
            ),
            mFilterNeutral: try XCTUnwrap(
                enlarger["m_filter_neutral"]?.double, file: file, line: line
            ),
            cFilterNeutral: try XCTUnwrap(
                enlarger["c_filter_neutral"]?.double, file: file, line: line
            ),
            lensBlur: try XCTUnwrap(
                enlarger["lens_blur"]?.double, file: file, line: line
            ),
            diffusionFilter: try enlarger.diffusionFilterParams(file: file, line: line),
            preflashExposure: try XCTUnwrap(
                enlarger["preflash_exposure"]?.double, file: file, line: line
            ),
            preflashYFilterShift: try XCTUnwrap(
                enlarger["preflash_y_filter_shift"]?.double, file: file, line: line
            ),
            preflashMFilterShift: try XCTUnwrap(
                enlarger["preflash_m_filter_shift"]?.double, file: file, line: line
            )
        ),
        scanner: ScannerParams(
            lensBlur: try XCTUnwrap(scanner["lens_blur"]?.double, file: file, line: line),
            whiteCorrection: try XCTUnwrap(
                scanner["white_correction"]?.bool, file: file, line: line
            ),
            blackCorrection: try XCTUnwrap(
                scanner["black_correction"]?.bool, file: file, line: line
            ),
            whiteLevel: try XCTUnwrap(
                scanner["white_level"]?.double, file: file, line: line
            ),
            blackLevel: try XCTUnwrap(
                scanner["black_level"]?.double, file: file, line: line
            ),
            unsharpMaskSigma: unsharp[0],
            unsharpMaskAmount: unsharp[1]
        ),
        io: IOParams(
            inputColorSpace: inputColourSpace,
            inputCCTFDecoding: try XCTUnwrap(
                io["input_cctf_decoding"]?.bool, file: file, line: line
            ),
            outputColorSpace: outputColourSpace,
            outputCCTFEncoding: try XCTUnwrap(
                io["output_cctf_encoding"]?.bool, file: file, line: line
            ),
            inputGamutCompress: inputSpec,
            outputGamutCompress: outputSpec,
            scanFilm: try XCTUnwrap(io["scan_film"]?.bool, file: file, line: line)
        )
    )
}
