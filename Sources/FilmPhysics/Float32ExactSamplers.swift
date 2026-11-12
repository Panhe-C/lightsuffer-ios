//
//  Float32ExactSamplers.swift
//  light suffer胶片 — iOS app
//
//  The exact samplers of the grain, in the precision of the GPU.
//
//  This file is the **executable specification** of the Metal kernels
//  `filmPoissonExact` and `filmBinomialExact` of
//  `Sources/FilmPhysicsMetal/Shaders/FilmShaders.metal`: the algorithm is
//  the one of ``ExactSamplers`` (the inversion of the cumulative
//  distribution, around the mode of the distribution), but the arithmetic
//  is `Float32` — the arithmetic of the GPU.
//
//  The two implementations (the one of this file and the one of the
//  shading language) are the same algorithm written with the same
//  expressions, so the tests of
//  `Tests/FilmPhysicsTests/Float32ExactSamplerTests.swift` (the law of the
//  samplers, their moments, and their agreement with the double precision
//  samplers of ``ExactSamplers``) validate the kernel before it reaches a
//  Metal device.
//
//  ## The limits of the single precision
//
//  The GPU has no `double` (the shading language of the package is
//  `Float32` from end to end, see `docs/PORTING.md` §7.3), so the
//  inversion is evaluated in single precision:
//
//  * the **log gamma function** is the Lanczos approximation
//    (``logGamma(_:)``), whose relative error is of the order of the
//    `Float32` epsilon (`6e-8`) — the CPU reference uses the same
//    approximation in double precision, where its error is of the order of
//    `1e-15`,
//  * the **cancellation free** forms of the log probabilities
//    (``logPoissonProbability(lambda:k:)`` and
//    ``logBinomialProbability(n:k:p:)``) keep their accuracy in single
//    precision: the terms of the order of `n` are combined before they
//    are summed, so the cancellation does not cost any digit.  The
//    *representation* of `n·p` and of `λ` costs a relative error of
//    `n·eps` (i.e. `7e-4` for the densest layer of the emulsion), which
//    is a relative error of the same order on the probability of the mode,
//  * the **special functions** (the regularised incomplete gamma and the
//    regularised incomplete beta) are evaluated with the same series and
//    the same continued fractions as the CPU reference, with the
//    convergence threshold of the single precision (`1e-7` instead of
//    `3e-16`) and with a floor of the denominators that the single
//    precision can represent (`1e-30` instead of `1e-300`).  Their
//    absolute error is of the order of `1e-5` — i.e. of the order of the
//    resolution of the uniform variate of the GPU (see below),
//  * the **uniform variate** of the GPU has **24 bits** (the resolution
//    of a `Float32` mantissa): the inversion is therefore exact up to
//    `6e-8` of probability, and not up to the `1e-16` of the double
//    precision reference.
//
//  The consequence on the law of the samplers is a **total variation
//  distance** of the order of `1e-5` between the law of the single
//  precision samplers and the exact law — six orders of magnitude below
//  the resolution of the statistical gate of the grain (which is of the
//  order of `1e-3` of the mean of the field).
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The exact samplers of the grain of the negative, in single precision.
///
/// The samplers are **pure functions** of their parameters and of one
/// uniform variate: the counter based generator of the GPU path
/// (``FilmCounterRandom``) draws the uniform from the hash of its
/// counter, so the variate of a pixel is a pure function of its
/// coordinates — the field does not depend on the order of the pixels.
///
/// The algorithm is the one of ``ExactSamplers``:
///
/// 1. the probability of the **mode** of the distribution is computed in
///    log space, with the cancellation free evaluation of
///    ``logPoissonProbability(lambda:k:)`` and
///    ``logBinomialProbability(n:k:p:)``,
/// 2. the cumulative distribution **below** the mode is computed with the
///    regularised incomplete gamma function (the Poisson) and with the
///    regularised incomplete beta function (the binomial),
/// 3. the variate is found by walking from the mode towards the side the
///    uniform falls on, with the recurrence of the probabilities, the
///    accumulated mass being accumulated with a compensated summation.
///
/// **No probability mass is dropped**: the walk is bounded by the support
/// of the distribution (the binomial) or by the underflow of the
/// probabilities (the Poisson), never by an arbitrary tolerance; the
/// variate of the tail of the range is the last `k` whose probability is
/// not negligible (and never a far outlier).
public enum Float32ExactSamplers {

