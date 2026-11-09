//
//  Digest.swift
//  light suffer胶片 — iOS app
//
//  The digest of the runtime parameters: the stock specific overrides the
//  upstream engine applies before the pipeline runs.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The digest of the runtime parameters.
///
/// Upstream reference: `spektrafilm.runtime.params_builder.digest_params`.
///
/// The digest applies the three stock specific steps of the upstream engine:
///
/// 1. ``applyDatabaseNeutralPrintFilters(_:)`` — the (C, M, Y) Kodak CC
///    values of the neutral print filters of the film / paper pair,
/// 2. ``applyFilmSpecifics(_:)`` — the DIR coupler chemistry and the
///    halation baseline of the film,
/// 3. ``applyPrintSpecifics(_:)`` — a no-op upstream (the hook where the
///    print specific overrides would go).
///
/// The upstream engine digests the parameters **once**, when the stock is
/// selected (`spektrafilm_gui.state.digest_after_selection`), and the GUI
/// then edits the digested values. The Swift digest keeps that behaviour but
/// is *idempotent* and *non destructive*: a value that still holds its
/// upstream default is replaced by the stock specific one, a value the user
/// has customised is left alone. The digest can therefore be applied every
/// time a pipeline is created without loosing the live parameters of the app.
public enum Digest {

    /// The halation presets, keyed by the use and the antihalation tag of the
    /// stock.
    ///
    /// Upstream reference: `spektrafilm.runtime.params_builder._HALATION_PRESETS`.
    private static let halationPresets: [String: (sigma: [Double], strength: [Double])] = [
        "still|strong": ([65, 65, 65], [0.015, 0.005, 0]),
        "still|weak": ([65, 65, 65], [0.08, 0.02, 0]),
        "still|no": ([65, 65, 65], [0.3, 0.1, 0.015]),
        "cine|strong": ([50, 50, 50], [0.015, 0.005, 0]),
        "cine|weak": ([50, 50, 50], [0.08, 0.02, 0]),
        "cine|no": ([50, 50, 50], [0.3, 0.1, 0.015]),
    ]

    // MARK: - The whole digest

    /// Digests the parameters of a run.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder.digest_params`.
    ///
    /// - Parameter params: the parameters before the digest.
    /// - Returns: the digested parameters.
    public static func digest(_ params: PipelineParams) -> PipelineParams {
        var params = params
        params = applyDatabaseNeutralPrintFilters(params)
        params = applyFilmSpecifics(params)
        params = applyPrintSpecifics(params)
        return params
    }

    // MARK: - The neutral print filters

    /// Applies the neutral print filter database.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder.apply_database_neutral_print_filters`.
    ///
    /// The database holds the (C, M, Y) Kodak CC values of the neutral print
    /// filters of every film / paper / illuminant triplet. When the database
    /// has no entry for the triplet, the values of the parameters are kept
    /// (the upstream engine prints a warning and uses the defaults).
    ///
    /// - Parameter params: the parameters before the digest.
    /// - Returns: the parameters with the neutral filters of the database.
    public static func applyDatabaseNeutralPrintFilters(
        _ params: PipelineParams
    ) -> PipelineParams {
        guard params.settings.neutralPrintFiltersFromDatabase else { return params }
        guard let values = NeutralPrintFilters.lookup(
            printStock: params.print.info.stock,
            illuminant: params.enlarger.illuminant,
            filmStock: params.film.info.stock
        ) else { return params }
        var params = params
        // The upstream engine always overrides the neutral values with the
        // ones of the database; the port only does it when the user has not
        // customised them.
        if params.enlarger.cFilterNeutral == EnlargerParams().cFilterNeutral {
            params.enlarger.cFilterNeutral = values[0]
        }
        if params.enlarger.mFilterNeutral == EnlargerParams().mFilterNeutral {
            params.enlarger.mFilterNeutral = values[1]
        }
        if params.enlarger.yFilterNeutral == EnlargerParams().yFilterNeutral {
            params.enlarger.yFilterNeutral = values[2]
        }
        return params
    }

    // MARK: - The film specifics

    /// Applies the stock specific film rendering parameters.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder._apply_film_specifics`.
    ///
    /// The DIR coupler inhibition values depend on the polarity of the stock
    /// (a positive emulsion develops in the silver stage and has a much
    /// weaker coupling), the halation baseline depends on the use and the
    /// anti-halation layer of the stock, and two stocks (Velvia 100 and
    /// Provia 100F) have their own DIR coupler chemistry.
    ///
    /// - Parameter params: the parameters before the digest.
    /// - Returns: the parameters with the stock specific film rendering.
    public static func applyFilmSpecifics(_ params: PipelineParams) -> PipelineParams {
        var params = params
        params.filmRender = filmRender(for: params.film, base: params.filmRender)
        return params
    }

