//
//  StatisticsSupport.swift
//  light suffer胶片 — iOS app
//
//  The summary statistics of the stochastic effects, as the slice 6 reference
//  fixture stores them, and the honest statistical gate of the comparison
//  with the upstream.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation
import XCTest
import FilmPhysics

// MARK: - The summary statistics of a field

/// The summary statistics of a stochastic field.
///
/// The statistics are the ones the reference fixture of the slice 6 stores:
/// the mean and the standard deviation of every channel, the autocorrelation
/// of the centred field at a few lags, the correlation of the channels and
/// the quantiles of the density histogram.
struct FieldStatistics {
    /// The mean of every channel.
    var means: [Double]
    /// The standard deviation of every channel.
    var stds: [Double]
    /// The autocorrelation of the centred field, one value per lag.
    var autocorrelation: [Double]
    /// The correlation of the channels: (0, 1), (0, 2) and (1, 2).
    var correlations: [Double]
    /// The quantiles of the density histogram (the three channels pooled).
    var quantiles: [Double]

    /// The statistics as a dictionary, with the keys of the reference.
    ///
    /// - Parameters:
    ///   - lags: the lags of the autocorrelation.
    ///   - quantileLevels: the levels of the quantiles.
    /// - Returns: the statistics.
    func asDictionary(lags: [Int], quantileLevels: [Double]) -> [String: Double] {
        var values: [String: Double] = [:]
        for channel in means.indices {
            values["mean_\(channel)"] = means[channel]
            values["std_\(channel)"] = stds[channel]
        }
        for (index, lag) in lags.enumerated() where index < autocorrelation.count {
            values["acf_\(lag)"] = autocorrelation[index]
        }
        for (index, pair) in [(0, 1), (0, 2), (1, 2)].enumerated()
        where index < correlations.count {
            values["corr_\(pair.0)_\(pair.1)"] = correlations[index]
        }
        for (index, level) in quantileLevels.enumerated() where index < quantiles.count {
            values["q\(String(format: "%02d", Int((level * 100).rounded())))"] = quantiles[index]
        }
        return values
    }
}

/// Computes the summary statistics of a stochastic field.
///
/// - Parameters:
///   - field: the field, three interleaved values per pixel.
///   - width: the width of the field, in pixels.
///   - height: the height of the field, in pixels.
///   - lags: the lags of the autocorrelation, in pixels.
///   - quantileLevels: the levels of the quantiles of the density histogram.
/// - Returns: the statistics of the field.
func fieldStatistics(
    _ field: [Double],
    width: Int,
    height: Int,
    lags: [Int],
    quantileLevels: [Double]
) -> FieldStatistics {
    let channels = 3
    let pixels = width * height

    var means = [Double](repeating: 0, count: channels)
    var stds = [Double](repeating: 0, count: channels)
    var centred = [Double](repeating: 0, count: field.count)
    for channel in 0..<channels {
        var sum = 0.0
        for pixel in 0..<pixels {
            sum += field[pixel * channels + channel]
        }
        let mean = pixels > 0 ? sum / Double(pixels) : 0
        means[channel] = mean
        var variance = 0.0
        for pixel in 0..<pixels {
            let value = field[pixel * channels + channel] - mean
            centred[pixel * channels + channel] = value
            variance += value * value
        }
        stds[channel] = pixels > 0 ? (variance / Double(pixels)).squareRoot() : 0
    }

    var autocorrelation: [Double] = []
    for lag in lags {
        guard lag > 0, lag < width || lag < height else {
            autocorrelation.append(0)
            continue
        }
        var numerator = 0.0
        var denominator = 0.0
        for channel in 0..<channels {
            for row in 0..<height {
                let base = row * width
                for column in 0..<(width - lag) {
                    let left = centred[(base + column) * channels + channel]
                    let right = centred[(base + column + lag) * channels + channel]
                    numerator += left * right
                    denominator += left * left
                }
            }
            for row in 0..<(height - lag) {
                let base = row * width
                let other = (row + lag) * width
                for column in 0..<width {
                    let top = centred[(base + column) * channels + channel]
                    let bottom = centred[(other + column) * channels + channel]
                    numerator += top * bottom
                    denominator += top * top
                }
            }
        }
        autocorrelation.append(denominator > 0 ? numerator / denominator : 0)
    }

    var correlations: [Double] = []
    for (first, second) in [(0, 1), (0, 2), (1, 2)] {
        var covariance = 0.0
        for pixel in 0..<pixels {
            covariance += centred[pixel * channels + first] * centred[pixel * channels + second]
        }
        covariance /= Double(max(pixels, 1))
        let denominator = stds[first] * stds[second]
        correlations.append(denominator > 0 ? covariance / denominator : 0)
    }

    var sorted = field
    sorted.sort()
    var quantiles: [Double] = []
    for level in quantileLevels {
        quantiles.append(quantile(sorted, level: level))
    }

    return FieldStatistics(
        means: means,
        stds: stds,
        autocorrelation: autocorrelation,
        correlations: correlations,
        quantiles: quantiles
    )
}

