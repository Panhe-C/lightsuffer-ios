//
//  Scanning.swift
//  light suffer胶片 — iOS app
//
//  The scanning stage: the developed print is scanned and converted into the
//  output RGB image.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The scanning stage of the pipeline.
public enum Scanning {

    /// Converts the CMY densities of the print into log10 XYZ.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.scanning.ScanningStage._return_callable_cmy_to_log_xyz`.
    ///
    /// ```
    /// density_spectral = print_channel_density · cmy_density + print_base_density
    /// light            = 10 ** (-density_spectral) · scan_illuminant
    /// xyz              = light · CMFs / normalisation
    /// log_xyz          = log10(max(xyz, 0) + 1e-10)
    /// ```
    ///
    /// - Parameters:
    ///   - cmy: the densities of the print, three values per pixel.
    ///   - channelDensity: the spectral density of the paper, `[wavelength][channel]`.
    ///   - baseDensity: the base density of the paper, one value per wavelength.
    ///   - scanIlluminant: the illuminant of the scanner, one value per wavelength.
    ///   - colourMatchingFunctions: the CIE 1931 2° CMFs, `[wavelength][XYZ]`.
    ///   - normalization: the normalisation of the illuminant, i.e. the sum of
    ///     the illuminant weighted by the y-bar CMF.
    /// - Returns: the log10 tristimulus values, three values per pixel.
    public static func cmyToLogXYZ(
        cmy: [Double],
        channelDensity: [[Double]],
        baseDensity: [Double],
        scanIlluminant: [Double],
        colourMatchingFunctions: [[Double]],
        normalization: Double
    ) -> [Double] {
        let wavelengths = min(
            min(channelDensity.count, scanIlluminant.count), colourMatchingFunctions.count
        )
        let densitySpectral = Spectral.densitySpectral(
            channelDensity: channelDensity,
            densityCMY: cmy,
            baseDensity: baseDensity
        )
        let light = Spectral.densityToLight(
            density: densitySpectral, wavelengths: wavelengths, light: scanIlluminant
        )
        let pixels = cmy.count / 3
        var xyz = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for component in 0..<3 {
                var total = 0.0
                for wavelength in 0..<wavelengths {
                    total += light[pixel * wavelengths + wavelength]
                        * colourMatchingFunctions[wavelength][component]
                }
                xyz[pixel * 3 + component] = total / normalization
            }
        }
        return Printing.log10Floor(xyz)
    }

    /// Scans the print and returns the output RGB image.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.stages.scanning.ScanningStage.scan` and
    /// `ScanningStage._density_to_rgb`.
    ///
    /// The blur, the unsharp mask, the glare and the output gamut compression
    /// are not part of slice 1.
    ///
    /// - Parameters:
    ///   - cmy: the densities of the print, three values per pixel.
    ///   - printProfile: the profile of the paper.
    ///   - scanIlluminant: the illuminant of the scanner.
    ///   - normalization: the normalisation of the illuminant.
    ///   - colourMatchingFunctions: the CIE 1931 2° CMFs.
    ///   - xyzToRGB: the XYZ to output RGB matrix. **Row `i` is the RGB
    ///     response to the `i`-th XYZ basis vector**, i.e. the conversion is
    ///     `rgb = xyz · matrix`.
    ///   - srgbToSRGB: the matrix the output transfer function applies before
    ///     the encoding, `rgb = matrix · rgb`.
    ///   - colorReference: the black / white reference of the print.
    ///   - outputGamutCompress: the output gamut compression (`nil` or the
    ///     `"off"` algorithm leaves the values untouched).
    /// - Returns: the encoded output RGB image, three values per pixel.
    public static func scan(
        cmy: [Double],
        printProfile: Profile,
        scanIlluminant: [Double],
        normalization: Double,
        colourMatchingFunctions: [[Double]],
        xyzToRGB: [[Double]],
        srgbToSRGB: [[Double]],
        colorReference: ColorReference = ColorReference(),
        outputGamutCompress: OutputGamutCompressSpec? = nil
    ) -> [Double] {
        let logXYZ = cmyToLogXYZ(
            cmy: cmy,
            channelDensity: printProfile.data.channelDensity,
            baseDensity: printProfile.data.baseDensity,
            scanIlluminant: scanIlluminant,
            colourMatchingFunctions: colourMatchingFunctions,
            normalization: normalization
        )
        var xyz = logXYZ.map { pow(10.0, $0) }
        xyz = colorReference.xyzCorrection(xyz: xyz)

        // XYZ -> RGB. The matrix stores the RGB response of every XYZ basis
        // vector in its rows, so the conversion is a row vector product.
        let pixels = xyz.count / 3
        var rgb = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                var total = 0.0
                for component in 0..<3 {
                    total += xyz[pixel * 3 + component] * xyzToRGB[component][channel]
                }
                rgb[pixel * 3 + channel] = total
            }
        }

        // The output gamut compression, applied to the linear RGB values
        // before the output transfer function.
        //
        // Upstream reference:
        // `spektrafilm.runtime.stages.scanning.ScanningStage._density_to_rgb`
        // and `spektrafilm.utils.gamut_compression.compress_rgb`.
        if let outputGamutCompress, outputGamutCompress.active {
            rgb = GamutCompression.compressRGB(
                rgb,
                spec: outputGamutCompress,
                outputColourSpace: .sRGB
            )
        }

        // The output transfer function first applies the sRGB to sRGB matrix
        // (a Bradford chromatic adaptation that is numerically the identity)
        // and then the sRGB encoding.
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                var total = 0.0
                for component in 0..<3 {
                    total += srgbToSRGB[component][channel] * rgb[pixel * 3 + component]
                }
                rgb[pixel * 3 + channel] = Colour.sRGBEncode(total)
            }
        }
        return rgb
    }
}
