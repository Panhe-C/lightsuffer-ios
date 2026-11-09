//
//  ColorFilters.swift
//  light suffer胶片 — iOS app
//
//  The colour filters of the enlarger: the synthetic CMY dichroic filters
//  the upstream engine uses by default.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The colour filters of the enlarger.
///
/// Upstream reference: `spektrafilm.model.color_filters`.
public enum ColorFilters {

    /// The synthetic CMY dichroic filters of the enlarger.
    ///
    /// Upstream reference:
    /// `spektrafilm.model.color_filters.create_combined_dichroic_filter` and
    /// `spektrafilm.model.color_filters.DichroicFilters.create_custom_filters`.
    ///
    /// ```
    /// Y = erf((λ - 516) / 12)
    /// M = -erf((λ - 500) / 8)   for λ ≤ 550,  erf((λ - 610) / 8) otherwise
    /// C = -erf((λ - 607) / 8)
    /// filter = value / 2 + 0.5
    /// ```
    ///
    /// - Parameter wavelengths: the spectral sampling.
    /// - Returns: the transmittance of the three filters, `[wavelength][CMY]`.
    public static func customDichroicFilters(wavelengths: [Double]) -> [[Double]] {
        let edges = [516.0, 500.0, 610.0, 607.0]
        let transitions = [12.0, 8.0, 8.0, 8.0]
        return wavelengths.map { wavelength in
            let yellow = Numerics.erf((wavelength - edges[0]) / transitions[0])
            let magenta = wavelength <= 550
                ? -Numerics.erf((wavelength - edges[1]) / transitions[1])
                : Numerics.erf((wavelength - edges[2]) / transitions[2])
            let cyan = -Numerics.erf((wavelength - edges[3]) / transitions[3])
            return [
                cyan / 2.0 + 0.5,
                magenta / 2.0 + 0.5,
                yellow / 2.0 + 0.5,
            ]
        }
    }

    /// The bundled synthetic CMY dichroic filters.
    public static func bundledDichroicFilters() -> [[Double]] {
        customDichroicFilters(wavelengths: FilmPhysics.wavelengths)
    }
}