/// The quantile of a sorted array, with the linear interpolation of NumPy.
///
/// - Parameters:
///   - sorted: the sorted values.
///   - level: the level of the quantile, in `[0, 1]`.
/// - Returns: the quantile.
func quantile(_ sorted: [Double], level: Double) -> Double {
    guard !sorted.isEmpty else { return .nan }
    if sorted.count == 1 { return sorted[0] }
    let position = (Double(sorted.count - 1)) * level
    let low = Int(position.rounded(.down))
    let high = Swift.min(low + 1, sorted.count - 1)
    let fraction = position - Double(low)
    return sorted[low] + fraction * (sorted[high] - sorted[low])
}

// MARK: - The Student t distribution

/// The natural logarithm of the gamma function.
///
/// The Lanczos approximation, the same one the package uses for the normal
/// distribution (the test only needs `logGamma` of a half integer).
///
/// - Parameter z: the argument.
/// - Returns: the natural logarithm of the gamma function.
func logGamma(_ z: Double) -> Double {
    let coefficients: [Double] = [
        676.5203681218851, -1259.1392167224028, 771.32342877765313,
        -176.61502916214059, 12.507343278686905, -0.13857109526572012,
        9.9843695780195716e-6, 1.5056327351493116e-7,
    ]
    if z < 0.5 {
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

/// The continued fraction of the regularised incomplete beta function.
///
/// The classic Lentz expansion of `betacf` (Numerical Recipes).
///
/// - Parameters:
///   - a: the first parameter of the beta function.
///   - b: the second parameter of the beta function.
///   - x: the argument, in `[0, 1)`.
/// - Returns: the continued fraction.
private func betaContinuedFraction(_ a: Double, _ b: Double, _ x: Double) -> Double {
    let epsilon = 3e-16
    let tiny = 1e-300
    let qab = a + b
    let qap = a + 1
    let qam = a - 1
    var c = 1.0
    var d = 1.0 - qab * x / qap
    if abs(d) < tiny { d = tiny }
    d = 1.0 / d
    var h = d
    for m in 1...300 {
        let doubled = 2.0 * Double(m)
        var numerator = Double(m) * (b - Double(m)) * x / ((qam + doubled) * (a + doubled))
        d = 1.0 + numerator * d
        if abs(d) < tiny { d = tiny }
        c = 1.0 + numerator / c
        if abs(c) < tiny { c = tiny }
        d = 1.0 / d
        h *= d * c
        numerator = -(a + Double(m)) * (qab + Double(m)) * x
            / ((a + doubled) * (qap + doubled))
        d = 1.0 + numerator * d
        if abs(d) < tiny { d = tiny }
        c = 1.0 + numerator / c
        if abs(c) < tiny { c = tiny }
        d = 1.0 / d
        let delta = d * c
        h *= delta
        if abs(delta - 1.0) < epsilon { break }
    }
    return h
}

/// The regularised incomplete beta function `I_x(a, b)`.
///
/// - Parameters:
///   - x: the argument, in `[0, 1]`.
///   - a: the first parameter of the beta function.
///   - b: the second parameter of the beta function.
/// - Returns: the regularised incomplete beta function.
func regularizedIncompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    let front = exp(
        logGamma(a + b) - logGamma(a) - logGamma(b)
            + a * log(x) + b * log(1.0 - x)
    )
    if x < (a + 1.0) / (a + b + 2.0) {
        return front * betaContinuedFraction(a, b, x) / a
    }
    return 1.0 - front * betaContinuedFraction(b, a, 1.0 - x) / b
}

/// The cumulative distribution function of the Student t distribution.
///
/// - Parameters:
///   - t: the value.
///   - degreesOfFreedom: the degrees of freedom of the distribution.
/// - Returns: the probability that a Student t variate is below `t`.
func studentTCDF(_ t: Double, degreesOfFreedom: Int) -> Double {
    if t.isNaN { return .nan }
    if degreesOfFreedom <= 0 { return .nan }
    let df = Double(degreesOfFreedom)
    let tail = 0.5 * regularizedIncompleteBeta(
        df / (df + t * t), a: df / 2.0, b: 0.5
    )
    return t > 0 ? 1.0 - tail : tail
}

/// The quantile of the Student t distribution.
///
/// The inverse of ``studentTCDF(_:degreesOfFreedom:)``, by bisection.
///
/// - Parameters:
///   - probability: the probability, in `(0, 1)`.
///   - degreesOfFreedom: the degrees of freedom of the distribution.
/// - Returns: the quantile.
func studentTQuantile(_ probability: Double, degreesOfFreedom: Int) -> Double {
    guard probability > 0, probability < 1 else { return .nan }
    var low = -400.0
    var high = 400.0
    for _ in 0..<200 {
        let middle = 0.5 * (low + high)
        if studentTCDF(middle, degreesOfFreedom: degreesOfFreedom) < probability {
            low = middle
        } else {
            high = middle
        }
    }
    return 0.5 * (low + high)
}

// MARK: - The gate of the statistical comparison

/// The gate of the statistical comparison between the port and the upstream.
///
/// A stochastic effect cannot be compared bit by bit: the upstream draws
/// from the legacy NumPy random state, the port from its own seeded
/// generator.  The comparison is therefore a comparison of the *means* of a
/// statistic over several realisations:
///
/// * the upstream mean `μ` and the upstream spread `σ` are the aggregate the
///   reference fixture stores over its `n` upstream seeds,
/// * the port value is the mean of `m` independent realisations of the port.
///
/// Under the null hypothesis (the port and the upstream draw the same
/// distribution) the difference of the two means is
///
///     port − μ  ~  N(0, σ² · (1/m + 1/n))
///
/// so the standardised difference is
///
///     z = |port − μ| / (σ · sqrt(1/m + 1/n))
///
/// and, because `σ` is itself estimated from the `n` upstream realisations,
/// `z` follows a **Student t with `n − 1` degrees of freedom** under the
/// null.
///
/// The gate is `|z| ≤ k`, with `k` the quantile of that Student t
/// distribution at the level `1 − α / (2 · comparisons)`, where `α` is the
/// family-wise false alarm rate (1 %) and `comparisons` is the number of
/// comparisons of the family (836 for the slice 6: the grain against the two
/// upstream references and the glare against the one).
///
/// The Bonferroni correction is used and not the Šidák one: the statistics
/// of a case are strongly correlated (the mean, the standard deviation and
/// the quantiles of the same field), and the Šidák correction assumes
/// independent tests.
///
/// The gate has **no relative and no absolute tolerance**: the tolerance is
/// entirely determined by the measured spread of the upstream.  The single
/// exception is a statistic whose upstream spread is *below the resolution of
/// the fixture* (the fixtures store seven significant digits): such a
/// statistic carries no information — the upstream spread is then the
/// floating point noise of the upstream computation and not the spread of the
/// statistic — and the comparison falls back to the resolution of the stored
/// values (half of the last significant digit).
struct StatisticalGate {

    /// The family-wise false alarm rate of the family of comparisons.
    static let familyWiseAlpha = 0.01

    /// The number of comparisons of the family.
    let comparisons: Int

    /// The number of upstream realisations (the seeds of the fixture).
    let upstreamSeeds: Int

    /// The number of port realisations.
    let portSeeds: Int

    /// The critical value `k` of the gate.
    let k: Double

    /// Creates the gate of a family of comparisons.
    ///
    /// - Parameters:
    ///   - comparisons: the number of comparisons of the family.
    ///   - upstreamSeeds: the number of upstream realisations.
    ///   - portSeeds: the number of port realisations.
    init(comparisons: Int, upstreamSeeds: Int, portSeeds: Int) {
        self.comparisons = comparisons
        self.upstreamSeeds = upstreamSeeds
        self.portSeeds = portSeeds
        self.k = StatisticalGate.criticalValue(
            comparisons: comparisons, upstreamSeeds: upstreamSeeds
        )
    }

    /// The critical value `k` of the gate.
    ///
    /// The quantile of the Student t distribution with `n − 1` degrees of
    /// freedom at the level `1 − α / (2 · comparisons)`, corrected for the
    /// fact that the fixture stores the *population* standard deviation of
    /// the upstream realisations (the `ddof = 0` convention of NumPy) while
    /// the Student t distribution is calibrated with the unbiased one
    /// (`ddof = 1`).
    ///
    /// - Parameters:
    ///   - comparisons: the number of comparisons of the family.
    ///   - upstreamSeeds: the number of upstream realisations.
    /// - Returns: the critical value.
    static func criticalValue(comparisons: Int, upstreamSeeds: Int) -> Double {
        let alpha = familyWiseAlpha / Double(comparisons)
        let quantile = studentTQuantile(
            1.0 - alpha / 2.0, degreesOfFreedom: upstreamSeeds - 1
        )
        let correction = (Double(upstreamSeeds) / Double(upstreamSeeds - 1)).squareRoot()
        return quantile * correction
    }

    /// The standard deviation of the difference between the port and the
    /// upstream mean.
    ///
    /// - Parameter upstreamStd: the spread of the upstream realisations.
    /// - Returns: the standard deviation of the difference.
    func scale(upstreamStd: Double) -> Double {
        let variance = 1.0 / Double(portSeeds) + 1.0 / Double(upstreamSeeds)
        return upstreamStd * variance.squareRoot()
    }

    /// The z-score of a comparison.
    ///
    /// - Parameters:
    ///   - port: the value of the port (the mean of its realisations).
    ///   - upstreamMean: the mean of the upstream realisations.
    ///   - upstreamStd: the spread of the upstream realisations.
    /// - Returns: the z-score.
    func zScore(port: Double, upstreamMean: Double, upstreamStd: Double) -> Double {
        let scale = self.scale(upstreamStd: upstreamStd)
        guard scale > 0 else { return .infinity }
        return abs(port - upstreamMean) / scale
    }

    /// The z-score of the *single draw* form of the comparison, i.e. the
    /// score of a port value that is one more independent draw of the
    /// upstream distribution instead of the mean of `portSeeds` draws.
    ///
    /// It is the score the review prescribes; it is reported next to the
    /// z-score of the gate, which is the exact one (the port averages
    /// `portSeeds` realisations, so the variance of the difference is
    /// `σ² · (1/portSeeds + 1/upstreamSeeds)`).
    ///
    /// - Parameters:
    ///   - port: the value of the port.
    ///   - upstreamMean: the mean of the upstream realisations.
    ///   - upstreamStd: the spread of the upstream realisations.
    /// - Returns: the z-score.
    func singleDrawZScore(
        port: Double, upstreamMean: Double, upstreamStd: Double
    ) -> Double {
        let scale = upstreamStd * (1.0 + 1.0 / Double(upstreamSeeds)).squareRoot()
        guard scale > 0 else { return .infinity }
        return abs(port - upstreamMean) / scale
    }

    /// The floor of a comparison: the resolution of the stored values.
    ///
    /// The fixtures store every floating point value with seven significant
    /// digits, so a value of magnitude `v` is stored with a granularity of
    /// `10^(floor(log10(v)) − 6)`.  When the spread of the upstream is below
    /// that granularity, the spread carries no information (it is the
    /// floating point noise of the upstream computation) and the comparison
    /// falls back to the resolution of the stored values.
    ///
    /// - Parameters:
    ///   - port: the value of the port.
    ///   - upstreamMean: the mean of the upstream realisations.
    ///   - upstreamStd: the spread of the upstream realisations.
    /// - Returns: the floor of the comparison (zero when the spread of the
    ///   upstream is resolved by the fixture).
    static func resolutionFloor(
        port: Double, upstreamMean: Double, upstreamStd: Double
    ) -> Double {
        let magnitude = Swift.max(abs(port), abs(upstreamMean))
        guard magnitude > 0, magnitude.isFinite else { return 0 }
        let granularity = pow(10, log10(magnitude).rounded(.down) - 6)
        guard upstreamStd < granularity else { return 0 }
        return 0.5 * granularity
    }

    /// The tolerance of a comparison.
    ///
    /// The tolerance is `k · σ · sqrt(1/m + 1/n)`, i.e. the critical value
    /// of the Student t distribution times the standard deviation of the
    /// difference.  When the comparison is against a reference that is known
    /// to differ from the algorithm of the port by a *measured* amount (the
    /// difference between the two upstream samplers, which the fixture
    /// measures explicitly), that difference is added **in quadrature** — it
    /// is a systematic offset of the reference, not a random one.
    ///
    /// - Parameters:
    ///   - port: the value of the port.
    ///   - upstreamMean: the mean of the upstream realisations.
    ///   - upstreamStd: the spread of the upstream realisations.
    ///   - samplerDifference: the measured difference between the reference
    ///     and the algorithm of the port.
    /// - Returns: the tolerance of the comparison.
    func tolerance(
        port: Double,
        upstreamMean: Double,
        upstreamStd: Double,
        samplerDifference: Double = 0
    ) -> Double {
        let statistical = k * scale(upstreamStd: upstreamStd)
        let combined = (
            statistical * statistical + samplerDifference * samplerDifference
        ).squareRoot()
        let floor = StatisticalGate.resolutionFloor(
            port: port, upstreamMean: upstreamMean, upstreamStd: upstreamStd
        )
        return Swift.max(combined, floor)
    }
}

// MARK: - The comparison of the statistics

/// The comparison of one statistic of one case.
struct StatisticComparison {
    /// The identifier of the case.
    let caseID: String
    /// The name of the statistic.
    let statistic: String
    /// The value of the port (the mean of its realisations).
    let port: Double
    /// The mean of the upstream realisations.
    let upstreamMean: Double
    /// The spread of the upstream realisations.
    let upstreamStd: Double
    /// The measured difference between the reference and the algorithm of the
    /// port (zero when the reference is the algorithm of the port).
    let samplerDifference: Double
    /// The z-score of the comparison.
    let z: Double
    /// The z-score of the single draw form of the comparison.
    let singleDrawZ: Double
    /// The tolerance of the comparison.
    let tolerance: Double
    /// The statistical tolerance of the comparison, without the measured
    /// difference between the reference and the algorithm of the port.
    let statisticalTolerance: Double
    /// Whether the spread of the upstream is below the resolution of the
    /// fixture (the comparison then falls back to the resolution).
    let belowResolution: Bool

    /// The deviation of the port from the upstream mean.
    var deviation: Double { abs(port - upstreamMean) }
}

/// Compares one statistic of one case with the aggregate of the fixture.
///
/// - Parameters:
///   - caseID: the identifier of the case.
///   - statistic: the name of the statistic.
///   - port: the value of the port.
///   - upstream: the aggregate of the upstream (the `mean` and the `std`).
///   - samplerDifference: the measured difference between the reference and
///     the algorithm of the port.
///   - gate: the gate of the family.
/// - Returns: the comparison.
func compareStatistic(
    caseID: String,
    statistic: String,
    port: Double,
    upstream: JSONValue,
    samplerDifference: Double,
    gate: StatisticalGate
) -> StatisticComparison {
    let mean = upstream["mean"]?.double ?? 0
    let std = upstream["std"]?.double ?? 0
    let floor = StatisticalGate.resolutionFloor(
        port: port, upstreamMean: mean, upstreamStd: std
    )
    let statisticalTolerance = gate.k * gate.scale(upstreamStd: std)
    return StatisticComparison(
        caseID: caseID,
        statistic: statistic,
        port: port,
        upstreamMean: mean,
        upstreamStd: std,
        samplerDifference: samplerDifference,
        z: gate.zScore(port: port, upstreamMean: mean, upstreamStd: std),
        singleDrawZ: gate.singleDrawZScore(
            port: port, upstreamMean: mean, upstreamStd: std
        ),
        tolerance: gate.tolerance(
            port: port, upstreamMean: mean, upstreamStd: std,
            samplerDifference: samplerDifference
        ),
        statisticalTolerance: statisticalTolerance,
        belowResolution: floor > 0
    )
}

/// Averages the statistics of several realisations of the port.
///
/// - Parameter runs: the statistics of every realisation.
/// - Returns: the mean of every statistic.
func averageStatistics(_ runs: [[String: Double]]) -> [String: Double] {
    var sums: [String: Double] = [:]
    for run in runs {
        for (key, value) in run { sums[key, default: 0] += value }
    }
    let count = Double(max(runs.count, 1))
    return sums.mapValues { $0 / count }
}

/// Prints the summary of a family of comparisons.
///
/// - Parameters:
///   - title: the title of the summary.
///   - reference: the description of the reference of the comparison.
///   - gate: the gate of the family.
///   - comparisons: the comparisons of the family.
///   - samplerDifference: whether the tolerance carries the measured
///     difference between the reference and the algorithm of the port.
func printStatisticalSummary(
    title: String,
    reference: String,
    gate: StatisticalGate,
    comparisons: [StatisticComparison],
    samplerDifference: Bool
) {
    let resolved = comparisons.filter { !$0.belowResolution }
    let unresolved = comparisons.count - resolved.count
    let sorted = resolved.sorted { $0.z > $1.z }
    let worst = sorted.prefix(5)

    print("")
    print("[\(title)] the statistical gate")
    print("  the reference : \(reference)")
    print("  the port averages \(gate.portSeeds) realisations, "
        + "the upstream mean averages \(gate.upstreamSeeds)")
    print("  the family    : \(gate.comparisons) comparisons, "
        + "the family-wise false alarm rate is "
        + "\(StatisticalGate.familyWiseAlpha * 100)% (Bonferroni)")
    print("  the critical value k = \(String(format: "%.4f", gate.k)) "
        + "(the Student t with \(gate.upstreamSeeds - 1) degrees of freedom)")
    print("  the gate      : |z| <= k, "
        + "z = |swift - mean| / (sigma * sqrt(1/\(gate.portSeeds) "
        + "+ 1/\(gate.upstreamSeeds)))")
    if samplerDifference {
        print("  the tolerance also carries the measured difference between "
            + "the two upstream samplers (in quadrature)")
        let explained = comparisons
            .filter { $0.deviation > $0.statisticalTolerance }
            .sorted { $0.z > $1.z }
        print("  the statistics above the statistical gate (the model difference "
            + "the sampler difference explains): \(explained.count)")
        for row in explained {
            print("    \(row.caseID) \(row.statistic): the deviation "
                + "\(String(format: "%.3g", row.deviation)), the sampler "
                + "difference \(String(format: "%.3g", row.samplerDifference)), "
                + "the tolerance \(String(format: "%.3g", row.tolerance))")
        }
    }
    print("  the statistics: \(comparisons.count) "
        + "(\(unresolved) below the resolution of the fixture)")
    if let maximum = sorted.first {
        print("  max |z| = \(String(format: "%.4f", maximum.z)) "
            + "(\(maximum.caseID) \(maximum.statistic))")
        let singleDraw = resolved.map(\.singleDrawZ).max() ?? 0
        print("  max |z| (the single draw form, "
            + "|swift - mean| / (sigma * sqrt(1 + 1/\(gate.upstreamSeeds)))) "
            + "= \(String(format: "%.4f", singleDraw))")
        print("  the 5 worst z-scores:")
        print("    z        z (one draw)  case                          "
            + "statistic   swift            upstream mean +- sigma")
        for row in worst {
            print("    \(String(format: "%.4f", row.z))  "
                + "\(String(format: "%.4f", row.singleDrawZ))  "
                + "\(row.caseID.padding(toLength: 30, withPad: " ", startingAt: 0))"
                + "\(row.statistic.padding(toLength: 12, withPad: " ", startingAt: 0))"
                + "\(String(format: "%.7g", row.port))  "
                + "\(String(format: "%.7g", row.upstreamMean)) +- "
                + "\(String(format: "%.3g", row.upstreamStd))")
        }
    }
    print("")
}

// MARK: - The slice 6 fixture

/// The number of entries of a JSON object (zero for the other kinds).
extension JSONValue {
    var entryCount: Int {
        if case let .object(object) = self { return object.count }
        return 0
    }
}

/// The cache of the profiles of the tests (the profile JSON files are big).
private var profileCache: [String: Profile] = [:]

/// The cache of the fixtures of the tests.
private var fixtureCache: [String: JSONValue] = [:]

/// Loads a fixture, caching it.
func slice6Fixture(named name: String = "slice6_stochastic") throws -> JSONValue {
    if let cached = fixtureCache[name] { return cached }
    let fixture = try JSONValue.load(named: name)
    fixtureCache[name] = fixture
    return fixture
}

/// Loads a profile, caching it.
func cachedProfile(stock: String) throws -> Profile {
    if let cached = profileCache[stock] { return cached }
    let profile = try ProfileLoader.load(stock: stock)
    profileCache[stock] = profile
    return profile
}

/// The parameters of a slice 6 case.
func slice6Params(_ entry: JSONValue) throws -> PipelineParams {
    let film = try cachedProfile(stock: try XCTUnwrap(entry["film"]?.string))
    let printProfile = try cachedProfile(stock: try XCTUnwrap(entry["print"]?.string))
    return try makePipelineParams(fixture: entry, film: film, print: printProfile)
}

/// The test image of a slice 6 case.
///
/// - Parameters:
///   - fixture: the slice 6 fixture.
///   - kind: the kind of the image (`flat` or `textured`).
/// - Returns: the image, in linear ProPhoto RGB.
func slice6Image(_ fixture: JSONValue, kind: String) throws -> RGBImage {
    let images = try XCTUnwrap(fixture["images"])
    let size = try XCTUnwrap(images["size"]?.doubles)
    let data = try XCTUnwrap(images[kind]?.flatDoubles)
    return RGBImage(width: Int(size[0]), height: Int(size[1]), data: data)
}

/// The kind of the test image of a slice 6 case (`flat` or `textured`).
func slice6ImageKind(_ entry: JSONValue) throws -> String {
    let identifier = try XCTUnwrap(entry["image"]?.string)
    return identifier.hasPrefix("textured") ? "textured" : "flat"
}

/// The difference of two fields, three interleaved values per pixel.
func subtract(_ lhs: [Double], _ rhs: [Double]) -> [Double] {
    guard lhs.count == rhs.count else { return [] }
    var output = [Double](repeating: 0, count: lhs.count)
    for index in 0..<lhs.count {
        output[index] = lhs[index] - rhs[index]
    }
    return output
}

// MARK: - The statistics of the port

/// The stochastic effects of the slice 6.
enum StochasticEffect {
    /// The grain of the negative (measured on the `cmy_film` tap).
    case grain
    /// The glare of the print (measured on the `rgb_out` tap).
    case glare
}

/// The summary statistics of the port for one case and one effect.
///
/// The effect is measured on the difference between the tap with the effect
/// and the tap without it: the difference is the effect itself.
///
/// - Parameters:
///   - params: the parameters of the case.
///   - image: the test image of the case.
///   - effect: the stochastic effect.
///   - seeds: the seeds of the port.
///   - lags: the lags of the autocorrelation.
///   - quantileLevels: the levels of the quantiles.
/// - Returns: the statistics of every realisation of the port.
func portFieldStatistics(
    params: PipelineParams,
    image: RGBImage,
    effect: StochasticEffect,
    seeds: [UInt64],
    lags: [Int],
    quantileLevels: [Double]
) throws -> [[String: Double]] {
    // The reference: every stochastic effect off.
    var referenceParams = params
    referenceParams.filmRender.grain.active = false
    referenceParams.printRender.glare.active = false
    let reference = try FilmPipeline(params: referenceParams).process(rgbIn: image)

    var runs: [[String: Double]] = []
    for seed in seeds {
        var runParams = params
        runParams.stochastic.seed = seed
        switch effect {
        case .grain:
            runParams.filmRender.grain.active = true
            runParams.printRender.glare.active = false
        case .glare:
            runParams.filmRender.grain.active = false
            runParams.printRender.glare.active = true
        }
        let run = try FilmPipeline(params: runParams).process(rgbIn: image)
        let field: [Double]
        switch effect {
        case .grain:
            field = subtract(run.cmyFilm.data, reference.cmyFilm.data)
        case .glare:
            field = subtract(run.rgbOut.data, reference.rgbOut.data)
        }
        runs.append(
            fieldStatistics(
                field,
                width: image.width,
                height: image.height,
                lags: lags,
                quantileLevels: quantileLevels
            ).asDictionary(lags: lags, quantileLevels: quantileLevels)
        )
    }
    return runs
}

/// The number of comparisons of the family of the slice 6.
///
/// The family covers every statistic of every case, against every reference
/// of the fixture: the grain against the two upstream references (the exact
/// SciPy generators and the fast kernels) and the glare against the one.
///
/// - Parameter fixture: the slice 6 fixture.
/// - Returns: the number of comparisons of the family.
func slice6FamilySize(_ fixture: JSONValue) throws -> Int {
    let cases = try XCTUnwrap(fixture["cases"]?.arrayElements)
    var total = 0
    for entry in cases {
        total += entry["grain"]?["aggregate"]?.entryCount ?? 0
        total += entry["grain"]?["fast_aggregate"]?.entryCount ?? 0
        total += entry["glare"]?["aggregate"]?.entryCount ?? 0
    }
    return total
}
