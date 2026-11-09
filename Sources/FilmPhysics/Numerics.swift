//
//  Numerics.swift
//  light suffer胶片 — iOS app
//
//  Small numeric helpers shared by the ported pipeline stages.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// Numeric helpers that reproduce the upstream (NumPy / SciPy) semantics
/// exactly, so that the ported stages stay bit-comparable with the
/// reference engine.
public enum Numerics {

    // MARK: - Interpolation

    /// One dimensional linear interpolation with `numpy.interp` semantics.
    ///
    /// Upstream reference: `numpy.interp` as used by
    /// `spektrafilm.model.couplers.compute_density_curves_before_dir_couplers`.
    ///
    /// * `axis` must be strictly ascending; values outside the axis are
    ///   clamped to the first / last value (`numpy.interp` behaviour).
    /// * A value that lands exactly on an axis knot returns the
    ///   corresponding value verbatim.
    /// * A `NaN` query returns `NaN`.
    ///
    /// - Parameters:
    ///   - x: the value to interpolate.
    ///   - axis: the (ascending) sample positions.
    ///   - values: the sample values, one per axis entry.
    public static func interpolate(x: Double, axis: [Double], values: [Double]) -> Double {
        guard axis.count == values.count, !axis.isEmpty else { return .nan }
        if x.isNaN { return .nan }
        if x <= axis[0] { return values[0] }
        let last = axis.count - 1
        if x >= axis[last] { return values[last] }

        // Binary search for the last index whose axis value is <= x.
        var low = 0
        var high = last
        while high - low > 1 {
            let mid = (low + high) / 2
            if axis[mid] <= x {
                low = mid
            } else {
                high = mid
            }
        }
        if axis[low] == x { return values[low] }
        let span = axis[high] - axis[low]
        let t = (x - axis[low]) / span
        return values[low] + t * (values[high] - values[low])
    }

    /// Interpolates every entry of `queries` with `numpy.interp` semantics.
    public static func interpolate(
        queries: [Double],
        axis: [Double],
        values: [Double]
    ) -> [Double] {
        queries.map { interpolate(x: $0, axis: axis, values: values) }
    }

