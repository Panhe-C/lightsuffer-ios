//
//  StockCatalogTests.swift
//  light suffer胶片 — iOS app
//
//  The catalogue of the films and the print media: every stock of the
//  upstream engine is bundled, its metadata matches the catalogue and every
//  look of the catalogue can be simulated.
//
//  This file is part of a GPLv3 licensed project; see LICENSE at the repo root.
//

import XCTest
@testable import FilmPhysics

final class StockCatalogTests: XCTestCase {

    // MARK: - The catalogue

    /// The catalogue holds the whole upstream catalogue.
    func testCatalogueHoldsTheUpstreamStocks() {
        XCTAssertEqual(StockCatalog.films.count, 20, "the upstream ships 20 camera films")
        XCTAssertEqual(StockCatalog.printMedia.count, 8, "the upstream ships 8 print media")
        XCTAssertEqual(StockCatalog.allStocks.count, 28)
        XCTAssertEqual(StockCatalog.negativeFilms.count, 16)
        XCTAssertEqual(StockCatalog.positiveFilms.count, 4)
        XCTAssertEqual(StockCatalog.papers.count, 6)
        XCTAssertEqual(StockCatalog.printFilms.count, 2)
        XCTAssertEqual(FilmPhysics.bundledProfiles.count, 28)
        XCTAssertEqual(Set(FilmPhysics.bundledProfiles).count, 28, "the stock names are unique")
    }

    /// Every stock of the catalogue is bundled and its metadata matches.
    func testEveryStockIsBundledAndMatchesItsProfile() throws {
        for descriptor in StockCatalog.allStocks {
            let profile = try XCTUnwrap(
                try StockCatalog.profile(stock: descriptor.stock),
                "the profile of \(descriptor.stock) is not bundled"
            )
            XCTAssertEqual(profile.info.stock, descriptor.stock)
            XCTAssertEqual(profile.info.name, descriptor.name)
            XCTAssertEqual(profile.info.type, descriptor.type)
            XCTAssertEqual(profile.info.support, descriptor.support)
            XCTAssertEqual(profile.info.use, descriptor.use)
            XCTAssertEqual(profile.info.antihalation, descriptor.antihalation)
            XCTAssertEqual(profile.info.targetPrint, descriptor.targetPrint)
            XCTAssertEqual(profile.info.referenceIlluminant, descriptor.referenceIlluminant)
            XCTAssertEqual(profile.info.viewingIlluminant, descriptor.viewingIlluminant)
        }
    }

    /// The 148 looks of the catalogue.
    func testCatalogueHoldsEveryLook() {
        let looks = StockCatalog.looks
        XCTAssertEqual(looks.count, 148, "16 negatives x 8 prints + 20 direct scans")
        XCTAssertEqual(Set(looks.map(\.id)).count, 148, "the look identifiers are unique")
        XCTAssertEqual(looks.filter { $0.scanFilm }.count, 20)
        XCTAssertEqual(looks.filter { !$0.scanFilm }.count, 128)

        // The slides are only scanned directly; the negatives are printed on
        // the eight print media *and* can be scanned directly (the upstream
        // engine offers both).
        for look in looks {
            if look.film.isPositive {
                XCTAssertTrue(look.scanFilm, "\(look.id): a slide is scanned directly")
                XCTAssertNil(look.print, "\(look.id): a slide has no print medium")
            } else if look.scanFilm {
                XCTAssertNil(look.print, "\(look.id): a direct scan has no print medium")
            } else {
                XCTAssertNotNil(look.print, "\(look.id): a negative needs a print medium")
            }
        }
    }

    /// The default print medium of a film is the one of its profile.
    func testDefaultPrintOfEveryFilm() throws {
        for film in StockCatalog.negativeFilms {
            let descriptor = try XCTUnwrap(StockCatalog.defaultPrint(for: film.stock))
            XCTAssertEqual(descriptor.stock, film.targetPrint)
            XCTAssertTrue(descriptor.isStill || descriptor.isCine)
            // The print medium must be able to print the film.
            XCTAssertNotNil(StockCatalog.printMedium(stock: descriptor.stock))
        }
        // A slide has no print medium.
        for film in StockCatalog.positiveFilms {
            XCTAssertNil(StockCatalog.defaultPrint(for: film.stock))
            XCTAssertTrue(StockCatalog.isScannedDirectly(stock: film.stock))
        }
        // A negative is not scanned directly by default.
        XCTAssertFalse(StockCatalog.isScannedDirectly(stock: "kodak_portra_400"))
    }

    // MARK: - The parameters of a look

