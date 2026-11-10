//
//  Couplers.swift
//  light suffer胶片 — iOS app
//
//  DIR couplers: the chemical coupling between the emulsion layers that
//  reduces the density of a layer when a neighbouring layer develops.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The parameters of the DIR (developer inhibitor releasing) couplers.
///
/// Upstream: `spektrafilm.runtime.params_schema.DirCouplersParams`.
public struct DirCouplersParams: Equatable, Sendable {
    /// Whether the couplers are active at all.
    public var active: Bool
    /// The overall amount of couplers.
    public var amount: Double
    /// The inhibition factor inside a layer.
    public var inhibitionSamelayer: Double
    /// The inhibition factor between layers.
    public var inhibitionInterlayer: Double
    /// The same layer inhibition, per channel (R, G, B).
    public var gammaSamelayerRGB: [Double]
    /// The inter layer inhibition of the R layer onto the G and B layers.
    public var gammaInterlayerRToGB: [Double]
    /// The inter layer inhibition of the G layer onto the R and B layers.
    public var gammaInterlayerGToRB: [Double]
    /// The inter layer inhibition of the B layer onto the R and G layers.
    public var gammaInterlayerBToRG: [Double]
    /// The spatial diffusion of the inhibitors, in micrometres.
    ///
    /// The inhibitors diffuse into the neighbourhood before they reduce the
    /// development of the surrounding pixels; the diffusion is a spatial
    /// effect and needs the size of a pixel of the negative.
    public var diffusionSizeUM: Double
    /// The spatial diffusion tail size of the inhibitors, in micrometres.
    public var diffusionTailUM: Double
    /// The weight of the exponential diffusion tail.
    public var diffusionTailWeight: Double

    public init(
        active: Bool = true,
        amount: Double = 1.0,
        inhibitionSamelayer: Double = 1.0,
        inhibitionInterlayer: Double = 1.0,
        gammaSamelayerRGB: [Double] = [0.341, 0.324, 0.273],
        gammaInterlayerRToGB: [Double] = [0.355, 0.305],
        gammaInterlayerGToRB: [Double] = [0.154, 0.358],
        gammaInterlayerBToRG: [Double] = [0.171, 0.225],
        diffusionSizeUM: Double = 20.0,
        diffusionTailUM: Double = 200.0,
        diffusionTailWeight: Double = 0.06
    ) {
        self.active = active
        self.amount = amount
        self.inhibitionSamelayer = inhibitionSamelayer
        self.inhibitionInterlayer = inhibitionInterlayer
        self.gammaSamelayerRGB = gammaSamelayerRGB
        self.gammaInterlayerRToGB = gammaInterlayerRToGB
        self.gammaInterlayerGToRB = gammaInterlayerGToRB
        self.gammaInterlayerBToRG = gammaInterlayerBToRG
        self.diffusionSizeUM = diffusionSizeUM
        self.diffusionTailUM = diffusionTailUM
        self.diffusionTailWeight = diffusionTailWeight
    }
}

/// The DIR coupler chemistry.
public enum Couplers {

    // MARK: - Inhibitor matrix

    /// Computes the inhibitor matrix of the DIR couplers.
    ///
    /// Upstream reference: `spektrafilm.model.couplers.compute_dir_couplers_matrix`.
    ///
    /// The row index is the donor layer that releases the inhibitor, the
    /// column index the receiving layer whose development is reduced.
    public static func matrix(_ params: DirCouplersParams) -> [[Double]] {
        var matrix = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        for channel in 0..<3 {
            matrix[channel][channel] = params.gammaSamelayerRGB[channel] * params.inhibitionSamelayer
        }
        matrix[0][1] = params.gammaInterlayerRToGB[0]
        matrix[0][2] = params.gammaInterlayerRToGB[1]
        matrix[1][0] = params.gammaInterlayerGToRB[0]
        matrix[1][2] = params.gammaInterlayerGToRB[1]
        matrix[2][0] = params.gammaInterlayerBToRG[0]
        matrix[2][1] = params.gammaInterlayerBToRG[1]
        for row in 0..<3 {
            for column in 0..<3 where row != column {
                matrix[row][column] *= params.inhibitionInterlayer
            }
        }
        return matrix
    }

    // MARK: - Curves before the couplers

