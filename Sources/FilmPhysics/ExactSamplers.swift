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
//  distribution, started at the mode of the distribution, which is exact and
//  of constant time).
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
public enum ExactSamplers {

    /// An exact Poisson variate.
    ///
    /// The method is the inversion of the cumulative distribution, started
    /// at the mode of the distribution (the mode of a Poisson distribution
    /// is `floor(λ)`): the probability of the mode is computed in log space
    /// (with the log gamma function), and the cumulative distribution is
    /// built from the mode, downwards and upwards.  The walk is of a
    /// constant expected length (a few steps), and the variate is the
    /// smallest `k` whose cumulative distribution exceeds the uniform.
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
        let modeProbability = exp(
            -lambda + Double(mode) * log(lambda)
                - Numerics.logGamma(Double(mode) + 1)
        )
        guard modeProbability > 0 else { return mode }

        // The cumulative distribution below the mode: F(mode - 1).
        //
        // The terms are summed from the mode downwards (the sum does not
        // depend on the order of the terms), and the cumulative
        // distribution is walked **down** from the mode when the variate is
        // below it.
        var below = 0.0
        var probability = modeProbability
        var k = mode
        while k > 0 {
            probability *= Double(k) / lambda
            below += probability
            k -= 1
        }
        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode (F(j) decreases), and the
            // variate is the smallest k whose cumulative distribution
            // exceeds the uniform.
            var cdf = below
            probability = modeProbability
            var j = mode
            while j > 0 {
                probability *= Double(j) / lambda
                j -= 1
                cdf -= probability
                if cdf <= u { return j }
            }
            return 0
        }

        // The mode itself.
        var cdf = below + modeProbability
        if u < cdf { return mode }

        // Above the mode: P(k + 1) = P(k) · λ/(k + 1).
        probability = modeProbability
        k = mode
        let limit = mode + 1000 + Int(20 * lambda.squareRoot())
        while k < limit {
            probability *= lambda / Double(k + 1)
            k += 1
            cdf += probability
            if u < cdf { return k }
        }
        return k
    }

    /// An exact binomial variate.
    ///
    /// The method is the inversion of the cumulative distribution, started
    /// at the mode of the distribution (the mode of a binomial
    /// distribution is `floor((n + 1) p)`): the probability of the mode is
    /// computed in log space (with the log gamma function), and the
    /// cumulative distribution is built from the mode, downwards and
    /// upwards.
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
        let modeProbability = exp(
            Numerics.logGamma(Double(n) + 1)
                - Numerics.logGamma(Double(mode) + 1)
                - Numerics.logGamma(Double(n - mode) + 1)
                + Double(mode) * log(p)
                + Double(n - mode) * log(q)
        )
        guard modeProbability > 0 else { return mode }

        // The cumulative distribution below the mode: F(mode - 1).
        //
        // The terms are summed from the mode downwards (the sum does not
        // depend on the order of the terms), and the cumulative
        // distribution is walked **down** from the mode when the variate is
        // below it.
        var below = 0.0
        var probability = modeProbability
        var k = mode
        while k > 0 {
            probability *= Double(k) * q / (Double(n - k + 1) * p)
            below += probability
            k -= 1
        }
        if u < below {
            // The variate is below the mode: the cumulative distribution is
            // walked **down** from the mode (F(j) decreases), and the
            // variate is the smallest k whose cumulative distribution
            // exceeds the uniform.
            var cdf = below
            probability = modeProbability
            var j = mode
            while j > 0 {
                probability *= Double(j) * q / (Double(n - j + 1) * p)
                j -= 1
                cdf -= probability
                if cdf <= u { return j }
            }
            return 0
        }

        // The mode itself.
        var cdf = below + modeProbability
        if u < cdf { return mode }

        // Above the mode: P(k + 1) = P(k) · (n - k) · p / ((k + 1) · q).
        probability = modeProbability
        k = mode
        while k < n {
            probability *= Double(n - k) * p / (Double(k + 1) * q)
            k += 1
            cdf += probability
            if u < cdf { return k }
        }
        return n
    }
}
