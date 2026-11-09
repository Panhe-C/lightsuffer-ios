//
//  NeutralPrintFilters.swift
//  light suffer胶片 — iOS app
//
//  The neutral print filter database: the Kodak CC filter values (C, M, Y)
//  that balance a given film on a given paper under a given illuminant.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// The neutral print filter database.
///
/// Upstream reference:
/// `spektrafilm.runtime.params_builder.apply_database_neutral_print_filters`
/// and `spektrafilm.utils.io.read_neutral_print_filters`.
///
/// The database is bundled as a resource (packed by `tools/pack_resources.py`);
/// its provenance is documented in
/// `Sources/FilmPhysics/Resources/CHANGELOG.txt`.
public enum NeutralPrintFilters {

    /// The neutral CC filter values of a film / paper / illuminant triplet.
    ///
    /// - Parameters:
    ///   - printStock: the stock of the paper.
    ///   - illuminant: the illuminant of the enlarger (`"TH-KG3"`).
    ///   - filmStock: the stock of the negative.
    /// - Returns: the (C, M, Y) CC values, or `nil` when the database has no
    ///   entry for the triplet.
    public static func lookup(
        printStock: String,
        illuminant: String,
        filmStock: String
    ) -> [Double]? {
        guard let database = cachedDatabase() else { return nil }
        guard let perIlluminant = database[printStock] else { return nil }
        guard let perFilm = perIlluminant[illuminant] else { return nil }
        guard let values = perFilm[filmStock], values.count >= 3 else { return nil }
        return [values[0], values[1], values[2]]
    }

    /// The cached neutral print filter database.
    public static func cachedDatabase() -> [String: [String: [String: [Double]]]]? {
        cachedStorage.database
    }

    /// The lazily loaded database.
    private static let cachedStorage = Storage()

    private final class Storage {
        let database: [String: [String: [String: [Double]]]]?

        init() {
            database = try? Resources.neutralPrintFilters()
        }
    }
}