    // MARK: - The special functions

    /// The natural logarithm of the gamma function.
    ///
    /// The Lanczos approximation, the same one the CPU reference uses
    /// (``Numerics/logGamma(_:)``), in single precision.
    ///
    /// - Parameter z: the argument.
    /// - Returns: the natural logarithm of the gamma function.
    public static func logGamma(_ z: Float) -> Float {
        // The nine coefficients of the Lanczos approximation (g = 7).
        let c0: Float = 0.99999999999980993
        let c1: Float = 676.5203681218851
        let c2: Float = -1259.1392167224028
        let c3: Float = 771.32342877765313
        let c4: Float = -176.61502916214059
        let c5: Float = 12.507343278686905
        let c6: Float = -0.13857109526572012
        let c7: Float = 9.9843695780195716e-6
        let c8: Float = 1.5056327351493116e-7
        if z < 0.5 {
            // The reflection formula.
            return log(Float.pi / abs(sin(Float.pi * z))) - logGamma(1 - z)
        }
        let shifted = z - 1
        var sum = c0
        sum += c1 / (shifted + 1)
        sum += c2 / (shifted + 2)
        sum += c3 / (shifted + 3)
        sum += c4 / (shifted + 4)
        sum += c5 / (shifted + 5)
        sum += c6 / (shifted + 6)
        sum += c7 / (shifted + 7)
        sum += c8 / (shifted + 8)
        let t = shifted + 7.5
        return 0.5 * log(2 * Float.pi) + (shifted + 0.5) * log(t) - t + log(sum)
    }

    /// The correction of the Stirling expansion of the logarithm of the
    /// gamma function.
    ///
    /// It is the difference between the exact logarithm of the gamma
    /// function and its main term.  For a large argument the Bernoulli
    /// series is used; for a small argument the exact difference is
    /// computed (both terms are small, so the difference is accurate).
    ///
    /// - Parameter z: the argument.
    /// - Returns: the correction.
    public static func stirlingCorrection(_ z: Float) -> Float {
        guard z > 0 else { return 0 }
        guard z >= 8 else {
            return logGamma(z) - ((z - 0.5) * log(z) - z + 0.5 * log(2 * Float.pi))
        }
        // The Bernoulli numbers `B(2j)` divided by `2j(2j-1)`, with the
        // powers of `z` computed by repeated multiplication (the series is
        // truncated by the single precision anyway).
        let z2 = z * z
        var power = z
        var sum: Float = 0
        sum += (1.0 / 12.0) / power
        power *= z2
        sum += (-1.0 / 360.0) / power
        power *= z2
        sum += (1.0 / 1260.0) / power
        power *= z2
        sum += (-1.0 / 1680.0) / power
        power *= z2
        sum += (1.0 / 1188.0) / power
        power *= z2
        sum += (-691.0 / 360360.0) / power
        power *= z2
        sum += (1.0 / 156.0) / power
        power *= z2
        sum += (-3617.0 / 122400.0) / power
        power *= z2
        sum += (43867.0 / 244188.0) / power
        power *= z2
        sum += (-174611.0 / 125400.0) / power
        return sum
    }

    /// The logarithm of the probability of a Poisson distribution.
    ///
    /// The evaluation is **cancellation free** (like the one of the CPU
    /// reference, ``Numerics/logPoissonProbability(lambda:k:)``): the terms
    /// of the Stirling expansion are combined into the relative entropy
    /// of the distribution, so that the error of the result is of the
    /// order of the rounding of the result itself.
    ///
    /// - Parameters:
    ///   - lambda: the mean of the distribution.
    ///   - k: the value.
    /// - Returns: the logarithm of the probability of `k`.
    public static func logPoissonProbability(lambda: Float, k: Int) -> Float {
        guard lambda > 0, k >= 0 else { return -.infinity }
        if k == 0 { return -lambda }
        let count = Float(k)
        let excess = count + 1 - lambda
        var value = -count * log1p(excess / lambda) + excess
        value -= 0.5 * log(2 * Float.pi * (count + 1))
        value -= stirlingCorrection(count + 1)
        return value
    }

