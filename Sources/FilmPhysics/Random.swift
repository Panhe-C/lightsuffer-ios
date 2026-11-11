//
//  Random.swift
//  light suffer胶片 — iOS app
//
//  The random number generator and the random variate samplers of the two
//  stochastic effects of the upstream engine (the grain of the negative and
//  the glare of the print).
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// A fast, seedable and portable pseudo random number generator.
///
/// The upstream engine has **no reproducible** stochastic path: the grain
/// reseeds the *global* legacy NumPy random state with a fixed seed
/// (`[0, 1, 2]` per channel, `+ 10` per sub layer) and the glare draws from
/// the *unseeded* global state. A port therefore needs its own generator,
/// with an **explicit seed**.
///
/// The port uses **xoshiro256\*\*** (Blackman & Vigna, 2018) seeded with
/// **SplitMix64** (Steele, Lea & Flood, 2014):
///
/// * it is fast (a few nanoseconds per variate) and has a period of
///   2^256,
/// * it passes the usual statistical test batteries (TestU01, PractRand),
/// * it is *exactly* reproducible on every platform: the whole arithmetic is
///   defined on `UInt64` with wrapping operators, so the same seed gives the
///   same stream on Linux, macOS and iOS.
///
/// The samplers below are the distributions the upstream draws from:
/// the uniform, the normal, the Poisson, the binomial and the lognormal.
/// The Poisson and the binomial follow the **fast kernels** of the upstream
/// (`spektrafilm.utils.fast_stats`), i.e. the normal approximations of the
/// exact SciPy generators of the default upstream path — the difference
/// between the two is a model difference, measured and documented in
/// `docs/PORTING.md` (§3.4).
public struct RandomGenerator {

    // MARK: - The state

    /// The four words of the xoshiro256 state.
    private var s0: UInt64
    private var s1: UInt64
    private var s2: UInt64
    private var s3: UInt64

    /// Creates a generator.
    ///
    /// - Parameter seed: the seed of the stream.
    public init(seed: UInt64) {
        var mixer = SplitMix64(seed: seed)
        s0 = mixer.next()
        s1 = mixer.next()
        s2 = mixer.next()
        s3 = mixer.next()
    }

    /// The next 64 bits of the stream.
    public mutating func next() -> UInt64 {
        let result = Self.rotateLeft(s1 &* 5, 7) &* 9
        let t = s1 << 17
        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = Self.rotateLeft(s3, 45)
        return result
    }

    /// Rotates a word to the left.
    ///
    /// - Parameters:
    ///   - value: the word to rotate.
    ///   - amount: the number of bits, between one and sixty three.
    /// - Returns: the rotated word.
    private static func rotateLeft(_ value: UInt64, _ amount: UInt64) -> UInt64 {
        (value << amount) | (value >> (64 - amount))
    }

    // MARK: - The uniform distribution

    /// A uniform variate in `[0, 1)`.
    ///
    /// The 53 high bits of the stream are mapped onto the double range, the
    /// same resolution the legacy NumPy generator uses.
    public mutating func uniform() -> Double {
        Double(next() >> 11) * 0x1.0p-53
    }

    // MARK: - The normal distribution

    /// A standard normal variate.
    ///
    /// Marsaglia's polar method, the method the legacy NumPy generator uses
    /// for `standard_normal`.
    public mutating func normal() -> Double {
        var u = 0.0
        var v = 0.0
        var s = 0.0
        repeat {
            u = uniform() * 2.0 - 1.0
            v = uniform() * 2.0 - 1.0
            s = u * u + v * v
        } while s >= 1.0 || s == 0.0
        return u * (-2.0 * log(s) / s).squareRoot()
    }

    // MARK: - The Poisson distribution

