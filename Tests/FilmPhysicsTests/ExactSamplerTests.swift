//
//  ExactSamplerTests.swift
//  light suffer胶片 — iOS app
//
//  The unit tests of the exact samplers of the grain (the inversion of the
//  cumulative distribution, started at the mode of the distribution).
//
//  The samplers must draw from the very same distributions as the SciPy
//  generators of the default path of the upstream (`scipy.stats.poisson.rvs`
//  and `scipy.stats.binom.rvs`): the test checks their mean and their
//  variance against the theoretical ones, and it checks the **difference**
//  with the fast kernels of the upstream — the inversion of the upstream
//  underflows for the dense layers of the emulsion, and the fast kernel
//  then returns the maximum of the distribution (every particle develops).
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
}
