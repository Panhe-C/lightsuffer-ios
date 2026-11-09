//
//  Spectral.swift
//  light suffer胶片 — iOS app
//
//  Spectral helpers: the CMY density to spectral density projection and the
//  density to light transmittance conversion.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// Spectral helpers shared by the printing and the scanning stages.
public enum Spectral {

    /// Projects CMY densities onto the spectral density of the emulsion.
    ///
    /// Upstream reference: `spektrafilm.model.develop.compute_density_spectral`
    ///
    /// ```
    /// density_spectral[i, j, l] = Σ_k density_cmy[i, j, k] · channel_density[l, k]
    ///                           + base_density[l]
    /// ```
    ///
    /// - Parameters:
    ///   - channelDensity: the spectral density of the image forming layer,
    ///     `[wavelength][channel]`.
    ///   - densityCMY: the CMY densities, three interleaved values per pixel.
    ///   - baseDensity: the optional base (fog) density, one value per wavelength.
    /// - Returns: the spectral densities, `wavelength` interleaved values per pixel.
    public static func densitySpectral(
        channelDensity: [[Double]],
        densityCMY: [Double],
        baseDensity: [Double]?
    ) -> [Double] {
        let wavelengths = channelDensity.count
        let pixels = densityCMY.count / 3
        var spectral = [Double](repeating: 0, count: pixels * wavelengths)
        for pixel in 0..<pixels {
            for wavelength in 0..<wavelengths {
                var total = 0.0
                for channel in 0..<3 {
                    total += densityCMY[pixel * 3 + channel] * channelDensity[wavelength][channel]
                }
                if let baseDensity {
                    total += baseDensity[wavelength]
                }
                spectral[pixel * wavelengths + wavelength] = total
            }
        }
        return spectral
    }

    /// Converts a spectral density into the transmitted light.
    ///
    /// Upstream reference: `spektrafilm.utils.conversions.density_to_light`
    ///
    /// ```
    /// transmitted = 10 ** (-density) · light
    /// ```
    ///
    /// A `NaN` density (the upstream profiles store "no contribution" as
    /// `NaN`) transmits no light at all.
    ///
    /// - Parameters:
    ///   - density: the spectral densities, `wavelength` interleaved values per pixel.
    ///   - wavelengths: the number of wavelength samples per pixel.
    ///   - light: the illuminant spectrum, one value per wavelength (a single
    ///     value is broadcast over the whole spectrum).
    /// - Returns: the transmitted light, `wavelength` interleaved values per pixel.
    public static func densityToLight(
        density: [Double],
        wavelengths: Int,
        light: [Double]
    ) -> [Double] {
        guard !light.isEmpty, wavelengths > 0 else { return [Double](repeating: 0, count: density.count) }
        var transmitted = [Double](repeating: 0, count: density.count)
        for index in 0..<density.count {
            let value = pow(10.0, -density[index]) * light[index % light.count]
            transmitted[index] = value.isNaN ? 0 : value
        }
        return transmitted
    }

    /// Converts the spectral density of a single patch into the transmitted
    /// light of that patch.
    public static func densityToLight(density: [Double], light: [Double]) -> [Double] {
        densityToLight(density: density, wavelengths: density.count, light: light)
    }

    /// Multiplies a per pixel spectral image with a spectral sensitivity
    /// table, i.e. the `contract("ijk, kl->ijl", light, sensitivity)` of the
    /// upstream code.
    ///
    /// - Parameters:
    ///   - light: the spectral light, `wavelength` interleaved values per pixel.
    ///   - wavelengths: the number of wavelength samples.
    ///   - sensitivity: the spectral sensitivity, `[wavelength][channel]`.
    /// - Returns: the channel responses, three interleaved values per pixel.
    public static func contractWithSensitivity(
        light: [Double],
        wavelengths: Int,
        sensitivity: [[Double]]
    ) -> [Double] {
        let pixels = light.count / wavelengths
        var result = [Double](repeating: 0, count: pixels * 3)
        for pixel in 0..<pixels {
            for channel in 0..<3 {
                var total = 0.0
                for wavelength in 0..<wavelengths {
                    total += light[pixel * wavelengths + wavelength]
                        * sensitivity[wavelength][channel]
                }
                result[pixel * 3 + channel] = total
            }
        }
        return result
    }
}