    /// The logarithm of the probability of a binomial distribution.
    ///
    /// The evaluation is **cancellation free**, like the one of the CPU
    /// reference (``Numerics/logBinomialProbability(n:k:p:)``).
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - k: the number of successes.
    ///   - p: the probability of a success.
    /// - Returns: the logarithm of the probability of `k`.
    public static func logBinomialProbability(n: Int, k: Int, p: Float) -> Float {
        guard n > 0, k >= 0, k <= n else { return -.infinity }
        guard p > 0, p < 1 else { return -.infinity }
        let q = 1 - p
        if k == 0 { return Float(n) * log(q) }
        if k == n { return Float(n) * log(p) }
        let trials = Float(n)
        let successes = Float(k)
        let failures = Float(n - k)
        var value = successes * log1p(
            (p * (trials + 1) - (successes + 1)) / (successes + 1)
        )
        value += failures * log1p(
            (q * (trials + 1) - (failures + 1)) / (failures + 1)
        )
        value += 0.5 * log(
            (trials + 1) / (2 * Float.pi * (successes + 1) * (failures + 1))
        )
        value += 1
        value += stirlingCorrection(trials + 1)
        value -= stirlingCorrection(successes + 1)
        value -= stirlingCorrection(failures + 1)
        return value
    }

    /// The series expansion of the lower incomplete gamma function.
    ///
    /// - Parameters:
    ///   - a: the shape of the gamma distribution.
    ///   - x: the argument.
    ///   - front: the front factor of the expansion.
    /// - Returns: the value of the series.
    public static func gammaSeries(_ a: Float, _ x: Float, front: Float) -> Float {
        // The convergence threshold of the single precision (the CPU
        // reference uses `3e-16`, the threshold of the double
        // precision).
        let epsilon: Float = 1e-7
        var ap = a
        var sum: Float = 1.0 / a
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

    /// The continued fraction expansion of the upper incomplete gamma
    /// function.
    ///
    /// - Parameters:
    ///   - a: the shape of the gamma distribution.
    ///   - x: the argument.
    ///   - front: the front factor of the expansion.
    /// - Returns: the value of the continued fraction.
    public static func gammaContinuedFraction(_ a: Float, _ x: Float, front: Float) -> Float {
        let epsilon: Float = 1e-7
        // The floor of the denominators: the single precision cannot
        // represent `1e-300` (it would be a zero, and the division by it
        // an infinity).
        let tiny: Float = 1e-30
        var b = x + 1 - a
        var c: Float = 1.0 / tiny
        var d: Float = 1.0 / b
        var h = d
        var iterations = 0
        while iterations < 1000 {
            let i = Float(iterations + 1)
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

    /// The regularised upper incomplete gamma function `Q(a, x)`, with the
    /// **cancellation free** evaluation of its front factor.
    ///
    /// `Q(a, x) = Γ(a, x) / Γ(a)` is the tail of the gamma distribution;
    /// the cumulative distribution of a Poisson distribution is
    /// `P(X ≤ k) = Q(k + 1, λ)`.
    ///
    /// - Parameters:
    ///   - a: the shape of the gamma distribution (an integer ≥ 1).
    ///   - x: the argument.
    /// - Returns: the value of `Q(a, x)`.
    public static func regularizedGammaQ(a: Int, x: Float) -> Float {
        guard a > 0 else { return 1 }
        guard x > 0 else { return 1 }
        guard x.isFinite else { return 0 }
        let shape = Float(a)
        let front = exp(logPoissonProbability(lambda: x, k: a - 1) + log(x))
        if x < shape + 1 {
            return 1 - gammaSeries(shape, x, front: front)
        }
        return gammaContinuedFraction(shape, x, front: front)
    }

    /// The continued fraction of the incomplete beta function (the modified
    /// Lentz method).
    ///
    /// - Parameters:
    ///   - a: the first shape.
    ///   - b: the second shape.
    ///   - x: the argument, in `[0, 1]`.
    /// - Returns: the value of the continued fraction.
    public static func betaContinuedFraction(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let epsilon: Float = 1e-7
        let tiny: Float = 1e-30
        let qab = a + b
        let qap = a + 1
        let qam = a - 1
        var c: Float = 1.0
        var d = 1 - qab * x / qap
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var h = d
        var m = 1
        while m <= 300 {
            let m2 = 2 * Float(m)
            // The even step.
            var numerator = Float(m) * (b - Float(m)) * x / ((qam + m2) * (a + m2))
            d = 1 + numerator * d
            if abs(d) < tiny { d = tiny }
            c = 1 + numerator / c
            if abs(c) < tiny { c = tiny }
            d = 1 / d
            h *= d * c
            // The odd step.
            numerator = -(a + Float(m)) * (qab + Float(m)) * x
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

    /// The regularised incomplete beta function `I_x(a, b)`, with the
    /// **cancellation free** evaluation of its front factor.
    ///
    /// `I_x(a, b)` is the cumulative distribution function of the beta
    /// distribution; the cumulative distribution of a binomial
    /// distribution is `P(X ≤ k) = I_p(k + 1, n - k)`.
    ///
    /// - Parameters:
    ///   - a: the first shape (an integer ≥ 1).
    ///   - b: the second shape (an integer ≥ 1).
    ///   - x: the argument, in `[0, 1]`.
    /// - Returns: the value of `I_x(a, b)`.
    public static func regularizedIncompleteBeta(a: Int, b: Int, x: Float) -> Float {
        guard a > 0, b > 0 else { return .nan }
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        let n = a + b - 1
        // The front factor is `x·b·P(a - 1; n, x)`: the probability of the
        // binomial distribution of `n` trials at `a - 1` successes, times
        // the factor of the tail of the beta distribution.
        let front = exp(
            logBinomialProbability(n: n, k: a - 1, p: x) + log(x) + log(Float(b))
        )
        if x < (Float(a) + 1) / (Float(a + b) + 2) {
            return front * betaContinuedFraction(Float(a), Float(b), x) / Float(a)
        }
        return 1 - front * betaContinuedFraction(Float(b), Float(a), 1 - x) / Float(b)
    }

    // MARK: - The samplers

    /// A compensated (Kahan) addition, in single precision.
    ///
    /// - Parameters:
    ///   - sum: the sum so far.
    ///   - value: the value to add.
    ///   - compensation: the compensation of the sum (updated).
    /// - Returns: the new sum.
    @inline(__always)
    public static func compensatedAdd(
        _ sum: Float, _ value: Float, compensation: inout Float
    ) -> Float {
        let adjusted = value - compensation
        let updated = sum + adjusted
        compensation = (updated - sum) - adjusted
        return updated
    }

    /// The largest uniform variate the single precision can represent
    /// below one (`1 - 2^-24`).
    ///
    /// The uniform of the counter based generator is built from the 24
    /// high bits of a hash, so it is always below this bound; the clamp
    /// only protects the sampler against a uniform of one.
    public static let maximumUniform: Float = 0.99999994

    /// An exact Poisson variate.
    ///
    /// The method is the inversion of the cumulative distribution, around
    /// the mode of the distribution (the mode of a Poisson distribution is
    /// `floor(λ)`).
    ///
    /// - Parameters:
    ///   - lambda: the mean of the distribution.
    ///   - uniform: the uniform variate that selects the variate, in
    ///     `[0, 1)`.
    /// - Returns: the variate.
    public static func poisson(lambda: Float, uniform: Float) -> Int {
        guard lambda > 0, lambda.isFinite else { return 0 }
        let u = min(max(uniform, 0), maximumUniform)

        // The mode of the distribution and its probability.
        let mode = Int(floor(lambda))
        let modeProbability = exp(logPoissonProbability(lambda: lambda, k: mode))
        guard modeProbability > 0, modeProbability.isFinite else { return mode }

        // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.
        let below = mode > 0 ? regularizedGammaQ(a: mode, x: lambda) : 0

        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode.
            var k = mode
            var probability = modeProbability        // P(k)
            var mass: Float = 0                       // the mass of (k, mode]
            var compensation: Float = 0
            let top = below + modeProbability         // P(X ≤ mode)
            while k > 0 {
                // The cumulative distribution of `k - 1`.
                let previous = top - mass - probability
                if previous <= u { break }
                mass = compensatedAdd(mass, probability, compensation: &compensation)
                probability *= Float(k) / lambda    // P(k - 1)
                k -= 1
            }
            return k
        }

        // The variate is at the mode or above it: the cumulative
        // distribution is walked **up** from the mode.
        var k = mode
        var probability = modeProbability             // P(k)
        var mass: Float = 0                          // the mass of (mode, k]
        var compensation: Float = 0
        let top = below + modeProbability             // P(X ≤ mode)
        if u < top {
            // The variate is the mode itself.
            return mode
        }
        // The bound of the walk: the terms of the distribution decay
        // geometrically beyond the mode, so the walk stops on the
        // underflow of the probability or on the stall of the accumulation
        // long before the bound (the bound is a safety net).
        while k < 1_048_576 {
            let next = probability * lambda / Float(k + 1)   // P(k + 1)
            if next == 0 {
                // The probability underflowed: the mass of the tail beyond
                // this point is negligible, so the uniform cannot fall in
                // it.
                break
            }
            let updated = mass + next
            if updated == mass && top + mass > u {
                // The accumulation of the cumulative distribution stalled:
                // the remaining mass is below the rounding of the sum.  The
                // variate is the last `k` whose probability is not
                // negligible (and **not** a far outlier).
                break
            }
            mass = compensatedAdd(mass, next, compensation: &compensation)
            probability = next
            k += 1
            if top + mass > u { break }
        }
        return k
    }

    /// An exact binomial variate.
    ///
    /// The method is the inversion of the cumulative distribution, around
    /// the mode of the distribution (the mode of a binomial distribution is
    /// `floor((n + 1) p)`).
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - p: the probability of a success.
    ///   - uniform: the uniform variate that selects the variate, in
    ///     `[0, 1)`.
    /// - Returns: the number of successes.
    public static func binomial(n: Int, p: Float, uniform: Float) -> Int {
        guard n > 0 else { return 0 }
        guard p > 0 else { return 0 }
        guard p < 1 else { return n }
        let u = min(max(uniform, 0), maximumUniform)

        let q = 1 - p
        // The mode of the distribution and its probability.
        let mode = min(max(Int(floor((Float(n) + 1) * p)), 0), n)
        let modeProbability = exp(logBinomialProbability(n: n, k: mode, p: p))
        guard modeProbability > 0, modeProbability.isFinite else { return mode }

        // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.
        //
        // The identity of the binomial distribution is
        // `P(X ≤ k) = I_(1-p)(n - k, k + 1)`.
        let below = mode > 0
            ? regularizedIncompleteBeta(a: n - mode + 1, b: mode, x: q)
            : 0

        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode.
            var k = mode
            var probability = modeProbability        // P(k)
            var mass: Float = 0                       // the mass of (k, mode]
            var compensation: Float = 0
            let top = below + modeProbability         // P(X ≤ mode)
            while k > 0 {
                let previous = top - mass - probability
                if previous <= u { break }
                mass = compensatedAdd(mass, probability, compensation: &compensation)
                // P(k - 1)
                probability *= Float(k) * q / (Float(n - k + 1) * p)
                k -= 1
            }
            return k
        }

        // The variate is at the mode or above it: the cumulative
        // distribution is walked **up** from the mode, until the end of the
        // support (the binomial distribution is bounded, so the walk always
        // terminates).
        var k = mode
        var probability = modeProbability             // P(k)
        var mass: Float = 0                          // the mass of (mode, k]
        var compensation: Float = 0
        let top = below + modeProbability             // P(X ≤ mode)
        if u < top {
            // The variate is the mode itself.
            return mode
        }
        while k < n {
            // P(k + 1)
            let next = probability * Float(n - k) * p / (Float(k + 1) * q)
            if next == 0 {
                // The probability underflowed: the mass of the tail beyond
                // this point is negligible.
                break
            }
            let updated = mass + next
            if updated == mass && top + mass > u {
                // The accumulation stalled: the variate is the last `k`
                // whose probability is not negligible.
                break
            }
            mass = compensatedAdd(mass, next, compensation: &compensation)
            probability = next
            k += 1
            if top + mass > u { break }
        }
        // The support ends at `n`: when the accumulated cumulative
        // distribution never exceeds the uniform (the sum of the terms of
        // the distribution is one, up to the rounding of the arithmetic),
        // the variate is the last `k` of the support.
        return k
    }
}