    /// Applies the halation preset of the stock.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder._apply_halation_preset`.
    ///
    /// The sigma of the first halation bounce is set by the base material
    /// (65 µm for a still triacetate base, 50 µm for a PET cine base) and the
    /// strength by the anti-halation layer.
    ///
    /// - Parameter params: the parameters before the digest.
    /// - Returns: the parameters with the halation baseline of the stock.
    public static func applyHalationPreset(_ params: PipelineParams) -> PipelineParams {
        var params = params
        guard params.film.isFilm else { return params }
        let key = "\(params.film.info.use.rawValue)|\(params.film.info.antihalation.rawValue)"
        guard let preset = halationPresets[key] else { return params }
        if params.filmRender.halationFirstSigmaUM == FilmRenderParams().halationFirstSigmaUM {
            params.filmRender.halationFirstSigmaUM = preset.sigma
        }
        if params.filmRender.halationStrength == FilmRenderParams().halationStrength {
            params.filmRender.halationStrength = preset.strength
        }
        return params
    }

    /// The stock specific film rendering parameters.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder._apply_film_specifics` and
    /// `spektrafilm.runtime.params_builder._apply_halation_preset`.
    ///
    /// - Parameters:
    ///   - profile: the profile of the film.
    ///   - base: the film rendering parameters before the digest.
    /// - Returns: the digested film rendering parameters.
    public static func filmRender(
        for profile: Profile,
        base: FilmRenderParams = FilmRenderParams()
    ) -> FilmRenderParams {
        var digest = base

        // The DIR coupler chemistry of the polarity of the emulsion.
        //
        // Upstream reference: `_apply_film_specifics`.
        let stockSpecific: (samelayer: [Double], rToGB: [Double], gToRB: [Double], bToRG: [Double])?
        switch profile.info.type {
        case .positive:
            stockSpecific = (
                [0.12, 0.08, 0.06], [0.12, 0.06], [0.08, 0.06], [0.06, 0.06]
            )
        case .negative:
            stockSpecific = (
                [0.336, 0.319, 0.273], [0.353, 0.302], [0.154, 0.353], [0.168, 0.226]
            )
        }
        if let stockSpecific {
            if digest.dirCouplers.gammaSamelayerRGB == DirCouplersParams().gammaSamelayerRGB {
                digest.dirCouplers.gammaSamelayerRGB = stockSpecific.samelayer
            }
            if digest.dirCouplers.gammaInterlayerRToGB == DirCouplersParams().gammaInterlayerRToGB {
                digest.dirCouplers.gammaInterlayerRToGB = stockSpecific.rToGB
            }
            if digest.dirCouplers.gammaInterlayerGToRB == DirCouplersParams().gammaInterlayerGToRB {
                digest.dirCouplers.gammaInterlayerGToRB = stockSpecific.gToRB
            }
            if digest.dirCouplers.gammaInterlayerBToRG == DirCouplersParams().gammaInterlayerBToRG {
                digest.dirCouplers.gammaInterlayerBToRG = stockSpecific.bToRG
            }
        }

        // The halation baseline of the material and of the anti-halation layer.
        //
        // Upstream reference: `_apply_halation_preset`.
        if profile.info.support == .film {
            let key = "\(profile.info.use.rawValue)|\(profile.info.antihalation.rawValue)"
            if let preset = halationPresets[key] {
                if digest.halationFirstSigmaUM == FilmRenderParams().halationFirstSigmaUM {
                    digest.halationFirstSigmaUM = preset.sigma
                }
                if digest.halationStrength == FilmRenderParams().halationStrength {
                    digest.halationStrength = preset.strength
                }
            }
        }

        // The stock specific overrides of the DIR coupler chemistry.
        //
        // Upstream reference: `_apply_film_specifics`.
        switch profile.info.stock {
        case "fujifilm_velvia_100":
            digest.dirCouplers.gammaSamelayerRGB = [0.108, 0.072, 0.054]
            digest.dirCouplers.gammaInterlayerRToGB = [0.108, 0.054]
            digest.dirCouplers.gammaInterlayerGToRB = [0.072, 0.054]
            digest.dirCouplers.gammaInterlayerBToRG = [0.054, 0.054]
        case "fujifilm_provia_100f":
            digest.dirCouplers.gammaSamelayerRGB = [0.156, 0.104, 0.078]
            digest.dirCouplers.gammaInterlayerRToGB = [0.156, 0.078]
            digest.dirCouplers.gammaInterlayerGToRB = [0.104, 0.078]
            digest.dirCouplers.gammaInterlayerBToRG = [0.078, 0.078]
        default:
            break
        }

        return digest
    }

    // MARK: - The print specifics

    /// Applies the stock specific print rendering parameters.
    ///
    /// Upstream reference:
    /// `spektrafilm.runtime.params_builder._apply_print_specifics`.
    ///
    /// The upstream hook is empty — the print media of the catalogue share
    /// the same print rendering parameters — so the port is a no-op too.
    ///
    /// - Parameter params: the parameters before the digest.
    /// - Returns: the unchanged parameters.
    public static func applyPrintSpecifics(_ params: PipelineParams) -> PipelineParams {
        params
    }
}
