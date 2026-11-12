//
//  PreviewLook.swift
//  light suffer胶片 — preview support
//

import FilmPhysics
import Foundation

/// The small set of physical adjustments exposed by the app shell.
///
/// These values are applied after ``StockCatalog/pipelineParams(film:print:scanFilm:)``
/// has loaded and digested a fresh look.  In particular, changing a look never
/// carries over stock-specific parameters from the previous look.
public struct PreviewAdjustments: Equatable, Sendable {
    /// Camera exposure compensation, in stops.
    public var exposureCompensationEV: Double
    /// Whether the physical silver-halide grain simulation is active.
    public var grainEnabled: Bool
    /// A dimensionless multiplier of the digested per-channel particle scales.
    ///
    /// The engine has no single grain-strength parameter.  For a control value
    /// `s`, the app sets `particleScale[channel] = digestedScale[channel] * s`.
    /// Thus the effective particle area of every channel is multiplied by `s`;
    /// `particleAreaUM2`, channel ratios, sublayer ratios and all other grain
    /// parameters retain their digested values.  A value of 1.0 is exactly the
    /// engine default.  Grain can be switched off independently.
    public var grainStrength: Double
    /// Whether the physical scatter and back-reflection halation are active.
    public var halationEnabled: Bool
    /// The engine's direct multiplier of back-reflection halation.
    public var halationAmount: Double

    public static let exposureCompensationRange = -2.0...2.0
    /// Zero is represented by Grain off rather than a zero particle area.
    public static let grainStrengthRange = 0.1...3.0
    public static let halationAmountRange = 0.0...3.0

    public init(
        exposureCompensationEV: Double = 0,
        grainEnabled: Bool = true,
        grainStrength: Double = 1,
        halationEnabled: Bool = true,
        halationAmount: Double = 1
    ) {
        self.exposureCompensationEV = exposureCompensationEV
        self.grainEnabled = grainEnabled
        self.grainStrength = grainStrength
        self.halationEnabled = halationEnabled
        self.halationAmount = halationAmount
    }
}

public enum PreviewLookError: LocalizedError, Equatable {
    case unknownFilm(String)
    case unknownPrintMedium(String)
    case printNotAvailableForPositive(String)
    case unsupportedLook(film: String, print: String?)

    public var errorDescription: String? {
        switch self {
        case let .unknownFilm(stock):
            return "The film stock ‘\(stock)’ is not in the catalogue."
        case let .unknownPrintMedium(stock):
            return "The print medium ‘\(stock)’ is not in the catalogue."
        case let .printNotAvailableForPositive(stock):
            return "The slide film ‘\(stock)’ must be scanned directly."
        case let .unsupportedLook(film, print):
            return "The catalogue does not support \(film) with \(print ?? "direct scan")."
        }
    }
}

/// Catalogue look construction and the app's basic physical adjustments.
public enum PreviewLook {
    public static let filmStock = "kodak_portra_400"
    public static let printStock = "kodak_portra_endura"
    public static let directScanIdentifier = "direct-scan"

    /// Kodak Portra 400 printed on Portra Endura, the app-shell default.
    public static var defaultLook: StockCatalog.Look {
        guard let look = StockCatalog.looks.first(where: {
            $0.film.stock == filmStock && $0.print?.stock == printStock && !$0.scanFilm
        }) else {
            preconditionFailure("The bundled default film look is missing from StockCatalog.looks")
        }
        return look
    }

    /// Selects a film and its catalogue default output.  Slides are direct scans.
    public static func look(film filmStock: String) throws -> StockCatalog.Look {
        guard let film = StockCatalog.film(stock: filmStock) else {
            throw PreviewLookError.unknownFilm(filmStock)
        }
        let direct = StockCatalog.isScannedDirectly(stock: filmStock)
        let print = direct ? nil : StockCatalog.defaultPrint(for: filmStock)
        return try catalogueLook(film: film, print: print, scanFilm: direct)
    }

    /// Selects a print medium, or `nil` for a direct scan, without changing film.
    /// Positive films reject every paper / cine-print path.
    public static func look(
        film filmStock: String,
        print printStock: String?
    ) throws -> StockCatalog.Look {
        guard let film = StockCatalog.film(stock: filmStock) else {
            throw PreviewLookError.unknownFilm(filmStock)
        }
        if StockCatalog.isScannedDirectly(stock: filmStock), printStock != nil {
            throw PreviewLookError.printNotAvailableForPositive(filmStock)
        }
        let print = try printStock.map { stock -> StockDescriptor in
            guard let medium = StockCatalog.printMedium(stock: stock) else {
                throw PreviewLookError.unknownPrintMedium(stock)
            }
            return medium
        }
        return try catalogueLook(film: film, print: print, scanFilm: print == nil)
    }

    /// Loads the bundled default look with unmodified basic adjustments.
    public static func pipelineParams() throws -> PipelineParams {
        try pipelineParams(for: defaultLook)
    }

    /// Builds a fresh, stock-digested look and applies the basic adjustments.
    ///
    /// None of these controls requires another digest: the digest does not
    /// derive values from camera EV, grain activity / particle scale, or the
    /// direct halation amount.  The stock digest itself is never bypassed.
    public static func pipelineParams(
        for look: StockCatalog.Look,
        adjustments: PreviewAdjustments = PreviewAdjustments(),
        inputSettings: PhotoInputSettings = PhotoInputSettings()
    ) throws -> PipelineParams {
        var params = try StockCatalog.pipelineParams(
            film: look.film.stock,
            print: look.print?.stock,
            scanFilm: look.scanFilm
        )

        params.camera.exposureCompensationEV = adjustments.exposureCompensationEV
        params.filmRender.grain.active = adjustments.grainEnabled
        params.filmRender.grain.particleScale = params.filmRender.grain.particleScale.map {
            $0 * adjustments.grainStrength
        }
        params.filmRender.halation.active = adjustments.halationEnabled
        params.filmRender.halation.halationAmount = adjustments.halationAmount

        // The decoder supplies pixels in exactly this tagged space. Unsupported
        // engine names are rejected or converted by the I/O policy, never passed
        // through to FilmPipeline. This writes no stock or stochastic fields.
        try inputSettings.apply(to: &params)

        // StockCatalog supplies autoExposure == false and the PipelineParams
        // default grain sampler.  Do not replace either policy here.
        return params
    }

    private static func catalogueLook(
        film: StockDescriptor,
        print: StockDescriptor?,
        scanFilm: Bool
    ) throws -> StockCatalog.Look {
        guard let look = StockCatalog.looks.first(where: {
            $0.film.stock == film.stock &&
                $0.print?.stock == print?.stock &&
                $0.scanFilm == scanFilm
        }) else {
            throw PreviewLookError.unsupportedLook(
                film: film.stock,
                print: print?.stock
            )
        }
        return look
    }
}