    /// The parameters of a look are the upstream defaults and they are
    /// digested.
    func testPipelineParamsOfALook() throws {
        let params = try StockCatalog.pipelineParams(film: "kodak_portra_400")
        XCTAssertEqual(params.film.info.stock, "kodak_portra_400")
        XCTAssertEqual(params.print.info.stock, "kodak_portra_endura")
        XCTAssertFalse(params.io.scanFilm, "a negative is printed by default")
        XCTAssertFalse(params.camera.autoExposure)
        // The unsharp mask of the scanner keeps its upstream default now
        // that it is ported.
        XCTAssertEqual(params.scanner.unsharpMaskSigma, 0.7)
        XCTAssertEqual(params.scanner.unsharpMaskAmount, 0.7)

        // The digest of the stock is applied: the DIR coupler chemistry of a
        // negative and the neutral print filters of the pair.
        XCTAssertEqual(params.filmRender.dirCouplers.gammaSamelayerRGB, [0.336, 0.319, 0.273])
        XCTAssertEqual(params.filmRender.dirCouplers.gammaInterlayerRToGB, [0.353, 0.302])
        XCTAssertEqual(params.filmRender.dirCouplers.gammaInterlayerGToRB, [0.154, 0.353])
        XCTAssertEqual(params.filmRender.dirCouplers.gammaInterlayerBToRG, [0.168, 0.226])
        XCTAssertEqual(params.filmRender.halation.halationFirstSigmaUM, [65, 65, 65])
        XCTAssertEqual(params.filmRender.halation.halationStrength, [0.015, 0.005, 0])
        XCTAssertEqual(params.enlarger.cFilterNeutral, 0, accuracy: 1e-9)
        XCTAssertEqual(params.enlarger.mFilterNeutral, 51.56801468495496, accuracy: 1e-6)
        XCTAssertEqual(params.enlarger.yFilterNeutral, 52.53400422349596, accuracy: 1e-6)

        // A slide is scanned directly and has its own DIR coupler chemistry.
        let slide = try StockCatalog.pipelineParams(film: "fujifilm_velvia_100")
        XCTAssertTrue(slide.io.scanFilm)
        XCTAssertEqual(slide.filmRender.dirCouplers.gammaSamelayerRGB, [0.108, 0.072, 0.054])
        XCTAssertEqual(slide.filmRender.dirCouplers.gammaInterlayerRToGB, [0.108, 0.054])
        XCTAssertEqual(slide.filmRender.dirCouplers.gammaInterlayerGToRB, [0.072, 0.054])
        XCTAssertEqual(slide.filmRender.dirCouplers.gammaInterlayerBToRG, [0.054, 0.054])
    }

    /// The digest is idempotent: digesting twice does not change the values.
    func testDigestIsIdempotent() throws {
        for descriptor in StockCatalog.allStocks where descriptor.isFilm {
            let params = try StockCatalog.pipelineParams(
                film: descriptor.stock,
                print: "kodak_portra_endura",
                scanFilm: descriptor.isPositive
            )
            let twice = Digest.digest(params)
            XCTAssertEqual(twice.filmRender.dirCouplers, params.filmRender.dirCouplers)
            XCTAssertEqual(
                twice.filmRender.halation.halationFirstSigmaUM,
                params.filmRender.halation.halationFirstSigmaUM
            )
            XCTAssertEqual(
                twice.filmRender.halation.halationStrength,
                params.filmRender.halation.halationStrength
            )
            XCTAssertEqual(twice.enlarger.cFilterNeutral, params.enlarger.cFilterNeutral)
            XCTAssertEqual(twice.enlarger.mFilterNeutral, params.enlarger.mFilterNeutral)
            XCTAssertEqual(twice.enlarger.yFilterNeutral, params.enlarger.yFilterNeutral)
        }
    }

    /// A parameter the user has customised is not overwritten by the digest.
    func testDigestKeepsTheCustomisedValues() throws {
        var params = try StockCatalog.pipelineParams(film: "kodak_portra_400")
        params.filmRender.dirCouplers.gammaSamelayerRGB = [0.2, 0.2, 0.2]
        params.enlarger.mFilterNeutral = 12.0
        params.filmRender.halation.halationStrength = [0.5, 0.5, 0.5]

        let digested = Digest.digest(params)
        XCTAssertEqual(digested.filmRender.dirCouplers.gammaSamelayerRGB, [0.2, 0.2, 0.2])
        XCTAssertEqual(digested.enlarger.mFilterNeutral, 12.0)
        XCTAssertEqual(digested.filmRender.halation.halationStrength, [0.5, 0.5, 0.5])
    }

    /// Every stock of the catalogue can be simulated.
    func testEveryLookRuns() throws {
        let image = RGBImage(width: 2, height: 2, data: [
            0.2, 0.2, 0.2, 0.5, 0.4, 0.3,
            0.8, 0.7, 0.6, 1.0, 0.9, 0.8,
        ])
        for look in StockCatalog.looks {
            let params = try StockCatalog.pipelineParams(
                film: look.film.stock,
                print: look.print?.stock,
                scanFilm: look.scanFilm
            )
            let pipeline = try FilmPipeline(params: params)
            let taps = try pipeline.process(rgbIn: image)
            XCTAssertEqual(taps.rgbOut.data.count, 2 * 2 * 3, "\(look.id)")
            XCTAssertTrue(taps.rgbOut.data.allSatisfy { $0.isFinite }, "\(look.id)")
            if look.scanFilm {
                XCTAssertEqual(taps.cmyFilm.data.count, 2 * 2 * 3, "\(look.id)")
                XCTAssertTrue(taps.logEPrint.data.isEmpty, "\(look.id): no print stage")
            } else {
                XCTAssertEqual(taps.cmyPrint.data.count, 2 * 2 * 3, "\(look.id)")
            }
        }
    }
}
