//
//  ExactSamplerTests.swift
//  light suffer胶片 — iOS app
//
//  The unit tests of the exact samplers of the grain (the inversion of the
//  cumulative distribution, around the mode of the distribution).
//
//  The samplers must draw from the very same distributions as the SciPy
//  generators of the default path of the upstream (`scipy.stats.poisson.rvs`
//  and `scipy.stats.binom.rvs`): the test checks their law (a chi-square
//  test of the empirical distribution against the exact one), their mean
//  and their variance, and it checks the **difference** with the fast
//  kernels of the upstream — the inversion of the upstream underflows for
//  the dense layers of the emulsion, and the fast kernel then returns the
//  maximum of the distribution (every particle develops).
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class ExactSamplerTests: XCTestCase {

    /// The number of the variates of the statistical checks.
    ///
    /// The tolerance of the checks is a few standard errors of the
    /// estimate: the check is a sanity check of the implementation, not a
    /// statistical validation (the validation of the grain is the one of
    /// `GrainStatisticsTests` and `GrainCounterTests`).
    private let samples = 200_000

    /// The tolerance of the statistical checks, in standard errors.
    private let tolerance = 5.0

    // MARK: - The helpers

    /// The probability of a Poisson distribution, computed by the **direct**
    /// formula (independently of the code of the samplers).
    private static func poissonProbability(lambda: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        return exp(
            -lambda + Double(k) * log(lambda) - Numerics.logGamma(Double(k) + 1)
        )
    }

    /// The probability of a binomial distribution, computed by the
    /// **direct** formula (independently of the code of the samplers).
    private static func binomialProbability(n: Int, k: Int, p: Double) -> Double {
        guard k >= 0, k <= n else { return 0 }
        return exp(
            Numerics.logGamma(Double(n) + 1)
                - Numerics.logGamma(Double(k) + 1)
                - Numerics.logGamma(Double(n - k) + 1)
                + Double(k) * log(p)
                + Double(n - k) * log(1 - p)
        )
    }

    /// The chi-square statistic of an empirical distribution against an
    /// exact one.
    ///
    /// The buckets whose expected count is below five are **merged** into
    /// the last one (the standard practice: the chi-square approximation
    /// needs an expected count of at least five).
    ///
    /// - Parameters:
    ///   - counts: the observed counts, one per bucket.
    ///   - expected: the expected counts, one per bucket.
    /// - Returns: the statistic and the number of the degrees of freedom.
    private static func chiSquare(
        counts: [Int], expected: [Double]
    ) -> (statistic: Double, degreesOfFreedom: Int) {
        var statistic = 0.0
        var degrees = 0
        var lastExpected = 0.0
        var lastObserved = 0
        for index in 0..<min(counts.count, expected.count) {
            lastExpected += expected[index]
            lastObserved += counts[index]
            if expected[index] >= 5 {
                statistic += pow(Double(lastObserved) - lastExpected, 2) / lastExpected
                degrees += 1
                lastExpected = 0
                lastObserved = 0
            }
        }
        return (statistic, max(degrees - 1, 1))
    }

    /// The probability of a chi-square statistic (the Wilson-Hilferty
    /// approximation of the normal quantile).
    ///
    /// The approximation is accurate to about 1e-3 over the range the
    /// tests use, which is enough for a gate at the level of 1e-3.
    private static func chiSquareProbability(
        _ statistic: Double, degreesOfFreedom: Int
    ) -> Double {
        let k = Double(degreesOfFreedom)
        let z = (pow(statistic / k, 1.0 / 3.0) - (1 - 2 / (9 * k)))
            / (2 / (9 * k)).squareRoot()
        return 1 - Numerics.normalCDF(z)
    }

    // MARK: - The moments

    /// The exact Poisson variate has the mean and the variance of the
    /// distribution.
    func testTheExactPoissonHasTheTheoreticalMoments() throws {
        let lambda = 137.0
        var generator = RandomGenerator(seed: 0xC0FFEE)
        var sum = 0.0
        var squares = 0.0
        for _ in 0..<samples {
            let variate = Double(generator.poissonExact(lambda))
            sum += variate
            squares += variate * variate
        }
        let mean = sum / Double(samples)
        let variance = squares / Double(samples) - mean * mean
        let standardError = lambda.squareRoot() / Double(samples).squareRoot()
        XCTAssertEqual(mean, lambda, accuracy: tolerance * standardError)
        XCTAssertEqual(variance, lambda, accuracy: tolerance * 2 * standardError)
    }

    /// The exact binomial variate has the mean and the variance of the
    /// distribution.
    func testTheExactBinomialHasTheTheoreticalMoments() throws {
        let n = 400
        let p = 0.73
        var generator = RandomGenerator(seed: 0xBEEF)
        var sum = 0.0
        var squares = 0.0
        for _ in 0..<samples {
            let variate = Double(generator.binomialExact(n: n, p: p))
            sum += variate
            squares += variate * variate
        }
        let mean = sum / Double(samples)
        let variance = squares / Double(samples) - mean * mean
        let standardError = (Double(n) * p * (1 - p)).squareRoot() / Double(samples).squareRoot()
        XCTAssertEqual(mean, Double(n) * p, accuracy: tolerance * standardError)
        XCTAssertEqual(
            variance, Double(n) * p * (1 - p),
            accuracy: tolerance * 2 * standardError * (1 + Double(n) * p * (1 - p)).squareRoot()
        )
    }

    // MARK: - The law of the samplers

    /// The law of the exact Poisson variate is the law of the distribution.
    ///
    /// The test is a **chi-square** test of the empirical distribution
    /// against the exact one (the probabilities are computed by the direct
    /// formula, independently of the code of the sampler).  The gate is the
    /// probability of the statistic: it must be above 1e-3 (the usual
    /// significance level).
    func testTheExactPoissonFollowsTheTheoreticalDistribution() throws {
        for lambda in [3.5, 2500.0] {
            let count = 100_000
            var generator = RandomGenerator(seed: 0x5EED)
            let mode = Int(floor(lambda))
            // The buckets: the mode and its neighbours, then the tails.
            let lower = mode - Int(6 * lambda.squareRoot()) - 10
            let upper = mode + Int(6 * lambda.squareRoot()) + 10
            var counts = [Int](repeating: 0, count: max(upper - lower + 1, 1))
            var outside = 0
            for _ in 0..<count {
                let variate = generator.poissonExact(lambda)
                if variate >= lower && variate <= upper {
                    counts[variate - lower] += 1
                } else {
                    outside += 1
                }
            }
            // The expected counts, by the direct formula.
            var expected = [Double](repeating: 0, count: counts.count)
            var total = 0.0
            for index in 0..<counts.count {
                expected[index] = Double(count) * Self.poissonProbability(
                    lambda: lambda, k: lower + index
                )
                total += expected[index]
            }
            // The mass outside of the buckets is negligible (it is added to
            // the last bucket, whose expected count is large enough).
            expected[expected.count - 1] += Double(outside)
            XCTAssertLessThan(
                Double(outside) / Double(count), 1e-6,
                "the mass outside of the buckets of the Poisson(\(lambda))"
            )
            let chi = Self.chiSquare(counts: counts, expected: expected)
            let probability = Self.chiSquareProbability(
                chi.statistic, degreesOfFreedom: chi.degreesOfFreedom
            )
            print("EXACT poisson(\(lambda)): the chi-square is \(chi.statistic) "
                + "for \(chi.degreesOfFreedom) degrees of freedom, the "
                + "probability is \(probability)")
            XCTAssertGreaterThan(
                probability, 1e-3,
                "the law of the exact Poisson(\(lambda)) is not the law of the "
                    + "distribution (the chi-square is \(chi.statistic))"
            )
        }
    }

    /// The law of the exact binomial variate is the law of the
    /// distribution.
    ///
    /// The test is a **chi-square** test, like the one of the Poisson; the
    /// dense layer of the emulsion (a probability of development of 0.998
    /// and 3 768 particles per pixel) is one of the cases.
    func testTheExactBinomialFollowsTheTheoreticalDistribution() throws {
        let cases = [(n: 40, p: 0.3), (n: 3768, p: 0.99828)]
        for (n, p) in cases {
            let count = 100_000
            var generator = RandomGenerator(seed: 0xBEEF)
            let mode = min(max(Int(floor((Double(n) + 1) * p)), 0), n)
            let deviation = (Double(n) * p * (1 - p)).squareRoot()
            let lower = max(mode - Int(6 * deviation) - 2, 0)
            let upper = min(mode + Int(6 * deviation) + 2, n)
            var counts = [Int](repeating: 0, count: max(upper - lower + 1, 1))
            var outside = 0
            for _ in 0..<count {
                let variate = generator.binomialExact(n: n, p: p)
                if variate >= lower && variate <= upper {
                    counts[variate - lower] += 1
                } else {
                    outside += 1
                }
            }
            var expected = [Double](repeating: 0, count: counts.count)
            for index in 0..<counts.count {
                expected[index] = Double(count) * Self.binomialProbability(
                    n: n, k: lower + index, p: p
                )
            }
            expected[expected.count - 1] += Double(outside)
            XCTAssertLessThan(
                Double(outside) / Double(count), 1e-6,
                "the mass outside of the buckets of the binomial(\(n), \(p))"
            )
            let chi = Self.chiSquare(counts: counts, expected: expected)
            let probability = Self.chiSquareProbability(
                chi.statistic, degreesOfFreedom: chi.degreesOfFreedom
            )
            print("EXACT binomial(\(n), \(p)): the chi-square is \(chi.statistic) "
                + "for \(chi.degreesOfFreedom) degrees of freedom, the "
                + "probability is \(probability)")
            XCTAssertGreaterThan(
                probability, 1e-3,
                "the law of the exact binomial(\(n), \(p)) is not the law of the "
                    + "distribution (the chi-square is \(chi.statistic))"
            )
        }
    }

    /// The special functions of the inversion agree with the direct sums.
    ///
    /// The incomplete gamma function gives the cumulative distribution of
    /// the Poisson and the incomplete beta function the one of the
    /// binomial: the test compares them with the direct sums of the
    /// probabilities (which are computed by the direct formula, over the
    /// whole support).
    func testTheSpecialFunctionsOfTheInversionAgreeWithTheDirectSums() throws {
        // The Poisson.
        for (lambda, k) in [(3.5, 2), (137.0, 100), (2500.0, 2400)] {
            var total = 0.0
            for index in 0...k {
                total += Self.poissonProbability(lambda: lambda, k: index)
            }
            let special = Numerics.regularizedGammaQ(a: k + 1, x: lambda)
            XCTAssertEqual(
                special, total, accuracy: 1e-12,
                "the cumulative distribution of the Poisson(\(lambda)) at \(k)"
            )
        }
        // The binomial.
        for (n, p, k) in [(20, 0.5, 10), (400, 0.73, 300), (3768, 0.998, 3760)] {
            var total = 0.0
            for index in 0...k {
                total += Self.binomialProbability(n: n, k: index, p: p)
            }
            let special = Numerics.regularizedIncompleteBeta(
                a: n - k, b: k + 1, x: 1 - p
            )
            XCTAssertEqual(
                special, total, accuracy: 1e-12,
                "the cumulative distribution of the binomial(\(n), \(p)) at \(k)"
            )
        }
    }

    // MARK: - The tail of the inversion

    /// The tail of the inversion is handled honestly.
    ///
    /// The inversion must be **consistent**: the variate `k` of a uniform
    /// `u` is the smallest `k` whose cumulative distribution exceeds `u`,
    /// i.e. `F(k - 1) ≤ u < F(k)`.  The test checks that property on a
    /// range of uniforms (the cumulative distributions are computed by the
    /// direct sum, independently of the code of the sampler).
    ///
    /// The tail of the range (the uniforms of the last `1e-16`) is the
    /// case the inversion cannot resolve: the cumulative distribution of a
    /// distribution is one, up to the rounding of the arithmetic, so the
    /// walk can end without a `k` whose cumulative distribution exceeds the
    /// uniform.  The sampler must then return the **last** `k` whose
    /// probability is not negligible (and **not** a far outlier), and the
    /// variate must stay monotone in the uniform.
    func testTheTailOfTheExactSamplersIsHandledHonestly() throws {
        // The Poisson: the inversion is consistent.
        let lambda = 137.0
        for uniform in [0.0, 1e-6, 0.1, 0.5, 0.9, 0.99, 0.999, 1.0 - 1e-12] {
            let variate = ExactSamplers.poisson(lambda: lambda, uniform: uniform)
            let below = Self.poissonCDF(lambda: lambda, k: variate - 1)
            let at = Self.poissonCDF(lambda: lambda, k: variate)
            XCTAssertLessThanOrEqual(
                below, uniform + 1e-12,
                "the Poisson(\(lambda)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k - 1) is \(below)"
            )
            XCTAssertGreaterThanOrEqual(
                at, uniform - 1e-12,
                "the Poisson(\(lambda)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k) is \(at)"
            )
        }

        // The binomial: the inversion is consistent.
        let n = 20
        let p = 0.5
        for uniform in [0.0, 1e-6, 0.1, 0.5, 0.9, 0.99, 0.999, 1.0 - 1e-12] {
            let variate = ExactSamplers.binomial(n: n, p: p, uniform: uniform)
            let below = Self.binomialCDF(n: n, p: p, k: variate - 1)
            let at = Self.binomialCDF(n: n, p: p, k: variate)
            XCTAssertLessThanOrEqual(
                below, uniform + 1e-12,
                "the binomial(\(n), \(p)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k - 1) is \(below)"
            )
            XCTAssertGreaterThanOrEqual(
                at, uniform - 1e-12,
                "the binomial(\(n), \(p)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k) is \(at)"
            )
        }

        // The tail of the range: the variate stays monotone and it is not a
        // far outlier.
        var previous = -1
        for uniform in [1.0 - 1e-9, 1.0 - 1e-12, 1.0 - 1e-15, 1.0 - 1e-16] {
            let variate = ExactSamplers.poisson(lambda: lambda, uniform: uniform)
            XCTAssertGreaterThanOrEqual(variate, previous)
            previous = variate
            XCTAssertLessThan(
                variate, Int(floor(lambda)) + Int(10 * lambda.squareRoot()) + 10,
                "the exact Poisson sampler returned \(variate), a far outlier"
            )
        }

        // The dense layer of the emulsion: the variate of the largest
        // uniform is the **last** value of the support (the cumulative
        // distribution of the support is one, up to the rounding of the
        // arithmetic, and the mass of the last value is not negligible).
        let dense = 3768
        let denseP = 0.99828
        let binomial = ExactSamplers.binomial(
            n: dense, p: denseP, uniform: 1.0 - 1e-16
        )
        XCTAssertLessThanOrEqual(
            binomial, dense,
            "the exact binomial sampler returned \(binomial), above the support"
        )
        XCTAssertGreaterThan(
            binomial, dense - 20,
            "the exact binomial sampler returned \(binomial), far below the mode"
        )
    }

    /// The exact samplers do not return a far outlier when the cumulative
    /// distribution of the window never exceeds the uniform.
    ///
    /// The sum of the terms of a distribution is one, up to the rounding of
    /// the arithmetic: the cumulative distribution of the walk can stay
    /// below the uniform (by about `1e-13`) when the uniform is the
    /// largest one.  The sampler must then return the **last** `k` of the
    /// walk (the last `k` of a non-negligible probability), and not the
    /// far limit of an unbounded walk.
    func testTheExactSamplersDoNotReturnAFarOutlier() throws {
        let lambda = 137.0
        let variate = ExactSamplers.poisson(lambda: lambda, uniform: 1.0 - 1e-16)
        // The walk of the inversion stops where the probability of the
        // terms is not negligible any more: its upper end is a few
        // standard deviations above the mode, and *not* the far limit of
        // the previous implementation (`mode + 1000 + 20 · √λ`).
        XCTAssertLessThan(
            variate, 400,
            "the exact Poisson sampler returned \(variate), a far outlier"
        )
        XCTAssertGreaterThan(variate, 137, "the variate is above the mode")

        let n = 20_000
        let binomial = ExactSamplers.binomial(n: n, p: 0.5, uniform: 1.0 - 1e-16)
        XCTAssertLessThan(
            binomial, n,
            "the exact binomial sampler returned \(binomial), a far outlier"
        )
    }

    /// The runtime of the exact samplers.
    ///
    /// The walk of the inversion is of the order of √(variance) steps: a
    /// hundred thousand variates of a dense layer (a mean of 2 500) must
    /// be drawn in a few seconds, even in a debug build.
    func testTheExactSamplersAreFast() throws {
        var generator = RandomGenerator(seed: 0x99)
        let start = Date()
        var sum = 0
        for _ in 0..<100_000 {
            sum += generator.poissonExact(2500)
        }
        let elapsed = Date().timeIntervalSince(start)
        print("EXACT the runtime of 100000 exact Poisson variates of a mean "
            + "of 2500: \(elapsed) s (the sum is \(sum))")
        XCTAssertLessThan(
            elapsed, 5.0,
            "the exact Poisson sampler took \(elapsed) s for 100000 variates"
        )
    }

    // MARK: - The upstream fast kernel

    /// The inversion of the upstream fast kernel underflows for the dense
    /// layers of the emulsion.
    ///
    /// The upstream kernel computes `(1 - p) ** n` in double precision: it
    /// underflows to zero when `n · log10(1 - p) < -308` (e.g. 3768
    /// particles per pixel and a probability of development of 0.998), the
    /// cumulative distribution of the inversion then stays at zero and the
    /// kernel returns the **maximum** of the distribution: every particle of
    /// the layer develops.
    ///
    /// The exact sampler does not have that failure mode: its variate has
    /// the mean of the distribution.
    func testTheUnderflowOfTheUpstreamFastInversion() throws {
        let n = 3768
        let p = 0.99828

        // The upstream fast kernel: the inversion of the cumulative
        // distribution underflows and the kernel returns the maximum.
        let fast = FilmCounterRandom.binomial(
            n: n, p: Float(p), seed: 1, pixel: 0, layer: 0, channel: 0
        )
        XCTAssertEqual(fast, n, "the fast kernel returns the maximum of the distribution")

        // The exact sampler: the variate has the mean of the distribution.
        var generator = RandomGenerator(seed: 0x1234)
        var sum = 0.0
        let count = 20_000
        for _ in 0..<count {
            sum += Double(generator.binomialExact(n: n, p: p))
        }
        let mean = sum / Double(count)
        let standardError = (Double(n) * p * (1 - p)).squareRoot() / Double(count).squareRoot()
        XCTAssertEqual(
            mean, Double(n) * p,
            accuracy: tolerance * standardError,
            "the exact sampler has the mean of the distribution"
        )
        XCTAssertLessThan(
            mean, Double(n) - 1,
            "the exact sampler does not develop every particle"
        )
    }

    /// The counter based exact sampler is a pure function of its counter,
    /// like the fast one.
    func testTheCounterBasedExactSamplerIsReproducible() throws {
        let first = FilmCounterRandom.binomialExact(
            n: 1000, p: 0.5, seed: 7, pixel: 3, layer: 1, channel: 2
        )
        let second = FilmCounterRandom.binomialExact(
            n: 1000, p: 0.5, seed: 7, pixel: 3, layer: 1, channel: 2
        )
        XCTAssertEqual(first, second, "the counter based exact sampler is reproducible")

        let poisson = FilmCounterRandom.poissonExact(
            lambda: 250, seed: 7, pixel: 3, layer: 1, channel: 2
        )
        XCTAssertEqual(
            poisson,
            FilmCounterRandom.poissonExact(
                lambda: 250, seed: 7, pixel: 3, layer: 1, channel: 2
            ),
            "the counter based exact Poisson sampler is reproducible"
        )
    }

    /// The exact samplers draw from the exact distributions: every `k`
    /// owns an interval of the uniform of the length `P(k)`.
    ///
    /// The check compares the **empirical** cumulative distribution with
    /// the theoretical one (a direct sum of the probabilities, computed
    /// here independently of the algorithm of the samplers).
    func testTheExactSamplersAreExact() throws {
        let count = 200_000

        // The Poisson, the mean of the distribution.
        let lambda = 42.0
        var generator = RandomGenerator(seed: 0x5EED)
        var hits = 0
        for _ in 0..<count {
            if generator.poissonExact(lambda) <= 42 { hits += 1 }
        }
        let empirical = Double(hits) / Double(count)
        let theoretical = Self.poissonCDF(lambda: lambda, k: 42)
        let standardError = (theoretical * (1 - theoretical) / Double(count)).squareRoot()
        XCTAssertEqual(
            empirical, theoretical, accuracy: 5 * standardError,
            "the exact Poisson sampler draws from the exact distribution"
        )

        // The binomial, the mean of the distribution.
        let n = 300
        let p = 0.41
        generator = RandomGenerator(seed: 0xBEEF)
        hits = 0
        for _ in 0..<count {
            if generator.binomialExact(n: n, p: p) <= 120 { hits += 1 }
        }
        let empiricalBinomial = Double(hits) / Double(count)
        let theoreticalBinomial = Self.binomialCDF(n: n, p: p, k: 120)
        let binomialError = (
            theoreticalBinomial * (1 - theoreticalBinomial) / Double(count)
        ).squareRoot()
        XCTAssertEqual(
            empiricalBinomial, theoreticalBinomial, accuracy: 5 * binomialError,
            "the exact binomial sampler draws from the exact distribution"
        )
    }

    /// The cumulative distribution of a Poisson distribution, computed by a
    /// direct sum (independently of the algorithm of the samplers).
    private static func poissonCDF(lambda: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        var total = 0.0
        for index in 0...k {
            total += poissonProbability(lambda: lambda, k: index)
        }
        return total
    }

    /// The cumulative distribution of a binomial distribution, computed by
    /// a direct sum (independently of the algorithm of the samplers).
    private static func binomialCDF(n: Int, p: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        var total = 0.0
        for index in 0...min(k, n) {
            total += binomialProbability(n: n, k: index, p: p)
        }
        return total
    }
}