    /// Index of the first element of `axis` that is strictly greater than `x`.
    ///
    /// This is `numpy.searchsorted(axis, x, side="right")`, including its
    /// treatment of `NaN` (which sorts after every number).
    ///
    /// Upstream reference: `spektrafilm.utils.fast_interp.fast_interp`.
    public static func searchSortedRight(_ axis: [Double], _ x: Double) -> Int {
        var low = 0
        var high = axis.count
        while low < high {
            let mid = (low + high) / 2
            if axis[mid] <= x {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    // MARK: - Statistics

    /// The geometric mean of the given values.
    ///
    /// Upstream reference: `numpy.exp(numpy.mean(numpy.log(values)))` as used
    /// by `spektrafilm.runtime.stages.printing._exposure_factor`.
    ///
    /// The values are expected to be strictly positive (the upstream code
    /// clamps them with `numpy.fmax(raw, 1e-10)` beforehand).
    public static func geometricMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        var sum = 0.0
        for value in values {
            sum += log(value)
        }
        return exp(sum / Double(values.count))
    }

    /// The minimum of the given values, ignoring `NaN` (`numpy.nanmin`).
    public static func nanMin(_ values: [Double]) -> Double {
        var result = Double.infinity
        for value in values where !value.isNaN {
            result = Swift.min(result, value)
        }
        return result
    }

    /// The maximum of the given values, ignoring `NaN` (`numpy.nanmax`).
    public static func nanMax(_ values: [Double]) -> Double {
        var result = -Double.infinity
        for value in values where !value.isNaN {
            result = Swift.max(result, value)
        }
        return result
    }

    /// The arithmetic mean of the given values, ignoring `NaN`
    /// (`numpy.nanmean`).
    public static func nanMean(_ values: [Double]) -> Double {
        var sum = 0.0
        var count = 0
        for value in values where !value.isNaN {
            sum += value
            count += 1
        }
        guard count > 0 else { return .nan }
        return sum / Double(count)
    }

    /// Replaces `NaN` with `0` and the infinities with the largest finite
    /// double (`numpy.nan_to_num` with the default arguments).
    ///
    /// Upstream reference: `spektrafilm.runtime.stages.filming._rgb_to_film_raw`
    /// and `spektrafilm.runtime.stages.printing._film_cmy_to_print_log_raw`.
    public static func nanToNum(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        if value == .infinity { return Double.greatestFiniteMagnitude }
        if value == -.infinity { return -Double.greatestFiniteMagnitude }
        return value
    }

    /// Vectorised `nanToNum`.
    public static func nanToNum(_ values: [Double]) -> [Double] {
        values.map(nanToNum)
    }

    // MARK: - Normal distribution

    /// The cumulative distribution function of the standard normal
    /// distribution (`scipy.stats.norm.cdf`).
    ///
    /// The implementation evaluates `0.5 * erfc(-z / sqrt(2))` through the
    /// regularised incomplete gamma function, which is accurate to about
    /// 1e-15 over the whole range — the same accuracy the upstream SciPy
    /// implementation has.
    ///
    /// Upstream reference: `scipy.stats.norm.cdf` as used by
    /// `spektrafilm.utils.morph_curves._layer_cdf`.
    public static func normalCDF(_ z: Double) -> Double {
        if z.isNaN { return .nan }
        if z == .infinity { return 1 }
        if z == -.infinity { return 0 }
        return 0.5 * erfc(-z / 1.4142135623730951)  // sqrt(2)
    }

    /// The complementary error function `erfc(x)`.
    ///
    /// Implemented through the regularised lower incomplete gamma function
    /// `P(1/2, x^2)`, using the series expansion for small arguments and the
    /// continued fraction for large ones.
    public static func erfc(_ x: Double) -> Double {
        if x.isNaN { return .nan }
        if x == .infinity { return 0 }
        if x == -.infinity { return 2 }
        if x < 0 { return 2 - erfc(-x) }
        let t = x * x
        if t < 1.5 {
            return 1 - incompleteGammaP(0.5, t)
        }
        return incompleteGammaQ(0.5, t)
    }

    /// The error function `erf(x)`.
    public static func erf(_ x: Double) -> Double {
        if x.isNaN { return .nan }
        if x == .infinity { return 1 }
        if x == -.infinity { return -1 }
        return x < 0 ? -erf(-x) : 1 - erfc(x)
    }

    /// The regularised lower incomplete gamma function `P(a, x)`.
    ///
    /// Only `a = 0.5` is needed by `erfc`, but the implementation is generic.
    /// It follows the classic series / continued fraction decomposition.
    private static func incompleteGammaP(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x < a + 1 {
            return gammaSeries(a, x)
        }
        return 1 - incompleteGammaQ(a, x)
    }

    /// The regularised upper incomplete gamma function `Q(a, x) = 1 - P(a, x)`.
    private static func incompleteGammaQ(_ a: Double, _ x: Double) -> Double {
        if x <= 0 { return 1 }
        if x < a + 1 {
            return 1 - gammaSeries(a, x)
        }
        return gammaContinuedFraction(a, x)
    }

    /// The series expansion of `P(a, x)`, used for `x < a + 1`.
    private static func gammaSeries(_ a: Double, _ x: Double) -> Double {
        let epsilon = 3e-16
        var ap = a
        var sum = 1.0 / a
        var delta = sum
        var iterations = 0
        while iterations < 1000 {
            ap += 1
            delta *= x / ap
            sum += delta
            if abs(delta) < abs(sum) * epsilon { break }
            iterations += 1
        }
        return sum * exp(-x + a * log(x) - logGamma(a))
    }

    /// The continued fraction expansion of `Q(a, x)`, used for `x >= a + 1`.
    private static func gammaContinuedFraction(_ a: Double, _ x: Double) -> Double {
        let epsilon = 3e-16
        let tiny = 1e-300
        var b = x + 1 - a
        var c = 1.0 / tiny
        var d = 1.0 / b
        var h = d
        var iterations = 0
        while iterations < 1000 {
            let i = Double(iterations + 1)
            let an = -i * (i - a)
            b += 2
            d = an * d + b
            if abs(d) < tiny { d = tiny }
            c = b + an / c
            if abs(c) < tiny { c = tiny }
            d = 1.0 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
            iterations += 1
        }
        return exp(-x + a * log(x) - logGamma(a)) * h
    }

    /// The natural logarithm of the gamma function.
    ///
    /// Only `a = 0.5` is needed (`logGamma(0.5) = log(sqrt(pi))`), the
    /// Lanczos approximation covers the general case.
    private static func logGamma(_ z: Double) -> Double {
        let coefficients: [Double] = [
            676.5203681218851, -1259.1392167224028, 771.32342877765313,
            -176.61502916214059, 12.507343278686905, -0.13857109526572012,
            9.9843695780195716e-6, 1.5056327351493116e-7,
        ]
        if z < 0.5 {
            // Reflection formula.
            return log(.pi / abs(sin(.pi * z))) - logGamma(1 - z)
        }
        let shifted = z - 1
        var sum = 0.99999999999980993
        for (index, coefficient) in coefficients.enumerated() {
            sum += coefficient / (shifted + Double(index) + 1)
        }
        let t = shifted + Double(coefficients.count) - 0.5
        return 0.5 * log(2 * .pi) + (shifted + 0.5) * log(t) - t + log(sum)
    }
}
