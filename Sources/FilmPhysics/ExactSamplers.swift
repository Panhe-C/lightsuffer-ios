//
//  ExactSamplers.swift
//  light suffer胶片 — iOS app
//
//  The **exact** samplers of the grain of the negative.
//
//  The upstream engine has two paths for the variates of the grain:
//
//  * the **default** path (`settings.use_fast_stats = False`), which draws
//    them from the exact SciPy generators (`scipy.stats.poisson.rvs` and
//    `scipy.stats.binom.rvs`, i.e. the PTRS and the BTPE algorithms of
//    NumPy),
//  * the **fast** path (`settings.use_fast_stats = True`), which draws them
//    from the kernels of `spektrafilm.utils.fast_stats`: the product method
//    of Knuth and the inversion of the cumulative distribution (both exact)
//    below their thresholds, and a **normal approximation** above them.
//
//  The port reproduces the **fast** path (it is the algorithm of the CPU
//  reference), and the two paths differ by a *model difference* that the
//  reference fixture measures explicitly (see `docs/PORTING.md` §3.4).
//
//  This file provides the **exact** samplers, so that the port can also
//  reproduce the default path of the upstream: they draw from the very same
//  distributions as the SciPy generators (the inversion of the cumulative
//  distribution, which is exact).
//
//  The investigation of the difference between the two paths is in
//  `docs/PORTING.md` §3.4: it is **not** a difference of approximation, it
//  is an **underflow** of the inversion of the upstream fast kernel — the
//  fast kernel computes `(1 - p) ** n` in double precision, which underflows
//  to zero for the dense layers of the emulsion (a thousand particles per
//  pixel and a probability of development of 0.998), and the kernel then
//  returns the maximum of the distribution (every particle develops).
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The sampler of the variates of the grain of the negative.
///
/// The default is ``fast``: the algorithm of the CPU reference (and of the
/// Metal kernels) must not change, so that the existing fixtures and the
/// existing validations stay valid.
public enum GrainSampler: Sendable {

    /// The fast kernels of the upstream (`spektrafilm.utils.fast_stats`).
    ///
    /// The algorithm the port reproduces by default: the product method of
    /// Knuth and the inversion below the thresholds of the upstream, and
    /// the normal approximations above them.
    case fast

    /// The exact generators of the upstream default path.
    ///
    /// The variates are drawn from the very same distributions as the SciPy
    /// generators of the upstream (`scipy.stats.poisson.rvs` and
    /// `scipy.stats.binom.rvs`): the inversion of the cumulative
    /// distribution, started at the mode of the distribution.
    case exact
}

/// The exact samplers of the grain of the negative.
///
/// The two samplers are **pure functions** of their parameters and of one
/// uniform variate: the sequential generator of the CPU reference draws the
/// uniform from its stream, and the counter based generator of the GPU path
/// draws it from the hash of its counter.  The two implementations
/// therefore share the very same code.
///
/// Upstream reference: the exact generators of the default path of the
/// upstream (`scipy.stats.poisson.rvs` and `scipy.stats.binom.rvs`, i.e.
/// the PTRS and the BTPE algorithms of NumPy); the *distribution* is the
/// one of those generators, the *realisation* is the one of the port.
///
/// ## The algorithm
///
/// Both samplers **invert the cumulative distribution** of their
/// distribution: the variate is the smallest `k` whose cumulative
/// distribution exceeds the uniform variate.  The inversion is done around
/// the **mode** of the distribution, where the probability mass is
/// concentrated:
///
/// 1. the probability of the mode is computed in log space, with the
///    **cancellation free** evaluation of ``Numerics/logPoissonProbability(lambda:k:)``
///    and ``Numerics/logBinomialProbability(n:k:p:)``,
/// 2. the cumulative distribution **below** the mode is computed with the
///    regularised incomplete gamma function (the Poisson) and with the
///    regularised incomplete beta function (the binomial),
/// 3. the variate is found by walking from the mode towards the side the
///    uniform variate falls on, with the recurrence of the probabilities:
///    `P(k - 1) = P(k)·k/λ` (the Poisson) and
///    `P(k ∓ 1) = P(k)·k·q/((n - k + 1)·p)` (the binomial).
///
/// The walk is **exact**: every `k` owns an interval of the uniform of the
/// length `P(k)`, and the interval of the variate is the one the uniform
/// falls in.  **No probability mass is dropped**: the walk is bounded by
/// the support of the distribution (the binomial) or by the underflow of
/// the probabilities (the Poisson), never by an arbitrary tolerance.
///
/// ### The cost
///
/// The number of steps of the walk is the distance between the mode and
/// the variate, which is of the order of **√(variance)** of the
/// distribution (the terms around the mode of a Poisson or of a binomial
/// distribution decay like a Gaussian).  The two special functions of the
/// first step cost a fixed number of iterations (a few tens).
///
/// The previous implementation walked from the mode **down to zero** before
/// trying the mode and the terms above it, i.e. it took `Θ(λ)` steps (about
/// 2 500 for the dense layers of the emulsion, and more than 11 000 for the
/// densest one) — the claim that the walk was of a "constant expected
/// length" was wrong, and it is corrected here.
///
/// ### The bias of the inversion
///
/// The only inexactness of the samplers is the rounding of the arithmetic:
///
/// * the cumulative distribution below the mode is the value of a special
///   function, whose relative error is of the order of `1e-15`,
/// * the walk accumulates the probabilities with a compensated
///   (Kahan) summation, so that the rounding of the accumulation is of the
///   order of `1e-16`,
/// * the probabilities of the walk are computed with the recurrence of the
///   distribution: their relative error grows with the number of steps
///   (of the order of `k·eps`, i.e. `4e-13` for the densest layer of the
///   emulsion).
///
/// The **total variation distance** between the law of the sampler and the
/// exact law is therefore of the order of `1e-12` for the densest layer of
/// the emulsion (and of the order of `1e-15` for the sparse ones).  It is
/// measured by the tests of `Tests/FilmPhysicsTests/ExactSamplerTests.swift`.
public enum ExactSamplers {

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
    public static func poisson(lambda: Double, uniform: Double) -> Int {
        guard lambda > 0, lambda.isFinite else { return 0 }
        let u = min(max(uniform, 0.0), 1.0 - 1e-16)

        // The mode of the distribution and its probability.
        let mode = Int(floor(lambda))
        let modeProbability = exp(Numerics.logPoissonProbability(lambda: lambda, k: mode))
        guard modeProbability > 0, modeProbability.isFinite else { return mode }

        // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.
        let below = mode > 0
            ? Numerics.regularizedGammaQ(a: mode, x: lambda)
            : 0.0

        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode.
            //
            // The mass that is subtracted from the cumulative distribution
            // is accumulated with a compensated summation, so that the
            // rounding of the accumulation stays of the order of the
            // rounding of the result.
            var k = mode
            var probability = modeProbability        // P(k)
            var mass = 0.0                          // the mass of (k, mode]
            var compensation = 0.0
            let top = below + modeProbability        // P(X ≤ mode)
            while k > 0 {
                // The cumulative distribution of `k - 1`.
                let previous = top - mass - probability
                if previous <= u { break }
                mass = Numerics.compensatedAdd(mass, probability, compensation: &compensation)
                probability *= Double(k) / lambda  // P(k - 1)
                k -= 1
            }
            return k
        }

