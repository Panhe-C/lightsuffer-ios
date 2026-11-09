//
//  StockCatalog.swift
//  light suffer胶片 — iOS app
//
//  The catalogue of the films and the print media the engine supports.
//
//  film modeling powered by spektrafilm
//  https://github.com/andreavolpato/spektrafilm
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import Foundation

/// A stock of the catalogue: a film that is exposed in a camera or a print
/// medium that receives the image of an enlarger.
///
/// Upstream reference: `spektrafilm.model.stocks.FilmStocks` and
/// `spektrafilm.model.stocks.PrintPapers`, and the `info` block of the
/// profile JSON files.
public struct StockDescriptor: Equatable, Sendable {

    /// The stock name, i.e. the stem of the profile file
    /// (`kodak_portra_400`).
    public let stock: String
    /// The human readable name of the stock (`Kodak Portra 400`).
    public let name: String
    /// The polarity of the emulsion (`negative` or `positive`).
    public let type: ProfileType
    /// The intended use of the stock (`still` or `cine`).
    public let use: ProfileUse
    /// The physical support of the emulsion (`film` or `paper`).
    public let support: ProfileSupport
    /// The strength of the anti-halation layer.
    public let antihalation: Antihalation
    /// The print medium the stock is normally paired with, if any.
    public let targetPrint: String?
    /// The reference illuminant of the stock.
    public let referenceIlluminant: String
    /// The viewing illuminant of the stock.
    public let viewingIlluminant: String

    public init(
        stock: String,
        name: String,
        type: ProfileType,
        use: ProfileUse,
        support: ProfileSupport,
        antihalation: Antihalation,
        targetPrint: String?,
        referenceIlluminant: String,
        viewingIlluminant: String
    ) {
        self.stock = stock
        self.name = name
        self.type = type
        self.use = use
        self.support = support
        self.antihalation = antihalation
        self.targetPrint = targetPrint
        self.referenceIlluminant = referenceIlluminant
        self.viewingIlluminant = viewingIlluminant
    }

    /// `true` for a slide / direct-scan emulsion.
    public var isPositive: Bool { type == .positive }

    /// `true` for a colour negative emulsion.
    public var isNegative: Bool { type == .negative }

    /// `true` for a cinema stock.
    public var isCine: Bool { use == .cine }

    /// `true` for a still camera stock.
    public var isStill: Bool { use == .still }

    /// `true` for a photographic film (the camera films and the cine print
    /// films), `false` for a paper.
    public var isFilm: Bool { support == .film }

    /// `true` for a photographic paper.
    public var isPaper: Bool { support == .paper }
}

/// The catalogue of the films and the print media of the engine.
///
/// The port ships the **complete upstream catalogue**: the 20 camera films
/// (16 colour negatives and 4 slides) and the 8 print media (6 papers and
/// 2 cine print films), i.e. the 132 looks of the upstream engine
/// (16 × 8 = 128 printed looks + 20 direct scans).
///
/// Upstream reference: `spektrafilm.model.stocks` and
/// `spektrafilm.profiles.io.list_profiles`.
public enum StockCatalog {

    // MARK: - The camera films

