//
//  FilmCounterRandom.swift
//  light suffer胶片 — iOS app
//
//  The counter based random number generator of the GPU port.
//
//  The CPU reference draws its random variates from a **sequential** stream
//  (xoshiro256\*\*), so the value of a variate depends on the order of the
//  draws.  A GPU pipeline has no such order: the pixels are processed in
//  parallel and in an arbitrary order.  The GPU port therefore uses a
//  **counter based** generator: every variate is a pure function of
//  `(seed, pixel, layer, channel, stream)`, so the field does not depend on
//  the order of the pixels and every pixel can be computed independently.
//
//  This file is the **executable specification** of the Metal kernels of
//  `Sources/FilmPhysicsMetal/Shaders/FilmShaders.metal`: the hash, the
//  uniforms and the variate samplers below are transliterated one to one
//  into the shading language.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The counter based random number generator of the GPU port.
///
/// The generator is a **hash of a counter**: the variate of a pixel is a
/// pure function of the seed, of the index of the pixel, of the emulsion
/// layer, of the channel and of the *stream* (the index of the variate
/// inside the pixel).  Two properties follow from it:
///
/// * the field does **not** depend on the order of the pixels: the GPU and
///   the CPU reference compute the same field for the same seed,
/// * every pixel is independent: the generator can be evaluated in any
///   order, in any number of threads, on any device.
///
/// The hash is the 32 bit avalanche finaliser of Chris Wellons
/// (`lowbias32`), the counter is mixed with the odd constants of the
/// golden ratio, and the uniforms use the 24 high bits of the hash (the
/// resolution of a `float` mantissa).
///
/// The variate samplers mirror the **fast kernels** of the upstream engine
/// (`spektrafilm.utils.fast_stats`), i.e. the ones the CPU reference
/// reproduces (see ``RandomGenerator``): the same algorithms, a different
/// source of randomness.  The distributions are therefore identical; only
/// the realisation is different.
public enum FilmCounterRandom {

    /// The number of the streams of the micro structure (the grain of the
    /// negative uses the streams below).
    public enum Stream {
        /// The Poisson variate of a pixel.
        public static let poisson: UInt32 = 0x1000
        /// The first uniform of the normal variate of the Poisson.
        public static let poissonNormalA: UInt32 = 0x2000
        /// The second uniform of the normal variate of the Poisson.
        public static let poissonNormalB: UInt32 = 0x2001
        /// The binomial variate of a pixel (the direct simulation).
        public static let binomial: UInt32 = 0x3000
        /// The first uniform of the normal variate of the binomial.
        public static let binomialNormalA: UInt32 = 0x4000
        /// The second uniform of the normal variate of the binomial.
        public static let binomialNormalB: UInt32 = 0x4001
        /// The inversion of the cumulative distribution of the binomial.
        public static let binomialInversion: UInt32 = 0x4002
        /// The lognormal variate of the micro structure.
        public static let microStructureA: UInt32 = 0x5000
        /// The second uniform of the lognormal variate.
        public static let microStructureB: UInt32 = 0x5001
        /// The first half of the uniform of the exact Poisson variate.
        public static let poissonExactA: UInt32 = 0x6000
        /// The second half of the uniform of the exact Poisson variate.
        public static let poissonExactB: UInt32 = 0x6001
        /// The first half of the uniform of the exact binomial variate.
        public static let binomialExactA: UInt32 = 0x7000
        /// The second half of the uniform of the exact binomial variate.
        public static let binomialExactB: UInt32 = 0x7001
    }

    // MARK: - The hash

    /// The 32 bit avalanche hash of a word.
    ///
    /// - Parameter value: the word to hash.
    /// - Returns: the hash.
    @inline(__always)
    public static func hash32(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x = x &* 0x7FEB_352D
        x ^= x >> 15
        x = x &* 0x846C_A68B
        x ^= x >> 16
        return x
    }

    /// The hash of a counter.
    ///
    /// - Parameters:
    ///   - seed: the seed of the stream (the low 32 bits of the seed of the
    ///     pipeline).
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    ///   - stream: the index of the variate inside the pixel.
    /// - Returns: the hash of the counter.
    @inline(__always)
    public static func counter(
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32,
        stream: UInt32
    ) -> UInt32 {
        var hash = hash32(seed &+ 0x9E37_79B9)
        hash = hash32(hash ^ (pixel &* 0x85EB_CA6B))
        hash = hash32(hash ^ (layer &* 0xC2B2_AE35))
        hash = hash32(hash ^ (channel &* 0x27D4_EB2F))
        hash = hash32(hash ^ (stream &* 0x1656_67B1))
        return hash
    }