    /// A Poisson variate.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_stats.fast_poisson`.
    ///
    /// The upstream kernel draws the variates below a mean of thirty with
    /// the product method of Knuth and the ones above with a normal
    /// approximation (rounded to the nearest integer, half to even, and
    /// clamped at zero).
    ///
    /// - Parameter lambda: the mean of the distribution.
    /// - Returns: the variate.
    public mutating func poisson(_ lambda: Double) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda < 30.0 {
            // Knuth's product method: the number of uniforms below exp(-lambda).
            let limit = exp(-lambda)
            var product = 1.0
            var k = 0
            repeat {
                product *= uniform()
                k += 1
            } while product > limit
            return k - 1
        }
        // The normal approximation of the upstream.
        let sample = (lambda + lambda.squareRoot() * normal()).rounded(.toNearestOrEven)
        return Swift.max(0, Int(sample))
    }

    /// An exact Poisson variate.
    ///
    /// The variate is drawn from the **exact** Poisson distribution, i.e.
    /// the distribution of the default path of the upstream (the SciPy
    /// `poisson` generator), and not from the normal approximation of the
    /// fast kernel of the upstream.
    ///
    /// Upstream reference: `scipy.stats.poisson.rvs` (the PTRS algorithm of
    /// NumPy); the *distribution* is the one of that generator, the
    /// *realisation* is the one of the port.
    ///
    /// - Parameter lambda: the mean of the distribution.
    /// - Returns: the variate.
    public mutating func poissonExact(_ lambda: Double) -> Int {
        ExactSamplers.poisson(lambda: lambda, uniform: uniform())
    }

    // MARK: - The binomial distribution

    /// A binomial variate.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_stats.fast_binomial`.
    ///
    /// The upstream kernel draws the variates with
    /// * a direct simulation below twenty five trials,
    /// * a normal approximation (rounded to the nearest integer, half to
    ///   even, and clamped to the support) when the variance of the
    ///   distribution is above ten,
    /// * the inversion of the cumulative distribution otherwise.
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - p: the probability of a success.
    /// - Returns: the number of successes.
    public mutating func binomial(n: Int, p: Double) -> Int {
        guard n > 0, p > 0 else { return 0 }
        guard p < 1 else { return n }
        if n < 25 {
            // The direct simulation of the upstream.
            var count = 0
            for _ in 0..<n {
                if uniform() < p { count += 1 }
            }
            return count
        }
        let mean = Double(n) * p
        let variance = Double(n) * p * (1.0 - p)
        if variance > 10.0 {
            // The normal approximation of the upstream.
            let sample = (mean + variance.squareRoot() * normal()).rounded(.toNearestOrEven)
            return Swift.min(Swift.max(Int(sample), 0), n)
        }
        // The inversion of the cumulative distribution.
        let q = 1.0 - p
        let ratio = p / q
        let u = uniform()
        var cdf = 0.0
        var probability = pow(q, Double(n))
        var k = 0
        while cdf < u && k <= n {
            cdf += probability
            if k < n {
                probability *= Double(n - k) / Double(k + 1) * ratio
            }
            k += 1
        }
        return k - 1
    }

    /// An exact binomial variate.
    ///
    /// The variate is drawn from the **exact** binomial distribution, i.e.
    /// the distribution of the default path of the upstream (the SciPy
    /// `binom` generator), and not from the normal approximation of the
    /// fast kernel of the upstream.
    ///
    /// Upstream reference: `scipy.stats.binom.rvs` (the BTPE algorithm of
    /// NumPy); the *distribution* is the one of that generator, the
    /// *realisation* is the one of the port.
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - p: the probability of a success.
    /// - Returns: the number of successes.
    public mutating func binomialExact(n: Int, p: Double) -> Int {
        ExactSamplers.binomial(n: n, p: p, uniform: uniform())
    }

    // MARK: - The lognormal distribution

    /// A lognormal variate with the given parameters of the underlying normal.
    ///
    /// Upstream reference: `spektrafilm.utils.fast_stats.fast_lognormal`.
    ///
    /// - Parameters:
    ///   - mu: the mean of the underlying normal.
    ///   - sigma: the standard deviation of the underlying normal.
    /// - Returns: the variate.
    public mutating func lognormal(mu: Double, sigma: Double) -> Double {
        if sigma < 1e-6 {
            // The upstream avoids the numerical noise of the normal draw.
            return exp(mu)
        }
        return exp(mu + sigma * normal())
    }

    /// A lognormal variate with the given mean and standard deviation in
    /// linear space.
    ///
    /// Upstream reference:
    /// `spektrafilm.utils.fast_stats.fast_lognormal_from_mean_std`.
    ///
    /// - Parameters:
    ///   - mean: the mean of the variate, in linear space.
    ///   - std: the standard deviation of the variate, in linear space.
    /// - Returns: the variate.
    public mutating func lognormalFromMeanStd(mean: Double, std: Double) -> Double {
        var mu = 0.0
        var sigma = 0.0
        if mean > 0 {
            let sigmaSquared = log(1.0 + (std * std) / (mean * mean))
            sigma = sigmaSquared.squareRoot()
            mu = log(mean) - sigmaSquared / 2.0
        }
        return lognormal(mu: mu, sigma: sigma)
    }
}

// MARK: - The seeding helper

/// The SplitMix64 generator, used to seed the xoshiro256 state.
///
/// Upstream reference: the seeding of the generators of
/// `numpy.random.Generator` and of the `randomgen` library.
public struct SplitMix64 {

    private var state: UInt64

    /// Creates the mixer.
    ///
    /// - Parameter seed: the seed of the mixer.
    public init(seed: UInt64) {
        state = seed
    }

    /// The next word of the mixer.
    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// The mixed seed of a stream.
    ///
    /// - Parameter seed: the seed to mix.
    /// - Returns: the mixed seed.
    public static func mix(_ seed: UInt64) -> UInt64 {
        var mixer = SplitMix64(seed: seed)
        return mixer.next()
    }
}

// MARK: - The seeds of the stochastic effects

/// The derivation of the per stream seeds of the stochastic effects.
///
/// The upstream engine uses a **fixed** seed per channel and sub layer of
/// the grain (`[0, 1, 2]` and `+ 10` per sub layer) and an **unseeded**
/// global random state for the glare. The port replaces both by an explicit
/// seed of the pipeline, from which the seed of every stream is derived, so
/// that a render is exactly reproducible.
public enum StochasticSeed {

    /// The seed of the grain of a channel and a sub layer.
    ///
    /// The derivation mirrors the structure of the upstream (`seed[channel] +
    /// 10 * layer`), with the seed of the pipeline in place of the fixed
    /// `[0, 1, 2]` of the upstream.
    ///
    /// - Parameters:
    ///   - seed: the seed of the pipeline.
    ///   - channel: the index of the channel (0 = cyan, 1 = magenta, 2 = yellow).
    ///   - layer: the index of the sub layer.
    /// - Returns: the seed of the stream of the layer.
    public static func grainLayer(seed: UInt64, channel: Int, layer: Int) -> UInt64 {
        SplitMix64.mix(seed &+ UInt64(channel) &+ 10 * UInt64(layer))
    }

    /// The seed of the glare.
    ///
    /// - Parameter seed: the seed of the pipeline.
    /// - Returns: the seed of the stream of the glare.
    public static func glare(seed: UInt64) -> UInt64 {
        SplitMix64.mix(seed ^ 0x676C_6172_6500_0000)
    }
}
