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
        gammaSeries(a, x, front: exp(-x + a * log(x) - logGamma(a)))
    }

    /// The series expansion of `P(a, x)` with an explicit front factor.
    ///
    /// The front factor is the part of the expansion that does not depend
    /// on the series itself: it is evaluated separately, so that the
    /// cancellation free evaluation of the exact samplers can be used
    /// without touching the numbers of the CPU reference (which use the
    /// plain front factor through `erfc`).
    private static func gammaSeries(_ a: Double, _ x: Double, front: Double) -> Double {
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
        return sum * front
    }

    /// The continued fraction expansion of `Q(a, x)`, used for `x >= a + 1`.
    private static func gammaContinuedFraction(_ a: Double, _ x: Double) -> Double {
        gammaContinuedFraction(a, x, front: exp(-x + a * log(x) - logGamma(a)))
    }

    /// The continued fraction expansion of `Q(a, x)` with an explicit front
    /// factor.
    private static func gammaContinuedFraction(
        _ a: Double, _ x: Double, front: Double
    ) -> Double {
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
        return front * h
    }

    /// A compensated (Kahan) addition.
    ///
    /// The compensation holds the part of the rounding that the previous
    /// additions lost, so that the sum of many terms keeps an absolute
    /// error of the order of the rounding of the result (and not of the
    /// order of the number of the terms).
    ///
    /// - Parameters:
    ///   - sum: the sum so far.
    ///   - value: the value to add.
    ///   - compensation: the compensation of the sum (updated).
    /// - Returns: the new sum.
    public static func compensatedAdd(
        _ sum: Double, _ value: Double, compensation: inout Double
    ) -> Double {
        let adjusted = value - compensation
        let updated = sum + adjusted
        compensation = (updated - sum) - adjusted
        return updated
    }

    // MARK: - The special functions of the exact samplers

    /// The regularised upper incomplete gamma function `Q(a, x)`, with the
    /// **cancellation free** evaluation of its front factor.
    ///
    /// `Q(a, x) = Γ(a, x) / Γ(a)` is the tail of the gamma distribution;
    /// the cumulative distribution of a Poisson distribution is
    /// `P(X ≤ k) = Q(k + 1, λ)`.
    ///
    /// The front factor of the continued fraction is
    /// `exp(-x + a·log(x) - Γ(a))`: it is the difference of terms of the
    /// order of `a·log(x)`, so its evaluation loses about thirteen digits
    /// when `a` is of the order of a thousand.  The implementation below
    /// evaluates it through the logarithm of the probability of a Poisson
    /// distribution (``logPoissonProbability``), which is free of that
    /// cancellation: the relative error of the front is of the order of the
    /// rounding of the result itself, and not of the order of the rounding
    /// of its terms.
    ///
    /// - Parameters:
    ///   - a: the shape of the gamma distribution (an integer ≥ 1).
    ///   - x: the argument.
    /// - Returns: the value of `Q(a, x)`.
    public static func regularizedGammaQ(a: Int, x: Double) -> Double {
        guard a > 0 else { return 1 }
        guard x > 0 else { return 1 }
        guard x.isFinite else { return 0 }
        let shape = Double(a)
        let front = exp(logPoissonProbability(lambda: x, k: a - 1) + log(x))
        if x < shape + 1 {
            return 1 - gammaSeries(shape, x, front: front)
        }
        return gammaContinuedFraction(shape, x, front: front)
    }

    /// The regularised incomplete beta function `I_x(a, b)`, with the
    /// **cancellation free** evaluation of its front factor.
    ///
    /// `I_x(a, b)` is the cumulative distribution function of the beta
    /// distribution; the cumulative distribution of a binomial
    /// distribution is `P(X ≤ k) = I_p(k + 1, n - k)`.
    ///
    /// The front factor is evaluated through the logarithm of the
    /// probability of a binomial distribution
    /// (``logBinomialProbability``), for the same reason as in
    /// ``regularizedGammaQ(a:x:)``.
    ///
    /// - Parameters:
    ///   - a: the first shape (an integer ≥ 1).
    ///   - b: the second shape (an integer ≥ 1).
    ///   - x: the argument, in `[0, 1]`.
    /// - Returns: the value of `I_x(a, b)`.
    public static func regularizedIncompleteBeta(a: Int, b: Int, x: Double) -> Double {
        guard a > 0, b > 0 else { return .nan }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let n = a + b - 1
        // The front factor is `x·b·P(a - 1; n, x)`: the probability of the
        // binomial distribution of `n` trials at `a - 1` successes, times
        // the factor of the tail of the beta distribution.
        let front = exp(
            logBinomialProbability(n: n, k: a - 1, p: x) + log(x) + log(Double(b))
        )
        if x < (Double(a) + 1) / (Double(a + b) + 2) {
            return front * betaContinuedFraction(Double(a), Double(b), x) / Double(a)
        }
        return 1 - front * betaContinuedFraction(Double(b), Double(a), 1 - x) / Double(b)
    }

    /// The continued fraction of the incomplete beta function (the modified
    /// Lentz method).
    private static func betaContinuedFraction(
        _ a: Double, _ b: Double, _ x: Double
    ) -> Double {
        let epsilon = 3e-16
        let tiny = 1e-300
        let qab = a + b
        let qap = a + 1
        let qam = a - 1
        var c = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        var m = 1
        while m <= 300 {
            let m2 = 2 * Double(m)
            // The even step.
            var numerator = Double(m) * (b - Double(m)) * x / ((qam + m2) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            // The odd step.
            numerator = -(a + Double(m)) * (qab + Double(m)) * x
                / ((a + m2) * (qap + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            let delta = d * c
            h *= delta
            if abs(delta - 1) < epsilon { break }
            m += 1
        }
        return h
    }

    /// The logarithm of the probability of a Poisson distribution.
    ///
    /// The evaluation is **cancellation free**: the terms of the Stirling
    /// expansion are combined into the relative entropy of the
    /// distribution, so that the absolute error of the result is of the
    /// order of the rounding of the result itself (and not of the order of
    /// the rounding of the terms, which are of the order of `k·log(λ)`).
    ///
    /// - Parameters:
    ///   - lambda: the mean of the distribution.
    ///   - k: the value.
    /// - Returns: the logarithm of the probability of `k`.
    public static func logPoissonProbability(lambda: Double, k: Int) -> Double {
        guard lambda > 0, k >= 0 else { return -.infinity }
        if k == 0 { return -lambda }
        let count = Double(k)
        // The Stirling expansion of the logarithm of the gamma function is
        // used at the argument `k + 1`:
        //
        //     log P(k) = -λ + k·log(λ) - [(k + 0.5)·log(k + 1) - (k + 1)
        //                + 0.5·log(2π) + S(k + 1)]
        //
        // The two terms of the order of `k` are combined into
        // `-k·log((k + 1)/λ) + (k + 1 - λ)`, which is free of any
        // cancellation: the difference `k + 1 - λ` is exact and the
        // logarithm is evaluated by `log1p`, which keeps the accuracy of
        // the small argument.
        let excess = count + 1 - lambda
        var value = -count * log1p(excess / lambda) + excess
        value -= 0.5 * log(2 * .pi * (count + 1))
        value -= stirlingCorrection(count + 1)
        return value
    }

    /// The logarithm of the probability of a binomial distribution.
    ///
    /// The evaluation is **cancellation free**, like
    /// ``logPoissonProbability(lambda:k:)``.
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - k: the number of successes.
    ///   - p: the probability of a success.
    /// - Returns: the logarithm of the probability of `k`.
    public static func logBinomialProbability(n: Int, k: Int, p: Double) -> Double {
        guard n > 0, k >= 0, k <= n else { return -.infinity }
        guard p > 0, p < 1 else { return -.infinity }
        let q = 1 - p
        if k == 0 { return Double(n) * log(q) }
        if k == n { return Double(n) * log(p) }
        let trials = Double(n)
        let successes = Double(k)
        let failures = Double(n - k)
        // The Stirling expansion of the logarithm of the gamma function is
        // used at the arguments `n + 1`, `k + 1` and `n - k + 1`:
        //
        //     log P(k) = k·log(p(n + 1)/(k + 1))
        //              + (n - k)·log(q(n + 1)/(n - k + 1))
        //              + 0.5·log((n + 1)/(2π(k + 1)(n - k + 1))) + 1
        //              + S(n + 1) - S(k + 1) - S(n - k + 1)
        //
        // The two logarithms of the first line are the logarithms of the
        // ratios, which are one when `k` is the mode of the distribution:
        // they are evaluated by `log1p`, which keeps the accuracy of the
        // small argument, so that the cancellation of the terms of the
        // order of `n` does not cost any digit.
        var value = successes * log1p(
            (p * (trials + 1) - (successes + 1)) / (successes + 1)
        )
        value += failures * log1p(
            (q * (trials + 1) - (failures + 1)) / (failures + 1)
        )
        value += 0.5 * log(
            (trials + 1) / (2 * .pi * (successes + 1) * (failures + 1))
        )
        value += 1
        value += stirlingCorrection(trials + 1)
        value -= stirlingCorrection(successes + 1)
        value -= stirlingCorrection(failures + 1)
        return value
    }

    /// The correction of the Stirling expansion of the logarithm of the
    /// gamma function.
    ///
    /// It is the difference between the exact logarithm of the gamma
    /// function and its main term:
    /// `S(z) = logGamma(z) - ((z - 0.5)·log(z) - z + 0.5·log(2π))`.
    ///
    /// For a large argument the Bernoulli series is used (its terms are
    /// computed directly, so the evaluation is free of any cancellation);
    /// for a small argument the exact difference is computed (both terms
    /// are small, so the difference is accurate).
    private static func stirlingCorrection(_ z: Double) -> Double {
        guard z > 0 else { return 0 }
        guard z >= 8 else {
            return logGamma(z) - ((z - 0.5) * log(z) - z + 0.5 * log(2 * .pi))
        }
        // The Bernoulli numbers `B(2j)` divided by `2j(2j-1)`.
        let coefficients: [Double] = [
            1.0 / 12.0, -1.0 / 360.0, 1.0 / 1260.0, -1.0 / 1680.0, 1.0 / 1188.0,
            -691.0 / 360360.0, 1.0 / 156.0, -3617.0 / 122400.0,
            43867.0 / 244188.0, -174611.0 / 125400.0,
        ]
        var sum = 0.0
        for (index, coefficient) in coefficients.enumerated() {
            let power = 2 * Double(index) + 1
            sum += coefficient / pow(z, power)
        }
        return sum
    }

    /// The natural logarithm of the gamma function.
    ///
    /// Only `a = 0.5` is needed (`logGamma(0.5) = log(sqrt(pi))`), the
    /// Lanczos approximation covers the general case.
    ///
    /// It is public because the exact samplers of the grain
    /// (``ExactSamplers``) compute the probability of the mode of their
    /// distributions in log space.
    public static func logGamma(_ z: Double) -> Double {
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