        // The variate is at the mode or above it: the cumulative
        // distribution is walked **up** from the mode.
        var k = mode
        var probability = modeProbability            // P(k)
        var mass = 0.0                              // the mass of (mode, k)
        var compensation = 0.0
        let top = below + modeProbability            // P(X ≤ mode)
        if u < top {
            // The variate is the mode itself.
            return mode
        }
        while true {
            let next = probability * lambda / Double(k + 1)  // P(k + 1)
            if next == 0 {
                // The probability underflowed: the mass of the tail beyond
                // this point is below 1e-300 (the terms decay geometrically
                // beyond the mode), so the uniform cannot fall in it.
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
            mass = Numerics.compensatedAdd(mass, next, compensation: &compensation)
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
    public static func binomial(n: Int, p: Double, uniform: Double) -> Int {
        guard n > 0 else { return 0 }
        guard p > 0 else { return 0 }
        guard p < 1 else { return n }
        let u = min(max(uniform, 0.0), 1.0 - 1e-16)

        let q = 1.0 - p
        // The mode of the distribution and its probability.
        let mode = min(max(Int(floor((Double(n) + 1) * p)), 0), n)
        let modeProbability = exp(Numerics.logBinomialProbability(n: n, k: mode, p: p))
        guard modeProbability > 0, modeProbability.isFinite else { return mode }

        // The cumulative distribution below the mode: `P(X ≤ mode - 1)`.
        //
        // The identity of the binomial distribution is
        // `P(X ≤ k) = I_(1-p)(n - k, k + 1)`.
        let below = mode > 0
            ? Numerics.regularizedIncompleteBeta(a: n - mode + 1, b: mode, x: q)
            : 0.0

        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode.
            var k = mode
            var probability = modeProbability        // P(k)
            var mass = 0.0                          // the mass of (k, mode]
            var compensation = 0.0
            let top = below + modeProbability        // P(X ≤ mode)
            while k > 0 {
                let previous = top - mass - probability
                if previous <= u { break }
                mass = Numerics.compensatedAdd(mass, probability, compensation: &compensation)
                probability *= Double(k) * q / (Double(n - k + 1) * p)   // P(k - 1)
                k -= 1
            }
            return k
        }

        // The variate is at the mode or above it: the cumulative
        // distribution is walked **up** from the mode, until the end of the
        // support (the binomial distribution is bounded, so the walk always
        // terminates).
        var k = mode
        var probability = modeProbability            // P(k)
        var mass = 0.0                              // the mass of (mode, k]
        var compensation = 0.0
        let top = below + modeProbability            // P(X ≤ mode)
        if u < top {
            // The variate is the mode itself.
            return mode
        }
        while k < n {
            let next = probability * Double(n - k) * p / (Double(k + 1) * q)  // P(k + 1)
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
            mass = Numerics.compensatedAdd(mass, next, compensation: &compensation)
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