    /// Inverts the DIR coupler effect on the characteristic density curves.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.couplers.compute_density_curves_before_dir_couplers`.
    ///
    /// The couplers increase the contrast of a layer, so the curves that are
    /// measured *after* the couplers have to be de-convolved to obtain the
    /// curves of the bare emulsion.
    ///
    /// - Parameters:
    ///   - densityCurves: the (normalised) density curves, `[sample][channel]`.
    ///   - logExposure: the log exposure axis of the curves.
    ///   - matrix: the inhibitor matrix, scaled by the coupler amount.
    ///   - positive: whether the emulsion is a positive (slide) stock.
    /// - Returns: the corrected density curves, `[sample][channel]`.
    public static func densityCurvesBeforeCouplers(
        densityCurves: [[Double]],
        logExposure: [Double],
        matrix: [[Double]],
        positive: Bool
    ) -> [[Double]] {
        guard !densityCurves.isEmpty else { return [] }
        let channels = densityCurves[0].count
        let samples = densityCurves.count

        // The silver density of the emulsion: for a positive stock the
        // silver density is d_max - d, for a negative stock it is d itself.
        var silver = [[Double]](repeating: [Double](repeating: 0, count: channels), count: samples)
        if positive {
            var maxima = [Double](repeating: -Double.infinity, count: channels)
            for sample in densityCurves {
                for channel in 0..<channels {
                    let value = sample[channel]
                    if !value.isNaN { maxima[channel] = Swift.max(maxima[channel], value) }
                }
            }
            for sample in 0..<samples {
                for channel in 0..<channels {
                    silver[sample][channel] = maxima[channel] - densityCurves[sample][channel]
                }
            }
        } else {
            for sample in 0..<samples {
                for channel in 0..<channels {
                    silver[sample][channel] = densityCurves[sample][channel]
                }
            }
        }

        // The inhibitor amount each sample releases into every channel.
        var amounts = [[Double]](repeating: [Double](repeating: 0, count: channels), count: samples)
        for sample in 0..<samples {
            for receiver in 0..<channels {
                var total = 0.0
                for donor in 0..<channels {
                    total += silver[sample][donor] * matrix[donor][receiver]
                }
                amounts[sample][receiver] = total
            }
        }

        // The de-convolved curves: the exposure axis of every channel is
        // shifted by the released inhibitor amount.
        var corrected = [[Double]](repeating: [Double](repeating: 0, count: channels), count: samples)
        for channel in 0..<channels {
            var shiftedAxis = [Double](repeating: 0, count: samples)
            for sample in 0..<samples {
                shiftedAxis[sample] = logExposure[sample] - amounts[sample][channel]
            }
            var values = [Double](repeating: 0, count: samples)
            for sample in 0..<samples {
                values[sample] = densityCurves[sample][channel]
            }
            var inverted = [Double](repeating: 0, count: samples)
            for sample in 0..<samples {
                inverted[sample] = Numerics.interpolate(
                    x: logExposure[sample], axis: shiftedAxis, values: values
                )
            }
            // The upstream evaluates the positive branch as
            // `-numpy.interp(log_exposure, log_exposure_0, -density_curves)`,
            // which — the interpolation being linear — is the same as
            // `numpy.interp(log_exposure, log_exposure_0, density_curves)`:
            // the sign of the two negations cancels.
            for sample in 0..<samples {
                corrected[sample][channel] = inverted[sample]
            }
        }
        return corrected
    }

    // MARK: - Exposure correction

    /// Computes the exposure correction the released inhibitors cause.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.couplers.compute_exposure_correction_dir_couplers`.
    ///
    /// The inhibitors are released by the layers that develop and they
    /// diffuse into the neighbourhood: the correction term is blurred with
    /// a Gaussian and with an exponential tail before it is subtracted from
    /// the log exposure.
    ///
    /// - Parameters:
    ///   - logRaw: the log exposure of the negative, three values per pixel.
    ///   - densityCMY: the developed densities, three values per pixel.
    ///   - densityMax: the maximum density of every channel.
    ///   - matrix: the inhibitor matrix, scaled by the coupler amount.
    ///   - positive: whether the emulsion is a positive (slide) stock.
    ///   - highExposureCouplersShift: the extra inhibition at high density.
    ///   - width: the width of the image, in pixels (the diffusion needs it).
    ///   - height: the height of the image, in pixels.
    ///   - diffusionSizePixel: the sigma of the Gaussian diffusion of the
    ///     inhibitors, in pixels (zero disables the diffusion).
    ///   - diffusionTailSizePixel: the decay constant of the exponential
    ///     tail of the diffusion, in pixels.
    ///   - diffusionTailWeight: the weight of the exponential tail.
    /// - Returns: the corrected log exposure, three values per pixel.
    public static func exposureCorrection(
        logRaw: [Double],
        densityCMY: [Double],
        densityMax: [Double],
        matrix: [[Double]],
        positive: Bool,
        highExposureCouplersShift: Double = 0.0,
        width: Int = 0,
        height: Int = 0,
        diffusionSizePixel: Double = 0,
        diffusionTailSizePixel: Double = 0,
        diffusionTailWeight: Double = 0
    ) -> [Double] {
        let pixels = logRaw.count / 3
        var correction = [Double](repeating: 0, count: logRaw.count)
        for pixel in 0..<pixels {
            for receiver in 0..<3 {
                var amount = 0.0
                for donor in 0..<3 {
                    var silver = densityCMY[pixel * 3 + donor]
                    if positive {
                        silver = densityMax[donor] - silver
                    }
                    if highExposureCouplersShift != 0 {
                        silver += highExposureCouplersShift * silver * silver
                    }
                    amount += silver * matrix[donor][receiver]
                }
                correction[pixel * 3 + receiver] = amount
            }
        }

        // The spatial diffusion of the inhibitors.
        if diffusionSizePixel > 0, width > 0, height > 0 {
            let gaussian = SpatialEffects.gaussianFilter(
                rgb: correction, width: width, height: height, sigma: diffusionSizePixel
            )
            let tail = SpatialEffects.exponentialFilter(
                rgb: correction,
                width: width,
                height: height,
                decayConstant: [diffusionTailSizePixel]
            )
            for index in 0..<correction.count {
                correction[index] = (1.0 - diffusionTailWeight) * gaussian[index]
                    + diffusionTailWeight * tail[index]
            }
        }

        var corrected = [Double](repeating: 0, count: logRaw.count)
        for index in 0..<logRaw.count {
            corrected[index] = logRaw[index] - correction[index]
        }
        return corrected
    }
}
