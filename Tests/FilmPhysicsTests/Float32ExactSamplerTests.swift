//
//  Float32ExactSamplerTests.swift
//  light suffer胶片 — iOS app
//
//  The unit tests of the exact samplers of the grain in **single
//  precision** (``Float32ExactSamplers``).
//
//  The file is the executable specification of the Metal kernels
//  `filmPoissonExact` and `filmBinomialExact` of
//  `Sources/FilmPhysicsMetal/Shaders/FilmShaders.metal`: the kernels
//  cannot run on Linux (there is no GPU here), so the algorithm of the
//  shading language is validated **here**, in the same arithmetic.
//
//  The tests check:
//
//  * the **law** of the samplers (a chi-square test against the exact
//    distributions, computed independently of the code of the samplers),
//  * the **moments** of the samplers (the mean and the variance of the
//    distributions),
//  * the **agreement** with the double precision samplers
//    (``ExactSamplers``): the single precision inversion must resolve the
//    same variates, except for the uniforms that fall on a boundary of the
//    cumulative distribution,
//  * the **consistency** of the inversion (`F(k - 1) ≤ u < F(k)`),
//  * the **failure mode of the fast kernel** (the underflow of the
//    inversion of the upstream, which develops every particle of the dense
//    layers of the emulsion) must **not** happen in the exact mode.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class Float32ExactSamplerTests: XCTestCase {

    /// The number of the variates of the statistical checks.
    private let samples = 100_000

    /// The tolerance of the statistical checks, in standard errors.
    private let tolerance = 5.0

    // MARK: - The helpers

    /// The probability of a Poisson distribution, computed by the **direct**
    /// formula (independently of the code of the samplers), in double
    /// precision.
    private static func poissonProbability(lambda: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        return exp(
            -lambda + Double(k) * log(lambda) - Numerics.logGamma(Double(k) + 1)
        )
    }

    /// The probability of a binomial distribution, computed by the **direct**
    /// formula (independently of the code of the samplers), in double
    /// precision.
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

    /// The cumulative distribution function of a Poisson distribution, by a
    /// direct sum (independently of the algorithm of the samplers).
    private static func poissonCDF(lambda: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        var total = 0.0
        for index in 0...k {
            total += poissonProbability(lambda: lambda, k: index)
        }
        return total
    }

    /// The cumulative distribution function of a binomial distribution, by a
    /// direct sum (independently of the algorithm of the samplers).
    private static func binomialCDF(n: Int, p: Double, k: Int) -> Double {
        guard k >= 0 else { return 0 }
        var total = 0.0
        for index in 0...min(k, n) {
            total += binomialProbability(n: n, k: index, p: p)
        }
        return total
    }

    /// The chi-square statistic of an empirical distribution against an
    /// exact one.
    ///
    /// The buckets whose expected count is below five are **merged** into
    /// the last one (the standard practice).
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
    private static func chiSquareProbability(
        _ statistic: Double, degreesOfFreedom: Int
    ) -> Double {
        let k = Double(degreesOfFreedom)
        let z = (pow(statistic / k, 1.0 / 3.0) - (1 - 2 / (9 * k)))
            / (2 / (9 * k)).squareRoot()
        return 1 - Numerics.normalCDF(z)
    }

    /// A uniform variate in `[0, 1)` with the resolution of a single
    /// precision (the resolution of the GPU).
    private func uniform32(_ index: Int) -> Float {
        Float((index &* 2_654_435_761) % 16_777_216) * (1.0 / 16_777_216.0)
    }

    // MARK: - The moments

    /// The single precision Poisson variate has the mean and the variance
    /// of the distribution.
    func testTheSinglePrecisionPoissonHasTheTheoreticalMoments() throws {
        let lambda: Float = 137
        var generator = RandomGenerator(seed: 0xC0FFEE)
        var sum: Double = 0
        var squares: Double = 0
        for _ in 0..<samples {
            let variate = Double(
                Float32ExactSamplers.poisson(lambda: lambda, uniform: Float(generator.uniform()))
            )
            sum += variate
            squares += variate * variate
        }
        let mean = sum / Double(samples)
        let variance = squares / Double(samples) - mean * mean
        let standardError = Double(lambda).squareRoot() / Double(samples).squareRoot()
        XCTAssertEqual(mean, Double(lambda), accuracy: tolerance * standardError)
        XCTAssertEqual(variance, Double(lambda), accuracy: tolerance * 2 * standardError)
    }

    /// The single precision binomial variate has the mean and the variance
    /// of the distribution.
    func testTheSinglePrecisionBinomialHasTheTheoreticalMoments() throws {
        let n = 400
        let p: Float = 0.73
        var generator = RandomGenerator(seed: 0xBEEF)
        var sum: Double = 0
        var squares: Double = 0
        for _ in 0..<samples {
            let variate = Double(
                Float32ExactSamplers.binomial(n: n, p: p, uniform: Float(generator.uniform()))
            )
            sum += variate
            squares += variate * variate
        }
        let mean = sum / Double(samples)
        let variance = squares / Double(samples) - mean * mean
        let standardError = (Double(n) * Double(p) * (1 - Double(p))).squareRoot()
            / Double(samples).squareRoot()
        XCTAssertEqual(mean, Double(n) * Double(p), accuracy: tolerance * standardError)
        XCTAssertEqual(
            variance, Double(n) * Double(p) * (1 - Double(p)),
            accuracy: tolerance * 2 * standardError * (1 + Double(n) * Double(p)
                * (1 - Double(p))).squareRoot()
        )
    }

    // MARK: - The law of the samplers

    /// The law of the single precision Poisson variate is the law of the
    /// distribution.
    ///
    /// The test is a **chi-square** test of the empirical distribution
    /// against the exact one (the probabilities are computed by the direct
    /// formula, in double precision).
    func testTheSinglePrecisionPoissonFollowsTheTheoreticalDistribution() throws {
        for lambda in [3.5, 2500.0] {
            let count = 100_000
            var generator = RandomGenerator(seed: 0x5EED)
            let mode = Int(floor(lambda))
            let lower = mode - Int(6 * lambda.squareRoot()) - 10
            let upper = mode + Int(6 * lambda.squareRoot()) + 10
            var counts = [Int](repeating: 0, count: max(upper - lower + 1, 1))
            var outside = 0
            for _ in 0..<count {
                let variate = Float32ExactSamplers.poisson(
                    lambda: Float(lambda), uniform: Float(generator.uniform())
                )
                if variate >= lower && variate <= upper {
                    counts[variate - lower] += 1
                } else {
                    outside += 1
                }
            }
            var expected = [Double](repeating: 0, count: counts.count)
            for index in 0..<counts.count {
                expected[index] = Double(count) * Self.poissonProbability(
                    lambda: lambda, k: lower + index
                )
            }
            expected[expected.count - 1] += Double(outside)
            // The buckets of the small Poisson leave a tail of the order of
            // `1e-5` of probability (the variate of the last uniform of
            // the range falls outside of them): the check is that the tail
            // stays negligible, not that it vanishes.
            XCTAssertLessThan(
                Double(outside) / Double(count), 1e-4,
                "the mass outside of the buckets of the Poisson(\(lambda))"
            )
            let chi = Self.chiSquare(counts: counts, expected: expected)
            let probability = Self.chiSquareProbability(
                chi.statistic, degreesOfFreedom: chi.degreesOfFreedom
            )
            print("FLOAT32-EXACT poisson(\(lambda)): the chi-square is "
                + "\(chi.statistic) for \(chi.degreesOfFreedom) degrees of "
                + "freedom, the probability is \(probability)")
            XCTAssertGreaterThan(
                probability, 1e-3,
                "the law of the single precision Poisson(\(lambda)) is not the "
                    + "law of the distribution (the chi-square is \(chi.statistic))"
            )
        }
    }

    /// The law of the single precision binomial variate is the law of the
    /// distribution.
    ///
    /// The dense layer of the emulsion (a probability of development of
    /// 0.998 and 3 768 particles per pixel) is one of the cases: it is the
    /// one the fast kernel of the upstream gets wrong.
    func testTheSinglePrecisionBinomialFollowsTheTheoreticalDistribution() throws {
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
                let variate = Float32ExactSamplers.binomial(
                    n: n, p: Float(p), uniform: Float(generator.uniform())
                )
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
            print("FLOAT32-EXACT binomial(\(n), \(p)): the chi-square is "
                + "\(chi.statistic) for \(chi.degreesOfFreedom) degrees of "
                + "freedom, the probability is \(probability)")
            XCTAssertGreaterThan(
                probability, 1e-3,
                "the law of the single precision binomial(\(n), \(p)) is not "
                    + "the law of the distribution (the chi-square is \(chi.statistic))"
            )
        }
    }

    // MARK: - The agreement with the double precision samplers

    /// The single precision samplers resolve the same variates as the
    /// double precision ones.
    ///
    /// The two implementations use the same algorithm and the same
    /// uniforms: they can only differ when the uniform falls on a boundary
    /// of the cumulative distribution (the resolution of the single
    /// precision is `1e-5` of probability, the resolution of the double
    /// precision is `1e-15`).
    func testTheSinglePrecisionSamplersAgreeWithTheDoublePrecisionOnes() throws {
        // The Poisson.
        for lambda in [3.5, 137.0, 2500.0] {
            var differences = 0
            let count = 20_000
            for index in 0..<count {
                let uniform = uniform32(index)
                let single = Float32ExactSamplers.poisson(
                    lambda: Float(lambda), uniform: uniform
                )
                let double = ExactSamplers.poisson(
                    lambda: lambda, uniform: Double(uniform)
                )
                if single != double { differences += 1 }
            }
            let rate = Double(differences) / Double(count)
            print("FLOAT32-EXACT poisson(\(lambda)): the single precision "
                + "sampler differs from the double precision one on \(rate) "
                + "of the uniforms")
            XCTAssertLessThan(
                rate, 1e-3,
                "the single precision Poisson(\(lambda)) differs from the "
                    + "double precision one on \(rate) of the uniforms"
            )
        }
        // The binomial.
        for (n, p) in [(40, 0.3), (400, 0.73), (3768, 0.99828)] {
            var differences = 0
            let count = 20_000
            for index in 0..<count {
                let uniform = uniform32(index)
                let single = Float32ExactSamplers.binomial(
                    n: n, p: Float(p), uniform: uniform
                )
                let double = ExactSamplers.binomial(
                    n: n, p: p, uniform: Double(uniform)
                )
                if single != double { differences += 1 }
            }
            let rate = Double(differences) / Double(count)
            print("FLOAT32-EXACT binomial(\(n), \(p)): the single precision "
                + "sampler differs from the double precision one on \(rate) "
                + "of the uniforms")
            XCTAssertLessThan(
                rate, 1e-3,
                "the single precision binomial(\(n), \(p)) differs from the "
                    + "double precision one on \(rate) of the uniforms"
            )
        }
    }

    // MARK: - The counter based samplers

    /// The counter based single precision samplers agree with the counter
    /// based double precision ones.
    ///
    /// The two draw their uniform from the **same** hash (the 24 high bits
    /// of the first stream of the exact Poisson and of the exact binomial
    /// are the 24 high bits of the 53 bit uniform of the double precision
    /// samplers), so the variates must be the same, except for the
    /// uniforms that fall on a boundary of the cumulative distribution.
    ///
    /// This is the property the Metal parity test relies on: the exact
    /// grain of the GPU and the exact grain of the CPU reference draw
    /// from the same uniforms.
    func testTheCounterBasedSinglePrecisionSamplersAgreeWithTheDoublePrecisionOnes() throws {
        var differences = 0
        let count = 20_000
        for pixel in 0..<count {
            let poissonSingle = FilmCounterRandom.poissonExactFloat32(
                lambda: 250, seed: 7, pixel: UInt32(pixel), layer: 1, channel: 2
            )
            let poissonDouble = FilmCounterRandom.poissonExact(
                lambda: 250, seed: 7, pixel: UInt32(pixel), layer: 1, channel: 2
            )
            if poissonSingle != poissonDouble { differences += 1 }

            let binomialSingle = FilmCounterRandom.binomialExactFloat32(
                n: 3768, p: 0.99828, seed: 7, pixel: UInt32(pixel), layer: 1, channel: 2
            )
            let binomialDouble = FilmCounterRandom.binomialExact(
                n: 3768, p: 0.99828, seed: 7, pixel: UInt32(pixel), layer: 1, channel: 2
            )
            if binomialSingle != binomialDouble { differences += 1 }
        }
        let rate = Double(differences) / Double(2 * count)
        print("FLOAT32-EXACT the counter based samplers: the single precision "
            + "samplers differ from the double precision ones on \(rate) of "
            + "the variates")
        XCTAssertLessThan(
            rate, 1e-3,
            "the counter based single precision samplers differ from the "
                + "double precision ones on \(rate) of the variates"
        )
    }

    // MARK: - The consistency of the inversion

    /// The single precision inversion is consistent.
    ///
    /// The variate `k` of a uniform `u` is the smallest `k` whose
    /// cumulative distribution exceeds `u`, i.e. `F(k - 1) ≤ u < F(k)`.
    func testTheSinglePrecisionInversionIsConsistent() throws {
        // The Poisson.
        let lambda = 137.0
        for uniform in [0.0, 1e-6, 0.1, 0.5, 0.9, 0.99, 0.999, 1.0 - 1e-7] {
            let variate = Float32ExactSamplers.poisson(
                lambda: Float(lambda), uniform: Float(uniform)
            )
            let below = Self.poissonCDF(lambda: lambda, k: variate - 1)
            let at = Self.poissonCDF(lambda: lambda, k: variate)
            XCTAssertLessThanOrEqual(
                below, uniform + 1e-5,
                "the Poisson(\(lambda)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k - 1) is \(below)"
            )
            XCTAssertGreaterThanOrEqual(
                at, uniform - 1e-5,
                "the Poisson(\(lambda)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k) is \(at)"
            )
        }
        // The binomial.
        let n = 20
        let p = 0.5
        for uniform in [0.0, 1e-6, 0.1, 0.5, 0.9, 0.99, 0.999, 1.0 - 1e-7] {
            let variate = Float32ExactSamplers.binomial(
                n: n, p: Float(p), uniform: Float(uniform)
            )
            let below = Self.binomialCDF(n: n, p: p, k: variate - 1)
            let at = Self.binomialCDF(n: n, p: p, k: variate)
            XCTAssertLessThanOrEqual(
                below, uniform + 1e-5,
                "the binomial(\(n), \(p)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k - 1) is \(below)"
            )
            XCTAssertGreaterThanOrEqual(
                at, uniform - 1e-5,
                "the binomial(\(n), \(p)) returned \(variate) for the uniform "
                    + "\(uniform), but F(k) is \(at)"
            )
        }
    }

    /// The single precision samplers do not return a far outlier.
    ///
    /// The tail of the range of the uniforms is the case the inversion
    /// cannot resolve: the variate must then be the **last** `k` whose
    /// probability is not negligible, and not the far limit of an
    /// unbounded walk.
    func testTheSinglePrecisionSamplersDoNotReturnAFarOutlier() throws {
        let lambda: Float = 137
        let variate = Float32ExactSamplers.poisson(
            lambda: lambda, uniform: Float32ExactSamplers.maximumUniform
        )
        XCTAssertLessThan(
            variate, 400,
            "the single precision Poisson sampler returned \(variate), a far outlier"
        )
        XCTAssertGreaterThan(variate, 137, "the variate is above the mode")

        let binomial = Float32ExactSamplers.binomial(
            n: 20_000, p: 0.5, uniform: Float32ExactSamplers.maximumUniform
        )
        XCTAssertLessThan(
            binomial, 20_000,
            "the single precision binomial sampler returned \(binomial), a far outlier"
        )
    }

    /// The exact mode does not have the failure mode of the fast kernel of
    /// the upstream.
    ///
    /// The fast kernel computes `(1 - p) ** n` in double precision: it
    /// underflows to zero for the dense layers of the emulsion, the
    /// cumulative distribution never accumulates and the kernel returns the
    /// **maximum** of the distribution (every particle develops).  The
    /// exact samplers, in single precision as in double precision, do not
    /// have that failure mode.
    func testTheSinglePrecisionExactSamplerDoesNotUnderflow() throws {
        let n = 3768
        let p: Float = 0.99828

        // The fast kernel: the inversion underflows and the kernel returns
        // the maximum of the distribution.
        let fast = FilmCounterRandom.binomial(
            n: n, p: p, seed: 1, pixel: 0, layer: 0, channel: 0
        )
        XCTAssertEqual(
            fast, n,
            "the fast kernel returns the maximum of the distribution"
        )

        // The exact sampler, in single precision: the variate has the mean
        // of the distribution.
        var sum: Double = 0
        let count = 20_000
        for index in 0..<count {
            sum += Double(
                Float32ExactSamplers.binomial(
                    n: n, p: p, uniform: uniform32(index)
                )
            )
        }
        let mean = sum / Double(count)
        let standardError = (Double(n) * Double(p) * (1 - Double(p))).squareRoot()
            / Double(count).squareRoot()
        XCTAssertEqual(
            mean, Double(n) * Double(p), accuracy: tolerance * standardError,
            "the single precision exact sampler has the mean of the distribution"
        )
        XCTAssertLessThan(
            mean, Double(n) - 1,
            "the single precision exact sampler develops every particle"
        )
    }
}
