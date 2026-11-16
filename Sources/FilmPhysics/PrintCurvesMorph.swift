// Port of spektrafilm.utils.morph_curves (s023), upstream commit 3bb2c2d.
// https://github.com/andreavolpato/spektrafilm
// This file is part of a GPLv3 licensed project; see LICENSE.

import Foundation

/// The coupled-gamma print chemistry controls of spektrafilm s023.
public struct PrintCurvesMorphParams: Equatable, Sendable {
    public var active: Bool
    public var gammaFactor: Double
    public var gammaFactorFast: Double
    public var gammaFactorSlow: Double
    public var gammaFactorRed: Double
    public var gammaFactorGreen: Double
    public var gammaFactorBlue: Double
    public var developerExhaustion: Double

    public init(
        active: Bool = true,
        gammaFactor: Double = 1,
        gammaFactorFast: Double = 1,
        gammaFactorSlow: Double = 1,
        gammaFactorRed: Double = 1,
        gammaFactorGreen: Double = 1,
        gammaFactorBlue: Double = 1,
        developerExhaustion: Double = 0
    ) {
        self.active = active
        self.gammaFactor = gammaFactor
        self.gammaFactorFast = gammaFactorFast
        self.gammaFactorSlow = gammaFactorSlow
        self.gammaFactorRed = gammaFactorRed
        self.gammaFactorGreen = gammaFactorGreen
        self.gammaFactorBlue = gammaFactorBlue
        self.developerExhaustion = developerExhaustion
    }
}

/// CPU curve preparation shared by the reference pipeline and Metal plans.
/// Upstream: `spektrafilm.utils.morph_curves.apply_print_curves_morph`.
public enum PrintCurvesMorph {
    private static let sigmaFloor = 0.05
    private static let gumbelLocation = -log(log(2.0))
    private static let gumbelWidth = 0.5 * log(2.0) * sqrt(2.0 * Double.pi)

    public static func evaluate(
        logExposure: [Double],
        model: DensityCurvesModel,
        params: PrintCurvesMorphParams,
        profileType: ProfileType
    ) throws -> [[Double]] {
        guard params.active else {
            return DensityCurves.evaluateFittedDensity(
                logExposure: logExposure, model: model, profileType: profileType
            )
        }
        let gammaValues = [
            params.gammaFactor, params.gammaFactorFast, params.gammaFactorSlow,
            params.gammaFactorRed, params.gammaFactorGreen, params.gammaFactorBlue,
        ]
        guard gammaValues.allSatisfy({ $0.isFinite && $0 > 0 }),
              params.developerExhaustion.isFinite,
              (0...1).contains(params.developerExhaustion) else {
            throw PipelineError.invalidInputs(
                "print chemistry requires finite positive gamma factors and exhaustion in [0, 1]"
            )
        }
        guard model.nChannels == 3, model.amplitudes.count == 3, model.sigmas.count == 3,
              model.centers.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }),
              model.amplitudes.allSatisfy({
                  $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 >= 0 }
              }),
              model.sigmas.allSatisfy({
                  $0.count == 3 && $0.allSatisfy { $0.isFinite && $0 > 0 }
              }) else {
            throw PipelineError.invalidInputs(
                "print chemistry requires a fitted three-channel, three-layer density model"
            )
        }

        let channelGammas = [params.gammaFactorRed, params.gammaFactorGreen, params.gammaFactorBlue]
        var curves = [[Double]](
            repeating: [Double](repeating: 0, count: 3), count: logExposure.count
        )
        for channel in 0..<3 {
            var centers = model.centers[channel]
            var sigmas = model.sigmas[channel]
            let amplitudes = model.amplitudes[channel]
            // Grain speed follows the threshold, regardless of emulsion polarity.
            let speedOrder = centers.indices.sorted { centers[$0] < centers[$1] }
            for (rank, layer) in speedOrder.enumerated() {
                let bandGamma = rank == 0 ? params.gammaFactorFast : params.gammaFactorSlow
                let gamma = params.gammaFactor * channelGammas[channel] * bandGamma
                guard gamma.isFinite, gamma > 0 else {
                    throw PipelineError.invalidInputs("the effective print chemistry gamma is invalid")
                }
                centers[layer] /= gamma
                sigmas[layer] = max(sigmas[layer] / gamma, sigmaFloor)
                guard centers[layer].isFinite, sigmas[layer].isFinite else {
                    throw PipelineError.invalidInputs("the morphed print density model is not finite")
                }
            }
            let offset = exhaustionOffset(
                centers: centers, amplitudes: amplitudes, sigmas: sigmas,
                profileType: profileType, mix: params.developerExhaustion
            )
            centers = centers.map { $0 + offset }
            for (sample, exposure) in logExposure.enumerated() {
                curves[sample][channel] = density(
                    exposure: exposure, centers: centers, amplitudes: amplitudes,
                    sigmas: sigmas, profileType: profileType, mix: params.developerExhaustion
                )
            }
        }
        return curves
    }

    private static func density(
        exposure: Double, centers: [Double], amplitudes: [Double], sigmas: [Double],
        profileType: ProfileType, mix: Double
    ) -> Double {
        var total = 0.0
        for layer in centers.indices {
            let z = (exposure - centers[layer]) / sigmas[layer]
            let signed = profileType == .positive ? -z : z
            var cdf = Numerics.normalCDF(signed)
            if mix > 0 {
                let gumbel = exp(-exp(-(signed / gumbelWidth + gumbelLocation)))
                cdf = (1 - mix) * cdf + mix * gumbel
            }
            total += amplitudes[layer] * cdf
        }
        return total
    }

    private static func exhaustionOffset(
        centers: [Double], amplitudes: [Double], sigmas: [Double],
        profileType: ProfileType, mix: Double
    ) -> Double {
        // Match upstream np.allclose(mix, 0) and its zero-residual tolerance.
        guard mix > 1e-8 else { return 0 }
        let target = density(
            exposure: 0, centers: centers, amplitudes: amplitudes, sigmas: sigmas,
            profileType: profileType, mix: 0
        )
        func residual(_ offset: Double) -> Double {
            density(
                exposure: 0, centers: centers.map { $0 + offset },
                amplitudes: amplitudes, sigmas: sigmas, profileType: profileType, mix: mix
            ) - target
        }
        guard abs(residual(0)) > 1e-12 else { return 0 }
        var low = -0.25
        var high = 0.25
        for _ in 0..<12 {
            var lowResidual = residual(low)
            let highResidual = residual(high)
            if lowResidual == 0 { return low }
            if highResidual == 0 { return high }
            if (lowResidual < 0) != (highResidual < 0) {
                // This monotone scalar root is solved once per channel, not per pixel.
                while high - low > 1e-10 {
                    let middle = (low + high) * 0.5
                    let middleResidual = residual(middle)
                    if middleResidual == 0 { return middle }
                    if (middleResidual < 0) == (lowResidual < 0) {
                        low = middle
                        lowResidual = middleResidual
                    } else {
                        high = middle
                    }
                }
                return (low + high) * 0.5
            }
            low *= 2
            high *= 2
        }
        return 0 // Upstream leaves the centers unchanged if no bracket is found.
    }
}