    /// The 20 camera films, in the order of the upstream `FilmStocks` enum.
    ///
    /// Upstream reference: `spektrafilm.model.stocks.FilmStocks`.
    public static let films: [StockDescriptor] = [
        // kodak pro
        StockDescriptor(
            stock: "kodak_ektar_100", name: "Kodak Ektar 100",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_160", name: "Kodak Portra 160",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_400", name: "Kodak Portra 400",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_800", name: "Kodak Portra 800",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_800_push1", name: "Kodak Portra 800 (Push 1)",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_800_push2", name: "Kodak Portra 800 (Push 2)",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        // kodak consumer
        StockDescriptor(
            stock: "kodak_gold_200", name: "Kodak Gold 200",
            type: .negative, use: .still, support: .film, antihalation: .weak,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_ultramax_400", name: "Kodak Ultramax 400",
            type: .negative, use: .still, support: .film, antihalation: .weak,
            targetPrint: "kodak_portra_endura",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        // kodak cine
        StockDescriptor(
            stock: "kodak_vision3_50d", name: "Kodak Vision3 50D",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: "kodak_2383",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_vision3_250d", name: "Kodak Vision3 250D",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: "kodak_2383",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_verita_200d", name: "Kodak Verita 200D",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: "kodak_2383",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_vision3_200t", name: "Kodak Vision3 200T",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: "kodak_2383",
            referenceIlluminant: "T", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_vision3_500t", name: "Kodak Vision3 500T",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: "kodak_2383",
            referenceIlluminant: "T", viewingIlluminant: "D50"
        ),
        // fuji pro
        StockDescriptor(
            stock: "fujifilm_pro_400h", name: "Fujifilm Pro 400H",
            type: .negative, use: .still, support: .film, antihalation: .strong,
            targetPrint: "fujifilm_crystal_archive_typeii",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        // fuji consumer
        StockDescriptor(
            stock: "fujifilm_c200", name: "Fujifilm C200",
            type: .negative, use: .still, support: .film, antihalation: .weak,
            targetPrint: "fujifilm_crystal_archive_typeii",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "fujifilm_xtra_400", name: "Fujifilm X-Tra 400",
            type: .negative, use: .still, support: .film, antihalation: .weak,
            targetPrint: "fujifilm_crystal_archive_typeii",
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        // positive
        StockDescriptor(
            stock: "kodak_ektachrome_100", name: "Kodak Ektachrome 100",
            type: .positive, use: .still, support: .film, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_kodachrome_64", name: "Kodak Kodachrome 64",
            type: .positive, use: .still, support: .film, antihalation: .weak,
            targetPrint: nil,
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "fujifilm_velvia_100", name: "Fujifilm Velvia 100",
            type: .positive, use: .still, support: .film, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "fujifilm_provia_100f", name: "Fujifilm Provia 100F",
            type: .positive, use: .still, support: .film, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "D55", viewingIlluminant: "D50"
        ),
    ]

    // MARK: - The print media

    /// The 8 print media, in the order of the upstream `PrintPapers` enum.
    ///
    /// Upstream reference: `spektrafilm.model.stocks.PrintPapers`.
    public static let printMedia: [StockDescriptor] = [
        StockDescriptor(
            stock: "kodak_ultra_endura", name: "Kodak Professional Ultra Endura",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_endura_premier", name: "Kodak Professional Endura Premier",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_ektacolor_edge", name: "Kodak Ektacolor Edge",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_supra_endura", name: "Kodak Professional Supra Endura",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_portra_endura", name: "Kodak Professional Portra Endura",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "fujifilm_crystal_archive_typeii", name: "Fujifilm Crystal Archive Type II",
            type: .negative, use: .still, support: .paper, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "D50"
        ),
        StockDescriptor(
            stock: "kodak_2383", name: "Kodak Vision 2383",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "K75P"
        ),
        StockDescriptor(
            stock: "kodak_2393", name: "Kodak Vision Premier 2393",
            type: .negative, use: .cine, support: .film, antihalation: .strong,
            targetPrint: nil,
            referenceIlluminant: "TH-KG3", viewingIlluminant: "K75P"
        ),
    ]

    // MARK: - Lookups

    /// The 16 colour negative films of the catalogue.
    public static var negativeFilms: [StockDescriptor] {
        films.filter { $0.isNegative }
    }

    /// The 4 slide (positive) films of the catalogue.
    public static var positiveFilms: [StockDescriptor] {
        films.filter { $0.isPositive }
    }

    /// The 6 papers of the catalogue.
    public static var papers: [StockDescriptor] {
        printMedia.filter { $0.support == .paper }
    }

    /// The 2 cine print films of the catalogue.
    public static var printFilms: [StockDescriptor] {
        printMedia.filter { $0.support == .film }
    }

    /// Every stock of the catalogue, the films first.
    public static var allStocks: [StockDescriptor] { films + printMedia }

    /// The stock names of the catalogue.
    public static var stockNames: [String] { allStocks.map(\.stock) }

    /// The descriptor of a stock.
    public static func descriptor(stock: String) -> StockDescriptor? {
        allStocks.first { $0.stock == stock }
    }

    /// The descriptor of a camera film.
    public static func film(stock: String) -> StockDescriptor? {
        films.first { $0.stock == stock }
    }

    /// The descriptor of a print medium.
    public static func printMedium(stock: String) -> StockDescriptor? {
        printMedia.first { $0.stock == stock }
    }

    /// Whether the stock is scanned directly instead of being printed.
    ///
    /// Upstream reference: `spektrafilm_gui.state.digest_after_selection`,
    /// which sets `params.io.scan_film = bool(params.film.is_positive)`.
    ///
    /// The slides (Velvia, Provia, Kodachrome, Ektachrome) are reversal
    /// emulsions: they are scanned directly. The negatives are printed on a
    /// paper, but the upstream engine also offers to scan them directly
    /// (`io.scan_film`), which is what this catalogue describes for them.
    public static func isScannedDirectly(stock: String) -> Bool {
        film(stock: stock)?.isPositive ?? false
    }
}

// MARK: - The looks

extension StockCatalog {

    /// A look of the catalogue: a film, the print medium it is printed on
    /// and the way the image is made.
    ///
    /// A slide (a positive emulsion) is scanned directly, a colour negative
    /// is printed on a paper and the print is scanned.
    public struct Look: Equatable, Sendable, Identifiable {
        /// The film of the look.
        public let film: StockDescriptor
        /// The print medium of the look, `nil` for a direct scan.
        public let print: StockDescriptor?
        /// Whether the film is scanned directly.
        public let scanFilm: Bool

        public init(film: StockDescriptor, print: StockDescriptor?, scanFilm: Bool) {
            self.film = film
            self.print = print
            self.scanFilm = scanFilm
        }

        /// The identifier of the look, e.g. `kodak_portra_400__kodak_portra_endura`.
        public var id: String {
            guard let print else { return "\(film.stock)__scan" }
            return "\(film.stock)__\(print.stock)"
        }

        /// The name of the look.
        public var name: String {
            guard let print else { return "\(film.name) (direct scan)" }
            return "\(film.name) → \(print.name)"
        }
    }

    /// Every look of the catalogue.
    ///
    /// The 16 colour negatives are printed on the 8 print media (128 looks)
    /// and the 20 films are scanned directly (20 looks), i.e. the 148
    /// combinations of the upstream engine.
    ///
    /// The order is the order of the upstream `FilmStocks` and
    /// `PrintPapers` enumerations: the prints of a film first, then the
    /// direct scan of the film.
    public static var looks: [Look] {
        var looks: [Look] = []
        for film in films {
            if film.isNegative {
                for print in printMedia {
                    looks.append(Look(film: film, print: print, scanFilm: false))
                }
            }
            looks.append(Look(film: film, print: nil, scanFilm: true))
        }
        return looks
    }

    /// The default print medium of a film.
    ///
    /// The default is the `target_print` of the profile; the slides have
    /// none (they are scanned directly).
    public static func defaultPrint(for film: String) -> StockDescriptor? {
        guard let descriptor = self.film(stock: film) else { return nil }
        guard let target = descriptor.targetPrint else { return nil }
        return printMedium(stock: target)
    }
}

// MARK: - The parameters of a look

extension StockCatalog {

    /// The parameters of a look, with the upstream defaults.
    ///
    /// The parameters are the upstream defaults of
    /// `spektrafilm.runtime.params_schema.RuntimePhotoParams`, with the
    /// features that are not ported yet switched off (the auto exposure of
    /// the camera, the lens blurs and the unsharp mask of the scanner).
    /// The stock specific digest is applied, exactly like the upstream
    /// `digest_params` does when a stock is selected.
    ///
    /// - Parameters:
    ///   - film: the stock of the film.
    ///   - print: the stock of the print medium; the default print of the
    ///     film when it is `nil` (a slide has none).
    ///   - scanFilm: whether the film is scanned directly; the slides always
    ///     are.
    /// - Returns: the digested parameters of the look.
    public static func pipelineParams(
        film: String,
        print printStock: String? = nil,
        scanFilm: Bool? = nil
    ) throws -> PipelineParams {
        guard let filmProfile = try profile(stock: film) else {
            throw ProfileError.notFound(stock: film)
        }
        let isPositive = filmProfile.info.type == .positive
        let scanned = scanFilm ?? isPositive
        let printName = printStock ?? defaultPrint(for: film)?.stock ?? "kodak_portra_endura"
        guard let printProfile = try profile(stock: printName) else {
            throw ProfileError.notFound(stock: printName)
        }

        let params = PipelineParams(
            film: filmProfile,
            print: printProfile,
            camera: CameraParams(autoExposure: false),
            scanner: ScannerParams(unsharpMaskSigma: 0, unsharpMaskAmount: 0),
            io: IOParams(scanFilm: scanned)
        )
        return Digest.digest(params)
    }

    /// The cached profiles of the catalogue.
    ///
    /// The profile JSON files are parsed once and kept: a catalogue sweep
    /// needs the twenty films and the eight print media over and over.
    public static func profile(stock: String) throws -> Profile? {
        try profileCache.profile(stock: stock)
    }

    /// The cached profiles.
    private static let profileCache = ProfileCache()

    private final class ProfileCache {
        private let lock = NSLock()
        private var profiles: [String: Profile] = [:]

        func profile(stock: String) throws -> Profile? {
            lock.lock()
            if let cached = profiles[stock] {
                lock.unlock()
                return cached
            }
            lock.unlock()
            guard let url = FilmPhysics.profileURL(stock: stock) else {
                lock.unlock()
                return nil
            }
            let loaded = try ProfileLoader.load(contentsOf: url, stock: stock)
            lock.lock()
            profiles[stock] = loaded
            lock.unlock()
            return loaded
        }
    }
}
