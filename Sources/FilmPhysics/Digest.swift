//
//  Digest.swift
//  light suffer胶片 — iOS app
//
//  The digest of the runtime parameters: the stock specific overrides the
//  upstream engine applies before the pipeline runs.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The digested film rendering parameters.
///
/// Upstream reference: `spektrafilm.runtime.params_builder._apply_film_specifics`
/// and `spektrafilm.runtime.params_builder._apply_halation_preset`.
public struct FilmRenderDigest: Equatable, Sendable {
    /// The DIR coupler parameters, with the stock specific inhibition values.
    public var dirCouplers: DirCouplersParams
    /// The sigma of the first halation bounce, per channel.
    public var halationFirstSigmaUM: [Double]
    /// The strength of the halation, per channel.
    public var halationStrength: [Double]
    /// The gamma factor of the density curves.
    public var densityCurveGamma: Double

    public init(
        dirCouplers: DirCouplersParams = DirCouplersParams(),
        halationFirstSigmaUM: [Double] = [65, 65, 65],
        halationStrength: [Double] = [0.05, 0.015, 0],
        densityCurveGamma: Double = 1.0
    ) {
        self.dirCouplers = dirCouplers
        self.halationFirstSigmaUM = halationFirstSigmaUM
        self.halationStrength = halationStrength
        self.densityCurveGamma = densityCurveGamma
    }
}

/// The digest of the runtime parameters.
///
/// Upstream reference: `spektrafilm.runtime.params_builder.digest_params`.
public enum Digest {

    /// The halation presets, keyed by the use and the antihalation tag of the
    /// stock.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_builder._HALATION_PRESETS`.
    private static let halationPresets: [String: (sigma: [Double], strength: [Double])] = [
        "still|strong": ([65, 65, 65], [0.015, 0.005, 0]),
        "still|weak": ([65, 65, 65], [0.08, 0.02, 0]),
        "still|no": ([65, 65, 65], [0.3, 0.1, 0.015]),
        "cine|strong": ([50, 50, 50], [0.015, 0.005, 0]),
        "cine|weak": ([50, 50, 50], [0.08, 0.02, 0]),
        "cine|no": ([50, 50, 50], [0.3, 0.1, 0.015]),
    ]

    /// Applies the stock specific film rendering parameters.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder._apply_film_specifics`.
    ///
    /// The DIR coupler inhibition values depend on the polarity of the stock
    /// (a positive emulsion develops in the silver stage and has a much
    /// weaker coupling), and the halation baseline depends on the use and the
    /// anti-halation layer of the stock.
    ///
    /// - Parameters:
    ///   - profile: the film profile.
    ///   - base: the parameters before the digest.
    /// - Returns: the digested parameters.
    public static func filmRender(
        for profile: Profile,
        base: FilmRenderDigest = FilmRenderDigest()
    ) -> FilmRenderDigest {
        var digest = base

        if profile.info.type == .positive {
            digest.dirCouplers.gammaSamelayerRGB = [0.12, 0.08, 0.06]
            digest.dirCouplers.gammaInterlayerRToGB = [0.12, 0.06]
            digest.dirCouplers.gammaInterlayerGToRB = [0.08, 0.06]
            digest.dirCouplers.gammaInterlayerBToRG = [0.06, 0.06]
        }
        if profile.info.type == .negative {
            digest.dirCouplers.gammaSamelayerRGB = [0.336, 0.319, 0.273]
            digest.dirCouplers.gammaInterlayerRToGB = [0.353, 0.302]
            digest.dirCouplers.gammaInterlayerGToRB = [0.154, 0.353]
            digest.dirCouplers.gammaInterlayerBToRG = [0.168, 0.226]
        }

        // Stock specific overrides.
        switch profile.info.stock {
        case "fujifilm_velvia_100":
            digest.dirCouplers.gammaSamelayerRGB = [0.108, 0.072, 0.054]
            digest.dirCouplers.gammaInterlayerRToGB = [0.108, 0.054]
            digest.dirCouplers.gammaInterlayerGToRB = [0.072, 0.054]
            digest.dirCouplers.gammaInterlayerBToRG = [0.054, 0.054]
        case "fujifilm_provia_100f":
            digest.dirCouplers.gammaSamelayerRGB = [0.156, 0.104, 0.078]
            digest.dirCouplers.gammaInterlayerRToGB = [0.156, 0.078]
            digest.dirCouplers.gammaInterlayerGToRB = [0.104, 0.078]
            digest.dirCouplers.gammaInterlayerBToRG = [0.078, 0.078]
        default:
            break
        }

        // The halation baseline of the material and of the anti-halation layer.
        if profile.info.support == .film {
            let key = "\(profile.info.use.rawValue)|\(profile.info.antihalation.rawValue)"
            if let preset = halationPresets[key] {
                digest.halationFirstSigmaUM = preset.sigma
                digest.halationStrength = preset.strength
            }
        }
        return digest
    }
}