    /// A uniform variate in `[0, 1)` from a hash.
    ///
    /// The 24 high bits of the hash are used: they are the ones a `float`
    /// can represent exactly.
    ///
    /// - Parameter hash: the hash of the counter.
    /// - Returns: the variate.
    @inline(__always)
    public static func uniform(_ hash: UInt32) -> Float {
        Float(hash >> 8) * (1.0 / 16_777_216.0)
    }

    /// A uniform variate in `[0, 1)` with the resolution of a double.
    ///
    /// The 53 high bits of two hashes are used: the exact samplers of the
    /// grain (``ExactSamplers``) invert the cumulative distribution, and
    /// the resolution of a single `float` would distort the tails of the
    /// distribution.
    ///
    /// - Parameters:
    ///   - first: the hash of the high bits.
    ///   - second: the hash of the low bits.
    /// - Returns: the variate.
    @inline(__always)
    public static func uniform53(_ first: UInt32, _ second: UInt32) -> Double {
        let high = UInt64(first >> 5)
        let low = UInt64(second >> 6)
        return Double(high * (UInt64(1) << 26) + low) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A standard normal variate from two hashes.
    ///
    /// The Box-Muller transform: it is the exact inverse of the normal
    /// distribution function and it needs exactly two uniforms, which is
    /// what a counter based generator can afford.
    ///
    /// - Parameters:
    ///   - first: the hash of the first uniform.
    ///   - second: the hash of the second uniform.
    /// - Returns: the variate.
    @inline(__always)
    public static func normal(first: UInt32, second: UInt32) -> Float {
        let u1 = Swift.max(uniform(first), 1e-7)
        let u2 = uniform(second)
        return (-2.0 * log(u1)).squareRoot() * cos(2.0 * Float.pi * u2)
    }

    // MARK: - The variate samplers

    /// A Poisson variate.
    ///
    /// The algorithm is the one of the upstream fast kernel
    /// (`spektrafilm.utils.fast_stats.fast_poisson`), the one the CPU
    /// reference reproduces: Knuth's product method below a mean of thirty,
    /// a normal approximation above it.
    ///
    /// - Parameters:
    ///   - lambda: the mean of the distribution.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the variate.
    public static func poisson(
        lambda: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda < 30.0 {
            // Knuth's product method: the number of uniforms below
            // `exp(-lambda)`.
            let limit = exp(-lambda)
            var product: Float = 1.0
            var k = 0
            repeat {
                product *= uniform(
                    counter(
                        seed: seed, pixel: pixel, layer: layer, channel: channel,
                        stream: Stream.poisson &+ UInt32(k)
                    )
                )
                k += 1
            } while product > limit && k < 1000
            return k - 1
        }
        // The normal approximation of the upstream.
        let z = normal(
            first: counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.poissonNormalA
            ),
            second: counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.poissonNormalB
            )
        )
        let sample = (lambda + lambda.squareRoot() * z).rounded(.toNearestOrEven)
        return Swift.max(0, Int(sample))
    }

    /// A binomial variate.
    ///
    /// The algorithm is the one of the upstream fast kernel
    /// (`spektrafilm.utils.fast_stats.fast_binomial`), the one the CPU
    /// reference reproduces: a direct simulation below twenty five trials,
    /// a normal approximation when the variance of the distribution is above
    /// ten, the inversion of the cumulative distribution otherwise.
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - p: the probability of a success.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the number of successes.
    public static func binomial(
        n: Int,
        p: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Int {
        guard n > 0, p > 0 else { return 0 }
        guard p < 1 else { return n }
        if n < 25 {
            // The direct simulation of the upstream.
            var count = 0
            for trial in 0..<n {
                let variate = uniform(
                    counter(
                        seed: seed, pixel: pixel, layer: layer, channel: channel,
                        stream: Stream.binomial &+ UInt32(trial)
                    )
                )
                if variate < p { count += 1 }
            }
            return count
        }
        let mean = Float(n) * p
        let variance = Float(n) * p * (1.0 - p)
        if variance > 10.0 {
            // The normal approximation of the upstream.
            let z = normal(
                first: counter(
                    seed: seed, pixel: pixel, layer: layer, channel: channel,
                    stream: Stream.binomialNormalA
                ),
                second: counter(
                    seed: seed, pixel: pixel, layer: layer, channel: channel,
                    stream: Stream.binomialNormalB
                )
            )
            let sample = (mean + variance.squareRoot() * z).rounded(.toNearestOrEven)
            return Swift.min(Swift.max(Int(sample), 0), n)
        }
        // The inversion of the cumulative distribution.
        let q = 1.0 - p
        let ratio = p / q
        let u = uniform(
            counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.binomialInversion
            )
        )
        var cdf: Float = 0.0
        var probability = pow(q, Float(n))
        var k = 0
        while cdf < u && k <= n {
            cdf += probability
            if k < n {
                probability *= Float(n - k) / Float(k + 1) * ratio
            }
            k += 1
        }
        return k - 1
    }

    /// An exact Poisson variate.
    ///
    /// The variate is drawn from the **exact** Poisson distribution, i.e.
    /// the distribution of the default path of the upstream (the SciPy
    /// `poisson` generator), and not from the normal approximation of the
    /// fast kernel of the upstream.
    ///
    /// The uniform variate has the resolution of a double (the exact
    /// samplers invert the cumulative distribution, and the resolution of a
    /// single `float` would distort the tails of the distribution).
    ///
    /// - Parameters:
    ///   - lambda: the mean of the distribution.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the variate.
    public static func poissonExact(
        lambda: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Int {
        guard lambda > 0 else { return 0 }
        let u = uniform53(
            counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.poissonExactA
            ),
            counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.poissonExactB
            )
        )
        return ExactSamplers.poisson(lambda: Double(lambda), uniform: u)
    }

    /// An exact binomial variate.
    ///
    /// The variate is drawn from the **exact** binomial distribution, i.e.
    /// the distribution of the default path of the upstream (the SciPy
    /// `binom` generator), and not from the normal approximation of the
    /// fast kernel of the upstream.
    ///
    /// - Parameters:
    ///   - n: the number of trials.
    ///   - p: the probability of a success.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the number of successes.
    public static func binomialExact(
        n: Int,
        p: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Int {
        guard n > 0, p > 0 else { return 0 }
        guard p < 1 else { return n }
        let u = uniform53(
            counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.binomialExactA
            ),
            counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.binomialExactB
            )
        )
        return ExactSamplers.binomial(n: n, p: Double(p), uniform: u)
    }

    /// A lognormal variate with the given parameters of the underlying
    /// normal.
    ///
    /// The algorithm is the one of the upstream fast kernel
    /// (`spektrafilm.utils.fast_stats.fast_lognormal`).
    ///
    /// - Parameters:
    ///   - mu: the mean of the underlying normal.
    ///   - sigma: the standard deviation of the underlying normal.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the variate.
    public static func lognormal(
        mu: Float,
        sigma: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Float {
        if sigma < 1e-6 {
            // The upstream avoids the numerical noise of the normal draw.
            return exp(mu)
        }
        let z = normal(
            first: counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.microStructureA
            ),
            second: counter(
                seed: seed, pixel: pixel, layer: layer, channel: channel,
                stream: Stream.microStructureB
            )
        )
        return exp(mu + sigma * z)
    }

    /// A lognormal variate with the given mean and standard deviation in
    /// linear space.
    ///
    /// - Parameters:
    ///   - mean: the mean of the variate, in linear space.
    ///   - std: the standard deviation of the variate, in linear space.
    ///   - seed: the seed of the stream.
    ///   - pixel: the index of the pixel.
    ///   - layer: the index of the emulsion layer.
    ///   - channel: the index of the colour channel.
    /// - Returns: the variate.
    public static func lognormalFromMeanStd(
        mean: Float,
        std: Float,
        seed: UInt32,
        pixel: UInt32,
        layer: UInt32,
        channel: UInt32
    ) -> Float {
        var mu: Float = 0.0
        var sigma: Float = 0.0
        if mean > 0 {
            let sigmaSquared = log(1.0 + (std * std) / (mean * mean))
            sigma = sigmaSquared.squareRoot()
            mu = log(mean) - sigmaSquared / 2.0
        }
        return lognormal(
            mu: mu, sigma: sigma, seed: seed, pixel: pixel, layer: layer, channel: channel
        )
    }
}
