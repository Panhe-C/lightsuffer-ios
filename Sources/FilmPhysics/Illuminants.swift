//
//  Illuminants.swift
//  light suffer胶片 — iOS app
//
//  The standard illuminants the pipeline uses: the enlarger lamp (TH-KG3),
//  the film reference illuminant (D55), the print viewing illuminant (D50)
//  and the sRGB white point (D65).
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The standard illuminants of the pipeline.
///
/// Upstream reference: `spektrafilm.model.illuminants.standard_illuminant`.
///
/// The spectra are bundled as a resource (packed by `tools/pack_resources.py`)
/// so that the port reproduces the upstream tables bit for bit; the
/// chromaticity of an illuminant is derived from its spectrum and the CIE
/// 1931 2° colour matching functions, exactly like
/// `spektrafilm.utils.spectral_upsampling._illuminant_to_xy` does.
public enum Illuminants {

    /// The cached illuminant spectra.
    public static func cached() -> [String: [Double]] {
        cachedStorage.illuminants
    }

    /// The cached CIE 1931 2° colour matching functions.
    public static func cachedColourMatchingFunctions() -> [[Double]] {
        cachedStorage.colourMatchingFunctions
    }

    /// The spectrum of an illuminant.
    ///
    /// - Parameter label: the label of the illuminant (`"TH-KG3"`, `"D55"`,
    ///   `"D50"`, `"D65"`).
    public static func spectrum(of label: String) -> [Double] {
        cached()[label] ?? []
    }

    /// The chromaticity of an illuminant.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.spectral_upsampling._illuminant_to_xy`.
    ///
    /// ```
    /// xyz[i] = Σ_l illuminant[l] · CMF[l, i]
    /// xy     = (X, Y) / (X + Y + Z)
    /// ```
    ///
    /// - Parameters:
    ///   - label: the label of the illuminant.
    ///   - illuminants: the illuminant spectra.
    ///   - colourMatchingFunctions: the CIE 1931 2° colour matching functions.
    public static func chromaticity(
        of label: String,
        illuminants: [String: [Double]],
        colourMatchingFunctions: [[Double]]
    ) -> Chromaticity {
        let spectrum = illuminants[label] ?? []
        guard !spectrum.isEmpty, !colourMatchingFunctions.isEmpty else {
            return Chromaticity(x: 0.3127, y: 0.329)
        }
        var xyz = [Double](repeating: 0, count: 3)
        let count = min(spectrum.count, colourMatchingFunctions.count)
        for wavelength in 0..<count {
            let value = spectrum[wavelength]
            for component in 0..<3 {
                xyz[component] += value * colourMatchingFunctions[wavelength][component]
            }
        }
        let total = xyz[0] + xyz[1] + xyz[2]
        guard total != 0 else { return Chromaticity(x: 0.3127, y: 0.329) }
        return Chromaticity(x: xyz[0] / total, y: xyz[1] / total)
    }

    /// The chromaticity of an illuminant, using the bundled resources.
    public static func chromaticity(of label: String) -> Chromaticity {
        chromaticity(
            of: label,
            illuminants: cached(),
            colourMatchingFunctions: cachedColourMatchingFunctions()
        )
    }

    /// The lazily loaded resources.
    private static let cachedStorage = Storage()

    /// The lazily loaded illuminant spectra and colour matching functions.
    private final class Storage {
        let illuminants: [String: [Double]]
        let colourMatchingFunctions: [[Double]]

        init() {
            illuminants = (try? Resources.illuminants()) ?? [:]
            colourMatchingFunctions = (try? Resources.colourMatchingFunctions()) ?? []
        }
    }
}
